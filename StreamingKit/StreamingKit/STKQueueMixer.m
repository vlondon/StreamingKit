//
//  STKQueueMixer.m
//
//  Created by James Gordon on 04/12/2014.
//
//

#import <pthread/pthread.h>
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
    
    BOOL _startingPlay;
    BUS_STATE _busState;
    
    pthread_mutex_t _playerMutex;
}

@end

// To handle sleep screen playback, we need to set all non-I/O audio units to this size.
const UInt32 k_maxFramesPerSlice = 4096;
const UInt32 k_busCount = 2;
const UInt32 k_bytesPerSample = 2;
const Float64 k_graphSampleRate = 44100.0;
const Float64 k_samplesPerMs = 44.1;
const UInt64 k_framesRequiredToPlay = k_graphSampleRate * 5;
const int k_maxLoadingEntries = 5;


@implementation STKQueueMixer

- (instancetype)init
{
    self = super.init;
    if (nil != self)
    {
        self.volume = 1;
        self.mixerState = STKQueueMixerStateReady;
        
        _mixQueue = [[NSMutableArray alloc] init];
        _startingPlay = YES;
        _busState = BUS_0;
        
        pthread_mutexattr_t attr;
        pthread_mutexattr_init(&attr);
        pthread_mutexattr_settype(&attr, PTHREAD_MUTEX_RECURSIVE);
        pthread_mutex_init(&_playerMutex, &attr);
        
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
        [self startPlayback];
    }
    
    return self;
}


#pragma mark Audio Graph magic

/*
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
        if (BUS_0 == player->_busState || FADE_FROM_0 == player->_busState)
        {
            volume = MAX(MIN(1.0 - fadeValue, 1.0), 0);
            if (0 >= volume) {
                [player trackEntry:entryForBus finishedPlayingOnBus:BUS_0];
            }
        }
        else
        {
            error = AudioUnitGetParameter(player->_mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, BUS_1, &volume);
            volume = MIN(1.0, 1.0 - volume);
        }
    }
    else
    {
        if (BUS_1 == player->_busState || FADE_FROM_1 == player->_busState)
        {
            volume = MAX(MIN(1.0 - fadeValue, 1.0), 0);
            if (0 >= volume) {
                [player trackEntry:entryForBus finishedPlayingOnBus:BUS_1];
            }
        }
        else
        {
            error = AudioUnitGetParameter(player->_mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, BUS_0, &volume);
            volume = MIN(1.0, 1.0 - volume);
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
        
        // TODO: Need to fill remainder of buffer with 0.
        // TODO: When using buffer fill like STKAudioPlayer, use below for setting framesPlayed instead of simply incrementing by inNumberFrames
//        entryForBus->framesPlayed += MIN(inNumberFrames, entryForBus->_pcmBufferUsedFrameCount);
        entryForBus->framesPlayed += inNumberFrames;
        
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


/*
 @brief Stop or pause playback. 
 
 @param keepTrack should be set to YES if we are pausing playback. If set to NO, buffer and queue will be cleared.
 
 @return void
 */
- (void)stopPlayback:(BOOL)keepTrack
{
    AUGraphStop(_audioGraph);
    
    if (keepTrack) {
        self.mixerState = STKQueueMixerStatePaused;
    } else {
        self.mixerState = STKQueueMixerStateStopped;
        [self clearQueue];
    }
}

- (void)startPlayback
{
    self.mixerState = STKQueueMixerStatePlaying;
    
    Boolean graphIsRunning;
    AUGraphIsRunning(_audioGraph, &graphIsRunning);
    if (graphIsRunning) {
        return;
    }
    
    AUGraphUninitialize(_audioGraph);
    AUGraphInitialize(_audioGraph);
    
    AUGraphStart(_audioGraph);
}

- (void)setVolume:(float)volume
{
    _volume = volume;
    AudioUnitSetParameter(_mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, _volume, 0);
}


#pragma mark Queue management

/*
 @brief Get the mixer queue, including the now playing and next track
 */
- (NSArray *)mixerQueue
{
    return @[_mixBus0, _mixBus1, _mixQueue];
}


