# iOS Host-Side Screen Capture Options

## Summary

There are several screen capture routes that do not require an in-app
screen-recording permission prompt:

| Route | Where it runs | Permission / trust gate | XCTest independent | Stream suitability |
|-------|---------------|-------------------------|--------------------|--------------------|
| CoreDevice displayservice media stream | Host process over iOS 17+ RSD/RemoteXPC | Trusted pairing plus active tunnel | Yes | Real RTP/HEVC video stream |
| QuickTime / Valeria USB screen capture | Host process over a hidden iOS USB AV configuration | Trusted USB device plus raw USB access or Apple's CoreMediaIO bridge | Yes | Real H264 video plus audio sample buffers |
| Apple iPhone Mirroring plus `mirroir-mcp` | Apple Continuity stream rendered by the macOS iPhone Mirroring app | macOS 15+, iOS 18+, same Apple Account, nearby device, Wi-Fi/Bluetooth; `mirroir-mcp` also needs macOS Accessibility and Screen Recording permissions | Yes | Real Apple audio/video stream, but `mirroir-mcp` captures the rendered Mac window |
| go-ios Instruments screenshot | Host process over USB/RSD | Trusted pairing plus Developer Disk Image on older iOS, or active tunnel on iOS 17+ | Mostly yes; not part of XCUITest, but still uses Apple developer services | Low to medium FPS MJPEG by repeated screenshots |
| CoreDevice screencaptureservice | Host process over iOS 17+ RSD/RemoteXPC | Trusted pairing plus active tunnel | Yes | Single PNG screenshot |
| libimobiledevice screenshotr | Host process over usbmuxd | Trusted pairing plus mounted developer image | Yes, separate from WDA/XCTest | Single screenshot; streaming would be repeated screenshots |
| AirPlay receiver | Host process as AirPlay target | User selects Screen Mirroring, same network/passcode as needed | Yes | Real video mirroring, H264/AAC style |
| ReplayKit Broadcast Upload Extension | On-device extension | User starts ReplayKit broadcast | Yes | Real video frames via `CMSampleBuffer` |

The most promising embeddable route for DeviceKit is now QuickTime / Valeria
USB screen capture. It is host-side, XCTest-independent, and produces a real
H264/audio stream rather than repeated screenshots. A real iPhone 14 Pro Max
on iOS 26.5 accepted the Valeria activation control request and exposed the
hidden sixth USB configuration. CoreDevice displayservice remains an important
protocol reference, but it was not exposed by that same device.

None of these host-side routes removes the need for trusted pairing. That is
already a DeviceKit prerequisite because the host must install/run the test
runner and forward the automation HTTP service. The relevant question is
whether the route requires an additional in-app permission or user broadcast
consent; the CoreDevice, Instruments, and Valeria routes do not appear to.

## pymobiledevice3 Maintenance Status

`pymobiledevice3` is actively maintained as of the June 13, 2026 check:

- GitHub latest release: `v9.18.0`, published June 11, 2026 at 17:46:44 UTC.
- PyPI latest release: `pymobiledevice3 9.18.0`, uploaded June 11, 2026
  at 17:47 UTC.
- PyPI classifier: `Development Status :: 5 - Production/Stable`.
- Local checkout is at `0ee5544`, tagged `v9.18.0`.
- GitHub repository metadata reported 90 open issues and 20 open pull
  requests; GitHub API `open_issues_count` was 110, which matches that combined
  issue-plus-PR total.
- The `v9.18.0` release notes explicitly include the CoreDevice work we care
  about:
  - `core_device: ScreenCaptureService + screen-capture CLI`
  - `core_device: DisplayService + media_stream_offer + display CLI`
  - `core_device: serve-web (browser HEVC viewer via WebCodecs)`
  - `core_device: serve-vnc (RFB 3.8 server for macOS Screen Sharing)`
- `pip index versions pymobiledevice3` also reported latest `9.18.0` and a long
  active version history.

This makes it a strong reference implementation for the CoreDevice display
route. The main caveat is license and architecture: the project is GPL-3.0, so
we should treat it as protocol/reference material or a separate tool dependency
unless the product licensing strategy explicitly allows direct code reuse.

Runtime validation is tracked separately in
`docs/coredevice-displayservice-verification.md`. The iPhone 14 Pro Max on
iOS 26.5 does NOT expose `com.apple.coredevice.displayservice` — this is a
device-side absence (not a version mismatch or parameter issue). The device
advertises `viewdevicescreen` (for `devices:` URL mirroring), not
`getmediasupportinfo` (for RTP/HEVC media stream). Regardless of host framework
version, the CoreDevice displayservice media stream route is dead on this model.
See the verification doc for the full investigation.

