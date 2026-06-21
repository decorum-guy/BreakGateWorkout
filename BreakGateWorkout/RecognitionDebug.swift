import AppKit
@preconcurrency import AVFoundation
import Combine
import Darwin
import SwiftUI
import UniformTypeIdentifiers

enum DeveloperContactConfig {
    static let developerEmail = "TODO_INSERT_DEVELOPER_EMAIL"
    static let telegramURLString = "https://t.me/TODO_INSERT_TELEGRAM"
}

@MainActor
final class RecognitionDebugWindowController {
    static let shared = RecognitionDebugWindowController()

    private var window: NSWindow?
    private var windowDelegate: WindowDelegate?

    private init() {}

    func show(settings: WorkoutSettingsStore) {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let contentView = RecognitionDebugContributionView(settings: settings) { [weak self] in
            self?.close()
        }
        let hostingController = NSHostingController(rootView: contentView)
        let screenFrame = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let debugWindow = NSWindow(
            contentRect: screenFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        debugWindow.title = settings.appLanguage == .russian ? "Помочь улучшить распознавание" : "Help Improve Recognition"
        debugWindow.contentViewController = hostingController
        debugWindow.isReleasedWhenClosed = false
        debugWindow.minSize = NSSize(width: 1180, height: 780)
        debugWindow.collectionBehavior = [.fullScreenPrimary, .managed]
        debugWindow.backgroundColor = .black
        debugWindow.setFrame(screenFrame, display: true)
        let delegate = WindowDelegate()
        debugWindow.delegate = delegate
        windowDelegate = delegate
        window = debugWindow

        NSApp.activate(ignoringOtherApps: true)
        debugWindow.makeKeyAndOrderFront(nil)
        debugWindow.orderFrontRegardless()
    }

    func close() {
        window?.close()
        window = nil
        windowDelegate = nil
    }

    private final class WindowDelegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            RecognitionDebugWindowController.shared.window = nil
            RecognitionDebugWindowController.shared.windowDelegate = nil
        }
    }
}

private struct RecognitionDebugContributionView: View {
    private enum Phase {
        case intro
        case exercise
        case review
        case summary
    }

    @ObservedObject var settings: WorkoutSettingsStore
    @StateObject private var camera = CameraModel()
    @StateObject private var recorder: RecognitionDebugRecorder

    let onDone: () -> Void

    @State private var phase: Phase = .intro
    @State private var currentStepIndex = 0
    @State private var currentStepStarted = false
    @State private var reviews: [RecognitionDebugExerciseReview] = []
    @State private var performanceRating = 4
    @State private var recognitionRating = RecognitionAccuracyRating.partly
    @State private var reviewComment = ""
    @State private var reviewWasManual = false
    @State private var reviewWasSkipped = false
    @State private var exportURL: URL?
    @State private var exportErrorMessage: String?
    @State private var exportStatusMessage: String?
    @State private var shouldRecordVideo = false
    @State private var selectedExerciseModes: Set<ExerciseMode>
    @State private var cameraPlacement = RecognitionDebugCameraPlacement.defaultPlacement
    @State private var didConfigure = false
    @State private var teardownTask: Task<Void, Never>?

    private var language: AppLanguage { settings.appLanguage }

    private var allDebugSteps: [RecognitionDebugExerciseStep] {
        [
            .reps(.pushUps, 5),
            .reps(.squats, 5),
            .reps(.abs, 5),
            .seconds(.plank, 10),
            .reps(.burpees, 3),
            .reps(.mountainClimbers, 10),
            .seconds(.tuckPlancheHold, 5),
            .seconds(.lSitHold, 5),
            .seconds(.elbowLeverHold, 5),
            .reps(.pikePushUps, 3)
        ]
    }

    private var steps: [RecognitionDebugExerciseStep] {
        allDebugSteps.filter { selectedExerciseModes.contains($0.mode) }
    }

    private var regularSteps: [RecognitionDebugExerciseStep] {
        allDebugSteps.filter { !$0.mode.isRecognitionDebugExperimental }
    }

    private var experimentalSteps: [RecognitionDebugExerciseStep] {
        allDebugSteps.filter(\.mode.isRecognitionDebugExperimental)
    }

    private var canStartSession: Bool {
        !steps.isEmpty
    }

    private var currentStep: RecognitionDebugExerciseStep? {
        guard steps.indices.contains(currentStepIndex) else { return nil }
        return steps[currentStepIndex]
    }