/*
 @brief Queue a URL to be played as soon as possible; place as next up bus entry and put current next up
        entry back to the front of the queue.
 
 @param url to play
 @param trackID to use for identifying entry
 @param duration of the source in ms
 @param fadeAt time before end of file to start fade in ms.
 
 @return void
 */
- (void)playNext:(NSURL *)url withID:(NSString *)trackID duration:(NSInteger)duration fadeAt:(NSInteger)time
{
    STKMixableQueueEntry *pushingEntry = [self entryForURL:url withID:trackID duration:duration fadeAt:time];
    [pushingEntry beginEntryLoad];
    
    STKMixableQueueEntry *bargedEntry;
    if (BUS_0 == _busState || FADE_FROM_0 == _busState)
    {
        // Next up is bus 1, so insert our queue-jumper here and place the currently up next entry to front of queue
        bargedEntry = _mixBus1;
        _mixBus1 = pushingEntry;
    }
    else
    {
        bargedEntry = _mixBus0;
        _mixBus0 = pushingEntry;
    }
    
    if (nil != bargedEntry) {
        pthread_mutex_lock(&_playerMutex);
        [_mixQueue addObject:bargedEntry];
        pthread_mutex_unlock(&_playerMutex);
    }
    
    if (STKQueueMixerStatePlaying != self.mixerState) {
        [self startPlayback];
    }
}


/*
 @brief Queue source to back of queue
 
 @param url to play
 @param trackID to use for identifying entry
 @param duration of the source in ms
 @param fadeAt time before end of file to start fade in ms.
 
 @return void
 */
- (void)queueURL:(NSURL *)url withID:(NSString *)trackID duration:(NSInteger)duration fadeAt:(NSInteger)time
{
    STKMixableQueueEntry *mixableEntry = [self entryForURL:url withID:trackID duration:duration fadeAt:time];
    [_mixQueue enqueue:mixableEntry];
    
    [self updateQueue];
    
    if (STKQueueMixerStatePlaying != self.mixerState) {
        [self startPlayback];
    }
}


- (STKMixableQueueEntry *)entryForURL:(NSURL *)url withID:(NSString *)trackID duration:(NSInteger)duration fadeAt:(NSInteger)time
{
    STKDataSource *source = [STKAudioPlayer dataSourceFromURL:url];
    STKMixableQueueEntry *mixableEntry = [[STKMixableQueueEntry alloc] initWithDataSource:source andQueueItemId:trackID];
    [mixableEntry setFadeoutAt:(time * k_samplesPerMs) withTotalDuration:(duration * k_samplesPerMs)];
    
    return mixableEntry;
}


- (BOOL)itemIsQueuedOrPlaying:(NSString *)itemID
{
    for (STKMixableQueueEntry *entry in _mixQueue)
    {
        if ([itemID isEqualToString:(NSString *)entry.queueItemId])
        {
            return YES;
        }
    }
    
    if ([itemID isEqualToString:(NSString *)_mixBus0.queueItemId])
    {
        return YES;
    }
    
    if ([itemID isEqualToString:(NSString *)_mixBus1.queueItemId])
    {
        return YES;
    }
    
    return NO;
}


