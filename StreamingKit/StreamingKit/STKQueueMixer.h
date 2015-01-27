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
-(void) queue:(STKQueueMixer *)mixer didStartPlayingQueueItemId:(NSObject *)queueItemId;
-(void) queue:(STKQueueMixer *)mixer didSkipItemWithId:(NSObject *)queueItemId;
-(void) queue:(STKQueueMixer *)mixer didFinishPlayingQueueItemId:(NSObject *)queueItemId;
-(void) queue:(STKQueueMixer *)mixer didChangeToState:(STKQueueMixerState)state from:(STKQueueMixerState)previousState;

@end


/*
 @class STKQueueMixer
 */
@interface STKQueueMixer : NSObject

@property (nonatomic, weak) id<STKQueueMixerDelegate> delegate;
@property (nonatomic) STKQueueMixerState mixerState;
@property (nonatomic) float volume;
@property (nonatomic, readonly) NSArray *mixerQueue;

- (BOOL)itemIsQueuedOrPlaying:(NSString *)itemID;
- (void)playNext:(NSURL *)url withID:(NSString *)trackID trackLength:(NSInteger)totalTime fadeAt:(NSInteger)crossfade fadeTime:(NSInteger)fadeFor;
- (void)queueURL:(NSURL *)url withID:(NSString *)trackID trackLength:(NSInteger)totalTime fadeAt:(NSInteger)crossfade fadeTime:(NSInteger)fadeFor;
- (void)skipItemWithId:(NSString *)entryID;
- (void)stopPlayback:(BOOL)keepTrack;
- (void)startPlayback;

@end
