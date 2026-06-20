# iOS 主机端投屏工具集

本仓库包含一组 macOS 主机端工具，用于通过 **CoreMediaIO (CMIO)**、**CoreDevice** 和 **USB Valeria** 等底层 Apple 协议，在不依赖 XCUITest / WDA 的情况下捕获 iOS 设备的屏幕画面和音频。

> 📖 详细的技术背景和分析见 [`docs/`](docs/) 目录。
> For English documentation, see [README_EN.md](README_EN.md).

## 核心发现

在 macOS 上，通过 CoreMediaIO 的 `com.apple.cmio.DAL.iOSScreenCapture` 插件，可以在不安装任何 on-device 应用的前提下，获取 iPhone 的实时屏幕画面（muxed video + audio）。

**关键前提**（三者缺一不可）：

1. **TCC 摄像头权限** — 终端（或调用进程）需在「系统设置 → 隐私与安全性 → 摄像头」中获得授权
2. **直接 CMIO HAL 读取** — 仅通过 AVFoundation 枚举设备不会触发 DAL 插件；必须直接读取 `kCMIOHardwarePropertyDevices` 并注册设备列表监听
3. **泵送主 RunLoop** — CMIO 插件通过异步回调完成与设备的握手；使用阻塞式 `sleep()` 将导致设备永远无法出现，必须用 `[NSRunLoop runUntilDate:]` 轮询等待

## 工具目录

### CMIO 屏幕捕获（已验证可工作 ✅）

| 工具 | 语言 | 功能 |
|------|------|------|
| [`CMIOScreenCaptureListener.m`](coredevice-shim/CMIOScreenCaptureListener.m) | Objective-C | 常驻 CMIO 客户端，设置 allow-gate 后持续监听设备列表变化，验证 muxed iOS 屏幕设备是否出现 |
| [`CMIOScreenCaptureFirstFrame.m`](coredevice-shim/CMIOScreenCaptureFirstFrame.m) | Objective-C | 打开 AVCaptureSession 连接到 muxed 设备，获取首帧视频数据 (`2vuy 1290x2796 ~54fps`)，验证 StartStream 成功 |
| [`CMIOScreenCaptureRecord.m`](coredevice-shim/CMIOScreenCaptureRecord.m) | Objective-C | 录制 muxed iOS 屏幕到 QuickTime `.mov` 文件，支持 video-only 和 av 模式 |
| [`CMIODeviceProbe.m`](coredevice-shim/CMIODeviceProbe.m) | Objective-C | 枚举 muxed 设备的 stream 和属性，用于探索能否实现纯视频捕获（不占用设备音频通道） |
| [`cmio-capture/`](cmio-capture/) | Go + CGO | Go 语言封装的 CMIO 屏幕录制命令行工具，支持多设备选择 |

**快速开始：**

```bash
# 1. 启动 CMIO 监听器，观察 muxed 设备是否出现
./coredevice-shim/run-cmio-listener.sh

# 2. 获取首帧验证流可用
./coredevice-shim/run-cmio-firstframe.sh

# 3. 录制 10 秒屏幕（仅视频，不占用设备音频）
./coredevice-shim/run-cmio-record.sh 10 /tmp/screen.mov

# 4. 录制 10 秒屏幕（含音频，会抢占设备音频通道）
./coredevice-shim/run-cmio-record.sh 10 /tmp/screen.mov av

# 5. Go 版本录制工具
cd cmio-capture && go run . -d 10 -o /tmp/screen.mov
```

**已知限制：** CMIO muxed 设备只暴露一个 `muxx` 类型的 stream（音视频复用），禁用 AVCaptureMovieFileOutput 的音频连接只能去掉文件中的音轨，但无法释放设备的音频通道。捕获期间，iPhone 上其他 app 的音频播放会被中断，停止捕获后恢复。

### CoreDevice DisplayService 探针（探索中 🔬）

