#ifndef VOICE_POINTER_MULTITOUCH_SUPPORT_SHIM_H
#define VOICE_POINTER_MULTITOUCH_SUPPORT_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum {
    VPDeviceKindUnknown = 0,
    VPDeviceKindBuiltInTrackpad = 1,
    VPDeviceKindMagicMouse = 2,
    VPDeviceKindExternalTrackpad = 3,
} VPDeviceKind;

typedef struct {
    uintptr_t token;
    VPDeviceKind kind;
    int32_t familyID;
    int32_t sensorRows;
    int32_t sensorColumns;
    int32_t touchCount;
    double lastFrameAgeSeconds;
    uint64_t callbackCount;
    int32_t rawTouchCount;
    uint32_t stageMask;
    float directionalDisplacementX;
    float directionalDisplacementY;
    float minDensity;
    uint64_t deviceID;
} VPDeviceInfo;

typedef enum { VPDecisionTouchCount = 0, VPDecisionLandingSkew = 1,
    VPDecisionFreshWindow = 2, VPDecisionMovement = 3, VPDecisionFrameExpired = 4,
    VPDecisionDensity = 5, VPDecisionPassed = 6 } VPGestureDecision;
typedef struct { int32_t stage; float x, y, major, minor, size, density; bool edge; } VPTouchSnapshotPoint;
bool VPMagicMouseIsEdge(float x, float minor, float margin, float maxMinor);
void VPSetMagicMouseEdgeFilter(float margin, float maxMinor);
bool VPTestInjectTouchFrame(VPDeviceKind kind, const VPTouchSnapshotPoint *points, int32_t count);
typedef struct { uintptr_t deviceToken; int32_t count; VPTouchSnapshotPoint points[6];
    double frameAgeSeconds, newestTouchAgeSeconds, oldestTouchAgeSeconds;
    float maximumMovement; } VPTouchSnapshot;
/// Numeric gate values and the selected mouse surface from one locked evaluation.
/// minDensity is the gate's tracked-contact minimum, not snapshot point density.
typedef struct {
    int32_t deviceIndex;
    VPGestureDecision reason;
    float minDensity;
    float requiredDensity;
    double skewSeconds, oldestAgeSeconds;
    bool retriedWithoutLift;
    VPTouchSnapshot snapshot;
} VPMouseDecision;
bool VPCopyTouchSnapshot(int32_t deviceIndex, VPTouchSnapshot *out);

typedef struct {
    uintptr_t deviceToken;
    VPDeviceKind deviceKind;
    int32_t touchCount;
    double newestTouchAgeSeconds;
    double oldestTouchAgeSeconds;
    float maximumMovement;
} VPGestureMatch;

/// Dynamically loads Apple's private MultitouchSupport framework and starts
/// callbacks for trackpad-class devices. Returns false without crashing when
/// the framework ABI is unavailable.
bool VPStartTouchDriver(void);
void VPStopTouchDriver(void);
bool VPReloadTouchDevices(void);
const char *VPGetTouchDriverStatus(void);
/// Copies the current status while holding the shim lock.
bool VPCopyTouchDriverStatus(char *buffer, size_t bufferSize);

int32_t VPGetTouchDeviceCount(void);
int32_t VPGetConnectedMultitouchServiceCount(void);
bool VPCopyTouchDeviceInfo(int32_t index, VPDeviceInfo *outInfo);

/// Atomically checks every current device against the touch-count gate.
/// A successful chord is consumed until all fingers leave that device.
bool VPConsumeEligibleGesture(
    int32_t magicMouseFingerCount,
    int32_t trackpadFingerCount,
    double freshChordWindowSeconds,
    double magicMouseFreshChordWindowSeconds,
    float maximumMovement,
    double maximumFrameAgeSeconds,
    bool trackpadEnabled,
    float magicMouseMinDensity,
    double maxLandingSkewSeconds,
    double fastLandingSeconds,
    float slowMinDensity,
    bool consume,
    VPGestureMatch *outMatch,
    VPMouseDecision *outDecision
);

/// The one two-stage density rule used by the live shim and Swift preview.
float VPMagicMouseRequiredDensity(float minimumDensity, float slowMinDensity,
                                  double fastLandingSeconds, double skewSeconds);

/// Test-only in-memory touch state injection; never touches the private framework.
/// Refuses if this process has loaded the real framework.
bool VPTestResetTouchState(void);

bool VPTestInjectTouchState(
    VPDeviceKind kind,
    int32_t touchCount,
    double frameAgeSeconds,
    double newestTouchAgeSeconds,
    double oldestTouchAgeSeconds,
    float maximumMovement,
    float minDensity
);
bool VPTestSetMinDensity(float minDensity);

/// Updates the latest injected device of `kind` with a normalized directional
/// displacement. Test-only; production values come from touch frames.
bool VPTestSetTouchDisplacement(
    VPDeviceKind kind,
    float displacementX,
    float displacementY
);

#ifdef __cplusplus
}
#endif

#endif
