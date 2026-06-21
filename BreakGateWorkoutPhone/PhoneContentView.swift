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

            VStack(alignment: .leading, spacing: 18) {
                Text("BreakGateWorkout Phone")
                    .font(.system(size: 32, weight: .bold, design: .rounded))

                Text("\(model.isRussian ? "Статус" : "Status"): \(localizedConnectionState)")
                    .font(.headline)
                    .foregroundStyle(.white.opacity(0.82))

                RemoteCameraPreview(image: model.previewImage)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(model.previewAspectRatio, contentMode: .fit)
                    .background(Color.black, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
                    Text("Mac: \(model.connectedMacLabel)")
                        .font(.subheadline.weight(.semibold))

                    if let stats = model.streamStatsText {
                        Text(stats)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 10) {
                    phoneActionButton(title: model.isRussian ? "Подключить" : "Connect") {
                        model.reconnect()
                    }
                    phoneActionButton(title: model.isRussian ? "Переподключить" : "Reconnect") {
                        model.reconnect()
                    }
                }

                HStack(spacing: 10) {
                    phoneActionButton(title: model.isRussian ? "Начать трансляцию" : "Start Stream", isPrimary: true) {
                        model.startStreaming()
                    }
                    phoneActionButton(title: model.isRussian ? "Остановить трансляцию" : "Stop Stream") {
                        model.stopStreaming()
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("\(model.isRussian ? "Зум" : "Zoom"): \(model.currentZoomLabel)")
                        .font(.subheadline.weight(.semibold))

                    HStack(spacing: 8) {
                        ForEach(RemoteCameraZoomLevel.allCases) { level in
                            Button(level.title) {
                                model.setZoom(level)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(model.currentZoomLevel == level ? .green : .gray)
                            .disabled(!model.supportedZoomLevels.contains(level))
                        }
                    }
                }

                Spacer()
            }
            .padding(24)
            .foregroundStyle(.white)
        }
        .onAppear {
            model.start()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                model.stopStreaming()
            }
        }
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

    private func phoneActionButton(title: String, isPrimary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .background((isPrimary ? Color.green.opacity(0.22) : Color.white.opacity(0.08)), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
    }
}
