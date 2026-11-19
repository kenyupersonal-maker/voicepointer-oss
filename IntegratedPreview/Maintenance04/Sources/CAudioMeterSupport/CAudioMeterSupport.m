#import "CAudioMeterSupport.h"
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>
#import <math.h>
#import <stdatomic.h>
#import <string.h>
#import <time.h>
#import <CommonCrypto/CommonDigest.h>
#import <mach/mach_time.h>
#import <unistd.h>

dispatch_queue_t VPCAudioControlQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.kenyu.VoicePointer.audio-control", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(queue, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    });
    return queue;
}

enum { VPCInputRingSlots = 32 };
_Static_assert(__atomic_always_lock_free(sizeof(uint_fast64_t), 0), "The SPSC sequences must be lock-free.");
_Static_assert(ATOMIC_INT_LOCK_FREE == 2 && ATOMIC_BOOL_LOCK_FREE == 2, "The render gate must be lock-free.");
typedef struct {
    UInt32 frames;
    AudioTimeStamp time;
} VPCInputRingSlot;
typedef struct {
    AudioUnit unit;
    atomic_bool enabled;
    atomic_uint inFlight;
    atomic_uint_fast64_t readSequence, writeSequence, callbacks, dropped;
    atomic_uint_fast64_t firstCallbackHost;
    atomic_int renderError;
    UInt32 maximumFrames;
    AudioBufferList scratch;
    float *scratchPCM;
    float *ringPCM;
    VPCInputRingSlot slots[VPCInputRingSlots];
} VPCInputRTState;

// This function is the entire AUHAL real-time path. It has no ObjC references,
// allocations, locks, dispatch, clock queries, conversion, or logging.
static OSStatus VPCInputOnlyRender(void *context, AudioUnitRenderActionFlags *flags,
    const AudioTimeStamp *time, __unused UInt32 bus, UInt32 frames, __unused AudioBufferList *data) {
    VPCInputRTState *state = context;
    atomic_fetch_add_explicit(&state->inFlight, 1, memory_order_acquire);
    if (!atomic_load_explicit(&state->enabled, memory_order_acquire)) {
        atomic_fetch_sub_explicit(&state->inFlight, 1, memory_order_release);
        return noErr;
    }
    if (frames > state->maximumFrames) {
        atomic_store_explicit(&state->renderError, kAudioUnitErr_TooManyFramesToProcess, memory_order_relaxed);
        atomic_fetch_sub_explicit(&state->inFlight, 1, memory_order_release);
        return kAudioUnitErr_TooManyFramesToProcess;
    }
    state->scratch.mBuffers[0].mDataByteSize = frames * sizeof(float);
    OSStatus status = AudioUnitRender(state->unit, flags, time, 1, frames, &state->scratch);
    if (status == noErr && frames) {
        atomic_fetch_add_explicit(&state->callbacks, 1, memory_order_relaxed);
        uint64_t expected = 0;
        if (time->mFlags & kAudioTimeStampHostTimeValid) {
            atomic_compare_exchange_strong_explicit(&state->firstCallbackHost, &expected,
                time->mHostTime, memory_order_relaxed, memory_order_relaxed);
        }
        uint64_t write = atomic_load_explicit(&state->writeSequence, memory_order_relaxed);
        uint64_t read = atomic_load_explicit(&state->readSequence, memory_order_acquire);
        if (write - read < VPCInputRingSlots) {
            UInt32 index = (UInt32)(write % VPCInputRingSlots);
            memcpy(state->ringPCM + (size_t)index * state->maximumFrames,
                state->scratchPCM, (size_t)frames * sizeof(float));
            state->slots[index].frames = frames;
            state->slots[index].time = *time;
            atomic_store_explicit(&state->writeSequence, write + 1, memory_order_release);
        } else {
            atomic_fetch_add_explicit(&state->dropped, 1, memory_order_relaxed);
            atomic_store_explicit(&state->renderError, kAudioUnitErr_TooManyFramesToProcess, memory_order_relaxed);
        }
    }
    if (status != noErr) atomic_store_explicit(&state->renderError, status, memory_order_relaxed);
    atomic_fetch_sub_explicit(&state->inFlight, 1, memory_order_release);
    return status;
}

static NSString *VPCFiniteDeviceClass(NSString *value) {
    for (NSString *allowed in @[@"builtin", @"bluetooth", @"usb", @"aggregate", @"other"]) {
        if ([value isEqual:allowed]) return allowed;
    }
    return @"other";
}

@interface VPCInputOnlyAudioCapture () {
    VPCInputRTState *_rt;
    AudioUnit _unit;
    BOOL _initialized;
    dispatch_queue_t _consumerQueue;
    dispatch_source_t _consumerTimer;
    AudioObjectPropertyListenerBlock _deviceListener;
    AudioObjectPropertyAddress _listenerAddresses[3];
    BOOL _listenerAdded[3];
    AudioStreamID _streamIDs[32];
    BOOL _streamListenerAdded[32][2];
    UInt32 _streamCount;
    uint64_t _startedHost, _firstCallbackHost;
    atomic_uint_fast64_t _firstNonzeroHost;
    atomic_int _renderFailure;
    double _hardwareRate;
    UInt32 _hardwareChannels;
    AudioStreamBasicDescription _hardwareFormat;
}
@property(nonatomic, readwrite, nullable) AVAudioFormat *format;
@property(nonatomic, readwrite) NSString *failureStage;
@property(nonatomic, readwrite) int32_t failureStatus;
@property(nonatomic, readwrite, getter=isRunning) BOOL running;
@property(nonatomic, readwrite) uint32_t resolvedDeviceID;
@property(nonatomic, copy, nullable) VPCAudioInputBufferHandler handler;
- (void)consumeRing;
@end

