//
//  ContentView.swift
//  BreakGateWorkout
//

@preconcurrency import AVFoundation
import AppKit
import Combine
import CoreGraphics
import Speech
import SwiftUI
import Vision

struct ContentView: View {
    @StateObject private var camera = CameraModel()
    @ObservedObject private var monitor: BreakGateMonitor
    @ObservedObject private var stats: WorkoutStats
    @ObservedObject private var settings: WorkoutSettingsStore

    init(monitor: BreakGateMonitor, stats: WorkoutStats, settings: WorkoutSettingsStore) {
        self.monitor = monitor
        self.stats = stats
        self.settings = settings
    }

    var body: some View {
        ZStack {
            AppBackground()
            GateScreenLayout(camera: camera, monitor: monitor, language: settings.appLanguage)
        }
        .frame(minWidth: 980, minHeight: 680)
        .preferredColorScheme(.dark)
        .task {
            DiagnosticLog.log("ContentView task started; configuring workout camera")
            camera.setAppLanguage(settings.appLanguage)
            camera.setStartPoseWaitDuration(settings.startPoseWaitDuration.timeInterval)
            camera.setExperimentalExercisesVisible(settings.showExperimentalExercises)
            camera.configureVoiceControl(isEnabled: settings.isVoiceControlEnabled)
            camera.onWorkoutCompleted = { plan, completedSteps in
                let reward = settings.rewardSetting(for: plan.difficulty)
                monitor.recordWorkoutCompletion(difficulty: plan.difficulty, rewardSetting: reward)
                stats.recordWorkoutCompletion(steps: completedSteps)
            }
            camera.startWorkoutPlan(settings.plan)
            await camera.start()
        }
        .onDisappear {
            DiagnosticLog.log("ContentView disappeared; stopping camera")
            camera.stop()
        }
        .onChange(of: settings.isVoiceControlEnabled) { _, isEnabled in
            Task { @MainActor in
                camera.configureVoiceControl(isEnabled: isEnabled)
            }
        }
        .onChange(of: settings.appLanguage) { _, language in
            Task { @MainActor in
                camera.setAppLanguage(language)
                camera.configureVoiceControl(isEnabled: settings.isVoiceControlEnabled)
            }
        }
        .onChange(of: settings.startPoseWaitDuration) { _, duration in
            Task { @MainActor in
                camera.setStartPoseWaitDuration(duration.timeInterval)
            }
        }
        .onChange(of: settings.showExperimentalExercises) { _, isVisible in
            Task { @MainActor in
                camera.setExperimentalExercisesVisible(isVisible)
            }
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
    let language: AppLanguage

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 8) {
                Text(language == .russian ? "Пора размяться" : "Time to move")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                Text(language == .russian ? "Выполни короткую тренировку, чтобы продолжить пользоваться Mac." : "Complete a short workout to continue using your Mac.")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                Text("BreakGateWorkout")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
    }
}

private struct GateScreenLayout: View {
    @ObservedObject var camera: CameraModel
    @ObservedObject var monitor: BreakGateMonitor
    let language: AppLanguage

    var body: some View {
        GeometryReader { geometry in
            mainArea
            .padding(.horizontal, 36)
            .padding(.top, gateTopInset(for: geometry.size.height))
            .padding(.bottom, 32)
        }
    }

    private var mainArea: some View {
        HStack(alignment: .top, spacing: 22) {
            leftColumn
                .frame(maxWidth: .infinity)

            CameraControlPanel(camera: camera)
                .frame(width: 340)
                .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 28) {
            HeaderView(language: language)

            CameraStageView(camera: camera, monitor: monitor)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func gateTopInset(for height: CGFloat) -> CGFloat {
        max(CGFloat(34), min(CGFloat(56), height * CGFloat(0.062) - CGFloat(30)))
    }
}

enum ExerciseMode: String, CaseIterable, Identifiable, Codable {
    case pushUps
    case squats
    case abs
    case plank
    case burpees
    case mountainClimbers
    case tuckPlancheHold
    case lSitHold
    case elbowLeverHold
    case pikePushUps

    var id: Self { self }

    var title: String {
        switch self {
        case .pushUps: "Push-ups"
        case .squats: "Squats"
        case .abs: "Abs"
        case .plank: "Plank"
        case .burpees: "Burpees"
        case .mountainClimbers: "Mountain Climbers"
        case .tuckPlancheHold: "Tuck Planche Hold"
        case .lSitHold: "L-sit Hold"
        case .elbowLeverHold: "Elbow Lever"
        case .pikePushUps: "Pike Push-ups"
        }
    }

    func title(_ language: AppLanguage) -> String {
        switch (self, language) {
        case (.pushUps, .english): "Push-ups"
        case (.pushUps, .russian): "Отжимания"
        case (.squats, .english): "Squats"
        case (.squats, .russian): "Приседания"
        case (.abs, .english): "Abs"
        case (.abs, .russian): "Пресс"
        case (.plank, .english): "Plank"
        case (.plank, .russian): "Планка"
        case (.burpees, .english): "Burpees"
        case (.burpees, .russian): "Бёрпи"
        case (.mountainClimbers, .english): "Mountain Climbers"
        case (.mountainClimbers, .russian): "Альпинист"
        case (.tuckPlancheHold, .english): "Tuck Planche Hold"
        case (.tuckPlancheHold, .russian): "Так планше"
        case (.lSitHold, .english): "L-sit Hold"
        case (.lSitHold, .russian): "Уголок"
        case (.elbowLeverHold, .english): "Elbow Lever"
        case (.elbowLeverHold, .russian): "Локтевой рычаг"
        case (.pikePushUps, .english): "Pike Push-ups"
        case (.pikePushUps, .russian): "Пайк-отжимания"
        }
    }

    var systemImage: String {
        switch self {
        case .pushUps: "figure.strengthtraining.traditional"
        case .squats: "figure.cross.training"
        case .abs: "figure.core.training"
        case .plank: "timer"
        case .burpees: "figure.highintensity.intervaltraining"
        case .mountainClimbers: "figure.climbing"
        case .tuckPlancheHold: "figure.gymnastics"
        case .lSitHold: "figure.core.training"
        case .elbowLeverHold: "figure.gymnastics"
        case .pikePushUps: "figure.gymnastics"
        }
    }

    var isExperimental: Bool {
        self == .mountainClimbers || self == .tuckPlancheHold || self == .lSitHold || self == .elbowLeverHold || self == .pikePushUps
    }

    var isTimed: Bool {
        self == .plank || self == .tuckPlancheHold || self == .lSitHold || self == .elbowLeverHold
    }
}

enum WorkoutDifficulty: String, CaseIterable, Identifiable, Codable {
    case light
    case medium
    case hard
    case extreme
    case extremePlus

    var id: Self { self }

    var title: String {
        switch self {
        case .light: "Light"
        case .medium: "Medium"
        case .hard: "Hard"
        case .extreme: "Extreme"
        case .extremePlus: "Extreme+"
        }
    }

    func title(_ language: AppLanguage) -> String {
        switch (self, language) {
        case (.light, .english): "Light"
        case (.light, .russian): "Легкая"
        case (.medium, .english): "Medium"
        case (.medium, .russian): "Средняя"
        case (.hard, .english): "Hard"
        case (.hard, .russian): "Сложная"
        case (.extreme, .english): "Extreme"
        case (.extreme, .russian): "Экстремальная"
        case (.extremePlus, .english): "Extreme+"
        case (.extremePlus, .russian): "Экстремальная+"
        }
    }

    var defaultStepCount: Int {
        switch self {
        case .light, .medium, .hard: 1
        case .extreme: 2
        case .extremePlus: 3
        }
    }
}

struct WorkoutStep: Identifiable, Codable, Equatable {
    var id: UUID
    var mode: ExerciseMode
    var targetReps: Int?
    var targetSeconds: Int?

    init(id: UUID = UUID(), mode: ExerciseMode, targetReps: Int? = nil, targetSeconds: Int? = nil) {
        self.id = id
        self.mode = mode
        self.targetReps = targetReps
        self.targetSeconds = targetSeconds
    }

    var targetAmount: Int {
        mode.isTimed ? (targetSeconds ?? 60) : (targetReps ?? 20)
    }

    var summary: String {
        mode.isTimed ? "\(mode.title) \(targetAmount)s" : "\(mode.title) x \(targetAmount)"
    }

    func summary(_ language: AppLanguage) -> String {
        mode.isTimed ? "\(mode.title(language)) \(targetAmount)с" : "\(mode.title(language)) x \(targetAmount)"
    }
}

struct WorkoutPlan: Codable, Equatable {
    var difficulty: WorkoutDifficulty
    var steps: [WorkoutStep]

    var summary: String {
        steps.map(\.summary).joined(separator: " -> ")
    }

    func summary(_ language: AppLanguage) -> String {
        steps.map { $0.summary(language) }.joined(separator: " -> ")
    }

    static func defaultPlan(for difficulty: WorkoutDifficulty) -> WorkoutPlan {
        switch difficulty {
        case .light:
            WorkoutPlan(difficulty: .light, steps: [WorkoutStep(mode: .pushUps, targetReps: 10)])
        case .medium:
            WorkoutPlan(difficulty: .medium, steps: [WorkoutStep(mode: .pushUps, targetReps: 15)])
        case .hard:
            WorkoutPlan(difficulty: .hard, steps: [WorkoutStep(mode: .pushUps, targetReps: 20)])
        case .extreme:
            WorkoutPlan(difficulty: .extreme, steps: [
                WorkoutStep(mode: .pushUps, targetReps: 20),
                WorkoutStep(mode: .squats, targetReps: 20)
            ])
        case .extremePlus:
            WorkoutPlan(difficulty: .extremePlus, steps: [
                WorkoutStep(mode: .pushUps, targetReps: 20),
                WorkoutStep(mode: .squats, targetReps: 20),
                WorkoutStep(mode: .abs, targetReps: 20)
            ])
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

enum CelebrationTone {
    case success
    case warning
    case failure

    var color: Color {
        switch self {
        case .success: .green
        case .warning: .yellow
        case .failure: .red
        }
    }
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
                        if camera.showCenteredPlankOverlay && camera.selectedMode == .plank {
                            PlankCountdownOverlay(camera: camera)
                        }
                    }
                    .overlay(alignment: .top) {
                        WorkoutProgressHUD(camera: camera)
                            .padding(.top, 16)
                    }
                    .overlay(alignment: .bottom) {
                        CoachingOverlay(camera: camera)
                            .padding(16)
                    }
                    .overlay(alignment: .bottomTrailing) {
                        PoseWaitCountdownOverlay(camera: camera)
                            .padding(16)
                    }
                    .overlay(alignment: .leading) {
                        CommandToastOverlay(camera: camera)
                            .padding(.leading, 16)
                    }
                    .overlay {
                        if camera.showWorkoutCompletedOverlay {
                            WorkoutCompletedOverlay(language: camera.appLanguage)
                                .transition(.opacity)
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if CameraModel.isEmergencyUnlockEnabled {
                            Button {
                                camera.emergencyCompleteWorkout()
                            } label: {
                                Label(camera.appLanguage == .russian ? "Экстренное завершение" : "Emergency Unlock", systemImage: "escape")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(Color.red.opacity(0.78), in: Capsule())
                                    .overlay {
                                        Capsule()
                                            .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                                    }
                            }
                            .buttonStyle(.plain)
                            .padding(16)
                            .help(camera.appLanguage == .russian ? "Экстренно завершить текущий гейт" : "Emergency complete current gate")
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(camera.appLanguage == .russian ? "Камера" : "Live Camera", systemImage: "video.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.92))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(.ultraThinMaterial, in: Capsule())

                            if monitor.gateActive {
                                Label(camera.appLanguage == .russian ? "BreakGate активирован" : "BreakGate activated", systemImage: "lock.open.fill")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.green)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(.ultraThinMaterial, in: Capsule())
                            }

                            Label(
                                camera.isVoiceControlEnabled
                                    ? "\(L.t(.voice, camera.appLanguage)): \(VoiceLanguageInfo.expectedLanguageName(for: camera.appLanguage))"
                                    : "\(L.t(.voice, camera.appLanguage)): \(L.t(.off, camera.appLanguage))",
                                systemImage: camera.isVoiceControlEnabled ? "mic.fill" : "mic.slash"
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(camera.isVoiceControlEnabled ? .blue : .white.opacity(0.72))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())

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

private struct WorkoutCompletedOverlay: View {
    let language: AppLanguage

    var body: some View {
        ZStack {
            Color.black.opacity(0.58)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 76, weight: .bold))
                    .foregroundStyle(.green)

                Text(language == .russian ? "Тренировка завершена" : "Workout completed")
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(language == .russian ? "BreakGate разблокирован" : "BreakGate unlocked")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
            }
            .padding(.horizontal, 44)
            .padding(.vertical, 34)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.35), radius: 34, y: 18)
        }
        .allowsHitTesting(true)
    }
}

private struct WorkoutProgressHUD: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack(spacing: 4) {
            if camera.selectedMode.isTimed {
                Text(camera.formattedPlankTime)
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(camera.timedHoldStatusText)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .foregroundStyle(camera.currentWorkoutState == .plankBroken ? .red : .green)
            } else {
                Text("\(camera.repCount) / \(camera.currentTargetAmount)")
                    .font(.system(size: 64, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(camera.appLanguage == .russian ? "Осталось: \(camera.remainingTargetAmount)" : "\(camera.remainingTargetAmount) left")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(camera.remainingTargetAmount == 0 ? .green : .white.opacity(0.72))
            }

            Text(camera.currentStepLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder((camera.currentWorkoutState == .plankBroken ? Color.red : Color.green).opacity(0.32), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 24, y: 10)
        .allowsHitTesting(false)
    }
}

private struct CoachingOverlay: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack(spacing: 10) {
            if let overlayMessage = camera.primaryOverlayMessage {
                Text(overlayMessage)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 16)
                    .background(camera.primaryOverlayTone.color.opacity(0.84), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
                    .transition(.scale.combined(with: .opacity))
            } else if let celebrationMessage = camera.celebrationMessage {
                Text(celebrationMessage)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 16)
                    .background(camera.celebrationTone.color.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
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

            if let voiceStatus = camera.voiceStatusMessage {
                Label(voiceStatus, systemImage: "waveform")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.86))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: camera.celebrationMessage)
        .animation(.spring(response: 0.26, dampingFraction: 0.82), value: camera.primaryOverlayMessage)
        .animation(.easeInOut(duration: 0.18), value: camera.coachingMessage)
        .allowsHitTesting(false)
    }
}

private struct CommandToastOverlay: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let commandToastMessage = camera.commandToastMessage {
                Label(commandToastMessage, systemImage: "checkmark.circle.fill")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(camera.commandToastTone.color.opacity(0.84), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.26), radius: 16, y: 8)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .frame(maxHeight: .infinity)
        .animation(.spring(response: 0.28, dampingFraction: 0.84), value: camera.commandToastMessage)
        .allowsHitTesting(false)
    }
}

private struct PoseWaitCountdownOverlay: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        if let text = camera.poseWaitCountdownText {
            Label(text, systemImage: "hourglass")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white.opacity(0.94))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.48), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(Color.yellow.opacity(0.36), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.20), radius: 10, y: 4)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .allowsHitTesting(false)
        }
    }
}

