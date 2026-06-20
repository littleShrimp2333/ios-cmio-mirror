import CoreDevice
import CoreDeviceMediaStreamSupport
import Foundation
import QuartzCore

@main
struct CoreDeviceProbe {
    static func main() async {
        let shouldViewScreen = CommandLine.arguments.contains("--view-screen")
        let shouldQuerySupport = CommandLine.arguments.contains("--media-support-info")
        let shouldQueryStatus = CommandLine.arguments.contains("--media-server-status")
        let shouldMakeVideoStream = CommandLine.arguments.contains("--make-video-stream")
        if shouldMakeVideoStream {
            installWatchdog(operation: "CoreDevice initialization with CoreDeviceMediaStreamSupport")
        }
        let manager = DeviceManager.shared

        print("Waiting for CoreDevice initialization...")
        fflush(stdout)
        await manager.awaitFullInitialization()

        let devices = manager.allDevices()
        print("CoreDevice devices: \(devices.count)")

        for device in devices {
            print("- \(device.deviceIdentifier): \(device.description)")
        }

        guard shouldViewScreen || shouldQuerySupport || shouldQueryStatus || shouldMakeVideoStream else {
            return
        }

        guard let device = devices.first else {
            fputs("No CoreDevice device is available.\n", stderr)
            Foundation.exit(2)
        }

        if shouldQuerySupport {
            installWatchdog(operation: "mediaStreamSupportInfo")
            await queryMediaSupportInfo(device)
        }

        if shouldQueryStatus {
            installWatchdog(operation: "mediaStreamServerStatus")
            await queryMediaServerStatus(device)
        }

        if shouldMakeVideoStream {
            installWatchdog(operation: "makeVideoStream")
            await makeVideoStream(device)
        }

        if shouldViewScreen {
            do {
                let token = try await device.viewScreen()
                print("viewScreen succeeded: \(token.description)")
            } catch {
                fputs("viewScreen failed: \(error)\n", stderr)
                Foundation.exit(1)
            }
        }
    }

    private static func installWatchdog(operation: String) {
        Task {
            try? await Task.sleep(for: .seconds(20))
            fputs("\(operation) timed out after 20 seconds.\n", stderr)
            Foundation.exit(124)
        }
    }

    private static func queryMediaSupportInfo(_ device: RemoteDevice) async {
        print("Querying mediaStreamSupportInfo...")
        let supportResult = await withCheckedContinuation { continuation in
            device.getMediaStreamSupportInfo(completingOn: nil) {
                continuation.resume(returning: $0)
            }
        }

        switch supportResult {
        case let .success(info):
            print("mediaStreamSupportInfo succeeded: \(String(reflecting: info))")
            dump(info)
        case let .failure(error):
            fputs("mediaStreamSupportInfo failed: \(error)\n", stderr)
        }
    }

    private static func queryMediaServerStatus(_ device: RemoteDevice) async {
        print("Querying mediaStreamServerStatus...")
        let statusResult = await withCheckedContinuation { continuation in
            device.getMediaStreamServerStatus(completingOn: nil) {
                continuation.resume(returning: $0)
            }
        }

        switch statusResult {
        case let .success(status):
            print("mediaStreamServerStatus succeeded: \(String(reflecting: status))")
            dump(status)
        case let .failure(error):
            fputs("mediaStreamServerStatus failed: \(error)\n", stderr)
        }
    }

    private static func makeVideoStream(_ device: RemoteDevice) async {
        print("Creating mirrored-primary video stream...")
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
        } catch {
            fputs("makeVideoStream failed: \(error)\n", stderr)
            Foundation.exit(1)
        }
    }
}
