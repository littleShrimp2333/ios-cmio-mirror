# CoreDevice Displayservice Verification

中文版本：
[`coredevice-displayservice-verification.zh-CN.md`](coredevice-displayservice-verification.zh-CN.md)

## Re-verification June 13, 2026 (audio-free route attempt)

Re-ran the route while looking for a video-only path that avoids the CoreMediaIO
audio-channel seizure. Result is unchanged and the root cause is now confirmed by
static analysis of the installed frameworks, not just the runtime error:

- `tools/coredevice-shim/run-media-probe.sh` reproduced exactly: `makeVideoStream`
  builds `PrimaryVideoStreamReceiveAVC`, then `activate()` throws CoreDeviceError
  1001 on capability `com.apple.coredevice.feature.getmediasupportinfo`.
- Static recon of `CoreDevice.framework` 518.31 and its embedded
  `CoreDeviceMediaStreamSupport.framework`: every media-stream activation path
  (`MediaStreamFunctions.startMediaStream`, `VideoStream.activate`,
  `PrimaryVideoStreamReceiveAVC`) converges on the single `getmediasupportinfo`
  capability. There is no conditional branch to an alternative capability.
- The newer capabilities this iOS 26.5 device advertises —
  `com.apple.coredevice.feature.viewdevicescreen`,
  `com.apple.dt.servicesocket.create`,
  `com.apple.dt.serviceconnection.create` — are **not referenced anywhere** in
  the installed framework binaries. `RemoteDevice.viewScreen()` returns a
  `ProcessToken` (a screen-mirroring process launcher, tied to the `devices:`
  URL), not a media stream.

Conclusion: `viewdevicescreen` and `getmediasupportinfo` are two DIFFERENT
capabilities with different purposes, not a newer replacement for an older one.
`viewdevicescreen` drives the `devices:` URL screen mirroring workflow
(`RemoteDevice.viewScreen()` → `ProcessToken`); `getmediasupportinfo` drives the
RTP/HEVC media stream pipeline (`MediaStreamFunctions`, `MediaStreamSession`).
iPhone 14 Pro Max (iPhone15,3) on iOS 26.5 advertises `viewdevicescreen` but NOT
`getmediasupportinfo`, so the media stream path is unavailable regardless of
host framework version. Additionally, the `com.apple.coredevice.displayservice`
RemoteXPC service itself is rejected by the device (CoreDevice error 1001 on
both socket and RemoteXPC route probes). This is a device-side absence, not a
host-side version gap — the iPhone 14 Pro Max simply does not offer this service.

Practical standing as of June 13, 2026: the CoreMediaIO/Valeria bridge
(see `docs/ios-host-screen-capture-options.md`) is the only route verified to
deliver a first frame on iOS 26.5. It seizes the device audio channel during
capture (inherent to the muxed stream, cannot be made video-only) but recovers
after stop. Both alternative "audio-free" routes are DEAD:
- Valeria USB raw (route 1): macOS blocks userspace libusb exclusive claim of
  the vendor-specific AV interface, even as root.
- CoreDevice displayservice (route 2): iPhone 14 Pro Max does not expose the
  `com.apple.coredevice.displayservice` service on iOS 26.5; this is a
  device-side absence, not a version mismatch.

Remaining verifiable routes for "no audio channel theft" are: Instruments
screenshots (go-ios style, real video path at lower FPS, no audio), AirPlay
receiver (user-initiated), and ReplayKit Broadcast (on-device extension).

## Status

Current status: static and maintenance checks passed. A real device pass was
run on an iPhone 14 Pro Max with iOS 26.5. Pairing, Developer Mode, RSD tunnel,
generic CoreDevice display info, and a native Swift call to
`RemoteDevice.viewScreen()` all worked up to their intended boundaries.
`viewScreen()` proved to be a launcher for a `devices:` URL rather than a frame
API, and this host has no macOS application registered for that URL scheme.
The specific `pymobiledevice3` 9.18.0 media-stream services also failed to
start on this device, so embeddable RTP/HEVC streaming is not yet verified for
iOS 26.5.

Check date: June 13, 2026.

## Claim Under Test

CoreDevice displayservice is the preferred host-side route for high-FPS screen
streaming that is independent from XCUITest/WDA. It should avoid the in-device
MJPEG/XCTest contention because capture runs in a host process over trusted
device services, not inside the test runner.

