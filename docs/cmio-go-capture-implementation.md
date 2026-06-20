# CMIO Go Capture — Implementation Details

## Overview

`tools/cmio-capture/` is a Go module that records the iOS device screen through
Apple's CoreMediaIO bridge on macOS. It wraps the proven `iOSScreenCapture`
DAL plugin recipe in CGO, exposing an idiomatic Go API and a CLI.

The bridge captures at native resolution (1290×2796 on iPhone 14 Pro Max), real
60 fps H.264, without an in-app screen-recording permission or manual USB
reconfiguration. USB stays at config 5 throughout.

## Architecture

```
CLI (main.go)
  │  flag parsing, error formatting
  ▼
cmio.Record(output, duration, mode)
  │  Go API: cmio.Error, cmio.Mode, cmio.Is()
  ▼
C.cmio_record()          ← CGO call
  │
  ▼
bridge_darwin.m          ← Objective-C implementation
  │
  ├── CMIOHardware.h     ← allow-gates, device-list read
  ├── AVCaptureSession   ← muxed iOS Device → AVCaptureMovieFileOutput
  └── NSRunLoop          ← pump while waiting (critical, see below)
```

The Go package (`cmio/`) exports exactly one function and two types:

```go
func Record(output string, duration float64, mode Mode) error

type Mode int
const (
    VideoOnly  Mode = iota  // no audio track in file
    AudioVideo              // includes muxed audio track
)

type Error struct { Code int; Message string }
func Is(err error, code int) bool
```

## The Three Preconditions

Getting a first frame requires three things to all be true. Each was a real
failure point discovered during protocol exploration.

### 1. TCC Camera Authorization

The muxed iOS device is a camera-class capture device on macOS. The host process
must have `AVMediaTypeVideo` authorization through TCC (Transparency, Consent &
Control). On first run the system prompts; after grant it persists.

```objc
AVAuthorizationStatus st =
    [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
if (st == AVAuthorizationStatusNotDetermined) {
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                             completionHandler:^(BOOL granted) { ... }];
}
```

If authorization is denied, the muxed device will still appear in CMIO but the
capture session will produce no frames.

### 2. Direct CMIO HAL Device-List Read

Asking only AVFoundation to enumerate devices does not poke the DAL plugin. The
client must read `kCMIOHardwarePropertyDevices` on the CMIO system object to
trigger the plugin. This is the actual poke that wakes up
`iOSScreenCaptureAssistant`.

```objc
static void list_read(void) {
    CMIOObjectPropertyAddress a = {kCMIOHardwarePropertyDevices, ...};
    UInt32 sz = 0;
    CMIOObjectGetPropertyDataSize(kSys, &a, 0, NULL, &sz);
    CMIOObjectID *ids = calloc(sz / sizeof(CMIOObjectID), ...);
    CMIOObjectGetPropertyData(kSys, &a, 0, NULL, sz, &sz, ids);
    free(ids);
}
```

Without this read, AVFoundation enumeration alone will not surface the muxed
`iOS Device` — even with the allow-gates already set.

### 3. Runloop Pumping While Waiting

After the allow-gates are set and the HAL has been poked, the muxed device
appears asynchronously (~3–5 seconds). Blocking the main thread with `sleep`
prevents the CMIO HAL from completing its XPC connection to the assistant
service, and the device never surfaces.

The fix is to pump the main runloop during the poll:

```objc
for (int i = 0; i < 40 && dev == nil; i++) {
    list_read();          // poke the DAL plugin
    dev = find_muxed();   // check AVFoundation
    if (!dev) {
        [[NSRunLoop currentRunLoop]
            runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.5]];
    }
}
```

This is the specific difference that made the first two ObjC probes fail (which
used `sleepForTimeInterval:`) while the runloop-driven listener always worked.

## Capture Session Setup

```objc
// Device discovery
AVCaptureDevice *dev = [AVCaptureDeviceDiscoverySession
    discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeExternal]
                         mediaType:AVMediaTypeMuxed
                          position:AVCaptureDevicePositionUnspecified]
    .devices.firstObject;

// Session configuration
AVCaptureSession *session = [[AVCaptureSession alloc] init];
[session beginConfiguration];
[session addInput:[AVCaptureDeviceInput deviceInputWithDevice:dev error:&err]];
[session addOutput:movieOutput];  // AVCaptureMovieFileOutput
[session commitConfiguration];
```

The muxed device's single stream (`VDC Video Stream`, `MediaType = muxx`) carries
both video and audio multiplexed. There is no separate audio stream to leave
inactive.

### Video-Only Mode

When `mode == VideoOnly`, the audio connection on the `AVCaptureMovieFileOutput`
is disabled:

