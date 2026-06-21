import Foundation
import MultipeerConnectivity

private enum RemoteCameraTransportEnvelopeKind: String, Codable {
    case hello
    case control
    case frame
    case status
}

private struct RemoteCameraTransportEnvelope: Codable {
    let kind: RemoteCameraTransportEnvelopeKind
    let payload: Data
}

private enum RemoteCameraTransportCodec {
    static func encode(_ message: RemoteCameraMessage) throws -> Data {
        let envelope: RemoteCameraTransportEnvelope
        switch message {
        case .hello(let device):
            envelope = RemoteCameraTransportEnvelope(kind: .hello, payload: try JSONEncoder().encode(device))
        case .control(let control):
            envelope = RemoteCameraTransportEnvelope(kind: .control, payload: try JSONEncoder().encode(control))
        case .frame(let metadata, let jpegData):
            envelope = RemoteCameraTransportEnvelope(
                kind: .frame,
                payload: try JSONEncoder().encode(RemoteCameraFramePacket(metadata: metadata, jpegData: jpegData))
            )
        case .status(let state, let description):
            envelope = RemoteCameraTransportEnvelope(
                kind: .status,
                payload: try JSONEncoder().encode(RemoteCameraStatusPacket(state: state, description: description))
            )
        }
        return try JSONEncoder().encode(envelope)
    }

    static func decode(_ data: Data) throws -> RemoteCameraMessage {
        let envelope = try JSONDecoder().decode(RemoteCameraTransportEnvelope.self, from: data)
        switch envelope.kind {
        case .hello:
            return .hello(device: try JSONDecoder().decode(RemoteCameraDeviceInfo.self, from: envelope.payload))
        case .control:
            return .control(try JSONDecoder().decode(RemoteCameraControlMessage.self, from: envelope.payload))
        case .frame:
            let packet = try JSONDecoder().decode(RemoteCameraFramePacket.self, from: envelope.payload)
            return .frame(metadata: packet.metadata, jpegData: packet.jpegData)
        case .status:
            let packet = try JSONDecoder().decode(RemoteCameraStatusPacket.self, from: envelope.payload)
            return .status(state: packet.state, description: packet.description)
        }
    }
}

private struct RemoteCameraFramePacket: Codable {
    let metadata: RemoteCameraFrameMetadata
    let jpegData: Data
}

private struct RemoteCameraStatusPacket: Codable {
    let state: RemoteCameraConnectionState
    let description: String
}

protocol RemoteCameraTransportDelegate: AnyObject {
    func remoteCameraTransport(_ transport: RemoteCameraTransport, didChangeSnapshot snapshot: RemoteCameraSessionSnapshot)
    func remoteCameraTransport(_ transport: RemoteCameraTransport, didReceiveFrame metadata: RemoteCameraFrameMetadata, jpegData: Data)
    func remoteCameraTransport(_ transport: RemoteCameraTransport, didReceiveControl control: RemoteCameraControlMessage)
}

final class RemoteCameraTransport: NSObject {
    static let serviceType = "breakgatecam"

    enum Role {
        case macHost
        case phoneCompanion
    }

    weak var delegate: RemoteCameraTransportDelegate?

    private let role: Role
    private let peerID: MCPeerID
    private let serviceAdvertiser: MCNearbyServiceAdvertiser?
    private let serviceBrowser: MCNearbyServiceBrowser?
    private let session: MCSession
    private let queue = DispatchQueue(label: "BreakGateWorkout.remoteCamera.transport", qos: .userInitiated)

    private(set) var snapshot = RemoteCameraSessionSnapshot()
    private var nearbyPeer: MCPeerID?
    private var connectedPeer: MCPeerID?
    private var knownPeerIDs: [String: MCPeerID] = [:]

    init(role: Role, displayName: String) {
        self.role = role
        self.peerID = MCPeerID(displayName: displayName)
        self.session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)

