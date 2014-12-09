//
//  STKStreamlinedConverterTest.m
//  Pods
//
//  Created by James Gordon on 04/12/2014.
//
//

#import "STKAudioPlayer.h"
#import "STKDataSource.h"
#import "STKQueueEntry.h"
#import "STKStreamlinedConverterTest.h"


@interface STKStreamlinedConverterTest() {
    
    AUGraph _audioGraph;
    
    AUNode _mixerNode;
    AUNode _converterNode;
    AUNode _outputNode;
    
    AudioComponentInstance _mixerUnit;
    AudioComponentInstance _converterUnit;
    AudioComponentInstance _outputUnit;
    
    AudioComponentDescription _mixerDescription;
    AudioComponentDescription _converterDescription;
    AudioComponentDescription _outputDescription;
    
    AudioStreamBasicDescription _inputStreamDescription;
    AudioStreamBasicDescription _outputStreamDescription;
    
    // TODO: Will most likely need an array of these and map to the audio stream ids
    STKQueueEntry *_playingEntry;
    AudioFileStreamID _playingStream;
    
    BOOL _discontinuousData;
    UInt8 *_readBuffer;
    AudioBufferList _bufferList;
    AudioBuffer *_aacBuffer;
    
//    volatile UInt32 _bufferFrameCount;
    volatile UInt32 _playedFrames;
    volatile UInt32 _bufferedBytes;
}

@end

// To handle sleep screen playback, we need to set all non-I/O audio units to this size.
const UInt32 k_maxFramesPerSlice = 4096;
const UInt32 k_busCount = 1;
const int k_bytesPerSample = 2;
const int k_readBufferSize = 64 * 1024;
//const int k_bufferTime = 10;
const Float64 k_graphSampleRate = 44100.0;


@implementation STKStreamlinedConverterTest

- (instancetype)init {
    self = super.init;
    if (nil != self) {
        [self setupStuff];
        [self buildAudioGraph];
    }
    
    return self;
}


- (void)playTrackWithURL:(NSURL *)url {
    
    // Get URL data source
    // Perform setup here
    // Change call from AVOAudioService to use this instead.
    
    NSLog(@"URL: %@", url);
    
    STKDataSource *source = [STKAudioPlayer dataSourceFromURL:url];
    source.delegate = self;
    
    [source registerForEvents:[NSRunLoop currentRunLoop]];
    [source seekToOffset:0];
    
    _playingEntry = [[STKQueueEntry alloc] initWithDataSource:source andQueueItemId:@"TEST_ID"];
}