```objc
if (!captureAudio) {
    for (AVCaptureConnection *c in movie.connections) {
        for (AVCaptureInputPort *p in c.inputPorts) {
            if ([p.mediaType isEqualToString:AVMediaTypeAudio])
                c.enabled = NO;
        }
    }
}
```

This removes the audio track from the output file, but does **not** prevent the
CoreMediaIO bridge from briefly activating the muxed audio path internally.
See "Audio Channel Takeover" below.

## Duration Tracking

The bridge has ~3–5 seconds of warm-up between `[session startRunning]` and the
first video frame. A wall-clock timer would cut the clip short. Instead the code
reads `movie.recordedDuration` — the actual media time written to the file:

```objc
Float64 rec = CMTimeGetSeconds(movie.recordedDuration);
if (rec >= targetDuration) {
    [movie stopRecording];
}
```

The poll loop runs until either the recording delegate reports finish, or a
safety deadline (`target + 45` seconds) expires.

## CMIO Allow-Gates

Two properties on the CMIO system object control whether screen-capture devices
are visible:

| Property | 4CC | Purpose |
|----------|-----|---------|
| `kCMIOHardwarePropertyAllowScreenCaptureDevices` | `'yes '` | Wired (USB) screen capture devices |
| `kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices` | `'wscd'` | Wireless screen capture devices |

Both are set to `1` before capture and restored to their prior values on exit:

```objc
gate_set(kCMIOHardwarePropertyAllowScreenCaptureDevices, 1);
gate_set(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, 1);
// ... capture ...
gate_set(kCMIOHardwarePropertyAllowScreenCaptureDevices, priorWired);
gate_set(kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices, priorWireless);
```

Setting the gates alone is not enough — the client must also read the HAL device
list (precondition 2) to poke the assistant into running its MobileDevice →
Valeria handshake.

## Error Codes

| Code | Meaning |
|------|---------|
| 1 | Failed to read CMIO allow-properties (system object unavailable) |
| 2 | Muxed iOS device did not surface (iPhone not paired/connected, or TCC denied) |
| 3 | `AVCaptureDeviceInput` creation failed (device exists but can't open input) |
| 4 | Cannot add muxed device input to session |
| 5 | Cannot add movie output to session |
| 6 | Recording finished with error (e.g. disk full, device disconnected mid-capture) |

## Audio Channel Takeover

Even in `VideoOnly` mode, the CoreMediaIO bridge activates the muxed audio path
internally. The iPhone routes its system audio to the host during capture,
interrupting on-device playback. Audio recovers when the capture session stops
(no reboot or replug needed).

This is not fixable within the CMIO bridge — the muxed stream bundles audio
and video in a single `muxx` media type with no per-track enable/disable
property at the CMIO stream level. A fully audio-free capture requires a
different route (Instruments screenshots, AirPlay receiver, or ReplayKit).

## Building

```bash
cd tools/cmio-capture
go build -o cmio-capture .
```

Requires:
- Go 1.26+ (CGO enabled, default on macOS)
- macOS SDK (Xcode)
- CGO linker frameworks: Foundation, CoreMediaIO, AVFoundation, CoreMedia

No external Go dependencies beyond the standard library.

## Usage

```bash
# Video-only, 10 seconds
cmio-capture -d 10 -o /tmp/screen.mov

# Video + audio, 30 seconds
cmio-capture -d 30 -av -o ~/Desktop/capture.mov
```

As a library:

```go
import "devicekit/tools/cmio-capture/cmio"

func main() {
    if err := cmio.Record("/tmp/screen.mov", 10, cmio.VideoOnly); err != nil {
        log.Fatal(err)
    }
}
```

## Output Format

- Container: QuickTime `.mov`
- Video: H.264 (AVC), 1290×2796, ~60 fps, variable bitrate
- Audio (when `-av`): AAC, 48 kHz, stereo
- File written by `AVCaptureMovieFileOutput` (hardware-accelerated encode via
  VideoToolbox inside the bridge)

## Related Files

- `tools/coredevice-shim/CMIOScreenCaptureListener.m` — original ObjC listener
  that proved the resident-client discovery
- `tools/coredevice-shim/CMIOScreenCaptureFirstFrame.m` — original ObjC probe
  that proved first-frame capture
- `tools/coredevice-shim/CMIOScreenCaptureRecord.m` — original ObjC recorder
  (10s .mov output)
- `tools/coredevice-shim/CMIODeviceProbe.m` — stream enumeration probe that
  confirmed single `muxx` stream (no separate audio stream)
- `tools/coredevice-shim/valeria_usb_claim_probe.py` — confirmed Valeria USB
  claim dead on macOS (root + detach still fails)
- `docs/coredevice-displayservice-verification.md` — CoreDevice displayservice
  investigation (dead on iPhone 14 Pro Max)
- `docs/ios-host-screen-capture-options.md` — full route survey