        switch role {
        case .macHost:
            self.serviceAdvertiser = nil
            self.serviceBrowser = MCNearbyServiceBrowser(peer: peerID, serviceType: Self.serviceType)
        case .phoneCompanion:
            self.serviceAdvertiser = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: Self.serviceType)
            self.serviceBrowser = nil
        }

        super.init()
        session.delegate = self
        serviceAdvertiser?.delegate = self
        serviceBrowser?.delegate = self
    }

    func start() {
        queue.async {
            switch self.role {
            case .macHost:
                self.snapshot.connectionState = .browsing
                self.snapshot.statusText = "Browsing for iPhone"
                self.log("setup opened")
                self.log("browsing started")
                self.serviceBrowser?.startBrowsingForPeers()
            case .phoneCompanion:
                self.snapshot.connectionState = .disconnected
                self.snapshot.statusText = "Advertising to Mac"
                self.log("advertising started")
                self.serviceAdvertiser?.startAdvertisingPeer()
            }
            self.publishSnapshot()
        }
    }

    func stop() {
        queue.async {
            self.serviceBrowser?.stopBrowsingForPeers()
            self.serviceAdvertiser?.stopAdvertisingPeer()
            self.session.disconnect()
            self.nearbyPeer = nil
            self.connectedPeer = nil
            self.snapshot.connectionState = .disconnected
            self.snapshot.isStreaming = false
            self.snapshot.statusText = "Disconnected"
            self.log("stream stopped")
            self.publishSnapshot()
        }
    }

    func reconnect() {
        stop()
        start()
    }

    func inviteNearbyPeer() {
        queue.async {
            guard let browser = self.serviceBrowser, let nearbyPeer = self.nearbyPeer else { return }
            self.snapshot.connectionState = .connecting
            self.snapshot.statusText = "Connecting..."
            self.log("connection state=connecting peer=\(nearbyPeer.displayName)")
            self.publishSnapshot()
            browser.invitePeer(nearbyPeer, to: self.session, withContext: nil, timeout: 10)
        }
    }

    func invitePeer(named deviceName: String) {
        queue.async {
            guard let browser = self.serviceBrowser else { return }
            let peer = self.knownPeerIDs[deviceName] ?? self.nearbyPeer
            guard let peer else { return }
            self.snapshot.connectionState = .connecting
            self.snapshot.statusText = "Connecting..."
            self.log("connection state=connecting peer=\(peer.displayName)")
            self.publishSnapshot()
            browser.invitePeer(peer, to: self.session, withContext: nil, timeout: 10)
        }
    }

    func send(_ message: RemoteCameraMessage) {
        queue.async {
            guard !self.session.connectedPeers.isEmpty else { return }
            do {
                let data = try RemoteCameraTransportCodec.encode(message)
                try self.session.send(data, toPeers: self.session.connectedPeers, with: .unreliable)
            } catch {
                self.snapshot.connectionState = .failed
                self.snapshot.statusText = error.localizedDescription
                self.log("error=\(error.localizedDescription)")
                self.publishSnapshot()
            }
        }
    }

    private func handle(peerState: MCSessionState, peerID: MCPeerID) {
        switch peerState {
        case .notConnected:
            connectedPeer = nil
            snapshot.connectionState = nearbyPeer == nil ? .browsing : .disconnected
            snapshot.connectedDeviceID = nil
            snapshot.connectedDeviceName = nil
            snapshot.isStreaming = false
            snapshot.statusText = "Disconnected"
            log("connection state=notConnected peer=\(peerID.displayName)")
        case .connecting:
            snapshot.connectionState = .connecting
            snapshot.connectedDeviceID = peerID.displayName
            snapshot.connectedDeviceName = peerID.displayName
            snapshot.statusText = "Connecting..."
            log("connection state=connecting peer=\(peerID.displayName)")
        case .connected:
            connectedPeer = peerID
            snapshot.connectionState = .connected
            snapshot.connectedDeviceID = peerID.displayName
            snapshot.connectedDeviceName = peerID.displayName
            snapshot.statusText = "Connected"
            log("connection state=connected peer=\(peerID.displayName)")
        @unknown default:
            snapshot.connectionState = .failed
            snapshot.statusText = "Unknown Multipeer state"
            log("error=unknown Multipeer state peer=\(peerID.displayName)")
        }
        publishSnapshot()
    }

    private func receive(_ data: Data) {
        do {
            let message = try RemoteCameraTransportCodec.decode(data)
            switch message {
            case .hello(let device):
                snapshot.discoveredDeviceID = device.id
                snapshot.discoveredDeviceName = device.name
                snapshot.connectedDeviceID = device.id
                snapshot.connectedDeviceName = device.name
                snapshot.pairingToken = device.pairingToken
                snapshot.availableZoomLevels = device.supportsZoomLevels
                log("paired phone=\(device.name)")
                publishSnapshot()
            case .control(let control):
                delegate?.remoteCameraTransport(self, didReceiveControl: control)
            case .frame(let metadata, let jpegData):
                snapshot.latestMetadata = metadata
                snapshot.latestFrameData = jpegData
                snapshot.latestFrameSize = CGSize(width: metadata.captureWidth, height: metadata.captureHeight)
                snapshot.connectedDeviceID = connectedPeer?.displayName ?? snapshot.connectedDeviceID
                snapshot.connectedDeviceName = metadata.deviceName
                snapshot.isStreaming = true
                snapshot.connectionState = .streaming
                snapshot.statusText = "Streaming"
                publishSnapshot()
                delegate?.remoteCameraTransport(self, didReceiveFrame: metadata, jpegData: jpegData)
            case .status(let state, let description):
                snapshot.connectionState = state
                snapshot.statusText = description
                if state == .streaming {
                    log("stream started")
                } else if state == .connected {
                    log("stream stopped")
                }
                publishSnapshot()
            }
        } catch {
            snapshot.connectionState = .failed
            snapshot.statusText = error.localizedDescription
            log("error=\(error.localizedDescription)")
            publishSnapshot()
        }
    }

    private func log(_ message: String) {
        switch role {
        case .macHost:
            print("BreakGateWorkout remote: \(message)")
        case .phoneCompanion:
            print("BreakGateWorkoutPhone: \(message)")
        }
    }

    private func publishSnapshot() {
        let snapshot = self.snapshot
        DispatchQueue.main.async {
            self.delegate?.remoteCameraTransport(self, didChangeSnapshot: snapshot)
        }
    }
}

