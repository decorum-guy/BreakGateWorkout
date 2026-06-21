import AVFoundation
import Combine
import CoreImage
import Foundation
import SwiftUI
import UIKit

final class PhoneCameraStreamModel: NSObject, ObservableObject {
    @Published private(set) var connectionState: RemoteCameraConnectionState = .disconnected
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var connectedMacLabel = "—"
    @Published private(set) var currentZoomLevel: RemoteCameraZoomLevel = .wide1x
    @Published private(set) var supportedZoomLevels: [RemoteCameraZoomLevel] = [.wide1x]
    @Published private(set) var cameraStatusText = "Camera not started"
    @Published private(set) var streamStatsText: String?

    let isRussian = Locale.current.language.languageCode?.identifier == "ru"

    var previewAspectRatio: CGFloat {
        guard let previewImage else { return 16.0 / 9.0 }
        return max(1, previewImage.size.width / max(1, previewImage.size.height))
    }

    var currentZoomLabel: String { currentZoomLevel.title }

    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "BreakGateWorkout.phone.capture", qos: .userInitiated)
    private lazy var transport = RemoteCameraTransport(
        role: .phoneCompanion,
        displayName: UIDevice.current.name
    )
    private var activeDevice: AVCaptureDevice?
    private var sessionID = UUID().uuidString
    private var frameIndex = 0
    private var isStreaming = false
    private var lastSentFrameDate = Date.distantPast
    private let targetFrameInterval: TimeInterval = 1.0 / 15.0
    private var lastKnownMacName: String? {
        didSet { UserDefaults.standard.set(lastKnownMacName, forKey: "BreakGateWorkoutPhone.pairedMacName") }
    }
    private var pairedMacID: String? {
        didSet { UserDefaults.standard.set(pairedMacID, forKey: "BreakGateWorkoutPhone.pairedMacID") }
    }
    private var pairingToken: String? {
        didSet { UserDefaults.standard.set(pairingToken, forKey: "BreakGateWorkoutPhone.pairingToken") }
    }
    private var lastKnownHost: String? {
        didSet { UserDefaults.standard.set(lastKnownHost, forKey: "BreakGateWorkoutPhone.lastKnownHost") }
    }
    private var lastConnectedAt: Date? {
        didSet { UserDefaults.standard.set(lastConnectedAt, forKey: "BreakGateWorkoutPhone.lastConnectedAt") }
    }

    override init() {
        super.init()
        transport.delegate = self
        pairedMacID = UserDefaults.standard.string(forKey: "BreakGateWorkoutPhone.pairedMacID")
        lastKnownMacName = UserDefaults.standard.string(forKey: "BreakGateWorkoutPhone.pairedMacName")
        pairingToken = UserDefaults.standard.string(forKey: "BreakGateWorkoutPhone.pairingToken")
        lastKnownHost = UserDefaults.standard.string(forKey: "BreakGateWorkoutPhone.lastKnownHost")
    }

    func start() {
        transport.start()
        configureCameraIfNeeded()
    }

    func reconnect() {
        transport.reconnect()
    }

    func startStreaming() {
        isStreaming = true
        sessionID = UUID().uuidString
        frameIndex = 0
        connectionState = .streaming
        transport.send(.status(state: .streaming, description: "Streaming"))
    }

    func stopStreaming() {
        isStreaming = false
        transport.send(.status(state: .connected, description: "Connected"))
    }

    func setZoom(_ level: RemoteCameraZoomLevel) {
        currentZoomLevel = level
        applyZoom(level)
    }

    private func configureCameraIfNeeded() {
        guard activeDevice == nil else { return }
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720

        let device = bestDevice(for: .wide1x)
        activeDevice = device
        supportedZoomLevels = availableZoomLevels()

        guard let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            cameraStatusText = "Camera unavailable"
            session.commitConfiguration()
            return
        }

        session.addInput(input)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            cameraStatusText = "Video output unavailable"
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        session.commitConfiguration()
        captureQueue.async {
            self.session.startRunning()
        }
        cameraStatusText = isRussian ? "Камера готова" : "Camera ready"
    }

    private func availableZoomLevels() -> [RemoteCameraZoomLevel] {
        var levels: [RemoteCameraZoomLevel] = [.wide1x]
        if AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) != nil {
            levels.insert(.ultraWide05, at: 0)
        }
        if AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back) != nil {
            levels.append(.tele2x)
            levels.append(.tele3x)
        } else if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back), device.activeFormat.videoMaxZoomFactor >= 3 {
            levels.append(.tele2x)
            levels.append(.tele3x)
        } else if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back), device.activeFormat.videoMaxZoomFactor >= 2 {
            levels.append(.tele2x)
        }
        return levels
    }

    private func bestDevice(for level: RemoteCameraZoomLevel) -> AVCaptureDevice? {
        switch level {
        case .ultraWide05:
            return AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .wide1x:
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        case .tele2x, .tele3x:
            return AVCaptureDevice.default(.builtInTelephotoCamera, for: .video, position: .back)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
        }
    }

    private func applyZoom(_ level: RemoteCameraZoomLevel) {
        guard let device = bestDevice(for: level) else { return }
        if activeDevice?.uniqueID != device.uniqueID {
            switchToDevice(device, preferredLevel: level)
            return
        }
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = min(max(CGFloat(level.zoomFactor), 1), device.activeFormat.videoMaxZoomFactor)
            device.unlockForConfiguration()
        } catch {}
    }

    private func switchToDevice(_ device: AVCaptureDevice, preferredLevel: RemoteCameraZoomLevel) {
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            activeDevice = device
        }
        session.commitConfiguration()
        applyZoom(preferredLevel)
    }

    private func sendFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isStreaming else { return }
        let now = Date()
        guard now.timeIntervalSince(lastSentFrameDate) >= targetFrameInterval else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSentFrameDate = now

        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)
        previewImage = image
        guard let jpegData = image.jpegData(compressionQuality: 0.55) else { return }

        let metadata = RemoteCameraFrameMetadata(
            sessionID: sessionID,
            frameIndex: frameIndex,
            timestampSeconds: now.timeIntervalSince1970,
            captureWidth: cgImage.width,
            captureHeight: cgImage.height,
            orientation: "portrait",
            isMirrored: false,
            zoomLabel: currentZoomLevel.title,
            zoomFactor: currentZoomLevel.zoomFactor,
            lensType: lensType(for: currentZoomLevel),
            deviceName: UIDevice.current.name,
            fpsApprox: 15,
            latencyMsApprox: nil
        )
        frameIndex += 1
        streamStatsText = "\(Int(metadata.fpsApprox ?? 0)) fps • \(metadata.captureWidth)x\(metadata.captureHeight)"
        transport.send(.frame(metadata: metadata, jpegData: jpegData))
    }

    private func lensType(for level: RemoteCameraZoomLevel) -> String {
        switch level {
        case .ultraWide05: return "ultraWide"
        case .wide1x: return "wide"
        case .tele2x, .tele3x: return "telephoto"
        }
    }

    private func sendHello() {
        transport.send(
            .hello(
                device: RemoteCameraDeviceInfo(
                    id: UIDevice.current.identifierForVendor?.uuidString ?? UIDevice.current.name,
                    name: UIDevice.current.name,
                    deviceName: UIDevice.current.model,
                    supportsZoomLevels: supportedZoomLevels
                )
            )
        )
    }
}

