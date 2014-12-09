//
//  STKStreamlinedConverterTest.h
//  Pods
//
//  Created by James Gordon on 04/12/2014.
//
//

#import <Foundation/Foundation.h>
#import "STKDataSource.h"

/*
 @class STKStreamlinedConverterTest
 @brief Testing streamlined audio format conversion
 
 @discussion
 
 Create our stuff
    Specifically - use converter audio unit to convert from aac to linear pcm
 Start loading the data
 When there is enough buffer, start the graph
 Play it!
 
 */
@interface STKStreamlinedConverterTest : NSObject<STKDataSourceDelegate>

- (void)playTrackWithURL:(NSURL *)url;

@end