@implementation VPCInputOnlyAudioCapture
- (instancetype)init {
    self = [super init];
    if (self) {
        _failureStage = @"new";
        atomic_init(&_firstNonzeroHost, 0); atomic_init(&_renderFailure, 0);
        _consumerQueue = dispatch_queue_create("com.kenyu.VoicePointer.audio-consumer", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_consumerQueue, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0));
    }
    return self;
}
- (OSStatus)failed:(OSStatus)status stage:(NSString *)stage {
    self.failureStatus = status; self.failureStage = stage;
    [self stop];
    return status;
}
- (NSString *)failureDiagnostic {
    return [NSString stringWithFormat:@"capture start failed stage=%@ status=%d", self.failureStage, self.failureStatus];
}
- (int32_t)prepareForUID:(NSString *)uid handler:(VPCAudioInputBufferHandler)handler {
    [self stop];
    self.failureStage = @"new"; self.failureStatus = noErr;
    _startedHost = _firstCallbackHost = 0;
    atomic_store_explicit(&_firstNonzeroHost, 0, memory_order_relaxed);
    atomic_store_explicit(&_renderFailure, 0, memory_order_relaxed);
    _hardwareRate = 0; _hardwareChannels = 0;
    if ([NSThread isMainThread]) return [self failed:kAudioUnitErr_CannotDoInCurrentContext stage:@"new"];
    AudioDeviceID device = kAudioObjectUnknown;
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyTranslateUIDToDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    UInt32 size = sizeof(device);
    OSStatus status;
    if (uid.length) {
        CFStringRef selector = (__bridge CFStringRef)uid;
        status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address,
            sizeof(selector), &selector, &size, &device);
    } else {
        address.mSelector = kAudioHardwarePropertyDefaultInputDevice;
        status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device);
    }
    if (status != noErr || device == kAudioObjectUnknown)
        return [self failed:status ?: kAudioUnitErr_InvalidPropertyValue stage:@"setDevice"];
    self.resolvedDeviceID = device;
    AudioComponentDescription description = {kAudioUnitType_Output, kAudioUnitSubType_HALOutput,
        kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (!component) return [self failed:kAudioUnitErr_InvalidProperty stage:@"new"];
    status = AudioComponentInstanceNew(component, &_unit);
    if (status != noErr) return [self failed:status stage:@"new"];
    UInt32 enabled = 1, disabled = 0;
    status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &enabled, sizeof(enabled));
    if (status != noErr) return [self failed:status stage:@"enableIO"];
    status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &disabled, sizeof(disabled));
    if (status != noErr) return [self failed:status stage:@"enableIO"];
    status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, sizeof(device));
    if (status != noErr) return [self failed:status stage:@"setDevice"];
    AudioStreamBasicDescription hardware = {0}; size = sizeof(hardware);
    status = AudioUnitGetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size);
    if (status != noErr) return [self failed:status stage:@"format"];
    _hardwareRate = hardware.mSampleRate; _hardwareChannels = hardware.mChannelsPerFrame;
    _hardwareFormat = hardware;
    if (!isfinite(_hardwareRate) || _hardwareRate <= 0 || _hardwareRate > 768000 ||
        !_hardwareChannels || _hardwareChannels > 32)
        return [self failed:kAudioUnitErr_FormatNotSupported stage:@"format"];
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
        sampleRate:_hardwareRate channels:1 interleaved:NO];
    if (!format) return [self failed:kAudioUnitErr_FormatNotSupported stage:@"format"];
    status = AudioUnitSetProperty(_unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
        format.streamDescription, sizeof(AudioStreamBasicDescription));
    if (status != noErr) return [self failed:status stage:@"format"];
    if (_hardwareChannels > 1) {
        SInt32 channelMap = 0;
        status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output, 1,
            &channelMap, sizeof(channelMap));
        if (status != noErr) return [self failed:status stage:@"format"];
    }
    status = AudioUnitSetProperty(_unit, kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Output, 1, &disabled, sizeof(disabled));
    if (status != noErr) return [self failed:status stage:@"format"];
    UInt32 maximumFrames = 0; size = sizeof(maximumFrames);
    status = AudioUnitGetProperty(_unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFrames, &size);
    if (status != noErr) return [self failed:status stage:@"format"];
    if (!maximumFrames || maximumFrames > 65536)
        return [self failed:kAudioUnitErr_TooManyFramesToProcess stage:@"format"];
    _rt = calloc(1, sizeof(VPCInputRTState));
    if (!_rt) return [self failed:kAudioUnitErr_FailedInitialization stage:@"format"];
    atomic_init(&_rt->enabled, false); atomic_init(&_rt->inFlight, 0);
    atomic_init(&_rt->readSequence, 0); atomic_init(&_rt->writeSequence, 0);
    atomic_init(&_rt->callbacks, 0); atomic_init(&_rt->dropped, 0); atomic_init(&_rt->firstCallbackHost, 0);
    atomic_init(&_rt->renderError, 0);
    _rt->unit = _unit; _rt->maximumFrames = maximumFrames;
    _rt->scratchPCM = calloc(maximumFrames, sizeof(float));
    _rt->ringPCM = calloc((size_t)maximumFrames * VPCInputRingSlots, sizeof(float));
    if (!_rt->scratchPCM || !_rt->ringPCM)
        return [self failed:kAudioUnitErr_FailedInitialization stage:@"format"];
    _rt->scratch.mNumberBuffers = 1;
    _rt->scratch.mBuffers[0] = (AudioBuffer){1, maximumFrames * sizeof(float), _rt->scratchPCM};
    self.format = format; self.handler = handler;
    AURenderCallbackStruct callback = {VPCInputOnlyRender, _rt};
    status = AudioUnitSetProperty(_unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback, sizeof(callback));
    if (status != noErr) return [self failed:status stage:@"format"];
    return noErr;
}
- (int32_t)start {
    if (!_unit || !_rt) return [self failed:kAudioUnitErr_Uninitialized stage:@"start"];
    if (self.running) return noErr;
    OSStatus status = AudioUnitInitialize(_unit);
    if (status != noErr) return [self failed:status stage:@"init"];
    _initialized = YES; _startedHost = mach_absolute_time();
    atomic_store_explicit(&_rt->enabled, true, memory_order_release);
    status = AudioOutputUnitStart(_unit);
    if (status != noErr) return [self failed:status stage:@"start"];
    self.running = YES; self.failureStage = @"start";
    __weak VPCInputOnlyAudioCapture *weakSelf = self;
    _consumerTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _consumerQueue);
    dispatch_source_set_timer(_consumerTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 10000000, 1000000);
    dispatch_source_set_event_handler(_consumerTimer, ^{
        @autoreleasepool { [weakSelf consumeRing]; }
    });
    dispatch_resume(_consumerTimer);
    _deviceListener = ^(__unused UInt32 count, __unused const AudioObjectPropertyAddress *addresses) {
        VPCInputOnlyAudioCapture *strongSelf = weakSelf;
        if (!strongSelf.running || !strongSelf.routeHandler) return;
        AudioStreamBasicDescription current = {0}; UInt32 bytes = sizeof(current);
        OSStatus readStatus = AudioUnitGetProperty(strongSelf->_unit, kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 1, &current, &bytes);
        AudioObjectPropertyAddress aliveAddress = {kAudioDevicePropertyDeviceIsAlive,
            kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        UInt32 alive = 0; bytes = sizeof(alive);
        OSStatus aliveStatus = AudioObjectGetPropertyData(strongSelf.resolvedDeviceID,
            &aliveAddress, 0, NULL, &bytes, &alive);
        if (readStatus != noErr || aliveStatus != noErr || !alive ||
            memcmp(&current, &strongSelf->_hardwareFormat, sizeof(current)) != 0)
            strongSelf.routeHandler(readStatus ?: aliveStatus);
    };
    _listenerAddresses[0] = (AudioObjectPropertyAddress){kAudioDevicePropertyDeviceIsAlive,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    _listenerAddresses[1] = (AudioObjectPropertyAddress){kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    _listenerAddresses[2] = (AudioObjectPropertyAddress){kAudioDevicePropertyStreamFormat,
        kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain};
    for (NSUInteger i = 0; i < 3; i++) {
        _listenerAdded[i] = AudioObjectHasProperty(self.resolvedDeviceID, &_listenerAddresses[i]) &&
            AudioObjectAddPropertyListenerBlock(self.resolvedDeviceID, &_listenerAddresses[i],
                VPCAudioControlQueue(), _deviceListener) == noErr;
    }
    AudioObjectPropertyAddress streams = {kAudioDevicePropertyStreams,
        kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain};
    UInt32 streamBytes = 0;
    if (AudioObjectGetPropertyDataSize(self.resolvedDeviceID, &streams, 0, NULL, &streamBytes) == noErr &&
        streamBytes > 0 && streamBytes <= sizeof(_streamIDs) &&
        AudioObjectGetPropertyData(self.resolvedDeviceID, &streams, 0, NULL, &streamBytes, _streamIDs) == noErr) {
        _streamCount = streamBytes / sizeof(AudioStreamID);
        for (UInt32 stream = 0; stream < _streamCount; stream++) {
            for (UInt32 index = 0; index < 2; index++) {
                AudioObjectPropertyAddress property = {index == 0 ? kAudioStreamPropertyVirtualFormat : kAudioStreamPropertyPhysicalFormat,
                    kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                _streamListenerAdded[stream][index] = AudioObjectHasProperty(_streamIDs[stream], &property) &&
                    AudioObjectAddPropertyListenerBlock(_streamIDs[stream], &property,
                        VPCAudioControlQueue(), _deviceListener) == noErr;
            }
        }
    }
    return noErr;
}
- (void)consumeRing {
    VPCInputRTState *state = _rt;
    if (!state) return;
    int renderError = atomic_exchange_explicit(&state->renderError, 0, memory_order_relaxed);
    if (renderError) {
        atomic_store_explicit(&_renderFailure, renderError, memory_order_relaxed);
        __weak VPCInputOnlyAudioCapture *weakSelf = self;
        dispatch_async(VPCAudioControlQueue(), ^{
            VPCInputOnlyAudioCapture *strongSelf = weakSelf;
            if (strongSelf.running && strongSelf.routeHandler) strongSelf.routeHandler(renderError);
        });
    }
    uint64_t read = atomic_load_explicit(&state->readSequence, memory_order_relaxed);
    uint64_t write = atomic_load_explicit(&state->writeSequence, memory_order_acquire);
    while (read < write) {
        UInt32 index = (UInt32)(read % VPCInputRingSlots);
        VPCInputRingSlot *slot = &state->slots[index];
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:self.format frameCapacity:slot->frames];
        if (buffer) {
            buffer.frameLength = slot->frames;
            float *source = state->ringPCM + (size_t)index * state->maximumFrames;
            memcpy(buffer.floatChannelData[0], source, (size_t)slot->frames * sizeof(float));
            if (!atomic_load_explicit(&_firstNonzeroHost, memory_order_relaxed)) {
                for (UInt32 frame = 0; frame < slot->frames; frame++) {
                    if (isfinite(source[frame]) && source[frame] != 0) {
                        atomic_store_explicit(&_firstNonzeroHost, (slot->time.mFlags & kAudioTimeStampHostTimeValid)
                            ? slot->time.mHostTime : mach_absolute_time(), memory_order_relaxed);
                        break;
                    }
                }
            }
            VPCAudioInputBufferHandler handler = self.handler;
            if (handler) handler(buffer, [AVAudioTime timeWithAudioTimeStamp:&slot->time sampleRate:_hardwareRate]);
        } else {
            atomic_store_explicit(&_renderFailure, kAudioUnitErr_FailedInitialization, memory_order_relaxed);
            __weak VPCInputOnlyAudioCapture *weakSelf = self;
            dispatch_async(VPCAudioControlQueue(), ^{
                VPCInputOnlyAudioCapture *strongSelf = weakSelf;
                if (strongSelf.running && strongSelf.routeHandler)
                    strongSelf.routeHandler(kAudioUnitErr_FailedInitialization);
            });
        }
        atomic_store_explicit(&state->readSequence, ++read, memory_order_release);
        write = atomic_load_explicit(&state->writeSequence, memory_order_acquire);
    }
}
- (void)stop { [self stopAndFinish:nil]; }
- (void)stopAndFinish:(void (^)(void))finish {
    if (!_unit && !_rt) { if (finish) finish(); return; }
    self.running = NO;
    if (_deviceListener) {
        for (UInt32 stream = 0; stream < _streamCount; stream++) {
            for (UInt32 index = 0; index < 2; index++) {
                if (_streamListenerAdded[stream][index]) {
                    AudioObjectPropertyAddress property = {index == 0 ? kAudioStreamPropertyVirtualFormat : kAudioStreamPropertyPhysicalFormat,
                        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
                    (void)AudioObjectRemovePropertyListenerBlock(_streamIDs[stream], &property,
                        VPCAudioControlQueue(), _deviceListener);
                    _streamListenerAdded[stream][index] = NO;
                }
            }
        }
        _streamCount = 0;
        for (NSUInteger i = 0; i < 3; i++) {
            if (_listenerAdded[i]) {
                (void)AudioObjectRemovePropertyListenerBlock(self.resolvedDeviceID, &_listenerAddresses[i],
                    VPCAudioControlQueue(), _deviceListener);
                _listenerAdded[i] = NO;
            }
        }
        _deviceListener = nil;
    }
    VPCInputRTState *retiredState = _rt;
    if (retiredState) atomic_store_explicit(&retiredState->enabled, false, memory_order_release);
    if (_unit) (void)AudioOutputUnitStop(_unit);
    // Stop is never called by the producer or consumer. The C callback retains
    // its state through Stop, and an already-entered callback is joined here.
    if (retiredState) {
        while (atomic_load_explicit(&retiredState->inFlight, memory_order_acquire)) usleep(100);
    }
    if (_consumerTimer) { dispatch_source_cancel(_consumerTimer); _consumerTimer = nil; }
    dispatch_sync(_consumerQueue, ^{
        [self consumeRing];
        if (retiredState) self->_firstCallbackHost = atomic_load_explicit(&retiredState->firstCallbackHost, memory_order_relaxed);
        // All current consumers have joined this barrier. A timer handler
        // queued after cancellation sees NULL on its own serial queue.
        self->_rt = NULL;
    });
    if (finish) finish(); // Seal only after the last ring slot was delivered.
    if (_initialized && _unit) (void)AudioUnitUninitialize(_unit);
    if (_unit) (void)AudioComponentInstanceDispose(_unit);
    _unit = NULL; _initialized = NO;
    if (retiredState) {
        // Storage also outlives Uninitialize/Dispose. Join any disabled callback
        // that entered while the unit was being torn down before freeing it.
        while (atomic_load_explicit(&retiredState->inFlight, memory_order_acquire)) usleep(100);
    }
    if (retiredState) { free(retiredState->scratchPCM); free(retiredState->ringPCM); free(retiredState); }
    self.handler = nil; self.routeHandler = nil;
}
- (NSString *)openDiagnosticForDeviceClass:(NSString *)deviceClass defaultClass:(NSString *)defaultClass {
    uint64_t callback = _rt ? atomic_load_explicit(&_rt->firstCallbackHost, memory_order_relaxed) : _firstCallbackHost;
    int64_t callbackMs = callback && _startedHost && callback >= _startedHost
        ? (int64_t)([AVAudioTime secondsForHostTime:callback - _startedHost] * 1000) : -1;
    uint64_t nonzero = atomic_load_explicit(&_firstNonzeroHost, memory_order_relaxed);
    int64_t nonzeroMs = nonzero && _startedHost && nonzero >= _startedHost
        ? (int64_t)([AVAudioTime secondsForHostTime:nonzero - _startedHost] * 1000) : -1;
    int renderStatus = atomic_load_explicit(&_renderFailure, memory_order_relaxed);
    return [NSString stringWithFormat:@"capture open backend=auhal device=%@ default=%@ stage=%@ status=%d hwRate=%.0f ch=%u firstCallbackMs=%lld firstNonzeroMs=%lld",
        VPCFiniteDeviceClass(deviceClass), VPCFiniteDeviceClass(defaultClass), self.failureStage, self.failureStatus ?: renderStatus,
        isfinite(_hardwareRate) ? _hardwareRate : 0, _hardwareChannels, (long long)callbackMs, (long long)nonzeroMs];
}
- (void)dealloc { [self stop]; }
@end

NSString *VPCAudioInputDiagnosticFields(void) {
    if ([NSThread isMainThread]) return @"deviceClass=unknown deviceID=0 hardwareRate=0 muted=unknown";
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &device) != noErr ||
        device == kAudioObjectUnknown) return @"deviceClass=unknown deviceID=0 hardwareRate=0 muted=unknown";

    return VPCAudioInputDiagnosticFieldsForDevice(device);
}

NSString *VPCAudioInputDiagnosticFieldsForDevice(uint32_t device) {
    if (!device || [NSThread isMainThread]) return @"deviceClass=unknown deviceID=0 hardwareRate=0 muted=unknown";
    AudioObjectPropertyAddress address;
    UInt32 size;
    UInt32 transport = 0;
    address = (AudioObjectPropertyAddress){kAudioDevicePropertyTransportType, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    size = sizeof(transport);
    (void)AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &transport);
    NSString *deviceClass = @"other";
    switch (transport) {
        case kAudioDeviceTransportTypeBuiltIn: deviceClass = @"builtin"; break;
        case kAudioDeviceTransportTypeBluetooth:
        case kAudioDeviceTransportTypeBluetoothLE: deviceClass = @"bluetooth"; break;
        case kAudioDeviceTransportTypeUSB: deviceClass = @"usb"; break;
        case kAudioDeviceTransportTypeAggregate: deviceClass = @"aggregate"; break;
        case kAudioDeviceTransportTypeContinuityCaptureWired:
        case kAudioDeviceTransportTypeContinuityCaptureWireless: deviceClass = @"continuity"; break;
    }
    CFStringRef uid = NULL;
    address.mSelector = kAudioDevicePropertyDeviceUID;
    size = sizeof(uid);
    (void)AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &uid);
    NSString *deviceID = @"0";
    if (uid) {
        const char *bytes = [(__bridge NSString *)uid UTF8String];
        if (bytes && strlen(bytes) <= UINT32_MAX) {
            unsigned char digest[CC_SHA256_DIGEST_LENGTH];
            CC_SHA256(bytes, (CC_LONG)strlen(bytes), digest);
            deviceID = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x", digest[0], digest[1], digest[2], digest[3], digest[4], digest[5]];
        }
        CFRelease(uid);
    }
    address.mSelector = kAudioDevicePropertyNominalSampleRate;
    Float64 hardwareRate = 0;
    size = sizeof(hardwareRate);
    (void)AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &hardwareRate);
    address = (AudioObjectPropertyAddress){kAudioDevicePropertyMute, kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain};
    UInt32 muted = 0;
    size = sizeof(muted);
    BOOL hasMute = AudioObjectHasProperty(device, &address) &&
        AudioObjectGetPropertyData(device, &address, 0, NULL, &size, &muted) == noErr;
    if (!isfinite(hardwareRate) || hardwareRate < 0 || hardwareRate > 768000) hardwareRate = 0;
    return [NSString stringWithFormat:@"deviceClass=%@ deviceID=%@ hardwareRate=%.0f muted=%@",
        deviceClass, deviceID, hardwareRate, hasMute ? (muted ? @"true" : @"false") : @"unknown"];
}

