#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface RealtimeAudioRingBuffer : NSObject

@property(nonatomic, readonly) NSUInteger capacityFrames;
@property(nonatomic, readonly) NSUInteger availableFrames;
@property(nonatomic, readonly) NSUInteger freeFrames;
@property(nonatomic, readonly) uint64_t overflowCount;
@property(nonatomic, readonly) uint64_t underflowCount;

- (BOOL)configureWithChannelCount:(NSUInteger)channelCount
                   capacityFrames:(NSUInteger)capacityFrames;

- (BOOL)writeChannels:(float * _Nonnull const * _Nonnull)channels
          channelCount:(NSUInteger)channelCount
            frameCount:(NSUInteger)frameCount;

- (NSUInteger)readChannels:(float * _Nonnull const * _Nonnull)channels
               channelCount:(NSUInteger)channelCount
                 frameCount:(NSUInteger)frameCount;

- (NSUInteger)readLeftChannel:(float * _Nonnull)leftChannel
                  rightChannel:(float * _Nonnull)rightChannel
                    frameCount:(NSUInteger)frameCount;

- (void)reset;

@end

NS_ASSUME_NONNULL_END
