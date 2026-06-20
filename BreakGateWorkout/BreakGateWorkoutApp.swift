//
//  BreakGateWorkoutApp.swift
//  BreakGateWorkout
//
//  Created by Артем Иванченко on 18.06.2026.
//

import AppKit
import ApplicationServices
@preconcurrency import AVFoundation
import Combine
import CoreGraphics
import IOKit
import ServiceManagement
import Speech
import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

enum DiagnosticLog {
    static let enabled = true

    static func log(_ message: String) {
        guard enabled else { return }
        print("BreakGateWorkout diagnostics: \(message)")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticLog.log("app launch")
        requestCameraPermissionEarly()
        requestAccessibilityPermissionIfMediaPauseEnabled()
        requestVoicePermissionsEarly()
        requestNotificationPermissionEarly()
        Task { @MainActor in
            SoundFeedbackService.shared.preload()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func requestCameraPermissionEarly() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            print("BreakGateWorkout camera permission: already authorized")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                print("BreakGateWorkout camera permission: early request granted=\(granted)")
            }
        case .denied, .restricted:
            print("BreakGateWorkout camera permission: denied or restricted")
        @unknown default:
            print("BreakGateWorkout camera permission: unknown status")
        }
    }

    private func requestAccessibilityPermissionIfMediaPauseEnabled() {
        guard UserDefaults.standard.bool(forKey: "BreakGateWorkout.autoPauseMediaOnGate") else {
            print("BreakGateWorkout accessibility permission: media pause disabled")
            return
        }

        let isTrusted = AXIsProcessTrusted()
        guard !isTrusted else {
            print("BreakGateWorkout accessibility permission: already trusted")
            return
        }

        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        let promptedTrust = AXIsProcessTrustedWithOptions(options)
        print("BreakGateWorkout accessibility permission: prompt requested, trusted=\(promptedTrust)")
    }

    private func requestVoicePermissionsEarly() {
        SFSpeechRecognizer.requestAuthorization { status in
            print("BreakGateWorkout speech permission: \(Self.speechAuthorizationDescription(status))")
        }

        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            print("BreakGateWorkout microphone permission: already authorized")
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                print("BreakGateWorkout microphone permission: early request granted=\(granted)")
            }
        case .denied, .restricted:
            print("BreakGateWorkout microphone permission: denied or restricted")
        @unknown default:
            print("BreakGateWorkout microphone permission: unknown status")
        }
    }

    private static func speechAuthorizationDescription(_ status: SFSpeechRecognizerAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "notDetermined"
        case .denied:
            return "denied"
        case .restricted:
            return "restricted"
        case .authorized:
            return "authorized"
        @unknown default:
            return "unknown"
        }
    }

    private func requestNotificationPermissionEarly() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                print("BreakGateWorkout notifications permission error: \(error.localizedDescription)")
            } else {
                print("BreakGateWorkout notifications permission granted=\(granted)")
            }
        }
    }
}

@main
struct BreakGateWorkoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var runtime = AppRuntime()

    var body: some Scene {
        MenuBarExtra {
            MenuBarControlView(monitor: runtime.monitor, stats: runtime.stats, settings: runtime.settings)
        } label: {
            MenuBarStatusLabel(state: runtime.statusIconState)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppRuntime: ObservableObject {
    enum StatusIconState: Equatable {
        case idle
        case active
    }

    let monitor = BreakGateMonitor()
    let stats = WorkoutStats()
    let settings = WorkoutSettingsStore()

    @Published private(set) var statusIconState: StatusIconState = .idle

    private var cancellables: Set<AnyCancellable> = []

    init() {
        DiagnosticLog.log("AppRuntime started")
        startMonitor()
        subscribeToGateState()
        subscribeToSettings()
    }

    private func startMonitor() {
        monitor.start()
        DiagnosticLog.log("monitor started")
        monitor.setScoringSensitivity(settings.scoringSensitivity)
        applyGateWarningSettings(
            delay: settings.gateWarningDelay,
            secondaryReminder: settings.secondaryGateReminder,
            language: settings.appLanguage
        )
    }

    private func subscribeToGateState() {
        monitor.$gateActive
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] isActive in
                Task { @MainActor in
                    self?.handleGateActiveChanged(isActive)
                }
            }
            .store(in: &cancellables)
    }

    private func subscribeToSettings() {
        settings.$scoringSensitivity
            .removeDuplicates()
            .sink { [weak self] sensitivity in
                Task { @MainActor in
                    self?.monitor.setScoringSensitivity(sensitivity)
                }
            }
            .store(in: &cancellables)

        settings.$gateWarningDelay
            .removeDuplicates()
            .sink { [weak self] delay in
                Task { @MainActor in
                    guard let self else { return }
                    self.applyGateWarningSettings(
                        delay: delay,
                        secondaryReminder: self.settings.secondaryGateReminder,
                        language: self.settings.appLanguage
                    )
                }
            }
            .store(in: &cancellables)

        settings.$secondaryGateReminder
            .removeDuplicates()
            .sink { [weak self] reminder in
                Task { @MainActor in
                    guard let self else { return }
                    self.applyGateWarningSettings(
                        delay: self.settings.gateWarningDelay,
                        secondaryReminder: reminder,
                        language: self.settings.appLanguage
                    )
                }
            }
            .store(in: &cancellables)

        settings.$appLanguage
            .removeDuplicates()
            .sink { [weak self] language in
                Task { @MainActor in
                    guard let self else { return }
                    self.applyGateWarningSettings(
                        delay: self.settings.gateWarningDelay,
                        secondaryReminder: self.settings.secondaryGateReminder,
                        language: language
                    )
                }
            }
            .store(in: &cancellables)
    }

    private func handleGateActiveChanged(_ isActive: Bool) {
        DiagnosticLog.log("gateActive changed: \(isActive)")
        setStatusIconState(isActive ? .active : .idle)

        if isActive {
            DiagnosticLog.log("showGate requested")
            SoftGateWindowController.shared.showGate(monitor: monitor, stats: stats, settings: settings)
        } else {
            DiagnosticLog.log("closeGate requested")
            SoftGateWindowController.shared.closeGate()
        }
    }

    private func setStatusIconState(_ state: StatusIconState) {
        guard statusIconState != state else { return }
        statusIconState = state
        DiagnosticLog.log("statusIconState changed: \(state.diagnosticName)")
    }

    private func applyGateWarningSettings(
        delay: GateWarningDelay,
        secondaryReminder: GateSecondaryReminder,
        language: AppLanguage
    ) {
        monitor.setGateWarningSettings(
            delay: delay,
            secondaryReminder: secondaryReminder,
            language: language
        )
    }
}

private extension AppRuntime.StatusIconState {
    var diagnosticName: String {
        switch self {
        case .idle: "idle"
        case .active: "active"
        }
    }
}

private enum MenuBarIconCache {
    static let idle = makeIcon(systemName: "figure.run")
    static let active = makeIcon(systemName: "figure.strengthtraining.traditional")

    static func image(for state: AppRuntime.StatusIconState) -> NSImage {
        switch state {
        case .idle: idle
        case .active: active
        }
    }

    private static func makeIcon(systemName: String) -> NSImage {
        let image = NSImage(systemSymbolName: systemName, accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 18, height: 18))
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}

private struct MenuBarStatusLabel: View {
    let state: AppRuntime.StatusIconState

    var body: some View {
        Image(nsImage: MenuBarIconCache.image(for: state))
    }
}

private struct MenuBarControlView: View {
    private enum Page {
        case main
        case settings
        case statistics
        case rewards
        case configure
        case about
    }

    @ObservedObject var monitor: BreakGateMonitor
    @ObservedObject var stats: WorkoutStats
    @ObservedObject var settings: WorkoutSettingsStore
    @State private var draftLanguage: AppLanguage
    @State private var draftVoiceControlEnabled: Bool
    @State private var page: Page = .main
    @State private var pageOpacity: Double = 1
    @State private var resetToMainPageTask: Task<Void, Never>?
    @State private var showSFXDetails = false

    private var language: AppLanguage { draftLanguage }

    init(monitor: BreakGateMonitor, stats: WorkoutStats, settings: WorkoutSettingsStore) {
        self.monitor = monitor
        self.stats = stats
        self.settings = settings
        _draftLanguage = State(initialValue: settings.appLanguage)
        _draftVoiceControlEnabled = State(initialValue: settings.isVoiceControlEnabled)
    }

    var body: some View {
        Group {
            if monitor.gateActive {
                activeGateMenu
            } else {
                pageContent
            }
        }
        .id(menuContentID)
        .padding(14)
        .frame(width: menuOuterWidth, height: menuHeight, alignment: .topLeading)
        .background(Color.black.opacity(0.20))
        .onAppear {
            cancelPendingMenuReset()
        }
        .onDisappear {
            scheduleMenuResetIfNeeded()
        }
        .onReceive(settings.$appLanguage.removeDuplicates()) { language in
            draftLanguage = language
        }
        .onReceive(settings.$isVoiceControlEnabled.removeDuplicates()) { isEnabled in
            draftVoiceControlEnabled = isEnabled
        }
    }

    private var menuContentID: String {
        monitor.gateActive ? "gate-active-menu" : "regular-menu-\(page)"
    }

    private var menuOuterWidth: CGFloat {
        if monitor.gateActive {
            return 430
        }

        switch page {
        case .configure:
            return 620
        case .about:
            return 520
        default:
            return 430
        }
    }

    private var menuHeight: CGFloat? {
        if monitor.gateActive {
            return activeGateMenuHeight
        }

        switch page {
        case .configure:
            return 720
        case .about:
            return 620
        default:
            return nil
        }
    }

    private var activeGateMenuHeight: CGFloat {
        170 + CGFloat(max(0, estimatedPlanSummaryLines - 1)) * 18
    }

    private var estimatedPlanSummaryLines: Int {
        let summaryLength = settings.plan.summary(language).count
        let stepCount = settings.plan.steps.count
        if stepCount <= 1 && summaryLength <= 34 {
            return 1
        }
        if stepCount <= 3 && summaryLength <= 74 {
            return 2
        }
        return min(4, max(2, Int(ceil(Double(summaryLength) / 52.0))))
    }

    @ViewBuilder
    private var pageContent: some View {
        rawPageContent
            .id(page)
            .opacity(pageOpacity)
            .animation(.easeInOut(duration: 0.14), value: pageOpacity)
    }

    @ViewBuilder
    private var rawPageContent: some View {
        switch page {
        case .main:
            normalMenu
        case .settings:
            menuPage(title: language == .russian ? "Настройки" : "Settings") {
                settingsPage
            }
        case .statistics:
            menuPage(title: L.t(.statistics, language)) {
                statisticsPage
            }
        case .rewards:
            menuPage(title: language == .russian ? "Бонусы" : "Rewards") {
                rewardsPage
            }
        case .configure:
            menuPage(title: L.t(.workoutPlan, language)) {
                WorkoutConfigurationView(settings: settings, embeddedInMenu: true) {
                    navigate(to: .main)
                }
            }
        case .about:
            menuPage(title: L.t(.about, language)) {
                AboutBreakGateView(settings: settings, embeddedInMenu: true)
            }
        }
    }

