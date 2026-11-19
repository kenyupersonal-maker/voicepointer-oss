#include "MultitouchSupportShim.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stddef.h>
#include <string.h>
#include <time.h>

#define VP_MAX_DEVICES 16
#define VP_MAX_TOUCHES 20
#define VP_MIN_SENSOR_ROWS 10

typedef struct { float x; float y; } VPPoint;
typedef struct { VPPoint position; VPPoint velocity; } VPReadout;

// Private ABI used by MultitouchSupport on current arm64 macOS releases.
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier;
    int32_t stage;
    int32_t fingerID;
    int32_t handID;
    VPReadout normalized;
    float contactSize;
    int32_t zero;
    float angle;
    float majorAxis;
    float minorAxis;
    VPReadout millimeters;
    int32_t unknown[2];
    float density;
} VPTouch;

// Verified arm64 layout of the legacy MultitouchSupport contact ABI.
_Static_assert(sizeof(VPReadout) == 16, "unexpected VPReadout ABI size");
_Static_assert(sizeof(VPTouch) == 96, "unexpected VPTouch ABI size");
_Static_assert(offsetof(VPTouch, timestamp) == 8, "unexpected VPTouch timestamp offset");
_Static_assert(offsetof(VPTouch, normalized) == 32, "unexpected VPTouch normalized offset");
_Static_assert(offsetof(VPTouch, millimeters) == 68, "unexpected VPTouch millimeters offset");
_Static_assert(offsetof(VPTouch, density) == 92, "unexpected VPTouch density offset");

typedef void *VPPrivateDeviceRef;
typedef int (*VPLegacyFrameCallback)(VPPrivateDeviceRef, VPTouch *, int32_t, double, int32_t);
typedef CFArrayRef (*VPCreateDeviceListFn)(void);
typedef void (*VPRegisterFrameCallbackFn)(VPPrivateDeviceRef, VPLegacyFrameCallback);
typedef void (*VPUnregisterFrameCallbackFn)(VPPrivateDeviceRef, VPLegacyFrameCallback);
typedef void (*VPDeviceStartFn)(VPPrivateDeviceRef, int32_t);
typedef void (*VPDeviceStopFn)(VPPrivateDeviceRef);
typedef int32_t (*VPGetSensorDimensionsFn)(VPPrivateDeviceRef, int32_t *, int32_t *);
typedef int32_t (*VPGetFamilyIDFn)(VPPrivateDeviceRef, int32_t *);
typedef bool (*VPIsBuiltInFn)(VPPrivateDeviceRef);
typedef io_service_t (*VPGetServiceFn)(VPPrivateDeviceRef);

typedef struct {
    int32_t identifier;
    float landingX;
    float landingY;
    float currentX;
    float currentY;
    float currentDensity, currentMajor, currentMinor, currentSize;
    double landedAt;
    bool seen;
} VPTrackedTouch;

typedef struct {
    VPPrivateDeviceRef device;
    uint64_t deviceID;
    VPDeviceKind kind;
    int32_t familyID;
    int32_t rows;
    int32_t columns;
    int32_t touchCount;
    double lastFrameAt;
    double newestLandingAt;
    double oldestLandingAt;
    float maximumMovement;
    bool consumed;
    VPTrackedTouch touches[VP_MAX_TOUCHES];
    int32_t trackedTouchCount;
    uint64_t rawCallbackCount;
    int32_t rawSuppliedTouchCount;
    uint32_t stageBitmask;
    float directionalDisplacementX;
    float directionalDisplacementY;
    VPTouchSnapshot snapshot;
} VPDeviceState;

static pthread_mutex_t vp_lock = PTHREAD_MUTEX_INITIALIZER;
static float vp_edge_margin, vp_edge_max_minor;
bool VPMagicMouseIsEdge(float x, float minor, float margin, float maxMinor) {
    return isfinite(x) && isfinite(minor) && isfinite(margin) && isfinite(maxMinor)
        && margin > 0 && margin < 0.5f && minor >= 0 && maxMinor > 0
        && (x >= 1.0f - margin || x <= margin) && minor <= maxMinor;
}
void VPSetMagicMouseEdgeFilter(float margin, float maxMinor) {
    if (!isfinite(margin) || !isfinite(maxMinor) || margin <= 0 || margin >= 0.5f || maxMinor <= 0) return;
    pthread_mutex_lock(&vp_lock);
    vp_edge_margin = margin; vp_edge_max_minor = maxMinor;
    pthread_mutex_unlock(&vp_lock);
}
static void *vp_framework = NULL;
static CFArrayRef vp_device_list = NULL;
static VPDeviceState vp_devices[VP_MAX_DEVICES];
static int32_t vp_device_count = 0;
static bool vp_stopping = false;
static char vp_status[256] = "Touch driver has not started";