    init(settings: WorkoutSettingsStore, onDone: @escaping () -> Void) {
        self.settings = settings
        self.onDone = onDone
        _recorder = StateObject(wrappedValue: RecognitionDebugRecorder(language: settings.appLanguage))
        _selectedExerciseModes = State(initialValue: Set(RecognitionDebugContributionView.defaultDebugSteps.map(\.mode)))
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.05, green: 0.07, blue: 0.10), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            switch phase {
            case .intro:
                introView
            case .exercise:
                exerciseView
            case .review:
                reviewView
            case .summary:
                summaryView
            }
        }
        .foregroundStyle(.white)
        .frame(minWidth: 1180, minHeight: 780)
        .onAppear(perform: handleAppear)
        .onDisappear {
            scheduleTeardown()
        }
        .alert(
            language == .russian ? "Не удалось экспортировать файл" : "Could not export file",
            isPresented: Binding(
                get: { exportErrorMessage != nil },
                set: { if !$0 { exportErrorMessage = nil } }
            )
        ) {
            Button("OK") {
                exportErrorMessage = nil
            }
        } message: {
            Text(exportErrorMessage ?? "")
        }
    }

    private var introView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label(language == .russian ? "Помочь улучшить распознавание" : "Help Improve Recognition", systemImage: "figure.run.square.stack")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundStyle(.green)

                Text(language == .russian
                    ? "Этот режим по умолчанию записывает обезличенные данные скелета и решения распознавания, а не видео. Вы сможете сами решить, отправлять ли debug-файл разработчику.\n\nВидео может содержать вас и комнату. Это необязательно и никогда не отправляется автоматически."
                    : "This mode records anonymized pose/skeleton data and recognition decisions, not video by default. You can review and choose whether to share the debug file with the developer.\n\nVideo may include you and your room. It is optional and is never sent automatically."
                )
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white.opacity(0.82))
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 10) {
                    privacyLine("video.slash.fill", language == .russian ? "Видео записывается только если включить опцию ниже" : "Video is recorded only if you enable it below")
                    privacyLine("mic.slash.fill", language == .russian ? "Звук не записывается" : "No audio is recorded")
                    privacyLine("point.3.connected.trianglepath.dotted", language == .russian ? "Сохраняются только точки скелета, уверенность и решения распознавания" : "Only skeleton points, confidence, and recognition decisions are saved")
                    privacyLine("square.and.arrow.up", language == .russian ? "Отправка только вручную после теста" : "Sharing is manual after the test")
                }
                .padding(18)
                .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Toggle(isOn: $shouldRecordVideo) {
                    Text(language == .russian ? "Также записать короткое видео для повторного анализа" : "Also record short video for replay analysis")
                        .font(.headline.weight(.semibold))
                }
                .toggleStyle(.checkbox)
                .foregroundStyle(.white.opacity(0.86))

                exerciseSelectionPanel

                debugCameraSourcePanel

                HStack {
                    Button {
                        startSession()
                    } label: {
                        Label(language == .russian ? "Начать тест распознавания" : "Start Recognition Test", systemImage: "play.fill")
                            .frame(minWidth: 220)
                    }
                    .buttonStyle(RecognitionDebugButtonStyle(kind: .primary))
                    .disabled(!canStartSession)

                    Button {
                        onDone()
                    } label: {
                        Text(language == .russian ? "Отмена" : "Cancel")
                            .frame(minWidth: 120)
                    }
                    .buttonStyle(RecognitionDebugButtonStyle(kind: .secondary))
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(44)
        }
    }

    private func privacyLine(_ systemImage: String, _ text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.white.opacity(0.82))
    }

    private var exerciseSelectionPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Label(language == .russian ? "Упражнения для debug-теста" : "Exercises for Debug Test", systemImage: "checklist")
                    .font(.headline.weight(.semibold))
                Spacer()
                Text("\(steps.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)
            }

            HStack(spacing: 10) {
                Button(language == .russian ? "Выбрать все" : "Select All") {
                    selectedExerciseModes = Set(allDebugSteps.map(\.mode))
                }
                .buttonStyle(RecognitionDebugButtonStyle(kind: .secondary))

                Button(language == .russian ? "Снять выбор" : "Clear") {
                    selectedExerciseModes.removeAll()
                }
                .buttonStyle(RecognitionDebugButtonStyle(kind: .secondary))
            }

            exerciseModeGroup(
                title: language == .russian ? "Обычные упражнения" : "Regular exercises",
                steps: regularSteps
            )

            if !experimentalSteps.isEmpty {
                exerciseModeGroup(
                    title: language == .russian ? "Экспериментальные упражнения" : "Experimental exercises",
                    steps: experimentalSteps
                )
            }

            if !canStartSession {
                Label(
                    language == .russian
                        ? "Выбери хотя бы одно упражнение, чтобы начать тест."
                        : "Select at least one exercise to start the test.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption.weight(.semibold))
                .foregroundStyle(.yellow)
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private func exerciseModeGroup(title: String, steps: [RecognitionDebugExerciseStep]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                ForEach(steps) { step in
                    RecognitionDebugExerciseModeButton(
                        mode: step.mode,
                        isSelected: selectedExerciseModes.contains(step.mode),
                        language: language
                    ) {
                        toggleExerciseSelection(step.mode)
                    }
                }
            }
        }
    }

    private var debugCameraSourcePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(language == .russian ? "Камера для debug-теста" : "Debug Test Camera", systemImage: "camera.fill")
                    .font(.headline.weight(.semibold))
                Spacer()
                Text(camera.selectedCameraName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Button {
                    camera.selectMacCamera()
                } label: {
                    Label(language == .russian ? "Mac" : "Mac", systemImage: "macbook")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RecognitionDebugButtonStyle(kind: .secondary))
                .disabled(!camera.hasMacCamera)

                Button {
                    camera.selectIPhoneCamera()
                } label: {
                    Label(language == .russian ? "iPhone" : "iPhone", systemImage: "iphone")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(RecognitionDebugButtonStyle(kind: camera.selectedDeviceIsIPhone ? .primary : .secondary))
                .disabled(!camera.hasIPhoneCamera)

                Button {
                    camera.refreshCameraDevices()
                } label: {
                    Label(language == .russian ? "Обновить" : "Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(RecognitionDebugButtonStyle(kind: .secondary))
            }

            if camera.hasIPhoneCamera {
                Text(language == .russian
                    ? "Можно выбрать iPhone Continuity Camera перед стартом теста. Это не iPhone Stream и не требует iOS-приложения."
                    : "You can select iPhone Continuity Camera before starting the test. This is not iPhone Stream and does not require an iOS app."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(language == .russian
                    ? "Если iPhone не появился, включи Continuity Camera рядом с Mac и нажми Обновить."
                    : "If iPhone does not appear, enable Continuity Camera near your Mac and press Refresh."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Label(camera.statusMessage, systemImage: camera.statusIsError ? "exclamationmark.triangle.fill" : (camera.isSwitchingCamera ? "arrow.triangle.2.circlepath" : "camera.aperture"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(camera.statusIsError ? .yellow : .secondary)
        }
        .padding(16)
        .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var exerciseView: some View {
        HStack(alignment: .top, spacing: 22) {
            recognitionCameraView

            VStack(alignment: .leading, spacing: 14) {
                Text("\(currentStepIndex + 1) / \(steps.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.green)

                Text(currentStep?.mode.title(language) ?? "")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                Text(currentStep?.targetText(language) ?? "")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.72))

                Text(language == .russian
                    ? "Выполни упражнение чётко. Программа может перейти дальше сама, либо нажми Далее после выполнения."
                    : "Perform the exercise clearly. Continue when the app recognizes it or press Next when done."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    debugLine(language == .russian ? "Состояние" : "State", camera.currentPoseState)
                    debugLine(language == .russian ? "Распознано" : "Detected", detectedText)
                    debugLine(language == .russian ? "Уверенность" : "Confidence", String(format: "%.2f", camera.confidence))
                    debugLine(language == .russian ? "Камера" : "Camera", camera.selectedCameraName)
                }
                .padding(14)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                Spacer()

                VStack(spacing: 10) {
                    Button {
                        beginCurrentStep()
                    } label: {
                        Label(language == .russian ? "Начать" : "Start", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RecognitionDebugButtonStyle(kind: .primary))
                    .disabled(currentStepStarted)

                    HStack(spacing: 10) {
                        Button {
                            presentReview(manual: true, skipped: false)
                        } label: {
                            Text(language == .russian ? "Далее" : "Next")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RecognitionDebugButtonStyle(kind: .secondary))

                        Button {
                            presentReview(manual: true, skipped: true)
                        } label: {
                            Text(language == .russian ? "Пропустить" : "Skip")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(RecognitionDebugButtonStyle(kind: .secondary))
                    }

                    Button {
                        finishSession()
                    } label: {
                        Text(language == .russian ? "Остановить тест" : "Stop Test")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(RecognitionDebugButtonStyle(kind: .danger))
                }
            }
            .frame(width: 330)
        }
        .padding(26)
    }

    private var recognitionCameraView: some View {
        ZStack(alignment: .topLeading) {
            CameraPreview(session: camera.session)
                .background(Color.black)
                .overlay {
                    if camera.statusIsError || camera.isSwitchingCamera || camera.session == nil || !camera.hasReceivedCameraFrame {
                        RecognitionDebugCameraPlaceholder(camera: camera, language: language)
                    }
                }
                .overlay {
                    RecognitionSkeletonOverlay(points: camera.posePoints, videoSize: camera.previewVideoSize)
                }
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(camera.isPersonDetected ? (language == .russian ? "Скелет найден" : "Skeleton detected") : (language == .russian ? "Встань в кадр" : "Step into frame"), systemImage: camera.isPersonDetected ? "checkmark.circle.fill" : "figure.stand")
                        Label(camera.currentPoseState, systemImage: "waveform.path.ecg")
                    }
                    .font(.caption.weight(.semibold))
                    .padding(12)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(16)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(camera.statusIsError ? Color.red.opacity(0.42) : Color.green.opacity(0.28), lineWidth: 1)
        }
        .aspectRatio(camera.previewAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 620)
    }

    private func debugLine(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.caption.weight(.semibold))
    }

    private var detectedText: String {
        guard let currentStep else { return "0 / 0" }
        if currentStep.mode.isTimed {
            let held = max(0, Int((camera.plankDuration - camera.plankTimeRemaining).rounded(.down)))
            return "\(held) / \(currentStep.targetAmount)s"
        }
        return "\(camera.repCount) / \(currentStep.targetAmount)"
    }

    private var reviewView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(currentStep?.mode.title(language) ?? "")
                    .font(.system(size: 30, weight: .bold, design: .rounded))

                Text(language == .russian ? "Насколько хорошо ты выполнил это упражнение?" : "How well did you perform this exercise?")
                    .font(.headline)

                Picker("", selection: $performanceRating) {
                    ForEach(1...5, id: \.self) { rating in
                        Text(performanceTitle(rating)).tag(rating)
                    }
                }
                .pickerStyle(.segmented)

                Text(language == .russian ? "Приложение распознало упражнение правильно?" : "Did the app recognize it correctly?")
                    .font(.headline)

                Picker("", selection: $recognitionRating) {
                    ForEach(RecognitionAccuracyRating.allCases) { rating in
                        Text(rating.title(language)).tag(rating)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 10) {
                    Text(language == .russian ? "Как стояла камера?" : "How was the camera positioned?")
                        .font(.headline)

                    Text(language == .russian
                        ? "Это поможет понять, мешали ли распознаванию угол, высота, расстояние или обрезанное тело в кадре."
                        : "This helps understand whether recognition failed because of angle, height, distance, or body cropping."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    CameraPlacementSelectorView(placement: $cameraPlacement, language: language)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(language == .russian ? "Расстояние до камеры" : "Camera distance")
                            .font(.subheadline.weight(.semibold))

                        Picker("", selection: Binding(
                            get: { cameraPlacement.distanceValue },
                            set: { cameraPlacement.distanceValue = $0 }
                        )) {
                            ForEach(RecognitionDebugCameraDistance.allCases) { distance in
                                Text(distance.title(language)).tag(distance)
                            }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text(language == .russian ? "Тело полностью было в кадре?" : "Was your full body visible?")
                            .font(.subheadline.weight(.semibold))

                        Picker("", selection: Binding(
                            get: { cameraPlacement.bodyFramingValue },
                            set: { cameraPlacement.bodyFramingValue = $0 }
                        )) {
                            ForEach(RecognitionDebugBodyFraming.allCases) { framing in
                                Text(framing.title(language)).tag(framing)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }

                Text(language == .russian ? "Комментарий" : "Comment")
                    .font(.headline)
                TextEditor(text: $reviewComment)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 110)
                    .padding(10)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                HStack {
                    Button {
                        saveReviewAndContinue()
                    } label: {
                        Label(currentStepIndex + 1 >= steps.count ? (language == .russian ? "Завершить" : "Finish") : (language == .russian ? "Далее" : "Next"), systemImage: "arrow.right")
                            .frame(minWidth: 160)
                    }
                    .buttonStyle(RecognitionDebugButtonStyle(kind: .primary))

                    Button {
                        finishSession()
                    } label: {
                        Text(language == .russian ? "Остановить тест" : "Stop Test")
                            .frame(minWidth: 150)
                    }
                    .buttonStyle(RecognitionDebugButtonStyle(kind: .danger))
                }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(44)
        }
    }

    private var summaryView: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(language == .russian ? "Debug-файл готов" : "Debug File Ready")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(.green)

            Text(language == .russian
                ? (recorder.videoRecorded ? "Звук не сохранялся. Видео записано только потому, что ты включил эту опцию. Ты сам решаешь, отправлять ли файл разработчику." : "Видео и звук не сохранялись. Ты сам решаешь, отправлять ли файл разработчику.")
                : (recorder.videoRecorded ? "No audio was saved. Video was recorded only because you enabled it. You choose whether to share the file with the developer." : "No video or audio was saved. You choose whether to share the file with the developer.")
            )
            .font(.headline)
            .foregroundStyle(.white.opacity(0.76))

            VStack(alignment: .leading, spacing: 8) {
                debugLine(language == .russian ? "Упражнений завершено" : "Exercises completed", "\(reviews.filter { !$0.skipped }.count)")
                debugLine(language == .russian ? "Упражнений пропущено" : "Exercises skipped", "\(reviews.filter(\.skipped).count)")
                debugLine(language == .russian ? "Сэмплов записано" : "Samples recorded", "\(recorder.sampleCount)")
                debugLine(language == .russian ? "Видео запрошено" : "Video requested", recorder.videoRequested ? (language == .russian ? "Да" : "Yes") : (language == .russian ? "Нет" : "No"))
                debugLine(language == .russian ? "Видео записано" : "Video recorded", recorder.videoRecorded ? (language == .russian ? "Да" : "Yes") : (language == .russian ? "Нет" : "No"))
                if recorder.videoRecorded {
                    debugLine(language == .russian ? "Длительность видео" : "Video duration", String(format: "%.1fs", recorder.videoDurationSeconds))
                }
                debugLine(language == .russian ? "Размер ZIP" : "ZIP file size", recorder.formattedFileSize(for: exportURL))
                debugLine(language == .russian ? "Статус экспорта" : "Export status", exportStatusMessage ?? (exportURL == nil ? (language == .russian ? "Ошибка" : "Failed") : (language == .russian ? "ZIP готов" : "ZIP ready")))
            }
            .padding(14)
            .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if let videoError = recorder.videoError, recorder.videoRequested {
                Label(videoError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.yellow)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                Button(language == .russian ? "Сохранить debug-файл" : "Save Debug File") { saveDebugFile() }
                    .buttonStyle(RecognitionDebugButtonStyle(kind: .secondary))
                Button(language == .russian ? "Поделиться debug-файлом" : "Share Debug File") { shareDebugFile() }
                    .buttonStyle(RecognitionDebugButtonStyle(kind: .secondary))
                Button(language == .russian ? "Отправить по почте" : "Send by Email") { sendByEmail() }
                    .buttonStyle(RecognitionDebugButtonStyle(kind: .secondary))
                Button(language == .russian ? "Открыть Telegram" : "Open Telegram") { openTelegram() }
                    .buttonStyle(RecognitionDebugButtonStyle(kind: .secondary))
                Button(language == .russian ? "Скопировать контакты разработчика" : "Copy Developer Contacts") { copyDeveloperContacts() }
                    .buttonStyle(RecognitionDebugButtonStyle(kind: .secondary))
                Button(language == .russian ? "Готово" : "Done") { onDone() }
                    .buttonStyle(RecognitionDebugButtonStyle(kind: .primary))
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .padding(44)
    }

    private func handleAppear() {
        teardownTask?.cancel()
        teardownTask = nil

        guard !didConfigure else { return }
        didConfigure = true
        configure()
    }

    private func scheduleTeardown() {
        teardownTask?.cancel()
        teardownTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            teardown()
        }
    }

    private func teardown() {
        guard didConfigure else { return }
        didConfigure = false
        camera.stopRecognitionDebugSession()
        camera.onRecognitionDebugVideoSampleBuffer = nil
        recorder.cancel()
        camera.stop()
    }

    private func configure() {
        camera.setAppLanguage(language)
        camera.setExperimentalExercisesVisible(true)
        camera.setSkeletonOverlayVisible(true)
        camera.onRecognitionDebugPoseUpdate = { _, update in
            guard let currentStep else { return }
            recorder.record(camera: camera, update: update, step: currentStep, stepIndex: currentStepIndex)
        }
        camera.onRecognitionDebugVideoSampleBuffer = { sampleBuffer in
            recorder.appendVideoSampleBuffer(sampleBuffer)
        }
        camera.onRecognitionDebugStepCompleted = {
            guard phase == .exercise else { return }
            presentReview(manual: false, skipped: false)
        }

        Task {
            await camera.start()
        }
    }

    private func startSession() {
        guard canStartSession else { return }
        recorder.start(language: language, recordVideo: shouldRecordVideo)
        reviews = []
        phase = .exercise
        currentStepIndex = 0
        currentStepStarted = false
    }

    private func beginCurrentStep() {
        guard let currentStep else { return }
        currentStepStarted = true
        camera.startRecognitionDebugStep(currentStep.workoutStep)
        recorder.markStepStarted(currentStep, stepIndex: currentStepIndex)
    }

    private func presentReview(manual: Bool, skipped: Bool) {
        reviewWasManual = manual
        reviewWasSkipped = skipped
        performanceRating = skipped ? 3 : 4
        recognitionRating = skipped ? .no : .partly
        reviewComment = ""
        cameraPlacement = reviews.last?.cameraPlacement ?? .defaultPlacement
        camera.stopRecognitionDebugSession()
        phase = .review
    }

    private func saveReviewAndContinue() {
        reviews.append(
            RecognitionDebugExerciseReview(
                exerciseMode: currentStep?.mode.rawValue ?? ExerciseMode.pushUps.rawValue,
                stepIndex: currentStepIndex,
                target: currentStep?.targetAmount ?? 0,
                detectedResult: (currentStep?.mode.isTimed ?? false)
                    ? max(0, Int((camera.plankDuration - camera.plankTimeRemaining).rounded(.down)))
                    : camera.repCount,
                userCompletedManually: reviewWasManual,
                skipped: reviewWasSkipped,
                userPerformanceRating: performanceRating,
                recognitionAccuracyRating: recognitionRating.rawValue,
                userComment: reviewComment,
                cameraPlacement: cameraPlacement
            )
        )

        guard currentStepIndex + 1 < steps.count else {
            finishSession()
            return
        }

        currentStepIndex += 1
        currentStepStarted = false
        phase = .exercise
    }

    private func finishSession() {
        camera.stopRecognitionDebugSession()
        do {
            exportURL = try recorder.writeFinalZip(
                reviews: reviews,
                allSteps: steps,
                completedExercises: reviews.filter { !$0.skipped }.count,
                skippedExercises: reviews.filter(\.skipped).count
            )
            exportStatusMessage = language == .russian ? "ZIP готов" : "ZIP ready"
            phase = .summary
        } catch {
            exportErrorMessage = error.localizedDescription
            exportStatusMessage = language == .russian ? "Ошибка экспорта" : "Export failed"
            phase = .summary
        }
    }

    private func saveDebugFile() {
        guard let exportURL else { return }
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "zip") ?? .data]
        panel.nameFieldStringValue = exportURL.lastPathComponent
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let destinationURL = panel.url else { return }
            do {
                if FileManager.default.fileExists(atPath: destinationURL.path) {
                    try FileManager.default.removeItem(at: destinationURL)
                }
                try FileManager.default.copyItem(at: exportURL, to: destinationURL)
            } catch {
                exportErrorMessage = error.localizedDescription
            }
        }
    }

    private func shareDebugFile() {
        guard let exportURL, let contentView = NSApp.keyWindow?.contentView else { return }
        NSApp.activate(ignoringOtherApps: true)
        let picker = NSSharingServicePicker(items: [exportURL])
        picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
    }

    private func sendByEmail() {
        guard let exportURL else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let service = NSSharingService(named: .composeEmail) {
            service.recipients = [DeveloperContactConfig.developerEmail]
            service.subject = "BreakGateWorkout recognition debug"
            service.perform(withItems: [exportURL])
        } else {
            shareDebugFile()
        }
    }

    private func openTelegram() {
        guard let url = URL(string: DeveloperContactConfig.telegramURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyDeveloperContacts() {
        let contacts = "\(DeveloperContactConfig.developerEmail)\n\(DeveloperContactConfig.telegramURLString)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(contacts, forType: .string)
    }

    private func performanceTitle(_ rating: Int) -> String {
        switch (rating, language) {
        case (1, .english): "Very poorly"
        case (1, .russian): "Очень плохо"
        case (2, .english): "Poorly"
        case (2, .russian): "Плохо"
        case (3, .english): "Okay"
        case (3, .russian): "Нормально"
        case (4, .english): "Good"
        case (4, .russian): "Хорошо"
        case (5, .english): "Very well"
        case (5, .russian): "Очень хорошо"
        default: "Okay"
        }
    }
}

private struct RecognitionDebugExerciseStep: Identifiable {
    let id = UUID()
    let mode: ExerciseMode
    let targetAmount: Int
    let isTimed: Bool

    static func reps(_ mode: ExerciseMode, _ reps: Int) -> RecognitionDebugExerciseStep {
        RecognitionDebugExerciseStep(mode: mode, targetAmount: reps, isTimed: false)
    }

    static func seconds(_ mode: ExerciseMode, _ seconds: Int) -> RecognitionDebugExerciseStep {
        RecognitionDebugExerciseStep(mode: mode, targetAmount: seconds, isTimed: true)
    }

    var workoutStep: WorkoutStep {
        isTimed
            ? WorkoutStep(mode: mode, targetSeconds: targetAmount)
            : WorkoutStep(mode: mode, targetReps: targetAmount)
    }

    func targetText(_ language: AppLanguage) -> String {
        if isTimed {
            return language == .russian ? "\(targetAmount) секунд" : "\(targetAmount) seconds"
        }
        return language == .russian ? "\(targetAmount) повторов" : "\(targetAmount) reps"
    }
}

private extension RecognitionDebugContributionView {
    static var defaultDebugSteps: [RecognitionDebugExerciseStep] {
        [
            .reps(.pushUps, 5),
            .reps(.squats, 5),
            .reps(.abs, 5),
            .seconds(.plank, 10),
            .reps(.burpees, 3),
            .reps(.mountainClimbers, 10),
            .seconds(.tuckPlancheHold, 5),
            .seconds(.lSitHold, 5),
            .seconds(.elbowLeverHold, 5),
            .reps(.pikePushUps, 3)
        ]
    }

    func toggleExerciseSelection(_ mode: ExerciseMode) {
        if selectedExerciseModes.contains(mode) {
            selectedExerciseModes.remove(mode)
        } else {
            selectedExerciseModes.insert(mode)
        }
    }
}

private extension ExerciseMode {
    var isRecognitionDebugExperimental: Bool {
        switch self {
        case .tuckPlancheHold, .lSitHold, .elbowLeverHold, .pikePushUps:
            return true
        case .pushUps, .squats, .abs, .plank, .burpees, .mountainClimbers:
            return false
        }
    }
}

private enum RecognitionAccuracyRating: String, CaseIterable, Identifiable, Codable {
    case yes
    case partly
    case no

    var id: Self { self }

    func title(_ language: AppLanguage) -> String {
        switch (self, language) {
        case (.yes, .english): "Yes"
        case (.yes, .russian): "Да"
        case (.partly, .english): "Partly"
        case (.partly, .russian): "Частично"
        case (.no, .english): "No"
        case (.no, .russian): "Нет"
        }
    }
}

private struct RecognitionDebugExerciseModeButton: View {
    let mode: ExerciseMode
    let isSelected: Bool
    let language: AppLanguage
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(mode.title(language))
                .font(.footnote.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isSelected ? Color.green.opacity(0.22) : Color.white.opacity(0.06), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(isSelected ? Color.green.opacity(0.45) : Color.white.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct CameraPlacementSelectorView: View {
    @Binding var placement: RecognitionDebugCameraPlacement
    let language: AppLanguage

    var body: some View {
        HStack(alignment: .center, spacing: 22) {
            CameraDirectionRingView(angleDegrees: Binding(
                get: { Double(placement.angleDegrees) },
                set: {
                    placement.angleDegrees = Int(RecognitionDebugCameraDirection.normalizedDegrees($0).rounded())
                    placement.directionLabel = RecognitionDebugCameraDirection.direction(for: Double(placement.angleDegrees)).rawValue
                }
            ))
                .frame(width: 190, height: 190)

            CameraHeightRailView(placement: $placement)
                .frame(width: 84, height: 190)

            VStack(alignment: .leading, spacing: 10) {
                Label(
                    "\(language == .russian ? "Камера" : "Camera"): \(placement.direction.title(language).lowercased())",
                    systemImage: "camera.fill"
                )
                .font(.callout.weight(.semibold))

                Label(
                    "\(language == .russian ? "Высота" : "Height"): \(placement.heightValue.title(language).lowercased())",
                    systemImage: "arrow.up.and.down"
                )
                .font(.callout.weight(.semibold))
            }
            .foregroundStyle(.white.opacity(0.86))

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct CameraDirectionRingView: View {
    @Binding var angleDegrees: Double

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let radius = size * 0.36
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let marker = markerPoint(center: center, radius: radius, angleDegrees: angleDegrees)

            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 10)

                Circle()
                    .stroke(Color.green.opacity(0.26), lineWidth: 1)

                Image(systemName: "figure.stand")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))

                Circle()
                    .fill(Color.green.opacity(0.12))
                    .frame(width: 72, height: 72)

                Circle()
                    .fill(Color.green)
                    .frame(width: 28, height: 28)
                    .overlay {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.black)
                    }
                    .position(marker)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let dx = value.location.x - center.x
                        let dy = center.y - value.location.y
                        let angle = atan2(dx, dy) * 180 / .pi
                        angleDegrees = RecognitionDebugCameraDirection.normalizedDegrees(angle)
                    }
            )
        }
    }

    private func markerPoint(center: CGPoint, radius: CGFloat, angleDegrees: Double) -> CGPoint {
        let radians = angleDegrees * .pi / 180
        return CGPoint(
            x: center.x + CGFloat(sin(radians)) * radius,
            y: center.y - CGFloat(cos(radians)) * radius
        )
    }
}

private struct CameraHeightRailView: View {
    @Binding var placement: RecognitionDebugCameraPlacement

    private let levelOrder: [RecognitionDebugCameraHeight] = [.low, .chestLevel, .high, .overhead]

    var body: some View {
        GeometryReader { geometry in
            let railHeight = geometry.size.height - 24
            let centerX = geometry.size.width / 2
            let markerY = yPosition(for: placement.heightNormalized, railHeight: railHeight) + 12

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 8, height: railHeight)
                    .offset(y: 12)

                ForEach(levelOrder, id: \.self) { level in
                    Capsule()
                        .fill(Color.white.opacity(0.32))
                        .frame(width: 18, height: 2)
                        .position(x: centerX, y: yPosition(for: level.normalizedValue, railHeight: railHeight) + 12)
                }

                Image(systemName: "figure.stand")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.52))
                    .offset(x: -22, y: 66)

                Circle()
                    .fill(Color.green)
                    .frame(width: 26, height: 26)
                    .overlay {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.black)
                    }
                    .position(x: centerX, y: markerY)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let normalized = normalizedHeight(from: value.location.y, railHeight: railHeight)
                        let snapped = RecognitionDebugCameraHeight.nearest(to: normalized)
                        placement.heightValue = snapped
                    }
            )
        }
    }

    private func normalizedHeight(from y: CGFloat, railHeight: CGFloat) -> Double {
        let clamped = min(max(y - 12, 0), railHeight)
        let progress = 1 - (clamped / railHeight)
        return Double(progress)
    }

    private func yPosition(for normalizedHeight: Double, railHeight: CGFloat) -> CGFloat {
        CGFloat(1 - normalizedHeight) * railHeight
    }
}