/// Handle the PCM formats reported by the tap instead of treating a missing
/// floatChannelData pointer as silence.
static float VPCLevelForPCMBuffer(AVAudioPCMBuffer *buffer, float *rawPeak, BOOL *unsupported) {
    *rawPeak = 0;
    *unsupported = NO;
    NSUInteger frames = buffer.frameLength, channels = buffer.format.channelCount;
    if (frames == 0 || channels == 0) return 0;
    BOOL interleaved = buffer.format.interleaved;
    double sum = 0;
    NSUInteger valid = 0;
    for (NSUInteger channel = 0; channel < channels; channel++) {
        for (NSUInteger frame = 0; frame < frames; frame++) {
            NSUInteger index = interleaved ? frame * channels + channel : frame;
            double sample;
            switch (buffer.format.commonFormat) {
            case AVAudioPCMFormatFloat64: {
                AudioBufferList *list = buffer.mutableAudioBufferList;
                NSUInteger plane = interleaved ? 0 : channel;
                if (!list || plane >= list->mNumberBuffers || !list->mBuffers[plane].mData) { *unsupported = YES; return 0; }
                sample = ((double *)list->mBuffers[plane].mData)[index];
                break;
            }
            case AVAudioPCMFormatFloat32: {
                float *const *data = buffer.floatChannelData;
                if (!data) { *unsupported = YES; return 0; }
                sample = data[interleaved ? 0 : channel][index];
                break;
            }
            case AVAudioPCMFormatInt16: {
                int16_t *const *data = buffer.int16ChannelData;
                if (!data) { *unsupported = YES; return 0; }
                sample = (double)data[interleaved ? 0 : channel][index] / 32768.0;
                break;
            }
            case AVAudioPCMFormatInt32: {
                int32_t *const *data = buffer.int32ChannelData;
                if (!data) { *unsupported = YES; return 0; }
                sample = (double)data[interleaved ? 0 : channel][index] / 2147483648.0;
                break;
            }
            default:
                *unsupported = YES;
                return 0;
            }
            if (!isfinite(sample)) continue;
            float magnitude = (float)fabs(sample);
            sum += sample * sample;
            *rawPeak = fmaxf(*rawPeak, magnitude);
            valid++;
        }
    }
    if (valid == 0) return 0;
    float rms = sqrtf((float)(sum / (double)valid));
    return fminf(fmaxf(fmaxf(rms * 2.8f, *rawPeak * .72f), 0), 1);
}

