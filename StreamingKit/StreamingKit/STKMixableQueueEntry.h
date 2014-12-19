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
    
    Float64 _fadeFrom;
    Float64 _fadeRatio;
}

- (void)setFadeoutAt:(Float64)fadeFrame withTotalDuration:(Float64)frameCount;
- (void)beginEntryLoad;
- (void)continueBuffering;
- (void)wakeupPlaybackThread;
- (void)tidyUp;

@end
