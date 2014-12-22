//
//  STKQueueMixer.h
//  Pods
//
//  Created by James Gordon on 04/12/2014.
//
//

#import <Foundation/Foundation.h>

typedef enum
{
    STKQueueMixerStateReady,
    STKQueueMixerStatePlaying,
    STKQueueMixerStatePaused,
    STKQueueMixerStateStopped,
    STKQueueMixerStateError,
}
STKQueueMixerState;

@class STKQueueMixer;

// Equivalent of STKAudioPlayer's delegate methods
@protocol STKQueueMixerDelegate <NSObject>

/// Raised when an item has started playing
//-(void) queue:(STKQueueMixer *)mixer didStartPlayingQueueItemId:(NSObject *)queueItemId;
-(void) queue:(STKQueueMixer *)mixer didSkipItemWithId:(NSObject *)queueItemId;
-(void) queue:(STKQueueMixer *)mixer didFinishPlayingQueueItemId:(NSObject *)queueItemId;
-(void) queue:(STKQueueMixer *)mixer didChangeToState:(STKQueueMixerState)state from:(STKQueueMixerState)previousState;

@end


/*
 @class STKQueueMixer
 
 @discussion
 
 */
@interface STKQueueMixer : NSObject

@property (nonatomic, weak) id<STKQueueMixerDelegate> delegate;
@property (nonatomic) STKQueueMixerState mixerState;

- (BOOL)itemIsQueuedOrPlaying:(NSString *)itemID;
- (void)queueURL:(NSURL *)url withID:(NSString *)trackID duration:(NSInteger)duration fadeAt:(NSInteger)time;
- (void)skipItemWithId:(NSString *)entryID;

@end
