//
//  ContentView.swift
//  BreakGateWorkout
//

@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreGraphics
import SwiftUI
import Vision

struct ContentView: View {
    @StateObject private var camera = CameraModel()
    @ObservedObject private var monitor: BreakGateMonitor
    @ObservedObject private var stats: WorkoutStats

    init(monitor: BreakGateMonitor, stats: WorkoutStats) {
        self.monitor = monitor
        self.stats = stats
    }

    var body: some View {
        ZStack {
            AppBackground()

            VStack(alignment: .leading, spacing: 24) {
                HeaderView()

                HStack(alignment: .top, spacing: 22) {
                    CameraStageView(camera: camera, monitor: monitor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    CameraControlPanel(camera: camera)
                        .frame(width: 320)
                }
            }
            .padding(28)
        }
        .frame(minWidth: 980, minHeight: 680)
        .preferredColorScheme(.dark)
        .task {
            camera.onWorkoutCompleted = { mode, amount in
                monitor.recordWorkoutCompletion()
                stats.recordWorkoutCompletion(mode: mode, amount: amount)
            }
            await camera.start()
        }
        .onDisappear {
            camera.stop()
        }
    }
}

private struct AppBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.05, green: 0.06, blue: 0.08),
                Color(red: 0.08, green: 0.10, blue: 0.13),
                Color(red: 0.03, green: 0.04, blue: 0.06)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

private struct HeaderView: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("BreakGateWorkout")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("Camera setup")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

enum ExerciseMode: String, CaseIterable, Identifiable {
    case pushUps
    case squats
    case abs
    case plank

    var id: Self { self }

    var title: String {
        switch self {
        case .pushUps: "Push-ups"
        case .squats: "Squats"
        case .abs: "Abs"
        case .plank: "Plank"
        }
    }
}

enum WorkoutState: String {
    case idle
    case tracking
    case noPerson
    case activeExercise
    case plankActive
    case plankBroken
}

private struct CameraStageView: View {
    @ObservedObject var camera: CameraModel
    @ObservedObject var monitor: BreakGateMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack(alignment: .topLeading) {
                CameraPreview(session: camera.session)
                    .background(Color.black)
                    .overlay {
                        if camera.session == nil {
                            PreviewPlaceholder(camera: camera)
                        }
                    }
                    .overlay {
                        if camera.showSkeletonOverlay {
                            SkeletonOverlayView(points: camera.posePoints, videoSize: camera.previewVideoSize)
                        }
                    }
                    .overlay {
                        if camera.selectedMode == .plank {
                            PlankCountdownOverlay(camera: camera)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        CoachingOverlay(camera: camera)
                            .padding(16)
                    }
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Live Camera", systemImage: "video.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())

                            if monitor.gateActive {
                                Label("BreakGate activated", systemImage: "lock.open.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }

                            if camera.showDebugPanel {
                                PoseDebugOverlay(camera: camera)
                            }
                        }
                        .padding(16)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(camera.session == nil ? Color.white.opacity(0.10) : Color.green.opacity(0.35), lineWidth: 1)
                    }
                    .shadow(color: camera.session == nil ? .clear : .green.opacity(0.16), radius: 28, y: 10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .aspectRatio(camera.previewAspectRatio, contentMode: .fit)
            .frame(minHeight: 500)
            .animation(.easeInOut(duration: 0.22), value: camera.session != nil)

            HStack(spacing: 8) {
                Image(systemName: camera.selectedDeviceIsIPhone ? "iphone" : "web.camera.fill")
                    .foregroundStyle(.secondary)
                Text(camera.selectedCameraName)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)
        }
    }
}

private struct CoachingOverlay: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack(spacing: 10) {
            if let celebrationMessage = camera.celebrationMessage {
                Label(celebrationMessage, systemImage: "sparkles")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color.green.opacity(0.78), in: Capsule())
                    .transition(.scale.combined(with: .opacity))
            }

            if let coachingMessage = camera.coachingMessage {
                Label(coachingMessage, systemImage: "figure.walk.motion")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.94))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: camera.celebrationMessage)
        .animation(.easeInOut(duration: 0.18), value: camera.coachingMessage)
        .allowsHitTesting(false)
    }
}