private struct RecognitionDebugCameraPlaceholder: View {
    @ObservedObject var camera: CameraModel
    let language: AppLanguage

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(iconColor)

            Text(titleText)
                .font(.headline.weight(.semibold))
                .multilineTextAlignment(.center)

            Text(camera.statusMessage)
                .font(.callout)
                .foregroundStyle(.white.opacity(0.76))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if camera.isSwitchingCamera {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.78))
    }

    private var iconName: String {
        if camera.statusIsError {
            return "video.slash.fill"
        }
        if camera.isSwitchingCamera {
            return "arrow.triangle.2.circlepath"
        }
        return "camera.viewfinder"
    }

    private var iconColor: Color {
        camera.statusIsError ? .red : .secondary
    }

    private var titleText: String {
        if camera.statusIsError {
            return language == .russian ? "Камера недоступна" : "Camera Unavailable"
        }
        if camera.isSwitchingCamera {
            return language == .russian ? "Переключаю камеру" : "Switching Camera"
        }
        if camera.session == nil {
            return language == .russian ? "Запускаю камеру" : "Starting Camera"
        }
        return language == .russian ? "Жду первое изображение с камеры" : "Waiting for the first camera frame"
    }
}

@MainActor
private final class RecognitionDebugRecorder: ObservableObject {
    @Published private(set) var sampleCount = 0
    @Published private(set) var videoRequested = false
    @Published private(set) var videoRecorded = false
    @Published private(set) var videoDurationSeconds: TimeInterval = 0
    @Published private(set) var videoError: String?

