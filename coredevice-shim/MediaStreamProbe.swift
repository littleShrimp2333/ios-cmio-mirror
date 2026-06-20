import CoreDevice
import CoreDeviceMediaStreamSupport
import Foundation
import QuartzCore

print("Waiting for CoreDevice initialization...")
let manager = DeviceManager.shared
await manager.awaitFullInitialization()

guard let device = manager.allDevices().first else {
    fputs("No CoreDevice device is available.\n", stderr)
    Foundation.exit(2)
}

print("Creating mirrored-primary video stream for \(device.deviceIdentifier)...")
let layer = CALayer()
let configuration = VideoStreamConfiguration.receiveMirroredPrimary(
    layer: layer,
    timeout: 15
)
let session = MediaStreamSession(clientSessionID: UUID())

do {
    let stream = try await session.makeVideoStream(
        withConfiguration: configuration,
        fromRemoteDevice: device
    )
    print("makeVideoStream succeeded: \(String(reflecting: stream))")

    let events = try await stream.activate()
    print("activate succeeded; waiting for video events...")

    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask {
            for try await event in events {
                switch event {
                case .receivedFirstFrame:
                    print("receivedFirstFrame")
                    await stream.requestLastDecodedFrame()
                case let .receivedLastDecodedFrame(data):
                    print("receivedLastDecodedFrame: \(data.count) bytes")
                    try data.write(to: URL(fileURLWithPath: "/tmp/coredevice-last-frame.bin"))
                    return
                case let .remoteVideoAttributesChanged(attributes):
                    print("remoteVideoAttributesChanged: \(String(reflecting: attributes))")
                }
            }
        }
        group.addTask {
            try await Task.sleep(for: .seconds(20))
            throw ProbeError.timeout
        }

        try await group.next()
        group.cancelAll()
    }

    await stream.invalidate()
    print("video stream invalidated")
} catch {
    fputs("media stream probe failed: \(error)\n", stderr)
    Foundation.exit(1)
}

enum ProbeError: Error {
    case timeout
}
