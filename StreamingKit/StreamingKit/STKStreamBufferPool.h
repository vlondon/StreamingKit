//
//  STKStreamBufferPool.h
//  StreamingKit
//

#import <Foundation/Foundation.h>

/*
 @class STKStreamBufferPool
 @brief Simple pool of same-size blocks of memory
 
 @description   On creation, we specify the maximum number of memory blocks allowed in the pool as well as the size of
                each block. To get a block of memory, we call getFreeCache. If there is a block available, we return
                a pointer to that memory. If there is no free block, but we've not exceeded the number of allowed blocks
                we will alloc a block now and return to the requester. Finally, if there are no free blocks, we return
                nil. 
                
                When the user has finished with its memory, we can return it to the pool by calling surrenderCache. This
                will zero out the surrendered memory and add the pointer to the pool, ready for future use.
 
                When flush is called, any unused blocks in the pool will be freed and the number of current blocks will
                be updated such that future calls to getFreeCache will re-create a block as required.
 */
@interface STKStreamBufferPool : NSObject

- (instancetype)initWithNumber:(UInt8)ofBuffers withSize:(UInt32)inBytes;

- (void *)getFreeBuffer;
- (void)surrenderBuffer:(void *)buffer;
- (void)flush;

@end