static VPCreateDeviceListFn vp_create_device_list = NULL;
static VPRegisterFrameCallbackFn vp_register_callback = NULL;
static VPUnregisterFrameCallbackFn vp_unregister_callback = NULL;
static VPDeviceStartFn vp_device_start = NULL;
static VPDeviceStopFn vp_device_stop = NULL;
static VPGetSensorDimensionsFn vp_get_dimensions = NULL;
static VPGetFamilyIDFn vp_get_family_id = NULL;
static VPIsBuiltInFn vp_is_built_in = NULL;
static VPGetServiceFn vp_get_service = NULL;

// The service must come from this device, never a global guessed trackpad ID.
// This runs during enumeration, outside vp_lock; it reads no touch history.
static uint64_t vp_read_device_id(VPPrivateDeviceRef device) {
    if (vp_get_service == NULL) return 0;
    io_service_t service = vp_get_service(device);
    if (service == IO_OBJECT_NULL) return 0;
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, CFSTR("Multitouch ID"), kCFAllocatorDefault, 0);
    uint64_t identifier = 0;
    if (value != NULL) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) {
            if (!CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &identifier)) identifier = 0;
        }
        CFRelease(value);
    }
    return identifier;
}

static double vp_monotonic_seconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC_RAW, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static bool vp_touch_is_active(const VPTouch *touch) {
    return touch->stage == 4;
}

// Magic Mouse contacts do not expose per-finger force in the ABI we consume.
// Keep the existing two-finger count gate, but require the two contacts to
// land close together so a late second finger cannot turn an ordinary click
// into a gesture. Trackpad recognition intentionally keeps its existing
// timing policy.

static void vp_reset_gesture(VPDeviceState *state) {
    state->touchCount = 0;
    state->newestLandingAt = 0;
    state->oldestLandingAt = 0;
    state->maximumMovement = 0;
    state->consumed = false;
    state->trackedTouchCount = 0;
    memset(state->touches, 0, sizeof(state->touches));
}

static VPDeviceState *vp_find_device(VPPrivateDeviceRef device) {
    for (int32_t index = 0; index < vp_device_count; index++) {
        if (vp_devices[index].device == device) return &vp_devices[index];
    }
    return NULL;
}

static VPTrackedTouch *vp_find_touch(VPDeviceState *state, int32_t identifier) {
    for (int32_t index = 0; index < state->trackedTouchCount; index++) {
        if (state->touches[index].identifier == identifier) return &state->touches[index];
    }
    return NULL;
}