## Maintenance Evidence

`pymobiledevice3` is still actively maintained and is a useful reference for
this route:

| Check | Result |
|-------|--------|
| GitHub latest release | `v9.18.0`, published June 11, 2026 at 17:46:44 UTC |
| PyPI latest release | `pymobiledevice3 9.18.0`, uploaded June 11, 2026 at 17:47 UTC |
| PyPI classifier | `Development Status :: 5 - Production/Stable` |
| Local checkout | `/tmp/pymobiledevice3-check`, commit `0ee5544`, tag `v9.18.0` |
| License | GPL-3.0 |

GitHub repository metadata at inspection time showed 90 open issues and 20 open
pull requests. GitHub API `open_issues_count` returned 110, which is consistent
with GitHub's issue-plus-PR aggregate count.

The `v9.18.0` release notes include the relevant CoreDevice work:

- `core_device: ScreenCaptureService + screen-capture CLI`
- `core_device: DisplayService + media_stream_offer + display CLI`
- `core_device: serve-web (browser HEVC viewer via WebCodecs)`
- `core_device: serve-vnc (RFB 3.8 server for macOS Screen Sharing)`

## Source Evidence

The local `pymobiledevice3` checkout exposes the service and stream controls in
these files:

| Concern | Evidence |
|---------|----------|
| CoreDevice service name | `/tmp/pymobiledevice3-check/pymobiledevice3/remote/core_device/display_service.py` |
| CLI commands | `/tmp/pymobiledevice3-check/pymobiledevice3/cli/developer/core_device.py` |
| RTP/HEVC stream helpers | `/tmp/pymobiledevice3-check/pymobiledevice3/remote/core_device/screen_stream.py` |
| VNC server path | `/tmp/pymobiledevice3-check/pymobiledevice3/remote/core_device/vnc_server.py` |
| CLI recipes | `/tmp/pymobiledevice3-check/docs/guides/cli-recipes.md` |

The service identifier is:

```text
com.apple.coredevice.displayservice
```

The relevant feature/action identifiers are:

```text
com.apple.coredevice.feature.getmediasupportinfo
com.apple.coredevice.action.mediastreamgetsupportinfo
com.apple.coredevice.feature.getmediastreamserverstatus
com.apple.coredevice.action.mediastreamstatus
com.apple.coredevice.feature.startmediastream
com.apple.coredevice.action.mediastreamstart
com.apple.coredevice.feature.stopmediastream
com.apple.coredevice.action.mediastreamstop
```

The video stream path binds a host UDP socket before calling
`startmediastream`. The device then pushes RTP/HEVC packets to the host.

## Real Device Pass

Device and host state:

| Field | Result |
|-------|--------|
| Device | iPhone 14 Pro Max (`iPhone15,3`) |
| iOS | 26.5 (`23F77`) |
| Transport | USB / wired |
| Pairing | `paired` after `pymobiledevice3 lockdown pair` |
| Developer Mode | `enabled` |
| DDI services | `ddiServicesAvailable: true` |
| RSD tunnel | `connected` via Apple CoreDevice; separate pymobiledevice3 tunneld also worked |
| pymobiledevice3 | 9.18.0 in `/tmp/pymd3-verify-venv` |

Successful checks:

```shell
devicectl list devices
# device available: iPhone15,3

/tmp/pymd3-verify-venv/bin/python -m pymobiledevice3 usbmux list
# ProductType: iPhone15,3
# ProductVersion: 26.5

/tmp/pymd3-verify-venv/bin/python -m pymobiledevice3 lockdown pair \
  --udid 00008120-00166CC802FB601E
# INFO waiting user pairing dialog...

devicectl device info details --device 215FC4CA-24D4-5ACD-BEE4-58307313317D
# pairingState: paired
# developerModeStatus: enabled
# ddiServicesAvailable: true
# tunnelState: connected

/tmp/pymd3-verify-venv/bin/python -m pymobiledevice3 developer core-device \
  get-display-info --tunnel 00008120-00166CC802FB601E
# primary displayId: 1
# currentMode.size: [1290.0, 2796.0]
# refreshRate: 120.0
# backlightState: activeOn
```

The user started `pymobiledevice3 remote tunneld` with root privileges. Its HTTP
control endpoint returned:

```json
{
  "00008120-00166CC802FB601E": [
    {
      "tunnel-address": "fd73:6dc3:1655::1",
      "tunnel-port": 51793,
      "interface": "usbmux-00008120-00166CC802FB601E-USB"
    }
  ]
}
```

The tunnel API itself was usable:

```shell
/tmp/pymd3-verify-venv/bin/python - <<'PY'
import asyncio
from pymobiledevice3.tunneld.api import get_tunneld_devices

async def main():
    rsds = await get_tunneld_devices()
    print(len(rsds), rsds[0].udid, rsds[0].product_type, rsds[0].product_version)
    await rsds[0].close()

asyncio.run(main())
PY
# 1 00008120-00166CC802FB601E iPhone15,3 26.5
```

Failed checks:

```shell
/tmp/pymd3-verify-venv/bin/python -m pymobiledevice3 developer core-device \
  display get-media-support-info --tunnel 00008120-00166CC802FB601E
# ERROR Failed to start service.

/tmp/pymd3-verify-venv/bin/python -m pymobiledevice3 developer core-device \
  display get-media-stream-server-status --tunnel 00008120-00166CC802FB601E
# ERROR Failed to start service.

/tmp/pymd3-verify-venv/bin/python -m pymobiledevice3 developer core-device \
  screen-capture screenshot /tmp/coredevice-screen.png \
  --tunnel 00008120-00166CC802FB601E
# ERROR Failed to start service.

/tmp/pymd3-verify-venv/bin/python -m pymobiledevice3 developer core-device \
  display start-video-stream /tmp/coredevice-cap.rtp --duration 3 \
  --tunnel 00008120-00166CC802FB601E
# Listening for RTP on [fd73:6dc3:1655::1] -> ::50730
# ERROR Failed to start service.
```

Interpretation:

- Trust pairing, Developer Mode, DDI, and RSD/tunneld are verified.
- Generic CoreDevice display info works through pymobiledevice3 on the same
  device and tunnel.
- The failure is isolated to the private media/screenshot services used by
  pymobiledevice3 9.18.0:
  `com.apple.coredevice.displayservice` and
  `com.apple.coredevice.screencaptureservice`.
- On iOS 26.5, Apple may have moved screen viewing to a newer internal
  `viewdevicescreen` / `screenViewingURL` / `MediaStreamFunctions` path, or
  the service start request now needs additional fields not present in
  pymobiledevice3 9.18.0.

## Apple CoreDevice String Evidence

The local Xcode 17 CoreDevice frameworks include media-stream support even
though `devicectl device --help` does not expose a screen-view command.

Relevant strings found in
`/Library/Developer/PrivateFrameworks/CoreDevice.framework`:

```text
MediaStreamFunctions
mediaStreamSupportInfo
mediaStreamServerStatus
startMediaStream(with:)
stopMediaStream(with:)
deviceInfo.screenViewingURL
screenViewingURL
SnapshotFetchScreenshotsActionDeclaration
com.apple.coredevice.action.snapshotfetchscreenshots
```

Relevant strings found in
`CoreDeviceMediaStreamSupport.framework`:

```text
com.apple.dt.coredevice.MediaStreamSupport
CoreDeviceScreenSharing
VideoStream.start: creating AVCScreenCapture
PrimaryVideoStreamReceiveAVC
SecondaryVideoStreamReceiveAVC
AVCMediaStreamNegotiatorTransportProtocolType
AVCMediaStreamNegotiatorAccessNetworkType
```

Device metadata also advertises:

```text
com.apple.coredevice.feature.viewdevicescreen
screenViewingURL: devices://device/open?id=215FC4CA-24D4-5ACD-BEE4-58307313317D
```

This makes Apple CoreDevice screen viewing still plausible, but the verified
entry point for iOS 26.5 is not the `pymobiledevice3` 9.18.0
`displayservice` wrapper.

## Direct CoreDevice.framework Entry Probe

After the `pymobiledevice3` wrapper failed, the next check bypassed
`pymobiledevice3` and `go-ios` and looked directly at Apple's installed
CoreDevice framework.

Framework and tool versions:

```text
CoreDevice.framework CFBundleVersion: 518.31
CoreDevice.framework DTXcodeBuild: 17F36
CoreDevice.framework DTSDKName: macosx26.4.internal
devicectl JSON version: 3
```

The framework does not ship a public Swift module interface:

```shell
find /Library/Developer/PrivateFrameworks/CoreDevice.framework \
  -name '*.swiftmodule' -o -name '*.swiftinterface'
# no CoreDevice.swiftmodule / CoreDevice.swiftinterface found

swift -F /Library/Developer/PrivateFrameworks \
  -framework CoreDevice \
  -e 'import CoreDevice; print("imported")'
# error: no such module 'CoreDevice'
```

The Swift classes are nevertheless present at runtime:

```text
objc_getClass("CoreDevice.DeviceManager") -> non-null
objc_getClass("CoreDevice.RemoteDevice") -> non-null
```

They are not ObjC-callable classes for these methods:

```text
class_copyMethodList(CoreDevice.DeviceManager) -> 0 methods
class_copyMethodList(CoreDevice.RemoteDevice) -> 0 methods
```

That means the useful entry points are Swift ABI symbols, not normal Objective-C
selectors.

Key demangled symbols:

```text
static CoreDevice.DeviceManager.shared.getter : CoreDevice.DeviceManager
CoreDevice.DeviceManager.awaitFullInitialization() async -> ()
CoreDevice.DeviceManager.allDevices() -> [CoreDevice.RemoteDevice]
CoreDevice.DeviceManager.devices.getter : [Foundation.UUID : CoreDevice.RemoteDevice]
CoreDevice.RemoteDevice.viewScreen() async throws -> CoreDevice.ProcessToken
CoreDevice.RemoteDevice.viewScreen(completingOn:completion:) -> ()
CoreDevice.RemoteDevice.mediaStreamSupportInfo.getter
CoreDevice.RemoteDevice.mediaStreamServerStatus.getter
CoreDevice.RemoteDevice.startMediaStream(with:) async throws
CoreDevice.RemoteDevice.stopMediaStream(with:) async throws
```

Minimal Swift ABI calls that worked:

```swift
@_silgen_name("$s10CoreDevice0B7ManagerC6sharedACvgZ")
func DeviceManager_shared() -> AnyObject

@_silgen_name("$s10CoreDevice0B7ManagerC23awaitFullInitializationyyYaFTj")
func DeviceManager_awaitFullInitialization(_ manager: AnyObject) async

let manager = DeviceManager_shared()
await DeviceManager_awaitFullInitialization(manager)
```

Observed output:

```text
manager ok DeviceManager 0x...
before
after
```

Calls that crossed Swift generic boundaries did not work safely when the probe
incorrectly substituted `AnyObject` for CoreDevice's real private types:

```swift
@_silgen_name("$s10CoreDevice0B7ManagerC10allDevicesSayAA06RemoteB0CGyF")
func DeviceManager_allDevices(_ manager: AnyObject) -> [AnyObject]

@_silgen_name("$s10CoreDevice0B7ManagerC7devicesSDy10Foundation4UUIDVAA06RemoteB0CGvgTj")
func DeviceManager_devices(_ manager: AnyObject) -> [UUID: AnyObject]
```

Both variants crashed the Swift interpreter. The same happened when trying to
register an `addDevicesAddedHandler` closure with `[AnyObject]`. This is
expected for an ABI-only probe: `[RemoteDevice]` and
`[UUID: RemoteDevice]` are not safely substitutable with `[AnyObject]` /
`[UUID: AnyObject]`.

A minimal private module shim was then added under
`tools/coredevice-shim`. With the exact `RemoteDevice` type declaration,
`DeviceManager.allDevices()` worked:

```shell
tools/coredevice-shim/run-probe.sh
# Waiting for CoreDevice initialization...
# CoreDevice devices: 1
# - 215FC4CA-24D4-5ACD-BEE4-58307313317D:
#   iPhone (Connected, iOS 26.5 23F77, ...)
```

The same shim successfully invoked `RemoteDevice.viewScreen()`:

```shell
tools/coredevice-shim/run-probe.sh --view-screen
# No application knows how to open URL
# devices://device/open?id=215FC4CA-24D4-5ACD-BEE4-58307313317D
# viewScreen failed: CoreDeviceError(errorCode: 10004, ...)
```

This is a useful positive result: the private Swift entry point is callable
without XCTest and resolves the connected device correctly. It also establishes
that `viewScreen()` is a launcher around the device's `screenViewingURL`, not a
direct API that returns video frames to the caller.

`screenViewingURL` was also tested directly:

```shell
open 'devices://device/open?id=215FC4CA-24D4-5ACD-BEE4-58307313317D'
# kLSApplicationNotFoundErr: no application claims the file
```

So the URL is present in CoreDevice metadata, but this host does not have a
LaunchServices handler registered for the `devices:` scheme. A LaunchServices
registry check found no handler. The only `Devices.app` found locally is inside
the iOS Simulator runtime and is not a macOS viewing application.

Interpretation:

- Apple's new CoreDevice entry exists and is not the same wrapper layer as
  `pymobiledevice3` / `go-ios`.
- The directly verified callable surface now includes `DeviceManager.shared`,
  `awaitFullInitialization()`, `allDevices()`, and `RemoteDevice.viewScreen()`.
- `RemoteDevice.viewScreen()` does not itself expose frames. It asks
  LaunchServices to open `devices://device/open?id=...`.
- The `viewScreen()` launch failed only because this host has no registered
  macOS `devices:` handler.
- The private framework separately exposes `MediaStreamFunctions`,
  `mediaStreamSupportInfo`, `mediaStreamServerStatus`, `startMediaStream(with:)`,
  and `stopMediaStream(with:)`. Those remain the best direct embedding target.
- A robust host implementation should either:
  - extend the private-module shim with the exact media-stream request/response
    layouts and call `MediaStreamFunctions`; or
  - install/use the Apple viewing application that owns the `devices:` scheme
    if a standalone viewer is acceptable; or
  - use Xcode/DVT's internal wrapper layer or compare its RemoteXPC traffic.

## CoreDeviceMediaStreamSupport Runtime Probe

A minimal private module shim now covers Apple's higher-level media stream
framework:

```text
CoreDeviceMediaStreamSupport.MediaStreamSession
CoreDeviceMediaStreamSupport.VideoStreamConfiguration.receiveMirroredPrimary
CoreDeviceMediaStreamSupport.VideoStream.activate
```

The real-device probe successfully created the primary mirrored-video receiver
without XCTest:

```shell
tools/coredevice-shim/run-media-probe.sh

# makeVideoStream succeeded:
# <CoreDeviceMediaStreamSupport.PrimaryVideoStreamReceiveAVC: ...>
```

Calling `activate()` reached the device capability check, then failed:

```text
CoreDeviceError Code=1001
The capability "Create Service Socket" is not supported by this device.
CapabilityFeatureIdentifier=com.apple.coredevice.feature.getmediasupportinfo
```

The same iOS 26.5 device advertises the newer capabilities
`com.apple.dt.servicesocket.create` and
`com.apple.coredevice.feature.viewdevicescreen`, but not
`com.apple.coredevice.feature.getmediasupportinfo`. Therefore,
CoreDeviceMediaStreamSupport 518.31 can construct the receiver but still routes
activation through an older media capability that iOS 26.5 no longer exposes.

CoreDevice also exposes `ScreenViewingURLHelper` with `preferred`, `VNC`, and
`Devices` URL types. The real-device probe returned:

```text
preferred: devices://device/open?id=215FC4CA-24D4-5ACD-BEE4-58307313317D
VNC: nil
Devices: devices://device/open?id=215FC4CA-24D4-5ACD-BEE4-58307313317D
```

Therefore, this iOS 26.5 device configuration does not provide a VNC URL.
The preferred route remains the higher-level `devices:` viewer.

## New Service Route Verification

The native shim now restores both current CoreDevice transport capabilities:

```text
com.apple.dt.servicesocket.create
com.apple.dt.serviceconnection.create
```

The raw service-socket route is verified working by a positive control:

```shell
tools/coredevice-shim/run-displayservice-socket-probe.sh \
  com.apple.instruments.dtservicehub
# socket opened: fd=4
```

It also opens the advertised `getdisplayinfo` feature, but rejects
`com.apple.coredevice.displayservice`, `viewdevicescreen`, and the old media
feature identifiers with CoreDevice error 1001.

The RemoteXPC service-connection route is independently verified working:

```shell
tools/coredevice-shim/run-displayservice-remotexpc-probe.sh \
  --feature com.apple.coredevice.feature.getdisplayinfo 0
# createServiceConnection supported: true
# RemoteXPC connection opened: <OS_xpc_remote_connection: ...>
```

The same route rejects `com.apple.coredevice.displayservice` for connection
modes `0`, `1`, and `2`. It also rejects direct mapping of
`com.apple.coredevice.feature.viewdevicescreen`.

