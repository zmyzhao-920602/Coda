import SwiftUI
import CodaCore

@main
struct CodaIOSApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var downloadDelegate

    init() {
        CarPlayDiag.installExceptionHandler()
        let info = Bundle.main.infoDictionary
        CarPlayDiag.log("=== app launched, version \(info?["CFBundleShortVersionString"] as? String ?? "?") build \(info?["CFBundleVersion"] as? String ?? "?") ===")
    }

    var body: some Scene {
        WindowGroup {
            IOSMainWindow()
                .overlay(alignment: .topTrailing) { CarPlayDebugButton() }
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
        Button { showing = true } label: {
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
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("刷新") { text = CarPlayDiag.read() } }
            }
            .onAppear { text = CarPlayDiag.read() }
        }
    }
}

// MARK: - CarPlay

import CarPlay
import UIKit

/// CarPlay template scene delegate — audio app variant (two-argument didConnect only).
///
/// v8 is a deliberate experiment: the head unit went black even though every callback
/// fired and the connector returned normally. Two candidates remain:
///
///  a) CarPlay rejects the templates — `setRootTemplate` reports an error to its
///     completion handler, which previous builds passed as nil and never observed;
///  b) the placeholder list does render for a few seconds, then `CarPlayConnector`
///     installs a CPTabBarTemplate and Apple's CarPlayTemplateUIHost crashes while
///     building the tab bar (`-[UITabBar setDelegate:]` inside `_prepareTabBar`),
///     which matches the first crash report we captured.
///
/// So this build installs ONLY the list template, logs the completion result, and
/// never touches CarPlayConnector. If the head unit shows the list, (b) is confirmed.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    nonisolated(unsafe) static var strongRetain: CarPlaySceneDelegate?

    private var didStart = false
    private var interfaceController: CPInterfaceController?

    override init() {
        super.init()
        CarPlaySceneDelegate.strongRetain = self
        CarPlayDiag.log("CarPlaySceneDelegate init (retained)")
    }

    deinit { CarPlayDiag.log("CarPlaySceneDelegate deinit") }

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
            boot(interfaceController)
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

    private func boot(_ controller: CPInterfaceController) {
        let section = CPListSection(items: [
            makeRow("list template works"),
            makeRow("do not install the tab bar"),
        ])
        let list = CPListTemplate(title: "Coda", sections: [section])
        list.emptyViewTitleVariants = ["Coda 列表模板已加载"]

        CarPlayDiag.log("setRootTemplate: requesting (CPListTemplate)")
        controller.setRootTemplate(list, animated: false) { ok, error in
            if let error {
                CarPlayDiag.log("setRootTemplate FAILED ok=\(ok) error=\(error.localizedDescription) \(String(describing: error))")
            } else {
                CarPlayDiag.log("setRootTemplate OK ok=\(ok) top=\(String(describing: controller.topTemplate))")
            }
        }
        CarPlayDiag.log("setRootTemplate: request handed to CarPlay")

        // Deliberately no CarPlayConnector call: this build only answers whether a
        // plain list template reaches the head unit.
    }

    private func makeRow(_ text: String) -> CPListItem {
        let item = CPListItem(text: text, detailText: nil)
        item.handler = { _, completion in completion() }
        return item
    }
}