private struct PoseDebugOverlay: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Skeleton Overlay", isOn: Binding(
                get: { camera.showSkeletonOverlay },
                set: { camera.setSkeletonOverlayVisible($0) }
            ))
            .toggleStyle(.switch)
            .font(.caption.weight(.medium))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(camera.repCount)")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("Reps")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text("Mode: \(camera.selectedMode.title)")
            Text("State: \(camera.currentPoseState)")
                .lineLimit(1)
            Text("Person: \(camera.isPersonDetected ? "YES" : "NO")")
            Text("Confidence: \(camera.confidence, specifier: "%.2f")")
            if camera.selectedMode == .plank {
                Text("Plank: \(camera.formattedPlankTime)")
            }
            if !camera.isPersonDetected {
                Text("No pose detected")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(.white.opacity(0.92))
        .padding(12)
        .frame(width: 190, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct PlankCountdownOverlay: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.16), lineWidth: 10)
                    .frame(width: 156, height: 156)
                Circle()
                    .trim(from: 0, to: camera.plankProgress)
                    .stroke(
                        camera.currentWorkoutState == .plankBroken ? Color.red : Color.green,
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .frame(width: 156, height: 156)

                Text(camera.formattedPlankTime)
                    .font(.system(size: 38, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }

            Text(camera.plankStatusText)
                .font(.headline.weight(.semibold))
                .foregroundStyle(camera.currentWorkoutState == .plankBroken ? .red : .white.opacity(0.9))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct SkeletonOverlayView: View {
    let points: [PoseJointPoint]
    let videoSize: CGSize

    private let connections: [(PoseJointName, PoseJointName)] = [
        (.leftShoulder, .leftElbow),
        (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow),
        (.rightElbow, .rightWrist),
        (.leftHip, .leftKnee),
        (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee),
        (.rightKnee, .rightAnkle),
        (.leftShoulder, .rightShoulder),
        (.leftHip, .rightHip),
        (.leftShoulder, .leftHip),
        (.rightShoulder, .rightHip)
    ]

    var body: some View {
        Canvas { context, size in
            let videoRect = fittedVideoRect(in: size)
            let pointMap = Dictionary(uniqueKeysWithValues: points.map { ($0.name, $0.location) })

            for connection in connections {
                guard let start = pointMap[connection.0], let end = pointMap[connection.1] else { continue }
                var path = Path()
                path.move(to: screenPoint(from: start, in: videoRect))
                path.addLine(to: screenPoint(from: end, in: videoRect))
                context.stroke(path, with: .color(.green.opacity(0.82)), lineWidth: 3)
            }

            for point in points {
                let center = screenPoint(from: point.location, in: videoRect)
                let radius: CGFloat = 5
                let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
                context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.95)))
                context.stroke(Path(ellipseIn: rect), with: .color(.green), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
        .opacity(points.isEmpty ? 0 : 1)
    }

    private func fittedVideoRect(in size: CGSize) -> CGRect {
        guard videoSize.width > 0, videoSize.height > 0, size.width > 0, size.height > 0 else {
            return CGRect(origin: .zero, size: size)
        }

        let videoAspect = videoSize.width / videoSize.height
        let containerAspect = size.width / size.height

        if videoAspect > containerAspect {
            let height = size.width / videoAspect
            return CGRect(x: 0, y: (size.height - height) / 2, width: size.width, height: height)
        } else {
            let width = size.height * videoAspect
            return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
        }
    }

    private func screenPoint(from normalizedPoint: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: rect.minX + normalizedPoint.x * rect.width,
            y: rect.minY + (1 - normalizedPoint.y) * rect.height
        )
    }
}

private struct PreviewPlaceholder: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: camera.statusIsError ? "video.slash.fill" : "camera.viewfinder")
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(camera.statusIsError ? .red : .secondary)

            Text(camera.isSwitchingCamera ? "Switching Camera" : camera.previewPlaceholder)
                .font(.headline)
                .foregroundStyle(.primary)

            if camera.isSwitchingCamera {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.72))
    }
}

private struct CameraControlPanel: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Camera")
                    .font(.title3.weight(.semibold))

                HStack(spacing: 8) {
                    CameraModePill(
                        title: "Mac",
                        systemImage: "display",
                        isSelected: camera.session != nil && !camera.selectedDeviceIsIPhone,
                        isEnabled: camera.hasMacCamera
                    ) {
                        camera.selectMacCamera()
                    }

                    CameraModePill(
                        title: "iPhone",
                        systemImage: "iphone",
                        isSelected: camera.selectedDeviceIsIPhone,
                        isEnabled: camera.hasIPhoneCamera
                    ) {
                        camera.selectIPhoneCamera()
                    }

                    Button {
                        camera.refreshCameraDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.callout.weight(.semibold))
                            .frame(width: 36, height: 36)
                            .background(Color.white.opacity(0.07), in: Circle())
                            .overlay {
                                Circle()
                                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .help("Refresh cameras")
                }
            }

            ZoomControlPanel(camera: camera)

            VStack(alignment: .leading, spacing: 10) {
                Text("Workout")
                    .font(.headline.weight(.semibold))

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
                    ForEach(ExerciseMode.allCases) { mode in
                        ExerciseModeButton(
                            mode: mode,
                            isSelected: camera.selectedMode == mode
                        ) {
                            camera.selectExerciseMode(mode)
                        }
                    }
                }
            }

            StatusStack(camera: camera)

            Divider()
                .overlay(Color.white.opacity(0.10))

            Toggle("Debug Panel", isOn: Binding(
                get: { camera.showDebugPanel },
                set: { camera.setDebugPanelVisible($0) }
            ))
            .toggleStyle(.switch)
            .font(.footnote.weight(.medium))

            VStack(alignment: .leading, spacing: 10) {
                Text("Devices")
                    .font(.headline.weight(.semibold))

                if camera.devices.isEmpty {
                    EmptyDeviceCard()
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(camera.devices) { device in
                                DeviceCard(
                                    device: device,
                                    isSelected: camera.selectedDeviceID == device.id
                                ) {
                                    camera.selectCamera(id: device.id)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .scrollIndicators(.hidden)
                }
            }

            Spacer()
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
    }
}

