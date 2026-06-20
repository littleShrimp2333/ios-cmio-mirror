// bridge_darwin.m — Objective-C implementation of the CMIO capture bridge.
//
// Proven recipe (see docs/ios-host-screen-capture-options.md):
//   1. Set both CMIO allow-gates on the system object.
//   2. Read the CMIO HAL device list directly + pump the main runloop while
//      waiting — this pokes the DAL plugin / iOSScreenCaptureAssistant into
//      surfacing the muxed AVFoundation device(s).
//   3. For recording: open an AVCaptureSession against the selected device,
//      disable audio connection when video-only, record until recordedDuration
//      reaches target, tear down, restore allow-gates.
//
// Multi-device: each connected iPhone surfaces as a separate AVCaptureDevice
// (different uniqueID).  cmio_device_count/cmio_device_info list them;
// cmio_record selects by uniqueID.

#import "bridge.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreMediaIO/CMIOHardware.h>
#import <Foundation/Foundation.h>

static const CMIOObjectID kSys = kCMIOObjectSystemObject;

// ---- gate helpers ----

static OSStatus gate_get(UInt32 sel, UInt32 *v) {
    CMIOObjectPropertyAddress a = {sel, kCMIOObjectPropertyScopeGlobal,
                                   kCMIOObjectPropertyElementMain};
    UInt32 sz = sizeof(UInt32);
    return CMIOObjectGetPropertyData(kSys, &a, 0, NULL, sz, &sz, v);
}
static OSStatus gate_set(UInt32 sel, UInt32 v) {
    CMIOObjectPropertyAddress a = {sel, kCMIOObjectPropertyScopeGlobal,
                                   kCMIOObjectPropertyElementMain};
    return CMIOObjectSetPropertyData(kSys, &a, 0, NULL, sizeof(v), &v);
}

static UInt32 prior_wired = 0, prior_wireless = 0;

static void gates_on(void) {
    gate_get(kCMIOHardwarePropertyAllowScreenCaptureDevices, &prior_wired);
    gate_get(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices,
             &prior_wireless);
    gate_set(kCMIOHardwarePropertyAllowScreenCaptureDevices, 1);
    gate_set(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, 1);
}
static void gates_off(void) {
    gate_set(kCMIOHardwarePropertyAllowScreenCaptureDevices, prior_wired);
    gate_set(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices,
             prior_wireless);
}

// Poke the CMIO HAL so the DAL plugin runs its assistant handshake.
static void list_read(void) {
    CMIOObjectPropertyAddress a = {kCMIOHardwarePropertyDevices,
                                   kCMIOObjectPropertyScopeGlobal,
                                   kCMIOObjectPropertyElementMain};
    UInt32 sz = 0;
    if (CMIOObjectGetPropertyDataSize(kSys, &a, 0, NULL, &sz) != noErr || !sz)
        return;
    UInt32 n = sz / sizeof(CMIOObjectID), used = sz;
    CMIOObjectID *ids = calloc(n, sizeof(CMIOObjectID));
    CMIOObjectGetPropertyData(kSys, &a, 0, NULL, sz, &used, ids);
    free(ids);
}

static NSArray<AVCaptureDevice *> *muxed_devices(void) {
    AVCaptureDeviceDiscoverySession *ds =
        [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeExternal ]
                                 mediaType:AVMediaTypeMuxed
                                  position:AVCaptureDevicePositionUnspecified];
    return ds.devices;
}

