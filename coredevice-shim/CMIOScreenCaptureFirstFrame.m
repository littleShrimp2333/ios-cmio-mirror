// CMIOScreenCaptureFirstFrame
//
// Pushes the verified "muxed iOS Device appears" result one step further: open an
// AVCaptureSession against that muxed device and prove StartStream actually fires
// by counting CMSampleBuffers in the data-output delegate. The first video buffer
// to arrive == ISRStartStreamNeroValeria fired and frames flow.
//
// Like the listener, it sets and (on exit) restores the host allow-gates, and the
// running AVCaptureSession is itself the resident CMIO client.

#import <Foundation/Foundation.h>
#import <CoreMediaIO/CMIOHardware.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>

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

static NSString *fmtDesc(CMFormatDescriptionRef fd) {
    if (!fd) return @"(nil fmt)";
    CMMediaType mt = CMFormatDescriptionGetMediaType(fd);
    FourCharCode sub = CMFormatDescriptionGetMediaSubType(fd);
    char m[5] = {(char)(mt>>24),(char)(mt>>16),(char)(mt>>8),(char)mt,0};
    char s[5] = {(char)(sub>>24),(char)(sub>>16),(char)(sub>>8),(char)sub,0};
    NSString *dims = @"";
    if (mt == kCMMediaType_Video) {
        CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(fd);
        dims = [NSString stringWithFormat:@" %dx%d", d.width, d.height];
    }
    return [NSString stringWithFormat:@"media=%s sub=%s%@", m, s, dims];
}

@interface FrameSink : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate,
                                  AVCaptureAudioDataOutputSampleBufferDelegate>
@property (atomic) NSUInteger videoCount;
@property (atomic) NSUInteger audioCount;
@property (atomic) BOOL loggedFirstVideo;
@property (atomic) BOOL loggedFirstAudio;
@end

@implementation FrameSink
- (void)captureOutput:(AVCaptureOutput *)output
  didOutputSampleBuffer:(CMSampleBufferRef)sb
         fromConnection:(AVCaptureConnection *)conn {
    BOOL isAudio = [output isKindOfClass:[AVCaptureAudioDataOutput class]];
    if (isAudio) {
        self.audioCount++;
        if (!self.loggedFirstAudio) {
            self.loggedFirstAudio = YES;
            logLine(@"FIRST AUDIO buffer: %@", fmtDesc(CMSampleBufferGetFormatDescription(sb)));
        }
        return;
    }
    self.videoCount++;
    if (!self.loggedFirstVideo) {
        self.loggedFirstVideo = YES;
        CMTime pts = CMSampleBufferGetPresentationTimeStamp(sb);
        CMFormatDescriptionRef fd = CMSampleBufferGetFormatDescription(sb);
        CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sb);
        logLine(@"*** FIRST VIDEO FRAME *** pts=%.3f %@ pixelBuffer=%@",
                CMTimeGetSeconds(pts), fmtDesc(fd), pb ? @"yes(decoded)" : @"no(encoded)");
        // Persist evidence: encoded bytes if compressed, else raw size note.
        CMBlockBufferRef bb = CMSampleBufferGetDataBuffer(sb);
        if (bb) {
            size_t len = CMBlockBufferGetDataLength(bb);
            char *bytes = malloc(len);
            if (CMBlockBufferCopyDataBytes(bb, 0, len, bytes) == kCMBlockBufferNoErr) {
                [[NSData dataWithBytes:bytes length:len]
                    writeToFile:@"/tmp/cmio-first-frame.bin" atomically:YES];
                logLine(@"wrote /tmp/cmio-first-frame.bin (%zu bytes)", len);
            }
            free(bytes);
        }
    }
    if (self.videoCount % 30 == 0) {
        logLine(@"video frames so far: %lu (audio: %lu)",
                (unsigned long)self.videoCount, (unsigned long)self.audioCount);
    }
}
@end

