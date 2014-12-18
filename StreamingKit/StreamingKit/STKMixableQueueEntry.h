//
//  STKMixableQueueEntry.h
//  StreamingKit
//
//  Created by James Gordon on 09/12/2014.
//

#import "STKDataSource.h"
#import "STKQueueEntry.h"


@interface STKMixableQueueEntry : STKQueueEntry<STKDataSourceDelegate>
{
@public
    AudioBuffer* _pcmAudioBuffer;
    volatile UInt32 _pcmBufferFrameStartIndex;
    volatile UInt32 _pcmBufferUsedFrameCount;
    
    UInt32 _fadeFrom;
    UInt32 _fadeRatio;
}

- (void)setFadeoutAt:(UInt32)fadeFrame withTotalDuration:(UInt32)frameCount;
- (void)beginEntryLoad;
- (void)continueBuffering;
- (void)wakeupPlaybackThread;
- (void)tidyUp;

@end
