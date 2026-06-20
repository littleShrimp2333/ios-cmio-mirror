# CoreDevice Displayservice 验证记录

## 当前结论

验证日期：2026 年 6 月 13 日。

在 iPhone 14 Pro Max（iOS 26.5，`23F77`）上，已经确认 CoreDevice 可以在
**不启动 XCTest/XCUITest/WDA** 的情况下识别设备并进入屏幕查看流程。

已验证成功：

- USB 配对、开发者模式、DDI 服务和 RSD tunnel 正常。
- `pymobiledevice3` 可通过 CoreDevice 获取显示信息。
- 原生 Swift shim 可调用 `DeviceManager.shared`、
  `awaitFullInitialization()` 和 `allDevices()`。
- 原生 Swift shim 可调用 `RemoteDevice.viewScreen()`，全程不依赖 XCTest。

尚未验证成功：

- iOS 26.5 上可嵌入到自有宿主进程的 RTP/HEVC 实时视频流。
- `pymobiledevice3 9.18.0` 的旧版 `displayservice` 和
  `screencaptureservice` 无法在该设备上启动。
- `RemoteDevice.viewScreen()` 不直接返回视频帧，而是尝试打开
  `devices://device/open?id=...`。当前 Mac 没有注册该 URL scheme 的应用，
  因此启动查看器失败。
- `CoreDeviceMediaStreamSupport` 可以创建主屏镜像接收器，但 `activate()`
  在旧媒体 capability 检查处失败，尚未收到第一帧。

因此，**“CoreDevice 屏幕查看入口无需 XCTest”已经得到验证**；但
**“画面能够成功显示”以及“DeviceKit 可以直接嵌入 CoreDevice 视频流”**
仍需继续验证。

## 验证目标

目标是确认 CoreDevice 能否作为宿主机侧的高帧率投屏方案，并避免
XCTest/WDA 内部截图与 UI tree dump 互相争抢资源。

理想架构如下：

```text
iPhone
  -> CoreDevice / RemoteXPC / RSD tunnel
  -> 宿主机视频接收进程
  -> HEVC 解码或转发
```

这条路径在宿主机运行，不需要在 XCUITest runner 内调用截图接口。

## 真机环境

| 项目 | 结果 |
|---|---|
| 设备 | iPhone 14 Pro Max（`iPhone15,3`） |
| iOS | 26.5（`23F77`） |
| 连接 | USB |
| 配对 | `paired` |
| 开发者模式 | `enabled` |
| DDI 服务 | `ddiServicesAvailable: true` |
| CoreDevice tunnel | `connected` |
| Xcode | 26.5（`17F42`） |
| CoreDevice.framework | 518.31 |
| pymobiledevice3 | 9.18.0 |

注意：系统当前 `xcode-select` 指向 CommandLineTools。运行 `devicectl`
时需要显式设置：

```shell
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun devicectl list devices
```

## pymobiledevice3 路径

`pymobiledevice3` 使用的显示服务名称为：

```text
com.apple.coredevice.displayservice
```

视频流流程是宿主机先绑定 UDP socket，再通过 RemoteXPC 请求设备向宿主机
发送 RTP/HEVC 数据。

显示信息查询成功：

```shell
/tmp/pymd3-verify-venv/bin/python -m pymobiledevice3 developer core-device \
  get-display-info --tunnel 00008120-00166CC802FB601E
```

实测返回主屏幕尺寸 `1290 x 2796`、刷新率 `120 Hz`。

但以下媒体服务命令都失败并返回 `Failed to start service`：

```shell
pymobiledevice3 developer core-device display get-media-support-info
pymobiledevice3 developer core-device display get-media-stream-server-status
pymobiledevice3 developer core-device display start-video-stream /tmp/cap.rtp
pymobiledevice3 developer core-device screen-capture screenshot /tmp/screen.png
```

这说明配对、tunnel 和通用 CoreDevice 通道正常，失败范围集中在 iOS 26.5
上的私有媒体流/截图服务。Apple 很可能已经迁移到新的
`viewdevicescreen` / `MediaStreamFunctions` 路径。

## 原生 CoreDevice.framework 探针

CoreDevice 没有公开 Swift module interface，但二进制中存在以下 Swift
ABI 符号：