static AVCaptureDevice *findMuxedDevice(void) {
    // Force a direct CMIO HAL device-list read first. This is what actually pokes
    // the DAL plugin / assistant to surface the screen-capture device; AVFoundation
    // enumeration alone does not trigger it.
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

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSTimeInterval runSeconds = (argc > 1) ? atof(argv[1]) : 25.0;

        UInt32 priorWired = 0, priorWireless = 0;
        getU32(kCMIOHardwarePropertyAllowScreenCaptureDevices, &priorWired);
        getU32(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, &priorWireless);
        setU32(kCMIOHardwarePropertyAllowScreenCaptureDevices, 1);
        setU32(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, 1);
        logLine(@"allow-gates set (prior wired=%d wireless=%d)", priorWired, priorWireless);

        // TCC: a capture device needs video authorization.
        AVAuthorizationStatus st = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
        logLine(@"video auth status = %ld", (long)st);
        if (st == AVAuthorizationStatusNotDetermined) {
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                     completionHandler:^(BOOL granted) {
                logLine(@"video auth granted = %d", granted);
                dispatch_semaphore_signal(sem);
            }];
            dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        } else if (st != AVAuthorizationStatusAuthorized) {
            logLine(@"WARNING: video not authorized (status=%ld); session may yield no frames", (long)st);
        }

        // Registering a device-list property listener is what pokes the DAL
        // plugin into running the assistant handshake. Setting the allow-gate
        // alone does not surface the muxed device; a client must subscribe.
        dispatch_queue_t listenQ = dispatch_queue_create("cmio.devlist", DISPATCH_QUEUE_SERIAL);
        CMIOObjectPropertyAddress devAddr = {
            kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain
        };
        CMIOObjectAddPropertyListenerBlock(kSystem, &devAddr, listenQ,
            ^(UInt32 n, const CMIOObjectPropertyAddress a[]) { (void)n; (void)a; });

        // Give the assistant a moment to surface the muxed device. Pump the main
        // runloop while waiting — the CMIO HAL needs it serviced to complete the
        // assistant connection; a plain sleep on the main thread blocks the surface.
        AVCaptureDevice *dev = nil;
        for (int i = 0; i < 30 && dev == nil; i++) {
            dev = findMuxedDevice();
            if (!dev) {
                [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
            }
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
        if ([session canAddInput:input]) { [session addInput:input]; }
        else { logLine(@"cannot add input"); return 1; }

        FrameSink *sink = [[FrameSink alloc] init];
        dispatch_queue_t q = dispatch_queue_create("cmio.frames", DISPATCH_QUEUE_SERIAL);

        AVCaptureVideoDataOutput *vout = [[AVCaptureVideoDataOutput alloc] init];
        vout.alwaysDiscardsLateVideoFrames = NO;
        [vout setSampleBufferDelegate:sink queue:q];
        if ([session canAddOutput:vout]) { [session addOutput:vout]; logLine(@"added video output"); }
        else { logLine(@"cannot add video output"); }

        AVCaptureAudioDataOutput *aout = [[AVCaptureAudioDataOutput alloc] init];
        [aout setSampleBufferDelegate:sink queue:q];
        if ([session canAddOutput:aout]) { [session addOutput:aout]; logLine(@"added audio output"); }
        else { logLine(@"cannot add audio output"); }

        [session commitConfiguration];
        [session startRunning];
        logLine(@"session running=%d; waiting %.0fs for first frame...", session.isRunning, runSeconds);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(runSeconds * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            CFRunLoopStop(CFRunLoopGetMain());
        });
        CFRunLoopRun();

        [session stopRunning];
        logLine(@"=== RESULT: video=%lu audio=%lu firstVideo=%d ===",
                (unsigned long)sink.videoCount, (unsigned long)sink.audioCount, sink.loggedFirstVideo);

        setU32(kCMIOHardwarePropertyAllowScreenCaptureDevices, priorWired);
        setU32(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, priorWireless);
        logLine(@"restored allow-gates");
    }
    return 0;
}