static void vp_process_touch_frame(
    VPPrivateDeviceRef device,
    VPTouch *touches,
    size_t suppliedTouchCount,
    double timestamp,
    size_t frame
) {
    (void)timestamp;
    (void)frame;
    // The framework occasionally reports a positive count with no contact
    // buffer while tearing down a device. Treat it as an ignorable frame.
    if (suppliedTouchCount > 0 && touches == NULL) return;
    const double now = vp_monotonic_seconds();

    pthread_mutex_lock(&vp_lock);
    if (vp_stopping) {
        pthread_mutex_unlock(&vp_lock);
        return;
    }
    VPDeviceState *state = vp_find_device(device);
    if (state == NULL) {
        pthread_mutex_unlock(&vp_lock);
        return;
    }

    for (int32_t index = 0; index < state->trackedTouchCount; index++) {
        state->touches[index].seen = false;
    }

    state->rawCallbackCount++;
    state->rawSuppliedTouchCount = suppliedTouchCount > INT32_MAX ? INT32_MAX : (int32_t)suppliedTouchCount;
    state->stageBitmask = 0;
    int32_t activeCount = 0;
    const size_t safeCount = suppliedTouchCount < VP_MAX_TOUCHES ? suppliedTouchCount : VP_MAX_TOUCHES;
    state->snapshot.count = (int32_t)(safeCount < 6 ? safeCount : 6);
    for (int32_t i = 0; i < state->snapshot.count; i++) {
        VPTouch *r = &touches[i];
        state->snapshot.points[i] = (VPTouchSnapshotPoint){r->stage, r->normalized.position.x,
            r->normalized.position.y, r->majorAxis, r->minorAxis, r->contactSize, r->density,
            state->kind == VPDeviceKindMagicMouse && VPMagicMouseIsEdge(r->normalized.position.x, r->minorAxis, vp_edge_margin, vp_edge_max_minor)};
    }
    for (size_t index = 0; index < safeCount; index++) {
        VPTouch *raw = &touches[index];
        if (raw->stage >= 0 && raw->stage < 32) state->stageBitmask |= (uint32_t)1u << raw->stage;
        if (!vp_touch_is_active(raw)) continue;
        if (state->kind == VPDeviceKindMagicMouse && VPMagicMouseIsEdge(raw->normalized.position.x, raw->minorAxis, vp_edge_margin, vp_edge_max_minor)) continue;
        activeCount++;
        VPTrackedTouch *tracked = vp_find_touch(state, raw->identifier);
        if (tracked == NULL && state->trackedTouchCount < VP_MAX_TOUCHES) {
            tracked = &state->touches[state->trackedTouchCount++];
            tracked->identifier = raw->identifier;
            tracked->landingX = raw->normalized.position.x;
            tracked->landingY = raw->normalized.position.y;
            tracked->currentX = raw->normalized.position.x;
            tracked->currentY = raw->normalized.position.y;
            tracked->landedAt = now;
        }
        if (tracked != NULL) {
            tracked->seen = true;
            tracked->currentDensity = raw->density;
            tracked->currentMajor = raw->majorAxis;
            tracked->currentMinor = raw->minorAxis;
            tracked->currentSize = raw->contactSize;
            tracked->currentX = raw->normalized.position.x;
            tracked->currentY = raw->normalized.position.y;
            const float dx = raw->normalized.position.x - tracked->landingX;
            const float dy = raw->normalized.position.y - tracked->landingY;
            const float movement = sqrtf(dx * dx + dy * dy);
            if (movement > state->maximumMovement) state->maximumMovement = movement;
        }
    }

    if (activeCount == 0) {
        vp_reset_gesture(state);
        state->lastFrameAt = now;
        pthread_mutex_unlock(&vp_lock);
        return;
    }

    int32_t writeIndex = 0;
    for (int32_t index = 0; index < state->trackedTouchCount; index++) {
        if (state->touches[index].seen) {
            if (writeIndex != index) state->touches[writeIndex] = state->touches[index];
            writeIndex++;
        }
    }
    state->trackedTouchCount = writeIndex;
    if (writeIndex > 0) {
        float displacementX = 0;
        float displacementY = 0;
        double newestLandingAt = 0;
        double oldestLandingAt = 0;
        for (int32_t index = 0; index < writeIndex; index++) {
            displacementX += state->touches[index].currentX - state->touches[index].landingX;
            displacementY += state->touches[index].currentY - state->touches[index].landingY;
            const double landedAt = state->touches[index].landedAt;
            if (newestLandingAt == 0 || landedAt > newestLandingAt) newestLandingAt = landedAt;
            if (oldestLandingAt == 0 || landedAt < oldestLandingAt) oldestLandingAt = landedAt;
        }
        state->directionalDisplacementX = displacementX / (float)writeIndex;
        state->directionalDisplacementY = displacementY / (float)writeIndex;
        state->newestLandingAt = newestLandingAt;
        state->oldestLandingAt = oldestLandingAt;
    }
    state->touchCount = activeCount;
    state->lastFrameAt = now;
    pthread_mutex_unlock(&vp_lock);
    return;
}

static void vp_clear_symbols(void) {
    vp_create_device_list = NULL;
    vp_register_callback = NULL;
    vp_unregister_callback = NULL;
    vp_device_start = NULL;
    vp_device_stop = NULL;
    vp_get_dimensions = NULL;
    vp_get_family_id = NULL;
    vp_is_built_in = NULL;
    vp_get_service = NULL;
}

