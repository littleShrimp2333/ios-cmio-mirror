import CoreDevice
import Foundation

func log(_ message: String) {
    fputs("\(message)\n", stderr)
}

log("Waiting for CoreDevice initialization...")
let manager = DeviceManager.shared
await manager.awaitFullInitialization()

guard let device = manager.allDevices().first else {
    fputs("No CoreDevice device is available.\n", stderr)
    Foundation.exit(2)
}

let deviceInfo = device.deviceInfo
log("deviceInfo.screenViewingURL: \(deviceInfo.screenViewingURL?.absoluteString ?? "nil")")

for (name, type) in [
    ("preferred", ScreenViewingURLHelper.ScreenViewingURLType.preferred),
    ("VNC", .VNC),
    ("Devices", .Devices),
] {
    log("Constructing \(name) URL...")
    let url = ScreenViewingURLHelper.url(for: deviceInfo, withType: type)
    log("\(name): \(url?.absoluteString ?? "nil")")
}