## CoreDevice Displayservice Route

`pymobiledevice3` implements a CoreDevice media stream path over iOS 17+
Remote Service Discovery / RemoteXPC.

The service is:

```text
com.apple.coredevice.displayservice
```

Important feature/action identifiers in `pymobiledevice3`:

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

For video, the host binds a UDP socket first, then asks the device to send RTP
there:

```text
host UDP socket
  <- device RTP/HEVC packets
RemoteXPC mediastreamstart request:
  receiverIP, receiverPort, senderIP, displayID, negotiatorOffer
```

`pymobiledevice3` has three useful wrappers around this:

| Command | Behavior |
|---------|----------|
| `developer core-device display start-video-stream` | Captures raw RTP/HEVC packets to a file |
| `developer core-device display serve-web` | Serves HEVC access units over HTTP and decodes in browser WebCodecs |
| `developer core-device display serve-vnc` | Decodes HEVC with VideoToolbox and exposes a VNC server |

This is the closest open-source match to "desktop assistant screen mirroring"
without app-level screen recording permission. It is also more promising than
go-ios MJPEG for high frame rates because it is a real video stream.

The local `pymobiledevice3` CLI recipe captures raw RTP/HEVC to
`/tmp/cap.rtp`, converts it to Annex-B H.265, then plays it with
`ffplay -framerate 60`; that is the current high-FPS smoke path to reproduce.

The same CoreDevice area also exposes:

```text
com.apple.coredevice.screencaptureservice
com.apple.coredevice.feature.capturescreenshot
com.apple.coredevice.action.capturescreenshot
```

That service returns a PNG screenshot. It is useful for still images, but the
displayservice RTP/HEVC path is the better streaming candidate.

Relevant local source after checking `doronz88/pymobiledevice3`:

| Concern | File |
|---------|------|
| CoreDevice display service wrapper | `/tmp/pymobiledevice3-check/pymobiledevice3/remote/core_device/display_service.py` |
| Screenshot service wrapper | `/tmp/pymobiledevice3-check/pymobiledevice3/remote/core_device/screen_capture_service.py` |
| RTP/HEVC depacketize and browser stream server | `/tmp/pymobiledevice3-check/pymobiledevice3/remote/core_device/screen_stream.py` |
| VNC server over decoded stream | `/tmp/pymobiledevice3-check/pymobiledevice3/remote/core_device/vnc_server.py` |
| CLI commands for display stream | `/tmp/pymobiledevice3-check/pymobiledevice3/cli/developer/core_device.py` |
| iOS 17 tunnel guide | `/tmp/pymobiledevice3-check/docs/guides/ios17-tunnels.md` |

### CoreDevice Preconditions

The `pymobiledevice3` iOS 17 tunnel guide says Apple moved developer service
access to CoreDevice/RemoteXPC flows starting with iOS 17. A trusted tunnel is
needed for many developer commands.

Practical prerequisites:

- Device is trusted/paired with the host.
- Developer Mode / developer service access is available.
- iOS 17+ requires an active RSD tunnel.
- Creating the tunnel may require elevated host privileges because it creates a
  TUN/TAP interface.
- On older iOS, use the DVT/Instruments path with mounted Developer Disk Image
  instead.

Xcode's public `devicectl` CLI confirms CoreDevice is the supported command-line
surface for device interaction and says JSON output is the stable automation
interface, but the installed Xcode 17 `devicectl device` help does not expose
display/mirror commands. The media stream feature should therefore be treated
as a private/internal CoreDevice capability discovered through traffic and
open-source implementations, not a public Apple API contract.

The local Xcode 17 CoreDevice framework does include private media stream
support. `CoreDevice.framework` contains strings such as `MediaStreamFunctions`,
`mediaStreamSupportInfo`, `mediaStreamServerStatus`, `startMediaStream(with:)`,
`stopMediaStream(with:)`, `deviceInfo.screenViewingURL`, and
`SnapshotFetchScreenshotsActionDeclaration`. Device metadata also advertises
`com.apple.coredevice.feature.viewdevicescreen`. Those symbols point to the
next reverse-engineering target if the older `displayservice` RemoteXPC service
name fails on newer iOS versions.