    private var sessionID = UUID().uuidString
    private let maxSampleCount = 12_000
    private let sampleInterval: TimeInterval = 0.15
    private var createdAt = Date()
    private var sessionStartMonotonicTime: CFTimeInterval = CACurrentMediaTime()
    private var endedAt: Date?
    private var lastSampleDate = Date.distantPast
    private var frameIndex = 0
    private var stepStarts: [RecognitionDebugStepStart] = []
    private var sessionFolderURL: URL?
    private var poseSamplesURL: URL?
    private var poseSamplesHandle: FileHandle?
    private var lastCameraSnapshot: RecognitionDebugCameraSnapshot?
    private var lastWrittenURL: URL?
    private var isActive = false
    private var language: AppLanguage
    private let videoRecorder = RecognitionDebugVideoRecorder()

    init(language: AppLanguage) {
        self.language = language
    }

    func start(language: AppLanguage, recordVideo: Bool) {
        self.language = language
        closePoseSamplesHandle()
        videoRecorder.cancel()
        sessionID = UUID().uuidString
        createdAt = Date()
        sessionStartMonotonicTime = CACurrentMediaTime()
        endedAt = nil
        lastSampleDate = .distantPast
        frameIndex = 0
        stepStarts = []
        lastCameraSnapshot = nil
        lastWrittenURL = nil
        sampleCount = 0
        videoRequested = recordVideo
        videoRecorded = false
        videoDurationSeconds = 0
        videoError = nil
        isActive = true

        do {
            let folder = try Self.makeSessionFolder(sessionID: sessionID)
            let samplesURL = folder.appendingPathComponent("pose-samples.jsonl")
            FileManager.default.createFile(atPath: samplesURL.path, contents: nil)
            poseSamplesHandle = try FileHandle(forWritingTo: samplesURL)
            sessionFolderURL = folder
            poseSamplesURL = samplesURL
            if recordVideo {
                do {
                    try videoRecorder.start(
                        outputURL: folder.appendingPathComponent("video.mp4"),
                        sessionStartMonotonicTime: sessionStartMonotonicTime
                    )
                } catch {
                    videoError = error.localizedDescription
                }
            }
        } catch {
            isActive = false
            lastWrittenURL = nil
        }
    }

