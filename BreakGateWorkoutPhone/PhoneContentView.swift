import SwiftUI

struct PhoneContentView: View {
    @ObservedObject var model: PhoneCameraStreamModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.06, green: 0.08, blue: 0.12), Color.black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("BreakGateWorkout Phone")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .minimumScaleFactor(0.82)

                    Text(model.isRussian ? "Режим камеры-спутника" : "Camera satellite mode")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))

                    Label(localizedConnectionState, systemImage: statusIconName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.86))

                    RemoteCameraPreview(image: model.previewImage)
                        .frame(maxWidth: .infinity)
                        .aspectRatio(model.previewAspectRatio, contentMode: .fit)
                        .background(Color.black, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay {
                            if model.previewImage == nil {
                                VStack(spacing: 12) {
                                    Image(systemName: "camera.fill")
                                        .font(.system(size: 42))
                                    Text(model.cameraStatusText)
                                        .multilineTextAlignment(.center)
                                }
                                .foregroundStyle(.white.opacity(0.72))
                                .padding(22)
                            }
                        }

                    VStack(alignment: .leading, spacing: 10) {
                        Label("Mac: \(model.connectedMacLabel)", systemImage: "desktopcomputer")
                            .font(.subheadline.weight(.semibold))

                        Text(satelliteHint)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))

                        if let stats = model.streamStatsText {
                            Text(stats)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(isOn: Binding(
                        get: { model.autoStartAfterConnection },
                        set: { model.setAutoStartAfterConnection($0) }
                    )) {
                        Text(model.isRussian
                            ? "Автоматически запускать трансляцию после подключения"
                            : "Auto-start stream after connection"
                        )
                        .font(.subheadline.weight(.semibold))
                    }
                    .toggleStyle(.switch)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(model.isRussian ? "Зум" : "Zoom"): \(model.currentZoomLabel)")
                            .font(.subheadline.weight(.semibold))

                        HStack(spacing: 8) {
                            ForEach(RemoteCameraZoomLevel.allCases) { level in
                                Button {
                                    model.setZoom(level)
                                } label: {
                                    Text(level.title)
                                        .font(.subheadline.weight(.bold))
                                        .frame(maxWidth: .infinity, minHeight: 40)
                                }
                                .buttonStyle(.plain)
                                .background(model.currentZoomLevel == level ? Color.green.opacity(0.28) : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(model.supportedZoomLevels.contains(level) ? Color.white.opacity(0.14) : Color.white.opacity(0.05), lineWidth: 1)
                                }
                                .opacity(model.supportedZoomLevels.contains(level) ? 1 : 0.38)
                                .disabled(!model.supportedZoomLevels.contains(level))
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 22)
                .padding(.bottom, 96)
                .foregroundStyle(.white)
            }
        }
        .safeAreaInset(edge: .bottom) {
            phoneActionButton(
                title: model.primaryActionTitle,
                showsProgress: model.actionInProgressTitle != nil || model.connectionState == .connecting,
                isPrimary: model.connectionState == .connected || model.connectionState == .streaming
            ) {
                model.performPrimaryAction()
            }
            .disabled(!model.primaryActionEnabled)
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 10)
            .background(.ultraThinMaterial)
        }
        .onAppear {
            model.start()
        }
        .onOpenURL { url in
            model.handleOpenURL(url)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                model.stopStreaming()
            }
        }
    }

    private var satelliteHint: String {
        if model.connectionState == .streaming {
            return model.isRussian ? "Трансляция идет" : "Streaming"
        }
        if model.cameraStatusText.localizedCaseInsensitiveContains("ready") || model.cameraStatusText.localizedCaseInsensitiveContains("готова") {
            return model.isRussian
                ? "Открой BreakGateWorkout на Mac и выбери iPhone Stream (бета)"
                : "Open BreakGateWorkout on Mac and choose iPhone Stream (beta)"
        }
        return model.cameraStatusText
    }

    private var localizedConnectionState: String {
        switch model.connectionState {
        case .disconnected:
            return model.isRussian ? "не подключено" : "Disconnected"
        case .browsing:
            return model.isRussian ? "поиск Mac" : "Searching for Mac"
        case .connecting:
            return model.isRussian ? "подключение" : "Connecting"
        case .connected:
            return model.isRussian ? "подключено" : "Connected"
        case .streaming:
            return model.isRussian ? "трансляция" : "Streaming"
        case .failed:
            return model.isRussian ? "ошибка" : "Failed"
        }
    }

    private var statusIconName: String {
        switch model.connectionState {
        case .disconnected, .browsing:
            return "wifi"
        case .connecting:
            return "link"
        case .connected:
            return "checkmark.circle.fill"
        case .streaming:
            return "dot.radiowaves.left.and.right"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private func phoneActionButton(title: String, showsProgress: Bool, isPrimary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if showsProgress {
                    ProgressView()
                        .controlSize(.regular)
                }
                Text(title)
                    .font(.headline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(.plain)
        .background((isPrimary ? Color.green.opacity(0.22) : Color.white.opacity(0.08)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
    }
}
