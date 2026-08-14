#import "FixedRateAudioConverter.h"
#import "RealtimeAudioRingBuffer.h"

#import <AudioToolbox/AudioToolbox.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <memory>
#include <thread>
#include <vector>

namespace {

constexpr UInt32 kInputFramesPerChunk = 1024;
constexpr NSTimeInterval kOutputBufferSeconds = 0.25;

AudioStreamBasicDescription planarFloatASBD(double sampleRate, UInt32 channels) {
    AudioStreamBasicDescription format{};
    format.mSampleRate = sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat |
        kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    format.mBytesPerPacket = sizeof(float);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(float);
    format.mChannelsPerFrame = channels;
    format.mBitsPerChannel = 32;
    return format;
}

struct ConverterImplementation {
    AudioConverterRef converter = nullptr;
    __strong RealtimeAudioRingBuffer *sourceRing = nil;
    __strong RealtimeAudioRingBuffer *outputRing = nil;
    double sourceRate = 0;
    double outputRate = 0;
    UInt32 channels = 0;
    UInt32 inputCapacity = kInputFramesPerChunk;
    UInt32 outputCapacity = 0;
    std::vector<float> inputStorage;
    std::vector<float> outputStorage;
    std::vector<float *> inputPointers;
    std::vector<float *> outputPointers;
    std::vector<uint8_t> inputABLStorage;
    std::vector<uint8_t> outputABLStorage;
    std::atomic<bool> running{false};
    std::atomic<uint32_t> sourcePeakBits{0};
    std::atomic<uint32_t> convertedPeakBits{0};
    std::atomic<NSUInteger> producedFrames{0};
    std::atomic<NSUInteger> requestedFrames{0};
    std::thread worker;
};

void updatePeak(std::atomic<uint32_t> &peakBits, float peak) {
    uint32_t candidate;
    memcpy(&candidate, &peak, sizeof(candidate));
    uint32_t current = peakBits.load(std::memory_order_relaxed);
    while (candidate > current && !peakBits.compare_exchange_weak(
        current, candidate, std::memory_order_relaxed
    )) {}
}

AudioBufferList *bufferList(std::vector<uint8_t> &storage, UInt32 channels) {
    const size_t size = sizeof(AudioBufferList)
        + (channels - 1) * sizeof(AudioBuffer);
    storage.assign(size, 0);
    auto *list = reinterpret_cast<AudioBufferList *>(storage.data());
    list->mNumberBuffers = channels;
    return list;
}

OSStatus converterInputProc(
    AudioConverterRef,
    UInt32 *ioPackets,
    AudioBufferList *ioData,
    AudioStreamPacketDescription **,
    void *userData
) {
    auto *implementation = static_cast<ConverterImplementation *>(userData);
    UInt32 requested = std::min(*ioPackets, implementation->inputCapacity);
    NSUInteger read = [implementation->sourceRing
        readLeftChannel:implementation->inputPointers[0]
        rightChannel:implementation->inputPointers[1]
        frameCount:requested];
    float sourcePeak = 0;
    for (UInt32 channel = 0; channel < implementation->channels; ++channel) {
        for (NSUInteger frame = 0; frame < read; ++frame) {
            sourcePeak = std::max(sourcePeak, static_cast<float>(
                std::abs(implementation->inputPointers[channel][frame])
            ));
        }
    }
    updatePeak(implementation->sourcePeakBits, sourcePeak);
    *ioPackets = static_cast<UInt32>(read);
    ioData->mNumberBuffers = implementation->channels;
    for (UInt32 channel = 0; channel < implementation->channels; ++channel) {
        ioData->mBuffers[channel].mNumberChannels = 1;
        ioData->mBuffers[channel].mData = implementation->inputPointers[channel];
        ioData->mBuffers[channel].mDataByteSize =
            static_cast<UInt32>(read * sizeof(float));
    }
    return noErr;
}

} // namespace

@interface FixedRateAudioConverter ()
@property(nonatomic, assign) void *implementation;
@end


@implementation FixedRateAudioConverter

- (instancetype)init {
    self = [super init];
    if (self) _implementation = new ConverterImplementation();
    return self;
}

- (BOOL)configureWithSourceRing:(RealtimeAudioRingBuffer *)sourceRing
               sourceSampleRate:(double)sourceSampleRate
                outputSampleRate:(double)outputSampleRate
                    channelCount:(NSUInteger)channelCount
                           error:(NSError **)error {
    [self teardown];
    if (sourceSampleRate <= 0 || outputSampleRate <= 0 || channelCount != 2) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain
            code:kAudio_ParamError userInfo:@{NSLocalizedDescriptionKey:
            @"Fixed-rate conversion requires valid rates and stereo audio."}];
        return NO;
    }

    auto *impl = static_cast<ConverterImplementation *>(_implementation);
    impl->sourceRing = sourceRing;
    impl->sourceRate = sourceSampleRate;
    impl->outputRate = outputSampleRate;
    impl->channels = static_cast<UInt32>(channelCount);
    impl->outputCapacity = static_cast<UInt32>(
        ceil(kInputFramesPerChunk * outputSampleRate / sourceSampleRate) + 64
    );
    impl->inputStorage.assign(channelCount * impl->inputCapacity, 0);
    impl->outputStorage.assign(channelCount * impl->outputCapacity, 0);
    impl->inputPointers.resize(channelCount);
    impl->outputPointers.resize(channelCount);
    for (NSUInteger channel = 0; channel < channelCount; ++channel) {
        impl->inputPointers[channel] = impl->inputStorage.data()
            + channel * impl->inputCapacity;
        impl->outputPointers[channel] = impl->outputStorage.data()
            + channel * impl->outputCapacity;
    }
    bufferList(impl->inputABLStorage, impl->channels);
    auto *outputABL = bufferList(impl->outputABLStorage, impl->channels);
    for (UInt32 channel = 0; channel < impl->channels; ++channel) {
        outputABL->mBuffers[channel].mNumberChannels = 1;
        outputABL->mBuffers[channel].mData = impl->outputPointers[channel];
        outputABL->mBuffers[channel].mDataByteSize =
            impl->outputCapacity * sizeof(float);
    }

    NSUInteger outputRingCapacity = static_cast<NSUInteger>(
        ceil(outputSampleRate * kOutputBufferSeconds)
    );
    impl->outputRing = [[RealtimeAudioRingBuffer alloc] init];
    if (![impl->outputRing configureWithChannelCount:channelCount
                                      capacityFrames:outputRingCapacity]) {
        return NO;
    }

    auto sourceFormat = planarFloatASBD(sourceSampleRate, impl->channels);
    auto destinationFormat = planarFloatASBD(outputSampleRate, impl->channels);
    OSStatus status = AudioConverterNew(
        &sourceFormat, &destinationFormat, &impl->converter
    );
    if (status != noErr) {
        if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain
            code:status userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"AudioConverterNew failed (%d).", status]}];
        [self teardown];
        return NO;
    }
    return YES;
}