- (void)skipItemWithId:(NSString *)entryID
{
    STKMixableQueueEntry *skippedEntry = [self entryForID:entryID];
    if (nil == skippedEntry)
    {
        return;
    }
    
    // If we're skipping the next up track, we need to do something special...
    STKMixableQueueEntry *nextUp = (BUS_0 == _busState) ? _mixBus1 : _mixBus0;
    if (nextUp == skippedEntry)
    {
        pthread_mutex_lock(&_playerMutex);
        STKMixableQueueEntry *newNextUp = _mixQueue.dequeue;
        pthread_mutex_unlock(&_playerMutex);
        
        if (BUS_0 == _busState || FADE_FROM_0 == _busState) {
            _mixBus1 = newNextUp;
        } else {
            _mixBus0 = newNextUp;
        }
        
        [skippedEntry tidyUp];
        
        return;
    }
    
    // If we're skipping something from the track, we don't need to worry too much...
    STKMixableQueueEntry *nowPlaying = (BUS_0 == _busState) ? _mixBus0 : _mixBus1;
    if (nowPlaying != skippedEntry)
    {
        pthread_mutex_lock(&_playerMutex);
        [_mixQueue removeObject:skippedEntry];
        [skippedEntry tidyUp];
        pthread_mutex_unlock(&_playerMutex);
        
        return;
    }
    
    // ...however, if we're skipping the now playing entry, we need to do something now.
    switch (_busState)
    {
        case BUS_0:
            _busState = FADE_FROM_0;
            [skippedEntry fadeFromNow];
            break;
            
        case BUS_1:
            _busState = FADE_FROM_1;
            [skippedEntry fadeFromNow];
            break;
            
        case FADE_FROM_0:
            [self trackEntry:_mixBus0 finishedPlayingOnBus:BUS_0];
            [skippedEntry fadeFromNow];
            _busState = FADE_FROM_1;
            break;
            
        case FADE_FROM_1:
            [self trackEntry:_mixBus1 finishedPlayingOnBus:BUS_1];
            [skippedEntry fadeFromNow];
            _busState = FADE_FROM_0;
            break;
            
        default:
            NSAssert(NO, @"Unexpected bus state found when skipping queue entry with ID %@.", entryID);
            break;
    }
}


- (STKMixableQueueEntry *)entryForID:(NSString *)entryID
{
    if ([entryID isEqualToString:(NSString *)_mixBus0.queueItemId]) {
        return _mixBus0;
    }

    if ([entryID isEqualToString:(NSString *)_mixBus1.queueItemId]) {
        return _mixBus1;
    }
    
    for (STKMixableQueueEntry *entry in _mixQueue) {
        if ([entryID isEqualToString:(NSString *)entry.queueItemId]) {
            return entry;
        }
    }
    
    return nil;
}


- (void)trackEntry:(STKMixableQueueEntry *)entry finishedPlayingOnBus:(int)busNumber
{
    // Ensure bus is set to 0 volume
    AudioUnitSetParameter (_mixerUnit, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, busNumber, 0, 0);
    
    [_mixQueue removeObject:entry];
    [self.delegate queue:self didFinishPlayingQueueItemId:entry.queueItemId];
    [entry tidyUp];
    
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
    if (nil != _mixBus0 && nil != _mixBus1)
    {
        // Bith tracks currently full, so no need to do anything
        return;
    }
    
    STKMixableQueueEntry *nextUp = _mixQueue.dequeue;
    if (nil == nextUp)
    {
        return;
    }
    
    // Should already be loading, but it is possible to reach a track before it has started loading.
    [nextUp beginEntryLoad];
    
    if (_startingPlay)
    {
        _mixBus0 = nextUp;
        _startingPlay = NO;
        return;
    }
    
    if (BUS_0 == _busState)
    {
        _mixBus1 = nextUp;
    }
    else
    {
        _mixBus0 = nextUp;
    }
    
    int queueSize = (int)_mixQueue.count;
    for (int entryIndex = queueSize - 1; entryIndex > MAX((queueSize - k_maxLoadingEntries), 0); --entryIndex)
    {
        [_mixQueue[entryIndex] beginEntryLoad];
    }
}


#pragma mark Tidy up


- (void)clearQueue
{
    [_mixBus0 tidyUp];
    [_mixBus1 tidyUp];
    
    _mixBus0 = nil;
    _mixBus1 = nil;
    
    pthread_mutex_lock(&_playerMutex);
    
    for (STKMixableQueueEntry *entry in _mixQueue) {
        [entry tidyUp];
    }
    
    [_mixQueue removeAllObjects];
    
    pthread_mutex_unlock(&_playerMutex);
    
    _startingPlay = YES;
    _busState = BUS_0;
    
    self.volume = 1;
}


- (void)dealloc
{
    if (_audioGraph)
    {
        AUGraphStop(_audioGraph);
        AUGraphClose(_audioGraph);
    }
    
    [self clearQueue];
    
    pthread_mutex_destroy(&_playerMutex);
}

@end