    private func menuPage<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    navigate(to: .main)
                } label: {
                    Label(language == .russian ? "Назад" : "Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)

                Spacer()

                Text(title)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 2)

            content()
        }
    }

    private func navigate(to newPage: Page) {
        guard page != newPage else { return }
        cancelPendingMenuReset()

        withAnimation(.easeInOut(duration: 0.12)) {
            pageOpacity = 0
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
            page = newPage
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                withAnimation(.easeInOut(duration: 0.16)) {
                    pageOpacity = 1
                }
            }
        }
    }

    private func scheduleMenuResetIfNeeded() {
        guard page != .main else { return }

        resetToMainPageTask?.cancel()
        resetToMainPageTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                page = .main
                pageOpacity = 1
                resetToMainPageTask = nil
            }
        }
    }

    private func cancelPendingMenuReset() {
        resetToMainPageTask?.cancel()
        resetToMainPageTask = nil
    }

    private var normalMenu: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerCard
            scoreCards
            currentPlanCard
            actionGroups
            utilityActions
        }
    }

    private var activeGateMenu: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Label(L.t(.gateActive, language), systemImage: "lock.open.fill")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.orange)

                Text(language == .russian ? "Заверши тренировку в окне гейта, чтобы продолжить." : "Complete the workout in the gate window to continue.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Text(settings.plan.summary(language))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .menuPanelCard(accent: .orange)

            Button {
                SoftGateWindowController.shared.showGate(monitor: monitor, stats: stats, settings: settings)
            } label: {
                Label(language == .russian ? "Показать окно гейта" : "Open Gate Window", systemImage: "rectangle.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MenuActionButtonStyle(kind: .warning))

            Text(language == .russian ? "Выход и сброс статистики недоступны, пока гейт активен." : "Quit and reset actions are unavailable while the gate is active.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BreakGate")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(monitor.gateActive ? L.t(.gateActiveSubtitle, language) : L.t(.readySubtitle, language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Label(monitor.gateActive ? L.t(.gateActive, language) : L.t(.gateIdle, language), systemImage: monitor.gateActive ? "lock.open.fill" : "figure.run")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(monitor.gateActive ? .orange : .green)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background((monitor.gateActive ? Color.orange : Color.green).opacity(0.14), in: Capsule())
            }

            MenuToggleCard(
                title: L.t(.monitoring, language),
                subtitle: monitor.isMonitoringEnabled ? L.t(.on, language) : L.t(.off, language),
                systemImage: "waveform.path.ecg",
                color: .green,
                titleFontSize: 15,
                isOn: Binding(
                    get: { monitor.isMonitoringEnabled },
                    set: { isEnabled in
                        Task { @MainActor in
                            monitor.setMonitoringEnabled(isEnabled)
                        }
                    }
                )
            )

            Button {
                navigate(to: .settings)
            } label: {
                Label(language == .russian ? "Настройки" : "Settings", systemImage: "gearshape.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MenuActionButtonStyle(kind: .secondary))
        }
        .menuPanelCard()
    }

    private var settingsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker(L.t(.language, language), selection: Binding(
                get: { draftLanguage },
                set: { newLanguage in
                    draftLanguage = newLanguage
                    settings.setAppLanguageSafely(newLanguage)
                }
            )) {
                ForEach(AppLanguage.allCases) { appLanguage in
                    Text(appLanguage.title).tag(appLanguage)
                }
            }
            .pickerStyle(.segmented)

            Toggle(L.t(.voice, language), isOn: Binding(
                get: { draftVoiceControlEnabled },
                set: { isEnabled in
                    draftVoiceControlEnabled = isEnabled
                    settings.setVoiceControlEnabledSafely(isEnabled)
                }
            ))

            if draftVoiceControlEnabled {
                Label(
                    language == .russian
                        ? "Микрофон слушает: \(VoiceLanguageInfo.expectedLanguageName(for: language))"
                        : "Microphone listens: \(VoiceLanguageInfo.expectedLanguageName(for: language))",
                    systemImage: "waveform"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.72))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(language == .russian ? "Имя для статистики" : "Stats display name")
                    .font(.headline)
                TextField(language == .russian ? "Например, Артем" : "For example, Alex", text: Binding(
                    get: { settings.userDisplayName },
                    set: { settings.setUserDisplayNameSafely($0) }
                ))
                .textFieldStyle(.roundedBorder)
            }

            Toggle(L.t(.runOnStartup, language), isOn: Binding(
                get: { settings.runOnStartupEnabled },
                set: { settings.setLaunchAtLoginEnabledSafely($0) }
            ))

            Toggle(language == .russian ? "Пауза медиа при гейте" : "Pause media on gate", isOn: Binding(
                get: { settings.autoPauseMediaOnGate },
                set: { settings.setAutoPauseMediaOnGateSafely($0) }
            ))

            Text(language == .russian ? "Если включено, для media play/pause нужен Accessibility доступ." : "When enabled, media play/pause needs Accessibility permission.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider().opacity(0.35)

            gateSettingsSection

            Divider().opacity(0.35)

            Text(language == .russian ? "Чувствительность скоринга" : "Scoring Sensitivity")
                .font(.headline)
            Text(language == .russian ? "Как быстро растет давление, пока ты работаешь без перерыва." : "How quickly pressure builds while you keep working without a break.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker(language == .russian ? "Чувствительность" : "Sensitivity", selection: Binding(
                get: { settings.scoringSensitivity },
                set: { settings.setScoringSensitivitySafely($0) }
            )) {
                ForEach(ScoringSensitivity.allCases) { sensitivity in
                    Text("\(sensitivity.title(language)) (\(sensitivity.multiplier, specifier: "%.1f")x)").tag(sensitivity)
                }
            }
            .pickerStyle(.menu)
        }
        .menuPanelCard()
    }

    private var gateSettingsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(language == .russian ? "Настройки гейта" : "Gate Settings")
                .font(.headline)

            Picker(language == .russian ? "Предупреждение перед гейтом" : "Gate warning delay", selection: Binding(
                get: { settings.gateWarningDelay },
                set: { settings.setGateWarningDelaySafely($0) }
            )) {
                ForEach(GateWarningDelay.allCases) { delay in
                    Text(delay.title(language)).tag(delay)
                }
            }
            .pickerStyle(.menu)

            Picker(language == .russian ? "Второе напоминание" : "Secondary reminder", selection: Binding(
                get: { settings.secondaryGateReminder },
                set: { settings.setSecondaryGateReminderSafely($0) }
            )) {
                ForEach(GateSecondaryReminder.allCases) { reminder in
                    Text(reminder.title(language)).tag(reminder)
                }
            }
            .pickerStyle(.menu)
            .disabled(!settings.gateWarningDelay.allowsSecondaryReminder)
            .help(settings.gateWarningDelay.allowsSecondaryReminder ? "" : (language == .russian ? "Работает только если первое предупреждение за 3 минуты или больше." : "Works only when the first warning is 3 minutes or more."))

            Picker(language == .russian ? "Ожидание исходной позы" : "Starting pose wait", selection: Binding(
                get: { settings.startPoseWaitDuration },
                set: { settings.setStartPoseWaitDurationSafely($0) }
            )) {
                ForEach(StartPoseWaitDuration.allCases) { duration in
                    Text(duration.title(language)).tag(duration)
                }
            }
            .pickerStyle(.menu)

            Toggle(language == .russian ? "Показывать экспериментальные упражнения" : "Show experimental exercises", isOn: Binding(
                get: { settings.showExperimentalExercises },
                set: { settings.setShowExperimentalExercisesSafely($0) }
            ))

            Toggle(language == .russian ? "Музыка гейта" : "Gate music", isOn: Binding(
                get: { settings.gateMusicEnabled },
                set: { settings.setGateMusicEnabledSafely($0) }
            ))

            Toggle("SFX", isOn: Binding(
                get: { settings.sfxEnabled },
                set: { settings.setSFXEnabledSafely($0) }
            ))

            Button {
                withAnimation(.easeInOut(duration: 0.16)) {
                    showSFXDetails.toggle()
                }
            } label: {
                Label(
                    language == .russian ? "Отдельные звуки" : "Individual sounds",
                    systemImage: showSFXDetails ? "chevron.down.circle" : "chevron.right.circle"
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .disabled(!settings.sfxEnabled)

            if showSFXDetails {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(SoundEffectKind.allCases) { effect in
                        Toggle(effect.title(language), isOn: Binding(
                            get: { settings.sfxEnabled && settings.isSoundEffectEnabled(effect) },
                            set: { settings.setSoundEffect(effect, enabled: $0) }
                        ))
                        .disabled(!settings.sfxEnabled)
                    }
                }
                .padding(.leading, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var scoreCards: some View {
        HStack(spacing: 8) {
            MenuMetricCard(
                title: L.t(.score, language),
                value: "\(Int(monitor.activityScore.rounded()))",
                subtitle: L.t(.activityLoad, language),
                systemImage: "gauge.with.dots.needle.67percent",
                color: pressureColor
            )
            MenuMetricCard(
                title: L.t(.pressure, language),
                value: monitor.breakPressure.title(language),
                subtitle: L.t(.triggerRisk, language),
                systemImage: "flame.fill",
                color: pressureColor
            )
            MenuMetricCard(
                title: L.t(.multiplier, language),
                value: "\(Int(monitor.currentScoreMultiplier * 100))%",
                subtitle: monitor.rewardRemainingDescription == "None" ? L.t(.normalScoring, language) : "\(monitor.rewardRemainingDescription) \(L.t(.left, language))",
                systemImage: "timer",
                color: monitor.currentScoreMultiplier < 1 ? .purple : .blue
            )
        }
    }

    private var currentPlanCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L.t(.currentPlan, language))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                Spacer()
                Text(settings.plan.difficulty.title(language))
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(difficultyColor.opacity(0.85), in: Capsule())
            }

            Text(settings.plan.summary(language))
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            Text(rewardSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("\(language == .russian ? "Чувствительность" : "Sensitivity"): \(settings.scoringSensitivity.title(language))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .menuPanelCard(accent: difficultyColor)
    }

    private var statsGrid: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(L.t(.statistics, language))
                .font(.system(size: 15, weight: .semibold, design: .rounded))

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                MenuMetricCard(title: L.t(.workouts, language), value: "\(stats.totalWorkoutsCompleted)", subtitle: L.t(.completed, language), systemImage: "checkmark.seal.fill", color: .blue)
                MenuMetricCard(title: ExerciseMode.pushUps.title(language), value: "\(stats.totalPushUps)", subtitle: L.t(.totalReps, language), systemImage: ExerciseMode.pushUps.systemImage, color: .green)
                MenuMetricCard(title: ExerciseMode.squats.title(language), value: "\(stats.totalSquats)", subtitle: L.t(.totalReps, language), systemImage: ExerciseMode.squats.systemImage, color: .orange)
                MenuMetricCard(title: ExerciseMode.abs.title(language), value: "\(stats.totalSitUps)", subtitle: L.t(.totalReps, language), systemImage: ExerciseMode.abs.systemImage, color: .purple)
                MenuMetricCard(title: ExerciseMode.plank.title(language), value: "\(stats.totalPlankSeconds)", subtitle: L.t(.seconds, language), systemImage: ExerciseMode.plank.systemImage, color: .cyan)
                MenuMetricCard(title: ExerciseMode.burpees.title(language), value: "\(stats.totalBurpees)", subtitle: L.t(.totalReps, language), systemImage: ExerciseMode.burpees.systemImage, color: .pink)
                MenuMetricCard(title: ExerciseMode.mountainClimbers.title(language), value: "\(stats.totalMountainClimbers)", subtitle: L.t(.totalReps, language), systemImage: ExerciseMode.mountainClimbers.systemImage, color: .mint)
                MenuMetricCard(title: ExerciseMode.lSitHold.title(language), value: "\(stats.totalLSitSeconds)", subtitle: L.t(.seconds, language), systemImage: ExerciseMode.lSitHold.systemImage, color: .indigo)
                MenuMetricCard(title: ExerciseMode.elbowLeverHold.title(language), value: "\(stats.totalElbowLeverSeconds)", subtitle: L.t(.seconds, language), systemImage: ExerciseMode.elbowLeverHold.systemImage, color: .teal)
                MenuMetricCard(title: L.t(.last, language), value: stats.lastWorkoutDescription(language), subtitle: L.t(.workout, language), systemImage: "calendar", color: .secondary)
            }
        }
        .menuPanelCard()
    }

    private var statisticsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            statsGrid

            HStack(spacing: 7) {
                Button(language == .russian ? "Поделиться" : "Share") {
                    StatisticsShareService.presentShareOptions(stats: stats, settings: settings)
                }
                .buttonStyle(MenuActionButtonStyle(kind: .primary))
                Button(L.t(.resetScore, language)) { monitor.resetScore() }
                    .buttonStyle(MenuActionButtonStyle(kind: .utility))
                Button(L.t(.resetAllStats, language)) { stats.resetAll() }
                    .buttonStyle(MenuActionButtonStyle(kind: .destructive))
            }
        }
    }

    private var rewardsPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(language == .russian ? "Бонус замедляет накопление новых очков после тренировки. Снижение очков при простое работает как обычно." : "Rewards slow down new score buildup after a workout. Idle score reduction still works normally.")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach([WorkoutDifficulty.medium, .hard, .extreme, .extremePlus], id: \.self) { difficulty in
                RewardSettingEditor(
                    difficulty: difficulty,
                    setting: Binding(
                        get: { settings.rewardSettings[difficulty] ?? WorkoutSettingsStore.defaultRewardSettings()[difficulty]! },
                        set: { newSetting in
                            var updated = settings.rewardSettings
                            updated[difficulty] = newSetting
                            settings.rewardSettings = updated
                        }
                    ),
                    language: language
                )
            }
        }
        .menuPanelCard()
    }

    private var actionGroups: some View {
        VStack(spacing: 7) {
            Button {
                monitor.startGate(reason: .manual)
            } label: {
                Label(L.t(.startWorkoutNow, language), systemImage: "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MenuActionButtonStyle(kind: .primary))

            HStack(spacing: 7) {
                Button {
                    monitor.startGate(reason: .manual)
                } label: {
                    Label(L.t(.openGate, language), systemImage: "rectangle.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MenuActionButtonStyle(kind: .secondary))

                Button {
                    navigate(to: .configure)
                } label: {
                    Label(L.t(.configure, language), systemImage: "slider.horizontal.3")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MenuActionButtonStyle(kind: .secondary))
            }

            HStack(spacing: 7) {
                Button {
                    navigate(to: .statistics)
                } label: {
                    Label(L.t(.statistics, language), systemImage: "chart.bar.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MenuActionButtonStyle(kind: .secondary))

                Button {
                    navigate(to: .rewards)
                } label: {
                    Label(language == .russian ? "Бонусы" : "Rewards", systemImage: "timer")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(MenuActionButtonStyle(kind: .secondary))
            }

            Button {
                navigate(to: .about)
            } label: {
                Label(L.t(.about, language), systemImage: "info.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MenuActionButtonStyle(kind: .secondary))

            Button {
                monitor.resetCurrentGate()
            } label: {
                Label(L.t(.resetCurrentGate, language), systemImage: "exclamationmark.triangle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(MenuActionButtonStyle(kind: .warning))
        }
    }

    private var utilityActions: some View {
        HStack(spacing: 7) {
            Spacer()

            Button(L.t(.quit, language)) { NSApplication.shared.terminate(nil) }
                .buttonStyle(MenuActionButtonStyle(kind: .destructive))
        }
    }

    private var pressureColor: Color {
        switch monitor.breakPressure {
        case .low: .green
        case .medium: .yellow
        case .high: .orange
        case .critical: .red
        }
    }

    private var difficultyColor: Color {
        switch settings.plan.difficulty {
        case .light: .green
        case .medium: .blue
        case .hard: .orange
        case .extreme: .red
        case .extremePlus: .purple
        }
    }

    private var rewardSummary: String {
        let setting = settings.rewardSetting(for: settings.plan.difficulty)
        guard settings.plan.difficulty != .light, setting.minutes > 0 else {
            return L.t(.rewardNone, language)
        }

        return String(format: L.t(.rewardScoring, language), "\(Int(setting.multiplier * 100))%", setting.minutes)
    }
}

private struct MenuMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let systemImage: String
    let color: Color

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 3)
                .fill(color)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: systemImage)
                        .foregroundStyle(color)
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                Text(value)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)

                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(color.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct StatisticsShareSnapshot {
    let language: AppLanguage
    let displayName: String
    let generatedAt: Date
    let totalWorkouts: Int
    let totalPushUps: Int
    let totalSquats: Int
    let totalSitUps: Int
    let totalPlankSeconds: Int
    let totalBurpees: Int
    let totalMountainClimbers: Int
    let totalLSitSeconds: Int
    let totalElbowLeverSeconds: Int
    let lastWorkoutDescription: String
}

private struct StatisticsPNGExport {
    let data: Data
    let pixelSize: CGSize
}

@MainActor
private enum StatisticsShareService {
    private static let imageSize = CGSize(width: 900, height: 1180)
    private static let exportScale: CGFloat = 3
    private static var shareAnchorWindow: NSWindow?
    private static var temporaryShareURLs: [URL] = []

    static func presentShareOptions(stats: WorkoutStats, settings: WorkoutSettingsStore) {
        let language = settings.appLanguage
        let trimmedName = settings.userDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let snapshot = StatisticsShareSnapshot(
            language: language,
            displayName: trimmedName.isEmpty ? (language == .russian ? "Спортсмен BreakGate" : "BreakGate athlete") : trimmedName,
            generatedAt: Date(),
            totalWorkouts: stats.totalWorkoutsCompleted,
            totalPushUps: stats.totalPushUps,
            totalSquats: stats.totalSquats,
            totalSitUps: stats.totalSitUps,
            totalPlankSeconds: stats.totalPlankSeconds,
            totalBurpees: stats.totalBurpees,
            totalMountainClimbers: stats.totalMountainClimbers,
            totalLSitSeconds: stats.totalLSitSeconds,
            totalElbowLeverSeconds: stats.totalElbowLeverSeconds,
            lastWorkoutDescription: stats.lastWorkoutDescription(language)
        )

        guard let export = renderPNGExport(snapshot: snapshot) else {
            showError(title: language == .russian ? "Не удалось экспортировать изображение" : "Could not export image", language: language)
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = language == .russian ? "Поделиться статистикой" : "Share statistics"
        alert.informativeText = language == .russian ? "Что сделать с красивой PNG-карточкой?" : "What should we do with the PNG stats card?"
        alert.addButton(withTitle: language == .russian ? "Поделиться..." : "Share...")
        alert.addButton(withTitle: language == .russian ? "Сохранить статистику" : "Save Statistics")
        alert.addButton(withTitle: language == .russian ? "Скопировать" : "Copy Image")
        alert.addButton(withTitle: language == .russian ? "Отмена" : "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            showSharePicker(export: export, language: language)
        case .alertSecondButtonReturn:
            save(export: export, language: language)
        case .alertThirdButtonReturn:
            copy(export: export, language: language)
        default:
            break
        }
    }

    private static func renderPNGExport(snapshot: StatisticsShareSnapshot) -> StatisticsPNGExport? {
        let view = StatisticsShareCard(snapshot: snapshot)
            .frame(width: imageSize.width, height: imageSize.height)

        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(imageSize)
        renderer.scale = exportScale
        renderer.colorMode = .nonLinear

        guard let cgImage = renderer.cgImage else { return nil }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        return StatisticsPNGExport(data: data, pixelSize: CGSize(width: cgImage.width, height: cgImage.height))
    }

    private static func showSharePicker(export: StatisticsPNGExport, language: AppLanguage) {
        do {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("BreakGateWorkout-stats-\(UUID().uuidString)")
                .appendingPathExtension("png")
            try export.data.write(to: url, options: .atomic)
            temporaryShareURLs.append(url)

            NSApp.activate(ignoringOtherApps: true)
            let anchorWindow = makeShareAnchorWindow()
            guard let contentView = anchorWindow.contentView else {
                showError(title: language == .russian ? "Не удалось экспортировать изображение" : "Could not export image", language: language)
                return
            }

            let picker = NSSharingServicePicker(items: [url])
            picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)

            Task { @MainActor in
                try? await Task.sleep(for: .seconds(90))
                shareAnchorWindow?.orderOut(nil)
                shareAnchorWindow = nil
                temporaryShareURLs.removeAll { $0 == url }
                try? FileManager.default.removeItem(at: url)
            }
        } catch {
            showError(title: language == .russian ? "Не удалось экспортировать изображение" : "Could not export image", message: error.localizedDescription, language: language)
        }
    }

    private static func save(export: StatisticsPNGExport, language: AppLanguage) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "BreakGateWorkout-stats.png"
        panel.title = language == .russian ? "Сохранить статистику" : "Save Statistics"

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try export.data.write(to: url, options: .atomic)
        } catch {
            showError(title: language == .russian ? "Не удалось сохранить файл" : "Could not save file", message: error.localizedDescription, language: language)
        }
    }

    private static func copy(export: StatisticsPNGExport, language: AppLanguage) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.png], owner: nil)
        guard pasteboard.setData(export.data, forType: .png) else {
            showError(title: language == .russian ? "Не удалось экспортировать изображение" : "Could not export image", language: language)
            return
        }
    }

    private static func makeShareAnchorWindow() -> NSWindow {
        if let shareAnchorWindow {
            shareAnchorWindow.makeKeyAndOrderFront(nil)
            return shareAnchorWindow
        }

        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1, height: 1)
        let anchorWindow = NSWindow(
            contentRect: NSRect(x: screenFrame.midX, y: screenFrame.midY, width: 1, height: 1),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        anchorWindow.isOpaque = false
        anchorWindow.backgroundColor = .clear
        anchorWindow.level = .floating
        anchorWindow.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        anchorWindow.orderFrontRegardless()
        shareAnchorWindow = anchorWindow
        return anchorWindow
    }

    private static func showError(title: String, message: String? = nil, language: AppLanguage) {
        NSSound.beep()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message ?? (language == .russian ? "Попробуй еще раз." : "Please try again.")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

private struct StatisticsShareCard: View {
    let snapshot: StatisticsShareSnapshot

    private var language: AppLanguage { snapshot.language }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.05, blue: 0.07),
                    Color(red: 0.06, green: 0.12, blue: 0.11),
                    Color(red: 0.03, green: 0.04, blue: 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("BreakGateWorkout")
                        .font(.system(size: 48, weight: .black, design: .rounded))
                    Text(snapshot.displayName)
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.green)
                    Text(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.62))
                }

                HStack(spacing: 18) {
                    ShareHeroMetric(
                        title: L.t(.workouts, language),
                        value: "\(snapshot.totalWorkouts)",
                        subtitle: L.t(.completed, language),
                        systemImage: "checkmark.seal.fill",
                        color: .blue
                    )
                    ShareHeroMetric(
                        title: L.t(.last, language),
                        value: snapshot.lastWorkoutDescription,
                        subtitle: L.t(.workout, language),
                        systemImage: "calendar",
                        color: .green
                    )
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18), GridItem(.flexible(), spacing: 18)], spacing: 18) {
                    ShareStatTile(mode: .pushUps, value: snapshot.totalPushUps, subtitle: L.t(.totalReps, language), color: .green, language: language)
                    ShareStatTile(mode: .squats, value: snapshot.totalSquats, subtitle: L.t(.totalReps, language), color: .orange, language: language)
                    ShareStatTile(mode: .abs, value: snapshot.totalSitUps, subtitle: L.t(.totalReps, language), color: .purple, language: language)
                    ShareStatTile(mode: .plank, value: snapshot.totalPlankSeconds, subtitle: totalSecondsSubtitle, color: .cyan, language: language)
                    ShareStatTile(mode: .burpees, value: snapshot.totalBurpees, subtitle: L.t(.totalReps, language), color: .pink, language: language)
                    ShareStatTile(mode: .mountainClimbers, value: snapshot.totalMountainClimbers, subtitle: L.t(.totalReps, language), color: .mint, language: language)
                    ShareStatTile(mode: .lSitHold, value: snapshot.totalLSitSeconds, subtitle: totalSecondsSubtitle, color: .indigo, language: language)
                    ShareStatTile(mode: .elbowLeverHold, value: snapshot.totalElbowLeverSeconds, subtitle: totalSecondsSubtitle, color: .teal, language: language)
                }

                Spacer()

                Text(language == .russian ? "Движение вместо залипания" : "Move before the screen wins")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
            }
            .padding(54)
        }
        .foregroundStyle(.white)
    }

    private var totalSecondsSubtitle: String {
        language == .russian ? "всего секунд" : "total seconds"
    }
}