// Offline fault injection traverses the same lifecycle as the real backend.
static void VPCDispatchMeterPCM(AVAudioPCMBuffer *buffer, float rawPeak, BOOL unsupported,
                               VPCAudioPCMEnabled enabled, VPCAudioPCMHandler handler) {
    if (!unsupported && enabled && handler && enabled()) handler(buffer, rawPeak);
}

BOOL VPCAudioMeterRunPCMOutletProbe(void) {
    AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
        sampleRate:16000 channels:1 interleaved:NO];
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:32];
    if (!buffer) return NO;
    buffer.frameLength = 32;
    for (NSUInteger i = 0; i < 32; i++) buffer.floatChannelData[0][i] = .25f;
    __block NSUInteger calls = 0;
    __block BOOL same = NO;
    VPCAudioPCMHandler handler = ^(AVAudioPCMBuffer *borrowed, float peak) {
        calls++; same = borrowed == buffer && fabsf(peak - .25f) < .0001f;
    };
    VPCDispatchMeterPCM(buffer, .25f, NO, ^BOOL { return NO; }, handler);
    if (calls != 0) return NO;
    VPCDispatchMeterPCM(buffer, .25f, YES, ^BOOL { return YES; }, handler);
    if (calls != 0) return NO;
    VPCDispatchMeterPCM(buffer, .25f, NO, ^BOOL { return YES; }, handler);
    return calls == 1 && same;
}

