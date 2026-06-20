# iOS Host-Side Screen Capture Toolkit

A collection of macOS host-side tools for capturing iOS device screen and audio using low-level Apple protocols — **CoreMediaIO (CMIO)**, **CoreDevice**, and **USB Valeria** — without depending on XCUITest or WebDriverAgent.

> 📖 For detailed technical background, see the [`docs/`](docs/) directory.
> 中文文档见 [README.md](README.md).

## Core Discovery

On macOS, the CoreMediaIO `com.apple.cmio.DAL.iOSScreenCapture` plugin can surface an iPhone's real-time screen as a muxed AVFoundation capture device — no on-device app installation required.

**Three non-negotiable prerequisites:**

1. **TCC Camera Authorization** — The terminal (or calling process) must be authorized under System Settings → Privacy & Security → Camera
2. **Direct CMIO HAL Read** — Enumerating devices through AVFoundation alone will NOT trigger the DAL plugin; you must directly read `kCMIOHardwarePropertyDevices` and register a device-list property listener
3. **Pump the Main RunLoop** — The CMIO plugin completes its device handshake through async callbacks; a blocking `sleep()` permanently prevents the device from appearing. Use `[NSRunLoop runUntilDate:]` to poll while waiting

## Tools

### CMIO Screen Capture (Verified ✅)

| Tool | Language | Purpose |
|------|----------|---------|
| [`CMIOScreenCaptureListener.m`](coredevice-shim/CMIOScreenCaptureListener.m) | Objective-C | Resident CMIO client that sets allow-gates and monitors device list changes, verifying that the muxed iOS screen device appears |
| [`CMIOScreenCaptureFirstFrame.m`](coredevice-shim/CMIOScreenCaptureFirstFrame.m) | Objective-C | Opens an AVCaptureSession on the muxed device, captures the first video frame (`2vuy 1290x2796 ~54fps`), proving StartStream works |
| [`CMIOScreenCaptureRecord.m`](coredevice-shim/CMIOScreenCaptureRecord.m) | Objective-C | Records the muxed iOS screen to a QuickTime `.mov` file, with video-only and av modes |
| [`CMIODeviceProbe.m`](coredevice-shim/CMIODeviceProbe.m) | Objective-C | Enumerates muxed device streams and properties, exploring whether pure-video capture (without seizing the audio channel) is possible |
| [`cmio-capture/`](cmio-capture/) | Go + CGO | Go-based CMIO screen recording CLI with multi-device support |

**Quick Start:**

```bash
# 1. Start CMIO listener to observe muxed device appearance
./coredevice-shim/run-cmio-listener.sh

# 2. Capture first frame to verify stream availability
./coredevice-shim/run-cmio-firstframe.sh

# 3. Record 10 seconds (video-only, preserves device audio)
./coredevice-shim/run-cmio-record.sh 10 /tmp/screen.mov

# 4. Record 10 seconds (with audio, seizes device audio channel)
./coredevice-shim/run-cmio-record.sh 10 /tmp/screen.mov av

# 5. Go-based recorder
cd cmio-capture && go run . -d 10 -o /tmp/screen.mov
```

**Known Limitation:** The CMIO muxed device exposes only a single `muxx`-type stream (audio+video multiplexed). Disabling the audio connection on AVCaptureMovieFileOutput removes the audio track from the file but does NOT release the device's audio channel. During capture, audio playback from other apps on the iPhone is interrupted; it recovers after capture stops.

### CoreDevice DisplayService Probes (Exploring 🔬)

| Tool | Purpose |
|------|---------|
| [`CoreDeviceProbe.swift`](coredevice-shim/CoreDeviceProbe.swift) | General-purpose CoreDevice probe with flags: `--view-screen`, `--media-support-info`, `--make-video-stream` |
| [`DisplayServiceSocketProbe.swift`](coredevice-shim/DisplayServiceSocketProbe.swift) | Connects to `com.apple.coredevice.displayservice` via Unix Domain Socket |
| [`DisplayServiceRemoteXPCProbe.swift`](coredevice-shim/DisplayServiceRemoteXPCProbe.swift) | Connects to display service via RemoteXPC, exploring different connection modes |
| [`MediaStreamProbe.swift`](coredevice-shim/MediaStreamProbe.swift) | CoreDevice media stream probe |
| [`MediaStreamFunctionsProbe.swift`](coredevice-shim/MediaStreamFunctionsProbe.swift) | Probes CoreDevice media-related functions |
| [`ScreenViewingURLProbe.swift`](coredevice-shim/ScreenViewingURLProbe.swift) | Retrieves screen viewing URL |

**Current Status:** CoreDevice.framework (518.31) on macOS 26.5 hardcodes the `getmediasupportinfo` capability, but the device no longer advertises it (now advertises `viewdevicescreen`). `makeVideoStream` succeeds, but `activate()` returns `CoreDeviceError 1001`. Requires a newer macOS/Xcode CoreDevice framework or reverse-engineering of the new capability.

### Valeria USB Raw Access

| Tool | Purpose |
|------|---------|
| [`valeria_usb_claim_probe.py`](coredevice-shim/valeria_usb_claim_probe.py) | Diagnoses why libusb cannot claim the iPhone's Valeria AV interface (USB config 6, interface 2, 0xff/0x2a) on macOS |

**Conclusion:** macOS IOUSBHost model blocks userspace exclusive claim of vendor-specific interfaces — even with `detach_kernel_driver` succeeding, `libusb_claim_interface()` returns `USBError: Other error`. Open-source Valeria clients are Linux/Windows-only.

## Build Environment

### CMIO Tools (Objective-C)

```bash
# All .m files use Foundation + CoreMediaIO + AVFoundation frameworks
# run-*.sh scripts invoke clang automatically
clang -framework Foundation -framework CoreMediaIO -framework AVFoundation \
      -framework CoreMedia -fobjc-arc \
      -o tool_name tool_name.m
```

### CoreDevice Probes (Swift)

Requires macOS 26+ with Xcode containing private framework `.swiftinterface` files. Pre-extracted module interfaces are provided:

- `coredevice-shim/CoreDevice.swiftmodule/`
- `coredevice-shim/CoreDeviceMediaStreamSupport.swiftmodule/`
- `coredevice-shim/CoreDeviceProtocols.swiftmodule/`

### RemoteXPC Shim

`coredevice-shim/RemoteXPCShim/` provides a minimal RemoteXPC bridge layer for connecting to iOS device CoreDevice services over the RemoteXPC protocol.

### Go CMIO Capture

```bash
cd cmio-capture
go build -o cmio-capture .
./cmio-capture -list              # List available devices
./cmio-capture -d 10 -o out.mov   # Record 10 seconds
./cmio-capture -d 30 -av -device "iPhone" -o capture.mov  # Record with audio
```

## Related Documentation

| Document | Content |
|----------|---------|
| [`ios-host-screen-capture-options.md`](docs/ios-host-screen-capture-options.md) | Comprehensive comparison of iOS host-side screen capture approaches |
| [`coredevice-displayservice-verification.md`](docs/coredevice-displayservice-verification.md) | CoreDevice DisplayService verification notes |
| [`cmio-go-capture-implementation.md`](docs/cmio-go-capture-implementation.md) | Go CMIO capture implementation details |

## License

TBD. This toolkit is provided for research and development reference.
