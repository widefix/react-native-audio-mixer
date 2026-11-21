#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#include "PCMMixer.h"
#include <limits>
#include <mutex>
#include <new>
#if TARGET_OS_IOS
#include <os/proc.h>
#endif

// Leave room for the rest of the app. os_proc_available_memory() already
// excludes the existing buffer, so only the new allocation is counted.
static constexpr size_t kMemoryMargin = 128ull * 1024 * 1024;

static NSError *OutOfMemoryError(void) {
    return [NSError errorWithDomain:@"RNAudioMixerDecode" code:-2 userInfo:@{
        NSLocalizedDescriptionKey: @"Not enough memory to load this song",
        @"reason": @"memory",
    }];
}

static NSError *DecodeError(OSStatus status) {
    return [NSError errorWithDomain:@"RNAudioMixerDecode" code:status ?: -1 userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Cannot decode audio to PCM (OSStatus %d)", (int)status],
    }];
}

template <typename Sample>
static bool CanAppendSamples(const std::vector<Sample> &samples, size_t extra) {
#if TARGET_OS_IOS
    const size_t newSize = samples.size() + extra;
    if (newSize <= samples.capacity()) return true;
    size_t newCapacity = samples.capacity() == 0 ? extra : samples.capacity();
    while (newCapacity < newSize) {
        if (newCapacity > std::numeric_limits<size_t>::max() / 2) return false;
        newCapacity *= 2;
    }
    if (newCapacity > std::numeric_limits<size_t>::max() / sizeof(Sample)) return false;
    const size_t needed = newCapacity * sizeof(Sample);
    const size_t available = os_proc_available_memory();
    if (available == 0) return true;
    return available > needed + kMemoryMargin;
#else
    (void)samples;
    (void)extra;
    return true;
#endif
}

inline audiomixer::Track::~Track() {
    if (audioFile) ExtAudioFileDispose((ExtAudioFileRef)audioFile);
}

// Caller holds decodeLock. Reads client-format frames into the ring, ahead of
// the playhead, and publishes them with readyUntil.
static void FillWindow(audiomixer::Track *track, uint64_t playhead) {
    ExtAudioFileRef file = (ExtAudioFileRef)track->audioFile;
    const uint32_t capacity = track->capacityFrames;
    if (!file || capacity == 0) return;
    const uint32_t trackChannels = track->channelCount == 1 ? 1u : 2u;
    uint64_t from = track->validFrom.load(std::memory_order_relaxed);
    uint64_t ready = track->readyUntil.load(std::memory_order_relaxed);
    if (playhead < from) return;
    if (ready < from) ready = from;
    uint32_t safety = capacity / 4;
    if (safety > audiomixer::streamSafetyFrames) safety = audiomixer::streamSafetyFrames;
    if (safety == 0 && capacity > 1) safety = 1;
    const uint64_t ahead = safety < capacity ? capacity - safety : capacity;
    const uint64_t length = track->lengthFrames.load(std::memory_order_relaxed);
    const uint64_t target = std::min(length, playhead + ahead);
    float chunk[4096 * audiomixer::channels];
    while (ready < target) {
        UInt32 frames = (UInt32)std::min<uint64_t>(4096, target - ready);
        AudioBufferList buffers = {1, {{trackChannels, (UInt32)(sizeof(float) * frames * trackChannels), chunk}}};
        UInt32 got = frames;
        OSStatus status = ExtAudioFileRead(file, &got, &buffers);
        if (status != noErr) break;
        if (got == 0) {
            track->lengthFrames.store(ready, std::memory_order_release);
            break;
        }
        if (got > frames) got = frames;
        for (UInt32 i = 0; i < got; ++i) {
            const size_t dst = size_t((ready + i) % capacity) * trackChannels;
            for (uint32_t channel = 0; channel < trackChannels; ++channel)
                track->samples[dst + channel] = chunk[i * trackChannels + channel];
        }
        ready += got;
        track->readyUntil.store(ready, std::memory_order_release);
    }
}

inline void audiomixer::Track::fillToward(const std::atomic<uint64_t> &playhead) {
    std::lock_guard<std::mutex> lock(decodeLock);
    FillWindow(this, playhead.load(std::memory_order_acquire));
}

inline void audiomixer::Track::seekTo(uint64_t frame) {
    std::lock_guard<std::mutex> lock(decodeLock);
    ExtAudioFileRef file = (ExtAudioFileRef)audioFile;
    if (!file || capacityFrames == 0) return;
    const uint64_t length = lengthFrames.load(std::memory_order_relaxed);
    if (frame > length) frame = length;
    // ExtAudioFileSeek is in file-format frames, not the 48 kHz client format.
    const SInt64 fileFrame = (SInt64)llround((double)frame * fileSampleRate / (double)audiomixer::sampleRate);
    const OSStatus status = ExtAudioFileSeek(file, fileFrame);
    validFrom.store(frame, std::memory_order_release);
    readyUntil.store(frame, std::memory_order_release);
    if (status != noErr) return;
    FillWindow(this, frame);
}

