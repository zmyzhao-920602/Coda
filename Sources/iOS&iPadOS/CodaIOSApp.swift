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

/// Plain-text log in the app's Documents folder, reachable through the Files app.
/// `.ips` reports never carry an NSException reason, so we record failures ourselves.
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

    static func installExceptionHandler() {
        NSSetUncaughtExceptionHandler { exception in
            CarPlayDiag.log("UNCAUGHT \(exception.name.rawValue): \(exception.reason ?? "<no reason>")")
            CarPlayDiag.log("STACK:\n" + exception.callStackSymbols.joined(separator: "\n"))
        }
    }
}

// MARK: - CarPlay

import CarPlay
import UIKit

/// CarPlay template scene delegate.
///
/// Deliberately implements ONLY the two-argument `didConnect interfaceController:`
/// variant. Evidence from two crash reports on iOS 16.5:
///
///  * two-argument (v1): CarPlay delivers the interface controller, the app installs a
///    CPTabBarTemplate, and then Apple's CarPlayTemplateUIHost crashes while building
///    the tab bar (`-[UITabBar setDelegate:]` ← `_prepareTabBar` ← `_UIAppearance`),
///    which the user sees as a black screen;
///  * three-argument (v2): CarPlay aborts inside `_deliverInterfaceControllerToDelegate`
///    while assembling its userInfo dictionary — audio apps have no CPWindow, so that
///    path is unusable here.
///
/// So: keep the two-argument method, and find out what the host chokes on.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    /// `UIScene.delegate` is weak; nothing else retains this object.
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
        // Step 1: a plain list template. If this renders on the head unit, the scene
        // plumbing is fine and the tab bar template is what upsets the host.
        CarPlayDiag.log("step1: installing placeholder CPListTemplate")
        let placeholder = CPListTemplate(title: "Coda", sections: [])
        placeholder.emptyViewTitleVariants = ["Coda 正在连接…"]
        controller.setRootTemplate(placeholder, animated: false, completion: nil)
        CarPlayDiag.log("step1: placeholder installed")

        // Step 2: hand over to the real connector, which installs a CPTabBarTemplate.
        // Running it a few seconds later keeps the two experiments distinguishable in
        // the log (and lets the placeholder paint first if the host survives).
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
