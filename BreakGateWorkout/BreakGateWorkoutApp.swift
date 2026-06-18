//
//  BreakGateWorkoutApp.swift
//  BreakGateWorkout
//
//  Created by Артем Иванченко on 18.06.2026.
//

import AppKit
import Combine
import CoreGraphics
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct BreakGateWorkoutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = BreakGateMonitor()
    @StateObject private var stats = WorkoutStats()

    var body: some Scene {
        Window("BreakGateWorkout", id: "workout") {
            ContentView(monitor: monitor, stats: stats)
        }

        MenuBarExtra {
            MenuBarControlView(monitor: monitor, stats: stats)
        } label: {
            MenuBarStatusLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.menu)
    }
}

private struct MenuBarStatusLabel: View {
    @ObservedObject var monitor: BreakGateMonitor
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: monitor.gateActive ? "figure.strengthtraining.traditional" : "camera.viewfinder")
            .symbolRenderingMode(.hierarchical)
            .onAppear {
                monitor.start()
            }
            .onReceive(monitor.$gateActive.removeDuplicates()) { isActive in
                guard isActive else { return }
                openWorkoutWindow()
            }
    }

    private func openWorkoutWindow() {
        openWindow(id: "workout")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

private struct MenuBarControlView: View {
    @ObservedObject var monitor: BreakGateMonitor
    @ObservedObject var stats: WorkoutStats
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Toggle("Monitoring \(monitor.isMonitoringEnabled ? "On" : "Off")", isOn: Binding(
            get: { monitor.isMonitoringEnabled },
            set: { monitor.setMonitoringEnabled($0) }
        ))

        Divider()

        Text("Current Activity Score: \(Int(monitor.activityScore.rounded()))")
        Text("Break Pressure: \(monitor.breakPressure.title)")
        Text(monitor.gateActive ? "Gate: Active" : "Gate: Idle")

        Divider()

        Button("Start Workout Now") {
            monitor.triggerGate()
            openWorkoutWindow()
        }

        Button("Open Workout Window") {
            openWorkoutWindow()
        }

        Button("Reset Current Gate") {
            monitor.resetCurrentGate()
        }

        Divider()

        Text("Total workouts completed: \(stats.totalWorkoutsCompleted)")
        Text("Total push-ups: \(stats.totalPushUps)")
        Text("Total squats: \(stats.totalSquats)")
        Text("Total sit-ups: \(stats.totalSitUps)")
        Text("Total plank seconds: \(stats.totalPlankSeconds)")
        Text("Last workout: \(stats.lastWorkoutDescription)")

        Divider()

        Button("Reset Score") {
            monitor.resetScore()
        }

        Button("Reset All Stats") {
            stats.resetAll()
        }

        Button("Quit BreakGateWorkout") {
            NSApplication.shared.terminate(nil)
        }
    }

    private func openWorkoutWindow() {
        openWindow(id: "workout")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

enum BreakPressure: String {
    case low = "Low"
    case medium = "Medium"
    case high = "High"
    case critical = "Critical"

    var title: String { rawValue }
}

@MainActor
final class BreakGateMonitor: ObservableObject {
    @Published private(set) var activityScore: Double = 0
    @Published private(set) var breakPressure: BreakPressure = .low
    @Published private(set) var gateActive = false
    @Published private(set) var lastWorkoutDate: Date?
    @Published var isMonitoringEnabled = true

    private var monitorTask: Task<Void, Never>?

    func start() {
        guard monitorTask == nil else { return }

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
            gateActive = false
        }
    }

    func triggerGate() {
        guard isMonitoringEnabled else { return }
        gateActive = true
    }

    func resetCurrentGate() {
        gateActive = false
    }

    func resetScore() {
        activityScore = 0
        breakPressure = .low
        gateActive = false
    }

    func recordWorkoutCompletion(date: Date = Date()) {
        activityScore = 0
        breakPressure = .low
        gateActive = false
        lastWorkoutDate = date
    }

    private func tick() {
        guard isMonitoringEnabled else { return }

        let idleSeconds = currentSystemIdleSeconds()
        if idleSeconds < 60 {
            activityScore += 4
        } else if idleSeconds > 300 {
            activityScore -= 8
        }

        activityScore = min(100, max(0, activityScore))
        breakPressure = pressure(for: activityScore)

        guard !gateActive, randomTriggerShouldFire(score: activityScore) else { return }
        gateActive = true
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
    @Published private(set) var lastWorkoutDate: Date? {
        didSet { save() }
    }

    var lastWorkoutDescription: String {
        guard let lastWorkoutDate else { return "Never" }
        return lastWorkoutDate.formatted(date: .abbreviated, time: .shortened)
    }

    private let defaults = UserDefaults.standard
    private let totalWorkoutsKey = "BreakGateWorkout.totalWorkoutsCompleted"
    private let totalPushUpsKey = "BreakGateWorkout.totalPushUps"
    private let totalSquatsKey = "BreakGateWorkout.totalSquats"
    private let totalSitUpsKey = "BreakGateWorkout.totalSitUps"
    private let totalPlankSecondsKey = "BreakGateWorkout.totalPlankSeconds"
    private let lastWorkoutDateKey = "BreakGateWorkout.lastWorkoutDate"

    init() {
        totalWorkoutsCompleted = defaults.integer(forKey: totalWorkoutsKey)
        totalPushUps = defaults.integer(forKey: totalPushUpsKey)
        totalSquats = defaults.integer(forKey: totalSquatsKey)
        totalSitUps = defaults.integer(forKey: totalSitUpsKey)
        totalPlankSeconds = defaults.integer(forKey: totalPlankSecondsKey)
        lastWorkoutDate = defaults.object(forKey: lastWorkoutDateKey) as? Date
    }

    func recordWorkoutCompletion(mode: ExerciseMode, amount: Int, date: Date = Date()) {
        totalWorkoutsCompleted += 1
        lastWorkoutDate = date

        switch mode {
        case .pushUps:
            totalPushUps += amount
        case .squats:
            totalSquats += amount
        case .abs:
            totalSitUps += amount
        case .plank:
            totalPlankSeconds += amount
        }
    }

    func resetAll() {
        totalWorkoutsCompleted = 0
        totalPushUps = 0
        totalSquats = 0
        totalSitUps = 0
        totalPlankSeconds = 0
        lastWorkoutDate = nil
    }

    private func save() {
        defaults.set(totalWorkoutsCompleted, forKey: totalWorkoutsKey)
        defaults.set(totalPushUps, forKey: totalPushUpsKey)
        defaults.set(totalSquats, forKey: totalSquatsKey)
        defaults.set(totalSitUps, forKey: totalSitUpsKey)
        defaults.set(totalPlankSeconds, forKey: totalPlankSecondsKey)
        defaults.set(lastWorkoutDate, forKey: lastWorkoutDateKey)
    }
}