// An NSException must never unwind across a Swift frame.
@protocol VPCAudioBackend <NSObject>
- (BOOL)prepare:(VPCAudioLevelHandler)handler failureHandler:(VPCAudioFailureHandler)failureHandler
    pcmEnabled:(VPCAudioPCMEnabled)pcmEnabled pcmHandler:(VPCAudioPCMHandler)pcmHandler diagnostic:(NSString **)diagnostic;
- (BOOL)start:(NSError **)error;
- (void)detachObserver;
- (void)removeTap;
- (void)stop;
- (NSString *)diagnosticSnapshot;
@end

@interface VPCSystemAudioBackend : NSObject <VPCAudioBackend>
@property(nonatomic, strong) AVAudioEngine *engine;
@property(nonatomic, strong) id observer;
@property(nonatomic) BOOL tapMayBeInstalled;
@property(nonatomic, copy) NSString *deviceFields;
@property(nonatomic) double configuredRate;
@property(nonatomic) uint32_t inputDeviceID;
@property(nonatomic) uint32_t configuredDevice;
@property(nonatomic) BOOL followsDefault;
@property(nonatomic) uint32_t systemDefaultInputID;
@property(nonatomic) double nominalSampleRate;
@property(nonatomic, copy) NSString *inputDiagnosticFields;
@property(nonatomic, copy) NSString *inputDeviceUID;
@property(nonatomic, copy) NSString *inputDeviceClass;
@property(nonatomic, copy) NSString *defaultDeviceClass;
@property(nonatomic) BOOL useEngineBackend;
@property(nonatomic, copy) NSString *openStage;
@property(nonatomic) int32_t openStatus;
@property(nonatomic, strong) VPCInputOnlyAudioCapture *inputOnlyCapture;
@property(nonatomic, strong) AVAudioFormat *configuredFormat;
@property(nonatomic, strong) dispatch_queue_t routeQueue;
@property(atomic) BOOL captureDesired;
- (void)resetDiagnostics;
@end

