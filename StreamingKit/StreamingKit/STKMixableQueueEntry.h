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
- (void)sourceFormatDidChange;

@end


@interface STKMixableQueueEntry : STKQueueEntry<STKDataSourceDelegate>
{
@public
    AudioBuffer* _pcmAudioBuffer;
}


- (void)beginEntryLoadWithRunLoop:(NSRunLoop *)runLoop;
- (void)continueBuffering;

@end