Direct probing confirmed the Swift ABI entry points exist:
`DeviceManager.shared`, `DeviceManager.awaitFullInitialization()`,
`RemoteDevice.viewScreen()`, and the `RemoteDevice` media-stream methods are
all present in `CoreDevice.framework` 518.31. `DeviceManager.shared` and
`awaitFullInitialization()` were callable from an ABI-only Swift probe. The
probe could not safely call `allDevices()` / `devices` / `viewScreen()` because
the framework does not ship `CoreDevice.swiftmodule`, and those APIs cross
private Swift generic/async type boundaries. Also, `screenViewingURL` currently
uses a `devices:` URL, but LaunchServices on this host has no registered
handler for that scheme.

## go-ios Route

The `go-ios` `ios screenshot` command uses the Instruments DTX screenshot
service:

```go
const screenshotServiceName string =
    "com.apple.instruments.server.services.screenshot"
```

It opens the Instruments connection, requests a channel for that screenshot
service, then calls:

```go
msg, err := d.channel.MethodCall("takeScreenshot")
imageBytes := msg.Payload[0].([]byte)
```

Its `--stream` mode is not a native video stream. It loops over
`TakeScreenshot()`, decodes each PNG, re-encodes it as JPEG, and serves those
JPEGs as multipart MJPEG:

```text
TakeScreenshot loop -> PNG -> JPEG encode -> multipart/x-mixed-replace
```

Relevant local source after checking `danielpaulus/go-ios`:

| Concern | File |
|---------|------|
| CLI `ios screenshot` | `/tmp/go-ios-check/cmd_device_diagnostics.go` |
| Screenshot save path | `/tmp/go-ios-check/main.go` |
| Instruments screenshot service | `/tmp/go-ios-check/ios/instruments/screenshot.go` |
| Instruments connection gates | `/tmp/go-ios-check/ios/instruments/helper.go` |

The connection helper shows the practical prerequisites:

- iOS before 17: Instruments service is gated by a mounted Developer Disk Image.
- iOS 17 and later: it needs an active tunnel to `com.apple.instruments.dtservicehub`.

That means this route is permission-light from the iOS UI perspective, but it
is not zero setup. The device must be trusted/paired, and the host must establish
the developer service path.

## libimobiledevice Route

`libimobiledevice` exposes an older `screenshotr` service:

```text
com.apple.mobile.screenshotr
```

Its docs describe it as retrieving a screenshot from the device and explicitly
note that a mounted developer image is required. The Debian
`idevicescreenshot` man page says the same thing: without a mounted developer
image, the screenshot service is not available.

This is simpler than go-ios conceptually, but it is a single-screenshot API.
Streaming would still be implemented as repeated screenshot capture. On modern
iOS, go-ios's Instruments/RSD route is more relevant than relying only on the
older `screenshotr` service.

## AirPlay Receiver Route

AirPlay mirroring is the likely class of technique used by many desktop tools
that advertise "no app permission" screen projection. It does not need our app
or ReplayKit extension, because the host acts as an AirPlay receiver and the
user starts iOS Screen Mirroring from Control Center.

Apple documents the user flow as:

- Device and receiver on the same Wi-Fi network.
- Open Control Center.
- Tap Screen Mirroring.
- Select the receiver.
- Enter a passcode if one is shown.

Open-source receivers such as RPiPlay implement AirPlay mirroring and receive
H264 video plus AAC audio. This is a true video path, not repeated screenshots.

Tradeoffs for DeviceKit:

- It is independent from XCTest and WDA.
- It is host-side and network/service-discovery heavy.
- It normally requires user interaction in Control Center.
- Bonjour/AirPlay discovery and pairing behavior are outside the current
  DeviceKit iOS/XCUITest server shape.
- It may be harder to make deterministic in automation labs than USB/RSD.

## Apple iPhone Mirroring And `mirroir-mcp`

`mirroir-mcp` does not open a CoreDevice service, XCTest session, or raw iPhone
media stream. It automates Apple's built-in macOS iPhone Mirroring application,
whose bundle identifier is `com.apple.ScreenContinuity`:

- `MirroringBridge.swift` finds the app and its window through macOS
  Accessibility and WindowServer APIs.
- `ScreenCapture.swift` invokes `/usr/sbin/screencapture` to capture the
  rendered Mac window as PNG.
- `ScreenRecorder.swift` invokes `screencapture -v -l <windowID>` to record the
  rendered Mac window.
- Input is sent to that window with macOS `CGEvent` APIs.

