// Fork addition. Thin wrapper around the private MultitouchSupport.framework.
// The framework is loaded with dlopen so that the build doesn't need private framework linker flags
#import "private.h"
#import <CoreFoundation/CoreFoundation.h>
#import <dlfcn.h>
#import <stdbool.h>

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t identifier;
    int32_t state;
    int32_t fingerId;
    int32_t handId;
    MTVector normalized;
    float size;
    int32_t zero1;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector mm;
    int32_t zero2[2];
    float density;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(MTDeviceRef, MTTouch *, int, double, int);

static CFArrayRef (*mtDeviceCreateList)(void) = NULL;
static void (*mtRegisterContactFrameCallback)(MTDeviceRef, MTContactCallbackFunction) = NULL;
static void (*mtUnregisterContactFrameCallback)(MTDeviceRef, MTContactCallbackFunction) = NULL;
static int (*mtDeviceStart)(MTDeviceRef, int) = NULL;
static int (*mtDeviceStop)(MTDeviceRef) = NULL;

static AeroTouchFrameCallback userCallback = NULL;
static CFArrayRef startedDevices = NULL;

static bool loadFramework(void) {
    static bool attempted = false;
    static bool loaded = false;
    if (attempted) return loaded;
    attempted = true;
    void *handle = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY);
    if (!handle) return false;
    mtDeviceCreateList = dlsym(handle, "MTDeviceCreateList");
    mtRegisterContactFrameCallback = dlsym(handle, "MTRegisterContactFrameCallback");
    mtUnregisterContactFrameCallback = dlsym(handle, "MTUnregisterContactFrameCallback");
    mtDeviceStart = dlsym(handle, "MTDeviceStart");
    mtDeviceStop = dlsym(handle, "MTDeviceStop");
    loaded = mtDeviceCreateList && mtRegisterContactFrameCallback && mtUnregisterContactFrameCallback && mtDeviceStart && mtDeviceStop;
    return loaded;
}

static int contactFrameCallback(MTDeviceRef device, MTTouch *touches, int count, double timestamp, int frame) {
    AeroTouchFrameCallback callback = userCallback;
    if (!callback) return 0;
    enum { maxTouches = 16 };
    AeroTouch out[maxTouches];
    int32_t outCount = 0;
    for (int i = 0; i < count && outCount < maxTouches; i++) {
        // 4 = finger has just touched the surface, 5 = finger keeps touching. Other states are hovering and lifting
        if (touches[i].state == 4 || touches[i].state == 5) {
            out[outCount].x = touches[i].normalized.position.x;
            out[outCount].y = touches[i].normalized.position.y;
            outCount++;
        }
    }
    callback(out, outCount, timestamp);
    return 0;
}

int32_t aeroMultitouchDeviceCount(void) {
    if (!loadFramework()) return -1;
    CFArrayRef devices = mtDeviceCreateList();
    if (!devices) return 0;
    int32_t count = (int32_t)CFArrayGetCount(devices);
    CFRelease(devices);
    return count;
}

void aeroMultitouchStop(void) {
    if (!startedDevices) return;
    for (CFIndex i = 0; i < CFArrayGetCount(startedDevices); i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(startedDevices, i);
        mtUnregisterContactFrameCallback(device, contactFrameCallback);
        mtDeviceStop(device);
    }
    CFRelease(startedDevices);
    startedDevices = NULL;
    userCallback = NULL;
}

int32_t aeroMultitouchStart(AeroTouchFrameCallback callback) {
    if (!loadFramework()) return 0;
    aeroMultitouchStop();
    CFArrayRef devices = mtDeviceCreateList();
    if (!devices) return 0;
    userCallback = callback;
    for (CFIndex i = 0; i < CFArrayGetCount(devices); i++) {
        MTDeviceRef device = (MTDeviceRef)CFArrayGetValueAtIndex(devices, i);
        mtRegisterContactFrameCallback(device, contactFrameCallback);
        mtDeviceStart(device, 0);
    }
    startedDevices = devices;
    return (int32_t)CFArrayGetCount(devices);
}
