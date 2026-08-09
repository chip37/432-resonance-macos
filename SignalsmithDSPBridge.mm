#import "SignalsmithDSPBridge.h"

#include "ThirdParty/SignalsmithStretch/signalsmith-stretch.h"

#include <memory>

namespace {

using Stretch = signalsmith::stretch::SignalsmithStretch<float>;

struct SignalsmithDSPBridgeImplementation {
    std::unique_ptr<Stretch> stretch = std::make_unique<Stretch>();
    NSUInteger channelCount = 0;
    double pitchCents = 0.0;
    float timeRatio = 1.0F;
    bool configured = false;
};

} // namespace

@interface SignalsmithDSPBridge ()

@property(nonatomic, assign) void *implementation;

@end

@implementation SignalsmithDSPBridge

- (instancetype)init {
    self = [super init];
    if (self) {
        _implementation = new SignalsmithDSPBridgeImplementation();
    }
    return self;
}

- (BOOL)configureWithSampleRate:(double)sampleRate
                   channelCount:(NSUInteger)channelCount {
    if (sampleRate <= 0 || channelCount == 0) {
        return NO;
    }

    auto *implementation =
        static_cast<SignalsmithDSPBridgeImplementation *>(_implementation);
    implementation->stretch->presetDefault(
        static_cast<int>(channelCount),
        static_cast<float>(sampleRate)
    );
    implementation->stretch->setTransposeSemitones(
        static_cast<float>(implementation->pitchCents / 100.0)
    );
    implementation->channelCount = channelCount;
    implementation->timeRatio = 1.0F;
    implementation->configured = true;
    return YES;
}

- (double)pitchCents {
    auto *implementation =
        static_cast<SignalsmithDSPBridgeImplementation *>(_implementation);
    return implementation->pitchCents;
}

- (void)setPitchCents:(double)pitchCents {
    auto *implementation =
        static_cast<SignalsmithDSPBridgeImplementation *>(_implementation);
    implementation->pitchCents = pitchCents;
    if (implementation->configured) {
        implementation->stretch->setTransposeSemitones(
            static_cast<float>(pitchCents / 100.0)
        );
    }
}

- (void)reset {
    auto *implementation =
        static_cast<SignalsmithDSPBridgeImplementation *>(_implementation);
    if (implementation->configured) {
        implementation->stretch->reset();
    }
}

- (BOOL)processInputChannels:(const float * _Nonnull const * _Nonnull)inputChannels
              outputChannels:(float * _Nonnull const * _Nonnull)outputChannels
                channelCount:(NSUInteger)channelCount
                  frameCount:(NSUInteger)frameCount {
    auto *implementation =
        static_cast<SignalsmithDSPBridgeImplementation *>(_implementation);
    if (!implementation->configured ||
        inputChannels == nullptr ||
        outputChannels == nullptr ||
        channelCount != implementation->channelCount) {
        return NO;
    }

    const int outputFrameCount = static_cast<int>(frameCount);
    const int inputFrameCount = static_cast<int>(
        frameCount * implementation->timeRatio
    );
    implementation->stretch->process(
        inputChannels,
        inputFrameCount,
        outputChannels,
        outputFrameCount
    );
    return YES;
}

- (void)dealloc {
    delete static_cast<SignalsmithDSPBridgeImplementation *>(_implementation);
    _implementation = nullptr;
}

@end
