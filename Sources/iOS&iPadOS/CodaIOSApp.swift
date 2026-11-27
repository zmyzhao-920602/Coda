import SwiftUI
import CodaCore

@main
struct CodaIOSApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var downloadDelegate

    init() {
        CarPlayDiag.installExceptionHandler()
        let info = Bundle.main.infoDictionary
        CarPlayDiag.log("app launched, version \(info?["CFBundleShortVersionString"] as? String ?? "?") build \(info?["CFBundleVersion"] as? String ?? "?")")
    }

    var body: some Scene {
        WindowGroup {
            IOSMainWindow()
                .overlay(alignment: .topTrailing) {
                    CarPlayDebugButton()
                }
        }
    }
}

final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        OfflineDownloadEvents.handleBackgroundSession(identifier: identifier, completion: completionHandler)
    }
}

// MARK: - Diagnostics

/// Plain-text log in the app's Documents folder, also viewable in-app through the
/// stethoscope button (top-right) so it can be read without the Files app.
enum CarPlayDiag {
    static let fileName = "carplay-diag.log"

    static var logURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent(fileName)
    }

    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = ("[\(stamp)] \(message)\n").data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL, options: .atomic)
        }
    }

    static func read() -> String {
        (try? String(contentsOf: logURL, encoding: .utf8)) ?? "<还没有日志文件：\(logURL.path)>"
    }

    static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            CarPlayDiag.log("UNCAUGHT \(exception.name.rawValue): \(exception.reason ?? "<no reason>")")
            CarPlayDiag.log("STACK:\n" + exception.callStackSymbols.joined(separator: "\n"))
        }
    }
}

struct CarPlayDebugButton: View {
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "stethoscope")
                .font(.system(size: 15, weight: .semibold))
                .padding(9)
                .background(.ultraThinMaterial, in: Circle())
        }
        .padding(10)
        .sheet(isPresented: $showing) { CarPlayDebugView() }
    }
}

struct CarPlayDebugView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
            .navigationTitle("CarPlay 诊断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("刷新") { text = CarPlayDiag.read() }
                }
            }
            .onAppear { text = CarPlayDiag.read() }
        }
    }
}

// MARK: - CarPlay

import CarPlay
import UIKit

/// CarPlay template scene delegate.
///
/// Only the two-argument `didConnect interfaceController:` variant is implemented:
/// on iOS 16.5 the three-argument variant aborts inside CarPlay's own delivery step
/// because audio apps have no CPWindow.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    /// `UIScene.delegate` is weak, and nothing in a SwiftUI lifecycle retains this object.
    nonisolated(unsafe) static var strongRetain: CarPlaySceneDelegate?

    private var didStart = false
    private var interfaceController: CPInterfaceController?

    override init() {
        super.init()
        CarPlaySceneDelegate.strongRetain = self
        CarPlayDiag.log("CarPlaySceneDelegate init (retained)")
    }

    deinit {
        CarPlayDiag.log("CarPlaySceneDelegate deinit")
    }

    fileprivate func startOnce(_ label: String, _ body: () -> Void) {
        if didStart {
            CarPlayDiag.log("\(label): duplicate callback ignored")
            return
        }
        didStart = true
        body()
    }
}

extension CarPlaySceneDelegate {
    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        CarPlayDiag.log("didConnect(2-arg) fired")
        startOnce("didConnect(2-arg)") {
            self.interfaceController = interfaceController
            boot(interfaceController, window: scene.carWindow)
        }
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        CarPlayDiag.log("didDisconnect fired")
        didStart = false
        self.interfaceController = nil
        CarPlayConnector.shared.didDisconnect()
    }

    private func boot(_ controller: CPInterfaceController, window: CPWindow) {
        CarPlayDiag.log("step1: installing placeholder CPListTemplate")
        let placeholder = CPListTemplate(title: "Coda", sections: [])
        placeholder.emptyViewTitleVariants = ["Coda 正在连接…"]
        controller.setRootTemplate(placeholder, animated: false, completion: nil)
        CarPlayDiag.log("step1: placeholder installed")

        CarPlayDiag.log("step2: scheduling CarPlayConnector in 5s")
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, self.interfaceController === controller else {
                CarPlayDiag.log("step2: skipped, scene gone")
                return
            }
            CarPlayDiag.log("step2: calling CarPlayConnector.didConnect")
            CarPlayConnector.shared.didConnect(interfaceController: controller, window: window)
            CarPlayDiag.log("step2: CarPlayConnector.didConnect returned")
        }
    }
}