- (void)start {
    auto *impl = static_cast<ConverterImplementation *>(_implementation);
    if (!impl->converter || impl->running.exchange(true)) return;
    impl->worker = std::thread([impl] {
        while (impl->running.load(std::memory_order_acquire)) {
            if (impl->sourceRing.availableFrames < kInputFramesPerChunk ||
                impl->outputRing.freeFrames < impl->outputCapacity) {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
                continue;
            }
            auto *outputABL = reinterpret_cast<AudioBufferList *>(
                impl->outputABLStorage.data()
            );
            for (UInt32 channel = 0; channel < impl->channels; ++channel) {
                outputABL->mBuffers[channel].mDataByteSize =
                    impl->outputCapacity * sizeof(float);
            }
            UInt32 outputFrames = impl->outputCapacity;
            impl->requestedFrames.store(outputFrames, std::memory_order_relaxed);
            OSStatus status = AudioConverterFillComplexBuffer(
                impl->converter, converterInputProc, impl,
                &outputFrames, outputABL, nullptr
            );
            if (status == noErr && outputFrames > 0) {
                if (outputABL->mNumberBuffers != impl->channels) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    continue;
                }
                bool valid = true;
                for (UInt32 channel = 0; channel < impl->channels; ++channel) {
                    auto &buffer = outputABL->mBuffers[channel];
                    if (buffer.mNumberChannels != 1 || !buffer.mData ||
                        buffer.mDataByteSize < outputFrames * sizeof(float)) {
                        valid = false;
                        break;
                    }
                    impl->outputPointers[channel] =
                        static_cast<float *>(buffer.mData);
                }
                if (!valid) {
                    std::this_thread::sleep_for(std::chrono::milliseconds(1));
                    continue;
                }
                float convertedPeak = 0;
                for (UInt32 channel = 0; channel < impl->channels; ++channel) {
                    for (UInt32 frame = 0; frame < outputFrames; ++frame) {
                        convertedPeak = std::max(convertedPeak, static_cast<float>(
                            std::abs(impl->outputPointers[channel][frame])
                        ));
                    }
                }
                updatePeak(impl->convertedPeakBits, convertedPeak);
                impl->producedFrames.store(outputFrames, std::memory_order_relaxed);
                [impl->outputRing writeChannels:impl->outputPointers.data()
                                      channelCount:impl->channels
                                        frameCount:outputFrames];
            } else {
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        }
    });
}

- (void)stop {
    auto *impl = static_cast<ConverterImplementation *>(_implementation);
    impl->running.store(false, std::memory_order_release);
    if (impl->worker.joinable()) impl->worker.join();
}

- (void)teardown {
    [self stop];
    auto *impl = static_cast<ConverterImplementation *>(_implementation);
    if (impl->converter) AudioConverterDispose(impl->converter);
    impl->converter = nullptr;
    impl->sourceRing = nil;
    impl->outputRing = nil;
    impl->sourceRate = 0;
    impl->outputRate = 0;
}

- (RealtimeAudioRingBuffer *)outputRingBuffer {
    return static_cast<ConverterImplementation *>(_implementation)->outputRing;
}
- (double)sourceSampleRate {
    return static_cast<ConverterImplementation *>(_implementation)->sourceRate;
}
- (double)outputSampleRate {
    return static_cast<ConverterImplementation *>(_implementation)->outputRate;
}
- (float)sourcePeak {
    uint32_t bits = static_cast<ConverterImplementation *>(_implementation)
        ->sourcePeakBits.load(std::memory_order_relaxed);
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}
- (float)convertedPeak {
    uint32_t bits = static_cast<ConverterImplementation *>(_implementation)
        ->convertedPeakBits.load(std::memory_order_relaxed);
    float value;
    memcpy(&value, &bits, sizeof(value));
    return value;
}
- (NSUInteger)converterProducedFrames {
    return static_cast<ConverterImplementation *>(_implementation)
        ->producedFrames.load(std::memory_order_relaxed);
}
- (NSUInteger)converterRequestedFrames {
    return static_cast<ConverterImplementation *>(_implementation)
        ->requestedFrames.load(std::memory_order_relaxed);
}

- (void)dealloc {
    [self teardown];
    delete static_cast<ConverterImplementation *>(_implementation);
}

@end
