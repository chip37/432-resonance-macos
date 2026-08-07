#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SignalsmithDSPBridge : NSObject

- (BOOL)configureWithSampleRate:(double)sampleRate
                   channelCount:(NSUInteger)channelCount;

- (void)reset;

@end

NS_ASSUME_NONNULL_END
