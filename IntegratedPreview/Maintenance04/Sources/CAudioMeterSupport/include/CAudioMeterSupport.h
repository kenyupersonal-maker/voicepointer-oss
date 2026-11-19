#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^VPCAudioLevelHandler)(float level);
typedef void (^VPCAudioFailureHandler)(NSString *reason);
// T8: Optional memory-only outlet, from the very same tap as the meter. Borrowed buffer expires on return.
typedef BOOL (^VPCAudioPCMEnabled)(void);
typedef void (^VPCAudioPCMHandler)(AVAudioPCMBuffer *buffer, float rawPeak);
typedef void (^VPCAudioInputBufferHandler)(AVAudioPCMBuffer *buffer, AVAudioTime *time);
typedef void (^VPCAudioInputRouteHandler)(int32_t status);

/// Shared serial HAL control queue. Cached inventory reads use a separate lock.
FOUNDATION_EXPORT dispatch_queue_t VPCAudioControlQueue(void);

/// Input-only AUHAL. Its real-time callback writes a preallocated SPSC ring;
/// handlers run on a normal 10ms consumer queue. All lifecycle calls belong on
/// VPCAudioControlQueue. UID selectors remain in memory and are never logged.
@interface VPCInputOnlyAudioCapture : NSObject
@property(nonatomic, readonly, nullable) AVAudioFormat *format;
@property(nonatomic, readonly) NSString *failureStage;
@property(nonatomic, readonly) int32_t failureStatus;
@property(nonatomic, readonly) NSString *failureDiagnostic;
@property(nonatomic, readonly, getter=isRunning) BOOL running;
@property(nonatomic, readonly) uint32_t resolvedDeviceID;
@property(nonatomic, copy, nullable) VPCAudioInputRouteHandler routeHandler;
- (int32_t)prepareForUID:(NSString *)uid handler:(VPCAudioInputBufferHandler)handler NS_SWIFT_NAME(prepare(uid:handler:));
- (int32_t)start;
- (void)stop;
- (void)stopAndFinish:(void (^ _Nullable)(void))finish NS_SWIFT_NAME(stop(finishing:));
- (NSString *)openDiagnosticForDeviceClass:(NSString *)deviceClass defaultClass:(NSString *)defaultClass NS_SWIFT_NAME(openDiagnostic(deviceClass:defaultClass:));
@end

@interface VPCAudioMeterSession : NSObject
@property(nonatomic) uint32_t inputDeviceID;
@property(nonatomic) uint32_t systemDefaultInputID;
@property(nonatomic) double nominalSampleRate;
@property(nonatomic, copy, nullable) NSString *inputDiagnosticFields;
@property(nonatomic, copy) NSString *inputDeviceUID;
@property(nonatomic, copy) NSString *inputDeviceClass;
@property(nonatomic, copy) NSString *defaultDeviceClass;
@property(nonatomic) BOOL useEngineBackend;
- (instancetype)initWithHandler:(VPCAudioLevelHandler)handler;
- (instancetype)initWithHandler:(VPCAudioLevelHandler)handler failureHandler:(VPCAudioFailureHandler _Nullable)failureHandler;
- (instancetype)initWithHandler:(VPCAudioLevelHandler)handler failureHandler:(VPCAudioFailureHandler _Nullable)failureHandler
    pcmEnabled:(VPCAudioPCMEnabled _Nullable)pcmEnabled pcmHandler:(VPCAudioPCMHandler _Nullable)pcmHandler;
- (BOOL)startWithFailure:(NSString * _Nullable * _Nullable)failure;
- (BOOL)startWithFailure:(NSString * _Nullable * _Nullable)failure diagnostic:(NSString * _Nullable * _Nullable)diagnostic;
- (NSString *)diagnosticSnapshot;
- (NSString *)openDiagnostic;
- (void)stop;
@end

FOUNDATION_EXPORT BOOL VPCAudioMeterRunLifecycleExceptionProbe(void);
FOUNDATION_EXPORT BOOL VPCAudioMeterRunLevelFormatProbe(void);
FOUNDATION_EXPORT BOOL VPCAudioMeterRunPCMOutletProbe(void);
/// Device class, a SHA-256 UID digest, hardware rate and mute enum only.
FOUNDATION_EXPORT NSString *VPCAudioInputDiagnosticFields(void);
FOUNDATION_EXPORT NSString *VPCAudioInputDiagnosticFieldsForDevice(uint32_t device);
/// Formats the real backend's empty diagnostic without opening an audio engine.
FOUNDATION_EXPORT NSString *VPCAudioMeterDiagnosticLogProbe(void);

NS_ASSUME_NONNULL_END
