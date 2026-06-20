// CMIOScreenCaptureListener
//
// Goal: get past the "set the allow-property once, see nothing" failure mode by
// keeping a CoreMediaIO client RESIDENT. We:
//   1. Set kCMIOHardwarePropertyAllowScreenCaptureDevices (wired) and
//      kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices on the system object.
//   2. Register property listeners on the device list so the async
//      MobileDevice -> Valeria handshake driven by iOSScreenCaptureAssistant has a
//      live client to surface a muxed iPhone screen-capture device to.
//   3. Stay alive on a CFRunLoop, snapshotting CMIO + AVFoundation device sets and
//      printing diffs as the device transitions.
//
// Read-only-ish: the only writes are the two allow-properties on the local host's
// CMIO system object, which we restore to their prior values on exit.

#import <Foundation/Foundation.h>
#import <CoreMediaIO/CMIOHardware.h>
#import <AVFoundation/AVFoundation.h>

static const CMIOObjectID kSystem = kCMIOObjectSystemObject;

static void logLine(NSString *fmt, ...) {
    va_list args;
    va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSDate *now = [NSDate date];
    fprintf(stderr, "[%.3f] %s\n", now.timeIntervalSinceReferenceDate, s.UTF8String);
}

static NSString *fourCC(UInt32 code) {
    char c[5] = { (char)(code >> 24), (char)(code >> 16), (char)(code >> 8), (char)code, 0 };
    return [NSString stringWithUTF8String:c];
}

// --- system-object UInt32 allow-property get/set ---

static OSStatus getU32(UInt32 selector, UInt32 *out) {
    CMIOObjectPropertyAddress addr = {
        selector, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain
    };
    UInt32 size = sizeof(UInt32);
    return CMIOObjectGetPropertyData(kSystem, &addr, 0, NULL, size, &size, out);
}

static OSStatus setU32(UInt32 selector, UInt32 value) {
    CMIOObjectPropertyAddress addr = {
        selector, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain
    };
    return CMIOObjectSetPropertyData(kSystem, &addr, 0, NULL, sizeof(value), &value);
}

// --- device enumeration ---

static NSString *deviceStringProp(CMIOObjectID dev, UInt32 selector) {
    CMIOObjectPropertyAddress addr = {
        selector, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain
    };
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    OSStatus st = CMIOObjectGetPropertyData(dev, &addr, 0, NULL, size, &size, &value);
    if (st != noErr || value == NULL) return nil;
    return (__bridge_transfer NSString *)value;
}

static NSArray<NSNumber *> *cmioDevices(void) {
    CMIOObjectPropertyAddress addr = {
        kCMIOHardwarePropertyDevices,
        kCMIOObjectPropertyScopeGlobal,
        kCMIOObjectPropertyElementMain
    };
    UInt32 dataSize = 0;
    if (CMIOObjectGetPropertyDataSize(kSystem, &addr, 0, NULL, &dataSize) != noErr) return @[];
    UInt32 count = dataSize / sizeof(CMIOObjectID);
    if (count == 0) return @[];
    CMIOObjectID *ids = calloc(count, sizeof(CMIOObjectID));
    UInt32 used = dataSize;
    if (CMIOObjectGetPropertyData(kSystem, &addr, 0, NULL, dataSize, &used, ids) != noErr) {
        free(ids);
        return @[];
    }
    NSMutableArray *out = [NSMutableArray array];
    for (UInt32 i = 0; i < used / sizeof(CMIOObjectID); i++) {
        [out addObject:@(ids[i])];
    }
    free(ids);
    return out;
}

static NSString *describeCMIODevice(CMIOObjectID dev) {
    NSString *name = deviceStringProp(dev, kCMIOObjectPropertyName);
    NSString *uid = deviceStringProp(dev, kCMIODevicePropertyDeviceUID);
    NSString *model = deviceStringProp(dev, kCMIODevicePropertyModelUID);
    return [NSString stringWithFormat:@"id=%u name=%@ uid=%@ model=%@",
            dev, name ?: @"?", uid ?: @"?", model ?: @"?"];
}

