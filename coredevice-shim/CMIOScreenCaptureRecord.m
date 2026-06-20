// CMIOScreenCaptureRecord
//
// Records the muxed iOS screen-capture device to a QuickTime .mov for a fixed
// duration. Same activation recipe as CMIOScreenCaptureFirstFrame (allow-gates,
// direct HAL read, runloop pumped while waiting for the device to surface), but
// uses AVCaptureMovieFileOutput so video+audio are muxed to a playable file with
// no manual sample-buffer handling.
//
// Usage: CMIOScreenCaptureRecord <seconds> <output.mov> [video|av]
//   video (default): video track only — does NOT capture the device audio
//     channel, so on-device playback in other apps keeps running.
//   av: also record the muxed audio track (this takes over the device audio
//     channel, interrupting other apps' playback — the old behavior).

#import <Foundation/Foundation.h>
#import <CoreMediaIO/CMIOHardware.h>
#import <AVFoundation/AVFoundation.h>

static const CMIOObjectID kSystem = kCMIOObjectSystemObject;

static void logLine(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    fprintf(stderr, "[%.3f] %s\n", [NSDate date].timeIntervalSinceReferenceDate, s.UTF8String);
}

static OSStatus getU32(UInt32 sel, UInt32 *out) {
    CMIOObjectPropertyAddress a = { sel, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
    UInt32 size = sizeof(UInt32);
    return CMIOObjectGetPropertyData(kSystem, &a, 0, NULL, size, &size, out);
}
static OSStatus setU32(UInt32 sel, UInt32 v) {
    CMIOObjectPropertyAddress a = { sel, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain };
    return CMIOObjectSetPropertyData(kSystem, &a, 0, NULL, sizeof(v), &v);
}

// Direct CMIO HAL device-list read pokes the DAL plugin to surface the device.
static AVCaptureDevice *findMuxedDevice(void) {
    CMIOObjectPropertyAddress a = {
        kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain
    };
    UInt32 sz = 0;
    if (CMIOObjectGetPropertyDataSize(kSystem, &a, 0, NULL, &sz) == noErr && sz > 0) {
        UInt32 used = sz;
        CMIOObjectID *ids = calloc(sz / sizeof(CMIOObjectID), sizeof(CMIOObjectID));
        CMIOObjectGetPropertyData(kSystem, &a, 0, NULL, sz, &used, ids);
        free(ids);
    }
    AVCaptureDeviceDiscoverySession *muxed =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal]
                                                              mediaType:AVMediaTypeMuxed
                                                               position:AVCaptureDevicePositionUnspecified];
    return muxed.devices.firstObject;
}

@interface RecDelegate : NSObject <AVCaptureFileOutputRecordingDelegate>
@property (atomic) BOOL finished;
@property (atomic) BOOL started;
@property (atomic, strong) NSError *error;
@end
@implementation RecDelegate
- (void)captureOutput:(AVCaptureFileOutput *)output
  didStartRecordingToOutputFileAtURL:(NSURL *)url
                     fromConnections:(NSArray *)conns {
    self.started = YES;
    logLine(@"recording started -> %@", url.path);
}
- (void)captureOutput:(AVCaptureFileOutput *)output
  didFinishRecordingToOutputFileAtURL:(NSURL *)url
                      fromConnections:(NSArray *)conns
                                error:(NSError *)error {
    self.error = error;
    self.finished = YES;
    logLine(@"recording finished (error=%@)", error ?: @"none");
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSTimeInterval seconds = (argc > 1) ? atof(argv[1]) : 10.0;
        NSString *outPath = (argc > 2)
            ? [NSString stringWithUTF8String:argv[2]]
            : @"/tmp/cmio-capture.mov";
        // Default to video-only so we don't seize the device audio channel.
        BOOL captureAudio = (argc > 3) && (strcmp(argv[3], "av") == 0);
        [[NSFileManager defaultManager] removeItemAtPath:outPath error:nil];

        UInt32 priorWired = 0, priorWireless = 0;
        getU32(kCMIOHardwarePropertyAllowScreenCaptureDevices, &priorWired);
        getU32(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, &priorWireless);
        setU32(kCMIOHardwarePropertyAllowScreenCaptureDevices, 1);
        setU32(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, 1);

        AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        if (st == AVAuthorizationStatusNotDetermined) {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                     completionHandler:^(BOOL g) { dispatch_semaphore_signal(sem); }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        }

        // Pump the runloop while waiting so the HAL completes its assistant connection.
        AVCaptureDevice *dev = nil;
        for (int i = 0; i < 30 && dev == nil; i++) {
            dev = findMuxedDevice();
            if (!dev) [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
        }
        if (!dev) {
            logLine(@"no muxed iOS device surfaced; aborting");
            setU32(kCMIOHardwarePropertyAllowScreenCaptureDevices, priorWired);
            setU32(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, priorWireless);
            return 2;
        }
        logLine(@"muxed device: %@ [%@] uid=%@", dev.localizedName, dev.modelID, dev.uniqueID);

        NSError *err = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:dev error:&err];
        if (!input) { logLine(@"deviceInput failed: %@", err); return 1; }

        AVCaptureSession *session = [[AVCaptureSession alloc] init];
        [session beginConfiguration];
        if (![session canAddInput:input]) { logLine(@"cannot add input"); return 1; }
        [session addInput:input];

        AVCaptureMovieFileOutput *movie = [[AVCaptureMovieFileOutput alloc] init];
        if (![session canAddOutput:movie]) { logLine(@"cannot add movie output"); return 1; }
        [session addOutput:movie];

        if (!captureAudio) {
            // Disable every audio connection on the movie output so the bridge is
            // not asked for an audio track. The muxed iOS device exposes audio +
            // video; we keep only video.
            for (AVCaptureConnection *c in movie.connections) {
                BOOL hasAudio = NO;
                for (AVCaptureInputPort *p in c.inputPorts) {
                    if ([p.mediaType isEqualToString:AVMediaTypeAudio]) { hasAudio = YES; break; }
                }
                if (hasAudio) { c.enabled = NO; }
            }
            logLine(@"audio capture disabled (video-only); device audio channel left free");
        } else {
            logLine(@"recording audio+video (device audio channel will be taken over)");
        }

        [session commitConfiguration];

        RecDelegate *del = [[RecDelegate alloc] init];
        [session startRunning];
        logLine(@"session running=%d; recording %.0fs...", session.isRunning, seconds);

        [movie startRecordingToOutputFileURL:[NSURL fileURLWithPath:outPath] recordingDelegate:del];

        // Stop based on actual recorded media duration, not wall clock — the bridge
        // has a few seconds of warmup before frames flow, so a wall-clock timer
        // would cut the clip short.
        NSDate *safetyDeadline = [NSDate dateWithTimeIntervalSinceNow:seconds + 30];
        __block BOOL stopRequested = NO;
        while (!del.finished && [safetyDeadline timeIntervalSinceNow] > 0) {
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.25]];
            if (!stopRequested) {
                Float64 recorded = CMTimeGetSeconds(movie.recordedDuration);
                if (recorded >= seconds) {
                    stopRequested = YES;
                    logLine(@"recorded %.2fs of media; stopping", recorded);
                    [movie stopRecording];
                }
            }
        }

        [session stopRunning];
        setU32(kCMIOHardwarePropertyAllowScreenCaptureDevices, priorWired);
        setU32(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, priorWireless);

        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:outPath error:nil];
        logLine(@"=== wrote %@ (%@ bytes) ===", outPath, attrs[NSFileSize] ?: @"0");
    }
    return 0;
}
