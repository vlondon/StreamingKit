//
//  STKQueueMixer.m
//
//  Created by James Gordon on 04/12/2014.
//
//

#import "STKAudioPlayer.h"
#import "STKDataSource.h"
#import "STKQueueMixer.h"


@interface STKQueueMixer() {
    
    AUGraph _audioGraph;
    
    AUNode _mixerNode;
    AUNode _outputNode;
    
    AudioComponentInstance _mixerUnit;
    AudioComponentInstance _outputUnit;
    
    AudioComponentDescription _mixerDescription;
    AudioComponentDescription _outputDescription;
    
    AudioStreamBasicDescription _outputStreamDescription;
    
    // TODO: Will most likely need an array of these and map to the audio stream ids
    STKMixableQueueEntry *_playingEntry;
 
    NSThread *_playbackThread;
    NSRunLoop *_playbackThreadRunLoop;
    
    BOOL _continueRunLoop;
}

@end

// To handle sleep screen playback, we need to set all non-I/O audio units to this size.
const UInt32 k_maxFramesPerSlice = 4096;
const UInt32 k_busCount = 1;
const int k_bytesPerSample = 2;
const Float64 k_graphSampleRate = 44100.0;
const UInt64 k_framesRequiredToPlay = k_graphSampleRate * 5;

@implementation STKQueueMixer

- (instancetype)init {
    self = super.init;
    if (nil != self) {
        
        [self setupStuff];
        [self buildAudioGraph];
        [self startPlaybackThread];
    }
    
    return self;
}


- (void)playTrackWithURL:(NSURL *)url {
    
    // Get URL data source
    // Perform setup here
    // Change call from AVOAudioService to use this instead.
    
    NSLog(@"URL: %@", url);
    
    STKDataSource *source = [STKAudioPlayer dataSourceFromURL:url];    
    _playingEntry = [[STKMixableQueueEntry alloc] initWithDataSource:source andQueueItemId:@"TEST_ID"];
    [_playingEntry beginEntryLoadWithRunLoop:_playbackThreadRunLoop];
}




- (void)setupStuff {
    
    _continueRunLoop = YES;
    
    _outputStreamDescription = (AudioStreamBasicDescription)
    {
        .mSampleRate = 44100.00,
        .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        .mFramesPerPacket = 1,
        .mChannelsPerFrame = 2,
        .mBytesPerFrame = k_bytesPerSample * 2 /*channelsPerFrame*/,
        .mBitsPerChannel = 8 * k_bytesPerSample,
        .mBytesPerPacket = (k_bytesPerSample * 2)
    };
}



#pragma mark Audio Graph magic


/*
 We're going to try the following graph:
 
                            +---------------+                 __
 -- BUS 0 (Now Playing) --> |               |                / //
                            | Mixer Unit    | --- lpcm ---> | ( -
 -- BUS 1 (Next up)     --> |               |                \_\\
                            +---------------+
 
 BUS 1 will be disabled and silenced until we reach the set time in the track to start the merge.
 At this time, BUS1 will be faded in and BUS0 faded out. For mixing the next song in, we'll then
 switch the fade from BUS1 to BUS0.
 
 We're going to have to queue one
 
 */
- (void)buildAudioGraph {
   
    // TODO: Safety checking on creation etc
    NewAUGraph(&_audioGraph);
    AUGraphOpen(_audioGraph);
    
    // Mixer with 2 input busses
    _mixerDescription = (AudioComponentDescription) {
        .componentType = kAudioUnitType_Mixer,
        .componentSubType = kAudioUnitSubType_MultiChannelMixer,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    AUGraphAddNode(_audioGraph, &_mixerDescription, &_mixerNode);
    AUGraphNodeInfo(_audioGraph, _mixerNode, &_mixerDescription, &_mixerUnit);
    
    // TODO: Need to set input stream format for both mixer input buses
    
    AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &k_busCount, sizeof(k_busCount));
    AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &k_maxFramesPerSlice, sizeof(k_maxFramesPerSlice));
    AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_SampleRate, kAudioUnitScope_Output, 0, &k_graphSampleRate, sizeof(k_graphSampleRate));
    AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &_outputStreamDescription, sizeof(_outputStreamDescription));
    
    // Hook up render callback - will need to do for both bus inputs when we're mixing
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = OutputRenderCallback;
    callbackStruct.inputProcRefCon = (__bridge void*)self;
    
    AUGraphSetNodeInputCallback(_audioGraph, _mixerNode, 0, &callbackStruct);
    
    // Output to hardware
    _outputDescription = (AudioComponentDescription) {
        .componentType = kAudioUnitType_Output,
        .componentSubType = kAudioUnitSubType_RemoteIO,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    AUGraphAddNode(_audioGraph, &_outputDescription, &_outputNode);
    AUGraphNodeInfo(_audioGraph, _outputNode, &_outputDescription, &_outputUnit);
    AudioUnitSetProperty(_outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &_outputStreamDescription, sizeof(_outputStreamDescription));
    
    AUGraphConnectNodeInput(_audioGraph, _mixerNode, 0, _outputNode, 0);
    
    AUGraphInitialize(_audioGraph);
    AUGraphStart(_audioGraph);
}

