#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SignalsmithDSPBridge : NSObject

@property(nonatomic) double pitchCents;

- (BOOL)configureWithSampleRate:(double)sampleRate
                   channelCount:(NSUInteger)channelCount;

- (void)reset;

- (BOOL)processInputChannels:(const float * _Nonnull const * _Nonnull)inputChannels
              outputChannels:(float * _Nonnull const * _Nonnull)outputChannels
                channelCount:(NSUInteger)channelCount
                  frameCount:(NSUInteger)frameCount;

@end

NS_ASSUME_NONNULL_END