private struct ShareHeroMetric: View {
    let title: String
    let value: String
    let subtitle: String
    let systemImage: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            Text(value)
                .font(.system(size: 34, weight: .black, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(subtitle)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))
                .frame(height: 24, alignment: .leading)
        }
        .padding(24)
        .frame(maxWidth: .infinity, minHeight: 164, alignment: .leading)
        .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(color.opacity(0.32), lineWidth: 1)
        }
    }
}

private struct ShareStatTile: View {
    let mode: ExerciseMode
    let value: Int
    let subtitle: String
    let color: Color
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(mode.title(language), systemImage: mode.systemImage)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text("\(value)")
                .font(.system(size: 44, weight: .black, design: .rounded))
                .monospacedDigit()
            Text(subtitle)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))
                .frame(height: 23, alignment: .leading)
        }
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 158, maxHeight: 158, alignment: .leading)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(color.opacity(0.28), lineWidth: 1)
        }
    }
}

private struct MenuToggleCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let color: Color
    var titleFontSize: CGFloat = 12
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: titleFontSize + 2, weight: .semibold))
                .foregroundStyle(isOn ? color : .secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: titleFontSize, weight: .semibold, design: .rounded))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background((isOn ? color.opacity(0.14) : Color.white.opacity(0.06)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder((isOn ? color : Color.white).opacity(0.18), lineWidth: 1)
        }
    }
}

private enum MenuActionButtonKind {
    case primary
    case secondary
    case warning
    case utility
    case destructive
}

private struct MenuActionButtonStyle: ButtonStyle {
    let kind: MenuActionButtonKind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold, design: .rounded))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .frame(height: height)
            .background(background.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            }
    }

    private var height: CGFloat {
        switch kind {
        case .primary: 38
        case .secondary, .warning: 34
        case .utility, .destructive: 30
        }
    }

    private var fontSize: CGFloat {
        switch kind {
        case .primary: 14
        case .secondary, .warning: 13
        case .utility, .destructive: 12
        }
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .warning: .orange
        case .destructive: .red
        default: .primary
        }
    }

    private var background: Color {
        switch kind {
        case .primary: .green.opacity(0.86)
        case .secondary: .white.opacity(0.08)
        case .warning: .orange.opacity(0.14)
        case .utility: .white.opacity(0.07)
        case .destructive: .red.opacity(0.12)
        }
    }

    private var stroke: Color {
        switch kind {
        case .primary: .green.opacity(0.38)
        case .warning: .orange.opacity(0.34)
        case .destructive: .red.opacity(0.30)
        default: .white.opacity(0.12)
        }
    }
}

private extension View {
    func menuPanelCard(accent: Color = Color.white.opacity(0.16)) -> some View {
        padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(accent.opacity(0.22), lineWidth: 1)
            }
    }
}

enum AppLanguage: String, CaseIterable, Identifiable, Codable {
    case english
    case russian

    var id: Self { self }

    var title: String {
        switch self {
        case .english: "English"
        case .russian: "Русский"
        }
    }

    var voiceLocaleIdentifier: String {
        switch self {
        case .english: "en-US"
        case .russian: "ru-RU"
        }
    }
}

enum LKey {
    case readySubtitle
    case gateActiveSubtitle
    case gateActive
    case gateIdle
    case monitoring
    case voice
    case runOnStartup
    case on
    case off
    case language
    case voiceInputOff
    case score
    case activityLoad
    case pressure
    case triggerRisk
    case multiplier
    case normalScoring
    case left
    case currentPlan
    case rewardNone
    case rewardScoring
    case statistics
    case workouts
    case completed
    case totalReps
    case seconds
    case last
    case workout
    case startWorkoutNow
    case openGate
    case configure
    case about
    case resetCurrentGate
    case resetScore
    case resetAllStats
    case quit
    case workoutPlan
    case planDescription
    case difficulty
    case workoutSteps
    case scoreRewards
    case rewardsDescription
    case resetToDefaults
    case cancel
    case save
    case step
    case exercise
    case reps
    case minutes
}