    nonisolated func appendVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        videoRecorder.append(sampleBuffer)
    }

    func cancel() {
        isActive = false
        closePoseSamplesHandle()
        videoRecorder.cancel()
    }

    func markStepStarted(_ step: RecognitionDebugExerciseStep, stepIndex: Int) {
        guard isActive else { return }
        stepStarts.append(
            RecognitionDebugStepStart(
                timestamp: Date().timeIntervalSince(createdAt),
                stepIndex: stepIndex,
                exerciseMode: step.mode.rawValue,
                targetAmount: step.targetAmount
            )
        )
    }

    func record(camera: CameraModel, update: PoseDetectionUpdate, step: RecognitionDebugExerciseStep, stepIndex: Int) {
        guard isActive else { return }
        let now = Date()
        let sessionTimeSeconds = CACurrentMediaTime() - sessionStartMonotonicTime
        guard now.timeIntervalSince(lastSampleDate) >= sampleInterval else { return }
        guard sampleCount < maxSampleCount else { return }
        guard let poseSamplesHandle else { return }
        lastSampleDate = now

        let posePoints = Dictionary(uniqueKeysWithValues: update.posePoints.map {
            ($0.name.debugName, RecognitionDebugJointPoint(x: Double($0.location.x), y: Double($0.location.y), confidence: Double($0.confidence)))
        })
        let metrics = RecognitionDebugMetrics(points: update.posePoints, exerciseMode: step.mode)
        let cameraSourceMode = camera.selectedDeviceIsIPhone ? "continuity" : "mac"
        let previewSize = RecognitionDebugSize(width: Double(camera.previewVideoSize.width), height: Double(camera.previewVideoSize.height))
        let sample = RecognitionDebugPoseSample(
            timestampSeconds: sessionTimeSeconds,
            videoTimeSeconds: videoRecorder.videoTimeSeconds(forSessionTime: sessionTimeSeconds),
            sessionID: sessionID,
            frameIndex: frameIndex,
            exerciseMode: step.mode.rawValue,
            stepIndex: stepIndex,
            workoutState: camera.currentWorkoutState.rawValue,
            currentPoseState: camera.currentPoseState,
            personDetected: camera.isPersonDetected,
            confidence: Double(camera.confidence),
            repCount: camera.repCount,
            targetAmount: step.targetAmount,
            holdSeconds: step.mode.isTimed ? max(0, Int((camera.plankDuration - camera.plankTimeRemaining).rounded(.down))) : 0,
            cameraSourceMode: cameraSourceMode,
            selectedCameraName: camera.selectedCameraName,
            previewVideoSize: previewSize,
            posePoints: posePoints,
            metrics: metrics,
            decision: RecognitionDebugDecision(
                isPoseValid: update.isStartingPoseDetected || update.workoutState == .plankActive || update.repCount > 0,
                reason: update.debugState,
                recognizedPhase: update.debugState
            )
        )

        do {
            let data = try JSONEncoder.recognitionDebugLineEncoder.encode(sample)
            poseSamplesHandle.write(data)
            poseSamplesHandle.write(Data("\n".utf8))
            frameIndex += 1
            sampleCount += 1
            lastCameraSnapshot = RecognitionDebugCameraSnapshot(
                cameraSourceMode: cameraSourceMode,
                selectedCameraName: camera.selectedCameraName,
                previewVideoSize: previewSize,
                captureResolution: RecognitionDebugSize(width: Double(update.videoSize.width), height: Double(update.videoSize.height))
            )
        } catch {
            isActive = false
            closePoseSamplesHandle()
        }
    }

    func writeFinalZip(
        reviews: [RecognitionDebugExerciseReview],
        allSteps: [RecognitionDebugExerciseStep],
        completedExercises: Int,
        skippedExercises: Int
    ) throws -> URL {
        isActive = false
        endedAt = Date()
        closePoseSamplesHandle()
        let videoResult = videoRecorder.finish()
        videoRecorded = videoResult.videoRecorded
        videoDurationSeconds = videoResult.videoDurationSeconds ?? 0
        if videoRequested, !videoResult.videoRecorded {
            videoError = videoResult.videoError ?? videoError ?? "Video recording did not produce a video file."
        }

        guard let sessionFolderURL, let poseSamplesURL else {
            throw RecognitionDebugExportError.exportFolderUnavailable
        }
        if !videoRecorded {
            try? FileManager.default.removeItem(at: sessionFolderURL.appendingPathComponent("video.mp4"))
        }

        let endDate = endedAt ?? Date()
        let metadata = RecognitionDebugMetadata(
            schemaVersion: 2,
            appName: "BreakGateWorkout",
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
            createdAt: ISO8601DateFormatter().string(from: createdAt),
            sessionID: sessionID,
            language: language.rawValue,
            debugMode: "recognitionContribution",
            videoRequested: videoRequested,
            videoRecorded: videoRecorded,
            audioRecorded: false,
            videoFileName: videoRecorded ? "video.mp4" : nil,
            videoDurationSeconds: videoResult.videoDurationSeconds,
            videoFrameCount: videoResult.videoFrameCount,
            videoFPSApprox: videoResult.videoFPSApprox,
            videoResolution: videoResult.videoResolution,
            videoOrientation: videoResult.videoOrientation,
            videoError: videoError,
            firstVideoPresentationTimestamp: videoResult.firstVideoPresentationTimestamp,
            videoStartSessionTimeSeconds: videoResult.videoStartSessionTimeSeconds,
            cameraSourceMode: lastCameraSnapshot?.cameraSourceMode,
            selectedCameraName: lastCameraSnapshot?.selectedCameraName,
            previewVideoSize: lastCameraSnapshot?.previewVideoSize,
            captureResolution: lastCameraSnapshot?.captureResolution,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: Self.deviceModel(),
            poseCoordinateSpace: "Vision normalized image coordinates",
            poseOrigin: "bottom-left",
            isMirrored: nil,
            previewGravity: "aspectFit",
            startedAt: ISO8601DateFormatter().string(from: createdAt),
            endedAt: ISO8601DateFormatter().string(from: endDate),
            durationSeconds: max(0, endDate.timeIntervalSince(createdAt)),
            selectedExercises: allSteps.map(\.mode.rawValue),
            completedExercises: completedExercises,
            skippedExercises: skippedExercises,
            poseSampleCount: sampleCount,
            sampleIntervalSeconds: sampleInterval,
            sampleCap: maxSampleCount,
            privacyNote: videoRecorded
                ? "Nothing was uploaded automatically. Audio was not recorded. Video was recorded only because the user explicitly enabled it."
                : "Nothing was uploaded automatically. Video and audio were not recorded."
        )

        let metadataURL = sessionFolderURL.appendingPathComponent("metadata.json")
        let reviewsURL = sessionFolderURL.appendingPathComponent("exercise-reviews.json")
        let zipURL = FileManager.default.temporaryDirectory.appendingPathComponent(Self.exportFileName(createdAt: createdAt))

        try JSONEncoder.recognitionDebugEncoder.encode(metadata).write(to: metadataURL, options: .atomic)
        try JSONEncoder.recognitionDebugEncoder.encode(RecognitionDebugExerciseReviewsExport(sessionID: sessionID, reviews: reviews)).write(to: reviewsURL, options: .atomic)

        try Self.validateWorkingFolder(sessionFolderURL, expectsVideo: videoRecorded)
        if FileManager.default.fileExists(atPath: zipURL.path) {
            try FileManager.default.removeItem(at: zipURL)
        }
        try Self.createZip(from: sessionFolderURL, to: zipURL)
        try Self.validateZip(zipURL, expectsVideo: videoRecorded)

        lastWrittenURL = zipURL
        _ = poseSamplesURL
        return zipURL
    }

    func formattedFileSize(for url: URL?) -> String {
        guard let url = url ?? lastWrittenURL,
              let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return "0 KB"
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: size.int64Value)
    }

    private static func exportFileName(createdAt: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HH-mm"
        return "BreakGateWorkout-recognition-debug-\(formatter.string(from: createdAt)).zip"
    }

    private static func makeSessionFolder(sessionID: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("BreakGateWorkout-recognition-debug-\(sessionID)", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func createZip(from folderURL: URL, to zipURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.currentDirectoryURL = folderURL
        process.arguments = [
            "-c",
            "-k",
            "--norsrc",
            "--zlibCompressionLevel",
            "6",
            ".",
            zipURL.path
        ]

        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw RecognitionDebugExportError.zipCreationFailed(Int(process.terminationStatus))
        }
    }

    private static func validateWorkingFolder(_ folderURL: URL, expectsVideo: Bool) throws {
        for filename in RecognitionDebugZipEntry.expected(expectsVideo: expectsVideo) {
            let fileURL = folderURL.appendingPathComponent(filename)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw RecognitionDebugExportError.missingTemporaryFile(filename)
            }
        }
    }

    private static func validateZip(_ zipURL: URL, expectsVideo: Bool) throws {
        guard FileManager.default.fileExists(atPath: zipURL.path) else {
            throw RecognitionDebugExportError.zipMissing
        }
        let size = (try FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else {
            throw RecognitionDebugExportError.zipEmpty
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", zipURL.path]
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let entries = Set(String(data: data, encoding: .utf8)?.split(separator: "\n").map(String.init) ?? [])
        guard entries == Set(RecognitionDebugZipEntry.expected(expectsVideo: expectsVideo)) else {
            throw RecognitionDebugExportError.unexpectedZipEntries(entries.sorted())
        }
    }

    private static func deviceModel() -> String? {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return Host.current().localizedName }
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }

    private func closePoseSamplesHandle() {
        try? poseSamplesHandle?.close()
        poseSamplesHandle = nil
    }
}

private struct RecognitionSkeletonOverlay: View {
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
            let rect = fittedVideoRect(in: size)
            let pointMap = Dictionary(uniqueKeysWithValues: points.map { ($0.name, $0.location) })

