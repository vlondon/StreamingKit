//
//  STKQueueMixer.m
//
//  Created by James Gordon on 04/12/2014.
//
//

#import "NSMutableArray+STKAudioPlayer.h"
#import "STKAudioPlayer.h"
#import "STKDataSource.h"
#import "STKMixableQueueEntry.h"
#import "STKQueueMixer.h"


typedef enum
{
    BUS_0 = 0,
    BUS_1 = 1,
    FADE_FROM_0,
    FADE_FROM_1
} BUS_STATE;


@interface STKQueueMixer() {
    
    AUGraph _audioGraph;
    
    AUNode _mixerNode;
    AUNode _outputNode;
    
    AudioComponentInstance _mixerUnit;
    AudioComponentInstance _outputUnit;
    
    AudioComponentDescription _mixerDescription;
    AudioComponentDescription _outputDescription;
    
    AudioStreamBasicDescription _outputStreamDescription;
    
    NSMutableArray *_mixQueue;
    STKMixableQueueEntry *_mixBus0;
    STKMixableQueueEntry *_mixBus1;
    
    BUS_STATE _busState;
}

@end

// To handle sleep screen playback, we need to set all non-I/O audio units to this size.
const UInt32 k_maxFramesPerSlice = 4096;
const UInt32 k_busCount = 2;
const UInt32 k_bytesPerSample = 2;
const Float64 k_graphSampleRate = 44100.0;
const UInt64 k_framesRequiredToPlay = k_graphSampleRate * 5;
const int k_maxLoadingEntries = 5;


@implementation STKQueueMixer

- (instancetype)init
{
    self = super.init;
    if (nil != self)
    {
        _mixQueue = [[NSMutableArray alloc] init];
        _busState = BUS_0;
        
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
        
        [self buildAudioGraph];
    }
    
    return self;
}


- (void)queueURL:(NSURL *)url withID:(NSString *)trackID duration:(int)duration fadeAt:(float)time
{
//    NSLog(@"Queue URL: %@ ", url);
    
    STKDataSource *source = [STKAudioPlayer dataSourceFromURL:url];
    STKMixableQueueEntry *mixableEntry = [[STKMixableQueueEntry alloc] initWithDataSource:source andQueueItemId:trackID];
    [mixableEntry setFadeoutAt:time withTotalDuration:duration];
    
    // TODO: Note that by starting load of every queued item as it's added, we're going to use a lot of memory
    // however, we need to cache a certain amount to ensure we're ready if user skips a track. For now though.
    // I'm just going on a memory gorge to get the whole mixing stuff working.
    // Might also be a good idea to have an internal "filler" sound to play if the next track hasn't buffered enough yet
    // We're also going to need to ensure we safely stop entry thread and free resources if entry is skipped.
    [mixableEntry beginEntryLoad];
    [_mixQueue enqueue:mixableEntry];
    
    [self updateQueue];
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
 
 */
- (void)buildAudioGraph
{
   
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
    
    AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, &k_busCount, sizeof(k_busCount));
    AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &k_maxFramesPerSlice, sizeof(k_maxFramesPerSlice));
    AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_SampleRate, kAudioUnitScope_Output, 0, &k_graphSampleRate, sizeof(k_graphSampleRate));
    AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &_outputStreamDescription, sizeof(_outputStreamDescription));
    AudioUnitSetProperty(_mixerUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &_outputStreamDescription, sizeof(_outputStreamDescription));
    
    // Hook up render callback - will need to do for both bus inputs when we're mixing
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = OutputRenderCallback;
    callbackStruct.inputProcRefCon = (__bridge void*)self;
    
    AUGraphSetNodeInputCallback(_audioGraph, _mixerNode, 0, &callbackStruct);
    AUGraphSetNodeInputCallback(_audioGraph, _mixerNode, 1, &callbackStruct);
    
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

