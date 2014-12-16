//
//  STKMixableQueueEntry.h
//  StreamingKit
//
//  Created by James Gordon on 09/12/2014.
//

#import "STKDataSource.h"
#import "STKQueueEntry.h"

@protocol STKMixableQueueEntryDelegate

- (void)sourceShouldBeginFadeOut;
- (void)trackIsFinsihed;

@end


@interface STKMixableQueueEntry : STKQueueEntry<STKDataSourceDelegate>
{
@public
    AudioBuffer* _pcmAudioBuffer;
    volatile UInt32 _pcmBufferFrameStartIndex;
    volatile UInt32 _pcmBufferUsedFrameCount;
}

@property (nonatomic) __weak id<STKMixableQueueEntryDelegate> delegate;

- (void)beginEntryLoad;
- (void)continueBuffering;
- (void)wakeupPlaybackThread;

@end