            for connection in connections {
                guard let start = pointMap[connection.0], let end = pointMap[connection.1] else { continue }
                var path = Path()
                path.move(to: screenPoint(from: start, in: rect))
                path.addLine(to: screenPoint(from: end, in: rect))
                context.stroke(path, with: .color(.green.opacity(0.86)), lineWidth: 3)
            }

            for point in points {
                let center = screenPoint(from: point.location, in: rect)
                let dot = CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: dot), with: .color(.white))
                context.stroke(Path(ellipseIn: dot), with: .color(.green), lineWidth: 2)
            }
        }
        .opacity(points.isEmpty ? 0 : 1)
        .allowsHitTesting(false)
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
        }
        let width = size.height * videoAspect
        return CGRect(x: (size.width - width) / 2, y: 0, width: width, height: size.height)
    }

    private func screenPoint(from normalizedPoint: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + normalizedPoint.x * rect.width, y: rect.minY + (1 - normalizedPoint.y) * rect.height)
    }
}

private struct RecognitionDebugButtonStyle: ButtonStyle {
    enum Kind {
        case primary
        case secondary
        case danger
    }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.bold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(background.opacity(configuration.isPressed ? 0.68 : 1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(stroke, lineWidth: 1)
            }
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: .white.opacity(0.9)
        case .danger: .red
        }
    }

    private var background: Color {
        switch kind {
        case .primary: .green.opacity(0.86)
        case .secondary: .white.opacity(0.09)
        case .danger: .red.opacity(0.12)
        }
    }

    private var stroke: Color {
        switch kind {
        case .primary: .green.opacity(0.42)
        case .secondary: .white.opacity(0.16)
        case .danger: .red.opacity(0.32)
        }
    }
}

nonisolated private final class RecognitionDebugVideoRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "BreakGateWorkout.recognitionDebug.videoWriter", qos: .utility)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let targetFrameInterval: TimeInterval = 1.0 / 15.0
    private let maxDurationSeconds: TimeInterval = 5 * 60

    private var active = false
    private var outputURL: URL?
    private var sessionStartMonotonicTime: CFTimeInterval = 0
    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var firstPresentationTime: CMTime?
    private var firstVideoSessionTime: TimeInterval?
    private var lastPresentationTime: CMTime?
    private var lastAppendedVideoTime: TimeInterval?
    private var frameCount = 0
    private var videoResolution: RecognitionDebugSize?
    private var errorMessage: String?

    init() {
        queue.setSpecific(key: queueKey, value: true)
    }

    func start(outputURL: URL, sessionStartMonotonicTime: CFTimeInterval) throws {
        try sync {
            reset(cancelWriter: true)
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            self.outputURL = outputURL
            self.sessionStartMonotonicTime = sessionStartMonotonicTime
            self.active = true
        }
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        sync {
            guard active else { return }
            guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard presentationTime.isValid else { return }

            if let firstPresentationTime {
                let videoTime = CMTimeGetSeconds(CMTimeSubtract(presentationTime, firstPresentationTime))
                guard videoTime <= maxDurationSeconds else {
                    active = false
                    return
                }
                if let lastAppendedVideoTime, videoTime - lastAppendedVideoTime < targetFrameInterval {
                    return
                }
            }

            do {
                try prepareWriterIfNeeded(for: sampleBuffer, presentationTime: presentationTime)
                guard let writerInput, writerInput.isReadyForMoreMediaData else { return }
                guard writerInput.append(sampleBuffer) else {
                    active = false
                    errorMessage = writer?.error?.localizedDescription ?? "Video writer could not append a frame."
                    return
                }

                let videoTime = CMTimeGetSeconds(CMTimeSubtract(presentationTime, firstPresentationTime ?? presentationTime))
                lastAppendedVideoTime = max(0, videoTime)
                lastPresentationTime = presentationTime
                frameCount += 1
            } catch {
                active = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func videoTimeSeconds(forSessionTime sessionTime: TimeInterval) -> TimeInterval? {
        sync {
            guard active || frameCount > 0, let firstVideoSessionTime else { return nil }
            return max(0, sessionTime - firstVideoSessionTime)
        }
    }

    func finish() -> RecognitionDebugVideoResult {
        let finishState: (AVAssetWriter?, AVAssetWriterInput?, URL?, Int, CMTime?, CMTime?, TimeInterval?, RecognitionDebugSize?, String?) = sync {
            active = false
            let result = (writer, writerInput, outputURL, frameCount, firstPresentationTime, lastPresentationTime, firstVideoSessionTime, videoResolution, errorMessage)
            writer = nil
            writerInput = nil
            return result
        }

        guard let writer = finishState.0, let writerInput = finishState.1, let outputURL = finishState.2, finishState.3 > 0 else {
            return RecognitionDebugVideoResult(
                videoRecorded: false,
                videoDurationSeconds: nil,
                videoFrameCount: finishState.3,
                videoFPSApprox: nil,
                videoResolution: finishState.7,
                videoOrientation: nil,
                firstVideoPresentationTimestamp: finishState.4.map(CMTimeGetSeconds),
                videoStartSessionTimeSeconds: finishState.6,
                videoError: finishState.8
            )
        }

        writerInput.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting {
            semaphore.signal()
        }
        semaphore.wait()

        let duration = Self.duration(first: finishState.4, last: finishState.5)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        let recorded = writer.status == .completed && fileSize > 0
        let finalError = recorded ? nil : (writer.error?.localizedDescription ?? finishState.8 ?? "Video recording did not finish successfully.")
        let fpsApprox = duration.flatMap { $0 > 0 ? Double(finishState.3) / $0 : nil }

        return RecognitionDebugVideoResult(
            videoRecorded: recorded,
            videoDurationSeconds: duration,
            videoFrameCount: finishState.3,
            videoFPSApprox: fpsApprox,
            videoResolution: finishState.7,
            videoOrientation: nil,
            firstVideoPresentationTimestamp: finishState.4.map(CMTimeGetSeconds),
            videoStartSessionTimeSeconds: finishState.6,
            videoError: finalError
        )
    }

    func cancel() {
        sync {
            reset(cancelWriter: true)
        }
    }

    private func prepareWriterIfNeeded(for sampleBuffer: CMSampleBuffer, presentationTime: CMTime) throws {
        guard writer == nil else { return }
        guard let outputURL else { throw RecognitionDebugExportError.videoOutputUnavailable }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw RecognitionDebugExportError.videoOutputUnavailable
        }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_500_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecognitionDebugExportError.videoOutputUnavailable
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? RecognitionDebugExportError.videoOutputUnavailable
        }
        writer.startSession(atSourceTime: presentationTime)

        self.writer = writer
        self.writerInput = input
        self.firstPresentationTime = presentationTime
        self.firstVideoSessionTime = CACurrentMediaTime() - sessionStartMonotonicTime
        self.videoResolution = RecognitionDebugSize(width: Double(width), height: Double(height))
    }

    private func reset(cancelWriter: Bool) {
        active = false
        if cancelWriter {
            writerInput?.markAsFinished()
            writer?.cancelWriting()
        }
        outputURL = nil
        writer = nil
        writerInput = nil
        firstPresentationTime = nil
        firstVideoSessionTime = nil
        lastPresentationTime = nil
        lastAppendedVideoTime = nil
        frameCount = 0
        videoResolution = nil
        errorMessage = nil
    }

    private func sync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true {
            return try work()
        }
        return try queue.sync(execute: work)
    }

    private static func duration(first: CMTime?, last: CMTime?) -> TimeInterval? {
        guard let first, let last, first.isValid, last.isValid else { return nil }
        return max(0, CMTimeGetSeconds(CMTimeSubtract(last, first)))
    }
}

private struct RecognitionDebugMetrics: Codable {
    let leftElbowAngle: Double?
    let rightElbowAngle: Double?
    let leftKneeAngle: Double?
    let rightKneeAngle: Double?
    let leftHipAngle: Double?
    let rightHipAngle: Double?
    let shoulderWidth: Double?
    let torsoLength: Double?
    let bodyLineAngle: Double?
    let hipHeightRelativeToShoulders: Double?
    let ankleHeightRelativeToHips: Double?
    let ankleHeightRelativeToWrists: Double?
    let visibleKeypointCount: Int
    let averageKeypointConfidence: Double?
    let missingKeypoints: [String]
    let criticalMissingForExercise: Bool
    let criticalMissingReason: String?

