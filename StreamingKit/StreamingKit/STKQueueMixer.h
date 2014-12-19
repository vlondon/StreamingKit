//
//  STKQueueMixer.h
//  Pods
//
//  Created by James Gordon on 04/12/2014.
//
//

#import <Foundation/Foundation.h>

@class STKQueueMixer;

// Equivalent of STKAudioPlayer's delegate methods
@protocol STKQueueMixerDelegate <NSObject>

/// Raised when an item has started playing
//-(void) queue:(STKQueueMixer *)mixer didStartPlayingQueueItemId:(NSObject *)queueItemId;
/// Raised when an item has finished buffering (may or may not be the currently playing item)
/// This event may be raised multiple times for the same item if seek is invoked on the player
//-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didFinishBufferingSourceWithQueueItemId:(NSObject*)queueItemId;
/// Raised when the state of the player has changed
//-(void) audioPlayer:(STKAudioPlayer*)audioPlayer stateChanged:(STKAudioPlayerState)state previousState:(STKAudioPlayerState)previousState;
/// Raised when an item has finished playing
-(void) queue:(STKQueueMixer *)mixer didFinishPlayingQueueItemId:(NSObject *)queueItemId; //withReason:(STKAudioPlayerStopReason)stopReason andProgress:(double)progress andDuration:(double)duration;
/// Raised when an unexpected and possibly unrecoverable error has occured (usually best to recreate the STKAudioPlauyer)
//-(void) audioPlayer:(STKAudioPlayer*)audioPlayer unexpectedError:(STKAudioPlayerErrorCode)errorCode;
@optional
/// Optionally implemented to get logging information from the STKAudioPlayer (used internally for debugging)
//-(void) audioPlayer:(STKAudioPlayer*)audioPlayer logInfo:(NSString*)line;
/// Raised when items queued items are cleared (usually because of a call to play, setDataSource or stop)
//-(void) audioPlayer:(STKAudioPlayer*)audioPlayer didCancelQueuedItems:(NSArray*)queuedItems;

@end


/*
 @class STKQueueMixer
 
 @discussion
 
 */
@interface STKQueueMixer : NSObject

@property (nonatomic, weak) id<STKQueueMixerDelegate> delegate;

- (void)queueURL:(NSURL *)url withID:(NSString *)trackID duration:(NSInteger)duration fadeAt:(NSInteger)time;
- (BOOL)itemIsQueuedOrPlaying:(NSString *)itemID;

@end