This proves a no-XCTest route exists, but it is a window-automation adapter
around Apple's Continuity implementation rather than an embeddable raw stream
client. The local iPhone Mirroring app links `ScreenContinuityServices` and
`ScreenSharingKit`; its UI binary describes separate audio/video and control
stream activation. It does not link CoreDevice.

Apple's operating requirements also make it a weak primary route for an
unattended multi-device lab:

- The Mac and iPhone must use the same Apple Account with two-factor
  authentication.
- Wi-Fi and Bluetooth must be enabled, and the devices must be near each other.
- The iPhone must be locked while mirroring is active.
- Apple supports one iPhone per Mac at a time.
- `mirroir-mcp` additionally needs macOS Accessibility and Screen Recording
  permissions.

It remains a useful fast proof-of-concept and fallback for a single local
device because it is independent from XCTest and uses Apple's real
audio/video stream.

## QuickTime / Valeria USB Video Route

QuickTime's wired iPhone screen capture path is a separate host-side video
route. Reverse-engineered implementations usually call the protocol
`Valeria`.

Strong local evidence on macOS 26.5:

- macOS ships the CoreMediaIO DAL plug-in
  `com.apple.cmio.DAL.iOSScreenCapture` and the launch service
  `com.apple.cmio.iOSScreenCaptureAssistant`.
- The SDK man page says the assistant provides audio/video capture from iOS
  devices through AVFoundation and allows multiple applications to capture
  from the same iOS device simultaneously.
- The assistant links `MobileDevice`, `AirPlayReceiver`, `CoreMediaIO`,
  `MediaToolbox`, and `VideoToolbox`.
- Its binary contains `Valeria`, `ISRStartStreamNeroValeria`,
  `val_EnqueueVideoSampleBuffer`, and `val_EnqueueAudioSampleBuffer`.

The open-source `quicktime_video_hack` and `ios-screen-record` projects provide
independent protocol implementations. Their documented flow is:

1. Send a vendor USB control request to expose the hidden QuickTime
   configuration.
2. Select the USB configuration containing a vendor-specific interface with
   subclass `0x2A` and four bulk endpoints.
3. Exchange Valeria clock and session messages.
4. Receive H264 video and audio in serialized CoreMedia sample buffers.

Real-device validation on an iPhone 14 Pro Max running iOS 26.5:

- Before activation, the device exposed five USB configurations.
- The Valeria activation request caused USB re-enumeration and exposed a sixth
  configuration.
- The host successfully selected `kUSBCurrentConfiguration = 6` and reached
  `USB connection ready, waiting for ping`.
- The old Python reference client then failed on its first endpoint read, so
  this run did not produce video frames.
- With configuration 6 activated and the raw USB handle released, the native
  CoreMediaIO property update succeeded, but AVFoundation and QuickTime did
  not enumerate a muxed iPhone screen source in the current device state.
- The device was restored to USB configuration 5, and CoreDevice returned to
  the connected state.

This verifies that the Valeria USB route still exists on iOS 26.5, but not yet
that the old open-source clients can consume the current protocol unchanged or
that Apple's native bridge can be activated without additional device-state
requirements.
The most important integration risk is that activating the hidden USB
configuration temporarily re-enumerates the device. We must verify whether
usbmuxd/CoreDevice/WDA sessions survive or can be re-established quickly while
the AV stream remains active.

Additional feasibility validation on June 13, 2026:

- `devicectl list devices` reported the iPhone 14 Pro Max as connected through
  CoreDevice after the USB experiments.
- IORegistry reported `bNumConfigurations = 6`, `kUSBCurrentConfiguration = 5`,
  and a USB device signature containing the vendor-specific `ff2a` interface
  marker.
- `pyusb`/`libusb` descriptor enumeration found configuration 6 with interface
  2 as `class=0xff`, `subclass=0x2a`, `protocol=0xff`, and endpoints
  `0x86`/`0x05`. This exactly matches the QuickTime / Valeria AV interface
  shape described by the open-source implementations.
- A short raw USB probe successfully selected configuration 6 and then restored
  configuration 5, but `libusb_claim_interface()` failed with
  `USBError: Other error` before the first Valeria ping/read. This means the
  route is present on the device, but a plain user-space libusb client on this
  macOS host is not yet sufficient to consume frames.