@implementation VPCSystemAudioBackend {
    atomic_uint_fast64_t _tapCallbacks;
    atomic_uint_fast64_t _unsupportedBuffers;
    atomic_uint_fast64_t _nonzeroBuffers;
    atomic_uint_least32_t _maxRawPeakBits;
    atomic_int _tapCommonFormat;
    atomic_uint_fast64_t _minimumFrames;
    atomic_uint_fast64_t _maximumFrames;
    atomic_uint_fast64_t _firstNonzeroNs;
    atomic_uint_fast64_t _firstCallbackNs;
    atomic_uint_fast64_t _startedAtNs;
    atomic_uint_fast64_t _tapSampleRate;
    atomic_uint _tapChannels;
}
- (instancetype)init {
    self = [super init];
    if (self) {
        [self resetDiagnostics];
        self.routeQueue = VPCAudioControlQueue();
    }
    return self;
}
- (void)resetDiagnostics {
    atomic_init(&_tapCallbacks, 0);
    atomic_init(&_unsupportedBuffers, 0);
    atomic_init(&_nonzeroBuffers, 0);
    atomic_init(&_maxRawPeakBits, 0);
    atomic_init(&_tapCommonFormat, -1);
    atomic_init(&_minimumFrames, UINT64_MAX);
    atomic_init(&_maximumFrames, 0);
    atomic_init(&_firstNonzeroNs, 0);
    atomic_init(&_firstCallbackNs, 0);
    atomic_init(&_startedAtNs, 0);
    atomic_init(&_tapSampleRate, 0);
    atomic_init(&_tapChannels, 0);
}
- (BOOL)prepare:(VPCAudioLevelHandler)handler failureHandler:(VPCAudioFailureHandler)failureHandler
    pcmEnabled:(VPCAudioPCMEnabled)pcmEnabled pcmHandler:(VPCAudioPCMHandler)pcmHandler diagnostic:(NSString **)diagnostic {
    [self resetDiagnostics];
    self.openStage = @"format"; self.openStatus = 0;
    AVAudioInputNode *input = nil;
    AVAudioFormat *format = nil;
    AudioDeviceID chosen = self.inputDeviceID ?: self.systemDefaultInputID;
    self.followsDefault = !chosen || chosen == self.systemDefaultInputID;
    VPCAudioInputBufferHandler pcmCallback = ^(AVAudioPCMBuffer *buffer, AVAudioTime *time) {
        (void)time;
        atomic_fetch_add_explicit(&_tapCallbacks, 1, memory_order_relaxed);
        uint64_t firstExpected = 0;
        atomic_compare_exchange_strong_explicit(&_firstCallbackNs, &firstExpected,
            clock_gettime_nsec_np(CLOCK_UPTIME_RAW), memory_order_relaxed, memory_order_relaxed);
        atomic_store_explicit(&_tapCommonFormat, (int)buffer.format.commonFormat, memory_order_relaxed);
        atomic_store_explicit(&_tapChannels, buffer.format.channelCount, memory_order_relaxed);
        atomic_store_explicit(&_tapSampleRate, (uint64_t)buffer.format.sampleRate, memory_order_relaxed);
        uint64_t frames = buffer.frameLength;
        uint64_t minFrames = atomic_load_explicit(&_minimumFrames, memory_order_relaxed);
        while (frames < minFrames && !atomic_compare_exchange_weak_explicit(&_minimumFrames, &minFrames, frames, memory_order_relaxed, memory_order_relaxed)) {}
        uint64_t maxFrames = atomic_load_explicit(&_maximumFrames, memory_order_relaxed);
        while (frames > maxFrames && !atomic_compare_exchange_weak_explicit(&_maximumFrames, &maxFrames, frames, memory_order_relaxed, memory_order_relaxed)) {}
        float rawPeak = 0;
        BOOL unsupported = NO;
        float level = VPCLevelForPCMBuffer(buffer, &rawPeak, &unsupported);
        if (unsupported) atomic_fetch_add_explicit(&_unsupportedBuffers, 1, memory_order_relaxed);
        if (rawPeak > 0) {
            atomic_fetch_add_explicit(&_nonzeroBuffers, 1, memory_order_relaxed);
            uint64_t expected = 0;
            atomic_compare_exchange_strong_explicit(&_firstNonzeroNs, &expected, clock_gettime_nsec_np(CLOCK_UPTIME_RAW), memory_order_relaxed, memory_order_relaxed);
            uint32_t bits;
            memcpy(&bits, &rawPeak, sizeof(bits));
            uint32_t prior = atomic_load_explicit(&_maxRawPeakBits, memory_order_relaxed);
            while (bits > prior && !atomic_compare_exchange_weak_explicit(
                &_maxRawPeakBits, &prior, bits, memory_order_relaxed, memory_order_relaxed)) {}
        }
        handler(level);
        VPCDispatchMeterPCM(buffer, rawPeak, unsupported, pcmEnabled, pcmHandler);
    };
    if (!self.useEngineBackend) {
        self.inputOnlyCapture = [[VPCInputOnlyAudioCapture alloc] init];
        if ([self.inputOnlyCapture prepareForUID:self.inputDeviceUID ?: @"" handler:pcmCallback] != noErr) {
            if (diagnostic) *diagnostic = self.inputOnlyCapture.failureDiagnostic;
            return NO;
        }
        chosen = self.inputOnlyCapture.resolvedDeviceID;
        format = self.inputOnlyCapture.format;
        __weak VPCSystemAudioBackend *weakSelf = self;
        self.inputOnlyCapture.routeHandler = ^(int32_t status) {
            VPCSystemAudioBackend *strongSelf = weakSelf;
            if (strongSelf.captureDesired && failureHandler)
                failureHandler(status ? @"AUDIO_ROUTE_REOPEN_FAILED" : @"AUDIO_ROUTE_CHANGED");
        };
    } else {
        // Explicit hidden rollback only. This legacy path stays off MainActor.
        for (int attempt = 0; attempt < 2; attempt++) {
            self.engine = [[AVAudioEngine alloc] init];
            input = self.engine.inputNode;
            format = [input inputFormatForBus:0];
            double nominal = self.nominalSampleRate;
            if (isfinite(format.sampleRate) && format.sampleRate > 0 && format.channelCount > 0 &&
                (nominal <= 0 || fabs(format.sampleRate - nominal) < 1)) break;
            [self.engine stop]; format = nil;
        }
    }
    if (!format) {
        self.openStatus = kAudioUnitErr_FormatNotSupported;
        if (diagnostic) *diagnostic = [NSString stringWithFormat:@"capture start failed stage=format status=%d", kAudioUnitErr_FormatNotSupported];
        return NO;
    }
    self.configuredDevice = chosen; self.configuredFormat = format; self.configuredRate = format.sampleRate;
    self.deviceFields = self.inputDiagnosticFields ?: @"deviceClass=unknown deviceID=0 hardwareRate=0 muted=unknown";
    if (diagnostic) *diagnostic = [NSString stringWithFormat:@"sampleRate=%.3f channels=%u commonFormat=%ld %@",
        format.sampleRate, format.channelCount, (long)format.commonFormat, self.deviceFields];
    if (self.engine) {
        self.tapMayBeInstalled = YES;
        // Negotiate the current route; callback PCM still drives conversion.
        [input installTapOnBus:0 bufferSize:512 format:nil block:pcmCallback];
    }
    if (failureHandler && self.engine) {
        self.observer = [[NSNotificationCenter defaultCenter]
            addObserverForName:AVAudioEngineConfigurationChangeNotification object:self.engine queue:nil
            usingBlock:^(__unused NSNotification *note) {
                uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
                uint64_t own = atomic_load_explicit(&_startedAtNs, memory_order_relaxed);
                if (own && now >= own && now - own < 500000000) return;
                // Never restart on CoreAudio's notification thread or after detach/stop.
                dispatch_async(self.routeQueue, ^{
                    @synchronized (self) {
                        if (!self.captureDesired) return;
                        AVAudioInputNode *node = self.engine.inputNode;
                        AVAudioFormat *current = [node inputFormatForBus:0];
                        // The Swift inventory observer checks cached device identity
                        // and rate. Never make a second hardware inventory query here.
                        if ([current isEqual:self.configuredFormat]) {
                            if (self.engine.running) return;
                            atomic_store_explicit(&_startedAtNs, clock_gettime_nsec_np(CLOCK_UPTIME_RAW), memory_order_relaxed);
                            NSError *error = nil;
                            if (![self.engine startAndReturnError:&error]) failureHandler(@"AUDIO_ROUTE_REOPEN_FAILED");
                            return;
                        }
                        failureHandler(@"AUDIO_ROUTE_CHANGED");
                    }
                });
            }];
    }
    return YES;
}
- (BOOL)start:(NSError **)error {
    @synchronized (self) {
        self.openStage = @"start";
        self.captureDesired = YES;
        atomic_store_explicit(&_startedAtNs, clock_gettime_nsec_np(CLOCK_UPTIME_RAW), memory_order_relaxed);
        BOOL result;
        if (self.inputOnlyCapture) {
            OSStatus status = [self.inputOnlyCapture start];
            result = status == noErr;
            if (!result && error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:status userInfo:nil];
        } else {
            result = [self.engine startAndReturnError:error];
            if (!result) self.openStatus = (int32_t)(error && *error ? (*error).code : kAudioUnitErr_FailedInitialization);
        }
        if (!result) self.captureDesired = NO;
        return result;
    }
}
- (void)detachObserver {
    self.captureDesired = NO;
    id observer = self.observer;
    self.observer = nil;
    if (observer) [[NSNotificationCenter defaultCenter] removeObserver:observer];
}
- (void)removeTap {
    if (!self.tapMayBeInstalled) return;
    self.tapMayBeInstalled = NO;
    [self.engine.inputNode removeTapOnBus:0];
}
- (void)stop { @synchronized (self) {
    self.captureDesired = NO; [self.engine stop]; [self.inputOnlyCapture stop];
} }
- (NSString *)openDiagnostic {
    if (self.inputOnlyCapture) return [self.inputOnlyCapture openDiagnosticForDeviceClass:self.inputDeviceClass defaultClass:self.defaultDeviceClass];
    uint64_t start = atomic_load_explicit(&_startedAtNs, memory_order_relaxed);
    uint64_t first = atomic_load_explicit(&_firstNonzeroNs, memory_order_relaxed);
    uint64_t firstCallback = atomic_load_explicit(&_firstCallbackNs, memory_order_relaxed);
    int64_t delay = first && start && first >= start ? (int64_t)((first - start) / 1000000) : -1;
    int64_t callbackMs = firstCallback && start && firstCallback >= start ? (int64_t)((firstCallback - start) / 1000000) : -1;
    return [NSString stringWithFormat:@"capture open backend=engine device=%@ default=%@ stage=%@ status=%d hwRate=%.0f ch=%u firstCallbackMs=%lld firstNonzeroMs=%lld",
        VPCFiniteDeviceClass(self.inputDeviceClass), VPCFiniteDeviceClass(self.defaultDeviceClass),
        self.openStage ?: @"new", self.openStatus, self.configuredRate, self.configuredFormat.channelCount,
        (long long)callbackMs, (long long)delay];
}
- (NSString *)diagnosticSnapshot {
    uint32_t bits = atomic_load_explicit(&_maxRawPeakBits, memory_order_relaxed);
    float peak = 0;
    memcpy(&peak, &bits, sizeof(peak));
    uint64_t callbacks = atomic_load_explicit(&_tapCallbacks, memory_order_relaxed);
    uint64_t nonzero = atomic_load_explicit(&_nonzeroBuffers, memory_order_relaxed);
    uint64_t first = atomic_load_explicit(&_firstNonzeroNs, memory_order_relaxed);
    uint64_t start = atomic_load_explicit(&_startedAtNs, memory_order_relaxed);
    int64_t delay = first && start && first >= start ? (int64_t)((first - start) / 1000000) : -1;
    uint64_t tapRate = atomic_load_explicit(&_tapSampleRate, memory_order_relaxed);
    return [NSString stringWithFormat:@"capture_diagnostic path=meter phase=end %@ sampleRate=%.0f tapRate=%llu channels=%u commonFormat=%d callbacks=%llu unsupported=%llu nonzero=%llu rawPeak=%.7f framesMin=%llu framesMax=%llu firstNonzeroMs=%lld state=%@",
        self.deviceFields ?: @"deviceClass=unknown deviceID=0 hardwareRate=0 muted=unknown",
        tapRate ? (double)tapRate : self.configuredRate, (unsigned long long)tapRate,
        atomic_load_explicit(&_tapChannels, memory_order_relaxed), atomic_load_explicit(&_tapCommonFormat, memory_order_relaxed),
        (unsigned long long)callbacks,
        (unsigned long long)atomic_load_explicit(&_unsupportedBuffers, memory_order_relaxed),
        (unsigned long long)nonzero, peak,
        (unsigned long long)(callbacks ? atomic_load_explicit(&_minimumFrames, memory_order_relaxed) : 0),
        (unsigned long long)atomic_load_explicit(&_maximumFrames, memory_order_relaxed), (long long)delay,
        callbacks == 0 ? @"no_callbacks" : (nonzero == 0 ? @"all_zero" : @"nonzero")];
}
@end