static int vp_on_touch_frame_legacy(
    VPPrivateDeviceRef device, VPTouch *touches, int32_t count, double timestamp, int32_t frame
) {
    vp_process_touch_frame(device, touches, count < 0 ? 0 : (size_t)count, timestamp, frame < 0 ? 0 : (size_t)frame);
    return 0;
}

static bool vp_load_framework(void) {
    if (vp_framework != NULL) return true;
    const char *paths[] = {
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport",
        "/System/Library/PrivateFrameworks/MultitouchSupport.framework/Versions/A/MultitouchSupport",
        "/System/Library/PrivateFrameworks/MultitouchSupportPrivate.framework/MultitouchSupportPrivate",
        "/System/Library/PrivateFrameworks/MultitouchSupportPrivate.framework/Versions/A/MultitouchSupportPrivate",
    };
    for (size_t index = 0; index < sizeof(paths) / sizeof(paths[0]); index++) {
        vp_framework = dlopen(paths[index], RTLD_NOW | RTLD_GLOBAL);
        if (vp_framework != NULL) {
            snprintf(vp_status, sizeof(vp_status), "Loaded %s", paths[index]);
            break;
        }
    }
    if (vp_framework == NULL) {
        snprintf(vp_status, sizeof(vp_status), "Unable to load MultitouchSupport: %s", dlerror());
        return false;
    }

#define VP_RESOLVE_REQUIRED(target, name)                                      \
    do {                                                                        \
        *(void **)(&(target)) = dlsym(vp_framework, (name));                   \
        if ((target) == NULL) {                                                  \
            snprintf(vp_status, sizeof(vp_status), "Missing symbol %s", name); \
            dlclose(vp_framework);                                               \
            vp_framework = NULL;                                                 \
            vp_clear_symbols();                                                  \
            return false;                                                        \
        }                                                                        \
    } while (0)

    VP_RESOLVE_REQUIRED(vp_create_device_list, "MTDeviceCreateList");
    // The classic callback ABI is used by the current macOS 26 reference
    // implementation and, unlike the refcon variant, has a matching public
    // unregister symbol on this system.
    VP_RESOLVE_REQUIRED(vp_register_callback, "MTRegisterContactFrameCallback");
    VP_RESOLVE_REQUIRED(vp_device_start, "MTDeviceStart");
    VP_RESOLVE_REQUIRED(vp_device_stop, "MTDeviceStop");
    VP_RESOLVE_REQUIRED(vp_get_dimensions, "MTDeviceGetSensorDimensions");
    VP_RESOLVE_REQUIRED(vp_get_family_id, "MTDeviceGetFamilyID");
    VP_RESOLVE_REQUIRED(vp_unregister_callback, "MTUnregisterContactFrameCallback");
    *(void **)(&vp_is_built_in) = dlsym(vp_framework, "MTDeviceIsBuiltIn");
    *(void **)(&vp_get_service) = dlsym(vp_framework, "MTDeviceGetService");
#undef VP_RESOLVE_REQUIRED
    return true;
}

static void vp_quiesce_devices(void) {
    VPPrivateDeviceRef devices[VP_MAX_DEVICES];
    int32_t deviceCount = 0;
    CFArrayRef deviceList = NULL;

    // Do not call into MultitouchSupport while holding vp_lock: MTDeviceStop
    // may synchronously drain a callback that also needs this lock.
    pthread_mutex_lock(&vp_lock);
    vp_stopping = true;
    deviceCount = vp_device_count;
    for (int32_t index = 0; index < deviceCount; index++) devices[index] = vp_devices[index].device;
    deviceList = vp_device_list;
    vp_device_list = NULL;
    memset(vp_devices, 0, sizeof(vp_devices));
    vp_device_count = 0;
    pthread_mutex_unlock(&vp_lock);

    for (int32_t index = 0; index < deviceCount; index++) {
        if (vp_unregister_callback != NULL) vp_unregister_callback(devices[index], vp_on_touch_frame_legacy);
        if (vp_device_stop != NULL) vp_device_stop(devices[index]);
        CFRelease((CFTypeRef)devices[index]);
    }
    if (deviceList != NULL) CFRelease(deviceList);
}

