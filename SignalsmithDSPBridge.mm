#import "SignalsmithDSPBridge.h"

#include "ThirdParty/SignalsmithStretch/signalsmith-stretch.h"

#include <memory>

namespace {

using Stretch = signalsmith::stretch::SignalsmithStretch<float>;

struct SignalsmithDSPBridgeImplementation {
    std::unique_ptr<Stretch> stretch = std::make_unique<Stretch>();
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
    implementation->configured = true;
    return YES;
}

- (void)reset {
    auto *implementation =
        static_cast<SignalsmithDSPBridgeImplementation *>(_implementation);
    if (implementation->configured) {
        implementation->stretch->reset();
    }
}

- (void)dealloc {
    delete static_cast<SignalsmithDSPBridgeImplementation *>(_implementation);
    _implementation = nullptr;
}

@end
