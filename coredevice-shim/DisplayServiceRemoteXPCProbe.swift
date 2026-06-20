import CoreDevice
import Dispatch
import Foundation
import RemoteXPCShim

let arguments = Array(CommandLine.arguments.dropFirst())
let usesFeatureIdentifier = arguments.first == "--feature"
let targetIndex = usesFeatureIdentifier ? 1 : 0
let target = arguments.indices.contains(targetIndex)
    ? arguments[targetIndex]
    : "com.apple.coredevice.displayservice"
let modeIndex = targetIndex + 1
let connectionMode = arguments.indices.contains(modeIndex)
    ? UInt64(arguments[modeIndex]) ?? 0
    : 0

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

let targetKind = usesFeatureIdentifier ? "feature" : "service"
log("Opening RemoteXPC \(targetKind): \(target), connectionMode=\(connectionMode)")

do {
    log("createServiceConnection supported: \(device.supports(.createServiceConnection))")
    let serviceConnection = try await device.getImplementation(for: .createServiceConnection)
    let queue = DispatchQueue(label: "devicekit.coredevice.remotexpc")
    let connection: xpc_remote_connection_t
    if usesFeatureIdentifier {
        connection = try await serviceConnection.remoteXPCConnection(
            toFeatureIdentifiedBy: target,
            connectionMode: connectionMode,
            handlingEventsOn: queue
        )
    } else {
        connection = try await serviceConnection.remoteXPCConnection(
            toServiceNamed: target,
            connectionMode: connectionMode,
            handlingEventsOn: queue
        )
    }
    log("RemoteXPC connection opened: \(String(reflecting: connection))")
} catch {
    fputs("RemoteXPC connection failed: \(error)\n", stderr)
    Foundation.exit(1)
}