NSString *VPCAudioMeterDiagnosticLogProbe(void) {
    // No prepare/start call: this executes the actual numeric formatter only.
    return [[[VPCSystemAudioBackend alloc] init] diagnosticSnapshot];
}

typedef id<VPCAudioBackend> (^VPCBackendFactory)(void);
@interface VPCAudioMeterSession ()
@property(nonatomic, strong) id<VPCAudioBackend> backend;
@property(nonatomic, copy) VPCAudioLevelHandler handler;
@property(nonatomic, copy) VPCAudioFailureHandler failureHandler;
@property(nonatomic, copy) VPCAudioPCMEnabled pcmEnabled;
@property(nonatomic, copy) VPCAudioPCMHandler pcmHandler;
@property(nonatomic, copy) VPCBackendFactory factory;
@property(nonatomic, copy) NSString *lastOpenDiagnostic;
@end

@implementation VPCAudioMeterSession
- (instancetype)initWithHandler:(VPCAudioLevelHandler)handler { return [self initWithHandler:handler failureHandler:nil]; }
- (instancetype)initWithHandler:(VPCAudioLevelHandler)handler failureHandler:(VPCAudioFailureHandler)failureHandler {
    return [self initWithHandler:handler failureHandler:failureHandler pcmEnabled:nil pcmHandler:nil];
}
- (instancetype)initWithHandler:(VPCAudioLevelHandler)handler failureHandler:(VPCAudioFailureHandler)failureHandler
    pcmEnabled:(VPCAudioPCMEnabled)pcmEnabled pcmHandler:(VPCAudioPCMHandler)pcmHandler {
    self = [super init];
    if (self) {
        _handler = [handler copy];
        _failureHandler = [failureHandler copy];
        _pcmEnabled = [pcmEnabled copy]; _pcmHandler = [pcmHandler copy];
        _factory = ^id<VPCAudioBackend> { return [[VPCSystemAudioBackend alloc] init]; };
    }
    return self;
}
- (BOOL)startWithFailure:(NSString **)failure { return [self startWithFailure:failure diagnostic:NULL]; }
- (BOOL)startWithFailure:(NSString **)failure diagnostic:(NSString **)diagnostic {
    [self stop];
    self.lastOpenDiagnostic = nil;
    NSString *stage = @"format";
    @try {
        self.backend = self.factory();
        if ([self.backend isKindOfClass:[VPCSystemAudioBackend class]]) {
            VPCSystemAudioBackend *backend = (VPCSystemAudioBackend *)self.backend;
            backend.inputDeviceID = self.inputDeviceID;
            backend.systemDefaultInputID = self.systemDefaultInputID;
            backend.nominalSampleRate = self.nominalSampleRate;
            backend.inputDiagnosticFields = self.inputDiagnosticFields;
            backend.inputDeviceUID = self.inputDeviceUID;
            backend.inputDeviceClass = self.inputDeviceClass;
            backend.defaultDeviceClass = self.defaultDeviceClass;
            backend.useEngineBackend = self.useEngineBackend;
        }
        if (![self.backend prepare:self.handler failureHandler:self.failureHandler
                pcmEnabled:self.pcmEnabled pcmHandler:self.pcmHandler diagnostic:diagnostic]) {
            if (failure) *failure = @"INPUT_FORMAT_UNAVAILABLE";
            [self stop];
            return NO;
        }
        NSError *error = nil;
        stage = @"start";
        if (![self.backend start:&error]) {
            if (failure) *failure = @"ENGINE_START_FAILED";
            if (diagnostic) *diagnostic = [NSString stringWithFormat:@"capture start failed stage=start status=%ld", (long)(error ? error.code : kAudioUnitErr_FailedInitialization)];
            [self stop];
            return NO;
        }
        return YES;
    } @catch (NSException *exception) {
        (void)exception;
        if (failure) *failure = @"CORE_AUDIO_EXCEPTION";
        if (diagnostic) *diagnostic = [NSString stringWithFormat:@"capture start failed stage=%@ status=%d", stage, kAudioUnitErr_CannotDoInCurrentContext];
        if ([self.backend isKindOfClass:[VPCSystemAudioBackend class]]) {
            VPCSystemAudioBackend *backend = (VPCSystemAudioBackend *)self.backend;
            backend.openStage = stage; backend.openStatus = kAudioUnitErr_CannotDoInCurrentContext;
        }
        [self stop];
        return NO;
    }
}
- (NSString *)diagnosticSnapshot { return [self.backend diagnosticSnapshot] ?: @"unavailable"; }
- (NSString *)openDiagnostic {
    return self.lastOpenDiagnostic ?: @"";
}
- (void)stop {
    // Separate boundaries ensure a failed removeTap cannot skip later cleanup.
    @try { [self.backend detachObserver]; } @catch (__unused NSException *e) {}
    @try { [self.backend removeTap]; } @catch (__unused NSException *e) {}
    @try { [self.backend stop]; } @catch (__unused NSException *e) {}
    if ([self.backend isKindOfClass:[VPCSystemAudioBackend class]]) {
        self.lastOpenDiagnostic = [(VPCSystemAudioBackend *)self.backend openDiagnostic];
    }
    @try { self.backend = nil; } @catch (__unused NSException *e) {}
}
- (void)dealloc { [self stop]; }
@end