// TCC auth — prompt if not determined.
static void ensure_auth(void) {
    AVAuthorizationStatus as =
        [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (as == AVAuthorizationStatusNotDetermined) {
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [AVCaptureDevice
            requestAccessForMediaType:AVMediaTypeVideo
                    completionHandler:^(BOOL g) {
                      (void)g;
                      dispatch_semaphore_signal(sem);
                    }];
        dispatch_semaphore_wait(sem,
                                dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    }
}

// Wait up to 25 s for at least one muxed device to surface.  Returns the device
// list (may be empty).
static NSArray<AVCaptureDevice *> *wait_for_devices(void) {
    NSArray<AVCaptureDevice *> *devs = nil;
    for (int i = 0; i < 50; i++) {
        list_read();               // poke the DAL plugin
        devs = muxed_devices();    // check AVFoundation
        if (devs.count > 0) break;
        [[NSRunLoop currentRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    }
    return devs ?: @[];
}

static AVCaptureDevice *find_by_uniqueID(NSString *uid) {
    if (uid.length == 0) return muxed_devices().firstObject;
    for (AVCaptureDevice *d in muxed_devices()) {
        if ([d.uniqueID isEqualToString:uid]) return d;
    }
    return nil;
}

// ---- helpers ----

static char *copy_ns_err(NSError *e) {
    NSString *s = e ? e.localizedDescription : @"unknown error";
    return strdup(s.UTF8String);
}
static char *copy_str(const char *s) { return strdup(s); }

// ---- recording delegate ----

@interface RecDelegate : NSObject <AVCaptureFileOutputRecordingDelegate>
@property(atomic) BOOL finished;
@property(atomic, strong) NSError *error;
@end
@implementation RecDelegate
- (void)captureOutput:(AVCaptureFileOutput *)o
    didStartRecordingToOutputFileAtURL:(NSURL *)url
                       fromConnections:(NSArray *)cs {
    (void)o; (void)url; (void)cs;
}
- (void)captureOutput:(AVCaptureFileOutput *)o
    didFinishRecordingToOutputFileAtURL:(NSURL *)url
                        fromConnections:(NSArray *)cs
                                  error:(NSError *)e {
    (void)o; (void)url; (void)cs;
    self.error = e;
    self.finished = YES;
}
@end

// ---- device discovery API ----

int cmio_list_devices(char **json) {
    @autoreleasepool {
        gates_on();
        ensure_auth();
        NSArray<AVCaptureDevice *> *devs = wait_for_devices();
        NSMutableArray *list = [NSMutableArray array];
        for (AVCaptureDevice *d in devs) {
            [list addObject:@{
                @"uniqueID": d.uniqueID ?: @"",
                @"name": d.localizedName ?: @"",
                @"modelID": d.modelID ?: @"",
            }];
        }
        NSData *data =
            [NSJSONSerialization dataWithJSONObject:list options:0 error:nil];
        NSString *s =
            [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        *json = strdup(s.UTF8String);
        gates_off();
        return (int)devs.count;
    }
}

// ---- recording API ----

int cmio_record(const char *uniqueID, const char *outputPath, double duration,
                int captureAudio, char **errMsg) {
    @autoreleasepool {
        NSString *uid =
            uniqueID ? [NSString stringWithUTF8String:uniqueID] : @"";

        gates_on();
        ensure_auth();

        AVCaptureDevice *dev = nil;
        for (int i = 0; i < 40 && dev == nil; i++) {
            list_read();
            dev = find_by_uniqueID(uid);
            if (!dev) {
                [[NSRunLoop currentRunLoop]
                    runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
            }
        }
        if (!dev) {
            gates_off();
            *errMsg = copy_str("muxed iOS device did not surface (is iPhone "
                               "paired/connected?)");
            return 2;
        }

        NSError *e = nil;
        AVCaptureDeviceInput *input =
            [AVCaptureDeviceInput deviceInputWithDevice:dev error:&e];
        if (!input) {
            gates_off();
            *errMsg = copy_ns_err(e);
            return 3;
        }

        AVCaptureSession *sess = [[AVCaptureSession alloc] init];
        [sess beginConfiguration];
        if (![sess canAddInput:input]) {
            [sess commitConfiguration];
            gates_off();
            *errMsg = copy_str("cannot add muxed device input to session");
            return 4;
        }
        [sess addInput:input];

        AVCaptureMovieFileOutput *movie =
            [[AVCaptureMovieFileOutput alloc] init];
        if (![sess canAddOutput:movie]) {
            [sess commitConfiguration];
            gates_off();
            *errMsg = copy_str("cannot add movie output to session");
            return 5;
        }
        [sess addOutput:movie];

        if (!captureAudio) {
            for (AVCaptureConnection *c in movie.connections) {
                for (AVCaptureInputPort *p in c.inputPorts) {
                    if ([p.mediaType isEqualToString:AVMediaTypeAudio])
                        c.enabled = NO;
                }
            }
        }
        [sess commitConfiguration];

        RecDelegate *del = [[RecDelegate alloc] init];
        [[NSFileManager defaultManager]
            removeItemAtPath:[NSString stringWithUTF8String:outputPath]
                       error:nil];
        [sess startRunning];

        [movie startRecordingToOutputFileURL:
                   [NSURL fileURLWithPath:[NSString
                                              stringWithUTF8String:outputPath]]
                             recordingDelegate:del];

        NSDate *deadline =
            [NSDate dateWithTimeIntervalSinceNow:(duration + 45)];
        BOOL stopped = NO;
        while (!del.finished && [deadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop]
                runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
            if (!stopped) {
                Float64 rec = CMTimeGetSeconds(movie.recordedDuration);
                if (rec >= duration) {
                    stopped = YES;
                    [movie stopRecording];
                }
            }
        }

        [sess stopRunning];
        gates_off();

        if (del.error) {
            *errMsg = copy_ns_err(del.error);
            return 6;
        }
        return 0;
    }
}

void cmio_free_str(char *s) { free(s); }