private struct ZoomControlPanel: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Lens / Zoom")
                    .font(.headline.weight(.semibold))
                Spacer()
                Text("\(camera.zoomFactor, specifier: "%.2f")x")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                ZoomPresetButton(title: "0.5x", isEnabled: camera.supportsUltraWideZoom) {
                    camera.setZoomFactor(0.5)
                }
                ZoomPresetButton(title: "1x", isEnabled: camera.supportsWideZoom) {
                    camera.setZoomFactor(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            Text("Active: \(camera.selectedInputSourceName)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if camera.selectedDeviceIsIPhone && !camera.supportsUltraWideZoom {
                Text("0.5x is not exposed by this Continuity Camera device.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if camera.inputSources.isEmpty {
                Text("macOS does not expose digital zoom for this camera.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct ZoomPresetButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(Color.white.opacity(isEnabled ? 0.08 : 0.035), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.white.opacity(isEnabled ? 0.12 : 0.05), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
    }
}

private struct ExerciseModeButton: View {
    let mode: ExerciseMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(mode.title)
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(isSelected ? Color.green.opacity(0.22) : Color.white.opacity(0.06), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(isSelected ? Color.green.opacity(0.45) : Color.white.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct CameraModePill: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.callout.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(isSelected ? Color.white.opacity(0.18) : Color.white.opacity(0.07), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(isSelected ? Color.white.opacity(0.28) : Color.white.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled ? .primary : .secondary)
        .opacity(isEnabled ? 1 : 0.45)
        .disabled(!isEnabled)
    }
}

private struct StatusStack: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack(spacing: 8) {
            if camera.statusIsError {
                StatusRow(title: "No Camera Available", systemImage: "xmark.circle.fill", color: .red)
            } else if camera.isSwitchingCamera {
                StatusRow(title: "Switching Camera", systemImage: "arrow.triangle.2.circlepath", color: .yellow)
            } else if camera.session != nil {
                StatusRow(title: "Camera Connected", systemImage: "checkmark.circle.fill", color: .green)
            } else {
                StatusRow(title: "Loading Camera", systemImage: "circle.dotted", color: .secondary)
            }

            StatusRow(
                title: camera.hasIPhoneCamera ? "iPhone Continuity Detected" : "iPhone Continuity Not Found",
                systemImage: camera.hasIPhoneCamera ? "iphone.circle.fill" : "iphone.slash",
                color: camera.hasIPhoneCamera ? .blue : .secondary
            )
        }
    }
}

private struct StatusRow: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .foregroundStyle(color)
                .frame(width: 18)
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct DeviceCard: View {
    let device: CameraDeviceInfo
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: device.isContinuityCamera ? "iphone" : "web.camera.fill")
                    .font(.title3)
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 28)

                VStack(alignment: .leading, spacing: 3) {
                    Text(device.localizedName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(device.isContinuityCamera ? "Continuity Camera" : device.deviceType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(12)
            .background(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.green.opacity(0.38) : Color.white.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyDeviceCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "video.slash")
                .foregroundStyle(.red)
            Text("No cameras found")
                .font(.callout.weight(.semibold))
            Text("Connect a camera or enable camera permission.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct CameraDeviceInfo: Identifiable {
    let id: String
    let name: String
    let localizedName: String
    let deviceType: String
    let isContinuityCamera: Bool
}

struct CameraInputSourceInfo: Identifiable {
    let id: String
    let name: String
    let inferredZoomFactor: CGFloat
    let isUltraWide: Bool
}

enum PoseJointName: Hashable {
    case leftShoulder
    case leftElbow
    case leftWrist
    case rightShoulder
    case rightElbow
    case rightWrist
    case leftHip
    case leftKnee
    case leftAnkle
    case rightHip
    case rightKnee
    case rightAnkle
}

struct PoseJointPoint: Identifiable {
    let id: PoseJointName
    let name: PoseJointName
    let location: CGPoint
    let confidence: Float
}

private final class SoundFeedbackService {
    func playRepAccepted() {
        playFirstAvailableSound(named: ["Pop", "Ping", "Glass"], volume: 0.35)
    }

    func playRepMissed() {
        playFirstAvailableSound(named: ["Funk", "Basso", "Submarine"], volume: 0.28)
    }

    func playPlankMilestone() {
        playFirstAvailableSound(named: ["Hero", "Glass", "Ping"], volume: 0.40)
    }

    func playFinalCountdownTick() {
        playFirstAvailableSound(named: ["Tink", "Pop", "Ping"], volume: 0.30)
    }

    private func playFirstAvailableSound(named names: [String], volume: Float) {
        for name in names {
            guard let sound = NSSound(named: NSSound.Name(name)) else { continue }
            sound.volume = volume
            sound.play()
            return
        }

        NSSound.beep()
    }
}

@MainActor
final class CameraModel: ObservableObject {
    @Published private(set) var session: AVCaptureSession?
    @Published private(set) var devices: [CameraDeviceInfo] = []
    @Published private(set) var hasMacCamera = false
    @Published private(set) var hasIPhoneCamera = false
    @Published private(set) var selectedDeviceID: String?
    @Published private(set) var selectedCameraName = "None"
    @Published private(set) var statusMessage = "Starting camera..."
    @Published private(set) var statusIsError = false
    @Published private(set) var isSwitchingCamera = false
    @Published var selectedMode: ExerciseMode = .pushUps
    @Published private(set) var repCount = 0
    @Published private(set) var currentPoseState = "idle"
    @Published private(set) var currentWorkoutState: WorkoutState = .idle
    @Published private(set) var confidence: Float = 0
    @Published private(set) var isPersonDetected = false
    @Published var showSkeletonOverlay = true
    @Published var showDebugPanel = true
    @Published private(set) var posePoints: [PoseJointPoint] = []
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var inputSources: [CameraInputSourceInfo] = []
    @Published private(set) var selectedInputSourceID: String?
    @Published private(set) var selectedInputSourceName = "Default"
    @Published private(set) var previewVideoSize = CGSize(width: 16, height: 9)
    @Published private(set) var plankTimeRemaining: Double = 0
    @Published private(set) var plankIsActive = false
    @Published private(set) var coachingMessage: String?
    @Published private(set) var celebrationMessage: String?
    @Published var plankDuration: Double = 60
    var onWorkoutCompleted: ((ExerciseMode, Int) -> Void)?

    var deviceSummary: String {
        guard !devices.isEmpty else { return "None" }
        return devices.map { "\($0.localizedName) [\($0.deviceType)]" }.joined(separator: ", ")
    }

    var previewPlaceholder: String {
        statusIsError ? statusMessage : "No camera preview"
    }

    var selectedDeviceIsIPhone: Bool {
        devices.first { $0.id == selectedDeviceID }?.isContinuityCamera ?? false
    }

    var formattedPlankTime: String {
        let remainingSeconds = max(0, Int(plankTimeRemaining.rounded(.up)))
        return String(format: "%02d:%02d", remainingSeconds / 60, remainingSeconds % 60)
    }

    var plankProgress: Double {
        guard plankDuration > 0 else { return 0 }
        return max(0, min(1, plankTimeRemaining / plankDuration))
    }

    var plankStatusText: String {
        switch currentWorkoutState {
        case .plankBroken:
            "Plank broken"
        case .plankActive:
            "Good form"
        default:
            "Hold position"
        }
    }

    var previewAspectRatio: CGFloat {
        guard previewVideoSize.width > 0, previewVideoSize.height > 0 else {
            return 16.0 / 9.0
        }

        return previewVideoSize.width / previewVideoSize.height
    }

    var supportsUltraWideZoom: Bool {
        inputSources.contains { $0.isUltraWide }
    }

    var supportsWideZoom: Bool {
        inputSources.isEmpty || inputSources.contains { !$0.isUltraWide }
    }

    private let sessionController = CameraSessionController()
    private let poseDetectionService = PoseDetectionService()
    private let soundFeedback = SoundFeedbackService()
    private let targetRepCount = 20
    private var captureDevices: [AVCaptureDevice] = []
    private var lastPlankTick: Date?
    private var plankBrokenUntil: Date?
    private var workoutCompletionRecorded = false
    private var lastSoundedRepCount = 0
    private var lastMissSoundDate: Date?
    private var lastFinalPlankSecondSound: Int?
    private var plankWasStable = false
    private var lastCelebratedRepCount = 0
    private var lastCelebratedPlankBucket = 0
    private var celebrationClearTask: Task<Void, Never>?

    init() {
        poseDetectionService.onUpdate = { [weak self] update in
            self?.applyPoseUpdate(update)
        }
        poseDetectionService.setMode(selectedMode)
        resetWorkoutState()
    }

    func start() async {
        refreshDevices()

        let granted = await requestCameraAccess()
        guard granted else {
            clearPreview(message: "Camera permission denied. Enable camera access in System Settings.", isError: true)
            return
        }

        guard let device = preferredMacCamera() else {
            clearPreview(message: "No camera available.", isError: true)
            return
        }

        configureCamera(device)
    }

    func stop() {
        sessionController.stop()
        poseDetectionService.reset()
        session = nil
        selectedDeviceID = nil
        selectedCameraName = "None"
        isSwitchingCamera = false
        resetPoseState()
    }

    func selectMacCamera() {
        refreshDevices()
        guard let device = preferredMacCamera() else {
            clearPreview(message: "No Mac camera is available.", isError: true)
            return
        }
        configureCamera(device)
    }

    func selectIPhoneCamera() {
        refreshDevices()
        guard let device = preferredIPhoneCamera() else {
            clearPreview(message: "iPhone Continuity Camera is not available.", isError: true)
            return
        }
        configureCamera(device)
    }

    func selectCamera(id: String) {
        refreshDevices()
        guard let device = captureDevices.first(where: { $0.uniqueID == id }) else {
            clearPreview(message: "Selected camera is no longer available.", isError: true)
            return
        }
        configureCamera(device)
    }

    func refreshCameraDevices() {
        refreshDevices()
        statusMessage = hasIPhoneCamera
            ? "Camera list refreshed. iPhone Continuity Camera detected."
            : "Camera list refreshed. iPhone Continuity Camera not found."
        statusIsError = false
    }

    func selectExerciseMode(_ mode: ExerciseMode) {
        guard selectedMode != mode else { return }
        selectedMode = mode
        poseDetectionService.setMode(mode)
        poseDetectionService.reset()
        resetWorkoutState()
    }

    func setSkeletonOverlayVisible(_ isVisible: Bool) {
        showSkeletonOverlay = isVisible
    }

    func setDebugPanelVisible(_ isVisible: Bool) {
        showDebugPanel = isVisible
    }

    func setZoomFactor(_ requestedZoomFactor: CGFloat) {
        guard let requestedInputSourceID = preferredInputSourceID(for: requestedZoomFactor) else {
            statusMessage = requestedZoomFactor < 1
                ? "0.5x lens is not exposed by this camera."
                : "1x lens is not exposed by this camera."
            statusIsError = false
            return
        }

        sessionController.setInputSource(id: requestedInputSourceID) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let activeInputSourceID):
                self.applyActiveInputSource(id: activeInputSourceID)
                self.statusMessage = "Camera running: \(self.selectedCameraName)"
                self.statusIsError = false
            case .failure(let error):
                self.statusMessage = "Lens could not be changed: \(error.localizedDescription)"
                self.statusIsError = false
            }
        }
    }

    private func requestCameraAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    private func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .external,
                .continuityCamera
            ],
            mediaType: .video,
            position: .unspecified
        )

        captureDevices = discovery.devices
        devices = captureDevices.map {
            CameraDeviceInfo(
                id: $0.uniqueID,
                name: $0.localizedName,
                localizedName: $0.localizedName,
                deviceType: $0.deviceType.rawValue,
                isContinuityCamera: isIPhoneCamera($0)
            )
        }
        hasIPhoneCamera = captureDevices.contains(where: isIPhoneCamera)
        hasMacCamera = preferredMacCamera() != nil

        print("BreakGateWorkout camera discovery: \(captureDevices.count) video device(s)")
        for device in captureDevices {
            print("BreakGateWorkout camera device: name=\(device.localizedName), deviceType=\(device.deviceType.rawValue), localizedName=\(device.localizedName), isContinuityCamera=\(device.isContinuityCamera)")
        }
        print("BreakGateWorkout iPhone Continuity Camera detected: \(hasIPhoneCamera)")
    }

    private func preferredMacCamera() -> AVCaptureDevice? {
        captureDevices.first { !isIPhoneCamera($0) } ?? captureDevices.first
    }

    private func preferredIPhoneCamera() -> AVCaptureDevice? {
        captureDevices.first(where: isIPhoneCamera)
    }

    private func isIPhoneCamera(_ device: AVCaptureDevice) -> Bool {
        let name = device.localizedName.lowercased()
        return device.isContinuityCamera || name.contains("iphone") || name.contains("continuity")
    }

    private func configureCamera(_ device: AVCaptureDevice) {
        let deviceName = device.localizedName
        selectedDeviceID = device.uniqueID
        selectedCameraName = deviceName
        updateZoomLimits(for: device)
        statusMessage = "Starting \(deviceName)..."
        statusIsError = false
        isSwitchingCamera = true
        session = nil
        poseDetectionService.reset()
        resetPoseState()

        sessionController.configure(
            device: device,
            videoDelegate: poseDetectionService,
            videoDelegateQueue: poseDetectionService.videoOutputQueue
        ) { [weak self] result in
            guard let self else { return }

            switch result {
            case .success(let newSession):
                self.session = newSession
                self.selectedDeviceID = device.uniqueID
                self.selectedCameraName = deviceName
                self.setZoomFactor(1)
                self.statusMessage = "Camera running: \(deviceName)"
                self.statusIsError = false
                self.isSwitchingCamera = false
            case .failure(let error):
                self.session = nil
                self.statusMessage = "Camera could not start: \(error.localizedDescription)"
                self.statusIsError = true
                self.isSwitchingCamera = false
            }
        }
    }

    private func clearPreview(message: String, isError: Bool) {
        sessionController.stop()
        poseDetectionService.reset()
        session = nil
        selectedDeviceID = nil
        selectedCameraName = "None"
        statusMessage = message
        statusIsError = isError
        isSwitchingCamera = false
        resetPoseState()
    }

    private func applyPoseUpdate(_ update: PoseDetectionUpdate) {
        confidence = update.confidence
        isPersonDetected = update.isPersonDetected
        posePoints = update.posePoints
        previewVideoSize = update.videoSize
        updateCoachingMessage()

        if selectedMode == .plank {
            updatePlankState(with: update)
        } else {
            repCount = update.repCount
            currentWorkoutState = update.workoutState
            currentPoseState = update.workoutState.rawValue
            playRepSoundIfNeeded()
            playMissSoundIfNeeded(for: update)
            celebrateRepProgressIfNeeded()
            checkWorkoutCompletion()
        }
    }

    private func resetPoseState() {
        resetWorkoutState()
    }

    private func resetWorkoutState() {
        repCount = 0
        currentWorkoutState = .idle
        currentPoseState = WorkoutState.idle.rawValue
        confidence = 0
        isPersonDetected = false
        posePoints = []
        plankTimeRemaining = selectedMode == .plank ? plankDuration : 0
        plankIsActive = false
        lastPlankTick = nil
        plankBrokenUntil = nil
        workoutCompletionRecorded = false
        lastSoundedRepCount = 0
        lastMissSoundDate = nil
        lastFinalPlankSecondSound = nil
        plankWasStable = false
        lastCelebratedRepCount = 0
        lastCelebratedPlankBucket = 0
        coachingMessage = nil
        celebrationMessage = nil
        celebrationClearTask?.cancel()
        celebrationClearTask = nil
    }

    private func updateZoomLimits(for device: AVCaptureDevice) {
        inputSources = cameraInputSourceInfos(for: device)
        applyActiveInputSource(id: device.activeInputSource?.inputSourceID)

        print("BreakGateWorkout input sources for \(device.localizedName): \(inputSources.count)")
        for source in inputSources {
            print("BreakGateWorkout input source: name=\(source.name), id=\(source.id), inferredZoom=\(source.inferredZoomFactor)x")
        }
    }

    private func cameraInputSourceInfos(for device: AVCaptureDevice) -> [CameraInputSourceInfo] {
        device.inputSources.map { source in
            let isUltraWide = isUltraWideInputSource(source)
            return CameraInputSourceInfo(
                id: source.inputSourceID,
                name: source.localizedName,
                inferredZoomFactor: isUltraWide ? 0.5 : 1,
                isUltraWide: isUltraWide
            )
        }
    }

    private func isUltraWideInputSource(_ source: AVCaptureDevice.InputSource) -> Bool {
        let searchText = "\(source.localizedName) \(source.inputSourceID)".lowercased()
        return searchText.contains("ultra")
            || searchText.contains("ultrawide")
            || searchText.contains("ultra-wide")
            || searchText.contains("0.5")
            || searchText.contains("0,5")
    }

    private func preferredInputSourceID(for requestedZoomFactor: CGFloat) -> String? {
        guard !inputSources.isEmpty else { return nil }

        if requestedZoomFactor < 1 {
            return inputSources.first { $0.isUltraWide }?.id
        }

        return inputSources.first { !$0.isUltraWide }?.id ?? inputSources.first?.id
    }

    private func applyActiveInputSource(id inputSourceID: String?) {
        selectedInputSourceID = inputSourceID

        guard let inputSourceID,
              let source = inputSources.first(where: { $0.id == inputSourceID }) else {
            selectedInputSourceName = inputSources.first?.name ?? "Default"
            zoomFactor = inputSources.first?.inferredZoomFactor ?? 1
            return
        }

        selectedInputSourceName = source.name
        zoomFactor = source.inferredZoomFactor
    }

    private func updatePlankState(with update: PoseDetectionUpdate) {
        let now = Date()
        let isStable = update.isPersonDetected && update.confidence >= 0.22 && update.workoutState == .plankActive

        if !isStable {
            if selectedMode == .plank && plankWasStable && plankTimeRemaining > 0 {
                soundFeedback.playRepMissed()
            }

            plankTimeRemaining = plankDuration
            plankIsActive = false
            lastPlankTick = nil
            plankBrokenUntil = now.addingTimeInterval(1.5)
            currentWorkoutState = .plankBroken
            currentPoseState = WorkoutState.plankBroken.rawValue
            lastCelebratedPlankBucket = 0
            lastFinalPlankSecondSound = nil
            plankWasStable = false
            return
        }

        if let brokenUntil = plankBrokenUntil, now < brokenUntil {
            currentWorkoutState = .plankBroken
            currentPoseState = WorkoutState.plankBroken.rawValue
            return
        }

        plankBrokenUntil = nil
        plankIsActive = true
        plankWasStable = true

        if let lastPlankTick {
            plankTimeRemaining = max(0, plankTimeRemaining - now.timeIntervalSince(lastPlankTick))
        }

        lastPlankTick = now
        currentWorkoutState = .plankActive
        currentPoseState = WorkoutState.plankActive.rawValue
        playPlankFinalCountdownIfNeeded()
        celebratePlankProgressIfNeeded()
        checkWorkoutCompletion()
    }

    private func updateCoachingMessage() {
        guard isPersonDetected, !posePoints.isEmpty else {
            coachingMessage = "Step into frame"
            return
        }

        if confidence < 0.20 {
            coachingMessage = "Improve lighting or face the camera"
            return
        }

        let xs = posePoints.map(\.location.x)
        let ys = posePoints.map(\.location.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            coachingMessage = "Hold still for tracking"
            return
        }

        let width = maxX - minX
        let height = maxY - minY
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2

        if width < 0.18 && height < 0.30 {
            coachingMessage = "Step closer"
        } else if width > 0.82 || height > 0.88 {
            coachingMessage = "Step farther back"
        } else if centerX < 0.34 {
            coachingMessage = "Move right"
        } else if centerX > 0.66 {
            coachingMessage = "Move left"
        } else if centerY < 0.30 {
            coachingMessage = "Move lower in frame"
        } else if centerY > 0.72 {
            coachingMessage = "Move higher in frame"
        } else if selectedMode == .plank && currentWorkoutState == .plankBroken {
            coachingMessage = "Straighten shoulders, hips, knees"
        } else {
            coachingMessage = "Good framing"
        }
    }

    private func celebrateRepProgressIfNeeded() {
        guard repCount > lastCelebratedRepCount else { return }
        lastCelebratedRepCount = repCount
        guard repCount.isMultiple(of: 5) else { return }
        showCelebration(message: celebrationText(for: repCount))
    }

    private func celebratePlankProgressIfNeeded() {
        let heldSeconds = max(0, plankDuration - plankTimeRemaining)
        let bucket = Int(heldSeconds / 20)
        guard bucket > 0, bucket > lastCelebratedPlankBucket else { return }

        lastCelebratedPlankBucket = bucket
        soundFeedback.playPlankMilestone()
        showCelebration(message: "\(bucket * 20)s held")
    }

    private func playRepSoundIfNeeded() {
        guard repCount > lastSoundedRepCount else { return }
        lastSoundedRepCount = repCount
        soundFeedback.playRepAccepted()
    }

    private func playMissSoundIfNeeded(for update: PoseDetectionUpdate) {
        guard update.repCount == lastSoundedRepCount else { return }

        let hasWeakSignal = !update.isPersonDetected && update.confidence >= 0.12
        let hasUncertainTracking = update.isPersonDetected
            && update.workoutState == .tracking
            && update.confidence >= 0.18
            && update.confidence < 0.34

        guard hasWeakSignal || hasUncertainTracking else { return }

        let now = Date()
        if let lastMissSoundDate, now.timeIntervalSince(lastMissSoundDate) < 2.0 {
            return
        }

        lastMissSoundDate = now
        soundFeedback.playRepMissed()
    }

    private func playPlankFinalCountdownIfNeeded() {
        let remainingSecond = Int(ceil(plankTimeRemaining))
        guard (1...5).contains(remainingSecond), lastFinalPlankSecondSound != remainingSecond else { return }

        lastFinalPlankSecondSound = remainingSecond
        soundFeedback.playFinalCountdownTick()
    }

    private func celebrationText(for rep: Int) -> String {
        switch rep % 4 {
        case 1:
            return "Nice rep \(rep)"
        case 2:
            return "Keep going"
        case 3:
            return "Clean work"
        default:
            return "Rep \(rep) locked"
        }
    }

    private func showCelebration(message: String) {
        celebrationClearTask?.cancel()
        celebrationMessage = message

        celebrationClearTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.celebrationMessage = nil
                self?.celebrationClearTask = nil
            }
        }
    }

    private func checkWorkoutCompletion() {
        guard !workoutCompletionRecorded else { return }

        switch selectedMode {
        case .pushUps, .squats, .abs:
            guard repCount >= targetRepCount else { return }
            workoutCompletionRecorded = true
            statusMessage = "Workout completed. BreakGate unlocked."
            onWorkoutCompleted?(selectedMode, repCount)
        case .plank:
            guard plankTimeRemaining <= 0, plankIsActive else { return }
            workoutCompletionRecorded = true
            statusMessage = "Workout completed. BreakGate unlocked."
            onWorkoutCompleted?(selectedMode, Int(plankDuration.rounded()))
        }
    }
}