    init(points: [PoseJointPoint], exerciseMode: ExerciseMode) {
        let map = Dictionary(uniqueKeysWithValues: points.map { ($0.name, $0) })
        visibleKeypointCount = points.count
        averageKeypointConfidence = points.isEmpty ? nil : Double(points.map(\.confidence).reduce(0, +) / Float(points.count))
        leftElbowAngle = Self.angle(.leftShoulder, .leftElbow, .leftWrist, map)
        rightElbowAngle = Self.angle(.rightShoulder, .rightElbow, .rightWrist, map)
        leftKneeAngle = Self.angle(.leftHip, .leftKnee, .leftAnkle, map)
        rightKneeAngle = Self.angle(.rightHip, .rightKnee, .rightAnkle, map)
        leftHipAngle = Self.angle(.leftShoulder, .leftHip, .leftKnee, map)
        rightHipAngle = Self.angle(.rightShoulder, .rightHip, .rightKnee, map)
        shoulderWidth = map[.leftShoulder].flatMap { leftShoulder in
            map[.rightShoulder].map { rightShoulder in
                Self.distance(leftShoulder.location, rightShoulder.location)
            }
        }

        var torsoLengthValue: Double?
        var hipHeightRelativeToShouldersValue: Double?
        var bodyLineAngleValue: Double?
        if let shoulder = Self.average([map[.leftShoulder]?.location, map[.rightShoulder]?.location]),
           let hip = Self.average([map[.leftHip]?.location, map[.rightHip]?.location]) {
            torsoLengthValue = Self.distance(shoulder, hip)
            hipHeightRelativeToShouldersValue = Double(hip.y - shoulder.y)
            bodyLineAngleValue = Double(atan2(hip.y - shoulder.y, hip.x - shoulder.x) * 180 / .pi)
        }
        torsoLength = torsoLengthValue
        hipHeightRelativeToShoulders = hipHeightRelativeToShouldersValue
        bodyLineAngle = bodyLineAngleValue

        var ankleHeightRelativeToHipsValue: Double?
        if let hip = Self.average([map[.leftHip]?.location, map[.rightHip]?.location]),
           let ankle = Self.average([map[.leftAnkle]?.location, map[.rightAnkle]?.location]) {
            ankleHeightRelativeToHipsValue = Double(ankle.y - hip.y)
        }
        ankleHeightRelativeToHips = ankleHeightRelativeToHipsValue

        var ankleHeightRelativeToWristsValue: Double?
        if let wrist = Self.average([map[.leftWrist]?.location, map[.rightWrist]?.location]),
           let ankle = Self.average([map[.leftAnkle]?.location, map[.rightAnkle]?.location]) {
            ankleHeightRelativeToWristsValue = Double(ankle.y - wrist.y)
        }
        ankleHeightRelativeToWrists = ankleHeightRelativeToWristsValue

        missingKeypoints = PoseJointName.debugAllCases
            .filter { map[$0] == nil }
            .map(\.debugName)
        let criticalMissing = Self.criticalMissingJoints(for: exerciseMode, visibleJoints: Set(map.keys))
        criticalMissingForExercise = !criticalMissing.isEmpty
        criticalMissingReason = criticalMissing.isEmpty ? nil : Self.criticalMissingReason(for: exerciseMode, missingJoints: criticalMissing)
    }

    private static func angle(_ first: PoseJointName, _ middle: PoseJointName, _ last: PoseJointName, _ map: [PoseJointName: PoseJointPoint]) -> Double? {
        guard let firstPoint = map[first]?.location, let middlePoint = map[middle]?.location, let lastPoint = map[last]?.location else { return nil }
        return Self.angle(first: firstPoint, middle: middlePoint, last: lastPoint)
    }

    private static func average(_ points: [CGPoint?]) -> CGPoint? {
        let validPoints = points.compactMap { $0 }
        guard !validPoints.isEmpty else { return nil }
        let sum = validPoints.reduce(CGPoint.zero) { partial, point in
            CGPoint(x: partial.x + point.x, y: partial.y + point.y)
        }
        return CGPoint(x: sum.x / CGFloat(validPoints.count), y: sum.y / CGFloat(validPoints.count))
    }

    private static func distance(_ first: CGPoint, _ second: CGPoint) -> Double {
        let dx = first.x - second.x
        let dy = first.y - second.y
        return Double(sqrt(dx * dx + dy * dy))
    }

    private static func angle(first: CGPoint, middle: CGPoint, last: CGPoint) -> Double {
        let firstVector = CGVector(dx: first.x - middle.x, dy: first.y - middle.y)
        let secondVector = CGVector(dx: last.x - middle.x, dy: last.y - middle.y)
        let dotProduct = firstVector.dx * secondVector.dx + firstVector.dy * secondVector.dy
        let firstLength = sqrt(firstVector.dx * firstVector.dx + firstVector.dy * firstVector.dy)
        let secondLength = sqrt(secondVector.dx * secondVector.dx + secondVector.dy * secondVector.dy)
        guard firstLength > 0, secondLength > 0 else { return 0 }
        let cosine = max(-1, min(1, dotProduct / (firstLength * secondLength)))
        return Double(acos(cosine) * 180 / .pi)
    }

    private static func criticalMissingJoints(for mode: ExerciseMode, visibleJoints: Set<PoseJointName>) -> [PoseJointName] {
        criticalJointGroups(for: mode)
            .filter { group in group.allSatisfy { !visibleJoints.contains($0) } }
            .flatMap { $0 }
            .filter { !visibleJoints.contains($0) }
    }

    private static func criticalJointGroups(for mode: ExerciseMode) -> [[PoseJointName]] {
        switch mode {
        case .pushUps:
            return bilateral(.wrist) + bilateral(.elbow) + bilateral(.shoulder) + bilateral(.hip) + [PoseJointName.kneesAndAnkles]
        case .squats:
            return bilateral(.shoulder) + bilateral(.hip) + bilateral(.knee) + bilateral(.ankle)
        case .abs:
            return bilateral(.shoulder) + bilateral(.hip) + bilateral(.knee)
        case .plank:
            return bilateral(.shoulder) + bilateral(.hip) + bilateral(.knee) + bilateral(.ankle)
        case .burpees, .mountainClimbers:
            return bilateral(.shoulder) + bilateral(.wrist) + bilateral(.hip) + bilateral(.knee) + bilateral(.ankle)
        case .tuckPlancheHold:
            return bilateral(.wrist) + bilateral(.elbow) + bilateral(.shoulder) + bilateral(.hip) + bilateral(.knee)
        case .lSitHold, .elbowLeverHold, .pikePushUps:
            return bilateral(.wrist) + bilateral(.elbow) + bilateral(.shoulder) + bilateral(.hip) + bilateral(.knee) + bilateral(.ankle)
        }
    }

    private static func bilateral(_ joint: RecognitionDebugJointKind) -> [[PoseJointName]] {
        switch joint {
        case .wrist: return [[.leftWrist, .rightWrist]]
        case .elbow: return [[.leftElbow, .rightElbow]]
        case .shoulder: return [[.leftShoulder, .rightShoulder]]
        case .hip: return [[.leftHip, .rightHip]]
        case .knee: return [[.leftKnee, .rightKnee]]
        case .ankle: return [[.leftAnkle, .rightAnkle]]
        }
    }

    private static func criticalMissingReason(for mode: ExerciseMode, missingJoints: [PoseJointName]) -> String {
        let names = missingJoints.map(\.debugName).joined(separator: ", ")
        return "\(mode.rawValue) needs these keypoints for reliable recognition: \(names)."
    }
}

private struct RecognitionDebugMetadata: Codable {
    let schemaVersion: Int
    let appName: String
    let appVersion: String?
    let buildNumber: String?
    let createdAt: String
    let sessionID: String
    let language: String
    let debugMode: String
    let videoRequested: Bool
    let videoRecorded: Bool
    let audioRecorded: Bool
    let videoFileName: String?
    let videoDurationSeconds: TimeInterval?
    let videoFrameCount: Int
    let videoFPSApprox: Double?
    let videoResolution: RecognitionDebugSize?
    let videoOrientation: String?
    let videoError: String?
    let firstVideoPresentationTimestamp: TimeInterval?
    let videoStartSessionTimeSeconds: TimeInterval?
    let cameraSourceMode: String?
    let selectedCameraName: String?
    let previewVideoSize: RecognitionDebugSize?
    let captureResolution: RecognitionDebugSize?
    let macOSVersion: String
    let deviceModel: String?
    let poseCoordinateSpace: String
    let poseOrigin: String
    let isMirrored: Bool?
    let previewGravity: String
    let startedAt: String
    let endedAt: String
    let durationSeconds: TimeInterval
    let selectedExercises: [String]
    let completedExercises: Int
    let skippedExercises: Int
    let poseSampleCount: Int
    let sampleIntervalSeconds: TimeInterval
    let sampleCap: Int
    let privacyNote: String
}

private struct RecognitionDebugStepStart: Codable {
    let timestamp: TimeInterval
    let stepIndex: Int
    let exerciseMode: String
    let targetAmount: Int
}

private struct RecognitionDebugPoseSample: Codable {
    let timestampSeconds: TimeInterval
    let videoTimeSeconds: TimeInterval?
    let sessionID: String
    let frameIndex: Int
    let exerciseMode: String
    let stepIndex: Int
    let workoutState: String
    let currentPoseState: String
    let personDetected: Bool
    let confidence: Double
    let repCount: Int
    let targetAmount: Int
    let holdSeconds: Int
    let cameraSourceMode: String
    let selectedCameraName: String
    let previewVideoSize: RecognitionDebugSize
    let posePoints: [String: RecognitionDebugJointPoint]
    let metrics: RecognitionDebugMetrics
    let decision: RecognitionDebugDecision
}

private struct RecognitionDebugSize: Codable {
    let width: Double
    let height: Double
}

private struct RecognitionDebugJointPoint: Codable {
    let x: Double
    let y: Double
    let confidence: Double
}

private struct RecognitionDebugDecision: Codable {
    let isPoseValid: Bool
    let reason: String
    let recognizedPhase: String
}

private struct RecognitionDebugCameraPlacement: Codable, Equatable {
    var angleDegrees: Int
    var directionLabel: String
    var height: String
    var heightNormalized: Double
    var distance: String
    var bodyFraming: String

    static let defaultPlacement = RecognitionDebugCameraPlacement(
        angleDegrees: 0,
        directionLabel: RecognitionDebugCameraDirection.front.rawValue,
        height: RecognitionDebugCameraHeight.chestLevel.rawValue,
        heightNormalized: RecognitionDebugCameraHeight.chestLevel.normalizedValue,
        distance: RecognitionDebugCameraDistance.medium.rawValue,
        bodyFraming: RecognitionDebugBodyFraming.fullBodyVisible.rawValue
    )

