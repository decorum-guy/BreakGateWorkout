import Foundation

enum RemoteCameraMode: String, Codable, CaseIterable {
    case localContinuity
    case iPhoneStreamBeta
}

enum RemoteCameraConnectionState: String, Codable {
    case disconnected
    case browsing
    case connecting
    case connected
    case streaming
    case failed
}

enum RemoteCameraZoomLevel: String, Codable, CaseIterable, Identifiable {
    case ultraWide05
    case wide1x
    case tele2x
    case tele3x

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ultraWide05: return "0.5x"
        case .wide1x: return "1x"
        case .tele2x: return "2x"
        case .tele3x: return "3x"
        }
    }

    var zoomFactor: Double {
        switch self {
        case .ultraWide05: return 0.5
        case .wide1x: return 1
        case .tele2x: return 2
        case .tele3x: return 3
        }
    }
}

enum RemoteCameraStreamQuality: String, Codable, CaseIterable, Identifiable {
    case fhd1080p
    case hd720p

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fhd1080p: return "FHD 1080p"
        case .hd720p: return "HD 720p"
        }
    }

    var dimensions: (width: Int, height: Int) {
        switch self {
        case .fhd1080p: return (1920, 1080)
        case .hd720p: return (1280, 720)
        }
    }
}

struct RemoteCameraDeviceInfo: Codable, Equatable, Identifiable {
    let id: String
    let name: String
    let deviceName: String
    let supportsZoomLevels: [RemoteCameraZoomLevel]
    let pairingToken: String?
    let pairedCompanionID: String?
}

struct RemoteCameraFrameMetadata: Codable, Equatable {
    let sessionID: String
    let frameIndex: Int
    let timestampSeconds: TimeInterval
    let captureWidth: Int
    let captureHeight: Int
    let orientation: String
    let remoteOrientation: String
    let displayWidth: Int
    let displayHeight: Int
    let isMirrored: Bool
    let zoomLabel: String
    let zoomFactor: Double
    let lensType: String
    let deviceName: String
    let fpsApprox: Double?
    let latencyMsApprox: Double?
}

enum RemoteCameraControlMessage: Codable, Equatable {
    case startStream(sessionID: String)
    case stopStream
    case setZoom(level: RemoteCameraZoomLevel)
    case ping(timestampSeconds: TimeInterval)
    case pong(timestampSeconds: TimeInterval)
    case disconnect
}

enum RemoteCameraMessage: Codable, Equatable {
    case hello(device: RemoteCameraDeviceInfo)
    case control(RemoteCameraControlMessage)
    case frame(metadata: RemoteCameraFrameMetadata, jpegData: Data)
    case status(state: RemoteCameraConnectionState, description: String)
}

struct RemoteCameraSessionSnapshot: Equatable {
    var connectionState: RemoteCameraConnectionState = .disconnected
    var selectedMode: RemoteCameraMode = .localContinuity
    var discoveredDeviceID: String?
    var discoveredDeviceName: String?
    var connectedDeviceID: String?
    var connectedDeviceName: String?
    var pairingToken: String?
    var latestMetadata: RemoteCameraFrameMetadata?
    var latestFrameData: Data?
    var latestFrameSize = CGSize(width: 16, height: 9)
    var statusText = ""
    var isStreaming = false
    var availableZoomLevels: [RemoteCameraZoomLevel] = []
    var remoteConnectionType = "multipeerConnectivity"
}