private final class CameraSessionController: @unchecked Sendable {
    private let queue = DispatchQueue(label: "BreakGateWorkout.camera.session")
    private var currentSession: AVCaptureSession?
    private var currentDevice: AVCaptureDevice?

    func configure(
        device: AVCaptureDevice,
        videoDelegate: AVCaptureVideoDataOutputSampleBufferDelegate,
        videoDelegateQueue: DispatchQueue,
        completion: @escaping @MainActor (Result<AVCaptureSession, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }

            self.stopCurrentSession()

            let newSession = AVCaptureSession()

            do {
                newSession.beginConfiguration()
                newSession.sessionPreset = .high

                // The session is new, but keep this defensive in case the code changes later.
                for input in newSession.inputs {
                    newSession.removeInput(input)
                }

                let input = try AVCaptureDeviceInput(device: device)
                guard newSession.canAddInput(input) else {
                    throw CameraError.cannotAddInput
                }

                newSession.addInput(input)

                let videoOutput = AVCaptureVideoDataOutput()
                videoOutput.alwaysDiscardsLateVideoFrames = true
                videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                videoOutput.setSampleBufferDelegate(videoDelegate, queue: videoDelegateQueue)

                guard newSession.canAddOutput(videoOutput) else {
                    throw CameraError.cannotAddVideoOutput
                }

                newSession.addOutput(videoOutput)

                if let connection = videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
                    connection.isVideoMirrored = false
                }

                newSession.commitConfiguration()
                newSession.startRunning()

                self.currentSession = newSession
                self.currentDevice = device

                Task { @MainActor in
                    completion(.success(newSession))
                }
            } catch {
                newSession.commitConfiguration()

                Task { @MainActor in
                    completion(.failure(error))
                }
            }
        }
    }

    func setInputSource(
        id inputSourceID: String,
        completion: @escaping @MainActor (Result<String, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let device = self?.currentDevice else {
                Task { @MainActor in
                    completion(.failure(CameraError.noActiveCamera))
                }
                return
            }

            guard let inputSource = device.inputSources.first(where: { $0.inputSourceID == inputSourceID }) else {
                Task { @MainActor in
                    completion(.failure(CameraError.inputSourceUnavailable))
                }
                return
            }

            do {
                try device.lockForConfiguration()
                device.activeInputSource = inputSource
                device.unlockForConfiguration()

                Task { @MainActor in
                    completion(.success(inputSource.inputSourceID))
                }
            } catch {
                Task { @MainActor in
                    completion(.failure(error))
                }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.stopCurrentSession()
        }
    }

    private func stopCurrentSession() {
        guard let session = currentSession else { return }

        if session.isRunning {
            session.stopRunning()
        }

        session.beginConfiguration()
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }
        session.commitConfiguration()
        currentSession = nil
        currentDevice = nil
    }
}