struct L {
    static func t(_ key: LKey, _ language: AppLanguage) -> String {
        switch (key, language) {
        case (.readySubtitle, .english): "Workout blocker is ready"
        case (.readySubtitle, .russian): "Блокировка готова"
        case (.gateActiveSubtitle, .english): "Workout gate is active"
        case (.gateActiveSubtitle, .russian): "Гейт активен"
        case (.gateActive, .english): "Gate Active"
        case (.gateActive, .russian): "Гейт активен"
        case (.gateIdle, .english): "Gate Idle"
        case (.gateIdle, .russian): "Гейт неактивен"
        case (.monitoring, .english): "Monitoring"
        case (.monitoring, .russian): "Мониторинг"
        case (.voice, .english): "Voice"
        case (.voice, .russian): "Голос"
        case (.runOnStartup, .english): "Run on Startup"
        case (.runOnStartup, .russian): "Автозапуск"
        case (.on, .english): "On"
        case (.on, .russian): "Вкл"
        case (.off, .english): "Off"
        case (.off, .russian): "Выкл"
        case (.language, .english): "Language"
        case (.language, .russian): "Язык"
        case (.voiceInputOff, .english): "Voice input off"
        case (.voiceInputOff, .russian): "Голос выключен"
        case (.score, .english): "Score"
        case (.score, .russian): "Очки"
        case (.activityLoad, .english): "activity load"
        case (.activityLoad, .russian): "нагрузка"
        case (.pressure, .english): "Pressure"
        case (.pressure, .russian): "Давление"
        case (.triggerRisk, .english): "trigger risk"
        case (.triggerRisk, .russian): "риск гейта"
        case (.multiplier, .english): "Multiplier"
        case (.multiplier, .russian): "Множитель"
        case (.normalScoring, .english): "normal scoring"
        case (.normalScoring, .russian): "обычный рост"
        case (.left, .english): "left"
        case (.left, .russian): "осталось"
        case (.currentPlan, .english): "Current Plan"
        case (.currentPlan, .russian): "Текущий план"
        case (.rewardNone, .english): "Reward: None"
        case (.rewardNone, .russian): "Бонус: нет"
        case (.rewardScoring, .english): "Reward: %@ scoring for %d min"
        case (.rewardScoring, .russian): "Бонус: %@ роста очков на %d мин"
        case (.statistics, .english): "Statistics"
        case (.statistics, .russian): "Статистика"
        case (.workouts, .english): "Workouts"
        case (.workouts, .russian): "Тренировки"
        case (.completed, .english): "completed"
        case (.completed, .russian): "завершено"
        case (.totalReps, .english): "total reps"
        case (.totalReps, .russian): "всего повторов"
        case (.seconds, .english): "seconds"
        case (.seconds, .russian): "секунды"
        case (.last, .english): "Last"
        case (.last, .russian): "Последняя"
        case (.workout, .english): "workout"
        case (.workout, .russian): "тренировка"
        case (.startWorkoutNow, .english): "Start Workout Now"
        case (.startWorkoutNow, .russian): "Начать тренировку"
        case (.openGate, .english): "Open Gate"
        case (.openGate, .russian): "Открыть гейт"
        case (.configure, .english): "Configure"
        case (.configure, .russian): "Конфигурация"
        case (.about, .english): "About BreakGateWorkout"
        case (.about, .russian): "О BreakGateWorkout"
        case (.resetCurrentGate, .english): "Reset Current Gate"
        case (.resetCurrentGate, .russian): "Сбросить текущий гейт"
        case (.resetScore, .english): "Reset Score"
        case (.resetScore, .russian): "Сбросить очки"
        case (.resetAllStats, .english): "Reset All Stats"
        case (.resetAllStats, .russian): "Сбросить статистику"
        case (.quit, .english): "Quit"
        case (.quit, .russian): "Выйти"
        case (.workoutPlan, .english): "Workout Plan"
        case (.workoutPlan, .russian): "План тренировки"
        case (.planDescription, .english): "Choose the gate difficulty, ordered steps, and score reward settings."
        case (.planDescription, .russian): "Выбери сложность гейта, порядок упражнений и бонусы к скорингу."
        case (.difficulty, .english): "Difficulty"
        case (.difficulty, .russian): "Сложность"
        case (.workoutSteps, .english): "Workout Steps"
        case (.workoutSteps, .russian): "Шаги тренировки"
        case (.scoreRewards, .english): "Score Rewards"
        case (.scoreRewards, .russian): "Бонусы скоринга"
        case (.rewardsDescription, .english): "Rewards reduce only positive score growth after a completed workout."
        case (.rewardsDescription, .russian): "Бонусы уменьшают только рост очков после завершенной тренировки."
        case (.resetToDefaults, .english): "Reset to Defaults"
        case (.resetToDefaults, .russian): "Сбросить по умолчанию"
        case (.cancel, .english): "Cancel"
        case (.cancel, .russian): "Отмена"
        case (.save, .english): "Save"
        case (.save, .russian): "Сохранить"
        case (.step, .english): "Step"
        case (.step, .russian): "Шаг"
        case (.exercise, .english): "Exercise"
        case (.exercise, .russian): "Упражнение"
        case (.reps, .english): "Reps"
        case (.reps, .russian): "Повторы"
        case (.minutes, .english): "Minutes"
        case (.minutes, .russian): "Минуты"
        }
    }
}

struct VoiceLanguageInfo {
    static func expectedLocaleIdentifier(for language: AppLanguage) -> String {
        language.voiceLocaleIdentifier
    }

    static func expectedLanguageName(for language: AppLanguage) -> String {
        language.title
    }
}

@MainActor
final class LaunchAtLoginService {
    static let shared = LaunchAtLoginService()

    private init() {}

    var isEnabled: Bool {
        guard #available(macOS 13.0, *) else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    func setEnabled(_ isEnabled: Bool) {
        do {
            try setEnabledThrowing(isEnabled)
            print("BreakGateWorkout launch at login: \(isEnabled ? "enabled" : "disabled")")
        } catch {
            print("BreakGateWorkout launch at login error: \(error.localizedDescription)")
        }
    }

    func setEnabledThrowing(_ isEnabled: Bool) throws {
        guard #available(macOS 13.0, *) else {
            print("BreakGateWorkout launch at login: requires macOS 13 or newer")
            return
        }

        if isEnabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
final class SoftGateWindowController {
    static let shared = SoftGateWindowController()
    static let sendPlayPauseMediaKeyOnGate = true

    private var window: NSWindow?
    private var secondaryOverlayWindows: [NSWindow] = []

    private init() {}

