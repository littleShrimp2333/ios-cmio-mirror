import CoreDevice
import Foundation

func log(_ message: String) {
    fputs("\(message)\n", stderr)
}

log("Waiting for CoreDevice initialization...")
let manager = DeviceManager.shared
await manager.awaitFullInitialization()

guard let device = manager.allDevices().first else {
    log("No CoreDevice device is available.")
    Foundation.exit(2)
}

log("Calling MediaStreamFunctions.mediaStreamSupportInfo...")

do {
    let response = try await MediaStreamFunctions(device: device).mediaStreamSupportInfo
    log("device: \(response.device)")
    log("client: \(response.client)")
    log("common: \(response.common)")
} catch {
    log("mediaStreamSupportInfo failed: \(error)")
    Foundation.exit(1)
}
