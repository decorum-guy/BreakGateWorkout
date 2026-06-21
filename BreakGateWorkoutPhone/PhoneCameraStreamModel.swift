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
    @Published private(set) var selectedQuality: RemoteCameraStreamQuality = .fhd1080p
    @Published private(set) var actionInProgressTitle: String?
    @Published var autoStartAfterConnection = true

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
    private var currentDeviceOrientation: UIDeviceOrientation = .portrait
    private var lastFrameLogDate = Date.distantPast
    private let targetFrameInterval: TimeInterval = 1.0 / 15.0
    private let ciContext = CIContext(options: nil)
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
    private var isConnectModeRequested = false

    override init() {
        super.init()
        transport.delegate = self
        pairedMacID = UserDefaults.standard.string(forKey: "BreakGateWorkoutPhone.pairedMacID")
        lastKnownMacName = UserDefaults.standard.string(forKey: "BreakGateWorkoutPhone.pairedMacName")
        pairingToken = UserDefaults.standard.string(forKey: "BreakGateWorkoutPhone.pairingToken")
        lastKnownHost = UserDefaults.standard.string(forKey: "BreakGateWorkoutPhone.lastKnownHost")
        if UserDefaults.standard.object(forKey: "BreakGateWorkoutPhone.autoStartAfterConnection") == nil {
            autoStartAfterConnection = true
        } else {
            autoStartAfterConnection = UserDefaults.standard.bool(forKey: "BreakGateWorkoutPhone.autoStartAfterConnection")
        }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationChanged),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    func start() {
        print("BreakGateWorkoutPhone: advertising started")
        transport.start()
        configureCameraIfNeeded()
        isConnectModeRequested = true
    }

    func handleOpenURL(_ url: URL) {
        guard url.scheme?.lowercased() == "breakgatephone" else { return }
        isConnectModeRequested = true
        transport.reconnect()
    }

    func reconnect() {
        isConnectModeRequested = true
        actionInProgressTitle = isRussian ? "Подключение..." : "Connecting..."
        connectionState = .connecting
        transport.reconnect()
    }

    func startStreaming() {
        actionInProgressTitle = isRussian ? "Запуск..." : "Starting..."
        isStreaming = true
        sessionID = UUID().uuidString
        frameIndex = 0
        connectionState = .streaming
        transport.send(.status(state: .streaming, description: "Streaming"))
        let resolution = selectedQuality.dimensions
        print("BreakGateWorkoutPhone: stream started resolution=\(resolution.width)x\(resolution.height) fpsTarget=15")
        clearActionProgressSoon()
    }

    func stopStreaming() {
        actionInProgressTitle = isRussian ? "Остановка..." : "Stopping..."
        isStreaming = false
        connectionState = .connected
        transport.send(.status(state: .connected, description: "Connected"))
        print("BreakGateWorkoutPhone: stream stopped")
        clearActionProgressSoon()
    }

    func setZoom(_ level: RemoteCameraZoomLevel) {
        currentZoomLevel = level
        applyZoom(level)
    }

    private func configureCameraIfNeeded() {
        guard activeDevice == nil else { return }
        session.beginConfiguration()
        if session.canSetSessionPreset(.hd1920x1080) {
            session.sessionPreset = .hd1920x1080
            selectedQuality = .fhd1080p
        } else if session.canSetSessionPreset(.hd1280x720) {
            session.sessionPreset = .hd1280x720
            selectedQuality = .hd720p
            print("BreakGateWorkoutPhone: error=FHD 1080p unsupported, falling back to HD 720p")
        } else {
            session.sessionPreset = .high
            selectedQuality = .hd720p
            print("BreakGateWorkoutPhone: error=FHD/HD presets unsupported, falling back to high preset")
        }

        let device = bestDevice(for: .wide1x)
        activeDevice = device
        supportedZoomLevels = availableZoomLevels()

        guard let device, let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            cameraStatusText = "Camera unavailable"
            print("BreakGateWorkoutPhone: error=camera unavailable")
            session.commitConfiguration()
            return
        }

        session.addInput(input)
        configureFrameRate(for: device)
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            cameraStatusText = "Video output unavailable"
            print("BreakGateWorkoutPhone: error=video output unavailable")
            session.commitConfiguration()
            return
        }
        session.addOutput(output)
        session.commitConfiguration()
        captureQueue.async {
            self.session.startRunning()
        }
        cameraStatusText = isRussian ? "Камера готова" : "Camera ready"
        let resolution = selectedQuality.dimensions
        print("BreakGateWorkoutPhone: camera configured preset=\(selectedQuality.title) resolution=\(resolution.width)x\(resolution.height) fps=15")
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
            configureFrameRate(for: device)
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
        guard let rawCGImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let remoteOrientation = normalizedOrientationName(for: currentDeviceOrientation)
        let image = uprightImage(from: rawCGImage, deviceOrientation: currentDeviceOrientation)
        guard let bakedCGImage = image.cgImage else { return }
        DispatchQueue.main.async {
            self.previewImage = image
        }
        guard let jpegData = image.jpegData(compressionQuality: 0.55) else { return }

        let metadata = RemoteCameraFrameMetadata(
            sessionID: sessionID,
            frameIndex: frameIndex,
            timestampSeconds: now.timeIntervalSince1970,
            captureWidth: bakedCGImage.width,
            captureHeight: bakedCGImage.height,
            orientation: "up",
            remoteOrientation: remoteOrientation,
            displayWidth: bakedCGImage.width,
            displayHeight: bakedCGImage.height,
            isMirrored: false,
            zoomLabel: currentZoomLevel.title,
            zoomFactor: currentZoomLevel.zoomFactor,
            lensType: lensType(for: currentZoomLevel),
            deviceName: UIDevice.current.name,
            fpsApprox: 15,
            latencyMsApprox: nil
        )
        frameIndex += 1
        DispatchQueue.main.async {
            self.streamStatsText = "\(Int(metadata.fpsApprox ?? 0)) fps • \(metadata.captureWidth)x\(metadata.captureHeight) • \(metadata.remoteOrientation)"
        }
        if now.timeIntervalSince(lastFrameLogDate) >= 1 || metadata.frameIndex % 30 == 0 {
            lastFrameLogDate = now
            print("BreakGateWorkoutPhone: frame sent index=\(metadata.frameIndex) orientation=\(metadata.remoteOrientation) zoom=\(metadata.zoomLabel)")
        }
        transport.send(.frame(metadata: metadata, jpegData: jpegData))
    }

    private func configureFrameRate(for device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let frameDuration = CMTime(value: 1, timescale: 15)
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            device.unlockForConfiguration()
        } catch {
            print("BreakGateWorkoutPhone: error=failed to set 15 fps \(error.localizedDescription)")
        }
    }

    private func uprightImage(from cgImage: CGImage, deviceOrientation: UIDeviceOrientation) -> UIImage {
        let source = UIImage(cgImage: cgImage, scale: 1, orientation: imageOrientation(for: deviceOrientation))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: source.size, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: source.size))
        }
    }

    private func imageOrientation(for deviceOrientation: UIDeviceOrientation) -> UIImage.Orientation {
        switch deviceOrientation {
        case .portrait:
            return .right
        case .portraitUpsideDown:
            return .left
        case .landscapeLeft:
            return .up
        case .landscapeRight:
            return .down
        default:
            return imageOrientation(for: currentDeviceOrientation)
        }
    }

    private func normalizedOrientationName(for deviceOrientation: UIDeviceOrientation) -> String {
        switch deviceOrientation {
        case .portrait:
            return "portrait"
        case .portraitUpsideDown:
            return "portraitUpsideDown"
        case .landscapeLeft:
            return "landscapeLeft"
        case .landscapeRight:
            return "landscapeRight"
        default:
            return "portrait"
        }
    }

    @objc private func deviceOrientationChanged() {
        let next = UIDevice.current.orientation
        guard next == .portrait || next == .portraitUpsideDown || next == .landscapeLeft || next == .landscapeRight else { return }
        currentDeviceOrientation = next
        print("BreakGateWorkoutPhone: orientation changed=\(normalizedOrientationName(for: next))")
    }

    private func clearActionProgressSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.actionInProgressTitle = nil
        }
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
                    supportsZoomLevels: supportedZoomLevels,
                    pairingToken: pairingToken,
                    pairedCompanionID: pairedMacID
                )
            )
        )
    }

    func setAutoStartAfterConnection(_ isEnabled: Bool) {
        autoStartAfterConnection = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "BreakGateWorkoutPhone.autoStartAfterConnection")
    }

    var primaryActionTitle: String {
        if let actionInProgressTitle {
            return actionInProgressTitle
        }
        switch connectionState {
        case .disconnected, .browsing:
            return isRussian ? "Подключиться к Mac" : "Connect to Mac"
        case .connecting:
            return isRussian ? "Подключение..." : "Connecting..."
        case .connected:
            return isRussian ? "Начать трансляцию" : "Start Stream"
        case .streaming:
            return isRussian ? "Остановить трансляцию" : "Stop Stream"
        case .failed:
            return isRussian ? "Переподключить" : "Reconnect"
        }
    }

    var primaryActionEnabled: Bool {
        actionInProgressTitle == nil && connectionState != .connecting
    }

    func performPrimaryAction() {
        switch connectionState {
        case .disconnected, .browsing, .failed:
            reconnect()
        case .connecting:
            break
        case .connected:
            startStreaming()
        case .streaming:
            stopStreaming()
        }
    }
}

