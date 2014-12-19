//
//  STKQueueMixer.h
//  Pods
//
//  Created by James Gordon on 04/12/2014.
//
//

#import <Foundation/Foundation.h>

/*
 @class STKQueueMixer
 
 @discussion
 
 */
@interface STKQueueMixer : NSObject

- (void)queueURL:(NSURL *)url withID:(NSString *)trackID duration:(int)duration fadeAt:(float)time;
- (BOOL)itemIsQueuedOrPlaying:(NSString *)itemID;

@end
