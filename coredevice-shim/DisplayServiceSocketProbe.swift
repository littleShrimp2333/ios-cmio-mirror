import CoreDevice
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let useFeatureIdentifier = arguments.first == "--feature"
let target = useFeatureIdentifier
    ? (arguments.dropFirst().first ?? "com.apple.coredevice.feature.viewdevicescreen")
    : (arguments.first ?? "com.apple.coredevice.displayservice")

print("Waiting for CoreDevice initialization...")
let manager = DeviceManager.shared
await manager.awaitFullInitialization()

guard let device = manager.allDevices().first else {
    fputs("No CoreDevice device is available.\n", stderr)
    Foundation.exit(2)
}

print("createServiceSocket supported: \(device.supports(.createServiceSocket))")
print("Opening \(useFeatureIdentifier ? "feature" : "service") socket: \(target)")

do {
    let serviceSocket = try await device.getImplementation(for: .createServiceSocket)
    let handle = if useFeatureIdentifier {
        try await serviceSocket.fileHandle(toFeatureIdentifiedBy: target)
    } else {
        try await serviceSocket.fileHandle(toServiceNamed: target)
    }
    print("socket opened: fd=\(handle.fileDescriptor)")
    try handle.close()
    print("socket closed")
} catch {
    fputs("socket failed: \(error)\n", stderr)
    Foundation.exit(1)
}
