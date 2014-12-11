//
//  STKQueueMixer.h
//  Pods
//
//  Created by James Gordon on 04/12/2014.
//
//

#import <Foundation/Foundation.h>
#import "STKMixableQueueEntry.h"

/*
 @class STKQueueMixer
 
 @discussion
 
 */
@interface STKQueueMixer : NSObject<STKMixableQueueEntryDelegate>

- (void)playTrackWithURL:(NSURL *)url;

@end