struct OpenedAudioFile {
    ExtAudioFileRef file = nullptr;
    ~OpenedAudioFile() { if (file) ExtAudioFileDispose(file); }
    OpenedAudioFile() = default;
    OpenedAudioFile(const OpenedAudioFile &) = delete;
    OpenedAudioFile &operator=(const OpenedAudioFile &) = delete;
};

// Files that fit in the window are decoded whole. Longer files keep the M4A
// open and decode streamWindowFrames (or the requested window) into a ring.
static std::shared_ptr<audiomixer::Track> DecodeTrack(NSURL *url, NSError **error, uint32_t windowFrames = audiomixer::streamWindowFrames) {
    try {
        OpenedAudioFile audio;
        OSStatus status = url ? ExtAudioFileOpenURL((__bridge CFURLRef)url, &audio.file) : -1;
        if (status != noErr || !audio.file) {
            if (error) *error = DecodeError(status);
            return nullptr;
        }
        AudioStreamBasicDescription fileFormat = {};
        UInt32 fileFormatSize = sizeof(fileFormat);
        ExtAudioFileGetProperty(audio.file, kExtAudioFileProperty_FileDataFormat, &fileFormatSize, &fileFormat);
        const double rate = fileFormat.mSampleRate > 0 ? fileFormat.mSampleRate : (double)audiomixer::sampleRate;
        const UInt32 trackChannels = audiomixer::channels;
        SInt64 fileFrames = 0;
        UInt32 framesSize = sizeof(fileFrames);
        const OSStatus lengthStatus = ExtAudioFileGetProperty(audio.file, kExtAudioFileProperty_FileLengthFrames, &framesSize, &fileFrames);
        uint64_t estimated = 0;
        if (lengthStatus == noErr && fileFrames > 0)
            estimated = (uint64_t)llround(fileFrames * (double)audiomixer::sampleRate / rate);
        const uint32_t window = windowFrames ? windowFrames : audiomixer::streamWindowFrames;
        AudioStreamBasicDescription format = {};
        format.mSampleRate = audiomixer::sampleRate;
        format.mFormatID = kAudioFormatLinearPCM;
        format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
        format.mBitsPerChannel = 32;
        format.mChannelsPerFrame = trackChannels;
        format.mFramesPerPacket = 1;
        format.mBytesPerFrame = format.mBytesPerPacket = sizeof(float) * trackChannels;
        status = ExtAudioFileSetProperty(audio.file, kExtAudioFileProperty_ClientDataFormat, sizeof(format), &format);
        if (status != noErr) {
            if (error) *error = DecodeError(status);
            return nullptr;
        }
        auto track = std::make_shared<audiomixer::Track>();
        track->channelCount = trackChannels;
        track->fileSampleRate = rate;
        if (estimated > window) {
            const size_t count = size_t(window) * trackChannels;
            {
                static std::mutex allocationLock;
                std::lock_guard<std::mutex> guard(allocationLock);
                if (!CanAppendSamples(track->samples, count)) {
                    if (error) *error = OutOfMemoryError();
                    return nullptr;
                }
                track->samples.assign(count, 0);
            }
            track->capacityFrames = window;
            track->lengthFrames.store(estimated, std::memory_order_release);
            track->audioFile = audio.file;
            audio.file = nullptr;
            std::atomic<uint64_t> origin{0};
            track->fillToward(origin);
            if (track->readyUntil.load(std::memory_order_acquire) == 0) {
                if (error) *error = DecodeError(-1);
                return nullptr;
            }
            return track;
        }
        float samples[4096 * audiomixer::channels];
        static std::mutex growLock;
        bool outOfMemory = false;
        while (status == noErr && !outOfMemory) {
            UInt32 frames = 4096;
            AudioBufferList buffers = {1, {{trackChannels, UInt32(sizeof(samples)), samples}}};
            status = ExtAudioFileRead(audio.file, &frames, &buffers);
            if (status != noErr || frames == 0) break;
            const size_t count = frames * trackChannels;
            std::lock_guard<std::mutex> guard(growLock);
            if (!CanAppendSamples(track->samples, count)) {
                outOfMemory = true;
                break;
            }
            track->samples.insert(track->samples.end(), samples, samples + count);
        }
        if (outOfMemory) {
            if (error) *error = OutOfMemoryError();
            return nullptr;
        }
        if (status != noErr || track->samples.empty()) {
            if (error) *error = DecodeError(status);
            return nullptr;
        }
        track->lengthFrames.store(track->samples.size() / trackChannels, std::memory_order_release);
        return track;
    } catch (const std::bad_alloc &) {
        if (error) *error = OutOfMemoryError();
        return nullptr;
    }
}
