import SwiftUI

@main
struct BreakGateWorkoutPhoneApp: App {
    @StateObject private var model = PhoneCameraStreamModel()

    var body: some Scene {
        WindowGroup {
            PhoneContentView(model: model)
        }
    }
}