This separates route compatibility from service availability: the new socket
and RemoteXPC routes both work on this iOS 26.5 device, but
`com.apple.coredevice.displayservice` is not exposed through either route.
`getdisplayinfo` is the successful control, while screen viewing remains a
higher-level capability or URL-launch workflow.

## Commands Checked

Maintenance and package checks:

```shell
python3 -m pip index versions pymobiledevice3
git -C /tmp/pymobiledevice3-check rev-parse --short HEAD
git -C /tmp/pymobiledevice3-check tag --points-at HEAD
```

Source lookup:

```shell
rg -n "serve-web|serve-vnc|start-video-stream|get-media-support-info|get-media-stream-server-status|ScreenCaptureService|DisplayService" \
  /tmp/pymobiledevice3-check/pymobiledevice3 \
  /tmp/pymobiledevice3-check/docs
```

Current runtime environment:

```shell
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun devicectl list devices
# iPhone 14 Pro Max connected

xcode-select -p
# /Library/Developer/CommandLineTools

/tmp/pymd3-verify-venv/bin/python -m pymobiledevice3 usbmux list
# iPhone15,3, iOS 26.5, USB
```

The globally selected developer directory is CommandLineTools, so Xcode tools
must be run with an explicit `DEVELOPER_DIR` or after changing `xcode-select`.
That does not change the CoreDevice result: the native shim links directly to
the installed private framework and sees the real connected iOS device.

## Runtime Verification Plan

For an iOS version where `displayservice` starts successfully, or after the
iOS 26.5 screen-viewing entry point is updated:

1. Install or run `pymobiledevice3` from an isolated environment.
2. Establish the iOS 17+ RSD tunnel if the target is iOS 17 or newer.
3. Query displayservice support:

```shell
pymobiledevice3 developer core-device display get-media-support-info
pymobiledevice3 developer core-device display get-media-stream-server-status
```

4. Capture a short raw RTP/HEVC stream:

```shell
pymobiledevice3 developer core-device display start-video-stream /tmp/cap.rtp --duration 10
```

5. Convert and play the capture:

```shell
misc/rtp_dump.py /tmp/cap.rtp /tmp/cap.h265
ffplay -framerate 60 /tmp/cap.h265
```

6. Run the same capture while hammering DeviceKit/WDA
   `/source?format=json`.
7. Accept the route if RTP packet cadence and decoded playback stay stable
   while `/source` is busy.

## Automation Fields To Record

For a real-device pass, record:

- Device model and iOS version.
- Whether the tunnel was required and how it was started.
- Output of `get-media-support-info`.
- Output of `get-media-stream-server-status` before and during streaming.
- Duration, bytes captured, packet count, and decode success.
- Frame cadence while idle.
- Frame cadence while `/source?format=json` is hammered.
- Host CPU and memory for the capture process.

## Decision

CoreDevice screen viewing is verified to be independent from XCTest. The
native shim can enumerate the real device and invoke `RemoteDevice.viewScreen()`
without launching an XCTest runner. However, embeddable screen streaming is not
yet verified: `viewScreen()` delegates to an unavailable `devices:` URL handler,
while the older `pymobiledevice3` 9.18.0 `displayservice` wrapper cannot start
on iOS 26.5.

Keep CoreDevice as the primary high-FPS host-side research direction. The new
service-socket and service-connection routes are now adapted and verified, but
neither exposes `com.apple.coredevice.displayservice` on this device. The next
implementation step is to call `MediaStreamFunctions` directly and inspect the
higher-level `viewdevicescreen` / `devices:` workflow or its RemoteXPC traffic.
The repository now includes `run-media-functions-probe.sh`; newly generated
Swift/JIT processes are currently blocked by the host `taskgated` loading
state, while previously cached probes still run. Use
go-ios/Instruments screenshot streaming only as a fallback because it is a
repeated screenshot loop, not a native video stream. Treat pymobiledevice3 as
GPL-3.0 reference/protocol evidence unless product licensing explicitly allows
direct reuse.

## Sources

- pymobiledevice3 source: https://github.com/doronz88/pymobiledevice3
- pymobiledevice3 PyPI package:
  https://pypi.org/project/pymobiledevice3/
- pymobiledevice3 v9.18.0 release:
  https://github.com/doronz88/pymobiledevice3/releases/tag/v9.18.0