bool VPReloadTouchDevices(void) {
    pthread_mutex_lock(&vp_lock);
    const bool frameworkLoaded = vp_load_framework();
    pthread_mutex_unlock(&vp_lock);
    if (!frameworkLoaded) return false;

    vp_quiesce_devices();
    CFArrayRef newDeviceList = vp_create_device_list();
    if (newDeviceList == NULL) {
        pthread_mutex_lock(&vp_lock);
        snprintf(vp_status, sizeof(vp_status), "MTDeviceCreateList returned no devices");
        pthread_mutex_unlock(&vp_lock);
        return false;
    }

    VPDeviceState newDevices[VP_MAX_DEVICES];
    memset(newDevices, 0, sizeof(newDevices));
    int32_t newDeviceCount = 0;
    const CFIndex rawCount = CFArrayGetCount(newDeviceList);
    for (CFIndex rawIndex = 0; rawIndex < rawCount && newDeviceCount < VP_MAX_DEVICES; rawIndex++) {
        VPPrivateDeviceRef device = (VPPrivateDeviceRef)CFArrayGetValueAtIndex(newDeviceList, rawIndex);
        int32_t rows = 0;
        int32_t columns = 0;
        if (vp_get_dimensions(device, &rows, &columns) != 0 || rows < VP_MIN_SENSOR_ROWS) continue;

        VPDeviceState *state = &newDevices[newDeviceCount++];
        memset(state, 0, sizeof(*state));
        state->device = device;
        state->deviceID = vp_read_device_id(device);
        CFRetain((CFTypeRef)device);
        state->rows = rows;
        state->columns = columns;
        if (vp_is_built_in != NULL && vp_is_built_in(device)) {
            state->kind = VPDeviceKindBuiltInTrackpad;
        } else if (rows <= 16 && columns <= 16) {
            // Current Magic Mouse sensors are materially smaller than Magic
            // Trackpad sensors. Family IDs are logged but not treated as a
            // stable product identifier because this is a private ABI.
            state->kind = VPDeviceKindMagicMouse;
        } else {
            state->kind = VPDeviceKindExternalTrackpad;
        }
        (void)vp_get_family_id(device, &state->familyID);
    }

    pthread_mutex_lock(&vp_lock);
    vp_device_list = newDeviceList;
    memcpy(vp_devices, newDevices, sizeof(newDevices));
    vp_device_count = newDeviceCount;
    vp_stopping = false;
    pthread_mutex_unlock(&vp_lock);

    for (int32_t index = 0; index < newDeviceCount; index++) {
        vp_register_callback(newDevices[index].device, vp_on_touch_frame_legacy);
        vp_device_start(newDevices[index].device, 0);
    }

    pthread_mutex_lock(&vp_lock);
    snprintf(vp_status, sizeof(vp_status), "Touch driver active (legacy callback): %d device(s)", newDeviceCount);
    pthread_mutex_unlock(&vp_lock);
    const bool success = newDeviceCount > 0;
    return success;
}

bool VPStartTouchDriver(void) { return VPReloadTouchDevices(); }

void VPStopTouchDriver(void) {
    vp_quiesce_devices();
    pthread_mutex_lock(&vp_lock);
    // Keep a successfully loaded framework resident for process lifetime.
    // Private-framework callbacks may be queued after device stop; unloading
    // here would leave those callbacks executing unmapped code.
    snprintf(vp_status, sizeof(vp_status), "Touch driver stopped");
    pthread_mutex_unlock(&vp_lock);
}

const char *VPGetTouchDriverStatus(void) { return vp_status; }

bool VPCopyTouchDriverStatus(char *buffer, size_t bufferSize) {
    if (buffer == NULL || bufferSize == 0) return false;
    pthread_mutex_lock(&vp_lock);
    snprintf(buffer, bufferSize, "%s", vp_status);
    pthread_mutex_unlock(&vp_lock);
    return true;
}

int32_t VPGetTouchDeviceCount(void) {
    pthread_mutex_lock(&vp_lock);
    const int32_t result = vp_device_count;
    pthread_mutex_unlock(&vp_lock);
    return result;
}