extension PhoneCameraStreamModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        sendFrame(sampleBuffer)
    }
}

extension PhoneCameraStreamModel: RemoteCameraTransportDelegate {
    func remoteCameraTransport(_ transport: RemoteCameraTransport, didChangeSnapshot snapshot: RemoteCameraSessionSnapshot) {
        connectionState = snapshot.connectionState
        connectedMacLabel = snapshot.connectedDeviceName ?? snapshot.discoveredDeviceName ?? lastKnownMacName ?? "—"
        if let name = snapshot.connectedDeviceName ?? snapshot.discoveredDeviceName {
            lastKnownMacName = name
            lastKnownHost = name
        }
        if snapshot.connectionState == .connected || snapshot.connectionState == .streaming {
            lastConnectedAt = Date()
            pairedMacID = snapshot.connectedDeviceName ?? snapshot.discoveredDeviceName
            if pairingToken == nil {
                pairingToken = UUID().uuidString
            }
            sendHello()
        }
    }

    func remoteCameraTransport(_ transport: RemoteCameraTransport, didReceiveFrame metadata: RemoteCameraFrameMetadata, jpegData: Data) {}

    func remoteCameraTransport(_ transport: RemoteCameraTransport, didReceiveControl control: RemoteCameraControlMessage) {
        DispatchQueue.main.async {
            switch control {
            case .startStream(let sessionID):
                self.sessionID = sessionID
                self.startStreaming()
            case .stopStream, .disconnect:
                self.stopStreaming()
            case .setZoom(let level):
                self.setZoom(level)
            case .ping(let timestampSeconds):
                self.transport.send(.control(.pong(timestampSeconds: timestampSeconds)))
            case .pong:
                break
            }
        }
    }
}