static OSStatus OutputRenderCallback(void* inRefCon, AudioUnitRenderActionFlags* ioActionFlags, const AudioTimeStamp* inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList* ioData) {
    
    OSStatus error = 0;
    STKQueueMixer *player = (__bridge STKQueueMixer *)inRefCon;
    
    // Take bytes from stream for specified bus and push to output.
    // If necessary, adjust mixer volume for cross-fade.
    
    // Use array of entries and then use the bus number to index the correct entry
    
    UInt32 bytesPerFrame = player->_playingEntry->audioStreamBasicDescription.mBytesPerFrame;
//    UInt64 playedFrames = player->_playingEntry->framesPlayed;
    
    ioData->mBuffers[0].mNumberChannels = player->_playingEntry->audioStreamBasicDescription.mChannelsPerFrame;
    ioData->mBuffers[0].mDataByteSize = inNumberFrames * bytesPerFrame;
    
    if (player->_playingEntry->framesQueued > k_framesRequiredToPlay) {
        
        memcpy(ioData->mBuffers[0].mData, player->_playingEntry->_pcmAudioBuffer->mData, ioData->mBuffers[0].mDataByteSize);
        player->_playingEntry->framesPlayed += inNumberFrames;
        
        memmove(player->_playingEntry->_pcmAudioBuffer->mData, player->_playingEntry->_pcmAudioBuffer->mData + (inNumberFrames * bytesPerFrame), player->_playingEntry->_pcmAudioBuffer->mDataByteSize - (inNumberFrames * bytesPerFrame));
        
        if (player->_playingEntry->_pcmBufferFrameStartIndex > inNumberFrames) {
            player->_playingEntry->_pcmBufferFrameStartIndex -= inNumberFrames;
        }
        
        if (player->_playingEntry->_pcmBufferUsedFrameCount > inNumberFrames) {
            player->_playingEntry->_pcmBufferUsedFrameCount -= inNumberFrames;
        }
        
        [player->_playingEntry continueBuffering];
        
    } else {
        memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
    }
    
    return error;
}



#pragma mark Run Loop/Threading management


- (void)startPlaybackThread {
    _playbackThread = [[NSThread alloc] initWithTarget:self selector:@selector(internalThread) object:nil];
    [_playbackThread start];
}

- (void)internalThread
{
    _playbackThreadRunLoop = [NSRunLoop currentRunLoop];
    NSThread.currentThread.threadPriority = 1;
    
    [_playbackThreadRunLoop addPort:[NSPort port] forMode:NSDefaultRunLoopMode];
    
    while (true)
    {
        @autoreleasepool
        {
            if (![self processRunLoop])
            {
                break;
            }
        }
        
        NSDate* date = [[NSDate alloc] initWithTimeIntervalSinceNow:10];
        [_playbackThreadRunLoop runMode:NSDefaultRunLoopMode beforeDate:date];
    }
}


/*
 @brief Management of threaded queue entries and preparation for playback
 
 @return YES if processing should continue, otherwise NO.
 */
- (BOOL)processRunLoop
{
    return _continueRunLoop;
}

-(BOOL) invokeOnPlaybackThread:(void(^)())block
{
    NSRunLoop* runLoop = _playbackThreadRunLoop;
    
    if (runLoop)
    {
        CFRunLoopPerformBlock([runLoop getCFRunLoop], NSRunLoopCommonModes, block);
        CFRunLoopWakeUp([runLoop getCFRunLoop]);
        
        return YES;
    }
    
    return NO;
}

-(void) wakeupPlaybackThread
{
    [self invokeOnPlaybackThread:^ {
        [self processRunLoop];
        [_playingEntry continueBuffering];
    }];
}



#pragma mark playback delegate




#pragma mark Tidy up

- (void)dealloc {
    if (_audioGraph) {
        AUGraphStop(_audioGraph);
        AUGraphClose(_audioGraph);
    }
    
    _continueRunLoop = NO;
}

@end