```text
CoreDevice.DeviceManager.shared
CoreDevice.DeviceManager.awaitFullInitialization()
CoreDevice.DeviceManager.allDevices()
CoreDevice.RemoteDevice.viewScreen()
CoreDevice.RemoteDevice.mediaStreamSupportInfo
CoreDevice.RemoteDevice.mediaStreamServerStatus
CoreDevice.RemoteDevice.startMediaStream(with:)
CoreDevice.RemoteDevice.stopMediaStream(with:)
CoreDevice.MediaStreamFunctions
```

仓库中的最小私有 module shim 位于：

```text
tools/coredevice-shim/
```

枚举设备：

```shell
tools/coredevice-shim/run-probe.sh
```

实测结果：

```text
Waiting for CoreDevice initialization...
CoreDevice devices: 1
- 215FC4CA-24D4-5ACD-BEE4-58307313317D:
  小虾米的新iphone (Connected, iOS 26.5 23F77, ...)
```

调用屏幕查看入口：

```shell
tools/coredevice-shim/run-probe.sh --view-screen
```

实测结果：

```text
No application knows how to open URL
devices://device/open?id=215FC4CA-24D4-5ACD-BEE4-58307313317D

viewScreen failed:
CoreDeviceError(errorCode: 10004, ...)
```

这个结果证明：

1. `RemoteDevice.viewScreen()` 可以在不启动 XCTest 的宿主进程中调用。
2. 它可以正确解析当前连接的真机。
3. 它本身不是返回视频帧的 API，而是通过 LaunchServices 打开
   `screenViewingURL`。
4. 当前 Mac 没有注册 `devices:` scheme 的 macOS 应用，因此查看器启动失败。
5. 本机找到的唯一 `Devices.app` 位于 iOS Simulator runtime，不能作为
   macOS 投屏宿主。

## Apple 私有媒体流证据

本机 `CoreDevice.framework` 和 `CoreDeviceMediaStreamSupport.framework`
包含以下符号或字符串：

```text
MediaStreamFunctions
mediaStreamSupportInfo
mediaStreamServerStatus
startMediaStream(with:)
stopMediaStream(with:)
CoreDeviceScreenSharing
PrimaryVideoStreamReceiveAVC
SecondaryVideoStreamReceiveAVC
VideoStream.start: creating AVCScreenCapture
```

这说明 Apple 的 CoreDevice 栈确实包含独立于 XCTest 的原生视频接收能力。
下一步不应继续围绕 `viewScreen()` 获取帧，而应直接补齐
`MediaStreamFunctions` 所需的私有 Swift 类型声明。

## CoreDeviceMediaStreamSupport 真机验证

本轮已补齐以下 Apple 私有高层 API 的最小 Swift module shim：

```text
CoreDeviceMediaStreamSupport.MediaStreamSession
CoreDeviceMediaStreamSupport.VideoStreamConfiguration.receiveMirroredPrimary
CoreDeviceMediaStreamSupport.VideoStream.activate
```

运行：

```shell
tools/coredevice-shim/run-media-probe.sh
```

创建主屏镜像接收器成功：

```text
makeVideoStream succeeded:
<CoreDeviceMediaStreamSupport.PrimaryVideoStreamReceiveAVC: ...>
```

这证明 `CoreDeviceMediaStreamSupport` 能识别真机并创建视频接收器，且整个流程
不依赖 XCTest。

调用 `activate()` 后失败：

```text
CoreDeviceError Code=1001
The capability "Create Service Socket" is not supported by this device.
CapabilityFeatureIdentifier=com.apple.coredevice.feature.getmediasupportinfo
```

与此同时，`devicectl device info details` 显示 iOS 26.5 实际广告：

```text
com.apple.dt.servicesocket.create
com.apple.coredevice.feature.viewdevicescreen
```

设备没有广告旧的 `com.apple.coredevice.feature.getmediasupportinfo`。因此，
当前失败点不是 XCTest，也不是无法构造视频接收器，而是
`CoreDeviceMediaStreamSupport 518.31` 激活时仍使用 iOS 26.5 未广告的旧
媒体 capability。该结果与 `pymobiledevice3 9.18.0` 启动旧
`displayservice` 失败一致。

CoreDevice 还包含 `ScreenViewingURLHelper`，支持 `preferred`、`VNC` 和
`Devices` URL 类型。仓库已加入 `run-screen-url-probe.sh`。

真机结果：

```text
deviceInfo.screenViewingURL:
devices://device/open?id=215FC4CA-24D4-5ACD-BEE4-58307313317D

preferred: devices://device/open?id=215FC4CA-24D4-5ACD-BEE4-58307313317D
VNC: nil
Devices: devices://device/open?id=215FC4CA-24D4-5ACD-BEE4-58307313317D
```