- **Root-level USB claim test (June 13, 2026):** `valeria_usb_claim_probe.py`
  confirmed the AV interface (config 6, intf 2, `class=0xff sub=0x2a`) is
  present and `set_configuration(6)` succeeds. Under `sudo`, `detach_kernel_driver`
  succeeds, but `libusb_claim_interface()` still returns `USBError: Other error`.
  This is definitive: it is not a file-permission or "another process owns the
  interface" problem — macOS's `IOUSBHost` model does not allow a userspace
  libusb process to claim exclusive access to a vendor-specific USB interface,
  **even as root**. The open-source Valeria clients (`quicktime_video_hack`,
  `ios-screen-record`) are designed for Linux/Windows where libusb can directly
  claim such interfaces; they cannot run on macOS without a kernel driver or a
  dedicated entitlement that grants USB interface access.
- The Apple CoreMediaIO bridge is present locally:
  `com.apple.cmio.DAL.iOSScreenCapture`,
  `com.apple.cmio.iOSScreenCaptureAssistant`, and
  `man 8 iOSScreenCaptureAssistant` says the DAL plug-in provides iOS
  audio/video capture through AVFoundation Capture APIs. The earlier failure to
  see a muxed source was a client-lifetime problem, not a device-state problem:
  a one-shot property set with no resident CMIO client gave the assistant's
  asynchronous MobileDevice -> Valeria handshake nothing to surface to. See the
  resolved result below.
- Offline protocol tests passed for the Python Valeria implementation:
  `PYTHONPATH=/tmp/ios-screen-record-check ../.venv/bin/python -m pytest -q`
  from `/tmp/ios-screen-record-check/test_case` produced `31 passed`.
- Offline protocol tests passed for the Go Valeria implementation's pure
  parsing/output packages with CGO disabled:
  `CGO_ENABLED=0 go test ./screencapture/common ./screencapture/coremedia ./screencapture/packet`.
  Full Go tests still need a GStreamer/glib environment, and raw USB packages
  need CGO/libusb.

### Apple CoreMediaIO bridge: muxed screen source surfaced (verified)

On June 13, 2026 the native Apple bridge was driven to expose a muxed iPhone
screen-capture source, using a resident CoreMediaIO client instead of a one-shot
property write. Tool:
`tools/coredevice-shim/CMIOScreenCaptureListener.m` (built/run by
`run-cmio-listener.sh`).

What it does:

- Sets both host gates on `kCMIOObjectSystemObject`:
  `kCMIOHardwarePropertyAllowScreenCaptureDevices` (`'yes '`) and
  `kCMIOHardwarePropertyAllowWirelessScreenCaptureDevices` (`'wscd'`) to `1`.
- Registers a `CMIOObjectAddPropertyListenerBlock` on
  `kCMIOHardwarePropertyDevices` and stays resident on a CFRunLoop, so
  `iOSScreenCaptureAssistant`'s asynchronous MobileDevice -> Valeria handshake
  has a live client to surface a device to.
- Snapshots the CMIO device list and the AVFoundation device sets
  (video + muxed) on every change, then restores the prior gate values on exit.

Observed sequence on the paired iPhone 14 Pro Max (iOS 26.5), USB at
`kUSBCurrentConfiguration = 5` throughout (no manual config-6 switch):

1. Immediately after setting the gates: 4 CMIO devices (two iPhone cameras, two
   Mac cameras); AVFoundation showed only camera video devices. No screen source.
2. ~5s later a `device-list-changed` callback fired and a fifth CMIO device
   appeared: `name=<device> model=iOS Device`,
   `uid=E1468882-8EFF-40CE-A4C3-957EF9A95A4E` — a different UID from the camera
   devices. AVFoundation simultaneously enumerated it under `AVMediaTypeMuxed`
   as `[iOS Device]`.
3. The muxed source persisted across the full resident window.
4. On exit, restoring `AllowScreenCaptureDevices`/`AllowWirelessScreenCaptureDevices`
   to `0` made the muxed `iOS Device` disappear again, confirming the resident
   allow-gate is the causal trigger, not a coincidental device transition.

Conclusion: the open question from the bullet above is resolved. The Apple
CoreMediaIO/iOSScreenCapture bridge does expose a muxed iPhone screen source on
iOS 26.5 without manually re-enumerating USB and without an in-app permission
prompt. The single missing ingredient previously was a *resident* CMIO client
holding the allow-gate open long enough for the assistant's async handshake. The
muxed `iOS Device` AVCaptureDevice is the entry point that corresponds to the
assistant's `ISRStartStreamNeroValeria` start path.

### First frame captured through the bridge (verified)

