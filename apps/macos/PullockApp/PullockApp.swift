import Foundation
import PullockCore
import PullockIPC
import PullockSimulation
import PullockUSB
import SwiftUI

@main
@MainActor
enum DevelopmentEntry {
    static func main() {
        if CommandLine.arguments.contains("--usb-inspect") {
            let watcher = USBWatcher { _ in }
            defer { watcher.stop() }
            do {
                try watcher.start()
                let redactor = ReportRedactor()
                let report: [String: Any] = ["component": "app", "realActions": 0, "protection": "unavailable",
                    "watcherReady": watcher.ready, "devices": watcher.inventory.map { $0.reportFields(using: redactor) }]
                let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                print(String(decoding: data, as: UTF8.self))
            } catch {
                print("{\"component\":\"app\",\"inspection\":\"failed\",\"realActions\":0}")
                Foundation.exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--self-check") {
            do {
                for scenario in SimulationScenario.allCases {
                    let steps = try SimulationRunner.run(scenario)
                    guard !steps.isEmpty, steps.allSatisfy({ $0.snapshot.profile == .simulation }) else {
                        throw SelfCheckFailure.invalidSimulation
                    }
                }
                print("{\"component\":\"app\",\"simulationScenarios\":6,\"realActions\":0,\"protocolVersion\":\(WireEnvelope.currentVersion)}")
            } catch {
                print("{\"component\":\"app\",\"selfCheck\":\"failed\"}")
                Foundation.exit(1)
            }
            return
        }
        PullockDevelopmentApp.main()
    }

    private enum SelfCheckFailure: Error { case invalidSimulation }
}

struct PullockDevelopmentApp: App {
    @State private var services = ServiceInspector()
    var body: some Scene {
        WindowGroup("Pullock Development · USB", id: "devices") {
            DaemonDevicesView().environment(services).frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 980, height: 680)
        WindowGroup("Pullock Development · Local USB inspection", id: "local-usb") {
            USBInspectorView().frame(minWidth: 820, minHeight: 560)
        }
        .defaultLaunchBehavior(.suppressed)
        WindowGroup("Pullock Development", id: "simulation") {
            SimulationView()
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 980, height: 680)
        .defaultLaunchBehavior(.suppressed)
        WindowGroup("Pullock Development · Screen lock test", id: "lock-test") {
            LockTestView().frame(minWidth: 680, minHeight: 500)
        }
        .defaultLaunchBehavior(.suppressed)
        WindowGroup("Pullock Development · Services", id: "services") {
            ServiceInspectorView().environment(services).frame(minWidth: 720, minHeight: 560)
        }
        .defaultLaunchBehavior(.suppressed)
        MenuBarExtra("Pullock · No protection", systemImage: "lock.slash") {
            DevelopmentMenu()
        }
    }
}

private struct DevelopmentMenu: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Text("DEVELOPMENT · No protection")
        Button("Choose USB connection") { openWindow(id: "devices") }
        Button("Local USB inspection") { openWindow(id: "local-usb") }
        Button("Open simulations") { openWindow(id: "simulation") }
        Button("Diagnostic services") { openWindow(id: "services") }
        Button("Test screen lock…") { openWindow(id: "lock-test") }
        Divider()
        Button("Quit Pullock Development") { NSApplication.shared.terminate(nil) }
    }
}

private struct SimulationView: View {
    @State private var selected: SimulationScenario = .removal
    @State private var steps: [SimulationStep] = []
    @State private var failed = false

    var body: some View {
        NavigationSplitView {
            List(SimulationScenario.allCases, selection: $selected) { scenario in
                Text(scenario.title).tag(scenario)
            }
            .navigationTitle("Scenarios")
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SIMULATION · NO PROTECTION")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(selected.title).font(.largeTitle.weight(.semibold))
                    Text("Synthetic events exercise the real state reducer. Simulations never lock or shut down your Mac.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                if failed {
                    ContentUnavailableView("Simulation failed", systemImage: "exclamationmark.triangle")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                                HStack(alignment: .top, spacing: 14) {
                                    Text(String(index + 1)).monospacedDigit().foregroundStyle(.secondary)
                                        .frame(width: 18)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(step.label).font(.headline)
                                        Text("SIMULATED \(step.snapshot.status.rawValue.uppercased())")
                                            .font(.caption.monospaced())
                                        ForEach(Array(step.actions.enumerated()), id: \.offset) { _, action in
                                            Text("Would request \(action.id.kind.rawValue) · not executed")
                                                .font(.callout).foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Spacer(minLength: 0)
                Divider()
                HStack {
                    Text("Live lock adapter and key enrollment are not qualified.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Run simulation", action: run).keyboardShortcut(.return)
                }
            }
            .padding(28)
        }
        .onAppear(perform: run)
        .onChange(of: selected) { run() }
    }

    private func run() {
        do { steps = try SimulationRunner.run(selected); failed = false }
        catch { steps = []; failed = true }
    }
}