    func showGate(monitor: BreakGateMonitor, stats: WorkoutStats, settings: WorkoutSettingsStore) {
        if let window {
            DiagnosticLog.log("showGate called while window already exists")
            bringToFront(window)
            return
        }

        DiagnosticLog.log("opening gate window")
        let mainScreen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = mainScreen?.frame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let contentView = ContentView(monitor: monitor, stats: stats, settings: settings)
        let hostingController = NSHostingController(rootView: contentView)
        let gateWindow = SoftGateWindow(
            contentRect: screenFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        gateWindow.title = "BreakGateWorkout"
        gateWindow.contentViewController = hostingController
        gateWindow.level = .screenSaver
        gateWindow.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
        gateWindow.isReleasedWhenClosed = false
        gateWindow.backgroundColor = .black
        gateWindow.setFrame(screenFrame, display: true)

        window = gateWindow
        secondaryOverlayWindows = makeSecondaryOverlayWindows(excluding: mainScreen)
        if settings.autoPauseMediaOnGate {
            MediaKeyPauseService.shared.sendPlayPause()
        }
        SoundFeedbackService.shared.startGateMusic()
        secondaryOverlayWindows.forEach { $0.orderFrontRegardless() }
        bringToFront(gateWindow)
        print("BreakGateWorkout gate: opened soft gate window")
    }

    func closeGate() {
        guard let window else {
            DiagnosticLog.log("closeGate called with no active window")
            return
        }

        DiagnosticLog.log("closing gate window")
        SoundFeedbackService.shared.stopGateMusic()
        window.orderOut(nil)
        window.close()
        self.window = nil
        secondaryOverlayWindows.forEach {
            $0.orderOut(nil)
            $0.close()
        }
        secondaryOverlayWindows = []
        print("BreakGateWorkout gate: closed soft gate window")
    }

    private func makeSecondaryOverlayWindows(excluding mainScreen: NSScreen?) -> [NSWindow] {
        NSScreen.screens.compactMap { screen in
            guard screen != mainScreen else { return nil }

            let overlay = SoftGateWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            overlay.level = .screenSaver
            overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            overlay.isReleasedWhenClosed = false
            overlay.backgroundColor = .black
            let contentView = NSView(frame: screen.frame)
            contentView.wantsLayer = true
            contentView.layer?.backgroundColor = NSColor.black.cgColor
            overlay.contentView = contentView
            overlay.setFrame(screen.frame, display: true)
            return overlay
        }
    }

    private func bringToFront(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private final class SoftGateWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class MediaKeyPauseService {
    static let shared = MediaKeyPauseService()

    private init() {}

    func sendPlayPause() {
        guard AXIsProcessTrusted() else {
            print("BreakGateWorkout media: play/pause skipped, Accessibility permission is not granted")
            return
        }

        postMediaKey(keyCode: NX_KEYTYPE_PLAY, keyState: NX_KEYDOWN)
        postMediaKey(keyCode: NX_KEYTYPE_PLAY, keyState: NX_KEYUP)
        print("BreakGateWorkout media: sent play/pause media key")
    }

    private func postMediaKey(keyCode: Int32, keyState: Int32) {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(keyState))
        let data1 = (Int(keyCode) << 16) | (Int(keyState) << 8)

        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else {
            print("BreakGateWorkout media: failed to create media key event")
            return
        }

        event.cgEvent?.post(tap: .cghidEventTap)
    }
}

struct ScoreReward: Codable, Equatable {
    var multiplier: Double
    var expiresAt: Date?

    var isActive: Bool {
        guard let expiresAt else { return false }
        return multiplier < 1 && expiresAt > Date()
    }
}

struct DifficultyRewardSetting: Codable, Equatable {
    var multiplier: Double
    var minutes: Int
}

enum GateWarningDelay: Int, CaseIterable, Identifiable, Codable {
    case seconds30 = 30
    case minute1 = 60
    case minutes3 = 180
    case minutes5 = 300
    case minutes10 = 600
    case minutes15 = 900

    var id: Int { rawValue }

    var allowsSecondaryReminder: Bool { rawValue >= 180 }

    func title(_ language: AppLanguage) -> String {
        switch (self, language) {
        case (.seconds30, .english): "30 seconds"
        case (.seconds30, .russian): "30 секунд"
        case (.minute1, .english): "1 minute"
        case (.minute1, .russian): "1 минута"
        case (.minutes3, .english): "3 minutes"
        case (.minutes3, .russian): "3 минуты"
        case (.minutes5, .english): "5 minutes"
        case (.minutes5, .russian): "5 минут"
        case (.minutes10, .english): "10 minutes"
        case (.minutes10, .russian): "10 минут"
        case (.minutes15, .english): "15 minutes"
        case (.minutes15, .russian): "15 минут"
        }
    }
}

enum GateSecondaryReminder: Int, CaseIterable, Identifiable, Codable {
    case off = 0
    case seconds30 = 30
    case minute1 = 60

    var id: Int { rawValue }

    func title(_ language: AppLanguage) -> String {
        switch (self, language) {
        case (.off, .english): "Off"
        case (.off, .russian): "Выкл"
        case (.seconds30, .english): "30 seconds before"
        case (.seconds30, .russian): "за 30 секунд"
        case (.minute1, .english): "1 minute before"
        case (.minute1, .russian): "за 1 минуту"
        }
    }

    func notificationTimingTitle(_ language: AppLanguage) -> String {
        switch (self, language) {
        case (.off, .english): "soon"
        case (.off, .russian): "скоро"
        case (.seconds30, .english): "in 30 seconds"
        case (.seconds30, .russian): "через 30 секунд"
        case (.minute1, .english): "in 1 minute"
        case (.minute1, .russian): "через 1 минуту"
        }
    }
}

enum ScoringSensitivity: String, CaseIterable, Identifiable, Codable {
    case relaxed
    case normal
    case strict
    case intense
    case brutal
    case hell

    var id: Self { self }

    var multiplier: Double {
        switch self {
        case .relaxed: 0.6
        case .normal: 1.0
        case .strict: 1.4
        case .intense: 1.8
        case .brutal: 2.5
        case .hell: 3.0
        }
    }

    func title(_ language: AppLanguage) -> String {
        switch (self, language) {
        case (.relaxed, .english): "Relaxed"
        case (.relaxed, .russian): "Спокойная"
        case (.normal, .english): "Normal"
        case (.normal, .russian): "Обычная"
        case (.strict, .english): "Strict"
        case (.strict, .russian): "Строгая"
        case (.intense, .english): "Intense"
        case (.intense, .russian): "Интенсивная"
        case (.brutal, .english): "Brutal"
        case (.brutal, .russian): "Жесткая"
        case (.hell, .english): "Hell"
        case (.hell, .russian): "Адская"
        }
    }
}

enum StartPoseWaitDuration: Int, CaseIterable, Identifiable, Codable {
    case seconds15 = 15
    case seconds30 = 30

    var id: Int { rawValue }
    var timeInterval: TimeInterval { TimeInterval(rawValue) }

    func title(_ language: AppLanguage) -> String {
        switch (self, language) {
        case (.seconds15, .english): "15 seconds"
        case (.seconds15, .russian): "15 секунд"
        case (.seconds30, .english): "30 seconds"
        case (.seconds30, .russian): "30 секунд"
        }
    }
}

@MainActor
final class WorkoutSettingsStore: ObservableObject {
    @Published var plan: WorkoutPlan {
        didSet { save() }
    }
    @Published var rewardSettings: [WorkoutDifficulty: DifficultyRewardSetting] {
        didSet { save() }
    }
    @Published var isVoiceControlEnabled: Bool {
        didSet { save() }
    }
    @Published var appLanguage: AppLanguage {
        didSet { save() }
    }
    @Published var runOnStartupEnabled: Bool {
        didSet { save() }
    }
    @Published var autoPauseMediaOnGate: Bool {
        didSet { save() }
    }
    @Published var scoringSensitivity: ScoringSensitivity {
        didSet { save() }
    }
    @Published var gateMusicEnabled: Bool {
        didSet {
            save()
            applySoundSettings()
        }
    }
    @Published var sfxEnabled: Bool {
        didSet {
            save()
            applySoundSettings()
        }
    }
    @Published var disabledSoundEffects: Set<SoundEffectKind> {
        didSet {
            save()
            applySoundSettings()
        }
    }
    @Published var gateWarningDelay: GateWarningDelay {
        didSet { save() }
    }
    @Published var secondaryGateReminder: GateSecondaryReminder {
        didSet { save() }
    }
    @Published var startPoseWaitDuration: StartPoseWaitDuration {
        didSet { save() }
    }
    @Published var userDisplayName: String {
        didSet { save() }
    }
    @Published var showExperimentalExercises: Bool {
        didSet { save() }
    }
    @Published private(set) var launchAtLoginErrorMessage: String?

    private let defaults = UserDefaults.standard
    private let planKey = "BreakGateWorkout.workoutPlan"
    private let rewardSettingsKey = "BreakGateWorkout.rewardSettings"
    private let voiceControlEnabledKey = "BreakGateWorkout.voiceControlEnabled"
    private let appLanguageKey = "BreakGateWorkout.appLanguage"
    private let runOnStartupEnabledKey = "BreakGateWorkout.runOnStartupEnabled"
    private let autoPauseMediaOnGateKey = "BreakGateWorkout.autoPauseMediaOnGate"
    private let scoringSensitivityKey = "BreakGateWorkout.scoringSensitivity"
    private let gateMusicEnabledKey = "BreakGateWorkout.gateMusicEnabled"
    private let sfxEnabledKey = "BreakGateWorkout.sfxEnabled"
    private let disabledSoundEffectsKey = "BreakGateWorkout.disabledSoundEffects"
    private let gateWarningDelayKey = "BreakGateWorkout.gateWarningDelay"
    private let secondaryGateReminderKey = "BreakGateWorkout.secondaryGateReminder"
    private let startPoseWaitDurationKey = "BreakGateWorkout.startPoseWaitDuration"
    private let userDisplayNameKey = "BreakGateWorkout.userDisplayName"
    private let showExperimentalExercisesKey = "BreakGateWorkout.showExperimentalExercises"

    init() {
        if let data = defaults.data(forKey: planKey),
           let decodedPlan = try? JSONDecoder().decode(WorkoutPlan.self, from: data) {
            plan = decodedPlan
        } else {
            plan = .defaultPlan(for: .light)
        }

        if let data = defaults.data(forKey: rewardSettingsKey),
           let decodedSettings = try? JSONDecoder().decode([WorkoutDifficulty: DifficultyRewardSetting].self, from: data) {
            rewardSettings = decodedSettings
        } else {
            rewardSettings = Self.defaultRewardSettings()
        }
        if defaults.object(forKey: voiceControlEnabledKey) == nil {
            isVoiceControlEnabled = true
        } else {
            isVoiceControlEnabled = defaults.bool(forKey: voiceControlEnabledKey)
        }
        if let rawLanguage = defaults.string(forKey: appLanguageKey),
           let decodedLanguage = AppLanguage(rawValue: rawLanguage) {
            appLanguage = decodedLanguage
        } else {
            appLanguage = Locale.preferredLanguages.first?.hasPrefix("ru") == true ? .russian : .english
        }
        if defaults.object(forKey: runOnStartupEnabledKey) == nil {
            runOnStartupEnabled = LaunchAtLoginService.shared.isEnabled
        } else {
            runOnStartupEnabled = defaults.bool(forKey: runOnStartupEnabledKey)
        }
        if defaults.object(forKey: autoPauseMediaOnGateKey) == nil {
            autoPauseMediaOnGate = false
        } else {
            autoPauseMediaOnGate = defaults.bool(forKey: autoPauseMediaOnGateKey)
        }
        if let rawSensitivity = defaults.string(forKey: scoringSensitivityKey),
           let decodedSensitivity = ScoringSensitivity(rawValue: rawSensitivity) {
            scoringSensitivity = decodedSensitivity
        } else {
            scoringSensitivity = .normal
        }

        if defaults.object(forKey: gateMusicEnabledKey) == nil {
            gateMusicEnabled = true
        } else {
            gateMusicEnabled = defaults.bool(forKey: gateMusicEnabledKey)
        }
        if defaults.object(forKey: sfxEnabledKey) == nil {
            sfxEnabled = true
        } else {
            sfxEnabled = defaults.bool(forKey: sfxEnabledKey)
        }
        if let rawEffects = defaults.stringArray(forKey: disabledSoundEffectsKey) {
            disabledSoundEffects = Set(rawEffects.compactMap(SoundEffectKind.init(rawValue:)))
        } else {
            disabledSoundEffects = []
        }
        if let decodedDelay = GateWarningDelay(rawValue: defaults.integer(forKey: gateWarningDelayKey)),
           defaults.object(forKey: gateWarningDelayKey) != nil {
            gateWarningDelay = decodedDelay
        } else {
            gateWarningDelay = .minute1
        }
        if let decodedReminder = GateSecondaryReminder(rawValue: defaults.integer(forKey: secondaryGateReminderKey)),
           defaults.object(forKey: secondaryGateReminderKey) != nil {
            secondaryGateReminder = decodedReminder
        } else {
            secondaryGateReminder = .off
        }
        if let decodedDuration = StartPoseWaitDuration(rawValue: defaults.integer(forKey: startPoseWaitDurationKey)),
           defaults.object(forKey: startPoseWaitDurationKey) != nil {
            startPoseWaitDuration = decodedDuration
        } else {
            startPoseWaitDuration = .seconds15
        }
        userDisplayName = defaults.string(forKey: userDisplayNameKey) ?? ""
        showExperimentalExercises = defaults.bool(forKey: showExperimentalExercisesKey)

        normalizePlan()
        applySoundSettings()
    }

    func rewardSetting(for difficulty: WorkoutDifficulty) -> DifficultyRewardSetting {
        rewardSettings[difficulty] ?? Self.defaultRewardSettings()[difficulty] ?? DifficultyRewardSetting(multiplier: 1, minutes: 0)
    }

    func setVoiceControlEnabledSafely(_ isEnabled: Bool) {
        Task { @MainActor in
            guard self.isVoiceControlEnabled != isEnabled else { return }
            self.isVoiceControlEnabled = isEnabled
        }
    }

    func setAppLanguageSafely(_ language: AppLanguage) {
        Task { @MainActor in
            guard self.appLanguage != language else { return }
            self.appLanguage = language
        }
    }

    func setLaunchAtLoginEnabledSafely(_ isEnabled: Bool) {
        Task { @MainActor in
            do {
                try LaunchAtLoginService.shared.setEnabledThrowing(isEnabled)
                self.launchAtLoginErrorMessage = nil
                self.runOnStartupEnabled = isEnabled
                print("BreakGateWorkout launch at login: \(isEnabled ? "enabled" : "disabled")")
            } catch {
                self.launchAtLoginErrorMessage = error.localizedDescription
                print("BreakGateWorkout launch at login error: \(error.localizedDescription)")
            }
        }
    }

    func setAutoPauseMediaOnGateSafely(_ isEnabled: Bool) {
        Task { @MainActor in
            guard self.autoPauseMediaOnGate != isEnabled else { return }
            self.autoPauseMediaOnGate = isEnabled
        }
    }

    func setScoringSensitivitySafely(_ sensitivity: ScoringSensitivity) {
        Task { @MainActor in
            guard self.scoringSensitivity != sensitivity else { return }
            self.scoringSensitivity = sensitivity
        }
    }

    func setGateMusicEnabledSafely(_ isEnabled: Bool) {
        Task { @MainActor in
            guard self.gateMusicEnabled != isEnabled else { return }
            self.gateMusicEnabled = isEnabled
        }
    }

    func setSFXEnabledSafely(_ isEnabled: Bool) {
        Task { @MainActor in
            guard self.sfxEnabled != isEnabled else { return }
            self.sfxEnabled = isEnabled
        }
    }

    func setSoundEffect(_ effect: SoundEffectKind, enabled isEnabled: Bool) {
        Task { @MainActor in
            var updated = self.disabledSoundEffects
            if isEnabled {
                updated.remove(effect)
            } else {
                updated.insert(effect)
            }
            guard updated != self.disabledSoundEffects else { return }
            self.disabledSoundEffects = updated
        }
    }

    func isSoundEffectEnabled(_ effect: SoundEffectKind) -> Bool {
        !disabledSoundEffects.contains(effect)
    }

    func applySoundSettings() {
        SoundFeedbackService.shared.applySettings(
            mainMenuMusicEnabled: gateMusicEnabled,
            sfxEnabled: sfxEnabled,
            disabledEffects: disabledSoundEffects
        )
    }

    func setGateWarningDelaySafely(_ delay: GateWarningDelay) {
        Task { @MainActor in
            guard self.gateWarningDelay != delay else { return }
            self.gateWarningDelay = delay
            if !delay.allowsSecondaryReminder {
                self.secondaryGateReminder = .off
            }
        }
    }

    func setSecondaryGateReminderSafely(_ reminder: GateSecondaryReminder) {
        Task { @MainActor in
            guard self.secondaryGateReminder != reminder else { return }
            self.secondaryGateReminder = reminder
        }
    }

    func setStartPoseWaitDurationSafely(_ duration: StartPoseWaitDuration) {
        Task { @MainActor in
            guard self.startPoseWaitDuration != duration else { return }
            self.startPoseWaitDuration = duration
        }
    }

    func setUserDisplayNameSafely(_ name: String) {
        Task { @MainActor in
            let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            guard self.userDisplayName != trimmed else { return }
            self.userDisplayName = trimmed
        }
    }

    func setShowExperimentalExercisesSafely(_ isVisible: Bool) {
        Task { @MainActor in
            guard self.showExperimentalExercises != isVisible else { return }
            self.showExperimentalExercises = isVisible
        }
    }

    func update(plan: WorkoutPlan, rewardSettings: [WorkoutDifficulty: DifficultyRewardSetting]) {
        self.plan = Self.normalized(plan)
        self.rewardSettings = rewardSettings
    }

    func resetToDefaults() {
        plan = .defaultPlan(for: .light)
        rewardSettings = Self.defaultRewardSettings()
    }

    static func defaultRewardSettings() -> [WorkoutDifficulty: DifficultyRewardSetting] {
        [
            .light: DifficultyRewardSetting(multiplier: 1.0, minutes: 0),
            .medium: DifficultyRewardSetting(multiplier: 0.65, minutes: 30),
            .hard: DifficultyRewardSetting(multiplier: 0.45, minutes: 60),
            .extreme: DifficultyRewardSetting(multiplier: 0.45, minutes: 80),
            .extremePlus: DifficultyRewardSetting(multiplier: 0.30, minutes: 120)
        ]
    }

    static func normalized(_ plan: WorkoutPlan) -> WorkoutPlan {
        var normalizedPlan = plan
        var steps = plan.steps

        if steps.isEmpty {
            steps = WorkoutPlan.defaultPlan(for: plan.difficulty).steps
        }

        steps = steps.map(normalizedStep)
        normalizedPlan.steps = steps
        return normalizedPlan
    }

    private func normalizePlan() {
        plan = Self.normalized(plan)
    }

    private static func defaultStep(for difficulty: WorkoutDifficulty) -> WorkoutStep {
        let defaultPlan = WorkoutPlan.defaultPlan(for: difficulty)
        return defaultPlan.steps.last ?? WorkoutStep(mode: .pushUps, targetReps: 20)
    }

    private static func normalizedStep(_ step: WorkoutStep) -> WorkoutStep {
        if step.mode.isTimed {
            let minimum = (step.mode == .tuckPlancheHold || step.mode == .lSitHold || step.mode == .elbowLeverHold) ? 5 : 10
            return WorkoutStep(id: step.id, mode: step.mode, targetSeconds: max(minimum, step.targetSeconds ?? minimum))
        }

        return WorkoutStep(id: step.id, mode: step.mode, targetReps: max(1, step.targetReps ?? 20))
    }

    private func save() {
        if let planData = try? JSONEncoder().encode(plan) {
            defaults.set(planData, forKey: planKey)
        }

        if let rewardData = try? JSONEncoder().encode(rewardSettings) {
            defaults.set(rewardData, forKey: rewardSettingsKey)
        }
        defaults.set(isVoiceControlEnabled, forKey: voiceControlEnabledKey)
        defaults.set(appLanguage.rawValue, forKey: appLanguageKey)
        defaults.set(runOnStartupEnabled, forKey: runOnStartupEnabledKey)
        defaults.set(autoPauseMediaOnGate, forKey: autoPauseMediaOnGateKey)
        defaults.set(scoringSensitivity.rawValue, forKey: scoringSensitivityKey)
        defaults.set(gateMusicEnabled, forKey: gateMusicEnabledKey)
        defaults.set(sfxEnabled, forKey: sfxEnabledKey)
        defaults.set(disabledSoundEffects.map(\.rawValue), forKey: disabledSoundEffectsKey)
        defaults.set(gateWarningDelay.rawValue, forKey: gateWarningDelayKey)
        defaults.set(secondaryGateReminder.rawValue, forKey: secondaryGateReminderKey)
        defaults.set(startPoseWaitDuration.rawValue, forKey: startPoseWaitDurationKey)
        defaults.set(userDisplayName, forKey: userDisplayNameKey)
        defaults.set(showExperimentalExercises, forKey: showExperimentalExercisesKey)
    }
}

@MainActor
final class WorkoutConfigurationWindowController {
    static let shared = WorkoutConfigurationWindowController()

    private var window: NSWindow?

    private init() {}

    func show(settings: WorkoutSettingsStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let view = WorkoutConfigurationView(settings: settings) { [weak self] in
            self?.close()
        }
        let controller = NSHostingController(rootView: view)
        let configWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 700),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        configWindow.title = L.t(.workoutPlan, settings.appLanguage)
        configWindow.contentViewController = controller
        configWindow.center()
        configWindow.isReleasedWhenClosed = false

        window = configWindow
        configWindow.makeKeyAndOrderFront(nil)
        configWindow.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}

@MainActor
final class AppSettingsWindowController {
    static let shared = AppSettingsWindowController()

    private var window: NSWindow?

    private init() {}

    func show(settings: WorkoutSettingsStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(rootView: AppSettingsView(settings: settings) { [weak self] in
            self?.close()
        })
        let settingsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        settingsWindow.title = settings.appLanguage == .russian ? "Настройки" : "Settings"
        settingsWindow.contentViewController = controller
        settingsWindow.center()
        settingsWindow.isReleasedWhenClosed = false

        window = settingsWindow
        settingsWindow.makeKeyAndOrderFront(nil)
        settingsWindow.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}

private struct AppSettingsView: View {
    @ObservedObject var settings: WorkoutSettingsStore
    let onClose: () -> Void

    private var language: AppLanguage { settings.appLanguage }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(language == .russian ? "Настройки BreakGate" : "BreakGate Settings")
                .font(.title2.weight(.bold))

            VStack(alignment: .leading, spacing: 10) {
                Picker(L.t(.language, language), selection: Binding(
                    get: { settings.appLanguage },
                    set: { settings.setAppLanguageSafely($0) }
                )) {
                    ForEach(AppLanguage.allCases) { appLanguage in
                        Text(appLanguage.title).tag(appLanguage)
                    }
                }
                .pickerStyle(.segmented)

                Toggle(L.t(.voice, language), isOn: Binding(
                    get: { settings.isVoiceControlEnabled },
                    set: { settings.setVoiceControlEnabledSafely($0) }
                ))
                Toggle(L.t(.runOnStartup, language), isOn: Binding(
                    get: { settings.runOnStartupEnabled },
                    set: { settings.setLaunchAtLoginEnabledSafely($0) }
                ))
                Toggle(language == .russian ? "Ставить медиа на паузу при гейте" : "Pause media when gate opens", isOn: Binding(
                    get: { settings.autoPauseMediaOnGate },
                    set: { settings.setAutoPauseMediaOnGateSafely($0) }
                ))
                Text(language == .russian ? "Если включено, macOS попросит Accessibility доступ для отправки media play/pause." : "When enabled, macOS needs Accessibility access to send the media play/pause key.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField(language == .russian ? "Имя для статистики" : "Stats display name", text: Binding(
                    get: { settings.userDisplayName },
                    set: { settings.setUserDisplayNameSafely($0) }
                ))
                .textFieldStyle(.roundedBorder)

                Picker(language == .russian ? "Ожидание исходной позы" : "Starting pose wait", selection: Binding(
                    get: { settings.startPoseWaitDuration },
                    set: { settings.setStartPoseWaitDurationSafely($0) }
                )) {
                    ForEach(StartPoseWaitDuration.allCases) { duration in
                        Text(duration.title(language)).tag(duration)
                    }
                }
                .pickerStyle(.menu)

                Toggle(language == .russian ? "Показывать экспериментальные упражнения" : "Show experimental exercises", isOn: Binding(
                    get: { settings.showExperimentalExercises },
                    set: { settings.setShowExperimentalExercisesSafely($0) }
                ))
            }
            .configurationCard()

            VStack(alignment: .leading, spacing: 10) {
                Text(language == .russian ? "Чувствительность скоринга" : "Scoring Sensitivity")
                    .font(.headline)
                Text(language == .russian ? "Как быстро растет давление, пока ты продолжаешь работать без перерыва." : "How quickly pressure builds while you keep working without a break.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(language == .russian ? "Чувствительность" : "Sensitivity", selection: Binding(
                    get: { settings.scoringSensitivity },
                    set: { settings.setScoringSensitivitySafely($0) }
                )) {
                    ForEach(ScoringSensitivity.allCases) { sensitivity in
                        Text("\(sensitivity.title(language)) (\(sensitivity.multiplier, specifier: "%.1f")x)").tag(sensitivity)
                    }
                }
                .pickerStyle(.menu)
            }
            .configurationCard()

            Spacer()

            HStack {
                Spacer()
                Button(language == .russian ? "Готово" : "Done") {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440, height: 520)
    }
}

@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()