@interface VPCFaultAudioBackend : NSObject <VPCAudioBackend>
@property(nonatomic) NSUInteger faults;
@property(nonatomic) NSUInteger prepared;
@property(nonatomic) NSUInteger started;
@property(nonatomic) NSUInteger detached;
@property(nonatomic) NSUInteger removed;
@property(nonatomic) NSUInteger stopped;
@end
@implementation VPCFaultAudioBackend
- (BOOL)prepare:(__unused VPCAudioLevelHandler)handler failureHandler:(__unused VPCAudioFailureHandler)failureHandler
    pcmEnabled:(__unused VPCAudioPCMEnabled)pcmEnabled pcmHandler:(__unused VPCAudioPCMHandler)pcmHandler diagnostic:(__unused NSString **)diagnostic {
    self.prepared++;
    if (self.faults & 1) [NSException raise:@"InjectedInstallTap" format:@"format mismatch"];
    return !(self.faults & 32);
}
- (BOOL)start:(NSError **)error {
    self.started++;
    if (self.faults & 2) [NSException raise:@"InjectedStart" format:@"start"];
    if (self.faults & 16) {
        if (error) *error = [NSError errorWithDomain:@"VPCProbe" code:1 userInfo:nil];
        return NO;
    }
    return YES;
}
- (void)detachObserver { self.detached++; }
- (void)removeTap {
    self.removed++;
    if (self.faults & 4) [NSException raise:@"InjectedRemoveTap" format:@"remove"];
}
- (void)stop {
    self.stopped++;
    if (self.faults & 8) [NSException raise:@"InjectedStop" format:@"stop"];
}
- (NSString *)diagnosticSnapshot { return @"probe"; }
@end

BOOL VPCAudioMeterRunLevelFormatProbe(void) {
    const AVAudioCommonFormat formats[] = {
        AVAudioPCMFormatFloat32, AVAudioPCMFormatFloat64, AVAudioPCMFormatInt16, AVAudioPCMFormatInt32
    };
    for (NSUInteger type = 0; type < sizeof(formats) / sizeof(formats[0]); type++) {
      for (NSUInteger layout = 0; layout < 2; layout++) {
        BOOL interleaved = layout == 1;
        AVAudioFormat *format = [[AVAudioFormat alloc] initWithCommonFormat:formats[type]
            sampleRate:48000 channels:2 interleaved:interleaved];
        AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:format frameCapacity:8];
        if (!buffer) return NO;
        buffer.frameLength = 8;
        for (NSUInteger channel = 0; channel < 2; channel++) {
            for (NSUInteger frame = 0; frame < 8; frame++) {
                NSUInteger index = interleaved ? frame * 2 + channel : frame;
                NSUInteger plane = interleaved ? 0 : channel;
                switch (formats[type]) {
                case AVAudioPCMFormatFloat64: {
                    AudioBufferList *list = buffer.mutableAudioBufferList;
                    ((double *)list->mBuffers[plane].mData)[index] = .25;
                    break;
                }
                case AVAudioPCMFormatFloat32: buffer.floatChannelData[plane][index] = 0.25f; break;
                case AVAudioPCMFormatInt16: buffer.int16ChannelData[plane][index] = 8192; break;
                case AVAudioPCMFormatInt32: buffer.int32ChannelData[plane][index] = 536870912; break;
                default: return NO;
                }
            }
        }
        float peak = 0;
        BOOL unsupported = NO;
        float level = VPCLevelForPCMBuffer(buffer, &peak, &unsupported);
        if (unsupported || fabsf(peak - 0.25f) > 0.001f || fabsf(level - 0.70f) > 0.001f) return NO;
      }
    }
    return YES;
}

BOOL VPCAudioMeterRunLifecycleExceptionProbe(void) {
    // All 64 combinations, each restarted three times on the SAME session.
    for (NSUInteger faults = 0; faults < 64; faults++) {
        VPCAudioMeterSession *session = [[VPCAudioMeterSession alloc] initWithHandler:^(__unused float level) {}];
        NSMutableArray<VPCFaultAudioBackend *> *created = [NSMutableArray array];
        session.factory = ^id<VPCAudioBackend> {
            VPCFaultAudioBackend *backend = [[VPCFaultAudioBackend alloc] init];
            backend.faults = faults;
            [created addObject:backend];
            return backend;
        };
        for (NSUInteger cycle = 0; cycle < 3; cycle++) {
            NSString *failure = nil;
            BOOL started = [session startWithFailure:&failure];
            BOOL expected = !(faults & (1 | 2 | 16 | 32));
            if (started != expected || (!started && !failure)) return NO;
            if (created.count != cycle + 1) return NO;
            VPCFaultAudioBackend *backend = created.lastObject;
            if (backend.prepared != 1 || backend.started != ((faults & (1 | 32)) ? 0 : 1)) return NO;
            [session stop];
            [session stop];
            if (session.backend || backend.detached != 1 || backend.removed != 1 || backend.stopped != 1) return NO;
        }
    }
    return YES;
}