int32_t VPGetConnectedMultitouchServiceCount(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    CFMutableDictionaryRef matching = IOServiceMatching("AppleMultitouchDevice");
    if (matching == NULL ||
        IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) != KERN_SUCCESS) {
        return -1;
    }
    int32_t count = 0;
    io_object_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        count++;
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return count;
}

bool VPCopyTouchDeviceInfo(int32_t index, VPDeviceInfo *outInfo) {
    if (outInfo == NULL) return false;
    pthread_mutex_lock(&vp_lock);
    if (index < 0 || index >= vp_device_count) {
        pthread_mutex_unlock(&vp_lock);
        return false;
    }
    const double now = vp_monotonic_seconds();
    const VPDeviceState *state = &vp_devices[index];
    *outInfo = (VPDeviceInfo){
        .token = (uintptr_t)state->device,
        .deviceID = state->deviceID,
        .kind = state->kind,
        .familyID = state->familyID,
        .sensorRows = state->rows,
        .sensorColumns = state->columns,
        .touchCount = state->touchCount,
        .lastFrameAgeSeconds = state->lastFrameAt > 0 ? now - state->lastFrameAt : -1,
        .callbackCount = state->rawCallbackCount,
        .rawTouchCount = state->rawSuppliedTouchCount,
        .stageMask = state->stageBitmask,
        .directionalDisplacementX = state->directionalDisplacementX,
        .directionalDisplacementY = state->directionalDisplacementY,
        .minDensity = state->trackedTouchCount > 0 ? state->touches[0].currentDensity : 0,
    };
    for (int32_t i = 1; i < state->trackedTouchCount; i++)
        if (state->touches[i].currentDensity < outInfo->minDensity) outInfo->minDensity = state->touches[i].currentDensity;
    if (!isfinite(outInfo->minDensity)) outInfo->minDensity = 0;
    pthread_mutex_unlock(&vp_lock);
    return true;
}

bool VPCopyTouchSnapshot(int32_t deviceIndex, VPTouchSnapshot *out) {
    if (!out) return false;
    const double now = vp_monotonic_seconds();
    pthread_mutex_lock(&vp_lock);
    if (deviceIndex < 0 || deviceIndex >= vp_device_count) { pthread_mutex_unlock(&vp_lock); return false; }
    VPDeviceState *s = &vp_devices[deviceIndex];
    *out = s->snapshot;
    out->deviceToken = (uintptr_t)s->device;
    out->frameAgeSeconds = now - s->lastFrameAt;
    out->newestTouchAgeSeconds = now - s->newestLandingAt;
    out->oldestTouchAgeSeconds = now - s->oldestLandingAt;
    out->maximumMovement = s->maximumMovement;
    pthread_mutex_unlock(&vp_lock);
    return true;
}

float VPMagicMouseRequiredDensity(float minimumDensity, float slowMinDensity,
                                  double fastLandingSeconds, double skewSeconds) {
    if (!isfinite(minimumDensity) || !isfinite(slowMinDensity) || !isfinite(fastLandingSeconds) ||
        !isfinite(skewSeconds) || fastLandingSeconds < 0 || skewSeconds < 0) return NAN;
    return skewSeconds <= fastLandingSeconds + 0.0000001 ? minimumDensity : fmaxf(minimumDensity, slowMinDensity);
}