    private var window: NSWindow?

    private init() {}

    func show(settings: WorkoutSettingsStore) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let controller = NSHostingController(rootView: AboutBreakGateView(settings: settings))
        let aboutWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 620),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        aboutWindow.title = L.t(.about, settings.appLanguage)
        aboutWindow.contentViewController = controller
        aboutWindow.center()
        aboutWindow.isReleasedWhenClosed = false

        window = aboutWindow
        aboutWindow.makeKeyAndOrderFront(nil)
        aboutWindow.orderFrontRegardless()
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct AboutBreakGateView: View {
    @ObservedObject var settings: WorkoutSettingsStore
    var embeddedInMenu = false

    var body: some View {
        let language = settings.appLanguage

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("BreakGateWorkout")
                    .font(.title.weight(.bold))

                ForEach(aboutSections(language), id: \.title) { section in
                    AboutSection(title: section.title, lines: section.lines)
                }
            }
            .padding(22)
        }
        .frame(width: embeddedInMenu ? nil : 560, height: embeddedInMenu ? nil : 620)
    }

    private func aboutSections(_ language: AppLanguage) -> [(title: String, lines: [String])] {
        switch language {
        case .english:
            [
                ("What BreakGate Does", [
                    "BreakGateWorkout is a menu bar workout gate for long computer sessions.",
                    "While monitoring is on, keyboard, mouse, and scroll activity slowly raise an activity score.",
                    "Long idle periods reduce the score. The camera is not used for scoring.",
                    "When the score gets high enough, BreakGate schedules a warning and then opens a workout gate.",
                    "The gate closes only after the configured workout plan is completed."
                ]),
                ("Score And Gate Timing", [
                    "The score updates once per minute, not on every click or keypress.",
                    "Active input during the last minute increases score. More strict sensitivity increases it faster.",
                    "If the computer has been idle for more than five minutes, score goes down.",
                    "Below 50 score, automatic gates do not trigger. Above 50, the trigger chance rises as pressure increases.",
                    "Manual Start Workout Now always opens the same gate and gives the same rewards after completion."
                ]),
                ("Workout Start", [
                    "When the gate opens, BreakGate waits for a clean starting position before counting.",
                    "The starting-pose window can be set to 15 or 30 seconds in Settings.",
                    "A small countdown shows how long automatic pose start is still waiting.",
                    "If the pose is accepted during that window, BreakGate starts automatically.",
                    "If the pose is not accepted in time, say go, start, begin, ready, or let's go to start by voice.",
                    "Push-ups and plank start from a straight plank-like body line.",
                    "Squats start from a tall standing position with legs visible.",
                    "Abs start from a lying position with the torso down and knees allowed to be slightly bent.",
                    "Burpees start from standing and count only after a standing → low push-up → standing cycle.",
                    "Mountain Climbers start from plank and count one left-right knee-drive pair as one rep.",
                    "Experimental exercises can be enabled in Settings. Tuck Planche Hold waits for a stable two-second hold before its timer starts.",
                    "L-sit Hold waits for a stable seated support position with straight legs before the timer starts.",
                    "Elbow Lever waits for a stable bent-arm horizontal body line before the timer starts.",
                    "When the starting position is accepted, you hear a short tick and see Go!"
                ]),
                ("Difficulty", [
                    "Light: one small workout, no reward multiplier.",
                    "Medium and above reduce future score growth for a while after completion.",
                    "Hard, Extreme, and Extreme+ are longer plans with stronger rewards.",
                    "Rewards do not erase old activity by themselves; completing the workout resets score to zero.",
                    "You can customize steps, reps, timed holds, sensitivity, and reward multipliers."
                ]),
                ("Voice Commands", [
                    "Voice control is optional. Turn it on only if you want hands-free control in the gate.",
                    "Start counting: go, start, begin, ready, let's go.",
                    "Change exercise with an anchor: change to plank, switch to squats, set to burpees, change to mountain climbers.",
                    "Change difficulty before the first rep: difficulty light, difficulty medium, difficulty hard, difficulty extreme, difficulty extreme plus.",
                    "Emergency unlock while developing: emergency unlock.",
                    "The selected app language controls which language the speech recognizer expects."
                ]),
                ("Stats Sharing", [
                    "Add your display name in Settings to personalize your statistics card.",
                    "The Statistics page can generate a dark PNG card with totals, last workout, and all exercise counters.",
                    "You can share the image, save it to your Mac, or copy it to the clipboard."
                ]),
                ("Permissions", [
                    "Camera is used only inside the gate to count exercises locally on your Mac.",
                    "Microphone and Speech Recognition are used only for optional voice commands.",
                    "Notifications are used for gate warnings before an automatic gate opens.",
                    "Accessibility is needed only if Pause media when gate opens is enabled.",
                    "For reliable permissions, use one stable copy of the app, ideally from Applications."
                ]),
                ("Safety", [
                    "BreakGate is a soft blocker, not a security boundary.",
                    "It does not try to block Cmd+Tab, Mission Control, or force-level system actions.",
                    "Emergency Unlock remains available while the app is in development.",
                    "If pose detection behaves oddly, improve lighting, keep the full body in frame, and use the start command when needed."
                ])
            ]
        case .russian:
            [
                ("Что делает BreakGate", [
                    "BreakGateWorkout живет в меню macOS и помогает разбивать долгие сессии за компьютером тренировками.",
                    "Пока мониторинг включен, клавиатура, мышь и скролл постепенно повышают счет активности.",
                    "Долгий простой снижает счет. Камера для скоринга не используется.",
                    "Когда счет становится высоким, BreakGate планирует предупреждение и затем открывает окно тренировки.",
                    "Гейт закрывается только после выполнения настроенного плана."
                ]),
                ("Счет и запуск гейта", [
                    "Счет обновляется раз в минуту, а не на каждый клик или каждую клавишу.",
                    "Если за последнюю минуту была активность, счет растет. Чем строже чувствительность, тем быстрее.",
                    "Если компьютер простаивает больше пяти минут, счет снижается.",
                    "До 50 очков автоматический гейт не запускается. После 50 шанс запуска растет вместе с давлением.",
                    "Кнопка Начать тренировку сейчас открывает тот же гейт и после завершения дает те же бонусы."
                ]),
                ("Старт упражнения", [
                    "Когда гейт открывается, BreakGate ждет чистую исходную позу и только потом начинает считать.",
                    "Окно ожидания исходной позы можно выбрать в настройках: 15 или 30 секунд.",
                    "В углу камеры показывается обратный отсчет ожидания позы.",
                    "Если поза принята во время этого окна, BreakGate стартует автоматически.",
                    "Если поза не принята вовремя, можно сказать поехали, погнали, начали, начинаем или готов.",
                    "Отжимания и планка стартуют из прямой позы, похожей на планку.",
                    "Приседания стартуют из ровной стойки; ноги должны быть видны камере.",
                    "Пресс стартует из положения лежа: корпус лежит, ноги могут быть немного согнуты.",
                    "Бёрпи стартуют из стойки и считаются только после цикла стойка → низкая фаза отжимания → стойка.",
                    "Альпинист стартует из планки и считает пару левое-правое подтягивание колена как один повтор.",
                    "Экспериментальные упражнения можно включить в настройках. Так планше сначала ждет стабильную фиксацию две секунды, потом запускает таймер.",
                    "Уголок ждет устойчивую опору на руках с вытянутыми ногами.",
                    "Локтевой рычаг ждет устойчивую горизонтальную линию тела на согнутых руках.",
                    "Когда исходная поза принята, прозвучит короткий сигнал и появится Начинай!"
                ]),
                ("Сложности", [
                    "Легкая: короткая тренировка без бонусного множителя.",
                    "Средняя и выше замедляют будущий набор очков после завершения.",
                    "Сложная, Экстремальная и Экстремальная+ длиннее и дают более сильные бонусы.",
                    "Бонус не стирает старые очки сам по себе; завершение тренировки сбрасывает счет в ноль.",
                    "Можно настроить шаги, повторы, удержания по времени, чувствительность и бонусные множители."
                ]),
                ("Голосовые команды", [
                    "Голосовое управление необязательно. Включай его только если нужны команды без рук в гейте.",
                    "Начать счет: поехали, погнали, начали, начинаем, готов.",
                    "Сменить упражнение можно только с якорем: переключи на планку, поменяй на пресс, смени на бёрпи, измени на альпинист.",
                    "Сменить сложность до первого повтора: сложность легкая, сложность средняя, сложность сложная, сложность экстремальная, сложность экстрим плюс.",
                    "Экстренная команда на время разработки: экстренно разблокировать.",
                    "Выбранный язык приложения определяет, какой язык ожидает распознавание речи."
                ]),
                ("Шеринг статистики", [
                    "В настройках можно указать имя для красивой карточки статистики.",
                    "На странице статистики можно создать PNG-карточку с итогами, последней тренировкой и счетчиками всех упражнений.",
                    "Картинку можно отправить через системное меню, сохранить на Mac или скопировать в буфер обмена."
                ]),
                ("Разрешения", [
                    "Камера используется только внутри гейта, чтобы локально считать упражнения на Mac.",
                    "Микрофон и Speech Recognition нужны только для необязательных голосовых команд.",
                    "Уведомления нужны для предупреждений перед автоматическим гейтом.",
                    "Accessibility нужен только если включена пауза медиа при открытии гейта.",
                    "Чтобы разрешения работали стабильнее, запускай одну постоянную копию приложения, лучше из Applications."
                ]),
                ("Безопасность", [
                    "BreakGate - мягкий блокировщик, а не системная защита.",
                    "Он не пытается блокировать Cmd+Tab, Mission Control и системные обходные действия.",
                    "Emergency Unlock остается доступен, пока приложение в разработке.",
                    "Если распознавание позы ведет себя странно, добавь света, держи тело целиком в кадре и при необходимости используй голосовой старт."
                ])
            ]
        }
    }
}