Also on June 13, 2026, the muxed device was driven all the way to first frame
and a sustained stream. Tool:
`tools/coredevice-shim/CMIOScreenCaptureFirstFrame.m` (built/run by
`run-cmio-firstframe.sh`). It sets the same allow-gates, opens an
`AVCaptureSession` against the muxed `iOS Device`, attaches an
`AVCaptureVideoDataOutput` plus `AVCaptureAudioDataOutput`, and counts
`CMSampleBuffer`s in the delegate.

Result on the paired iPhone 14 Pro Max (iOS 26.5), USB still at config 5:

- First video frame: `media=vide sub=2vuy 1290x2796`, delivered as a *decoded*
  `CVImageBuffer` (the Apple bridge hands back `2vuy` pixel buffers, not raw
  Annex-B H264 — VideoToolbox decode happens inside the bridge).
- Over a 30s window: 1637 video frames and 2441 audio frames (`lpcm`), i.e.
  roughly 54 fps video plus continuous audio. This confirms
  `ISRStartStreamNeroValeria` actually fires and frames flow, not just that the
  device enumerates.

Three preconditions were all required to reach first frame (each was a real
failure point before it was added):

1. **TCC camera authorization.** The muxed device is a camera-class capture
   device, so the host process needs `AVMediaTypeVideo` authorization. First run
   triggers the prompt; once granted it persists.
2. **Direct CMIO HAL device-list read + device-list property listener.** Asking
   only AVFoundation to enumerate does not poke the DAL plugin. The client must
   read `kCMIOHardwarePropertyDevices` via `CMIOObjectGetPropertyData` (and/or
   register `CMIOObjectAddPropertyListenerBlock`) on the system object.
3. **A serviced main runloop while waiting for the device to surface.** Blocking
   the main thread with `sleep` prevents the CMIO HAL from completing its
   connection to the assistant, and the muxed device never appears. Pumping the
   runloop (`[NSRunLoop runUntilDate:]`) during the poll is what made the device
   surface and frames start. This was the specific blocker that made the
   first two probe attempts fail while the runloop-driven listener always worked.

Net: the host-side, no-in-app-permission, no-manual-USB-reconfiguration screen
capture route is proven end to end on iOS 26.5 — from allow-gate to a sustained
~54 fps decoded video + audio stream through Apple's own CoreMediaIO bridge.

A Go demo wrapping the same recipe is at `tools/cmio-capture/` (module
`devicekit/tools/cmio-capture`). Build with `go build .`; usage:

```
cmio-capture -d 10 -o /tmp/cap.mov      # video-only (no audio track in file)
cmio-capture -d 10 -av -o /tmp/cap.mov  # video+audio
```

The package `cmio` exports a single `Record(output, duration, mode)` function
that can be used as a library. Error codes are returned as `cmio.Error`.

### CMIO bridge seizes the device audio channel (video-only not possible here)

Follow-up on June 13, 2026: capturing through the CoreMediaIO bridge takes over
the iPhone's audio output — on-device app playback is interrupted while a capture
session runs. It recovers once capture stops (verified), so this is in-capture
behavior, not a stuck state. Attempts to suppress it failed, and probing showed
why:

- Disabling the audio connection on `AVCaptureMovieFileOutput` (or omitting the
  audio data output) removes the audio *track from the file* but does NOT free
  the device audio channel — on-device playback is still interrupted.
- `tools/coredevice-shim/CMIODeviceProbe.m` enumerated the muxed device's
  streams: it exposes a single stream `VDC Video Stream`, direction=input,
  `MediaType = muxx` (muxed). There is no separate audio stream to leave
  inactive — audio and video are multiplexed in one stream.
- Static analysis of `iOSScreenCapture.plugin` / `iOSScreenCaptureAssistant`
  found only standard CMIO stream properties (`pft `, `nfrt`, `sdir`, etc.) — no
  custom audio enable/disable selector, and no video-only Valeria/FigNero
  variant. Audio is coupled to video through the `APValeriaHelper*` /
  `FigNeroStartStream` pipeline.

Conclusion: the CoreMediaIO bridge cannot capture video without seizing the
device audio channel; the coupling is baked into the muxed Valeria stream. For a
route that is pure video by protocol (no audio-channel takeover), use CoreDevice
displayservice (RTP/HEVC), tracked above and in
`docs/coredevice-displayservice-verification.md`.