| 工具 | 功能 |
|------|------|
| [`CoreDeviceProbe.swift`](coredevice-shim/CoreDeviceProbe.swift) | 通用 CoreDevice 探测器，支持 `--view-screen`、`--media-support-info`、`--make-video-stream` 等参数 |
| [`DisplayServiceSocketProbe.swift`](coredevice-shim/DisplayServiceSocketProbe.swift) | 通过 Unix Domain Socket 连接 `com.apple.coredevice.displayservice` |
| [`DisplayServiceRemoteXPCProbe.swift`](coredevice-shim/DisplayServiceRemoteXPCProbe.swift) | 通过 RemoteXPC 连接 display service，探索不同 connection mode |
| [`MediaStreamProbe.swift`](coredevice-shim/MediaStreamProbe.swift) | CoreDevice 媒体流探测器 |
| [`MediaStreamFunctionsProbe.swift`](coredevice-shim/MediaStreamFunctionsProbe.swift) | 探测 CoreDevice 的媒体相关函数 |
| [`ScreenViewingURLProbe.swift`](coredevice-shim/ScreenViewingURLProbe.swift) | 获取屏幕查看 URL |

**当前状态：** macOS 26.5 上的 CoreDevice.framework (518.31) 硬编码了 `getmediasupportinfo` capability，但该设备不再声明此能力（改为 `viewdevicescreen`）。`makeVideoStream` 可成功创建，但 `activate()` 返回 `CoreDeviceError 1001`。需要新版 macOS/Xcode 的 CoreDevice framework 或逆向分析新 capability。

### Valeria USB 原始访问

| 工具 | 功能 |
|------|------|
| [`valeria_usb_claim_probe.py`](coredevice-shim/valeria_usb_claim_probe.py) | 诊断为何 macOS 上 libusb 无法 claim iPhone 的 Valeria AV 接口（USB config 6, interface 2, 0xff/0x2a） |

**结论：** macOS IOUSBHost 模型阻止用户态独占 claim vendor-specific 接口 — 即使 `detach_kernel_driver` 成功，`libusb_claim_interface()` 仍返回 `USBError: Other error`。开源 Valeria 客户端仅支持 Linux/Windows。

## 编译环境

### CMIO 工具（Objective-C）

```bash
# 所有 .m 文件均使用 Foundation + CoreMediaIO + AVFoundation 框架
# run-*.sh 脚本会自动调用 clang 编译
clang -framework Foundation -framework CoreMediaIO -framework AVFoundation \
      -framework CoreMedia -fobjc-arc \
      -o tool_name tool_name.m
```

### CoreDevice 探针（Swift）

需要 macOS 26+ 且 Xcode 中包含私有框架的 `.swiftinterface` 文件。本仓库提供了预提取的模块接口：

- `coredevice-shim/CoreDevice.swiftmodule/`
- `coredevice-shim/CoreDeviceMediaStreamSupport.swiftmodule/`
- `coredevice-shim/CoreDeviceProtocols.swiftmodule/`

### RemoteXPC Shim

`coredevice-shim/RemoteXPCShim/` 提供了一个最小化的 RemoteXPC 桥接层，用于通过 RemoteXPC 协议连接 iOS 设备的 CoreDevice 服务。

### Go CMIO Capture

```bash
cd cmio-capture
go build -o cmio-capture .
./cmio-capture -list              # 列出可用设备
./cmio-capture -d 10 -o out.mov   # 录制 10 秒
./cmio-capture -d 30 -av -device "iPhone" -o capture.mov  # 含音频录制
```

## 相关文档

| 文档 | 内容 |
|------|------|
| [`ios-host-screen-capture-options.md`](docs/ios-host-screen-capture-options.md) | iOS 主机端投屏方案全景对比 |
| [`coredevice-displayservice-verification.md`](docs/coredevice-displayservice-verification.md) | CoreDevice DisplayService 验证记录 |
| [`cmio-go-capture-implementation.md`](docs/cmio-go-capture-implementation.md) | Go 语言 CMIO 捕获实现细节 |

## 许可

待定。本工具集仅供研究和开发参考。