private struct AboutSection: View {
    let title: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            ForEach(lines, id: \.self) { line in
                Text("• \(line)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct WorkoutConfigurationView: View {
    @ObservedObject var settings: WorkoutSettingsStore
    let onClose: () -> Void
    var embeddedInMenu = false

    @State private var draftPlan: WorkoutPlan
    private var language: AppLanguage { settings.appLanguage }

    init(settings: WorkoutSettingsStore, embeddedInMenu: Bool = false, onClose: @escaping () -> Void) {
        self.settings = settings
        self.onClose = onClose
        self.embeddedInMenu = embeddedInMenu
        _draftPlan = State(initialValue: settings.plan)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text(L.t(.workoutPlan, language))
                    .font(.title2.weight(.bold))
                Text(L.t(.planDescription, language))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(L.t(.difficulty, language))
                    .font(.headline)
                Picker(L.t(.difficulty, language), selection: Binding(
                    get: { draftPlan.difficulty },
                    set: { difficulty in
                        draftPlan = .defaultPlan(for: difficulty)
                    }
                )) {
                    ForEach(WorkoutDifficulty.allCases) { difficulty in
                        Text(difficulty.title(language)).tag(difficulty)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .configurationCard()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L.t(.workoutSteps, language))
                            .font(.headline)
                        ForEach(draftPlan.steps.indices, id: \.self) { index in
                            WorkoutStepEditor(
                                step: Binding(
                                    get: { draftPlan.steps[index] },
                                    set: { draftPlan.steps[index] = WorkoutSettingsStore.normalized(WorkoutPlan(difficulty: draftPlan.difficulty, steps: [$0])).steps[0] }
                                ),
                                index: index,
                                canMoveUp: index > 0,
                                canMoveDown: index < draftPlan.steps.count - 1,
                                canRemove: draftPlan.steps.count > 1,
                                moveUp: { moveStep(from: index, offset: -1) },
                                moveDown: { moveStep(from: index, offset: 1) },
                                remove: { removeStep(at: index) },
                                difficulty: draftPlan.difficulty,
                                showExperimentalExercises: settings.showExperimentalExercises,
                                language: language
                            )
                        }

                        Button {
                            draftPlan.steps.append(defaultStepForCurrentDifficulty())
                            draftPlan = WorkoutSettingsStore.normalized(draftPlan)
                        } label: {
                            Label(language == .russian ? "Добавить шаг" : "Add Step", systemImage: "plus.circle.fill")
                        }
                        .buttonStyle(.bordered)
                    }
                    .configurationCard()

                    VStack(alignment: .leading, spacing: 10) {
                        Text(language == .russian ? "Чувствительность скоринга" : "Scoring Sensitivity")
                            .font(.headline)
                        Text(language == .russian ? "Как быстро растет давление, пока ты продолжаешь работать без перерыва." : "How quickly pressure builds while you keep working without a break.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Picker(language == .russian ? "Чувствительность" : "Sensitivity", selection: Binding(
                            get: { settings.scoringSensitivity },
                            set: { settings.setScoringSensitivitySafely($0) }
                        )) {
                            ForEach(ScoringSensitivity.allCases) { sensitivity in
                                Text("\(sensitivity.title(language)) (\(sensitivity.multiplier, specifier: "%.1f")x)").tag(sensitivity)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .configurationCard()

                }
                .padding(.vertical, 2)
            }

            HStack {
                Button(L.t(.resetToDefaults, language)) {
                    draftPlan = .defaultPlan(for: .light)
                }

                Spacer()

                Button(L.t(.cancel, language)) {
                    onClose()
                }

                Button(L.t(.save, language)) {
                    settings.update(plan: draftPlan, rewardSettings: settings.rewardSettings)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(embeddedInMenu ? 0 : 20)
        .frame(width: embeddedInMenu ? nil : 620, height: embeddedInMenu ? nil : 700)
        .background(
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissTextEditing()
                }
        )
        .onChange(of: draftPlan.difficulty) { _, _ in
            draftPlan = WorkoutSettingsStore.normalized(draftPlan)
        }
    }

    private func moveStep(from index: Int, offset: Int) {
        let newIndex = index + offset
        guard draftPlan.steps.indices.contains(index), draftPlan.steps.indices.contains(newIndex) else { return }
        draftPlan.steps.swapAt(index, newIndex)
    }

    private func removeStep(at index: Int) {
        guard draftPlan.steps.indices.contains(index), draftPlan.steps.count > 1 else { return }
        draftPlan.steps.remove(at: index)
    }

    private func defaultStepForCurrentDifficulty() -> WorkoutStep {
        switch draftPlan.difficulty {
        case .light:
            WorkoutStep(mode: .pushUps, targetReps: 10)
        case .medium:
            WorkoutStep(mode: .pushUps, targetReps: 15)
        case .hard, .extreme, .extremePlus:
            WorkoutStep(mode: .pushUps, targetReps: 20)
        }
    }
}

private struct WorkoutStepEditor: View {
    @Binding var step: WorkoutStep
    let index: Int
    let canMoveUp: Bool
    let canMoveDown: Bool
    let canRemove: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void
    let difficulty: WorkoutDifficulty
    let showExperimentalExercises: Bool
    let language: AppLanguage

    private var availableModes: [ExerciseMode] {
        ExerciseMode.allCases.filter { showExperimentalExercises || !$0.isExperimental }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(L.t(.step, language)) \(index + 1)", systemImage: step.mode.systemImage)
                    .font(.headline)
                Spacer()
                Button(action: moveUp) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveUp)
                Button(action: moveDown) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(.borderless)
                .disabled(!canMoveDown)
                Button(role: .destructive, action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(!canRemove)
            }

            Picker(L.t(.exercise, language), selection: Binding(
                get: { step.mode },
                set: { mode in
                    step.mode = mode
                    if mode.isTimed {
                        step.targetSeconds = step.targetSeconds ?? defaultSeconds(for: mode)
                        step.targetReps = nil
                    } else {
                        step.targetReps = defaultReps(for: mode, difficulty: difficulty)
                        step.targetSeconds = nil
                    }
                }
            )) {
                ForEach(availableModes) { mode in
                    Label(mode.title(language), systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.menu)

            if step.mode.isTimed {
                TargetSliderEditor(
                    title: L.t(.seconds, language),
                    value: Binding(
                        get: { step.targetSeconds ?? defaultSeconds(for: step.mode) },
                        set: { step.targetSeconds = $0 }
                    ),
                    range: experimentalHoldModes.contains(step.mode) ? 5...60 : 10...300,
                    step: experimentalHoldModes.contains(step.mode) ? 1 : 5
                )
            } else {
                TargetNumberEditor(
                    title: L.t(.reps, language),
                    value: Binding(
                        get: { step.targetReps ?? 20 },
                        set: { step.targetReps = $0 }
                    ),
                    range: 1...100,
                    step: 1
                )
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }

    private func defaultSeconds(for mode: ExerciseMode) -> Int {
        experimentalHoldModes.contains(mode) ? 5 : 90
    }

    private var experimentalHoldModes: Set<ExerciseMode> {
        [.tuckPlancheHold, .lSitHold, .elbowLeverHold]
    }

    private func defaultReps(for mode: ExerciseMode, difficulty: WorkoutDifficulty) -> Int {
        switch mode {
        case .burpees:
            switch difficulty {
            case .light: return 5
            case .medium: return 7
            case .hard, .extreme, .extremePlus: return 10
            }
        case .mountainClimbers:
            switch difficulty {
            case .light: return 10
            case .medium: return 15
            case .hard: return 20
            case .extreme, .extremePlus: return 30
            }
        case .pushUps, .squats, .abs:
            switch difficulty {
            case .light: return 10
            case .medium: return 15
            case .hard, .extreme, .extremePlus: return 20
            }
        case .plank, .tuckPlancheHold, .lSitHold, .elbowLeverHold:
            return 20
        }
    }
}

private struct TargetSliderEditor: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(title):")
                Spacer()
                Text("\(value)")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }

            Slider(
                value: Binding(
                    get: { Double(value) },
                    set: { newValue in
                        let stepped = Int((newValue / Double(step)).rounded()) * step
                        value = min(range.upperBound, max(range.lowerBound, stepped))
                    }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound),
                step: Double(step)
            )
        }
    }
}

private struct TargetNumberEditor: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int

    @State private var draftValue = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("\(title):")

            TextField("", text: $draftValue)
                .textFieldStyle(.roundedBorder)
                .frame(width: 48)
                .focused($isFocused)
                .onSubmit(commitAndEndEditing)

            if isFocused {
                Button(action: commitAndEndEditing) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .frame(width: 22, height: 22)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }

            StepperButtons(
                decrement: { adjust(by: -step) },
                increment: { adjust(by: step) },
                canDecrement: value > range.lowerBound,
                canIncrement: value < range.upperBound
            )
        }
        .animation(.easeInOut(duration: 0.12), value: isFocused)
        .onAppear {
            draftValue = "\(value)"
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                draftValue = "\(value)"
            } else {
                commitDraft()
            }
        }
    }

    private func adjust(by delta: Int) {
        commitDraft()
        let adjusted = min(range.upperBound, max(range.lowerBound, value + delta))
        value = adjusted
        draftValue = "\(adjusted)"
    }

    private func commitDraft() {
        let trimmed = draftValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed) else {
            draftValue = "\(value)"
            return
        }

        let clamped = min(range.upperBound, max(range.lowerBound, parsed))
        value = clamped
        draftValue = "\(clamped)"
    }

    private func commitAndEndEditing() {
        commitDraft()
        isFocused = false
        dismissTextEditing()
    }
}

private func dismissTextEditing() {
    NSApp.keyWindow?.makeFirstResponder(nil)
}

private struct StepperButtons: View {
    let decrement: () -> Void
    let increment: () -> Void
    let canDecrement: Bool
    let canIncrement: Bool

    var body: some View {
        HStack(spacing: 2) {
            Button(action: decrement) {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .disabled(!canDecrement)

            Button(action: increment) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .disabled(!canIncrement)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private struct RewardSettingEditor: View {
    let difficulty: WorkoutDifficulty
    @Binding var setting: DifficultyRewardSetting
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(difficulty.title(language))
                    .font(.headline)
                Spacer()
                Text("\(Int(setting.multiplier * 100))% / \(setting.minutes)m")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Stepper("\(L.t(.multiplier, language)): \(Int(setting.multiplier * 100))%", value: Binding(
                get: { setting.multiplier },
                set: { setting.multiplier = min(1, max(0.1, $0)) }
            ), in: 0.1...1.0, step: 0.05)
            Stepper("\(L.t(.minutes, language)): \(setting.minutes)", value: Binding(
                get: { setting.minutes },
                set: { setting.minutes = max(0, $0) }
            ), in: 0...240, step: 5)
        }
        .padding(12)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        }
    }
}

private extension View {
    func configurationCard() -> some View {
        padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
    }
}

enum BreakPressure: String {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case critical = "Critical"

    var title: String { rawValue }

