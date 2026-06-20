// CMIODeviceProbe — enumerate the muxed iOS device's streams and properties.
//
// Goal: find a CMIO-level lever to capture video without seizing the device
// audio channel. We list the device's streams (with media type / direction),
// and probe a set of device + stream properties for settability.
//
// Usage: CMIODeviceProbe

#import <Foundation/Foundation.h>
#import <CoreMediaIO/CMIOHardware.h>

static const CMIOObjectID kSystem = kCMIOObjectSystemObject;

static void p(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a]; va_end(a);
    fprintf(stdout, "%s\n", s.UTF8String);
}
static NSString *fcc(UInt32 c) {
    char b[5] = {(char)(c>>24),(char)(c>>16),(char)(c>>8),(char)c,0};
    return [NSString stringWithUTF8String:b];
}
static OSStatus setU32(UInt32 sel, UInt32 v) {
    CMIOObjectPropertyAddress a = { sel, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
    return CMIOObjectSetPropertyData(kSystem, &a, 0, NULL, sizeof(v), &v);
}

static NSString *objName(CMIOObjectID o) {
    CMIOObjectPropertyAddress a = { kCMIOObjectPropertyName, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
    CFStringRef v = NULL; UInt32 sz = sizeof(v);
    if (CMIOObjectGetPropertyData(o, &a, 0, NULL, sz, &sz, &v) == noErr && v)
        return (__bridge_transfer NSString *)v;
    return @"?";
}

static void dumpStreamProps(CMIOObjectID stream) {
    struct { UInt32 sel; const char *name; } props[] = {
        { kCMIOStreamPropertyDirection, "Direction(0=out,1=in)" },
        { kCMIOStreamPropertyTerminalType, "TerminalType" },
        { kCMIOStreamPropertyStartingChannel, "StartingChannel" },
        { kCMIOStreamPropertyLatency, "Latency" },
    };
    for (int i = 0; i < 4; i++) {
        CMIOObjectPropertyAddress a = { props[i].sel, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
        UInt32 v = 0, sz = sizeof(v);
        OSStatus st = CMIOObjectGetPropertyData(stream, &a, 0, NULL, sz, &sz, &v);
        if (st == noErr) p(@"      %s = %u", props[i].name, v);
    }
    // Format description -> media type tells us audio vs video stream.
    CMIOObjectPropertyAddress fa = { kCMIOStreamPropertyFormatDescription, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
    CMFormatDescriptionRef fd = NULL; UInt32 fsz = sizeof(fd);
    if (CMIOObjectGetPropertyData(stream, &fa, 0, NULL, fsz, &fsz, &fd) == noErr && fd) {
        CMMediaType mt = CMFormatDescriptionGetMediaType(fd);
        p(@"      MediaType = %@", fcc(mt));
        CFRelease(fd);
    }
}

static NSArray<NSNumber *> *deviceStreams(CMIOObjectID dev, UInt32 scope) {
    CMIOObjectPropertyAddress a = { kCMIODevicePropertyStreams, scope, kCMIOObjectPropertyElementMain };
    UInt32 sz = 0;
    if (CMIOObjectGetPropertyDataSize(dev, &a, 0, NULL, &sz) != noErr || sz == 0) return @[];
    UInt32 n = sz / sizeof(CMIOObjectID), used = sz;
    CMIOObjectID *ids = calloc(n, sizeof(CMIOObjectID));
    CMIOObjectGetPropertyData(dev, &a, 0, NULL, sz, &used, ids);
    NSMutableArray *out = [NSMutableArray array];
    for (UInt32 i = 0; i < used / sizeof(CMIOObjectID); i++) [out addObject:@(ids[i])];
    free(ids);
    return out;
}

static void probeDeviceProp(CMIOObjectID dev, UInt32 sel, const char *name) {
    CMIOObjectPropertyAddress a = { sel, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
    Boolean settable = false;
    Boolean has = CMIOObjectHasProperty(dev, &a);
    OSStatus stSet = CMIOObjectIsPropertySettable(dev, &a, &settable);
    UInt32 v = 0, sz = sizeof(v);
    OSStatus stGet = CMIOObjectGetPropertyData(dev, &a, 0, NULL, sz, &sz, &v);
    p(@"    %s [%@]: has=%d settable=%d(st=%d) get=%d val=%u",
      name, fcc(sel), has, settable, stSet, stGet, (stGet==noErr?v:0));
}

int main(void) {
    @autoreleasepool {
        setU32(kCMIOHardwarePropertyAllowScreenCaptureDevices, 1);
        setU32(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, 1);

        // poke + let device surface
        CMIOObjectPropertyAddress da = { kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
        for (int i = 0; i < 30; i++) {
            UInt32 sz = 0; CMIOObjectGetPropertyDataSize(kSystem, &da, 0, NULL, &sz);
            if (sz) { UInt32 used=sz; CMIOObjectID *t=calloc(sz/4,4); CMIOObjectGetPropertyData(kSystem,&da,0,NULL,sz,&used,t); free(t); }
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.3]];
            // find the iOS Device
            UInt32 dsz=0; CMIOObjectGetPropertyDataSize(kSystem,&da,0,NULL,&dsz);
            UInt32 used=dsz; CMIOObjectID *ids=calloc(dsz/4,4);
            CMIOObjectGetPropertyData(kSystem,&da,0,NULL,dsz,&used,ids);
            CMIOObjectID target = 0;
            for (UInt32 k=0;k<used/4;k++){ if ([objName(ids[k]) length] && [[objName(ids[k]) lowercaseString] rangeOfString:@"iphone"].location != NSNotFound) {
                // prefer model "iOS Device"
                CMIOObjectPropertyAddress ma={kCMIODevicePropertyModelUID,kCMIOObjectPropertyScopeGlobal,kCMIOObjectPropertyElementMain};
                CFStringRef m=NULL; UInt32 msz=sizeof(m);
                if (CMIOObjectGetPropertyData(ids[k],&ma,0,NULL,msz,&msz,&m)==noErr && m){
                    NSString *ms=(__bridge_transfer NSString*)m;
                    if ([ms isEqualToString:@"iOS Device"]) target = ids[k];
                }
            }}
            free(ids);
            if (target) {
                p(@"=== muxed device id=%u name=%@ ===", target, objName(target));
                p(@"  -- device properties --");
                probeDeviceProp(target, kCMIODevicePropertyDeviceIsRunning, "DeviceIsRunning");
                probeDeviceProp(target, kCMIODevicePropertyDeviceIsRunningSomewhere, "RunningSomewhere");
                probeDeviceProp(target, 'hsme', "ExcludeNonDALAccess?");
                probeDeviceProp(target, kCMIODevicePropertyDeviceMaster, "DeviceMaster");
                // enumerate streams for input scope
                NSArray *inS = deviceStreams(target, kCMIODevicePropertyScopeInput);
                NSArray *gS  = deviceStreams(target, kCMIOObjectPropertyScopeGlobal);
                p(@"  -- streams: global=%lu input=%lu --", (unsigned long)gS.count, (unsigned long)inS.count);
                NSArray *all = gS.count ? gS : inS;
                for (NSNumber *sn in all) {
                    CMIOObjectID s = (CMIOObjectID)sn.unsignedIntValue;
                    p(@"    stream id=%u name=%@", s, objName(s));
                    dumpStreamProps(s);
                }
                return 0;
            }
        }
        p(@"muxed device did not surface");
    }
    return 2;
}
