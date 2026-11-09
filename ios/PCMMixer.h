#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

namespace armsaudio {
constexpr uint32_t sampleRate = 48000;
constexpr uint32_t channels = 2;
// A long track keeps this much decoded audio. The reader stays this far behind
// the end of the ring so it never overwrites a frame the callback is playing.
constexpr uint32_t streamWindowFrames = sampleRate * 2;
constexpr uint32_t streamSafetyFrames = 8192;

struct Track {
    // Full song when capacityFrames is 0. Otherwise a ring: frame F is samples[(F % capacityFrames) * channelCount].
    std::vector<float> samples;
    uint32_t channelCount = 2;
    uint32_t capacityFrames = 0;
    std::atomic<uint64_t> lengthFrames{0};
    std::atomic<uint64_t> validFrom{0};
    std::atomic<uint64_t> readyUntil{0};
    double fileSampleRate = sampleRate;
    void *audioFile = nullptr;
    std::mutex decodeLock;
    std::atomic<float> volume{1}, pan{0}, amplitude{0};

    uint64_t frameCount() const {
        const uint64_t length = lengthFrames.load(std::memory_order_acquire);
        if (length) return length;
        return channelCount ? samples.size() / channelCount : 0;
    }
    // Fills decoded audio up to the playhead. The audio callback must not call this.
    void fillToward(const std::atomic<uint64_t> &playhead);
    // Moves the open file to a frame. Call only while the device is stopped.
    void seekTo(uint64_t frame);

    Track() = default;
    Track(const Track &) = delete;
    Track &operator=(const Track &) = delete;
    ~Track();
};

// The callback reads every track at one shared position. It does not allocate,
// take a lock, or read a file. A reader thread publishes frames into each ring.
struct Mixer {
    std::vector<std::shared_ptr<Track>> tracks;
    std::atomic<uint64_t> position{0};
    uint64_t length = 0;

    void render(float *output, uint32_t frames) {
        std::fill_n(output, size_t(frames) * channels, 0.0f);
        const uint64_t start = position.load();
        for (const auto &track : tracks) {
            const float volume = track->volume.load();
            const float pan = track->pan.load();
            const float left = volume * std::min(1.0f, 1 - pan);
            const float right = volume * std::min(1.0f, 1 + pan);
            const uint32_t trackChannels = track->channelCount == 1 ? 1u : 2u;
            const uint64_t songFrames = track->frameCount();
            const bool streaming = track->capacityFrames != 0;
            const uint32_t cap = streaming ? track->capacityFrames : uint32_t(std::min<uint64_t>(songFrames, 0xffffffffu));
            double energy = 0;
            if (cap != 0 && track->samples.size() >= size_t(cap) * trackChannels) {
                const uint64_t ready = streaming ? track->readyUntil.load(std::memory_order_acquire) : songFrames;
                const uint64_t from = streaming ? track->validFrom.load(std::memory_order_acquire) : 0;
                const uint64_t oldest = std::max(from, ready > cap ? ready - cap : 0);
                const uint32_t available = start < songFrames ? uint32_t(std::min<uint64_t>(frames, songFrames - start)) : 0;
                for (uint32_t i = 0; i < available; ++i) {
                    const uint64_t frame = start + i;
                    if (frame < oldest || frame >= ready) continue;
                    const size_t index = size_t(frame % cap);
                    float l, r;
                    if (trackChannels == 1) {
                        const float sample = track->samples[index];
                        l = sample * left;
                        r = sample * right;
                    } else {
                        l = track->samples[index * 2] * left;
                        r = track->samples[index * 2 + 1] * right;
                    }
                    output[i * channels] += l;
                    output[i * channels + 1] += r;
                    energy += (double(l) * l + double(r) * r) / 2;
                }
            }
            track->amplitude.store(frames ? std::min(1.0, std::sqrt(energy / frames)) : 0);
        }
        for (size_t i = 0; i < size_t(frames) * channels; ++i)
            output[i] = std::max(-1.0f, std::min(1.0f, output[i]));
        position.store(std::min(length, start + frames));
    }
};
}