- (void)setupStuff {

    _discontinuousData = NO;
//    _bufferFrameCount = 0;
    _playedFrames = 0;
    _bufferedBytes = 0;
    _readBuffer = calloc(sizeof(UInt8), k_readBufferSize);
    _aacBuffer = &_bufferList.mBuffers[0];
    
    // TODO: Need to create input file description based on parsed stream data
    // yeah, we want to handle this property from file parser: kAudioFileStreamProperty_DataFormat
    
    // don't play if we haven't parsed the header
    
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
 
                            +---------------+               +-----------+                 _
 -- BUS 0 (Now Playing) --> |               |               |           |                / / /
                            | Mixer Unit    | ---  aac ---> | Converter | --- lpcm ---> | (  -
 -- BUS 1 (Next up)     --> |               |               |           |                \_\ \
                            +---------------+               +-----------+
 
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
    
    // Hook up render callback - will need to do for both bus inputs when we're mixing
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = OutputRenderCallback;
    callbackStruct.inputProcRefCon = (__bridge void*)self;
    
    AUGraphSetNodeInputCallback(_audioGraph, _mixerNode, 0, &callbackStruct);
    
    
    // Convert aac to lpcm
    _converterDescription = (AudioComponentDescription) {
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentType = kAudioUnitType_FormatConverter,
        .componentSubType = kAudioUnitSubType_AUConverter,
        .componentFlags = 0,
        .componentFlagsMask = 0
    };
    
    AUGraphAddNode(_audioGraph, &_converterDescription, &_converterNode);
    AUGraphNodeInfo(_audioGraph, _converterNode, &_converterDescription, &_converterUnit);
    
    // Will have to set input when it's parsed from stream
    
    AudioUnitSetProperty(_converterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, &_outputStreamDescription, sizeof(_outputStreamDescription));
    
    
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
    
    // TODO: Might need to set output unit's input/output values, though should be enabled and disabled by default.
    
    AudioUnitSetProperty(_outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &_outputStreamDescription, sizeof(_outputStreamDescription));
    
    
    // Connect mixer to converter and then converter to output
    AUGraphConnectNodeInput(_audioGraph, _mixerNode, 0, _converterNode, 0);
    AUGraphConnectNodeInput(_audioGraph, _converterNode, 0, _outputNode, 0);
    
    AUGraphInitialize(_audioGraph);
    AUGraphStart(_audioGraph);
}


static OSStatus OutputRenderCallback(void* inRefCon, AudioUnitRenderActionFlags* ioActionFlags, const AudioTimeStamp* inTimeStamp, UInt32 inBusNumber, UInt32 inNumberFrames, AudioBufferList* ioData) {
    
    OSStatus error = 0;
    STKStreamlinedConverterTest *player = (__bridge STKStreamlinedConverterTest *)inRefCon;
    
    // Take bytes from stream for specified bus and push to output.
    // If necessary, adjust mixer volume for cross-fade.
    
    UInt32 bytesPerFrame = player->_inputStreamDescription.mBytesPerFrame;
    UInt32 playedFrames = player->_playedFrames;
    
    ioData->mBuffers[0].mNumberChannels = player->_inputStreamDescription.mChannelsPerFrame;
//    ioData->mBuffers[0].mDataByteSize = inNumberFrames * bytesPerFrame;
    
    if (player->_bufferedBytes > 23000) {
        
//        memcpy(ioData->mBuffers[0].mData, player->_aacBuffer->mData + (playedFrames * bytesPerFrame), inNumberFrames * bytesPerFrame);
        memcpy(ioData->mBuffers[0].mData, player->_aacBuffer->mData + player->_playedFrames * 23, inNumberFrames);
        
        player->_playedFrames += inNumberFrames;
        
    } else {
        memset(ioData->mBuffers[0].mData, 0, ioData->mBuffers[0].mDataByteSize);
    }
    
    return error;
}


#pragma mark Audio stream parsing

static void AudioFileStreamPropertyListenerProc(void* clientData, AudioFileStreamID audioFileStream, AudioFileStreamPropertyID	propertyId, UInt32* flags)
{
    STKStreamlinedConverterTest *player = (__bridge STKStreamlinedConverterTest *)clientData;
    [player handlePropertyChangeForFileStream:audioFileStream fileStreamPropertyID:propertyId ioFlags:flags];
}

-(void) handlePropertyChangeForFileStream:(AudioFileStreamID)inAudioFileStream fileStreamPropertyID:(AudioFileStreamPropertyID)inPropertyID ioFlags:(UInt32*)ioFlags
{
    OSStatus error;
    
    // Use inAudioFileStream to determine which stream we're reading for. This will be necessary when we support multiple tracks buffering at the same time
    
    
    if (!_playingEntry)
    {
        return;
    }
    
    switch (inPropertyID)
    {
        case kAudioFileStreamProperty_DataOffset:
        {
            SInt64 offset;
            UInt32 offsetSize = sizeof(offset);
            
            AudioFileStreamGetProperty(_playingStream, kAudioFileStreamProperty_DataOffset, &offsetSize, &offset);
            
            UInt32 bitrate;
            UInt32 bitrateSize = sizeof(bitrate);
            
            AudioFileStreamGetProperty(_playingStream, kAudioFileStreamProperty_BitRate, &bitrateSize, &bitrate);
            NSLog(@"BITRATE: %d", (unsigned int)bitrate);
            
            _playingEntry->parsedHeader = YES;
            _playingEntry->audioDataOffset = offset;
            
            break;
        }
        case kAudioFileStreamProperty_FileFormat:
        {
            char fileFormat[4];
            UInt32 fileFormatSize = sizeof(fileFormat);
            
            AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FileFormat, &fileFormatSize, &fileFormat);
            
            break;
        }
        case kAudioFileStreamProperty_DataFormat:
        {
            AudioStreamBasicDescription newBasicDescription;
            STKQueueEntry* entryToUpdate = _playingEntry;
            
            if (!_playingEntry->parsedHeader)
            {
                UInt32 size = sizeof(newBasicDescription);
                AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_DataFormat, &size, &newBasicDescription);
                
//                pthread_mutex_lock(&playerMutex);
                
                if (entryToUpdate->audioStreamBasicDescription.mFormatID == 0)
                {
                    entryToUpdate->audioStreamBasicDescription = newBasicDescription;
                }
                
                entryToUpdate->sampleRate = entryToUpdate->audioStreamBasicDescription.mSampleRate;
                entryToUpdate->packetDuration = entryToUpdate->audioStreamBasicDescription.mFramesPerPacket / entryToUpdate->sampleRate;
                
                UInt32 packetBufferSize = 0;
                UInt32 sizeOfPacketBufferSize = sizeof(packetBufferSize);
                
                error = AudioFileStreamGetProperty(_playingStream, kAudioFileStreamProperty_PacketSizeUpperBound, &sizeOfPacketBufferSize, &packetBufferSize);
                
                if (error || packetBufferSize == 0)
                {
                    error = AudioFileStreamGetProperty(_playingStream, kAudioFileStreamProperty_MaximumPacketSize, &sizeOfPacketBufferSize, &packetBufferSize);
                    
                    if (error || packetBufferSize == 0)
                    {
                        entryToUpdate->packetBufferSize = 2048; //STK_DEFAULT_PACKET_BUFFER_SIZE;
                    }
                    else
                    {
                        entryToUpdate->packetBufferSize = packetBufferSize;
                    }
                }
                else
                {
                    entryToUpdate->packetBufferSize = packetBufferSize;
                }
                
                _aacBuffer->mNumberChannels = newBasicDescription.mChannelsPerFrame;
                
                _inputStreamDescription = newBasicDescription;
                AudioUnitSetProperty(_converterUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &_inputStreamDescription, sizeof(_inputStreamDescription));
                
//                pthread_mutex_unlock(&playerMutex);
            }
            
            break;
        }
        case kAudioFileStreamProperty_AudioDataByteCount:
        {
            UInt64 audioDataByteCount;
            UInt32 byteCountSize = sizeof(audioDataByteCount);
            
            AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_AudioDataByteCount, &byteCountSize, &audioDataByteCount);
            
            _playingEntry->audioDataByteCount = audioDataByteCount;
            
            _aacBuffer->mDataByteSize = (UInt32)_playingEntry->audioDataByteCount;
            _aacBuffer->mData = (void*)calloc((unsigned long)_playingEntry->audioDataByteCount, 1);
            
            // Total size
            //
            
            break;
        }
        case kAudioFileStreamProperty_ReadyToProducePackets:
        {
            _discontinuousData = YES;
            break;
        }
        case kAudioFileStreamProperty_FormatList:
        {
            Boolean outWriteable;
            UInt32 formatListSize;
            OSStatus err = AudioFileStreamGetPropertyInfo(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, &outWriteable);
            
            if (err)
            {
                break;
            }
            
            AudioFormatListItem* formatList = malloc(formatListSize);
            
            err = AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_FormatList, &formatListSize, formatList);
            
            if (err)
            {
                free(formatList);
                break;
            }
            
            for (int i = 0; i * sizeof(AudioFormatListItem) < formatListSize; i += sizeof(AudioFormatListItem))
            {
                AudioStreamBasicDescription pasbd = formatList[i].mASBD;
                
                if (pasbd.mFormatID == kAudioFormatMPEG4AAC_HE || pasbd.mFormatID == kAudioFormatMPEG4AAC_HE_V2)
                {
                    _playingEntry->audioStreamBasicDescription = pasbd;
                    
                    break;
                }
            }
            
            free(formatList);
            
            break;
        }