    func title(_ language: AppLanguage) -> String {
        switch (self, language) {
        case (.low, .english): "Low"
        case (.low, .russian): "Низкое"
        case (.medium, .english): "Medium"
        case (.medium, .russian): "Среднее"
        case (.high, .english): "High"
        case (.high, .russian): "Высокое"
        case (.critical, .english): "Critical"
        case (.critical, .russian): "Критичное"
        }
    }
}

enum GateStartReason {
    case manual
    case scoreTrigger
}

private struct GateWarningNotificationService {
    static func sendInitialWarning(delay: GateWarningDelay, language: AppLanguage) {
        let content = UNMutableNotificationContent()
        content.title = language == .russian ? "BreakGate скоро активируется" : "BreakGate will activate soon"
        content.body = language == .russian
            ? "Гейт будет активирован через \(delay.title(language))."
            : "The gate will activate in \(delay.title(language))."
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let request = UNNotificationRequest(
            identifier: "BreakGateWorkout.gateWarning.initial.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func scheduleSecondaryReminder(delay: GateWarningDelay, reminder: GateSecondaryReminder, language: AppLanguage) {
        guard reminder != .off, delay.allowsSecondaryReminder, delay.rawValue > reminder.rawValue else { return }

        let content = UNMutableNotificationContent()
        content.title = language == .russian ? "BreakGate почти активен" : "BreakGate is almost active"
        content.body = language == .russian
            ? "Гейт активируется \(reminder.notificationTimingTitle(language))."
            : "The gate activates \(reminder.notificationTimingTitle(language))."
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let triggerDelay = TimeInterval(delay.rawValue - reminder.rawValue)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: triggerDelay, repeats: false)
        let request = UNNotificationRequest(
            identifier: "BreakGateWorkout.gateWarning.secondary.\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        UNUserNotificationCenter.current().add(request)
    }
}

@MainActor
final class BreakGateMonitor: ObservableObject {
    @Published private(set) var activityScore: Double = 0
    @Published private(set) var breakPressure: BreakPressure = .low
    @Published private(set) var gateActive = false
    @Published private(set) var lastWorkoutDate: Date?
    @Published private(set) var scoreReward: ScoreReward
    @Published var isMonitoringEnabled = true
    @Published private(set) var scoringSensitivity: ScoringSensitivity = .normal

    private var monitorTask: Task<Void, Never>?
    private var pendingGateTask: Task<Void, Never>?
    private var gateWarningDelay: GateWarningDelay = .minute1
    private var secondaryGateReminder: GateSecondaryReminder = .off
    private var appLanguage: AppLanguage = .english
    private let defaults = UserDefaults.standard
    private let scoreRewardKey = "BreakGateWorkout.scoreReward"

    init() {
        if let data = defaults.data(forKey: scoreRewardKey),
           let decodedReward = try? JSONDecoder().decode(ScoreReward.self, from: data) {
            scoreReward = decodedReward
        } else {
            scoreReward = ScoreReward(multiplier: 1, expiresAt: nil)
        }

        clearExpiredRewardIfNeeded()
    }

    var currentScoreMultiplier: Double {
        return scoreReward.isActive ? scoreReward.multiplier : 1
    }

    var rewardRemainingDescription: String {
        guard let expiresAt = scoreReward.expiresAt, scoreReward.isActive else {
            return "None"
        }

        let remainingMinutes = max(0, Int(ceil(expiresAt.timeIntervalSinceNow / 60)))
        return "\(remainingMinutes)m"
    }

    func start() {
        guard monitorTask == nil else { return }

        DiagnosticLog.log("monitor task started")
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.tick()
            }
        }
    }

    func setMonitoringEnabled(_ isEnabled: Bool) {
        isMonitoringEnabled = isEnabled
        if !isEnabled {
            cancelPendingGateWarning()
        }
    }

    func setScoringSensitivity(_ sensitivity: ScoringSensitivity) {
        scoringSensitivity = sensitivity
    }

    func setGateWarningSettings(delay: GateWarningDelay, secondaryReminder: GateSecondaryReminder, language: AppLanguage) {
        gateWarningDelay = delay
        secondaryGateReminder = delay.allowsSecondaryReminder ? secondaryReminder : .off
        appLanguage = language
    }

    func startGate(reason: GateStartReason) {
        print("BreakGateWorkout gate: requested (\(reason))")
        switch reason {
        case .manual:
            activateGate(reason: reason)
        case .scoreTrigger:
            scheduleGateWarning()
        }
    }

    func triggerGate() {
        startGate(reason: .manual)
    }

    func resetCurrentGate() {
        cancelPendingGateWarning()
        gateActive = false
    }

    func resetScore() {
        activityScore = 0
        breakPressure = .low
    }

    func recordWorkoutCompletion(difficulty: WorkoutDifficulty, rewardSetting: DifficultyRewardSetting, date: Date = Date()) {
        activityScore = 0
        breakPressure = .low
        cancelPendingGateWarning()
        gateActive = false
        lastWorkoutDate = date
        applyReward(difficulty: difficulty, setting: rewardSetting, date: date)
    }

    private func tick() {
        guard isMonitoringEnabled else { return }
        clearExpiredRewardIfNeeded()

        let idleSeconds = currentSystemIdleSeconds()
        let scoreBefore = activityScore
        if idleSeconds < 60 {
            activityScore += 4 * currentScoreMultiplier * scoringSensitivity.multiplier
        } else if idleSeconds > 300 {
            activityScore -= 8
        }

        activityScore = min(100, max(0, activityScore))
        breakPressure = pressure(for: activityScore)
        DiagnosticLog.log(
            String(
                format: "monitor tick idle=%.1fs score %.1f -> %.1f pressure=%@ gateActive=%@ pendingGate=%@",
                idleSeconds,
                scoreBefore,
                activityScore,
                breakPressure.rawValue,
                String(gateActive),
                String(pendingGateTask != nil)
            )
        )

        guard !gateActive, pendingGateTask == nil, randomTriggerShouldFire(score: activityScore) else { return }
        startGate(reason: .scoreTrigger)
    }

    private func scheduleGateWarning() {
        guard pendingGateTask == nil, !gateActive else { return }
        let delay = gateWarningDelay
        let reminder = secondaryGateReminder
        let language = appLanguage
        print("BreakGateWorkout gate: warning scheduled for \(delay.rawValue)s")

        GateWarningNotificationService.sendInitialWarning(delay: delay, language: language)
        GateWarningNotificationService.scheduleSecondaryReminder(
            delay: delay,
            reminder: reminder,
            language: language
        )

        pendingGateTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay.rawValue))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.pendingGateTask = nil
                self.activateGate(reason: .scoreTrigger)
            }
        }
    }

    private func activateGate(reason: GateStartReason) {
        cancelPendingGateWarning()
        print("BreakGateWorkout gate: activated (\(reason))")
        gateActive = true
    }

    private func cancelPendingGateWarning() {
        pendingGateTask?.cancel()
        pendingGateTask = nil
    }

    private func applyReward(difficulty: WorkoutDifficulty, setting: DifficultyRewardSetting, date: Date) {
        guard difficulty != .light, setting.minutes > 0, setting.multiplier < 1 else {
            scoreReward = ScoreReward(multiplier: 1, expiresAt: nil)
            saveReward()
            return
        }

        scoreReward = ScoreReward(
            multiplier: setting.multiplier,
            expiresAt: date.addingTimeInterval(TimeInterval(setting.minutes * 60))
        )
        saveReward()
    }

    private func clearExpiredRewardIfNeeded() {
        guard let expiresAt = scoreReward.expiresAt, expiresAt <= Date() else { return }
        scoreReward = ScoreReward(multiplier: 1, expiresAt: nil)
        saveReward()
    }

    private func saveReward() {
        if let data = try? JSONEncoder().encode(scoreReward) {
            defaults.set(data, forKey: scoreRewardKey)
        }
    }

    private func pressure(for score: Double) -> BreakPressure {
        switch score {
        case 0..<40:
            return .low
        case 40..<70:
            return .medium
        case 70..<90:
            return .high
        default:
            return .critical
        }
    }

    private func randomTriggerShouldFire(score: Double) -> Bool {
        let chance: Double
        switch score {
        case ..<50:
            chance = 0
        case 50..<70:
            chance = 0.05
        case 70..<85:
            chance = 0.20
        case 85..<95:
            chance = 0.45
        case 95..<100:
            chance = 0.80
        default:
            chance = 1
        }

        return Double.random(in: 0...1) < chance
    }

    private func currentSystemIdleSeconds() -> Double {
        let eventTypes: [CGEventType] = [
            .mouseMoved,
            .leftMouseDown,
            .rightMouseDown,
            .keyDown,
            .scrollWheel
        ]

        let idleTimes = eventTypes.map {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0)
        }

        return idleTimes.filter(\.isFinite).min() ?? 0
    }
}

@MainActor
final class WorkoutStats: ObservableObject {
    @Published private(set) var totalWorkoutsCompleted: Int {
        didSet { save() }
    }
    @Published private(set) var totalPushUps: Int {
        didSet { save() }
    }
    @Published private(set) var totalSquats: Int {
        didSet { save() }
    }
    @Published private(set) var totalSitUps: Int {
        didSet { save() }
    }
    @Published private(set) var totalPlankSeconds: Int {
        didSet { save() }
    }
    @Published private(set) var totalBurpees: Int {
        didSet { save() }
    }
    @Published private(set) var totalMountainClimbers: Int {
        didSet { save() }
    }
    @Published private(set) var totalLSitSeconds: Int {
        didSet { save() }
    }
    @Published private(set) var totalElbowLeverSeconds: Int {
        didSet { save() }
    }
    @Published private(set) var lastWorkoutDate: Date? {
        didSet { save() }
    }

    var lastWorkoutDescription: String {
        guard let lastWorkoutDate else { return "Never" }
        return lastWorkoutDate.formatted(date: .abbreviated, time: .shortened)
    }

    func lastWorkoutDescription(_ language: AppLanguage) -> String {
        guard let lastWorkoutDate else {
            return language == .russian ? "Никогда" : "Never"
        }
        return lastWorkoutDate.formatted(date: .abbreviated, time: .shortened)
    }

    private let defaults = UserDefaults.standard
    private let totalWorkoutsKey = "BreakGateWorkout.totalWorkoutsCompleted"
    private let totalPushUpsKey = "BreakGateWorkout.totalPushUps"
    private let totalSquatsKey = "BreakGateWorkout.totalSquats"
    private let totalSitUpsKey = "BreakGateWorkout.totalSitUps"
    private let totalPlankSecondsKey = "BreakGateWorkout.totalPlankSeconds"
    private let totalBurpeesKey = "BreakGateWorkout.totalBurpees"
    private let totalMountainClimbersKey = "BreakGateWorkout.totalMountainClimbers"
    private let totalLSitSecondsKey = "BreakGateWorkout.totalLSitSeconds"
    private let totalElbowLeverSecondsKey = "BreakGateWorkout.totalElbowLeverSeconds"
    private let lastWorkoutDateKey = "BreakGateWorkout.lastWorkoutDate"

    init() {
        totalWorkoutsCompleted = defaults.integer(forKey: totalWorkoutsKey)
        totalPushUps = defaults.integer(forKey: totalPushUpsKey)
        totalSquats = defaults.integer(forKey: totalSquatsKey)
        totalSitUps = defaults.integer(forKey: totalSitUpsKey)
        totalPlankSeconds = defaults.integer(forKey: totalPlankSecondsKey)
        totalBurpees = defaults.integer(forKey: totalBurpeesKey)
        totalMountainClimbers = defaults.integer(forKey: totalMountainClimbersKey)
        totalLSitSeconds = defaults.integer(forKey: totalLSitSecondsKey)
        totalElbowLeverSeconds = defaults.integer(forKey: totalElbowLeverSecondsKey)
        lastWorkoutDate = defaults.object(forKey: lastWorkoutDateKey) as? Date
    }

    func recordWorkoutCompletion(mode: ExerciseMode, amount: Int, date: Date = Date()) {
        recordWorkoutCompletion(steps: [WorkoutStep(mode: mode, targetReps: mode.isTimed ? nil : amount, targetSeconds: mode.isTimed ? amount : nil)], date: date)
    }

    func recordWorkoutCompletion(steps: [WorkoutStep], date: Date = Date()) {
        totalWorkoutsCompleted += 1
        lastWorkoutDate = date

        for step in steps {
            switch step.mode {
            case .pushUps:
                totalPushUps += step.targetReps ?? 0
            case .squats:
                totalSquats += step.targetReps ?? 0
            case .abs:
                totalSitUps += step.targetReps ?? 0
            case .plank:
                totalPlankSeconds += step.targetSeconds ?? 0
            case .tuckPlancheHold:
                totalPlankSeconds += step.targetSeconds ?? 0
            case .burpees:
                totalBurpees += step.targetReps ?? 0
            case .mountainClimbers:
                totalMountainClimbers += step.targetReps ?? 0
            case .lSitHold:
                totalLSitSeconds += step.targetSeconds ?? 0
            case .elbowLeverHold:
                totalElbowLeverSeconds += step.targetSeconds ?? 0
            }
        }
    }

    func resetAll() {
        totalWorkoutsCompleted = 0
        totalPushUps = 0
        totalSquats = 0
        totalSitUps = 0
        totalPlankSeconds = 0
        totalBurpees = 0
        totalMountainClimbers = 0
        totalLSitSeconds = 0
        totalElbowLeverSeconds = 0
        lastWorkoutDate = nil
    }

    private func save() {
        defaults.set(totalWorkoutsCompleted, forKey: totalWorkoutsKey)
        defaults.set(totalPushUps, forKey: totalPushUpsKey)
        defaults.set(totalSquats, forKey: totalSquatsKey)
        defaults.set(totalSitUps, forKey: totalSitUpsKey)
        defaults.set(totalPlankSeconds, forKey: totalPlankSecondsKey)
        defaults.set(totalBurpees, forKey: totalBurpeesKey)
        defaults.set(totalMountainClimbers, forKey: totalMountainClimbersKey)
        defaults.set(totalLSitSeconds, forKey: totalLSitSecondsKey)
        defaults.set(totalElbowLeverSeconds, forKey: totalElbowLeverSecondsKey)
        defaults.set(lastWorkoutDate, forKey: lastWorkoutDateKey)
    }
}