bool VPConsumeEligibleGesture(
    int32_t magicMouseFingerCount, int32_t trackpadFingerCount,
    double freshChordWindowSeconds, double magicMouseFreshChordWindowSeconds,
    float maximumMovement,
    double maximumFrameAgeSeconds, bool trackpadEnabled,
    float magicMouseMinDensity, double maxLandingSkewSeconds, double fastLandingSeconds, float slowMinDensity, bool consume,
    VPGestureMatch *outMatch, VPMouseDecision *outDecision
) {
    if (!outMatch) return false;
    int32_t winner = -1;
    double winnerFrameAt = -1;
    int closestRank = -1;
    VPMouseDecision decision = {.deviceIndex = -1, .reason = VPDecisionTouchCount, .minDensity = 0};
    pthread_mutex_lock(&vp_lock);
    const double now = vp_monotonic_seconds();
    for (int32_t index = 0; index < vp_device_count; index++) {
        VPDeviceState *state = &vp_devices[index];
        bool mouse = state->kind == VPDeviceKindMagicMouse;
        bool pad = state->kind == VPDeviceKindBuiltInTrackpad || state->kind == VPDeviceKindExternalTrackpad;
        if (!mouse && !pad) continue;
        if (pad && !trackpadEnabled) continue;
        double frameAge = now - state->lastFrameAt;
        double newest = now - state->newestLandingAt, oldest = now - state->oldestLandingAt;
        float density = INFINITY;
        for (int32_t i = 0; i < state->trackedTouchCount; i++) {
            float d = state->touches[i].currentDensity;
            if (!isfinite(d)) { density = 0; break; }
            if (d < density) density = d;
        }
        if (!isfinite(density)) density = 0;
        const float need = VPMagicMouseRequiredDensity(magicMouseMinDensity, slowMinDensity, fastLandingSeconds, oldest - newest);
        VPGestureDecision reason = VPDecisionPassed;
        int rank = 6;
        if (state->touchCount != (mouse ? magicMouseFingerCount : trackpadFingerCount) ||
            state->touchCount <= 0 || (consume && state->consumed) || state->newestLandingAt <= 0 || state->oldestLandingAt <= 0) {
            reason = VPDecisionTouchCount; rank = 0;
        } else if (mouse && (!isfinite(maxLandingSkewSeconds) || maxLandingSkewSeconds <= 0 ||
                  oldest - newest > maxLandingSkewSeconds + 0.0000001)) {
            reason = VPDecisionLandingSkew; rank = 1;
        } else if (newest < 0 || oldest < 0 ||
                   oldest > (mouse ? magicMouseFreshChordWindowSeconds : freshChordWindowSeconds)) {
            reason = VPDecisionFreshWindow; rank = 2;
        } else if (state->maximumMovement > maximumMovement) {
            reason = VPDecisionMovement; rank = 3;
        } else if (frameAge < 0 || frameAge > maximumFrameAgeSeconds) {
            reason = VPDecisionFrameExpired; rank = 4;
        } else if (mouse && (!isfinite(need) || (need > 0 && density < need))) {
            reason = VPDecisionDensity; rank = 5;
        }
        if (mouse && (rank > closestRank ||
            (rank == closestRank && decision.deviceIndex >= 0 &&
             state->lastFrameAt > vp_devices[decision.deviceIndex].lastFrameAt))) {
            closestRank = rank;
            decision = (VPMouseDecision){
                .deviceIndex = index, .reason = reason, .minDensity = density,
                .requiredDensity = isfinite(need) ? need : -1,
                .skewSeconds = oldest - newest, .oldestAgeSeconds = oldest,
                .retriedWithoutLift = false, .snapshot = state->snapshot,
            };
            decision.snapshot.deviceToken = (uintptr_t)state->device;
            decision.snapshot.frameAgeSeconds = frameAge;
            decision.snapshot.newestTouchAgeSeconds = newest;
            decision.snapshot.oldestTouchAgeSeconds = oldest;
            decision.snapshot.maximumMovement = state->maximumMovement;
        }
        if (reason != VPDecisionPassed) continue;
        if (state->lastFrameAt > winnerFrameAt) { winner = index; winnerFrameAt = state->lastFrameAt; }
    }
    if (outDecision) *outDecision = decision;
    if (winner < 0) { pthread_mutex_unlock(&vp_lock); return false; }
    VPDeviceState *state = &vp_devices[winner];
    if (consume) state->consumed = true;
    *outMatch = (VPGestureMatch){(uintptr_t)state->device, state->kind, state->touchCount,
        now - state->newestLandingAt, now - state->oldestLandingAt, state->maximumMovement};
    pthread_mutex_unlock(&vp_lock);
    return true;
}

bool VPTestSetTouchDisplacement(
    VPDeviceKind kind,
    float displacementX,
    float displacementY
) {
    pthread_mutex_lock(&vp_lock);
    for (int32_t index = vp_device_count - 1; index >= 0; index--) {
        VPDeviceState *state = &vp_devices[index];
        if (state->kind != kind) continue;
        state->directionalDisplacementX = displacementX;
        state->directionalDisplacementY = displacementY;
        const float movement = sqrtf(
            displacementX * displacementX + displacementY * displacementY
        );
        if (movement > state->maximumMovement) state->maximumMovement = movement;
        pthread_mutex_unlock(&vp_lock);
        return true;
    }
    pthread_mutex_unlock(&vp_lock);
    return false;
}