//        case kAudioFileStreamProperty_MaximumPacketSize:
//        {
//            UInt32 maxSize;
//            UInt32 pss = sizeof(maxSize);
//            AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_MaximumPacketSize, &pss, &maxSize);
//            
//            NSLog(@"MAX SIZE: %d", (unsigned int)maxSize);
//            NSLog(@"FILE SIZE %d", (unsigned int)_playingEntry->audioDataByteCount);
//        }
//        case kAudioFileStreamProperty_AudioDataPacketCount:
//        {
//            UInt32 packetCount;
//            UInt32 pcs = sizeof(packetCount);
//            AudioFileStreamGetProperty(inAudioFileStream, kAudioFileStreamProperty_AudioDataPacketCount, &pcs, &packetCount);
//            
//            NSLog(@"PACKET COUNT: %d", (unsigned int)packetCount);
//        }
//            
//        default: {
//            
//            unsigned int num = (unsigned int)inPropertyID;
//            unsigned char res[4];
//            
//            res[0] = (num>>24) & 0xFF;
//            res[1] = (num>>16) & 0xFF;
//            res[2] = (num>>8) & 0xFF;
//            res[3] = num & 0xFF;
//            
//            NSLog(@"DEFAULT %s", res);
//        }
    }
}


static void AudioFileStreamPacketsProc(void* clientData, UInt32 numberBytes, UInt32 numberPackets, const void* inputData, AudioStreamPacketDescription* packetDescriptions)
{
    STKStreamlinedConverterTest* player = (__bridge STKStreamlinedConverterTest*)clientData;
    [player handleAudioPackets:inputData numberBytes:numberBytes numberPackets:numberPackets packetDescriptions:packetDescriptions];
}