private struct PoseDebugOverlay: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(camera.appLanguage == .russian ? "Скелет" : "Skeleton Overlay", isOn: Binding(
                get: { camera.showSkeletonOverlay },
                set: { camera.setSkeletonOverlayVisible($0) }
            ))
            .toggleStyle(.switch)
            .font(.caption.weight(.medium))

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(camera.repCount)")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(L.t(.reps, camera.appLanguage))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text("\(camera.appLanguage == .russian ? "Режим" : "Mode"): \(camera.selectedMode.title(camera.appLanguage))")
            Text("\(camera.appLanguage == .russian ? "Состояние" : "State"): \(camera.currentPoseState)")
                .lineLimit(1)
            if let lastVoiceTranscript = camera.lastVoiceTranscript {
                Text("\(camera.appLanguage == .russian ? "Слышно" : "Heard"): \(lastVoiceTranscript)")
                    .lineLimit(2)
                    .foregroundStyle(.secondary)
            }
            Text("\(camera.appLanguage == .russian ? "Человек" : "Person"): \(camera.isPersonDetected ? (camera.appLanguage == .russian ? "ДА" : "YES") : (camera.appLanguage == .russian ? "НЕТ" : "NO"))")
            Text("\(camera.appLanguage == .russian ? "Уверенность" : "Confidence"): \(camera.confidence, specifier: "%.2f")")
            if camera.selectedMode.isTimed {
                    Text("\(camera.selectedMode.title(camera.appLanguage)): \(camera.formattedPlankTime)")
            }
            if !camera.isPersonDetected {
                Text(camera.appLanguage == .russian ? "Поза не найдена" : "No pose detected")
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

            Text(camera.isSwitchingCamera ? (camera.appLanguage == .russian ? "Переключаю камеру" : "Switching Camera") : camera.previewPlaceholder)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(camera.appLanguage == .russian ? "Камера" : "Camera")
                        .font(.title3.weight(.semibold))

                    HStack(spacing: 8) {
                        CameraModePill(
                            title: camera.appLanguage == .russian ? "Mac" : "Mac",
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
                        .help(camera.appLanguage == .russian ? "Обновить камеры" : "Refresh cameras")
                    }
                }

                ZoomControlPanel(camera: camera)

                VStack(alignment: .leading, spacing: 10) {
                    Text(camera.appLanguage == .russian ? "Тренировка" : "Workout")
                        .font(.headline.weight(.semibold))

                    VStack(alignment: .leading, spacing: 5) {
                        Text("\(L.t(.difficulty, camera.appLanguage)): \(camera.currentDifficultyTitle)")
                        Text(camera.currentStepLabel)
                        Text(camera.currentProgressSummary)
                        Text(camera.currentRemainingSummary)
                            .foregroundStyle(.secondary)
                        if let nextStepPreview = camera.nextStepPreview {
                            Text("\(camera.appLanguage == .russian ? "Дальше" : "Next"): \(nextStepPreview)")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption.weight(.medium))
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    Picker(L.t(.difficulty, camera.appLanguage), selection: Binding(
                        get: { camera.activeWorkoutPlan.difficulty },
                        set: { camera.selectDifficulty($0) }
                    )) {
                        ForEach(WorkoutDifficulty.allCases) { difficulty in
                            Text(difficulty.title(camera.appLanguage)).tag(difficulty)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(!camera.canChangeDifficulty)

                    if !camera.canChangeDifficulty {
                        Text(camera.appLanguage == .russian ? "Сложность блокируется после первого прогресса." : "Difficulty locks after first progress.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        exerciseGrid(modes: regularExerciseModes)

                        if !experimentalExerciseModes.isEmpty {
                            Text(camera.appLanguage == .russian ? "Экспериментальные упражнения" : "Experimental")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)

                            exerciseGrid(modes: experimentalExerciseModes)
                        }
                    }
                }

                StatusStack(camera: camera)

                Divider()
                    .overlay(Color.white.opacity(0.10))

                Toggle(camera.appLanguage == .russian ? "Debug-панель" : "Debug Panel", isOn: Binding(
                    get: { camera.showDebugPanel },
                    set: { camera.setDebugPanelVisible($0) }
                ))
                .toggleStyle(.switch)
                .font(.footnote.weight(.medium))

                VStack(alignment: .leading, spacing: 10) {
                    Text(camera.appLanguage == .russian ? "Устройства" : "Devices")
                        .font(.headline.weight(.semibold))

                    if camera.devices.isEmpty {
                        EmptyDeviceCard(language: camera.appLanguage)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(camera.devices) { device in
                                DeviceCard(
                                    device: device,
                                    isSelected: camera.selectedDeviceID == device.id,
                                    language: camera.appLanguage
                                ) {
                                    camera.selectCamera(id: device.id)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .padding(18)
        }
        .scrollIndicators(.hidden)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var regularExerciseModes: [ExerciseMode] {
        camera.availableExerciseModes.filter { !$0.isExperimental }
    }

    private var experimentalExerciseModes: [ExerciseMode] {
        camera.availableExerciseModes.filter { $0.isExperimental }
    }

    @ViewBuilder
    private func exerciseGrid(modes: [ExerciseMode]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], spacing: 8) {
            ForEach(modes) { mode in
                ExerciseModeButton(
                    mode: mode,
                    isSelected: camera.selectedMode == mode,
                    language: camera.appLanguage
                ) {
                    camera.selectExerciseMode(mode)
                }
            }
        }
    }
}

private struct ZoomControlPanel: View {
    @ObservedObject var camera: CameraModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(camera.appLanguage == .russian ? "Линза / Зум" : "Lens / Zoom")
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

            Text("\(camera.appLanguage == .russian ? "Активно" : "Active"): \(camera.selectedInputSourceName)")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if camera.selectedDeviceIsIPhone && !camera.supportsUltraWideZoom {
                Text(camera.appLanguage == .russian ? "0.5x не доступен через это Continuity Camera устройство." : "0.5x is not exposed by this Continuity Camera device.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if camera.inputSources.isEmpty {
                Text(camera.appLanguage == .russian ? "macOS не отдает управление зумом для этой камеры." : "macOS does not expose digital zoom for this camera.")
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
    let language: AppLanguage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(mode.title(language))
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
                StatusRow(title: camera.appLanguage == .russian ? "Камера недоступна" : "Camera unavailable", systemImage: "xmark.circle.fill", color: .red)
            } else if camera.isSwitchingCamera {
                StatusRow(title: camera.appLanguage == .russian ? "Подключение камеры…" : "Connecting camera…", systemImage: "arrow.triangle.2.circlepath", color: .yellow)
            } else if camera.session != nil {
                StatusRow(title: camera.appLanguage == .russian ? "Камера готова" : "Camera ready", systemImage: "checkmark.circle.fill", color: .green)
            } else {
                StatusRow(title: camera.appLanguage == .russian ? "Подключение камеры…" : "Connecting camera…", systemImage: "circle.dotted", color: .secondary)
            }

            StatusRow(
                title: camera.selectedCameraStatusTitle,
                systemImage: camera.selectedDeviceIsIPhone ? "iphone.circle.fill" : "web.camera.fill",
                color: camera.selectedDeviceIsIPhone ? .blue : .secondary
            )

            StatusRow(
                title: camera.continuityAvailabilityTitle,
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
    let language: AppLanguage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: device.isContinuityCamera ? "iphone" : "web.camera.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(isSelected ? .white : .secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.localizedName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(device.displayType(language))
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
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(isSelected ? Color.white.opacity(0.14) : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Color.green.opacity(0.38) : Color.white.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct EmptyDeviceCard: View {
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "video.slash")
                .foregroundStyle(.red)
            Text(language == .russian ? "Камеры не найдены" : "No cameras found")
                .font(.callout.weight(.semibold))
            Text(language == .russian ? "Подключи камеру или разреши доступ к камере." : "Connect a camera or enable camera permission.")
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

    func displayType(_ language: AppLanguage) -> String {
        if isContinuityCamera {
            return "Continuity Camera"
        }

        if deviceType.contains("BuiltInWideAngleCamera") {
            return language == .russian ? "Встроенная камера Mac" : "Built-in Mac camera"
        }

        if deviceType.contains("External") {
            return language == .russian ? "Внешняя камера" : "External camera"
        }

        return deviceType
            .replacingOccurrences(of: "AVCaptureDeviceType", with: "")
            .replacingOccurrences(of: "Camera", with: " Camera")
    }
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

enum SoundEffectKind: String, CaseIterable, Identifiable, Codable {
    case repCount
    case plankFail
    case plankCountdown
    case exerciseFinish
    case gateStart

    var id: String { rawValue }

    func title(_ language: AppLanguage) -> String {
        switch (self, language) {
        case (.repCount, .english): "Rep count"
        case (.repCount, .russian): "Засчитанный повтор"
        case (.plankFail, .english): "Plank fail"
        case (.plankFail, .russian): "Срыв планки"
        case (.plankCountdown, .english): "Plank countdown"
        case (.plankCountdown, .russian): "Финальный отсчет планки"
        case (.exerciseFinish, .english): "Exercise finish"
        case (.exerciseFinish, .russian): "Завершение тренировки"
        case (.gateStart, .english): "Gate start"
        case (.gateStart, .russian): "Запуск гейта"
        }
    }
}

@MainActor
final class SoundFeedbackService {
    static let shared = SoundFeedbackService()

    enum GateMusicState {
        case stopped
        case starting
        case looping
        case stopping
    }

    private let assetNames = [
        "rep_count",
        "plank_fail",
        "plank_countdown",
        "exercise_finish",
        "gate_start",
        "main_menu"
    ]
    private var audioData: [String: Data] = [:]
    private var effectPlayers: [AVAudioPlayer] = []
    private var gateStartPlayer: AVAudioPlayer?
    private var mainMenuPlayer: AVAudioPlayer?
    private var gateMusicTask: Task<Void, Never>?
    private var fadeTask: Task<Void, Never>?
    private var gatePlaybackGeneration = 0
    private var gateMusicState: GateMusicState = .stopped
    private var isMainMenuMusicEnabled = true
    private var isSFXEnabled = true
    private var disabledEffects: Set<SoundEffectKind> = []

    func applySettings(mainMenuMusicEnabled: Bool, sfxEnabled: Bool, disabledEffects: Set<SoundEffectKind>) {
        isMainMenuMusicEnabled = mainMenuMusicEnabled
        isSFXEnabled = sfxEnabled
        self.disabledEffects = disabledEffects

        if !mainMenuMusicEnabled {
            stopGateMusic()
        }
    }

    func preload() {
        for name in assetNames where audioData[name] == nil {
            guard let asset = NSDataAsset(name: name) else {
                print("BreakGateWorkout audio: asset not found for \(name)")
                continue
            }
            audioData[name] = asset.data
            print("BreakGateWorkout audio: preloaded asset \(name)")
        }
    }

    func playRepAccepted() {
        playOneShot(named: "rep_count", effect: .repCount, volume: 0.50)
    }

    func playPlankFail() {
        playOneShot(named: "plank_fail", effect: .plankFail, volume: 0.55)
    }

    func playPlankMilestone() {
        playOneShot(named: "rep_count", effect: .repCount, volume: 0.50)
    }

    func playFinalCountdownTick() {
        playOneShot(named: "plank_countdown", effect: .plankCountdown, volume: 0.55)
    }

    func playExerciseFinish() {
        playOneShot(named: "exercise_finish", effect: .exerciseFinish, volume: 0.65)
    }

    func startGateMusic() {
        preload()
        guard isMainMenuMusicEnabled else {
            playOneShot(named: "gate_start", effect: .gateStart, volume: 0.70)
            return
        }

        guard gateMusicState == .stopped else {
            print("BreakGateWorkout audio: start ignored, state=\(gateMusicState)")
            return
        }

        gateMusicState = .starting
        gatePlaybackGeneration += 1
        let generation = gatePlaybackGeneration

        gateMusicTask?.cancel()
        fadeTask?.cancel()
        mainMenuPlayer?.stop()
        mainMenuPlayer = nil

        if canPlayEffect(.gateStart) {
            gateStartPlayer = makePlayer(named: "gate_start")
            gateStartPlayer?.volume = 0.70
            gateStartPlayer?.numberOfLoops = 0
            gateStartPlayer?.play()
        } else {
            gateStartPlayer = nil
        }

        let delay = gateStartPlayer?.duration ?? 0
        gateMusicTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self, self.gatePlaybackGeneration == generation else { return }
                self.startMainMenuLoop()
            }
        }
    }

    func stopGateMusic() {
        guard gateMusicState != .stopped, gateMusicState != .stopping else {
            print("BreakGateWorkout audio: stop ignored, already \(gateMusicState)")
            return
        }

        gateMusicState = .stopping
        gatePlaybackGeneration += 1
        gateMusicTask?.cancel()
        gateMusicTask = nil

        gateStartPlayer?.stop()
        gateStartPlayer = nil

        fadeOutMainMenu()
    }

    private func startMainMenuLoop() {
        guard gateMusicState == .starting else { return }
        guard mainMenuPlayer == nil else { return }
        guard let player = makePlayer(named: "main_menu") else {
            print("BreakGateWorkout audio: main_menu asset not found")
            gateMusicState = .stopped
            return
        }

        player.numberOfLoops = -1
        player.volume = 0
        player.play()
        mainMenuPlayer = player
        gateMusicState = .looping
        print("BreakGateWorkout audio: main_menu loop started")
        fade(player: player, to: 0.35, duration: 1.5, stopWhenDone: false)
    }

    private func fadeOutMainMenu() {
        guard let player = mainMenuPlayer else {
            gateMusicState = .stopped
            return
        }
        fade(player: player, to: 0, duration: 1.2, stopWhenDone: true)
    }

    private func playOneShot(named name: String, effect: SoundEffectKind, volume: Float) {
        guard canPlayEffect(effect) else { return }
        preload()
        guard let player = makePlayer(named: name) else {
            NSSound.beep()
            return
        }

        player.volume = volume
        player.numberOfLoops = 0
        player.currentTime = 0
        player.play()
        effectPlayers.append(player)
        cleanupFinishedEffects()
    }

    private func canPlayEffect(_ effect: SoundEffectKind) -> Bool {
        isSFXEnabled && !disabledEffects.contains(effect)
    }

    private func makePlayer(named name: String) -> AVAudioPlayer? {
        guard let data = audioData[name] else { return nil }

        do {
            let player = try AVAudioPlayer(data: data)
            player.prepareToPlay()
            return player
        } catch {
            print("BreakGateWorkout audio: failed to decode asset \(name): \(error.localizedDescription)")
            return nil
        }
    }

    private func fade(player: AVAudioPlayer, to targetVolume: Float, duration: TimeInterval, stopWhenDone: Bool) {
        fadeTask?.cancel()

        let startVolume = player.volume
        let steps = 24
        let stepDuration = duration / Double(steps)

        fadeTask = Task { [weak self, weak player] in
            for step in 1...steps {
                try? await Task.sleep(nanoseconds: UInt64(stepDuration * 1_000_000_000))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard let player else { return }
                    let progress = Float(step) / Float(steps)
                    player.volume = startVolume + (targetVolume - startVolume) * progress
                }
            }

            await MainActor.run {
                guard let self, let player else { return }
                player.volume = targetVolume
                if stopWhenDone {
                    player.stop()
                    if self.mainMenuPlayer === player {
                        self.mainMenuPlayer = nil
                    }
                    self.gateMusicState = .stopped
                }
                self.fadeTask = nil
            }
        }
    }

    private func cleanupFinishedEffects() {
        effectPlayers.removeAll { !$0.isPlaying }
    }
}

@MainActor
final class CameraModel: ObservableObject {
    static let isEmergencyUnlockEnabled = true
    private enum PreferredCameraKind: String {
        case mac
        case continuity
    }

    private enum CameraDefaultsKey {
        static let preferredKind = "BreakGateWorkout.camera.preferredKind"
        static let selectedDeviceID = "BreakGateWorkout.camera.selectedDeviceID"
    }

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
    @Published var showDebugPanel = UserDefaults.standard.object(forKey: "BreakGateWorkout.showDebugPanel") as? Bool ?? false
    @Published private(set) var posePoints: [PoseJointPoint] = []
    @Published private(set) var zoomFactor: CGFloat = 1
    @Published private(set) var inputSources: [CameraInputSourceInfo] = []
    @Published private(set) var selectedInputSourceID: String?
    @Published private(set) var selectedInputSourceName = "Default"
    @Published private(set) var previewVideoSize = CGSize(width: 16, height: 9)
    @Published private(set) var hasReceivedCameraFrame = false
    @Published private(set) var plankTimeRemaining: Double = 0
    @Published private(set) var plankIsActive = false
    @Published private(set) var coachingMessage: String?
    @Published private(set) var celebrationMessage: String?
    @Published private(set) var celebrationTone: CelebrationTone = .success
    @Published private(set) var commandToastMessage: String?
    @Published private(set) var commandToastTone: CelebrationTone = .success
    @Published private(set) var primaryOverlayMessage: String?
    @Published private(set) var primaryOverlayTone: CelebrationTone = .warning
    @Published private(set) var poseWaitCountdownText: String?
    @Published private(set) var voiceStatusMessage: String?
    @Published private(set) var lastVoiceTranscript: String?
    @Published private(set) var isVoiceControlEnabled = false
    @Published private(set) var appLanguage: AppLanguage = .english
    @Published private(set) var showWorkoutCompletedOverlay = false
    @Published var plankDuration: Double = 60
    @Published private(set) var activeWorkoutPlan = WorkoutPlan.defaultPlan(for: .light)
    @Published private(set) var currentStepIndex = 0
    @Published private(set) var completedSteps: [WorkoutStep] = []
    @Published private(set) var showExperimentalExercises = false
    let showCenteredPlankOverlay = false
    var onWorkoutCompleted: ((WorkoutPlan, [WorkoutStep]) -> Void)?

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

    var selectedCameraStatusTitle: String {
        if statusIsError || session == nil {
            return appLanguage == .russian ? "Камера недоступна" : "Camera unavailable"
        }

        return selectedDeviceIsIPhone
            ? (appLanguage == .russian ? "Continuity Camera" : "Continuity Camera")
            : (appLanguage == .russian ? "Камера Mac" : "Mac camera")
    }

    var continuityAvailabilityTitle: String {
        hasIPhoneCamera
            ? (appLanguage == .russian ? "iPhone найден как Continuity Camera" : "iPhone found as Continuity Camera")
            : (appLanguage == .russian ? "Continuity Camera недоступна" : "Continuity Camera unavailable")
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
            appLanguage == .russian ? "Планка сорвана" : "Plank broken"
        case .plankActive:
            appLanguage == .russian ? "Хорошая форма" : "Good form"
        default:
            appLanguage == .russian ? "Держи позицию" : "Hold position"
        }
    }

    var timedHoldStatusText: String {
        if selectedMode == .plank {
            return currentWorkoutState == .plankBroken
                ? (appLanguage == .russian ? "Планка сорвана - начни заново" : "Plank broken - restart")
                : (appLanguage == .russian ? "Держи планку" : "Hold plank")
        }

        if selectedMode == .tuckPlancheHold {
            return plankIsActive
                ? (appLanguage == .russian ? "Держи так планше" : "Hold tuck planche")
                : (appLanguage == .russian ? "Зафиксируй 2 секунды" : "Stabilize for 2 seconds")
        }
        if selectedMode == .lSitHold {
            return plankIsActive
                ? (appLanguage == .russian ? "Держи уголок" : "Hold the L-sit")
                : (appLanguage == .russian ? "Сядь в уголок" : "Get into L-sit")
        }
        if selectedMode == .elbowLeverHold {
            return plankIsActive
                ? (appLanguage == .russian ? "Держи рычаг" : "Hold the lever")
                : (appLanguage == .russian ? "Встань в локтевой рычаг" : "Get into elbow lever")
        }

        return currentTargetLabel
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

    var currentStep: WorkoutStep {
        activeWorkoutPlan.steps.indices.contains(currentStepIndex)
            ? activeWorkoutPlan.steps[currentStepIndex]
            : activeWorkoutPlan.steps[0]
    }

    var currentDifficultyTitle: String {
        activeWorkoutPlan.difficulty.title(appLanguage)
    }

    var currentStepLabel: String {
        appLanguage == .russian
            ? "Шаг \(currentStepIndex + 1) из \(activeWorkoutPlan.steps.count)"
            : "Step \(currentStepIndex + 1) of \(activeWorkoutPlan.steps.count)"
    }

    var currentTargetLabel: String {
        if currentStep.mode.isTimed {
            return appLanguage == .russian
                ? "\(currentStep.mode.title(appLanguage)): \(currentStep.targetAmount) секунд"
                : "Hold \(currentStep.mode.title(appLanguage).lowercased()) for \(currentStep.targetAmount) seconds"
        }

        return appLanguage == .russian
            ? "\(currentStep.mode.title(appLanguage)): \(currentStep.targetAmount) повторов"
            : "\(currentStep.targetAmount) \(currentStep.mode.title(appLanguage).lowercased()) to continue"
    }

    var currentTargetAmount: Int {
        selectedMode.isTimed ? Int(plankDuration.rounded()) : targetRepCount
    }

    var remainingTargetAmount: Int {
        if selectedMode.isTimed {
            return max(0, Int(plankTimeRemaining.rounded(.up)))
        }

        return max(0, currentTargetAmount - repCount)
    }

    var currentProgressSummary: String {
        if selectedMode.isTimed {
            let prefix = appLanguage == .russian ? "Сейчас" : "Current"
            return "\(prefix): \(selectedMode.title(appLanguage)) \(max(0, currentTargetAmount - remainingTargetAmount)) / \(currentTargetAmount)s"
        }

        return "\(appLanguage == .russian ? "Сейчас" : "Current"): \(selectedMode.title(appLanguage)) \(repCount) / \(currentTargetAmount)"
    }

    var currentRemainingSummary: String {
        if appLanguage == .russian {
            return selectedMode.isTimed
                ? "Осталось: \(remainingTargetAmount)с"
                : "Осталось: \(remainingTargetAmount)"
        }

        return selectedMode.isTimed
            ? "\(remainingTargetAmount)s \(L.t(.left, appLanguage))"
            : "\(remainingTargetAmount) \(L.t(.left, appLanguage))"
    }

    var nextStepPreview: String? {
        let nextIndex = currentStepIndex + 1
        guard activeWorkoutPlan.steps.indices.contains(nextIndex) else { return nil }
        return activeWorkoutPlan.steps[nextIndex].summary(appLanguage)
    }

    var canChangeDifficulty: Bool {
        guard currentStepIndex == 0, completedSteps.isEmpty, repCount == 0 else { return false }
        guard selectedMode.isTimed else { return true }
        return plankDuration - plankTimeRemaining < 0.5
    }

    var availableExerciseModes: [ExerciseMode] {
        ExerciseMode.allCases.filter { showExperimentalExercises || !$0.isExperimental }
    }

    private let sessionController = CameraSessionController()
    private let poseDetectionService = PoseDetectionService()
    private let soundFeedback = SoundFeedbackService.shared
    private let voiceCommandService = VoiceCommandService()
    private let userDefaults = UserDefaults.standard
    private var targetRepCount = 20
    private var captureDevices: [AVCaptureDevice] = []
    private var lastPlankTick: Date?
    private var plankBrokenUntil: Date?
    private var workoutCompletionRecorded = false
    private var lastSoundedRepCount = 0
    private var lastFinalPlankSecondSound: Int?
    private var plankWasStable = false
    private var lastTimedHoldDiagnosticState: String?
    private var lastCelebratedRepCount = 0
    private var lastCelebratedPlankBucket = 0
    private var celebrationClearTask: Task<Void, Never>?
    private var commandToastClearTask: Task<Void, Never>?
    private var exerciseStartDelay: TimeInterval = 15
    private let startingPoseHoldDuration: TimeInterval = 0.6
    private var exerciseStartReadyAt = Date.distantFuture
    private var startingPoseStableSince: Date?
    private var exerciseCountingEnabled = false
    private var voiceStartRequested = false
    private var automaticStartWindowExpired = false
    private var recognitionDebugSessionActive = false
    var onRecognitionDebugPoseUpdate: ((CameraModel, PoseDetectionUpdate) -> Void)?
    var onRecognitionDebugStepCompleted: (() -> Void)?
    var onRecognitionDebugVideoSampleBuffer: ((CMSampleBuffer) -> Void)?

    private var startingPoseConfidenceThreshold: Float {
        selectedMode == .plank ? 0.22 : 0.34
    }

    private var preferredCameraKind: PreferredCameraKind {
        get {
            guard let rawValue = userDefaults.string(forKey: CameraDefaultsKey.preferredKind),
                  let kind = PreferredCameraKind(rawValue: rawValue) else {
                return .mac
            }
            return kind
        }
        set {
            userDefaults.set(newValue.rawValue, forKey: CameraDefaultsKey.preferredKind)
        }
    }

    private var persistedSelectedDeviceID: String? {
        get { userDefaults.string(forKey: CameraDefaultsKey.selectedDeviceID) }
        set {
            if let newValue {
                userDefaults.set(newValue, forKey: CameraDefaultsKey.selectedDeviceID)
            } else {
                userDefaults.removeObject(forKey: CameraDefaultsKey.selectedDeviceID)
            }
        }
    }

    init() {
        poseDetectionService.onUpdate = { [weak self] update in
            self?.applyPoseUpdate(update)
        }
        poseDetectionService.onSampleBuffer = { [weak self] sampleBuffer in
            self?.onRecognitionDebugVideoSampleBuffer?(sampleBuffer)
        }
        voiceCommandService.onStatus = { [weak self] status in
            self?.voiceStatusMessage = status
        }
        voiceCommandService.onUnrecognized = { [weak self] in
            self?.clearCommandToast()
        }
        voiceCommandService.onTranscript = { [weak self] transcript in
            self?.lastVoiceTranscript = transcript
        }
        voiceCommandService.onCommand = { [weak self] command, transcript in
            self?.handleVoiceCommand(command, transcript: transcript)
        }
        poseDetectionService.setMode(selectedMode)
        resetWorkoutState()
    }

    func start() async {
        DiagnosticLog.log("CameraModel.start requested")
        refreshDevices()

        let granted = await requestCameraAccess()
        guard granted else {
            DiagnosticLog.log("CameraModel.start stopped: camera permission denied")
            clearPreview(message: appLanguage == .russian ? "Нет доступа к камере. Разреши доступ в System Settings." : "Camera permission denied. Enable camera access in System Settings.", isError: true)
            return
        }

        let device = restoredPreferredDevice()

        guard let device else {
            DiagnosticLog.log("CameraModel.start stopped: no camera available")
            clearPreview(message: appLanguage == .russian ? "Камера недоступна." : "No camera available.", isError: true)
            return
        }

        DiagnosticLog.log("CameraModel.start configuring device=\(device.localizedName)")
        configureCamera(device)
    }

    func stop() {
        DiagnosticLog.log("CameraModel.stop requested")
        recognitionDebugSessionActive = false
        onRecognitionDebugPoseUpdate = nil
        onRecognitionDebugStepCompleted = nil
        onRecognitionDebugVideoSampleBuffer = nil
        sessionController.stop()
        poseDetectionService.reset()
        voiceCommandService.stop()
        session = nil
        isSwitchingCamera = false
        hasReceivedCameraFrame = false
        resetPoseState()
    }

    func setAppLanguage(_ language: AppLanguage) {
        appLanguage = language
    }

    func setStartPoseWaitDuration(_ duration: TimeInterval) {
        exerciseStartDelay = duration
        if !exerciseCountingEnabled {
            exerciseStartReadyAt = Date().addingTimeInterval(duration)
            automaticStartWindowExpired = false
            primaryOverlayMessage = startPromptText()
            primaryOverlayTone = .warning
        }
    }

    func setExperimentalExercisesVisible(_ isVisible: Bool) {
        showExperimentalExercises = isVisible
    }

    func configureVoiceControl(isEnabled: Bool) {
        isVoiceControlEnabled = isEnabled
        if isEnabled {
            voiceCommandService.start(language: appLanguage)
        } else {
            voiceCommandService.stop()
            voiceStatusMessage = appLanguage == .russian ? "Голос: выкл" : "Voice: off"
        }
    }

    func selectMacCamera() {
        refreshDevices()
        preferredCameraKind = .mac
        guard let device = preferredMacCamera() else {
            clearPreview(message: appLanguage == .russian ? "Mac камера недоступна." : "No Mac camera is available.", isError: true)
            return
        }
        configureCamera(device)
    }

    func selectIPhoneCamera() {
        refreshDevices()
        preferredCameraKind = .continuity
        guard let device = preferredIPhoneCamera() else {
            guard let fallback = fallbackForMissingPreferredCamera(kind: .continuity) else {
                clearPreview(message: appLanguage == .russian ? "iPhone Continuity Camera недоступна." : "iPhone Continuity Camera is not available.", isError: true)
                return
            }

            statusMessage = appLanguage == .russian
                ? "iPhone Continuity Camera недоступна. Переключаюсь на доступную Mac камеру."
                : "iPhone Continuity Camera is not available. Switching to the available Mac camera."
            statusIsError = false
            configureCamera(fallback, allowFallback: false)
            return
        }
        configureCamera(device)
    }

    func selectCamera(id: String) {
        refreshDevices()
        guard let device = captureDevices.first(where: { $0.uniqueID == id }) else {
            guard let fallback = fallbackForMissingPreferredCamera(kind: preferredCameraKind) else {
                clearPreview(message: appLanguage == .russian ? "Выбранная камера больше недоступна." : "Selected camera is no longer available.", isError: true)
                return
            }

            statusMessage = appLanguage == .russian
                ? "Выбранная камера недоступна. Переключаюсь на доступную Mac камеру."
                : "Selected camera is unavailable. Switching to the available Mac camera."
            statusIsError = false
            configureCamera(fallback, allowFallback: false)
            return
        }
        preferredCameraKind = isIPhoneCamera(device) ? .continuity : .mac
        configureCamera(device)
    }

    func refreshCameraDevices() {
        refreshDevices()
        statusMessage = hasIPhoneCamera
            ? (appLanguage == .russian ? "Список камер обновлен. iPhone Continuity Camera найдена." : "Camera list refreshed. iPhone Continuity Camera detected.")
            : (appLanguage == .russian ? "Список камер обновлен. iPhone Continuity Camera не найдена." : "Camera list refreshed. iPhone Continuity Camera not found.")
        statusIsError = false
    }

    func startWorkoutPlan(_ plan: WorkoutPlan) {
        activeWorkoutPlan = WorkoutSettingsStore.normalized(plan)
        currentStepIndex = 0
        completedSteps = []
        applyCurrentStep(resetPoseService: true)
    }

    func emergencyCompleteWorkout() {
        guard !workoutCompletionRecorded else { return }

        workoutCompletionRecorded = true
        statusMessage = appLanguage == .russian ? "Экстренное завершение использовано. BreakGate разблокирован." : "Emergency unlock used. BreakGate unlocked."
        soundFeedback.playExerciseFinish()
        onWorkoutCompleted?(activeWorkoutPlan, activeWorkoutPlan.steps)
    }

    func selectExerciseMode(_ mode: ExerciseMode) {
        guard activeWorkoutPlan.steps.indices.contains(currentStepIndex) else { return }
        guard showExperimentalExercises || !mode.isExperimental else {
            statusMessage = appLanguage == .russian
                ? "Экспериментальные упражнения выключены в настройках."
                : "Experimental exercises are disabled in Settings."
            return
        }
        activeWorkoutPlan.steps[currentStepIndex] = defaultStep(mode: mode, difficulty: activeWorkoutPlan.difficulty)
        applyCurrentStep(resetPoseService: true)
    }

    func selectDifficulty(_ difficulty: WorkoutDifficulty) {
        guard canChangeDifficulty else { return }

        let currentMode = selectedMode
        var newPlan = WorkoutPlan.defaultPlan(for: difficulty)
        if !newPlan.steps.isEmpty {
            newPlan.steps[0] = defaultStep(mode: currentMode, difficulty: difficulty)
        }

        activeWorkoutPlan = WorkoutSettingsStore.normalized(newPlan)
        currentStepIndex = 0
        completedSteps = []
        applyCurrentStep(resetPoseService: true)
    }

    func startRecognitionDebugStep(_ step: WorkoutStep) {
        recognitionDebugSessionActive = true
        activeWorkoutPlan = WorkoutSettingsStore.normalized(WorkoutPlan(difficulty: .light, steps: [step]))
        currentStepIndex = 0
        completedSteps = []
        applyCurrentStep(resetPoseService: true)
        exerciseCountingEnabled = true
        voiceStartRequested = false
        automaticStartWindowExpired = true
        primaryOverlayMessage = nil
        poseWaitCountdownText = nil
        poseDetectionService.setCountingEnabled(true)
        DiagnosticLog.log("recognition debug step started mode=\(selectedMode.rawValue) target=\(currentTargetAmount)")
    }

    func stopRecognitionDebugSession() {
        recognitionDebugSessionActive = false
        poseDetectionService.setCountingEnabled(false)
        DiagnosticLog.log("recognition debug session stopped")
    }

    private func handleVoiceCommand(_ command: VoiceCommand, transcript: String) {
        clearCommandToast()

        switch command {
        case .startWorkout:
            voiceStartRequested = true
            voiceStatusMessage = appLanguage == .russian ? "Голос: начинаем" : "Voice: start"
            confirmExerciseStartIfReady(reason: .voice)
        case .exercise(let mode):
            guard mode != selectedMode else {
                voiceStatusMessage = "\(L.t(.voice, appLanguage)): \(mode.title(appLanguage))"
                showCommandToast(message: mode.title(appLanguage))
                return
            }
            selectExerciseMode(mode)
            showCommandToast(message: mode.title(appLanguage))
            voiceStatusMessage = "\(L.t(.voice, appLanguage)): \(mode.title(appLanguage))"
        case .difficulty(let difficulty):
            guard canChangeDifficulty else {
                voiceStatusMessage = appLanguage == .russian ? "Голос: сложность заблокирована" : "Voice: difficulty locked"
                showCommandToast(message: voiceStatusMessage ?? "", tone: .warning)
                return
            }
            guard difficulty != activeWorkoutPlan.difficulty else {
                voiceStatusMessage = "\(L.t(.voice, appLanguage)): \(difficulty.title(appLanguage))"
                showCommandToast(message: "\(L.t(.difficulty, appLanguage)): \(difficulty.title(appLanguage))")
                return
            }
            selectDifficulty(difficulty)
            showCommandToast(message: "\(L.t(.difficulty, appLanguage)): \(difficulty.title(appLanguage))")
            voiceStatusMessage = "\(L.t(.voice, appLanguage)): \(difficulty.title(appLanguage))"
        case .emergencyUnlock:
            voiceStatusMessage = appLanguage == .russian ? "Голос: экстренное завершение" : "Voice: emergency unlock"
            showCommandToast(message: voiceStatusMessage ?? "", tone: .warning)
            emergencyCompleteWorkout()
        }
    }

    private func clearCommandToast() {
        commandToastClearTask?.cancel()
        commandToastMessage = nil
        commandToastClearTask = nil
    }

    func setSkeletonOverlayVisible(_ isVisible: Bool) {
        showSkeletonOverlay = isVisible
    }

    func setDebugPanelVisible(_ isVisible: Bool) {
        showDebugPanel = isVisible
        UserDefaults.standard.set(isVisible, forKey: "BreakGateWorkout.showDebugPanel")
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
                self.statusMessage = self.appLanguage == .russian ? "Камера работает: \(self.selectedCameraName)" : "Camera running: \(self.selectedCameraName)"
                self.statusIsError = false
            case .failure(let error):
                self.statusMessage = self.appLanguage == .russian ? "Не удалось переключить линзу: \(error.localizedDescription)" : "Lens could not be changed: \(error.localizedDescription)"
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
        print("BreakGateWorkout camera: discovery started")
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .external,
                .continuityCamera
            ],
            mediaType: .video,
            position: .unspecified
        )

        var seenDeviceIDs = Set<String>()
        captureDevices = discovery.devices.filter { device in
            seenDeviceIDs.insert(device.uniqueID).inserted
        }
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

        print("BreakGateWorkout camera: found devices count=\(captureDevices.count)")
        for device in captureDevices {
            print("BreakGateWorkout camera: device name=\(device.localizedName) localizedName=\(device.localizedName) uniqueID=\(device.uniqueID) type=\(device.deviceType.rawValue) continuity=\(isIPhoneCamera(device))")
        }
        print("BreakGateWorkout camera: continuity available=\(hasIPhoneCamera) mac available=\(hasMacCamera)")
    }

    private func preferredMacCamera() -> AVCaptureDevice? {
        captureDevices.first(where: isBuiltInMacCamera) ??
        captureDevices.first(where: { !isIPhoneCamera($0) }) ??
        captureDevices.first
    }

    private func preferredIPhoneCamera() -> AVCaptureDevice? {
        captureDevices.first(where: isIPhoneCamera)
    }

    private func fallbackCamera(excluding device: AVCaptureDevice) -> AVCaptureDevice? {
        let preferredFallback = fallbackForMissingPreferredCamera(kind: preferredCameraKind)
        if let preferredFallback, preferredFallback.uniqueID != device.uniqueID {
            return preferredFallback
        }

        return captureDevices.first(where: { $0.uniqueID != device.uniqueID })
    }

    private func fallbackForMissingPreferredCamera(kind: PreferredCameraKind) -> AVCaptureDevice? {
        switch kind {
        case .continuity:
            return preferredIPhoneCamera() ?? preferredMacCamera() ?? captureDevices.first
        case .mac:
            return preferredMacCamera() ?? preferredIPhoneCamera() ?? captureDevices.first
        }
    }

    private func restoredPreferredDevice() -> AVCaptureDevice? {
        if let selectedDeviceID,
           let selectedDevice = captureDevices.first(where: { $0.uniqueID == selectedDeviceID }) {
            print("BreakGateWorkout camera: restoring in-memory device uniqueID=\(selectedDeviceID)")
            return selectedDevice
        }

        if let persistedSelectedDeviceID,
           let persistedDevice = captureDevices.first(where: { $0.uniqueID == persistedSelectedDeviceID }) {
            print("BreakGateWorkout camera: restoring saved device uniqueID=\(persistedSelectedDeviceID)")
            selectedDeviceID = persistedSelectedDeviceID
            return persistedDevice
        }

        let fallback = fallbackForMissingPreferredCamera(kind: preferredCameraKind)
        if let fallback {
            print("BreakGateWorkout camera: restoring preferred kind=\(preferredCameraKind.rawValue) fallback device=\(fallback.localizedName)")
        } else {
            print("BreakGateWorkout camera: no device available for preferred kind=\(preferredCameraKind.rawValue)")
        }
        return fallback
    }

    private func isBuiltInMacCamera(_ device: AVCaptureDevice) -> Bool {
        !isIPhoneCamera(device) && device.deviceType == .builtInWideAngleCamera
    }

    private func isIPhoneCamera(_ device: AVCaptureDevice) -> Bool {
        let name = device.localizedName.lowercased()
        return device.isContinuityCamera || name.contains("iphone") || name.contains("continuity")
    }

    private func configureCamera(_ device: AVCaptureDevice, allowFallback: Bool = true) {
        let deviceName = device.localizedName
        DiagnosticLog.log("CameraModel.configureCamera device=\(deviceName)")
        print("BreakGateWorkout camera: selecting device name=\(deviceName) uniqueID=\(device.uniqueID) continuity=\(isIPhoneCamera(device))")
        selectedDeviceID = device.uniqueID
        persistedSelectedDeviceID = device.uniqueID
        preferredCameraKind = isIPhoneCamera(device) ? .continuity : .mac
        selectedCameraName = deviceName
        updateZoomLimits(for: device)
        statusMessage = appLanguage == .russian ? "Подключение камеры…" : "Connecting camera…"
        statusIsError = false
        isSwitchingCamera = true
        hasReceivedCameraFrame = false
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
                DiagnosticLog.log("CameraModel.configureCamera success device=\(deviceName)")
                print("BreakGateWorkout camera: session started device=\(deviceName) uniqueID=\(device.uniqueID) continuity=\(self.isIPhoneCamera(device))")
                self.session = newSession
                self.selectedDeviceID = device.uniqueID
                self.selectedCameraName = deviceName
                self.setZoomFactor(1)
                self.statusMessage = self.isIPhoneCamera(device)
                    ? (self.appLanguage == .russian ? "Continuity Camera: \(deviceName)" : "Continuity Camera: \(deviceName)")
                    : (self.appLanguage == .russian ? "Камера Mac: \(deviceName)" : "Mac camera: \(deviceName)")
                self.statusIsError = false
                self.isSwitchingCamera = false
            case .failure(let error):
                DiagnosticLog.log("CameraModel.configureCamera failed device=\(deviceName) error=\(error.localizedDescription)")
                if allowFallback, let fallback = self.fallbackCamera(excluding: device) {
                    DiagnosticLog.log("CameraModel.configureCamera retrying with fallback device=\(fallback.localizedName)")
                    self.statusMessage = self.appLanguage == .russian
                        ? "\(deviceName) недоступна. Переключаюсь на \(fallback.localizedName)."
                        : "\(deviceName) is unavailable. Switching to \(fallback.localizedName)."
                    self.statusIsError = false
                    self.isSwitchingCamera = false
                    self.configureCamera(fallback, allowFallback: false)
                    return
                }

                self.session = nil
                print("BreakGateWorkout camera: session failed device=\(deviceName) error=\(error.localizedDescription)")
                self.statusMessage = self.appLanguage == .russian ? "Не удалось запустить камеру: \(error.localizedDescription)" : "Camera could not start: \(error.localizedDescription)"
                self.statusIsError = true
                self.isSwitchingCamera = false
            }
        }
    }

    private func clearPreview(message: String, isError: Bool) {
        DiagnosticLog.log("CameraModel.clearPreview isError=\(isError) message=\(message)")
        sessionController.stop()
        poseDetectionService.reset()
        session = nil
        selectedCameraName = appLanguage == .russian ? "Камера недоступна" : "Camera unavailable"
        statusMessage = message
        statusIsError = isError
        isSwitchingCamera = false
        hasReceivedCameraFrame = false
        resetPoseState()
    }

    private func applyPoseUpdate(_ update: PoseDetectionUpdate) {
        hasReceivedCameraFrame = true
        confidence = update.confidence
        isPersonDetected = update.isPersonDetected
        posePoints = update.posePoints
        previewVideoSize = update.videoSize
        updateCoachingMessage()
        defer {
            onRecognitionDebugPoseUpdate?(self, update)
        }

        guard exerciseCountingEnabled else {
            updateStartReadiness(with: update)
            return
        }

        if selectedMode.isTimed {
            updateTimedHoldState(with: update)
        } else {
            repCount = update.repCount
            currentWorkoutState = update.workoutState
            currentPoseState = update.debugState
            playRepSoundIfNeeded()
            celebrateRepProgressIfNeeded()
            checkWorkoutCompletion()
        }
    }

    private func resetPoseState() {
        resetWorkoutState()
    }

    private func applyCurrentStep(resetPoseService: Bool) {
        let step = currentStep
        selectedMode = step.mode

        if step.mode.isTimed {
            plankDuration = Double(step.targetSeconds ?? step.targetAmount)
        } else {
            targetRepCount = step.targetReps ?? step.targetAmount
        }

        poseDetectionService.setMode(step.mode)
        if resetPoseService {
            poseDetectionService.reset()
        }
        resetWorkoutState()
        statusMessage = appLanguage == .russian ? "Текущий шаг: \(step.summary(appLanguage))" : "Current step: \(step.summary(appLanguage))"
    }

    private func defaultStep(mode: ExerciseMode, difficulty: WorkoutDifficulty) -> WorkoutStep {
        if mode.isTimed {
            let seconds: Int
            if mode == .tuckPlancheHold || mode == .lSitHold || mode == .elbowLeverHold {
                seconds = 5
            } else {
                switch difficulty {
                case .light:
                    seconds = 45
                case .medium:
                    seconds = 60
                case .hard, .extreme, .extremePlus:
                    seconds = 90
                }
            }
            return WorkoutStep(mode: mode, targetSeconds: seconds)
        }

        let reps: Int
        switch mode {
        case .burpees:
            switch difficulty {
            case .light:
                reps = 5
            case .medium:
                reps = 7
            case .hard, .extreme, .extremePlus:
                reps = 10
            }
        case .mountainClimbers:
            switch difficulty {
            case .light:
                reps = 10
            case .medium:
                reps = 15
            case .hard:
                reps = 20
            case .extreme, .extremePlus:
                reps = 30
            }
        case .pushUps, .squats, .abs, .pikePushUps:
            switch difficulty {
            case .light:
                reps = 10
            case .medium:
                reps = 15
            case .hard, .extreme, .extremePlus:
                reps = 20
            }
        case .plank, .tuckPlancheHold, .lSitHold, .elbowLeverHold:
            reps = 20
        }
        return WorkoutStep(mode: mode, targetReps: reps)
    }

    private func resetWorkoutState() {
        repCount = 0
        currentWorkoutState = .idle
        currentPoseState = WorkoutState.idle.rawValue
        confidence = 0
        isPersonDetected = false
        posePoints = []
        plankTimeRemaining = selectedMode.isTimed ? plankDuration : 0
        plankIsActive = false
        lastPlankTick = nil
        plankBrokenUntil = nil
        workoutCompletionRecorded = false
        lastSoundedRepCount = 0
        lastFinalPlankSecondSound = nil
        plankWasStable = false
        lastTimedHoldDiagnosticState = nil
        lastCelebratedRepCount = 0
        lastCelebratedPlankBucket = 0
        exerciseStartReadyAt = Date().addingTimeInterval(exerciseStartDelay)
        startingPoseStableSince = nil
        exerciseCountingEnabled = false
        voiceStartRequested = false
        automaticStartWindowExpired = false
        coachingMessage = nil
        celebrationMessage = nil
        celebrationTone = .success
        commandToastMessage = nil
        commandToastTone = .success
        poseWaitCountdownText = nil
        primaryOverlayMessage = startPromptText()
        primaryOverlayTone = .warning
        showWorkoutCompletedOverlay = false
        celebrationClearTask?.cancel()
        celebrationClearTask = nil
        commandToastClearTask?.cancel()
        commandToastClearTask = nil
        poseDetectionService.setCountingEnabled(false)
        updatePoseWaitCountdown(now: Date())
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

    private func updateTimedHoldState(with update: PoseDetectionUpdate) {
        let now = Date()
        let isExperimentalHold = selectedMode == .tuckPlancheHold || selectedMode == .lSitHold || selectedMode == .elbowLeverHold
        let requiredConfidence: Float = isExperimentalHold ? 0.30 : 0.22
        let requiredStableDuration: TimeInterval = isExperimentalHold ? 2.0 : 0
        let isPoseActive = update.isPersonDetected && update.confidence >= requiredConfidence && update.workoutState == .plankActive
        logTimedHoldStateIfNeeded(isPoseActive ? "valid \(update.debugState)" : "invalid \(update.debugState)")

        if !isPoseActive {
            if selectedMode == .plank && plankWasStable && plankTimeRemaining > 0 {
                soundFeedback.playPlankFail()
                showCelebration(message: appLanguage == .russian ? "Планка сорвана" : "Plank broken", tone: .failure)
            }

            plankTimeRemaining = plankDuration
            plankIsActive = false
            lastPlankTick = nil
            plankBrokenUntil = now.addingTimeInterval(1.5)
            currentWorkoutState = .plankBroken
            currentPoseState = update.debugState
            lastCelebratedPlankBucket = 0
            lastFinalPlankSecondSound = nil
            plankWasStable = false
            return
        }

        if selectedMode == .plank, let brokenUntil = plankBrokenUntil, now < brokenUntil {
            currentWorkoutState = .plankBroken
            currentPoseState = WorkoutState.plankBroken.rawValue
            return
        }

        plankBrokenUntil = nil
        plankWasStable = true

        if lastPlankTick == nil {
            lastPlankTick = now
            currentWorkoutState = .plankActive
            currentPoseState = update.debugState
            return
        }

        if !plankIsActive, let stableSince = lastPlankTick {
            guard now.timeIntervalSince(stableSince) >= requiredStableDuration else {
                currentWorkoutState = .plankActive
                currentPoseState = appLanguage == .russian ? "стабилизация" : "stabilizing"
                return
            }

            plankIsActive = true
            lastPlankTick = now
            currentWorkoutState = .plankActive
            currentPoseState = update.debugState
            logTimedHoldStateIfNeeded("timer started")
            return
        }

        plankIsActive = true

        if let lastPlankTick {
            plankTimeRemaining = max(0, plankTimeRemaining - now.timeIntervalSince(lastPlankTick))
        }

        lastPlankTick = now
        currentWorkoutState = .plankActive
        currentPoseState = update.debugState
        if selectedMode == .plank {
            playPlankFinalCountdownIfNeeded()
            celebratePlankProgressIfNeeded()
        }
        checkWorkoutCompletion()
    }

    private func logTimedHoldStateIfNeeded(_ state: String) {
        guard selectedMode == .lSitHold || selectedMode == .elbowLeverHold else { return }
        let diagnosticState = "\(selectedMode.rawValue):\(state)"
        guard lastTimedHoldDiagnosticState != diagnosticState else { return }
        lastTimedHoldDiagnosticState = diagnosticState
        DiagnosticLog.log("\(selectedMode.rawValue) \(state)")
    }

    private func updateCoachingMessage() {
        guard isPersonDetected, !posePoints.isEmpty else {
            coachingMessage = appLanguage == .russian ? "Встань в кадр" : "Step into frame"
            return
        }

        if confidence < 0.20 {
            coachingMessage = appLanguage == .russian ? "Добавь света или повернись к камере" : "Improve lighting or face the camera"
            return
        }

        let xs = posePoints.map(\.location.x)
        let ys = posePoints.map(\.location.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            coachingMessage = appLanguage == .russian ? "Замри для трекинга" : "Hold still for tracking"
            return
        }

        let width = maxX - minX
        let height = maxY - minY
        let centerX = (minX + maxX) / 2
        let centerY = (minY + maxY) / 2

        if width < 0.18 && height < 0.30 {
            coachingMessage = appLanguage == .russian ? "Подойди ближе" : "Step closer"
        } else if width > 0.82 || height > 0.88 {
            coachingMessage = appLanguage == .russian ? "Отойди дальше" : "Step farther back"
        } else if centerX < 0.34 {
            coachingMessage = appLanguage == .russian ? "Сдвинься вправо" : "Move right"
        } else if centerX > 0.66 {
            coachingMessage = appLanguage == .russian ? "Сдвинься влево" : "Move left"
        } else if centerY < 0.30 {
            coachingMessage = appLanguage == .russian ? "Опустись ниже в кадре" : "Move lower in frame"
        } else if centerY > 0.72 {
            coachingMessage = appLanguage == .russian ? "Поднимись выше в кадре" : "Move higher in frame"
        } else if selectedMode == .plank && currentWorkoutState == .plankBroken {
            coachingMessage = appLanguage == .russian ? "Выпрями плечи, таз и колени" : "Straighten shoulders, hips, knees"
        } else if selectedMode == .burpees {
            switch currentPoseState {
            case BurpeePhase.standing.rawValue, BurpeePhase.initialJump.rawValue:
                coachingMessage = appLanguage == .russian ? "Встань ровно" : "Stand tall"
            case BurpeePhase.squat.rawValue, BurpeePhase.returnSquat.rawValue:
                coachingMessage = appLanguage == .russian ? "Ноги назад / прыжок вверх" : "Kick back / jump up"
            case BurpeePhase.plank.rawValue:
                coachingMessage = appLanguage == .russian ? "Вниз в отжимание" : "Drop to push-up"
            case BurpeePhase.pushUpDown.rawValue:
                coachingMessage = appLanguage == .russian ? "Вернись в присед" : "Back to squat"
            case BurpeePhase.finalJump.rawValue:
                coachingMessage = appLanguage == .russian ? "Выпрыгни вверх" : "Jump up"
            default:
                coachingMessage = appLanguage == .russian ? "Отожмись" : "Push up"
            }
        } else if selectedMode == .mountainClimbers {
            switch currentPoseState {
            case MountainClimberPhase.plankReady.rawValue:
                coachingMessage = appLanguage == .russian ? "Подтяни колено" : "Drive your knee"
            case MountainClimberPhase.leftKneeDrive.rawValue, MountainClimberPhase.rightKneeDrive.rawValue:
                coachingMessage = appLanguage == .russian ? "Смени ногу" : "Switch legs"
            case MountainClimberPhase.waitingForAlternation.rawValue:
                coachingMessage = appLanguage == .russian ? "Держи планку" : "Hold plank"
            default:
                coachingMessage = appLanguage == .russian ? "Держи корпус" : "Keep your core tight"
            }
        } else if selectedMode == .lSitHold {
            if currentPoseState == "lSitHold" {
                coachingMessage = appLanguage == .russian ? "Держи уголок" : "Hold the L-sit"
            } else if currentPoseState.contains("lift") {
                coachingMessage = appLanguage == .russian ? "Подними ноги выше" : "Lift your legs higher"
            } else if currentPoseState.contains("hips") {
                coachingMessage = appLanguage == .russian ? "Оторви таз от пола" : "Lift your hips off the floor"
            } else if currentPoseState.contains("legs") {
                coachingMessage = appLanguage == .russian ? "Выпрями ноги" : "Straighten your legs"
            } else if currentPoseState.contains("support") {
                coachingMessage = appLanguage == .russian ? "Дави руками в пол" : "Press through your hands"
            } else {
                coachingMessage = appLanguage == .russian ? "Сядь в уголок" : "Get into L-sit"
            }
        } else if selectedMode == .elbowLeverHold {
            if currentPoseState == "elbowLeverHold" {
                coachingMessage = appLanguage == .russian ? "Держи рычаг" : "Hold the lever"
            } else if currentPoseState.contains("line") {
                coachingMessage = appLanguage == .russian ? "Выпрями тело" : "Straighten your body"
            } else if currentPoseState.contains("support") {
                coachingMessage = appLanguage == .russian ? "Локти ближе к корпусу" : "Keep elbows close"
            } else {
                coachingMessage = appLanguage == .russian ? "Встань в локтевой рычаг" : "Get into elbow lever"
            }
        } else if selectedMode == .pikePushUps {
            if currentPoseState == PikePushUpPhase.pikeUp.rawValue {
                coachingMessage = appLanguage == .russian ? "Держи таз выше" : "Keep your hips high"
            } else if currentPoseState == PikePushUpPhase.pikeDown.rawValue {
                coachingMessage = appLanguage == .russian ? "Опусти голову к полу" : "Lower your head toward the floor"
            } else if currentPoseState.contains("hips") {
                coachingMessage = appLanguage == .russian ? "Не опускай таз" : "Do not drop your hips"
            } else if currentPoseState.contains("legs") {
                coachingMessage = appLanguage == .russian ? "Выпрями ноги" : "Straighten your legs"
            } else {
                coachingMessage = appLanguage == .russian ? "Встань в пайк" : "Get into pike"
            }
        } else {
            coachingMessage = appLanguage == .russian ? "Кадр хороший" : "Good framing"
        }
    }

    private func updateStartReadiness(with update: PoseDetectionUpdate) {
        currentWorkoutState = update.workoutState
        currentPoseState = update.debugState
        let now = Date()
        updatePoseWaitCountdown(now: now)

        if voiceStartRequested {
            confirmExerciseStart(reason: .voice)
            return
        }

        if now >= exerciseStartReadyAt {
            automaticStartWindowExpired = true
            startingPoseStableSince = nil
            poseWaitCountdownText = nil
            primaryOverlayMessage = appLanguage == .russian ? "Скажи «поехали», когда будешь готов" : "Say “go” when ready"
            primaryOverlayTone = .warning
            return
        }

        if !update.isStartingPoseDetected || update.confidence < startingPoseConfidenceThreshold {
            startingPoseStableSince = nil
            primaryOverlayMessage = startPromptText()
            primaryOverlayTone = .warning
            return
        }

        if let stableSince = startingPoseStableSince {
            if now.timeIntervalSince(stableSince) >= startingPoseHoldDuration {
                confirmExerciseStart(reason: .autoPose)
            }
        } else {
            startingPoseStableSince = now
        }
    }

    private func confirmExerciseStartIfReady(reason: ExerciseStartReason) {
        confirmExerciseStart(reason: reason)
    }

    private func confirmExerciseStart(reason: ExerciseStartReason) {
        guard !exerciseCountingEnabled else { return }

        DiagnosticLog.log("exercise counting enabled reason=\(reason) mode=\(selectedMode.rawValue)")
        exerciseCountingEnabled = true
        voiceStartRequested = false
        startingPoseStableSince = nil
        poseDetectionService.setCountingEnabled(true)
        soundFeedback.playFinalCountdownTick()
        primaryOverlayMessage = nil
        poseWaitCountdownText = nil
        showCelebration(message: appLanguage == .russian ? "Начинай!" : "Go!", tone: .success)
    }

    private func startPromptText() -> String {
        appLanguage == .russian ? "Встань в исходную позу" : "Get into starting position"
    }

    private func updatePoseWaitCountdown(now: Date) {
        guard !exerciseCountingEnabled, !automaticStartWindowExpired else {
            poseWaitCountdownText = nil
            return
        }

        let remaining = max(0, Int(ceil(exerciseStartReadyAt.timeIntervalSince(now))))
        poseWaitCountdownText = appLanguage == .russian
            ? "Ожидание позы \(remaining)с"
            : "Waiting for pose \(remaining)s"
    }

    private func celebrateRepProgressIfNeeded() {
        guard repCount > lastCelebratedRepCount else { return }
        lastCelebratedRepCount = repCount
        guard repCount.isMultiple(of: 5) || repCount >= currentTargetAmount else { return }
        showCelebration(message: celebrationText(for: repCount))
    }

    private func celebratePlankProgressIfNeeded() {
        let heldSeconds = max(0, plankDuration - plankTimeRemaining)
        let bucket = Int(heldSeconds / 20)
        guard bucket > 0, bucket > lastCelebratedPlankBucket else { return }

        lastCelebratedPlankBucket = bucket
        soundFeedback.playPlankMilestone()
        showCelebration(message: appLanguage == .russian ? "\(bucket * 20)с удержано" : "\(bucket * 20)s held")
    }

    private func playRepSoundIfNeeded() {
        guard repCount > lastSoundedRepCount else { return }
        lastSoundedRepCount = repCount
        soundFeedback.playRepAccepted()
    }

    private func playPlankFinalCountdownIfNeeded() {
        let remainingSecond = Int(ceil(plankTimeRemaining))
        guard (1...5).contains(remainingSecond), lastFinalPlankSecondSound != remainingSecond else { return }

        lastFinalPlankSecondSound = remainingSecond
        soundFeedback.playFinalCountdownTick()
    }

    private func celebrationText(for rep: Int) -> String {
        if rep >= currentTargetAmount {
            return appLanguage == .russian ? "Разблокировано!" : "Unlocked!"
        }

        if rep * 2 >= currentTargetAmount {
            return appLanguage == .russian ? "Половина готова!" : "Halfway there!"
        }

        let messages = appLanguage == .russian
            ? ["Отлично!", "Продолжай!", "Чистый повтор!"]
            : ["Nice!", "Keep going!", "Clean rep!"]
        return messages[(rep / 5) % messages.count]
    }

    private func showCelebration(message: String, tone: CelebrationTone = .success) {
        celebrationClearTask?.cancel()
        celebrationMessage = message
        celebrationTone = tone

        celebrationClearTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.celebrationMessage = nil
                self?.celebrationClearTask = nil
            }
        }
    }

    private func showCommandToast(message: String, tone: CelebrationTone = .success) {
        commandToastClearTask?.cancel()
        commandToastMessage = message
        commandToastTone = tone

        commandToastClearTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1600))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.commandToastMessage = nil
                self?.commandToastClearTask = nil
            }
        }
    }

    private func checkWorkoutCompletion() {
        guard !workoutCompletionRecorded else { return }

        switch selectedMode {
        case .pushUps, .squats, .abs, .burpees, .mountainClimbers, .pikePushUps:
            guard repCount >= targetRepCount else { return }
            if recognitionDebugSessionActive {
                workoutCompletionRecorded = true
                DiagnosticLog.log("recognition debug rep target reached mode=\(selectedMode.rawValue)")
                onRecognitionDebugStepCompleted?()
                return
            }
            completeCurrentStep(amount: repCount)
        case .plank, .tuckPlancheHold, .lSitHold, .elbowLeverHold:
            guard plankTimeRemaining <= 0, plankIsActive else { return }
            if selectedMode == .lSitHold || selectedMode == .elbowLeverHold {
                DiagnosticLog.log("\(selectedMode.rawValue) hold completed")
            }
            if recognitionDebugSessionActive {
                workoutCompletionRecorded = true
                DiagnosticLog.log("recognition debug timed target reached mode=\(selectedMode.rawValue)")
                onRecognitionDebugStepCompleted?()
                return
            }
            completeCurrentStep(amount: Int(plankDuration.rounded()))
        }
    }

    private func completeCurrentStep(amount: Int) {
        var completedStep = currentStep
        if completedStep.mode.isTimed {
            completedStep.targetSeconds = amount
            completedStep.targetReps = nil
        } else {
            completedStep.targetReps = amount
            completedStep.targetSeconds = nil
        }
        completedSteps.append(completedStep)

        let nextIndex = currentStepIndex + 1
        if activeWorkoutPlan.steps.indices.contains(nextIndex) {
            currentStepIndex = nextIndex
            let nextStep = currentStep
            applyCurrentStep(resetPoseService: true)
            showCelebration(message: "\(appLanguage == .russian ? "Дальше" : "Next"): \(nextStep.summary(appLanguage))")
            return
        }

        workoutCompletionRecorded = true
        statusMessage = appLanguage == .russian ? "Тренировка завершена. BreakGate разблокирован." : "Workout completed. BreakGate unlocked."
        soundFeedback.playExerciseFinish()
        showWorkoutCompletedOverlay = true

        let completedPlan = activeWorkoutPlan
        let finalCompletedSteps = completedSteps
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                guard let self, self.workoutCompletionRecorded else { return }
                self.onWorkoutCompleted?(completedPlan, finalCompletedSteps)
            }
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

            DiagnosticLog.log("CameraSessionController.configure requested device=\(device.localizedName)")
            print("BreakGateWorkout camera: configure session requested device=\(device.localizedName) uniqueID=\(device.uniqueID)")
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
                DiagnosticLog.log("AVCaptureSession.startRunning completed device=\(device.localizedName)")

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
            DiagnosticLog.log("CameraSessionController.stop requested")
            self?.stopCurrentSession()
        }
    }

    private func stopCurrentSession() {
        guard let session = currentSession else {
            DiagnosticLog.log("CameraSessionController.stopCurrentSession no active session")
            return
        }

        if let currentDevice {
            print("BreakGateWorkout camera: stopping previous session device=\(currentDevice.localizedName) uniqueID=\(currentDevice.uniqueID)")
        }

        if session.isRunning {
            session.stopRunning()
            DiagnosticLog.log("AVCaptureSession.stopRunning completed")
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
    let debugState: String
    let confidence: Float
    let isPersonDetected: Bool
    let isStartingPoseDetected: Bool
    let posePoints: [PoseJointPoint]
    let videoSize: CGSize
}

private enum ExerciseStartReason {
    case autoPose
    case voice
}

private struct PoseStateResult {
    let state: WorkoutState
    let debugState: String
}

private final class PoseDetectionService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let videoOutputQueue = DispatchQueue(label: "BreakGateWorkout.pose.videoOutput", qos: .userInitiated)

    var onUpdate: (@MainActor (PoseDetectionUpdate) -> Void)?
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?

    private let bodyPoseRequest = VNDetectHumanBodyPoseRequest()
    private let minimumPointConfidence: Float = 0.25
    private let minimumFrameInterval: TimeInterval = 1.0 / 30.0
    private let pushUpAngleUpThreshold: CGFloat = 150
    private let pushUpAngleDownThreshold: CGFloat = 95
    private let squatKneeBentThreshold: CGFloat = 115
    private let squatKneeStraightThreshold: CGFloat = 155
    private let absContractedThreshold: CGFloat = 55
    private let absExtendedThreshold: CGFloat = 105
    private let absLooseContractedThreshold: CGFloat = 68
    private let absLooseExtendedThreshold: CGFloat = 96
    private let absContractedShoulderKneeRatio: CGFloat = 1.18
    private let absExtendedShoulderKneeRatio: CGFloat = 1.42
    private let plankStraightThreshold: CGFloat = 145
    private let mountainClimberPlankThreshold: CGFloat = 124
    private let burpeeStandingThreshold: CGFloat = 150
    private let burpeePushUpDownThreshold: CGFloat = 105
    private let burpeeSquatThreshold: CGFloat = 125
    private let mountainClimberHipDriveThreshold: CGFloat = 138
    private let mountainClimberKneeToShoulderRatio: CGFloat = 0.74
    private let tuckPlancheArmStraightThreshold: CGFloat = 150
    private let tuckPlancheKneeToTorsoRatio: CGFloat = 1.35
    private let lSitArmStraightThreshold: CGFloat = 145
    private let lSitLegStraightThreshold: CGFloat = 145
    private let elbowLeverBodyStraightThreshold: CGFloat = 145
    private let pikeExtendedThreshold: CGFloat = 145
    private let pikeDownElbowMin: CGFloat = 55
    private let pikeDownElbowMax: CGFloat = 120

    private var mode: ExerciseMode = .pushUps
    private var lastProcessedTime: CFTimeInterval = 0
    private var isProcessingFrame = false
    private var repCount = 0
    private var personWasDetected = false
    private var pushUpPosition: ExercisePosition = .waiting
    private var squatPosition: ExercisePosition = .waiting
    private var absPosition: ExercisePosition = .waiting
    private var burpeePhase: BurpeePhase = .standing
    private var burpeeLastHipY: CGFloat?
    private var mountainPhase: MountainClimberPhase = .plankReady
    private var lastMountainDriveSide: BodySide?
    private var pikePhase: PikePushUpPhase = .pikeReady
    private var pikeTopHeadY: CGFloat?
    private var pikeTopShoulderY: CGFloat?
    private var pikeTopElbowAngle: CGFloat?
    private var pikeBottomHeadY: CGFloat?
    private var pikeBottomShoulderY: CGFloat?
    private var pikeBottomElbowAngle: CGFloat?
    private var countingEnabled = false
    private var diagnosticsWindowStart = CACurrentMediaTime()
    private var diagnosticsFramesSeen = 0
    private var diagnosticsVisionRuns = 0
    private var diagnosticsPublishes = 0

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
                        debugState: WorkoutState.idle.rawValue,
                        confidence: 0,
                        isPersonDetected: false,
                        isStartingPoseDetected: false,
                        posePoints: [],
                        videoSize: CGSize(width: 16, height: 9)
                    )
                )
            }
        }
    }

    func setCountingEnabled(_ isEnabled: Bool) {
        videoOutputQueue.async { [weak self] in
            guard let self else { return }
            self.countingEnabled = isEnabled
            if isEnabled {
                self.resetExercisePositionsOnQueue()
            }
        }
    }

    private func resetStateOnQueue() {
        lastProcessedTime = 0
        isProcessingFrame = false
        repCount = 0
        personWasDetected = false
        countingEnabled = false
        resetExercisePositionsOnQueue()
        resetDiagnosticsCounters()
    }

    private func resetExercisePositionsOnQueue() {
        pushUpPosition = .waiting
        squatPosition = .waiting
        absPosition = .waiting
        burpeePhase = .standing
        burpeeLastHipY = nil
        mountainPhase = .plankReady
        lastMountainDriveSide = nil
        pikePhase = .pikeReady
        pikeTopHeadY = nil
        pikeTopShoulderY = nil
        pikeTopElbowAngle = nil
        pikeBottomHeadY = nil
        pikeBottomShoulderY = nil
        pikeBottomElbowAngle = nil
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        onSampleBuffer?(sampleBuffer)

        let now = CACurrentMediaTime()
        diagnosticsFramesSeen += 1
        reportDiagnosticsIfNeeded(now: now)
        guard now - lastProcessedTime >= minimumFrameInterval else { return }
        guard !isProcessingFrame else { return }

        lastProcessedTime = now
        isProcessingFrame = true
        diagnosticsVisionRuns += 1

        defer {
            isProcessingFrame = false
        }

        let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up, options: [:])
        let videoSize = videoSize(from: sampleBuffer)

        do {
            try handler.perform([bodyPoseRequest])

            guard let observation = bodyPoseRequest.results?.first else {
                publishPersonLostIfNeeded()
                publish(workoutState: .noPerson, debugState: WorkoutState.noPerson.rawValue, confidence: 0, isPersonDetected: false, posePoints: [], videoSize: videoSize)
                return
            }

            let points = try observation.recognizedPoints(.all)
            let usablePoints = points.values.filter { $0.confidence >= minimumPointConfidence }
            let averageConfidence = usablePoints.isEmpty ? 0 : usablePoints.reduce(Float(0)) { $0 + $1.confidence } / Float(usablePoints.count)

            guard usablePoints.count >= 5 else {
                publishPersonLostIfNeeded()
                publish(workoutState: .noPerson, debugState: WorkoutState.noPerson.rawValue, confidence: averageConfidence, isPersonDetected: false, posePoints: [], videoSize: videoSize)
                return
            }

            if !personWasDetected {
                personWasDetected = true
                print("BreakGateWorkout pose: person detected")
            }

            let startingPoseDetected = isStartingPoseValid(points: points)
            let poseResult = countingEnabled ? updateExerciseState(points: points) : startingPoseResult(isDetected: startingPoseDetected)
            publish(
                workoutState: poseResult.state,
                debugState: poseResult.debugState,
                confidence: averageConfidence,
                isPersonDetected: true,
                isStartingPoseDetected: startingPoseDetected,
                posePoints: skeletonPoints(from: points),
                videoSize: videoSize
            )
        } catch {
            publish(workoutState: .idle, debugState: WorkoutState.idle.rawValue, confidence: 0, isPersonDetected: false, posePoints: [], videoSize: videoSize)
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

    private func startingPoseResult(isDetected: Bool) -> PoseStateResult {
        if mode == .plank {
            return PoseStateResult(state: isDetected ? .plankActive : .tracking, debugState: isDetected ? "plank ready" : "waiting start")
        }

        return PoseStateResult(state: isDetected ? .tracking : .idle, debugState: isDetected ? "start ready" : "waiting start")
    }

    private func isStartingPoseValid(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> Bool {
        switch mode {
        case .pushUps, .plank:
            return isPlankFormValid(points: points)
        case .mountainClimbers:
            return isMountainClimberBaseValid(points: points)
        case .pikePushUps:
            return pikeTopPoseResult(points: points).isValid
        case .tuckPlancheHold:
            return isTuckPlancheValid(points: points)
        case .lSitHold:
            return lSitPoseResult(points: points).isValid
        case .elbowLeverHold:
            return elbowLeverPoseResult(points: points).isValid
        case .burpees:
            return isStandingFormValid(points: points)
        case .squats:
            guard let kneeAngle = bestAngle(
                points: points,
                firstCandidates: [.leftHip, .rightHip],
                middleCandidates: [.leftKnee, .rightKnee],
                lastCandidates: [.leftAnkle, .rightAnkle]
            ) else {
                return false
            }

            return kneeAngle >= squatKneeStraightThreshold
        case .abs:
            guard let metrics = absMetrics(points: points) else { return false }
            return metrics.isExtended
        }
    }

    private func updateExerciseState(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> PoseStateResult {
        switch mode {
        case .pushUps:
            guard let elbowAngle = bestAngle(
                points: points,
                firstCandidates: [.leftShoulder, .rightShoulder],
                middleCandidates: [.leftElbow, .rightElbow],
                lastCandidates: [.leftWrist, .rightWrist]
            ) else { return PoseStateResult(state: .tracking, debugState: "push-up tracking") }

            return PoseStateResult(state: updatePushUpState(elbowAngle: elbowAngle) ? .activeExercise : .tracking, debugState: pushUpPosition == .down ? "push-up down" : "push-up up")
        case .squats:
            guard let kneeAngle = bestAngle(
                points: points,
                firstCandidates: [.leftHip, .rightHip],
                middleCandidates: [.leftKnee, .rightKnee],
                lastCandidates: [.leftAnkle, .rightAnkle]
            ) else { return PoseStateResult(state: .tracking, debugState: "squat tracking") }

            return PoseStateResult(state: updateSquatState(kneeAngle: kneeAngle) ? .activeExercise : .tracking, debugState: squatPosition == .down ? "squat down" : "squat up")
        case .abs:
            guard let metrics = absMetrics(points: points) else {
                return PoseStateResult(state: .tracking, debugState: "abs tracking")
            }

            let counted = updateAbsState(metrics: metrics)
            let phase = absPosition == .down ? "abs contracted" : "abs extended"
            return PoseStateResult(
                state: counted ? .activeExercise : .tracking,
                debugState: "\(phase) angle \(Int(metrics.torsoAngle.rounded())) ratio \(String(format: "%.2f", metrics.shoulderToKneeRatio))"
            )
        case .plank:
            let isValid = isPlankFormValid(points: points)
            return PoseStateResult(state: isValid ? .plankActive : .plankBroken, debugState: isValid ? "plank active" : "plank broken")
        case .tuckPlancheHold:
            let isValid = isTuckPlancheValid(points: points)
            return PoseStateResult(state: isValid ? .plankActive : .plankBroken, debugState: isValid ? "tuck planche hold" : "tuck planche setup")
        case .lSitHold:
            let result = lSitPoseResult(points: points)
            return PoseStateResult(state: result.isValid ? .plankActive : .plankBroken, debugState: result.debugState)
        case .elbowLeverHold:
            let result = elbowLeverPoseResult(points: points)
            return PoseStateResult(state: result.isValid ? .plankActive : .plankBroken, debugState: result.debugState)
        case .burpees:
            let counted = updateBurpeeState(points: points)
            return PoseStateResult(state: counted ? .activeExercise : .tracking, debugState: burpeePhase.rawValue)
        case .mountainClimbers:
            let counted = updateMountainClimberState(points: points)
            return PoseStateResult(state: counted ? .activeExercise : .tracking, debugState: mountainPhase.rawValue)
        case .pikePushUps:
            let counted = updatePikePushUpState(points: points)
            return PoseStateResult(state: counted ? .activeExercise : .tracking, debugState: pikePhase.rawValue)
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

    private func updateAbsState(metrics: AbsMetrics) -> Bool {
        if metrics.isContracted {
            absPosition = .down
            return false
        }

        if metrics.isExtended {
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

    private func absMetrics(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> AbsMetrics? {
        guard let torsoAngle = bestAngle(
            points: points,
            firstCandidates: [.leftShoulder, .rightShoulder],
            middleCandidates: [.leftHip, .rightHip],
            lastCandidates: [.leftKnee, .rightKnee]
        ), let shoulderCenter = averagePoint(points: points, joints: [.leftShoulder, .rightShoulder]),
           let hipCenter = averagePoint(points: points, joints: [.leftHip, .rightHip]),
           let kneeCenter = averagePoint(points: points, joints: [.leftKnee, .rightKnee]) else {
            return nil
        }

        let hipToKnee = max(0.01, distance(hipCenter, kneeCenter))
        let shoulderToKneeRatio = distance(shoulderCenter, kneeCenter) / hipToKnee
        return AbsMetrics(
            torsoAngle: torsoAngle,
            shoulderToKneeRatio: shoulderToKneeRatio,
            contractedAngle: absContractedThreshold,
            looseContractedAngle: absLooseContractedThreshold,
            extendedAngle: absExtendedThreshold,
            looseExtendedAngle: absLooseExtendedThreshold,
            contractedRatio: absContractedShoulderKneeRatio,
            extendedRatio: absExtendedShoulderKneeRatio
        )
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

    private func isStandingFormValid(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> Bool {
        guard let bodyLineAngle = bestAngle(
            points: points,
            firstCandidates: [.leftShoulder, .rightShoulder],
            middleCandidates: [.leftHip, .rightHip],
            lastCandidates: [.leftKnee, .rightKnee]
        ), let kneeAngle = bestAngle(
            points: points,
            firstCandidates: [.leftHip, .rightHip],
            middleCandidates: [.leftKnee, .rightKnee],
            lastCandidates: [.leftAnkle, .rightAnkle]
        ) else {
            return false
        }

        return bodyLineAngle >= burpeeStandingThreshold && kneeAngle >= squatKneeStraightThreshold
    }

    private func updateBurpeeState(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> Bool {
        let isStanding = isStandingFormValid(points: points)
        let isSquat = isSquatLike(points: points)
        let isPlank = isBurpeePlankValid(points: points)
        let hipY = averageY(points: points, joints: [.leftHip, .rightHip])
        let upwardBurst = hipY.map { currentY in
            if let burpeeLastHipY {
                return currentY - burpeeLastHipY > 0.025
            }
            return false
        } ?? false
        defer {
            if let hipY {
                burpeeLastHipY = hipY
            }
        }
        let elbowAngle = bestAngle(
            points: points,
            firstCandidates: [.leftShoulder, .rightShoulder],
            middleCandidates: [.leftElbow, .rightElbow],
            lastCandidates: [.leftWrist, .rightWrist]
        )
        let isPushUpLow = isPlank && (elbowAngle ?? 180) <= burpeePushUpDownThreshold
        let isJumpOrStand = isStanding && (upwardBurst || isJumpLike(points: points))

        switch burpeePhase {
        case .standing:
            if isStanding && upwardBurst {
                burpeePhase = .initialJump
            } else if isSquat {
                burpeePhase = .squat
            }
        case .initialJump:
            if isSquat {
                burpeePhase = .squat
            }
        case .squat:
            if isPlank {
                burpeePhase = .plank
            }
        case .plank:
            if isPushUpLow {
                burpeePhase = .pushUpDown
            }
        case .pushUpDown:
            if isSquat {
                burpeePhase = .returnSquat
            }
        case .returnSquat:
            if isJumpOrStand {
                repCount += 1
                burpeePhase = .finalJump
                print("BreakGateWorkout pose: rep counted (\(repCount))")
                return true
            }
        case .finalJump:
            if isSquat {
                burpeePhase = .squat
            } else if isStanding {
                burpeePhase = .standing
            }
        }

        return false
    }

    private func updateMountainClimberState(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> Bool {
        guard isMountainClimberBaseValid(points: points) else {
            mountainPhase = .waitingForAlternation
            return false
        }

        let leftDrive = kneeDriveSide(points: points, side: .left)
        let rightDrive = kneeDriveSide(points: points, side: .right)
        let driveSide: BodySide?
        if leftDrive && !rightDrive {
            driveSide = .left
        } else if rightDrive && !leftDrive {
            driveSide = .right
        } else {
            driveSide = nil
        }

        guard let driveSide else {
            mountainPhase = .plankReady
            return false
        }

        mountainPhase = driveSide == .left ? .leftKneeDrive : .rightKneeDrive

        if let lastMountainDriveSide, lastMountainDriveSide != driveSide {
            repCount += 1
            self.lastMountainDriveSide = driveSide
            print("BreakGateWorkout pose: rep counted (\(repCount))")
            return true
        }

        lastMountainDriveSide = driveSide
        return false
    }

    private func kneeDriveSide(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint], side: BodySide) -> Bool {
        let shoulder: VNHumanBodyPoseObservation.JointName = side == .left ? .leftShoulder : .rightShoulder
        let hip: VNHumanBodyPoseObservation.JointName = side == .left ? .leftHip : .rightHip
        let knee: VNHumanBodyPoseObservation.JointName = side == .left ? .leftKnee : .rightKnee
        let ankle: VNHumanBodyPoseObservation.JointName = side == .left ? .leftAnkle : .rightAnkle

        let hipAngle = bestAngle(
            points: points,
            firstCandidates: [shoulder],
            middleCandidates: [hip],
            lastCandidates: [knee]
        )

        if let hipAngle, hipAngle <= mountainClimberHipDriveThreshold {
            return true
        }

        guard let shoulderPoint = validPoint(points[shoulder]),
              let hipPoint = validPoint(points[hip]),
              let kneePoint = validPoint(points[knee]),
              let anklePoint = validPoint(points[ankle]) else {
            return false
        }

        let torsoLength = max(0.01, distance(shoulderPoint, hipPoint))
        let kneeToShoulder = distance(kneePoint, shoulderPoint)
        let ankleToShoulder = distance(anklePoint, shoulderPoint)
        return kneeToShoulder / torsoLength <= mountainClimberKneeToShoulderRatio
            || kneeToShoulder < ankleToShoulder * 0.78
    }

    private func isMountainClimberBaseValid(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> Bool {
        let leftLine = sideBodyLineAngle(points: points, side: .left)
        let rightLine = sideBodyLineAngle(points: points, side: .right)
        return [leftLine, rightLine].compactMap { $0 }.contains { $0 >= mountainClimberPlankThreshold }
    }

    private func isBurpeePlankValid(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> Bool {
        let leftLine = sideBodyLineAngle(points: points, side: .left)
        let rightLine = sideBodyLineAngle(points: points, side: .right)
        return [leftLine, rightLine].compactMap { $0 }.contains { $0 >= mountainClimberPlankThreshold }
    }

    private func sideBodyLineAngle(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint], side: BodySide) -> CGFloat? {
        let shoulder: VNHumanBodyPoseObservation.JointName = side == .left ? .leftShoulder : .rightShoulder
        let hip: VNHumanBodyPoseObservation.JointName = side == .left ? .leftHip : .rightHip
        let ankle: VNHumanBodyPoseObservation.JointName = side == .left ? .leftAnkle : .rightAnkle
        guard let shoulderPoint = validPoint(points[shoulder]),
              let hipPoint = validPoint(points[hip]),
              let anklePoint = validPoint(points[ankle]) else {
            return nil
        }
        return angle(first: shoulderPoint, middle: hipPoint, last: anklePoint)
    }

    private func isSquatLike(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> Bool {
        guard let kneeAngle = bestAngle(
            points: points,
            firstCandidates: [.leftHip, .rightHip],
            middleCandidates: [.leftKnee, .rightKnee],
            lastCandidates: [.leftAnkle, .rightAnkle]
        ) else {
            return false
        }

        return kneeAngle <= burpeeSquatThreshold
    }

    private func isJumpLike(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> Bool {
        guard let kneeAngle = bestAngle(
            points: points,
            firstCandidates: [.leftHip, .rightHip],
            middleCandidates: [.leftKnee, .rightKnee],
            lastCandidates: [.leftAnkle, .rightAnkle]
        ) else {
            return false
        }

        return kneeAngle >= squatKneeStraightThreshold
    }

    private func isTuckPlancheValid(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> Bool {
        guard
            let leftWrist = validPoint(points[.leftWrist]),
            let rightWrist = validPoint(points[.rightWrist]),
            let leftElbow = validPoint(points[.leftElbow]),
            let rightElbow = validPoint(points[.rightElbow]),
            let leftShoulder = validPoint(points[.leftShoulder]),
            let rightShoulder = validPoint(points[.rightShoulder])
        else {
            return false
        }

        let kneePoints = [points[.leftKnee], points[.rightKnee]].compactMap(validPoint)
        let anklePoints = [points[.leftAnkle], points[.rightAnkle]].compactMap(validPoint)
        guard !kneePoints.isEmpty, !anklePoints.isEmpty else { return false }

        let leftArmAngle = angle(first: leftShoulder, middle: leftElbow, last: leftWrist)
        let rightArmAngle = angle(first: rightShoulder, middle: rightElbow, last: rightWrist)
        guard leftArmAngle >= tuckPlancheArmStraightThreshold, rightArmAngle >= tuckPlancheArmStraightThreshold else {
            return false
        }

        let highestWristY = max(leftWrist.y, rightWrist.y)
        let averageElbowY = (leftElbow.y + rightElbow.y) / 2
        guard anklePoints.contains(where: { $0.y >= highestWristY && $0.y >= averageElbowY - 0.06 }) else {
            return false
        }

        let shoulderCenter = CGPoint(x: (leftShoulder.x + rightShoulder.x) / 2, y: (leftShoulder.y + rightShoulder.y) / 2)
        let torsoReference = max(0.01, distance(shoulderCenter, CGPoint(x: (leftElbow.x + rightElbow.x) / 2, y: (leftElbow.y + rightElbow.y) / 2)))
        return kneePoints.contains { distance($0, shoulderCenter) / torsoReference <= tuckPlancheKneeToTorsoRatio }
    }

    private func updatePikePushUpState(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> Bool {
        let top = pikeTopPoseResult(points: points)
        let bottom = pikeBottomPoseResult(points: points)

        if top.isValid {
            let metrics = top.metrics
            switch pikePhase {
            case .pikeReady, .pikeBroken:
                pikePhase = .pikeUp
                pikeTopHeadY = metrics?.headY
                pikeTopShoulderY = metrics?.shoulderY
                pikeTopElbowAngle = metrics?.elbowAngle
                return false
            case .pikeDown:
                guard pikeMovementWasMeaningful() else {
                    pikePhase = .pikeUp
                    pikeTopHeadY = metrics?.headY
                    pikeTopShoulderY = metrics?.shoulderY
                    pikeTopElbowAngle = metrics?.elbowAngle
                    return false
                }
                repCount += 1
                pikePhase = .pikeUp
                pikeTopHeadY = metrics?.headY
                pikeTopShoulderY = metrics?.shoulderY
                pikeTopElbowAngle = metrics?.elbowAngle
                return true
            case .pikeUp:
                pikeTopHeadY = metrics?.headY
                pikeTopShoulderY = metrics?.shoulderY
                pikeTopElbowAngle = metrics?.elbowAngle
                return false
            }
        }

        if bottom.isValid {
            pikeBottomHeadY = bottom.metrics?.headY
            pikeBottomShoulderY = bottom.metrics?.shoulderY
            pikeBottomElbowAngle = bottom.metrics?.elbowAngle
            pikePhase = .pikeDown
            return false
        }

        if pikeTopPoseResult(points: points, allowBentArms: true).isValid {
            pikePhase = .pikeReady
        } else {
            pikePhase = .pikeBroken
        }
        return false
    }

    private func pikeMovementWasMeaningful() -> Bool {
        guard
            let topHeadY = pikeTopHeadY,
            let topShoulderY = pikeTopShoulderY,
            let topElbowAngle = pikeTopElbowAngle,
            let bottomHeadY = pikeBottomHeadY,
            let bottomShoulderY = pikeBottomShoulderY,
            let bottomElbowAngle = pikeBottomElbowAngle
        else {
            return true
        }

        let scale = max(0.04, abs(topShoulderY - topHeadY) * 3)
        let headDrop = bottomHeadY - topHeadY
        let shoulderDrop = bottomShoulderY - topShoulderY
        let elbowChange = topElbowAngle - bottomElbowAngle
        return headDrop >= scale * 0.12 || shoulderDrop >= scale * 0.10 || elbowChange >= 25
    }

    private func pikeTopPoseResult(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint], allowBentArms: Bool = false) -> (isValid: Bool, debugState: String, metrics: PikePoseMetrics?) {
        guard let metrics = pikePoseMetrics(points: points) else {
            return (false, PikePushUpPhase.pikeBroken.rawValue, nil)
        }

        guard metrics.hipsHigh else {
            return (false, "pikeBroken hips", metrics)
        }
        guard metrics.legsStraight else {
            return (false, "pikeBroken legs", metrics)
        }
        guard metrics.invertedV else {
            return (false, PikePushUpPhase.pikeBroken.rawValue, metrics)
        }
        guard allowBentArms || metrics.armsStraight else {
            return (false, PikePushUpPhase.pikeDown.rawValue, metrics)
        }
        guard metrics.supportLooksGood else {
            return (false, PikePushUpPhase.pikeBroken.rawValue, metrics)
        }
        return (true, PikePushUpPhase.pikeUp.rawValue, metrics)
    }

    private func pikeBottomPoseResult(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> (isValid: Bool, debugState: String, metrics: PikePoseMetrics?) {
        guard let metrics = pikePoseMetrics(points: points) else {
            return (false, PikePushUpPhase.pikeBroken.rawValue, nil)
        }

        guard metrics.hipsHigh else {
            return (false, "pikeBroken hips", metrics)
        }
        guard metrics.legsStraight else {
            return (false, "pikeBroken legs", metrics)
        }
        guard metrics.elbowsBent else {
            return (false, PikePushUpPhase.pikeReady.rawValue, metrics)
        }

        let scale = max(0.04, metrics.torsoLength)
        let headNearHands = metrics.headY >= metrics.wristY - scale * 0.25
        let shouldersLowered = pikeTopShoulderY.map { metrics.shoulderY > $0 + scale * 0.08 } ?? true
        guard headNearHands || shouldersLowered else {
            return (false, PikePushUpPhase.pikeReady.rawValue, metrics)
        }
        return (true, PikePushUpPhase.pikeDown.rawValue, metrics)
    }

    private func pikePoseMetrics(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> PikePoseMetrics? {
        guard
            let shoulderCenter = averagePoint(points: points, joints: [.leftShoulder, .rightShoulder]),
            let hipCenter = averagePoint(points: points, joints: [.leftHip, .rightHip]),
            let wristCenter = averagePoint(points: points, joints: [.leftWrist, .rightWrist]),
            let kneeCenter = averagePoint(points: points, joints: [.leftKnee, .rightKnee])
        else {
            return nil
        }

        let ankleCenter = averagePoint(points: points, joints: [.leftAnkle, .rightAnkle]) ?? kneeCenter
        let headPoint = averagePoint(points: points, joints: [.nose, .neck]) ?? shoulderCenter
        let torsoLength = max(0.04, distance(shoulderCenter, hipCenter))
        let hipMargin = torsoLength * 0.15
        let hipsHigh = hipCenter.y < shoulderCenter.y - hipMargin
            && hipCenter.y < kneeCenter.y - hipMargin
            && hipCenter.y < ankleCenter.y - hipMargin * 0.6

        guard let elbowAngle = bestAngle(
            points: points,
            firstCandidates: [.leftShoulder, .rightShoulder],
            middleCandidates: [.leftElbow, .rightElbow],
            lastCandidates: [.leftWrist, .rightWrist]
        ) else {
            return nil
        }

        let kneeAngle = bestAngle(
            points: points,
            firstCandidates: [.leftHip, .rightHip],
            middleCandidates: [.leftKnee, .rightKnee],
            lastCandidates: [.leftAnkle, .rightAnkle]
        ) ?? 180

        let shoulderHipKnee = bestAngle(
            points: points,
            firstCandidates: [.leftShoulder, .rightShoulder],
            middleCandidates: [.leftHip, .rightHip],
            lastCandidates: [.leftKnee, .rightKnee]
        ) ?? angle(first: shoulderCenter, middle: hipCenter, last: kneeCenter)

        let wristShoulderDistance = abs(wristCenter.x - shoulderCenter.x)
        let supportLooksGood = wristCenter.y > shoulderCenter.y - torsoLength * 0.15
            && wristShoulderDistance / torsoLength <= 1.55

        return PikePoseMetrics(
            torsoLength: torsoLength,
            headY: headPoint.y,
            shoulderY: shoulderCenter.y,
            wristY: wristCenter.y,
            elbowAngle: elbowAngle,
            hipsHigh: hipsHigh,
            armsStraight: elbowAngle >= pikeExtendedThreshold,
            elbowsBent: (pikeDownElbowMin...pikeDownElbowMax).contains(elbowAngle),
            legsStraight: kneeAngle >= pikeExtendedThreshold,
            invertedV: (45...115).contains(shoulderHipKnee),
            supportLooksGood: supportLooksGood
        )
    }

    private func lSitPoseResult(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> (isValid: Bool, debugState: String) {
        guard
            let shoulderCenter = averagePoint(points: points, joints: [.leftShoulder, .rightShoulder]),
            let hipCenter = averagePoint(points: points, joints: [.leftHip, .rightHip])
        else {
            return (false, "lSitSetup")
        }

        if isPlankFormValid(points: points) {
            return (false, "lSitBroken support")
        }

        let torsoLength = max(0.04, distance(shoulderCenter, hipCenter))
        let torsoUprightEnough = shoulderCenter.y > hipCenter.y + 0.04
        guard torsoUprightEnough else {
            return (false, "lSitBroken support")
        }

        let wrists = [points[.leftWrist], points[.rightWrist]].compactMap(validPoint)
        guard !wrists.isEmpty, wrists.contains(where: { distance($0, hipCenter) / torsoLength <= 1.75 }) else {
            return (false, "lSitBroken support")
        }
        let averageWristY = wrists.map(\.y).reduce(0, +) / CGFloat(wrists.count)
        let hipPoints = [points[.leftHip], points[.rightHip]].compactMap(validPoint)
        let kneePoints = [points[.leftKnee], points[.rightKnee]].compactMap(validPoint)
        let anklePoints = [points[.leftAnkle], points[.rightAnkle]].compactMap(validPoint)
        guard !hipPoints.isEmpty, !kneePoints.isEmpty, !anklePoints.isEmpty else {
            return (false, "lSitSetup")
        }

        let averageHipY = hipPoints.map(\.y).reduce(0, +) / CGFloat(hipPoints.count)
        let averageKneeY = kneePoints.map(\.y).reduce(0, +) / CGFloat(kneePoints.count)
        let averageAnkleY = anklePoints.map(\.y).reduce(0, +) / CGFloat(anklePoints.count)
        let legLiftMargin = torsoLength * 0.12
        let kneesAboveWrists = averageKneeY < averageWristY - legLiftMargin
        let anklesAboveWrists = averageAnkleY < averageWristY - legLiftMargin
        let hipsNotSittingLow = averageHipY < averageWristY + torsoLength * 0.08
        guard hipsNotSittingLow else {
            return (false, "lSitBroken hips")
        }
        guard kneesAboveWrists, anklesAboveWrists else {
            return (false, "lSitBroken lift")
        }

        var straightArmCount = 0
        var straightLegCount = 0
        var lAngleCount = 0
        var legsForwardCount = 0

        let sides: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
            (.leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle),
            (.rightShoulder, .rightElbow, .rightWrist, .rightHip, .rightKnee, .rightAnkle)
        ]

        for side in sides {
            if
                let shoulder = validPoint(points[side.0]),
                let elbow = validPoint(points[side.1]),
                let wrist = validPoint(points[side.2]),
                angle(first: shoulder, middle: elbow, last: wrist) >= lSitArmStraightThreshold
            {
                straightArmCount += 1
            }

            guard
                let hip = validPoint(points[side.3]),
                let knee = validPoint(points[side.4]),
                let ankle = validPoint(points[side.5])
            else {
                continue
            }

            if angle(first: hip, middle: knee, last: ankle) >= lSitLegStraightThreshold {
                straightLegCount += 1
            }

            let hipAngle = angle(first: shoulderCenter, middle: hip, last: knee)
            if (60...120).contains(hipAngle) {
                lAngleCount += 1
            }

            if abs(ankle.x - hip.x) >= 0.10 || abs(knee.x - hip.x) >= 0.08 {
                legsForwardCount += 1
            }
        }

        guard straightArmCount >= 1 else { return (false, "lSitBroken support") }
        guard straightLegCount >= 1 else { return (false, "lSitBroken legs") }
        guard lAngleCount >= 1, legsForwardCount >= 1 else { return (false, "lSitSetup") }
        return (true, "lSitHold")
    }

    private func elbowLeverPoseResult(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint]) -> (isValid: Bool, debugState: String) {
        guard
            let shoulderCenter = averagePoint(points: points, joints: [.leftShoulder, .rightShoulder]),
            let hipCenter = averagePoint(points: points, joints: [.leftHip, .rightHip])
        else {
            return (false, "elbowLeverSetup")
        }

        let torsoLength = max(0.04, distance(shoulderCenter, hipCenter))
        var bentArmCount = 0
        var elbowSupportCount = 0
        var straightBodyCount = 0
        var bodyYValues: [CGFloat] = [shoulderCenter.y, hipCenter.y]

        let sides: [(VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName, VNHumanBodyPoseObservation.JointName)] = [
            (.leftShoulder, .leftElbow, .leftWrist, .leftHip, .leftKnee, .leftAnkle),
            (.rightShoulder, .rightElbow, .rightWrist, .rightHip, .rightKnee, .rightAnkle)
        ]

        for side in sides {
            if
                let shoulder = validPoint(points[side.0]),
                let elbow = validPoint(points[side.1]),
                let wrist = validPoint(points[side.2])
            {
                let armAngle = angle(first: shoulder, middle: elbow, last: wrist)
                if (55...120).contains(armAngle) {
                    bentArmCount += 1
                }

                if distance(elbow, hipCenter) / torsoLength <= 1.35 || distance(elbow, shoulderCenter) / torsoLength <= 1.2 {
                    elbowSupportCount += 1
                }
            }

            guard
                let shoulder = validPoint(points[side.0]),
                let hip = validPoint(points[side.3]),
                let knee = validPoint(points[side.4]),
                let ankle = validPoint(points[side.5])
            else {
                continue
            }

            let shoulderHipKnee = angle(first: shoulder, middle: hip, last: knee)
            let hipKneeAnkle = angle(first: hip, middle: knee, last: ankle)
            if shoulderHipKnee >= elbowLeverBodyStraightThreshold && hipKneeAnkle >= elbowLeverBodyStraightThreshold {
                straightBodyCount += 1
            }
            bodyYValues.append(contentsOf: [knee.y, ankle.y])
        }

        let ySpread = (bodyYValues.max() ?? 0) - (bodyYValues.min() ?? 0)
        guard straightBodyCount >= 1, ySpread <= 0.22 else {
            return (false, "elbowLeverBroken line")
        }
        guard bentArmCount >= 1, elbowSupportCount >= 1 else {
            return (false, "elbowLeverBroken support")
        }
        return (true, "elbowLeverHold")
    }

    private func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }

    private func averageY(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint], joints: [VNHumanBodyPoseObservation.JointName]) -> CGFloat? {
        let values = joints.compactMap { validPoint(points[$0])?.y }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / CGFloat(values.count)
    }

    private func averagePoint(points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint], joints: [VNHumanBodyPoseObservation.JointName]) -> CGPoint? {
        let values = joints.compactMap { validPoint(points[$0]) }
        guard !values.isEmpty else { return nil }
        let total = values.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        return CGPoint(x: total.x / CGFloat(values.count), y: total.y / CGFloat(values.count))
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
        debugState: String,
        confidence: Float,
        isPersonDetected: Bool,
        isStartingPoseDetected: Bool = false,
        posePoints: [PoseJointPoint],
        videoSize: CGSize
    ) {
        let update = PoseDetectionUpdate(
            repCount: repCount,
            workoutState: workoutState,
            debugState: debugState,
            confidence: confidence,
            isPersonDetected: isPersonDetected,
            isStartingPoseDetected: isStartingPoseDetected,
            posePoints: posePoints,
            videoSize: videoSize
        )
        diagnosticsPublishes += 1

        Task { @MainActor in
            onUpdate?(update)
        }
    }

    private func resetDiagnosticsCounters() {
        diagnosticsWindowStart = CACurrentMediaTime()
        diagnosticsFramesSeen = 0
        diagnosticsVisionRuns = 0
        diagnosticsPublishes = 0
    }

    private func reportDiagnosticsIfNeeded(now: CFTimeInterval) {
        let elapsed = now - diagnosticsWindowStart
        guard elapsed >= 1 else { return }

        DiagnosticLog.log(
            String(
                format: "camera pipeline frames=%.1f/s vision=%.1f/s publishes=%.1f/s mode=%@",
                Double(diagnosticsFramesSeen) / elapsed,
                Double(diagnosticsVisionRuns) / elapsed,
                Double(diagnosticsPublishes) / elapsed,
                mode.rawValue
            )
        )
        resetDiagnosticsCounters()
    }
}

private struct AbsMetrics {
    let torsoAngle: CGFloat
    let shoulderToKneeRatio: CGFloat
    let contractedAngle: CGFloat
    let looseContractedAngle: CGFloat
    let extendedAngle: CGFloat
    let looseExtendedAngle: CGFloat
    let contractedRatio: CGFloat
    let extendedRatio: CGFloat

    var isContracted: Bool {
        torsoAngle <= contractedAngle
            || (torsoAngle <= looseContractedAngle && shoulderToKneeRatio <= contractedRatio)
    }

    var isExtended: Bool {
        torsoAngle >= extendedAngle
            || (torsoAngle >= looseExtendedAngle && shoulderToKneeRatio >= extendedRatio)
    }
}

private struct PikePoseMetrics {
    let torsoLength: CGFloat
    let headY: CGFloat
    let shoulderY: CGFloat
    let wristY: CGFloat
    let elbowAngle: CGFloat
    let hipsHigh: Bool
    let armsStraight: Bool
    let elbowsBent: Bool
    let legsStraight: Bool
    let invertedV: Bool
    let supportLooksGood: Bool
}

private enum ExercisePosition {
    case waiting
    case up
    case down
}

private enum BurpeePhase: String {
    case standing = "burpeeStanding"
    case initialJump = "burpeeInitialJump"
    case squat = "burpeeSquat"
    case plank = "burpeePlank"
    case pushUpDown = "burpeePushUpDown"
    case returnSquat = "burpeeReturnSquat"
    case finalJump = "burpeeFinalJump"
}

private enum MountainClimberPhase: String {
    case plankReady = "plank ready"
    case leftKneeDrive = "left knee drive"
    case rightKneeDrive = "right knee drive"
    case waitingForAlternation = "waiting for alternation"
}

private enum PikePushUpPhase: String {
    case pikeReady = "pikeReady"
    case pikeDown = "pikeDown"
    case pikeUp = "pikeUp"
    case pikeBroken = "pikeBroken"
}

private enum BodySide {
    case left
    case right
}

private enum VoiceCommand {
    case startWorkout
    case exercise(ExerciseMode)
    case difficulty(WorkoutDifficulty)
    case emergencyUnlock
}

@MainActor
private final class VoiceCommandService {
    var onCommand: ((VoiceCommand, String) -> Void)?
    var onStatus: ((String?) -> Void)?
    var onTranscript: ((String) -> Void)?
    var onUnrecognized: (() -> Void)?

    private let audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var lastHandledText = ""
    private var lastHandledAt = Date.distantPast
    private var isRunning = false
    private var activeLanguage: AppLanguage = .english

    func start(language: AppLanguage) {
        if isRunning, activeLanguage != language {
            stop()
        }
        guard !isRunning else { return }
        activeLanguage = language
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            onStatus?("Voice: permission needed")
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            onStatus?("Voice: mic permission needed")
            return
        }

        let localeIdentifier = VoiceLanguageInfo.expectedLocaleIdentifier(for: language)
        speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) ?? SFSpeechRecognizer()
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            onStatus?("Voice: unavailable")
            return
        }

        do {
            try startRecognition(with: speechRecognizer)
            isRunning = true
            onStatus?(language == .russian ? "Голос: слушаю" : "Voice: listening")
        } catch {
            onStatus?("Voice: \(error.localizedDescription)")
            stop()
        }
    }

    func stop() {
        guard isRunning || recognitionTask != nil || audioEngine.isRunning else { return }

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        isRunning = false
        onStatus?(nil)
    }

    private func startRecognition(with recognizer: SFSpeechRecognizer) throws {
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            Task { @MainActor in
                if let result {
                    self.handle(transcript: result.bestTranscription.formattedString)
                }

                if error != nil || result?.isFinal == true {
                    self.restartSoon()
                }
            }
        }
    }

    private func restartSoon() {
        guard isRunning else { return }
        stop()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            self.start(language: self.activeLanguage)
        }
    }

    private func handle(transcript: String) {
        let normalized = transcript
            .lowercased()
            .replacingOccurrences(of: "ё", with: "е")

        guard normalized != lastHandledText || Date().timeIntervalSince(lastHandledAt) > 2 else { return }
        onTranscript?(transcript)
        guard let command = parseCommand(from: normalized) else {
            if !normalized.isEmpty {
                onStatus?(activeLanguage == .russian ? "Голос: команда не распознана" : "Voice: command not recognized")
                onUnrecognized?()
            }
            return
        }

        lastHandledText = normalized
        lastHandledAt = Date()
        onStatus?(activeLanguage == .russian ? "Голос: \(transcript)" : "Voice: \(transcript)")
        onCommand?(command, transcript)
    }

    private func parseCommand(from text: String) -> VoiceCommand? {
        if containsAny(text, ["emergency unlock", "unlock", "экстренно", "разблокировать"]) {
            return .emergencyUnlock
        }

        if containsAny(text, [
            "поехали",
            "погнали",
            "начали",
            "начинаем",
            "готов",
            "готова",
            "старт",
            "start",
            "go",
            "begin",
            "ready",
            "let's go",
            "lets go"
        ]) {
            return .startWorkout
        }

        let difficultyMatch = parseDifficultyCommandWithPosition(from: text)

        guard let exerciseAnchorPosition = latestKeywordPosition(in: text, keywords: [
            "change to",
            "switch to",
            "set to",
            "переключи на",
            "переключить на",
            "поменяй на",
            "поменять на",
            "смени на",
            "сменить на",
            "измени на",
            "изменить на",
            "перейди на",
            "перейти на"
        ]) else {
            return difficultyMatch?.command
        }

        let exerciseText = String(text.dropFirst(exerciseAnchorPosition))
        let exerciseMatches: [(VoiceCommand, Int?)] = [
            (.exercise(.plank), latestKeywordPosition(in: exerciseText, keywords: ["plank", "планка", "планку", "плэнк", "пленк"])),
            (.exercise(.squats), latestKeywordPosition(in: exerciseText, keywords: ["squat", "squats", "присед", "приседания", "сквот", "сквоты"])),
            (.exercise(.pushUps), latestKeywordPosition(in: exerciseText, keywords: ["push", "push-up", "pushups", "push ups", "отжим", "отжимания", "пушап", "пуш ап"])),
            (.exercise(.abs), latestKeywordPosition(in: exerciseText, keywords: ["abs", "sit-up", "situps", "sit ups", "press", "пресс"])),
            (.exercise(.burpees), latestKeywordPosition(in: exerciseText, keywords: ["burpees", "burpee", "берпи", "бёрпи"])),
            (.exercise(.mountainClimbers), latestKeywordPosition(in: exerciseText, keywords: ["mountain climbers", "climbers", "клаймберсы", "альпинист", "альпинисты"])),
            (.exercise(.tuckPlancheHold), latestKeywordPosition(in: exerciseText, keywords: ["tuck planche", "planche", "так планше", "так планч", "планше", "планч"])),
            (.exercise(.lSitHold), latestKeywordPosition(in: exerciseText, keywords: ["l sit", "l-sit", "lsit", "l sit hold", "уголок", "л сит", "эль сит"])),
            (.exercise(.elbowLeverHold), latestKeywordPosition(in: exerciseText, keywords: ["elbow lever", "elbow lever hold", "локтевой рычаг", "рычаг на локтях"])),
            (.exercise(.pikePushUps), latestKeywordPosition(in: exerciseText, keywords: ["pike pushups", "pike push-ups", "pike push up", "pike", "пайк отжимания", "пайк", "отжимания пайк"]))
        ]

        let exerciseMatch = exerciseMatches.compactMap({ command, position in
            position.map { (command: command, position: exerciseAnchorPosition + $0) }
        }).max(by: { $0.position < $1.position })

        switch (exerciseMatch, difficultyMatch) {
        case let (exercise?, difficulty?):
            return exercise.position > difficulty.position ? exercise.command : difficulty.command
        case let (exercise?, nil):
            return exercise.command
        case let (nil, difficulty?):
            return difficulty.command
        case (nil, nil):
            return nil
        }
    }

    private func parseDifficultyCommand(from text: String) -> VoiceCommand? {
        parseDifficultyCommandWithPosition(from: text)?.command
    }

    private func parseDifficultyCommandWithPosition(from text: String) -> (command: VoiceCommand, position: Int)? {
        guard latestKeywordPosition(in: text, keywords: ["difficulty", "сложность", "сложности", "уровень"]) != nil else { return nil }

        let difficultyMatches: [(VoiceCommand, Int?)] = [
            (.difficulty(.extremePlus), latestKeywordPosition(in: text, keywords: ["extreme plus", "extreme+", "экстрим плюс", "экстремальная плюс"])),
            (.difficulty(.extreme), latestKeywordPosition(in: text, keywords: ["extreme", "экстрим", "экстремальная"])),
            (.difficulty(.hard), latestKeywordPosition(in: text, keywords: ["hard", "сложный", "сложная", "тяжелый", "тяжелая"])),
            (.difficulty(.medium), latestKeywordPosition(in: text, keywords: ["medium", "normal", "средний", "средняя"])),
            (.difficulty(.light), latestKeywordPosition(in: text, keywords: ["light", "easy", "легкий", "легкая", "леегкая", "легко", "простая", "простой", "лайт"]))
        ]

        if let latestDifficulty = difficultyMatches.compactMap({ command, position in
            position.map { (command: command, position: $0) }
        }).max(by: { $0.1 < $1.1 }) {
            return latestDifficulty
        }

        return nil
    }

    private func containsAny(_ text: String, _ needles: [String]) -> Bool {
        needles.contains { text.contains($0) }
    }

    private func latestKeywordPosition(in text: String, keywords: [String]) -> Int? {
        keywords.compactMap { keyword in
            guard let range = text.range(of: keyword, options: [.caseInsensitive, .backwards]) else { return nil }
            return text.distance(from: text.startIndex, to: range.lowerBound)
        }.max()
    }
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