Current feasibility verdict: the wired route is feasible as a host-side capture
route, because the real device exposes the expected Valeria USB interface and
two independent source implementations can parse/write the protocol fixtures.
A raw libusb client still cannot claim the AV bulk interface on this macOS host,
but that path is now secondary: Apple's own CoreMediaIO/iOSScreenCapture bridge
has been verified to surface the iPhone as a muxed AVFoundation device (see the
"muxed screen source surfaced" result above), which avoids manual USB
re-enumeration entirely. For DeviceKit, the recommended next step is to consume
frames through that bridge with an `AVCaptureSession`, treating the raw
pyusb/libusb Valeria client as a fallback for hosts where the bridge is
unavailable.

## Commercial Tools Such As i4Tools

i4Tools/AiSi Assistant is closed source, so its exact implementation cannot be
proved from public code. The current public behavior, checked again on
June 13, 2026, exposes at least two distinct projection products:

- The older AiSi Assistant `实时桌面` workflow connects the device to the PC,
  downloads matching support files, and offers live viewing plus screenshots.
  This is consistent with a developer-support-image-backed screenshot or
  Instruments path, but the exact service remains unverified.
- The current standalone `爱思投屏` product supports both wireless AirPlay and
  wired USB projection. Its official wired instructions require only USB
  trust and a driver, and advertise up to 60 FPS, high quality, and low
  latency without installing an iOS app.

Source-level validation should be read as route validation, not as proof of
i4Tools' private implementation. The strongest public-code evidence is:

- Wireless: RPiPlay commit `64d0341ed3bef098c940c9ed0675948870a271f9`
  registers `_raop._tcp` and `_airplay._tcp` with DNS-SD, handles the
  AirTunes/RAOP RTSP session, and passes decrypted mirroring payloads to H264
  video callbacks and AAC audio structures. This directly explains the iOS
  Control Center `屏幕镜像` workflow shown by AiSi's public instructions.
- Wired USB: `quicktime_video_hack` commit
  `d81396e2e7758d98c2a594853b64f98b54a8a871` and `ios-screen-record` commit
  `dbde61558004d5edf88e51d3104ae671d9374743` independently implement the same
  QuickTime / Valeria shape:
  - send USB control request `bmRequestType=0x40`, `bRequest=0x52`,
    `wIndex=0x02` to expose the hidden QuickTime configuration;
  - find/select the vendor-specific USB interface whose subclass is `0x2A`;
  - use bulk endpoints for the Valeria session;
  - parse `FEED` messages as video `CMSampleBuffer` data and `EAT!` messages
    as audio `CMSampleBuffer` data;
  - write video as Annex-B H264 NAL units plus raw/WAV audio.

Therefore the current wired AiSi behavior strongly matches the
QuickTime / Valeria class of implementation: trusted USB connection, host
driver, no iOS app, and a true high-frame-rate video stream. This is still a
high-confidence inference rather than direct proof. Direct proof would require
one of: AiSi source code, runtime USB traffic showing the `0x40/0x52` control
request and `0x2A` interface selection, or Bonjour/RTSP traffic for the wireless
path.

Its wireless mode is no longer just an inference: AiSi's own instructions say
the iOS device uses Control Center `屏幕镜像` and selects the host. That is the
AirPlay receiver route. The remaining unknown is which AirPlay implementation
AiSi uses internally.

"No permission" in these products means no iOS app-level screen recording
permission. It does not mean no trust pairing, no USB driver, no USB
re-enumeration, or no user interaction for wireless AirPlay.

## Fit For DeviceKit

### Best short-term experiment

Prototype a host-side QuickTime / Valeria helper first:

1. Reuse Apple's CoreMediaIO iOS screen capture bridge on macOS, or implement
   the documented Valeria USB protocol in a dedicated host helper.
2. Select the target by UDID and activate the hidden USB AV configuration.
3. Receive and persist H264 frames before adding any viewer or transcoding.
4. Re-establish the DeviceKit/WDA connection after USB re-enumeration.
5. In parallel, hammer DeviceKit/WDA `/source?format=json`.
6. Measure frame cadence, control latency, and reconnect behavior.

Keep the CoreDevice displayservice helper as a parallel research experiment:

1. Establish the same trust/pairing setup already needed for DeviceKit.
2. For iOS 17+, establish an RSD tunnel.
3. Attempt to open `com.apple.coredevice.displayservice`.
4. If exposed, receive the RTP/HEVC media stream and compare it with Valeria.

Fallback experiment if both video routes prove version-sensitive:

1. Connect to the target device through usbmuxd/RSD.
2. Open `com.apple.instruments.server.services.screenshot`.
3. Call `takeScreenshot` in a loop.
4. Serve the frames as MJPEG or encode them on the host.
5. In parallel, hammer DeviceKit/WDA `/source?format=json`.
6. Verify frame cadence does not collapse when XCUITest source is busy.

This fallback still tests XCTest independence, but it is unlikely to be the best
high-FPS path because it is repeated screenshot capture.

### Best long-term video path

Use a real video source:

- QuickTime / Valeria USB if deterministic wired capture is required.
- AirPlay receiver if user-driven mirroring is acceptable.
- CoreDevice displayservice if iOS 17+ developer-service mirroring is acceptable.
- Apple iPhone Mirroring if a single-device same-account Mac workflow is
  acceptable.
- ReplayKit Broadcast Upload Extension if app-bundled capture is acceptable.

These should outperform repeated screenshot loops at high FPS. go-ios-style
Instruments screenshots are still useful as a no-extension fallback, but they
are unlikely to match true HEVC/H264 mirroring for sustained 30/60 FPS.

## Implementation Boundary

The QuickTime / Valeria, go-ios, CoreDevice, Apple iPhone Mirroring, and AirPlay
approaches cannot live entirely inside `DeviceKitTests`. They require a
host-side binary/service because the iOS app process cannot control the host
USB configuration, open usbmuxd/RSD, or act as a desktop receiver.

For this repository, that suggests a split:

- Keep the current in-device `/mjpeg` as compatibility fallback.
- Add a host-side `devicekit-host` capture service for Valeria video, USB/RSD
  screenshot, or AirPlay receiver experiments.
- Let the existing DeviceKit/WDA server remain the control plane.
- Expose the host-side stream under a separate URL or proxy it through the host
  CLI/API.

## Sources

- go-ios source: https://github.com/danielpaulus/go-ios
- pymobiledevice3 source: https://github.com/doronz88/pymobiledevice3
- pymobiledevice3 PyPI package:
  https://pypi.org/project/pymobiledevice3/
- pymobiledevice3 v9.18.0 release:
  https://github.com/doronz88/pymobiledevice3/releases/tag/v9.18.0
- Frida DTX service example:
  https://frida.re/news/2024/05/31/frida-16-3-0-released/
- libimobiledevice feature list:
  https://libimobiledevice.org/docs/libimobiledevice/latest/
- libimobiledevice `screenshotr` docs:
  https://docs.libimobiledevice.org/libimobiledevice/latest/screenshotr_8h.html
- Debian `idevicescreenshot` man page:
  https://manpages.debian.org/testing/libimobiledevice-utils/idevicescreenshot.1.en.html
- Apple AirPlay mirroring support:
  https://support.apple.com/en-us/102661
- RPiPlay AirPlay receiver:
  https://github.com/FD-/RPiPlay
- RPiPlay source-level check:
  `/tmp/RPiPlay-check` at `64d0341ed3bef098c940c9ed0675948870a271f9`
  (`lib/dnssd.c`, `lib/raop.c`, `lib/raop_handlers.h`,
  `lib/raop_rtp_mirror.c`, `lib/stream.h`, `rpiplay.cpp`)
- Apple iPhone Mirroring requirements:
  https://support.apple.com/en-us/120421
- `mirroir-mcp` source:
  https://github.com/jfarcand/mirroir-mcp
- QuickTime / Valeria protocol reference and Go implementation:
  https://github.com/danielpaulus/quicktime_video_hack
- QuickTime / Valeria Go source-level check:
  `/tmp/quicktime_video_hack-check` at
  `d81396e2e7758d98c2a594853b64f98b54a8a871`
  (`screencapture/activator.go`, `screencapture/discovery.go`,
  `screencapture/usbadapter.go`, `screencapture/messageprocessor.go`,
  `screencapture/coremedia/avfilewriter.go`)
- Python Valeria implementation:
  https://github.com/YueChen-C/ios-screen-record
- Python Valeria source-level check:
  `/tmp/ios-screen-record-check` at
  `dbde61558004d5edf88e51d3104ae671d9374743`
  (`ioscreen/util.py`, `ioscreen/asyn.py`, `ioscreen/coremedia/consumer.py`)
- AiSi Assistant older `实时桌面` instructions:
  https://helper.i4.cn/news_detail_10338.html
- Current AiSi wired/wireless projection product:
  https://www.i4.cn/pro_screen.html
- AiSi wired projection instructions:
  https://www.i4.cn/news_detail_13235.html
- Local Apple documentation:
  `man 8 iOSScreenCaptureAssistant`