extension RemoteCameraTransport: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        queue.async {
            self.nearbyPeer = peerID
            self.knownPeerIDs[peerID.displayName] = peerID
            self.snapshot.discoveredDeviceID = peerID.displayName
            self.snapshot.discoveredDeviceName = peerID.displayName
            self.snapshot.statusText = "iPhone found"
            self.log("peer found name=\(peerID.displayName)")
            self.publishSnapshot()
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        queue.async {
            if self.nearbyPeer == peerID {
                self.nearbyPeer = nil
                self.snapshot.discoveredDeviceID = nil
                self.snapshot.discoveredDeviceName = nil
            }
            if self.connectedPeer == peerID {
                self.connectedPeer = nil
                self.snapshot.connectedDeviceID = nil
                self.snapshot.connectedDeviceName = nil
                self.snapshot.connectionState = .disconnected
            }
            self.knownPeerIDs.removeValue(forKey: peerID.displayName)
            self.snapshot.statusText = "iPhone not found"
            self.log("connection state=lost peer=\(peerID.displayName)")
            self.publishSnapshot()
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        queue.async {
            self.snapshot.connectionState = .failed
            self.snapshot.statusText = error.localizedDescription
            self.log("error=\(error.localizedDescription)")
            self.publishSnapshot()
        }
    }
}

extension RemoteCameraTransport: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        queue.async {
            self.connectedPeer = peerID
            self.snapshot.connectionState = .connecting
            self.snapshot.connectedDeviceName = peerID.displayName
            self.snapshot.statusText = "Connecting..."
            self.log("connection state=connecting peer=\(peerID.displayName)")
            self.publishSnapshot()
            invitationHandler(true, self.session)
        }
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        queue.async {
            self.snapshot.connectionState = .failed
            self.snapshot.statusText = error.localizedDescription
            self.log("error=\(error.localizedDescription)")
            self.publishSnapshot()
        }
    }
}

extension RemoteCameraTransport: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        queue.async {
            self.handle(peerState: state, peerID: peerID)
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        queue.async {
            self.receive(data)
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    #if os(iOS)
    func session(_ session: MCSession, didReceive certificate: [Any]?, fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }
    #endif
}
