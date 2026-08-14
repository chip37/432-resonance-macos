#import "RealtimeAudioRingBuffer.h"

#include <atomic>
#include <cstdint>
#include <memory>
#include <vector>

namespace {

struct RealtimeAudioRingBufferImplementation {
    std::vector<float> storage;
    NSUInteger channelCount = 0;
    NSUInteger capacityFrames = 0;
    std::atomic<uint64_t> readFrame{0};
    std::atomic<uint64_t> writeFrame{0};
    std::atomic<uint64_t> overflowCount{0};
    std::atomic<uint64_t> underflowCount{0};
};

} // namespace

@interface RealtimeAudioRingBuffer ()

@property(nonatomic, assign) void *implementation;

@end

@implementation RealtimeAudioRingBuffer

- (instancetype)init {
    self = [super init];
    if (self) {
        _implementation = new RealtimeAudioRingBufferImplementation();
    }
    return self;
}

- (BOOL)configureWithChannelCount:(NSUInteger)channelCount
                   capacityFrames:(NSUInteger)capacityFrames {
    if (channelCount == 0 || capacityFrames == 0) {
        return NO;
    }

    auto *implementation =
        static_cast<RealtimeAudioRingBufferImplementation *>(_implementation);
    implementation->storage.assign(channelCount * capacityFrames, 0.0F);
    implementation->channelCount = channelCount;
    implementation->capacityFrames = capacityFrames;
    [self reset];
    return YES;
}

- (BOOL)writeChannels:(float * _Nonnull const * _Nonnull)channels
          channelCount:(NSUInteger)channelCount
            frameCount:(NSUInteger)frameCount {
    auto *implementation =
        static_cast<RealtimeAudioRingBufferImplementation *>(_implementation);
    if (channels == nullptr ||
        channelCount != implementation->channelCount ||
        frameCount == 0 ||
        frameCount > implementation->capacityFrames) {
        implementation->overflowCount.fetch_add(1, std::memory_order_relaxed);
        return NO;
    }

    const uint64_t writeFrame =
        implementation->writeFrame.load(std::memory_order_relaxed);
    const uint64_t readFrame =
        implementation->readFrame.load(std::memory_order_acquire);
    const uint64_t availableFrames = writeFrame - readFrame;
    const uint64_t freeFrames = implementation->capacityFrames - availableFrames;
    if (frameCount > freeFrames) {
        implementation->overflowCount.fetch_add(1, std::memory_order_relaxed);
        return NO;
    }

    for (NSUInteger channel = 0; channel < channelCount; ++channel) {
        float *destination = implementation->storage.data()
            + channel * implementation->capacityFrames;
        const float *source = channels[channel];
        for (NSUInteger frame = 0; frame < frameCount; ++frame) {
            destination[(writeFrame + frame) % implementation->capacityFrames] =
                source[frame];
        }
    }

    implementation->writeFrame.store(
        writeFrame + frameCount,
        std::memory_order_release
    );
    return YES;
}

- (NSUInteger)readChannels:(float * _Nonnull const * _Nonnull)channels
               channelCount:(NSUInteger)channelCount
                 frameCount:(NSUInteger)frameCount {
    auto *implementation =
        static_cast<RealtimeAudioRingBufferImplementation *>(_implementation);
    if (channels == nullptr || channelCount != implementation->channelCount) {
        return 0;
    }

    const uint64_t readFrame =
        implementation->readFrame.load(std::memory_order_relaxed);
    const uint64_t writeFrame =
        implementation->writeFrame.load(std::memory_order_acquire);
    const NSUInteger availableFrames =
        static_cast<NSUInteger>(writeFrame - readFrame);
    const NSUInteger framesToRead = MIN(frameCount, availableFrames);
    if (framesToRead < frameCount) {
        implementation->underflowCount.fetch_add(1, std::memory_order_relaxed);
    }

    for (NSUInteger channel = 0; channel < channelCount; ++channel) {
        const float *source = implementation->storage.data()
            + channel * implementation->capacityFrames;
        float *destination = channels[channel];
        for (NSUInteger frame = 0; frame < framesToRead; ++frame) {
            destination[frame] =
                source[(readFrame + frame) % implementation->capacityFrames];
        }
    }

    implementation->readFrame.store(
        readFrame + framesToRead,
        std::memory_order_release
    );
    return framesToRead;
}

- (NSUInteger)readLeftChannel:(float * _Nonnull)leftChannel
                  rightChannel:(float * _Nonnull)rightChannel
                    frameCount:(NSUInteger)frameCount {
    float *channels[2] = {leftChannel, rightChannel};
    return [self readChannels:channels channelCount:2 frameCount:frameCount];
}

- (NSUInteger)capacityFrames {
    auto *implementation =
        static_cast<RealtimeAudioRingBufferImplementation *>(_implementation);
    return implementation->capacityFrames;
}

- (NSUInteger)availableFrames {
    auto *implementation =
        static_cast<RealtimeAudioRingBufferImplementation *>(_implementation);
    const uint64_t writeFrame =
        implementation->writeFrame.load(std::memory_order_acquire);
    const uint64_t readFrame =
        implementation->readFrame.load(std::memory_order_acquire);
    return static_cast<NSUInteger>(writeFrame - readFrame);
}

- (NSUInteger)freeFrames {
    return self.capacityFrames - self.availableFrames;
}

- (uint64_t)overflowCount {
    auto *implementation =
        static_cast<RealtimeAudioRingBufferImplementation *>(_implementation);
    return implementation->overflowCount.load(std::memory_order_relaxed);
}

- (uint64_t)underflowCount {
    auto *implementation =
        static_cast<RealtimeAudioRingBufferImplementation *>(_implementation);
    return implementation->underflowCount.load(std::memory_order_relaxed);
}

- (void)reset {
    auto *implementation =
        static_cast<RealtimeAudioRingBufferImplementation *>(_implementation);
    implementation->readFrame.store(0, std::memory_order_relaxed);
    implementation->writeFrame.store(0, std::memory_order_relaxed);
    implementation->overflowCount.store(0, std::memory_order_relaxed);
    implementation->underflowCount.store(0, std::memory_order_relaxed);
}

- (void)dealloc {
    delete static_cast<RealtimeAudioRingBufferImplementation *>(_implementation);
    _implementation = nullptr;
}

@end