因此 iOS 26.5 当前真机配置不会生成 VNC URL，`preferred` 仍然选择
`devices:` 高层查看器。

## 新版路由真机验证

原生 shim 已补齐并验证当前 CoreDevice 的两条新版传输 capability：

```text
com.apple.dt.servicesocket.create
com.apple.dt.serviceconnection.create
```

原始 service-socket 路由的正向对照成功：

```shell
tools/coredevice-shim/run-displayservice-socket-probe.sh \
  com.apple.instruments.dtservicehub
# socket opened: fd=4
```

它也能通过 feature identifier 打开 `getdisplayinfo`，但
`com.apple.coredevice.displayservice`、`viewdevicescreen` 和旧媒体 feature
均返回 CoreDevice error 1001。

RemoteXPC service-connection 路由也通过独立正向对照：

```shell
tools/coredevice-shim/run-displayservice-remotexpc-probe.sh \
  --feature com.apple.coredevice.feature.getdisplayinfo 0
# createServiceConnection supported: true
# RemoteXPC connection opened: <OS_xpc_remote_connection: ...>
```

同一条 RemoteXPC 路由在 connection mode `0`、`1`、`2` 下均无法打开
`com.apple.coredevice.displayservice`，也不能直接把
`com.apple.coredevice.feature.viewdevicescreen` 映射成 RemoteXPC 连接。

因此可以排除“新版路由尚未适配”这个变量：新版 socket 和 RemoteXPC 路由
都已在 iOS 26.5 真机上通过正向对照，但该设备没有通过这两条路由暴露
`com.apple.coredevice.displayservice`。`getdisplayinfo` 是可用对照，
屏幕查看则仍属于更高层 capability 或 URL 启动流程。

## 下一步验证计划

1. 从 CoreDevice Swift metadata 和符号中继续还原以下精确类型布局：

```text
DeviceMediaStream.SupportInfoResponse
DeviceMediaStream.DeviceServerInfo
DeviceMediaStream.StartRequest
DeviceMediaStream.StartResponse
DeviceMediaStream.StopRequest
DeviceMediaStream.StopResponse
```

2. 扩展 `tools/coredevice-shim`，直接调用：

```text
mediaStreamSupportInfo
mediaStreamServerStatus
startMediaStream(with:)
```

3. 追踪更高层 `viewdevicescreen` / `devices:` 工作流使用的实际服务和握手。
4. 获取并解码视频接收流，记录帧率、码率、CPU 和内存。
5. 同时高频请求 DeviceKit/WDA `/source?format=json`。
6. 若视频帧率在 UI tree 压力下保持稳定，即可确认该方案解决 XCTest
   内部截图竞争问题。

## 决策

CoreDevice 仍然是最值得继续投入的宿主机高帧率投屏方向。

当前已能确定它的屏幕查看入口不依赖 XCTest；但由于缺少 `devices:` scheme
宿主，本轮没有成功显示画面。也不能把 `pymobiledevice3 9.18.0` 的
`displayservice` 实现视为 iOS 26.5 可直接使用的方案。下一阶段应优先实现
新版 service-socket 路由或 VNC URL helper，而不是继续把
`RemoteDevice.viewScreen()` 当作视频帧接口。原生
`CoreDeviceMediaStreamSupport` 已证明能创建接收器，但激活仍受旧 capability
限制。新版 service-socket 与 service-connection 路由已经完成适配和正向
验证，但该真机没有通过它们暴露 `com.apple.coredevice.displayservice`。
`ScreenViewingURLHelper.VNC` 也已确认返回 `nil`。仓库新增
`run-media-functions-probe.sh` 用于直接验证 `MediaStreamFunctions`；当前新
Swift/JIT 进程受宿主 `taskgated` 装载状态阻塞，待其恢复后可直接运行。

`go-ios` / Instruments 循环截图可以作为回退方案，但它是重复截图转 MJPEG，
不是真正的视频流。`pymobiledevice3` 为 GPL-3.0，应主要作为协议和实现参考，
除非产品许可策略明确允许直接复用。

## 参考来源

- [pymobiledevice3 源码](https://github.com/doronz88/pymobiledevice3)
- [pymobiledevice3 PyPI](https://pypi.org/project/pymobiledevice3/)
- [pymobiledevice3 v9.18.0](https://github.com/doronz88/pymobiledevice3/releases/tag/v9.18.0)
