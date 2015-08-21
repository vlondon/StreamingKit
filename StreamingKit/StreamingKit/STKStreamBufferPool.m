//
//  STKStreamBufferPool.m
//  StreamingKit
//

#import "NSMutableArray+STKAudioPlayer.h"
#import "STKStreamBufferPool.h"

@interface STKStreamBufferPool()

@property (nonatomic, readonly) NSMutableArray *poolQueue;

@property (nonatomic) UInt8 currentBufferCount;
@property (nonatomic) UInt8 maxBuffers;
@property (nonatomic) UInt32 bufferSize;

@end


@implementation STKStreamBufferPool

- (instancetype)initWithNumber:(UInt8)ofBuffers withSize:(UInt32)inBytes {
    
    self = [super init];
    if (self) {

        self.currentBufferCount = 0;
        self.maxBuffers = ofBuffers;
        self.bufferSize = inBytes;

        _poolQueue = [[NSMutableArray alloc] initWithCapacity:self.maxBuffers];
    }
    
    return self;
}

- (void *)getFreeBuffer {

    @synchronized(self) {

        void *buffer = ((NSValue *)[self.poolQueue dequeue]).pointerValue;
        if (!buffer && self.currentBufferCount < self.maxBuffers) {

            // No cache, but we are allowed to create a new one.
            buffer = calloc(self.bufferSize, 1);
            ++self.currentBufferCount;
        }

        return buffer;
    }
}

- (void)surrenderBuffer:(void *)buffer {

    @synchronized(self) {

        memset(buffer, 0, self.bufferSize);
        [self.poolQueue enqueue:[NSValue valueWithPointer:buffer]];
    }
}

- (void)flush {

    @synchronized(self) {

        void *buffer = ((NSValue *)[self.poolQueue dequeue]).pointerValue;
        while (buffer) {

            free(buffer);
            --self.currentBufferCount;

            buffer = ((NSValue *)[self.poolQueue dequeue]).pointerValue;
        }
    }
}

- (void)dealloc {

    NSValue *bufferValue = [self.poolQueue dequeue];
    while (bufferValue) {
        void *buffer = bufferValue.pointerValue;
        free(buffer);
    }
}

@end