bool VPTestResetTouchState(void) {
    pthread_mutex_lock(&vp_lock);
    if (vp_framework != NULL || vp_device_list != NULL || vp_stopping) {
        pthread_mutex_unlock(&vp_lock);
        return false;
    }
    memset(vp_devices, 0, sizeof(vp_devices));
    vp_device_count = 0;
    pthread_mutex_unlock(&vp_lock);
    return true;
}

bool VPTestInjectTouchState(
    VPDeviceKind kind,
    int32_t touchCount,
    double frameAgeSeconds,
    double newestTouchAgeSeconds,
    double oldestTouchAgeSeconds,
    float maximumMovement,
    float minDensity
) {
    if (touchCount < 0 || touchCount > VP_MAX_TOUCHES || frameAgeSeconds < 0 ||
        newestTouchAgeSeconds < 0 || oldestTouchAgeSeconds < newestTouchAgeSeconds) return false;
    const double now = vp_monotonic_seconds();
    pthread_mutex_lock(&vp_lock);
    if (vp_framework != NULL || vp_device_list != NULL || vp_stopping || vp_device_count >= VP_MAX_DEVICES) {
        pthread_mutex_unlock(&vp_lock);
        return false;
    }
    VPDeviceState *state = &vp_devices[vp_device_count++];
    memset(state, 0, sizeof(*state));
    state->device = (VPPrivateDeviceRef)(uintptr_t)(0xfeed0000u + (unsigned)vp_device_count);
    state->kind = kind;
    state->touchCount = touchCount;
    state->lastFrameAt = now - frameAgeSeconds;
    state->newestLandingAt = now - newestTouchAgeSeconds;
    state->oldestLandingAt = now - oldestTouchAgeSeconds;
    state->maximumMovement = maximumMovement;
    state->rawCallbackCount = 1;
    state->rawSuppliedTouchCount = touchCount;
    state->stageBitmask = 1u << 4;
    state->consumed = false;
    state->trackedTouchCount = touchCount;
    state->snapshot.count = touchCount < 6 ? touchCount : 6;
    for (int32_t i = 0; i < touchCount; i++) state->touches[i].currentDensity = minDensity;
    for (int32_t i = 0; i < state->snapshot.count; i++)
        state->snapshot.points[i] = (VPTouchSnapshotPoint){4, 0.4f, 0.6f, 0.1f, 0.05f, 0.02f, minDensity, false};
    pthread_mutex_unlock(&vp_lock);
    return true;
}

bool VPTestInjectTouchFrame(VPDeviceKind kind, const VPTouchSnapshotPoint *points, int32_t count) {
    if (!points || count < 0 || count > 6) return false;
    pthread_mutex_lock(&vp_lock);
    if (vp_framework || vp_device_list || vp_stopping || vp_device_count == 0 || vp_devices[vp_device_count - 1].kind != kind) {
        pthread_mutex_unlock(&vp_lock); return false;
    }
    VPPrivateDeviceRef device = vp_devices[vp_device_count - 1].device;
    pthread_mutex_unlock(&vp_lock);
    VPTouch raw[6] = {0};
    for (int i = 0; i < count; ++i) {
        raw[i].identifier = i + 1; raw[i].stage = points[i].stage;
        raw[i].normalized.position.x = points[i].x; raw[i].normalized.position.y = points[i].y;
        raw[i].majorAxis = points[i].major; raw[i].minorAxis = points[i].minor;
        raw[i].contactSize = points[i].size; raw[i].density = points[i].density;
    }
    vp_process_touch_frame(device, raw, (size_t)count, 0, 0);
    return true;
}
bool VPTestSetMinDensity(float minDensity) {
    pthread_mutex_lock(&vp_lock);
    if (vp_framework != NULL || vp_device_list != NULL || vp_device_count == 0) {
        pthread_mutex_unlock(&vp_lock); return false;
    }
    VPDeviceState *s = &vp_devices[vp_device_count - 1];
    for (int32_t i = 0; i < s->trackedTouchCount; i++) s->touches[i].currentDensity = minDensity;
    pthread_mutex_unlock(&vp_lock); return true;
}
