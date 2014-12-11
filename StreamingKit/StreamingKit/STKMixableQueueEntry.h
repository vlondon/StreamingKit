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
- (void)sourceDidChangeToFormat:(AudioStreamBasicDescription)asbd;

@end


@interface STKMixableQueueEntry : STKQueueEntry<STKDataSourceDelegate>
{
@public
    AudioBuffer* _pcmAudioBuffer;
}

@property (nonatomic) __weak id<STKMixableQueueEntryDelegate> delegate;

- (void)beginEntryLoadWithRunLoop:(NSRunLoop *)runLoop;
- (void)continueBuffering;

@end