static NSString *avSnapshot(void) {
    NSMutableArray *lines = [NSMutableArray array];
    NSArray<AVCaptureDeviceType> *types = @[
        AVCaptureDeviceTypeExternal,
        AVCaptureDeviceTypeBuiltInWideAngleCamera,
        AVCaptureDeviceTypeMicrophone,
    ];
    AVCaptureDeviceDiscoverySession *vs =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:types
                                                              mediaType:AVMediaTypeVideo
                                                               position:AVCaptureDevicePositionUnspecified];
    for (AVCaptureDevice *d in vs.devices) {
        [lines addObject:[NSString stringWithFormat:@"  AV-video: %@ [%@] uid=%@",
                          d.localizedName, d.modelID, d.uniqueID]];
    }
    AVCaptureDeviceDiscoverySession *muxed =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal]
                                                              mediaType:AVMediaTypeMuxed
                                                               position:AVCaptureDevicePositionUnspecified];
    for (AVCaptureDevice *d in muxed.devices) {
        [lines addObject:[NSString stringWithFormat:@"  AV-MUXED: %@ [%@] uid=%@",
                          d.localizedName, d.modelID, d.uniqueID]];
    }
    if (lines.count == 0) return @"  (no AV capture devices)";
    return [lines componentsJoinedByString:@"\n"];
}

static void snapshot(NSString *tag) {
    NSArray<NSNumber *> *devs = cmioDevices();
    logLine(@"--- snapshot: %@ (CMIO devices=%lu) ---", tag, (unsigned long)devs.count);
    for (NSNumber *d in devs) {
        logLine(@"  CMIO: %@", describeCMIODevice((CMIOObjectID)d.unsignedIntValue));
    }
    logLine(@"%@", avSnapshot());
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSTimeInterval runSeconds = (argc > 1) ? atof(argv[1]) : 45.0;

        UInt32 priorWired = 0, priorWireless = 0;
        OSStatus gw = getU32(kCMIOHardwarePropertyAllowScreenCaptureDevices, &priorWired);
        OSStatus gl = getU32(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, &priorWireless);
        logLine(@"prior allow: wired(%@)=%d[st=%d] wireless(%@)=%d[st=%d]",
                fourCC(kCMIOHardwarePropertyAllowScreenCaptureDevices), priorWired, gw,
                fourCC(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices), priorWireless, gl);

        OSStatus sw = setU32(kCMIOHardwarePropertyAllowScreenCaptureDevices, 1);
        OSStatus sl = setU32(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, 1);
        logLine(@"set allow=1: wired st=%d wireless st=%d", sw, sl);

        snapshot(@"after-set");

        // Listen for device-list and allow-property changes so we observe the
        // assistant surfacing the screen-capture device asynchronously.
        dispatch_queue_t q = dispatch_queue_create("cmio.listener", DISPATCH_QUEUE_SERIAL);
        CMIOObjectPropertyAddress devAddr = {
            kCMIOHardwarePropertyDevices,
            kCMIOObjectPropertyScopeGlobal,
            kCMIOObjectPropertyElementMain
        };
        CMIOObjectAddPropertyListenerBlock(kSystem, &devAddr, q,
            ^(UInt32 n, const CMIOObjectPropertyAddress addrs[]) {
                (void)n; (void)addrs;
                snapshot(@"device-list-changed");
            });

        logLine(@"resident for %.0fs; assistant handshake may surface a device...", runSeconds);

        // Periodic re-snapshot in case a change arrives without a listener callback.
        __block int ticks = 0;
        int maxTicks = (int)(runSeconds / 5.0);
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                                  5 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            ticks++;
            snapshot([NSString stringWithFormat:@"tick-%d", ticks]);
            if (ticks >= maxTicks) {
                CFRunLoopStop(CFRunLoopGetMain());
            }
        });
        dispatch_resume(timer);

        CFRunLoopRun();

        // Restore prior allow values to leave the host as we found it.
        setU32(kCMIOHardwarePropertyAllowScreenCaptureDevices, priorWired);
        setU32(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, priorWireless);
        logLine(@"restored allow: wired=%d wireless=%d", priorWired, priorWireless);
        snapshot(@"final");
    }
    return 0;
}
