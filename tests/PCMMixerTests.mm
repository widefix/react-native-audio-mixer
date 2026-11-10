#import "../ios/PCMDecoder.h"
#include <cassert>
#include <iostream>

int main(int argc, const char **argv) {
    @autoreleasepool {
        armsaudio::Mixer mixer;
        auto a = std::make_shared<armsaudio::Track>();
        auto b = std::make_shared<armsaudio::Track>();
        a->channelCount = 2;
        b->channelCount = 2;
        a->samples = {0.2f, 0.4f, 0.3f, 0.5f};
        b->samples = {0.1f, 0.2f};
        mixer.tracks = {a, b};
        mixer.length = 2;
        float output[8];
        mixer.render(output, 4);
        assert(std::abs(output[0] - 0.3f) < 1e-6);
        assert(std::abs(output[1] - 0.6f) < 1e-6);
        assert(std::abs(output[2] - 0.3f) < 1e-6);
        assert(output[4] == 0 && output[7] == 0);
        assert(mixer.position == 2);
        mixer.render(output, 4);
        for (float sample : output) assert(sample == 0);
        assert(a->amplitude == 0 && b->amplitude == 0);
        mixer.position = 0;
        a->pan = -1;
        b->volume = 0;
        mixer.render(output, 1);
        assert(std::abs(output[0] - 0.2f) < 1e-6 && output[1] == 0);
        mixer.position = 0;
        a->pan = 1;
        a->volume = 0.5;
        mixer.render(output, 1);
        assert(output[0] == 0 && std::abs(output[1] - 0.2f) < 1e-6);
        // Two full-scale tracks sum past 1 and clip. One shared position still advances both.
        auto clipLeft = std::make_shared<armsaudio::Track>();
        auto clipRight = std::make_shared<armsaudio::Track>();
        clipLeft->channelCount = clipRight->channelCount = 2;
        clipLeft->samples = clipRight->samples = {1.f, -1.f};
        mixer.tracks = {clipLeft, clipRight};
        mixer.length = 1;
        mixer.position = 0;
        mixer.render(output, 1);
        assert(output[0] == 1 && output[1] == -1);
        // A mono track is stored as one channel and spread by the pan law at mix time.
        auto mono = std::make_shared<armsaudio::Track>();
        mono->channelCount = 1;
        mono->samples = {0.5f, 0.f};
        mixer.tracks = {mono, a};
        a->pan = 0;
        a->volume = 0;
        mixer.length = 2;
        mixer.position = 0;
        mixer.render(output, 2);
        assert(std::abs(output[0] - 0.5f) < 1e-6 && std::abs(output[1] - 0.5f) < 1e-6);
        assert(output[2] == 0 && output[3] == 0);
        assert(mixer.position == 2);
        // A ring publishes [validFrom, readyUntil). Frame F lives at F % capacity, and the slot
        // capacity behind the write is stale.
        auto ring = std::make_shared<armsaudio::Track>();
        ring->channelCount = 1;
        ring->capacityFrames = 4;
        ring->lengthFrames.store(8);
        ring->samples = {0.25f, 0.5f, 0.75f, 1.f};
        ring->validFrom.store(0);
        ring->readyUntil.store(4);
        mixer.tracks = {ring};
        mixer.length = 8;
        mixer.position = 0;
        mixer.render(output, 1);
        assert(std::abs(output[0] - 0.25f) < 1e-5 && std::abs(output[1] - 0.25f) < 1e-5);
        ring->readyUntil.store(6);
        mixer.position = 0;
        mixer.render(output, 1);
        assert(output[0] == 0 && output[1] == 0);
        mixer.position = 4;
        mixer.render(output, 1);
        assert(std::abs(output[0] - 0.25f) < 1e-5);
        mixer.position = 6;
        mixer.render(output, 1);
        assert(output[0] == 0 && output[1] == 0);
        ring->validFrom.store(4);
        ring->readyUntil.store(4);
        mixer.position = 4;
        mixer.render(output, 1);
        assert(output[0] == 0 && output[1] == 0);
        ring->readyUntil.store(5);
        mixer.position = 4;
        mixer.render(output, 1);
        assert(std::abs(output[0] - 0.25f) < 1e-5);

        assert(argc > 1);
        for (int i = 1; i < argc; ++i) {
            NSError *error = nil;
            auto decoded = DecodeTrack([NSURL fileURLWithPath:@(argv[i])], &error);
            assert(decoded && !error);
            assert(decoded->channelCount == armsaudio::channels);
            const auto frames = decoded->frameCount();
            assert(frames >= 47000 && frames <= 50000);
            assert(decoded->samples.size() == frames * armsaudio::channels);
            double energy = 0;
            for (float sample : decoded->samples) {
                assert(std::isfinite(sample));
                energy += double(sample) * sample;
            }
            assert(energy > 1);
            mixer.tracks = {decoded}; mixer.length = frames; mixer.position = frames - 1;
            mixer.render(output, 4);
            assert(output[2] == 0 && mixer.position == frames);
        }
        NSError *streamError = nil;
        auto streamed = DecodeTrack([NSURL fileURLWithPath:@(argv[1])], &streamError, 8000);
        assert(streamed && !streamError);
        assert(streamed->capacityFrames == 8000);
        assert(streamed->frameCount() > streamed->capacityFrames);
        assert(streamed->samples.size() == size_t(8000) * streamed->channelCount);
        const uint64_t primed = streamed->readyUntil.load();
        assert(primed > 4000 && primed <= 8000);
        mixer.tracks = {streamed};
        mixer.length = streamed->frameCount();
        mixer.position = 4000;
        float streamedOutput[512];
        auto energyOf = [](const float *samples, size_t count) {
            double energy = 0;
            for (size_t i = 0; i < count; ++i) energy += double(samples[i]) * samples[i];
            return energy;
        };
        mixer.render(streamedOutput, 256);
        assert(energyOf(streamedOutput, 512) > 1e-4);
        mixer.position = 30000;
        mixer.render(streamedOutput, 64);
        assert(streamedOutput[0] == 0 && streamedOutput[1] == 0);
        streamed->fillToward(mixer.position);
        mixer.render(streamedOutput, 256);
        assert(energyOf(streamedOutput, 512) > 1e-4);
        streamed->seekTo(0);
        mixer.position = 30000;
        mixer.render(streamedOutput, 64);
        assert(streamedOutput[0] == 0 && streamedOutput[1] == 0);
        mixer.position = 4000;
        mixer.render(streamedOutput, 256);
        assert(energyOf(streamedOutput, 512) > 1e-4);
        NSError *error = nil;
        assert(!DecodeTrack([NSURL fileURLWithPath:@"/nonexistent/audio.m4a"], &error));
        assert(error);
        std::cout << "PCM mixing and M4A decoding tests passed\n";
    }
}