static OSStatus OutputRenderCallback(void* inRefCon, AudioUnitRenderActionFlags* ioActionFlags, const AudioTimeStamp* inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList* ioData)
{
    OSStatus error = 0;
    STKQueueMixer *player = (__bridge STKQueueMixer *)inRefCon;
    
    if (inBusNumber != player->_busState && FADE_FROM_0 > player->_busState) {
        return error;
    }
    
    STKMixableQueueEntry *entryForBus = (BUS_0 == inBusNumber) ? player->_mixBus0 : player->_mixBus1;
    if (nil == entryForBus)
    {
        return error;
    }
    
    // Use array of entries and then use the bus number to index the correct entry
    UInt32 bytesPerFrame = entryForBus->audioStreamBasicDescription.mBytesPerFrame;
    
    ioData->mBuffers[0].mNumberChannels = entryForBus->audioStreamBasicDescription.mChannelsPerFrame;
    ioData->mBuffers[0].mDataByteSize = inNumberFrames * bytesPerFrame;
    
    float fadeValue = (entryForBus->framesPlayed - entryForBus->_fadeFrom) * entryForBus->_fadeRatio;
    float volume;
    if (BUS_0 == inBusNumber)
    {
        if (BUS_0 == player->_busState || FADE_FROM_0 == player->_busState) {
            volume = MIN(1 - fadeValue, 1);
        } else {
            volume = MIN(1, fadeValue);
        }
    }
    else
    {
        if (BUS_1 == player->_busState || FADE_FROM_1 == player->_busState) {
            volume = MIN(1 - fadeValue, 1);
        } else {
            volume = MIN(1, fadeValue);
        }
    }
    
    if (1 > volume && inBusNumber == player->_busState)
    {
        player->_busState = (player->_busState == BUS_0) ? FADE_FROM_0 : FADE_FROM_1;
    }
    
    error = AudioUnitSetParameter (player->_mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, inBusNumber, volume, 0);
    
    if (entryForBus->framesQueued > k_framesRequiredToPlay)
    {
        memcpy(ioData->mBuffers[0].mData, entryForBus->_pcmAudioBuffer->mData, ioData->mBuffers[0].mDataByteSize);
        entryForBus->framesPlayed += MIN(inNumberFrames, entryForBus->_pcmBufferUsedFrameCount);  // TODO: Need to fill remainder of buffer with 0.
        
        // TODO: This is VERY CPU intensive, using 25% CPU per thread, as opposed to the 1-2% used by the method seen in STKAudioPlayer's output render callback.
        memmove(entryForBus->_pcmAudioBuffer->mData, entryForBus->_pcmAudioBuffer->mData + (inNumberFrames * bytesPerFrame), entryForBus->_pcmAudioBuffer->mDataByteSize - (inNumberFrames * bytesPerFrame));
        
        if (entryForBus->_pcmBufferFrameStartIndex > inNumberFrames) {
            entryForBus->_pcmBufferFrameStartIndex -= inNumberFrames;
        }
        
        if (entryForBus->_pcmBufferUsedFrameCount > inNumberFrames) {
            entryForBus->_pcmBufferUsedFrameCount -= inNumberFrames;
        }
        
        [entryForBus continueBuffering];
    }
    else
    {
        memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
    }
    
    if (entryForBus->framesPlayed == entryForBus->lastFrameQueued)
    {
        [player trackEntry:entryForBus finishedPlayingOnBus:inBusNumber];
    }
    
    return error;
}


- (void)trackEntry:(STKMixableQueueEntry *)entry finishedPlayingOnBus:(int)busNumber
{
    // Ensure bus is set to 0 volume
    AudioUnitSetParameter (_mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, busNumber, 0, 0);
    
    [entry tidyUp];
    [_mixQueue removeObject:entry];
    
    if (0 == busNumber)
    {
        _busState = BUS_1;
        _mixBus0 = nil;
    }
    else
    {
        _busState = BUS_0;
        _mixBus1 = nil;
    }
    
    [self updateQueue];
}


- (void)updateQueue
{
    if (nil != _mixBus0 && nil != _mixBus1) {
        // Bith tracks currently full, so no need to do anything
        return;
    }
    
    STKMixableQueueEntry *nextUp = _mixQueue.dequeue;
    if (nil == nextUp) {
        return;
    }
    
    // Should already be loading, but it is possible to reach a track before it has started loading.
    [nextUp beginEntryLoad];
    
    // The first invocation of this function should assign the entry to bus 0.
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _mixBus0 = nextUp;
        return;
    });
    
    if (BUS_0 == _busState)
    {
        _mixBus1 = nextUp;
    }
    else
    {
        _mixBus0 = nextUp;
    }
    
    int queueSize = (int)_mixQueue.count;
    for (int entryIndex = queueSize; entryIndex > MAX((queueSize - k_maxLoadingEntries), 0); --entryIndex)
    {
        [_mixQueue[entryIndex] beginEntryLoad];
    }
}


#pragma mark Tidy up

- (void)dealloc
{
    if (_audioGraph)
    {
        AUGraphStop(_audioGraph);
        AUGraphClose(_audioGraph);
    }
    
    // TODO: Ensure all queued entries are stopped and killed
}

@end