extension PhoneCameraStreamModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        sendFrame(sampleBuffer)
    }
}

extension PhoneCameraStreamModel: RemoteCameraTransportDelegate {
    func remoteCameraTransport(_ transport: RemoteCameraTransport, didChangeSnapshot snapshot: RemoteCameraSessionSnapshot) {
        actionInProgressTitle = nil
        connectionState = snapshot.connectionState
        connectedMacLabel = snapshot.connectedDeviceName ?? snapshot.discoveredDeviceName ?? lastKnownMacName ?? "—"
        if let name = snapshot.connectedDeviceName ?? snapshot.discoveredDeviceName {
            lastKnownMacName = name
            lastKnownHost = name
        }
        if snapshot.connectionState == .connected || snapshot.connectionState == .streaming {
            if snapshot.connectionState == .connected {
                print("BreakGateWorkoutPhone: peer connected=\(snapshot.connectedDeviceName ?? connectedMacLabel)")
            }
            lastConnectedAt = Date()
            pairedMacID = snapshot.connectedDeviceID ?? snapshot.connectedDeviceName ?? snapshot.discoveredDeviceName
            pairingToken = snapshot.pairingToken ?? pairingToken ?? UUID().uuidString
            sendHello()
            if snapshot.connectionState == .connected, autoStartAfterConnection, isConnectModeRequested {
                startStreaming()
            }
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