private enum CameraError: LocalizedError {
    case cannotAddInput
    case cannotAddVideoOutput
    case noActiveCamera
    case inputSourceUnavailable

    var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            "The selected camera could not be added to the capture session."
        case .cannotAddVideoOutput:
            "The camera frame output could not be added to the capture session."
        case .noActiveCamera:
            "No active camera is available for lens control."
        case .inputSourceUnavailable:
            "The selected lens is not available on this camera."
        }
    }
}

struct PoseDetectionUpdate {
    let repCount: Int
    let workoutState: WorkoutState
    let confidence: Float
    let isPersonDetected: Bool
    let posePoints: [PoseJointPoint]
    let videoSize: CGSize
}

private final class PoseDetectionService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let videoOutputQueue = DispatchQueue(label: "BreakGateWorkout.pose.videoOutput", qos: .userInitiated)

    var onUpdate: (@MainActor (PoseDetectionUpdate) -> Void)?

    private let bodyPoseRequest = VNDetectHumanBodyPoseRequest()
    private let minimumPointConfidence: Float = 0.25
    private let minimumFrameInterval: TimeInterval = 1.0 / 30.0
    private let pushUpAngleUpThreshold: CGFloat = 150
    private let pushUpAngleDownThreshold: CGFloat = 95
    private let squatKneeBentThreshold: CGFloat = 115
    private let squatKneeStraightThreshold: CGFloat = 155
    private let absContractedThreshold: CGFloat = 55
    private let absExtendedThreshold: CGFloat = 105
    private let plankStraightThreshold: CGFloat = 145

    private var mode: ExerciseMode = .pushUps
    private var lastProcessedTime: CFTimeInterval = 0
    private var isProcessingFrame = false
    private var repCount = 0
    private var personWasDetected = false
    private var pushUpPosition: ExercisePosition = .waiting
    private var squatPosition: ExercisePosition = .waiting
    private var absPosition: ExercisePosition = .waiting

    func setMode(_ mode: ExerciseMode) {
        videoOutputQueue.async { [weak self] in
            self?.mode = mode
            self?.resetStateOnQueue()
        }
    }

    func reset() {
        videoOutputQueue.async { [weak self] in
            guard let self else { return }
            self.resetStateOnQueue()

            Task { @MainActor in
                self.onUpdate?(
                    PoseDetectionUpdate(
                        repCount: 0,
                        workoutState: .idle,
                        confidence: 0,
                        isPersonDetected: false,
                        posePoints: [],
                        videoSize: CGSize(width: 16, height: 9)
                    )
                )
            }
        }
    }

    private func resetStateOnQueue() {
        lastProcessedTime = 0
        isProcessingFrame = false
        repCount = 0
        personWasDetected = false
        pushUpPosition = .waiting
        squatPosition = .waiting
        absPosition = .waiting
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = CACurrentMediaTime()
        guard now - lastProcessedTime >= minimumFrameInterval else { return }
        guard !isProcessingFrame else { return }

        lastProcessedTime = now
        isProcessingFrame = true

        defer {
            isProcessingFrame = false
        }

        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        let videoSize = videoSize(from: sampleBuffer)

        do {
            try handler.perform([bodyPoseRequest])

            guard let observation = bodyPoseRequest.results?.first else {
                publishPersonLostIfNeeded()
                publish(workoutState: .noPerson, confidence: 0, isPersonDetected: false, posePoints: [], videoSize: videoSize)
                return
            }

            let points = try observation.recognizedPoints(.all)
            let usablePoints = points.values.filter { $0.confidence >= minimumPointConfidence }
            let averageConfidence = usablePoints.isEmpty ? 0 : usablePoints.reduce(Float(0)) { $0 + $1.confidence } / Float(usablePoints.count)

            guard usablePoints.count >= 5 else {
                publishPersonLostIfNeeded()
                publish(workoutState: .noPerson, confidence: averageConfidence, isPersonDetected: false, posePoints: [], videoSize: videoSize)
                return
            }

            if !personWasDetected {
                personWasDetected = true
                print("BreakGateWorkout pose: person detected")
            }

            let workoutState = updateExerciseState(points: points)
            publish(
                workoutState: workoutState,
                confidence: averageConfidence,
                isPersonDetected: true,
                posePoints: skeletonPoints(from: points),
                videoSize: videoSize
            )
        } catch {
            publish(workoutState: .idle, confidence: 0, isPersonDetected: false, posePoints: [], videoSize: videoSize)
        }
    }

    private func videoSize(from sampleBuffer: CMSampleBuffer) -> CGSize {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return CGSize(width: 16, height: 9)
        }

        return CGSize(
            width: CVPixelBufferGetWidth(imageBuffer),
            height: CVPixelBufferGetHeight(imageBuffer)
        )
    }

    private func skeletonPoints(from points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> [PoseJointPoint] {
        let jointMap: [(VNHumanBodyPoseObservation.JointName, PoseJointName)] = [
            (.leftShoulder, .leftShoulder),
            (.leftElbow, .leftElbow),
            (.leftWrist, .leftWrist),
            (.rightShoulder, .rightShoulder),
            (.rightElbow, .rightElbow),
            (.rightWrist, .rightWrist),
            (.leftHip, .leftHip),
            (.leftKnee, .leftKnee),
            (.leftAnkle, .leftAnkle),
            (.rightHip, .rightHip),
            (.rightKnee, .rightKnee),
            (.rightAnkle, .rightAnkle)
        ]

        return jointMap.compactMap { visionName, localName in
            guard let point = points[visionName], point.confidence >= minimumPointConfidence else {
                return nil
            }

            return PoseJointPoint(
                id: localName,
                name: localName,
                location: point.location,
                confidence: point.confidence
            )
        }
    }

    private func updateExerciseState(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> WorkoutState {
        switch mode {
        case .pushUps:
            guard let elbowAngle = bestAngle(
                points: points,
                firstCandidates: [.leftShoulder, .rightShoulder],
                middleCandidates: [.leftElbow, .rightElbow],
                lastCandidates: [.leftWrist, .rightWrist]
            ) else { return .tracking }

            return updatePushUpState(elbowAngle: elbowAngle) ? .activeExercise : .tracking
        case .squats:
            guard let kneeAngle = bestAngle(
                points: points,
                firstCandidates: [.leftHip, .rightHip],
                middleCandidates: [.leftKnee, .rightKnee],
                lastCandidates: [.leftAnkle, .rightAnkle]
            ) else { return .tracking }

            return updateSquatState(kneeAngle: kneeAngle) ? .activeExercise : .tracking
        case .abs:
            guard let torsoAngle = bestAngle(
                points: points,
                firstCandidates: [.leftShoulder, .rightShoulder],
                middleCandidates: [.leftHip, .rightHip],
                lastCandidates: [.leftKnee, .rightKnee]
            ) else { return .tracking }

            return updateAbsState(torsoAngle: torsoAngle) ? .activeExercise : .tracking
        case .plank:
            return isPlankFormValid(points: points) ? .plankActive : .plankBroken
        }
    }

    private func updatePushUpState(elbowAngle: CGFloat) -> Bool {
        if elbowAngle <= pushUpAngleDownThreshold {
            pushUpPosition = .down
            return false
        }

        if elbowAngle >= pushUpAngleUpThreshold {
            if pushUpPosition == .down {
                repCount += 1
                pushUpPosition = .up
                print("BreakGateWorkout pose: rep counted (\(repCount))")
                return true
            }
            pushUpPosition = .up
        }

        return false
    }

    private func updateSquatState(kneeAngle: CGFloat) -> Bool {
        if kneeAngle <= squatKneeBentThreshold {
            squatPosition = .down
            return false
        }

        if kneeAngle >= squatKneeStraightThreshold {
            if squatPosition == .down {
                repCount += 1
                squatPosition = .up
                print("BreakGateWorkout pose: rep counted (\(repCount))")
                return true
            }
            squatPosition = .up
        }

        return false
    }

    private func updateAbsState(torsoAngle: CGFloat) -> Bool {
        if torsoAngle <= absContractedThreshold {
            absPosition = .down
            return false
        }

        if torsoAngle >= absExtendedThreshold {
            if absPosition == .down {
                repCount += 1
                absPosition = .up
                print("BreakGateWorkout pose: rep counted (\(repCount))")
                return true
            }
            absPosition = .up
        }

        return false
    }

    private func isPlankFormValid(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> Bool {
        guard let bodyLineAngle = bestAngle(
            points: points,
            firstCandidates: [.leftShoulder, .rightShoulder],
            middleCandidates: [.leftHip, .rightHip],
            lastCandidates: [.leftKnee, .rightKnee]
        ) else {
            return false
        }

        return bodyLineAngle >= plankStraightThreshold
    }

    private func bestAngle(
        points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
        firstCandidates: [VNHumanBodyPoseObservation.JointName],
        middleCandidates: [VNHumanBodyPoseObservation.JointName],
        lastCandidates: [VNHumanBodyPoseObservation.JointName]
    ) -> CGFloat? {
        for index in firstCandidates.indices {
            guard
                let first = validPoint(points[firstCandidates[index]]),
                let middle = validPoint(points[middleCandidates[index]]),
                let last = validPoint(points[lastCandidates[index]])
            else {
                continue
            }

            return angle(first: first, middle: middle, last: last)
        }

        return nil
    }

    private func validPoint(_ point: VNRecognizedPoint?) -> CGPoint? {
        guard let point, point.confidence >= minimumPointConfidence else { return nil }
        return point.location
    }

    private func angle(first: CGPoint, middle: CGPoint, last: CGPoint) -> CGFloat {
        let firstVector = CGVector(dx: first.x - middle.x, dy: first.y - middle.y)
        let secondVector = CGVector(dx: last.x - middle.x, dy: last.y - middle.y)
        let dotProduct = firstVector.dx * secondVector.dx + firstVector.dy * secondVector.dy
        let firstLength = hypot(firstVector.dx, firstVector.dy)
        let secondLength = hypot(secondVector.dx, secondVector.dy)

        guard firstLength > 0, secondLength > 0 else { return 0 }

        let cosine = max(-1, min(1, dotProduct / (firstLength * secondLength)))
        return acos(cosine) * 180 / .pi
    }

    private func publishPersonLostIfNeeded() {
        if personWasDetected {
            personWasDetected = false
            print("BreakGateWorkout pose: person lost")
        }
    }

    private func publish(
        workoutState: WorkoutState,
        confidence: Float,
        isPersonDetected: Bool,
        posePoints: [PoseJointPoint],
        videoSize: CGSize
    ) {
        let update = PoseDetectionUpdate(
            repCount: repCount,
            workoutState: workoutState,
            confidence: confidence,
            isPersonDetected: isPersonDetected,
            posePoints: posePoints,
            videoSize: videoSize
        )

        Task { @MainActor in
            onUpdate?(update)
        }
    }
}

private enum ExercisePosition {
    case waiting
    case up
    case down
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession?

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.setSession(session)
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.setSession(session)
    }
}

final class PreviewView: NSView {
    private let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupPreviewLayer()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupPreviewLayer()
    }

    override func makeBackingLayer() -> CALayer {
        previewLayer
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }

    func setSession(_ session: AVCaptureSession?) {
        previewLayer.session = session
    }

    private func setupPreviewLayer() {
        wantsLayer = true
        previewLayer.videoGravity = .resizeAspect
        previewLayer.backgroundColor = NSColor.black.cgColor
        layer = previewLayer
    }
}