-(void) handleAudioPackets:(const void*)inputData numberBytes:(UInt32)numberBytes numberPackets:(UInt32)numberPackets packetDescriptions:(AudioStreamPacketDescription*)packetDescriptions {
    
    if (!_playingEntry->parsedHeader) {
        return;
    }
    
    // TODO: Safety checks
    
    // Take parsed audio packets and fill our audio buffer with said aac data
    
    memcpy(_aacBuffer->mData + _bufferedBytes, inputData, numberBytes);
    _bufferedBytes += numberBytes;
    
    // Get sample size etc
    
    
    // TODO: Error handling
}


#pragma mark Data Source Delegate

-(void) dataSourceDataAvailable:(STKDataSource*)dataSource {
    
    // Call AudioFileStreamOpen to parse the incoming bytes
    // Read into a buffer via the data source
    // Might need to seek to position
    // If file header specifies discontinuous packets, set that flag
    // Forward those onto AudioFileStreamParseBytes
    
    int bytesRead = [dataSource readIntoBuffer:_readBuffer withSize:k_readBufferSize];
    if (0 == bytesRead) {
        return;
    }
    
    OSStatus error;
    if (!_playingStream) {
        error = AudioFileStreamOpen((__bridge void*)self, AudioFileStreamPropertyListenerProc, AudioFileStreamPacketsProc, dataSource.audioFileTypeHint, &_playingStream);
    }
    
    int flags = 0;
    if (_discontinuousData) {
        flags = kAudioFileStreamParseFlag_Discontinuity;
    }
    
    if (_playingStream) {
        error = AudioFileStreamParseBytes(_playingStream, bytesRead, _readBuffer, flags);
    }
    
    // TODO: Error handling
    
}

-(void) dataSourceErrorOccured:(STKDataSource*)dataSource {
    NSLog(@"I'm probably going to crash; data source error");
}

-(void) dataSourceEof:(STKDataSource*)dataSource {
    NSLog(@"I will probably crash; out of data");
}


- (void)dealloc {
    if (_audioGraph) {
        AUGraphStop(_audioGraph);
        AUGraphClose(_audioGraph);
    }
}

@end