    var direction: RecognitionDebugCameraDirection {
        get { RecognitionDebugCameraDirection(rawValue: directionLabel) ?? .front }
        set {
            directionLabel = newValue.rawValue
            angleDegrees = newValue.defaultAngleDegrees
        }
    }

    var heightValue: RecognitionDebugCameraHeight {
        get { RecognitionDebugCameraHeight(rawValue: height) ?? .chestLevel }
        set {
            height = newValue.rawValue
            heightNormalized = newValue.normalizedValue
        }
    }

    var distanceValue: RecognitionDebugCameraDistance {
        get { RecognitionDebugCameraDistance(rawValue: distance) ?? .medium }
        set { distance = newValue.rawValue }
    }

    var bodyFramingValue: RecognitionDebugBodyFraming {
        get { RecognitionDebugBodyFraming(rawValue: bodyFraming) ?? .fullBodyVisible }
        set { bodyFraming = newValue.rawValue }
    }
}

private struct RecognitionDebugExerciseReview: Codable {
    let exerciseMode: String
    let stepIndex: Int
    let target: Int
    let detectedResult: Int
    let userCompletedManually: Bool
    let skipped: Bool
    let userPerformanceRating: Int
    let recognitionAccuracyRating: String
    let userComment: String
    let cameraPlacement: RecognitionDebugCameraPlacement

    enum CodingKeys: String, CodingKey {
        case exerciseMode
        case stepIndex
        case target
        case detectedResult
        case userCompletedManually
        case skipped = "wasSkipped"
        case userPerformanceRating
        case recognitionAccuracyRating
        case userComment
        case cameraPlacement
    }
}

private struct RecognitionDebugExerciseReviewsExport: Codable {
    let sessionID: String
    let reviews: [RecognitionDebugExerciseReview]
}

private struct RecognitionDebugCameraSnapshot {
    let cameraSourceMode: String
    let selectedCameraName: String
    let previewVideoSize: RecognitionDebugSize
    let captureResolution: RecognitionDebugSize
}

private struct RecognitionDebugVideoResult {
    let videoRecorded: Bool
    let videoDurationSeconds: TimeInterval?
    let videoFrameCount: Int
    let videoFPSApprox: Double?
    let videoResolution: RecognitionDebugSize?
    let videoOrientation: String?
    let firstVideoPresentationTimestamp: TimeInterval?
    let videoStartSessionTimeSeconds: TimeInterval?
    let videoError: String?
}

private enum RecognitionDebugCameraDirection: String, CaseIterable, Identifiable, Codable {
    case front
    case frontRight
    case right
    case backRight
    case back
    case backLeft
    case left
    case frontLeft

    var id: Self { self }

    var defaultAngleDegrees: Int {
        switch self {
        case .front: 0
        case .frontRight: 45
        case .right: 90
        case .backRight: 135
        case .back: 180
        case .backLeft: 225
        case .left: 270
        case .frontLeft: 315
        }
    }

    func title(_ language: AppLanguage) -> String {
        switch (self, language) {
        case (.front, .english): "Front"
        case (.front, .russian): "Спереди"
        case (.frontRight, .english): "Front right"
        case (.frontRight, .russian): "Спереди справа"
        case (.right, .english): "Right"
        case (.right, .russian): "Справа"
        case (.backRight, .english): "Back right"
        case (.backRight, .russian): "Сзади справа"
        case (.back, .english): "Back"
        case (.back, .russian): "Сзади"
        case (.backLeft, .english): "Back left"
        case (.backLeft, .russian): "Сзади слева"
        case (.left, .english): "Left"
        case (.left, .russian): "Слева"
        case (.frontLeft, .english): "Front left"
        case (.frontLeft, .russian): "Спереди слева"
        }
    }

    static func normalizedDegrees(_ value: Double) -> Double {
        let normalized = value.truncatingRemainder(dividingBy: 360)
        return normalized < 0 ? normalized + 360 : normalized
    }

    static func direction(for angleDegrees: Double) -> RecognitionDebugCameraDirection {
        let normalized = normalizedDegrees(angleDegrees)
        let directions: [RecognitionDebugCameraDirection] = [.front, .frontRight, .right, .backRight, .back, .backLeft, .left, .frontLeft]
        let index = Int(((normalized + 22.5) / 45.0).rounded(.down)) % directions.count
        return directions[index]
    }
}

private enum RecognitionDebugCameraHeight: String, CaseIterable, Identifiable, Codable {
    case low
    case chestLevel
    case high
    case overhead
    case unknown

    var id: Self { self }

    var normalizedValue: Double {
        switch self {
        case .low: 0.0
        case .chestLevel: 0.5
        case .high: 0.78
        case .overhead: 1.0
        case .unknown: 0.5
        }
    }

    func title(_ language: AppLanguage) -> String {
        switch (self, language) {
        case (.low, .english): "Low"
        case (.low, .russian): "Низко"
        case (.chestLevel, .english): "Chest level"
        case (.chestLevel, .russian): "На уровне груди"
        case (.high, .english): "High"
        case (.high, .russian): "Высоко"
        case (.overhead, .english): "Overhead"
        case (.overhead, .russian): "Сверху"
        case (.unknown, .english): "Unknown"
        case (.unknown, .russian): "Не знаю"
        }
    }

    static func nearest(to value: Double) -> RecognitionDebugCameraHeight {
        [.low, .chestLevel, .high, .overhead]
            .min(by: { abs($0.normalizedValue - value) < abs($1.normalizedValue - value) }) ?? .chestLevel
    }
}

private enum RecognitionDebugCameraDistance: String, CaseIterable, Identifiable, Codable {
    case close
    case medium
    case far
    case unknown

    var id: Self { self }

    func title(_ language: AppLanguage) -> String {
        switch (self, language) {
        case (.close, .english): "Close"
        case (.close, .russian): "Близко"
        case (.medium, .english): "Medium"
        case (.medium, .russian): "Средне"
        case (.far, .english): "Far"
        case (.far, .russian): "Далеко"
        case (.unknown, .english): "Unknown"
        case (.unknown, .russian): "Не знаю"
        }
    }
}

private enum RecognitionDebugBodyFraming: String, CaseIterable, Identifiable, Codable {
    case fullBodyVisible
    case partlyCropped
    case notSure

    var id: Self { self }

    func title(_ language: AppLanguage) -> String {
        switch (self, language) {
        case (.fullBodyVisible, .english): "Full body visible"
        case (.fullBodyVisible, .russian): "Тело полностью в кадре"
        case (.partlyCropped, .english): "Partly cropped"
        case (.partlyCropped, .russian): "Часть тела обрезана"
        case (.notSure, .english): "Not sure"
        case (.notSure, .russian): "Не уверен"
        }
    }
}

private enum RecognitionDebugJointKind {
    case wrist
    case elbow
    case shoulder
    case hip
    case knee
    case ankle
}

private enum RecognitionDebugZipEntry {
    static func expected(expectsVideo: Bool) -> [String] {
        var entries = [
            "metadata.json",
            "pose-samples.jsonl",
            "exercise-reviews.json"
        ]
        if expectsVideo {
            entries.append("video.mp4")
        }
        return entries
    }
}

private enum RecognitionDebugExportError: LocalizedError {
    case exportFolderUnavailable
    case missingTemporaryFile(String)
    case zipCreationFailed(Int)
    case zipMissing
    case zipEmpty
    case unexpectedZipEntries([String])
    case videoOutputUnavailable

    var errorDescription: String? {
        switch self {
        case .exportFolderUnavailable:
            return "Recognition debug export folder could not be prepared."
        case .missingTemporaryFile(let filename):
            return "Recognition debug export is missing \(filename)."
        case .zipCreationFailed(let status):
            return "Could not create the recognition debug ZIP file. ditto exited with status \(status)."
        case .zipMissing:
            return "Recognition debug ZIP file was not created."
        case .zipEmpty:
            return "Recognition debug ZIP file is empty."
        case .unexpectedZipEntries(let entries):
            return "Recognition debug ZIP contains unexpected files: \(entries.joined(separator: ", "))."
        case .videoOutputUnavailable:
            return "Video recording could not be initialized from the camera frames."
        }
    }
}

private extension JSONEncoder {
    static var recognitionDebugEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static var recognitionDebugLineEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension PoseJointName {
    static let debugAllCases: [PoseJointName] = [
        .leftShoulder,
        .leftElbow,
        .leftWrist,
        .rightShoulder,
        .rightElbow,
        .rightWrist,
        .leftHip,
        .leftKnee,
        .leftAnkle,
        .rightHip,
        .rightKnee,
        .rightAnkle
    ]

    static let kneesAndAnkles: [PoseJointName] = [
        .leftKnee,
        .rightKnee,
        .leftAnkle,
        .rightAnkle
    ]

    var debugName: String {
        switch self {
        case .leftShoulder: "leftShoulder"
        case .leftElbow: "leftElbow"
        case .leftWrist: "leftWrist"
        case .rightShoulder: "rightShoulder"
        case .rightElbow: "rightElbow"
        case .rightWrist: "rightWrist"
        case .leftHip: "leftHip"
        case .leftKnee: "leftKnee"
        case .leftAnkle: "leftAnkle"
        case .rightHip: "rightHip"
        case .rightKnee: "rightKnee"
        case .rightAnkle: "rightAnkle"
        }
    }
}
