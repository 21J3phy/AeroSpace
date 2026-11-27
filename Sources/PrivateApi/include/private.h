#ifndef private_header_h
#define private_header_h

#import <ApplicationServices/ApplicationServices.h>

// Potential alternative 1?
// func allWindowsOnCurrentMacOsSpace() {
//     let options = CGWindowListOption(arrayLiteral: .excludeDesktopElements, .optionOnScreenOnly)
//     let windowsListInfo = CGWindowListCopyWindowInfo(options, CGWindowID(0))
//     let infoList = windowsListInfo as! [[String:Any]]
//     let windows = infoList.filter { $0["kCGWindowLayer"] as! Int == 0 }
//     print(windows.count)
//     for window in windows {
//             print(window)
//             print("Name: \(window["kCGWindowOwnerName"].unsafelyUnwrapped)")
//             print("PID: \(window["kCGWindowOwnerPID"].unsafelyUnwrapped)")
//             print("window ID: \(window["kCGWindowNumber"])")
//             print("---")
//     }
// }
//
// Alternative 2:
// @_silgen_name("_AXUIElementGetWindow")
// @discardableResult
// func _AXUIElementGetWindow(_ axUiElement: AXUIElement, _ id: inout CGWindowID) -> AXError
AXError _AXUIElementGetWindow(AXUIElementRef element, uint32_t *identifier);

// ===== Fork addition: raw trackpad touches (MultitouchSupport.framework, loaded lazily with dlopen) =====

typedef struct {
    float x; // Normalized [0, 1]. Left to right
    float y; // Normalized [0, 1]. Bottom to top
} AeroTouch;

// Called on a MultitouchSupport thread for every frame. `touches` contains only the fingers that touch the surface
typedef void (*AeroTouchFrameCallback)(const AeroTouch *touches, int32_t count, double timestamp);

// Starts listening on all multitouch devices. Returns the number of devices that were started
int32_t aeroMultitouchStart(AeroTouchFrameCallback callback);
void aeroMultitouchStop(void);
// Number of multitouch devices currently known to the system. -1 if the framework is unavailable
int32_t aeroMultitouchDeviceCount(void);

#endif
