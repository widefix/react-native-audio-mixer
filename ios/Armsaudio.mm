#import <React/RCTBridgeModule.h>
#import <React/RCTEventEmitter.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#include "PCMDecoder.h"
#include <chrono>
#include <condition_variable>
#include <mutex>
#include <thread>
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MINIAUDIO_IMPLEMENTATION
#include "vendor/miniaudio.h"

@interface Armsaudio : RCTEventEmitter <RCTBridgeModule>
@end

@implementation Armsaudio {
    armsaudio::Mixer _mixer;
    ma_context _context;
    ma_device _device;
    BOOL _contextReady, _deviceReady, _playing, _resumeAfterBackground, _resumeAfterInterruption;
    NSUInteger _generation, _pending;
    NSMutableDictionary<NSString *, NSNumber *> *_trackIndices;
    NSMutableDictionary<NSString *, NSString *> *_urlMap;
    NSMutableArray<NSURLSessionTask *> *_downloads;
    NSTimer *_timer;
    NSString *_stemsDirectory;
    std::thread _filler;
    std::mutex _tracksMutex;
    std::mutex _fillCvMutex;
    std::condition_variable _fillCv;
    bool _fillStop, _fillAwake, _fillKick;
}
RCT_EXPORT_MODULE(Armsaudio)
+ (BOOL)requiresMainQueueSetup { return YES; }
- (dispatch_queue_t)methodQueue { return dispatch_get_main_queue(); }
- (NSArray<NSString *> *)supportedEvents {
    return @[@"DownloadComplete", @"TrackLoaded", @"MixerDurationSet", @"PlaybackProgress",
             @"DownloadErrors", @"TracksAmplitudes", @"AppErrorsX", @"DownloadStart", @"PlaybackPaused"];
}
- (instancetype)init {
    if ((self = [super init])) {
        _trackIndices = [NSMutableDictionary new];
        _urlMap = [NSMutableDictionary new];
        _downloads = [NSMutableArray new];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(background) name:UIApplicationWillResignActiveNotification object:nil];
        [nc addObserver:self selector:@selector(foreground) name:UIApplicationDidBecomeActiveNotification object:nil];
        [nc addObserver:self selector:@selector(interruption:) name:AVAudioSessionInterruptionNotification object:nil];
        _fillStop = _fillAwake = _fillKick = NO;
        // A killed app never reaches reset, so previous loads leave their M4A folders behind.
        [self deleteOrphanStemDirectories];
    }
    return self;
}
- (void)emitError:(NSString *)event message:(NSString *)message {
    [self sendEventWithName:event body:@{@"errMsg": message}];
}
- (BOOL)prepareDevice {
    if (_deviceReady) return YES;
    ma_context_config contextConfig = ma_context_config_init();
    contextConfig.coreaudio.sessionCategory = ma_ios_session_category_none;
    contextConfig.coreaudio.noAudioSessionActivate = MA_TRUE;
    contextConfig.coreaudio.noAudioSessionDeactivate = MA_TRUE;
    ma_result result = ma_context_init(nullptr, 0, &contextConfig, &_context);
    if (result == MA_SUCCESS) {
        _contextReady = YES;
        ma_device_config config = ma_device_config_init(ma_device_type_playback);
        config.playback.format = ma_format_f32;
        config.playback.channels = armsaudio::channels;
        config.sampleRate = armsaudio::sampleRate;
        config.pUserData = &_mixer;
        config.dataCallback = [](ma_device *device, void *output, const void *, ma_uint32 frames) {
            static_cast<armsaudio::Mixer *>(device->pUserData)->render(static_cast<float *>(output), frames);
        };
        result = ma_device_init(&_context, &config, &_device);
        _deviceReady = result == MA_SUCCESS;
    }
    if (!_deviceReady) {
        if (_contextReady) ma_context_uninit(&_context);
        _contextReady = NO;
        [self emitError:@"AppErrorsX" message:[NSString stringWithFormat:@"Cannot initialize miniaudio (%d)", result]];
    }
    return _deviceReady;
}
- (void)pause {
    if (_deviceReady && _playing) ma_device_stop(&_device);
    _playing = NO;
    std::lock_guard<std::mutex> lock(_fillCvMutex);
    _fillAwake = false;
}
- (void)wakeFiller {
    {
        std::lock_guard<std::mutex> lock(_fillCvMutex);
        _fillAwake = true;
    }
    _fillCv.notify_one();
}
- (void)kickFiller {
    {
        std::lock_guard<std::mutex> lock(_fillCvMutex);
        _fillKick = true;
    }
    _fillCv.notify_one();
}
- (void)stopFiller {
    {
        std::lock_guard<std::mutex> lock(_fillCvMutex);
        _fillStop = true;
    }
    _fillCv.notify_one();
    if (_filler.joinable()) _filler.join();
}
- (void)startFiller {
    [self stopFiller];
    {
        std::lock_guard<std::mutex> lock(_fillCvMutex);
        _fillStop = false;
        _fillAwake = false;
        _fillKick = false;
    }
    // Raw pointer: this thread must not keep the module alive. stopFiller joins it before dealloc continues.
    void *owner = (__bridge void *)self;
    _filler = std::thread([owner] {
        while (true) {
            __unsafe_unretained Armsaudio *self = (__bridge Armsaudio *)owner;
            bool playing = false;
            {
                std::unique_lock<std::mutex> lock(self->_fillCvMutex);
                self->_fillCv.wait(lock, [&] { return self->_fillStop || self->_fillAwake || self->_fillKick; });
                if (self->_fillStop) break;
                playing = self->_fillAwake;
                // A seek while paused needs one refill, then the thread waits again.
                if (!playing) self->_fillKick = false;
            }
            std::vector<std::shared_ptr<armsaudio::Track>> tracks;
            {
                std::lock_guard<std::mutex> lock(self->_tracksMutex);
                tracks = self->_mixer.tracks;
            }
            @autoreleasepool {
                for (const auto &track : tracks) track->fillToward(self->_mixer.position);
            }
            if (playing) std::this_thread::sleep_for(std::chrono::milliseconds(5));
        }
    });
}
- (NSURL *)copyStemAtLocation:(NSURL *)location name:(NSString *)name directory:(NSString *)directory error:(NSError **)error {
    if (!location || directory.length == 0) return nil;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) return nil;
    NSURL *dest = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:name]];
    [fm removeItemAtURL:dest error:nil];
    if (![fm copyItemAtURL:location toURL:dest error:error]) return nil;
    return dest;
}
- (void)deleteStemsDirectory {
    if (!_stemsDirectory) return;
    [NSFileManager.defaultManager removeItemAtPath:_stemsDirectory error:nil];
    _stemsDirectory = nil;
}
- (void)deleteOrphanStemDirectories {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *tmp = NSTemporaryDirectory();
    for (NSString *name in [fm contentsOfDirectoryAtPath:tmp error:nil]) {
        if (![name hasPrefix:@"armsaudio"]) continue;
        NSString *path = [tmp stringByAppendingPathComponent:name];
        BOOL directory = NO;
        if (![fm fileExistsAtPath:path isDirectory:&directory] || !directory) continue;
        if (_stemsDirectory.length && [path isEqualToString:_stemsDirectory]) continue;
        [fm removeItemAtPath:path error:nil];
    }
}
- (void)failToPlay:(NSString *)message {
    if (message) [self emitError:@"AppErrorsX" message:message];
    [self sendEventWithName:@"PlaybackPaused" body:nil];
}
- (void)play {
    if (_pending || _mixer.tracks.empty()) {
        [self failToPlay:nil];
        return;
    }
    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    if (![session setCategory:AVAudioSessionCategoryPlayback error:&error] || ![session setActive:YES error:&error]) {
        [self failToPlay:error.localizedDescription];
        return;
    }
    if (![self prepareDevice]) {
        [self failToPlay:nil];
        return;
    }
    if (ma_device_start(&_device) == MA_SUCCESS) {
        _playing = YES;
        [self wakeFiller];
    } else [self failToPlay:@"Cannot start miniaudio playback"];
}
RCT_EXPORT_METHOD(togglePlay) {
    // A pending resume still counts as playing, so Pause cancels it instead of starting audio.
    BOOL playing = _playing || _resumeAfterBackground || _resumeAfterInterruption;
    _resumeAfterBackground = _resumeAfterInterruption = NO;
    if (playing) [self pause]; else [self play];
}
RCT_EXPORT_METHOD(setVolume:(float)volume forFileName:(NSString *)fileName) {
    NSNumber *index = _trackIndices[fileName];
    if (!index) { [self emitError:@"AppErrorsX" message:@"Unknown mixer track"]; return; }
    if (std::isfinite(volume)) _mixer.tracks[index.unsignedIntegerValue]->volume.store(std::max(0.f, std::min(1.f, volume)));
}
RCT_EXPORT_METHOD(setPan:(float)pan forFileName:(NSString *)fileName) {
    NSNumber *index = _trackIndices[fileName];
    if (!index) { [self emitError:@"AppErrorsX" message:@"Unknown mixer track"]; return; }
    // The slider and Android use -1 = left, 0 = center, 1 = right.
    if (std::isfinite(pan)) _mixer.tracks[index.unsignedIntegerValue]->pan.store(std::max(-1.f, std::min(1.f, pan)));
}
RCT_EXPORT_METHOD(setPlaybackPosition:(double)point) {
    if (!std::isfinite(point)) return;
    BOOL playing = _playing;
    [self pause];
    const uint64_t frame = uint64_t(std::max(0.0, std::min(1.0, point)) * _mixer.length);
    std::vector<std::shared_ptr<armsaudio::Track>> tracks;
    {
        std::lock_guard<std::mutex> lock(_tracksMutex);
        tracks = _mixer.tracks;
    }
    // Quiesce the reader until every cursor and the shared position have moved.
    [self stopFiller];
    for (const auto &track : tracks) track->seekTo(frame);
    _mixer.position.store(frame);
    [self startFiller];
    [self kickFiller];
    if (playing) [self play];
}
RCT_EXPORT_METHOD(resetApp) {
    ++_generation;
    for (NSURLSessionTask *task in _downloads) [task cancel];
    [_downloads removeAllObjects];
    [_timer invalidate]; _timer = nil;
    [self pause];
    [self stopFiller];
    if (_deviceReady) ma_device_uninit(&_device);
    if (_contextReady) ma_context_uninit(&_context);
    _deviceReady = _contextReady = NO;
    _resumeAfterBackground = _resumeAfterInterruption = NO;
    {
        std::lock_guard<std::mutex> lock(_tracksMutex);
        _mixer.tracks.clear();
        _mixer.length = 0;
        _mixer.position.store(0);
    }
    [_trackIndices removeAllObjects];
    [_urlMap removeAllObjects];
    _pending = 0;
    [self deleteStemsDirectory];
    _stemsDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"armsaudio-%@", NSUUID.UUID.UUIDString]];
    [self startFiller];
}
- (void)tick {
    if (!_playing) return;
    uint64_t position = _mixer.position.load();
    [self sendEventWithName:@"PlaybackProgress" body:@{@"progress": @(_mixer.length ? double(position) / _mixer.length : 0)}];
    NSMutableDictionary *amplitudes = [NSMutableDictionary new];
    for (NSString *name in _trackIndices) amplitudes[name] = @(_mixer.tracks[_trackIndices[name].unsignedIntegerValue]->amplitude.load());
    [self sendEventWithName:@"TracksAmplitudes" body:@{@"amplitudes": amplitudes}];
}
- (void)finishDownloads {
    [_downloads removeAllObjects];
    __weak Armsaudio *weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *) { [weakSelf tick]; }];
    [self sendEventWithName:@"DownloadComplete" body:[_urlMap copy]];
    [self sendEventWithName:@"MixerDurationSet" body:@(double(_mixer.length) / armsaudio::sampleRate)];
}
RCT_EXPORT_METHOD(downloadAudioFiles:(NSArray<NSString *> *)urls) {
    [self resetApp];
    [self sendEventWithName:@"DownloadStart" body:@{@"status": @"DownloadStart"}];
    NSUInteger generation = _generation;
    _pending = urls.count;
    if (!_pending) { [self finishDownloads]; return; }
    for (NSUInteger index = 0; index < urls.count; ++index) {
        NSString *urlString = urls[index];
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url || ![@[@"https", @"http"] containsObject:url.scheme.lowercaseString]) {
            [self resetApp];
            [self emitError:@"DownloadErrors" message:@"Invalid audio URL"];
            return;
        }
        // Unique identifiers also handle tracks whose URLs share a basename.
        NSString *name = [NSString stringWithFormat:@"track%lu.m4a", (unsigned long)index];
        NSString *stemsDirectory = _stemsDirectory;
        __weak Armsaudio *weakSelf = self;
        NSURLSessionDownloadTask *task = [NSURLSession.sharedSession downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *downloadError) {
            @autoreleasepool {
                NSError *error = downloadError;
                __block std::shared_ptr<armsaudio::Track> track;
                NSURL *saved = nil;
                NSInteger statusCode = [(NSHTTPURLResponse *)response statusCode];
                if (!error && (statusCode < 200 || statusCode >= 300)) {
                    error = [NSError errorWithDomain:@"ArmsaudioHTTP" code:statusCode userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Audio download failed (HTTP %ld)", (long)statusCode]}];
                }
                // URLSession deletes its temporary file when this handler returns, so keep our own copy.
                Armsaudio *loader = weakSelf;
                if (!error && location && loader)
                    saved = [loader copyStemAtLocation:location name:name directory:stemsDirectory error:&error];
                if (!error && saved) track = DecodeTrack(saved, &error);
                dispatch_async(dispatch_get_main_queue(), ^{
                    Armsaudio *self = weakSelf;
                    if (!self || generation != self->_generation) {
                        track.reset();
                        NSFileManager *fm = NSFileManager.defaultManager;
                        if (saved) [fm removeItemAtURL:saved error:nil];
                        if (stemsDirectory.length && (!self || ![stemsDirectory isEqualToString:self->_stemsDirectory]))
                            [fm removeItemAtPath:stemsDirectory error:nil];
                        return;
                    }
                    if (!track) {
                        [self resetApp];
                        NSMutableDictionary *body = [@{@"errMsg": error.localizedDescription ?: @"Cannot decode downloaded audio"} mutableCopy];
                        if (error.userInfo[@"reason"]) body[@"reason"] = error.userInfo[@"reason"];
                        [self sendEventWithName:@"DownloadErrors" body:body];
                        return;
                    }
                    {
                        std::lock_guard<std::mutex> lock(self->_tracksMutex);
                        self->_trackIndices[name] = @(self->_mixer.tracks.size());
                        self->_mixer.tracks.push_back(track);
                        self->_mixer.length = std::max(self->_mixer.length, track->frameCount());
                    }
                    self->_urlMap[urlString] = name;
                    [self sendEventWithName:@"TrackLoaded" body:@{@"name": name}];
                    if (--self->_pending == 0) [self finishDownloads];
                });
            }
        }];
        [_downloads addObject:task];
        [task resume];
    }
}
- (void)background {
    if (_playing) {
        _resumeAfterBackground = YES;
        [self pause];
        [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
    }
}
- (void)foreground {
    if (_resumeAfterBackground && !_resumeAfterInterruption) { _resumeAfterBackground = NO; [self play]; }
}
- (void)interruption:(NSNotification *)notification {
    // AVAudioSession notifications are not guaranteed to arrive on main.
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([notification.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan) {
            self->_resumeAfterInterruption = self->_playing || self->_resumeAfterBackground;
            [self pause];
        } else {
            BOOL resume = self->_resumeAfterInterruption;
            self->_resumeAfterInterruption = NO;
            BOOL allowed = ([notification.userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue] & AVAudioSessionInterruptionOptionShouldResume) != 0;
            if (resume && allowed) {
                if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                    self->_resumeAfterBackground = NO;
                    [self play];
                } else self->_resumeAfterBackground = YES;
            } else {
                self->_resumeAfterBackground = NO;
                // Native playback stays paused. Tell JS so the button matches.
                if (resume) [self sendEventWithName:@"PlaybackPaused" body:nil];
            }
        }
    });
}
- (void)invalidate {
    dispatch_async(dispatch_get_main_queue(), ^{ [self resetApp]; });
    [super invalidate];
}
- (void)dealloc {
    [self stopFiller];
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_timer invalidate];
    for (NSURLSessionTask *task in _downloads) [task cancel];
    if (_deviceReady) ma_device_uninit(&_device);
    if (_contextReady) ma_context_uninit(&_context);
    _mixer.tracks.clear();
    [self deleteStemsDirectory];
}
@end
