#import <Foundation/Foundation.h>

@class RealtimeAudioRingBuffer;

NS_ASSUME_NONNULL_BEGIN

@interface FixedRateAudioConverter : NSObject

@property(nonatomic, readonly, nullable) RealtimeAudioRingBuffer *outputRingBuffer;
@property(nonatomic, readonly) double sourceSampleRate;
@property(nonatomic, readonly) double outputSampleRate;
@property(nonatomic, readonly) float sourcePeak;
@property(nonatomic, readonly) float convertedPeak;
@property(nonatomic, readonly) NSUInteger converterProducedFrames;
@property(nonatomic, readonly) NSUInteger converterRequestedFrames;

- (BOOL)configureWithSourceRing:(RealtimeAudioRingBuffer *)sourceRing
               sourceSampleRate:(double)sourceSampleRate
                outputSampleRate:(double)outputSampleRate
                    channelCount:(NSUInteger)channelCount
                           error:(NSError * _Nullable * _Nullable)error;
- (void)start;
- (void)stop;
- (void)teardown;

@end

NS_ASSUME_NONNULL_END
