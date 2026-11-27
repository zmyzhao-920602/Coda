import SwiftUI
import CodaCore

@main
struct CodaIOSApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var downloadDelegate

    init() {
        CarPlayDiag.installExceptionHandler()
        CarPlayDiag.log("app launched, version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
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

/// Writes a plain-text log into the app's Documents folder so it can be pulled off
/// the device through the Files app (UIFileSharingEnabled is set in Info.plist).
/// Goal: capture the CarPlay-side NSException reason, which .ips crash reports omit.
enum CarPlayDiag {
    static let fileName = "carplay-diag.log"

    static var logURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return dir.appendingPathComponent(fileName)
    }

    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
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

/// CarPlay template scene delegate — instantiated automatically by UIApplicationSceneManifest in Info.plist.
/// It just forwards the connect/disconnect callbacks into `CarPlayConnector` inside CodaCore;
/// the app target itself stays as a thin bridge and owns no CarPlay logic of its own.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var didStart = false

    override init() {
        super.init()
        CarPlayDiag.log("CarPlaySceneDelegate init")
    }

    fileprivate func startOnce(_ label: String, _ body: () -> Void) {
        if didStart {
            CarPlayDiag.log("\(label): already started, ignoring duplicate callback")
            return
        }
        didStart = true
        body()
    }
}

extension CarPlaySceneDelegate {
    // iOS 14+ variant. Apple's navigation apps receive this one; whether audio apps
    // get it (with a nil window) is exactly what we are trying to establish.
    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        CarPlayDiag.log("didConnect(3-arg) fired")
        startOnce("didConnect(3-arg)") {
            boot(interfaceController, window: window)
        }
    }

    // iOS 13 variant, still the documented one for audio apps.
    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        CarPlayDiag.log("didConnect(2-arg) fired")
        startOnce("didConnect(2-arg)") {
            boot(interfaceController, window: scene.carWindow)
        }
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        CarPlayDiag.log("didDisconnect fired")
        didStart = false
        CarPlayConnector.shared.didDisconnect()
    }

    /// Install a placeholder root template first: if this shows up on the head unit
    /// but the real tabs never do, the problem is inside CarPlayConnector, not the
    /// scene plumbing.
    private func boot(_ interfaceController: CPInterfaceController, window: CPWindow) {
        CarPlayDiag.log("boot: installing placeholder root template")
        let placeholder = CPListTemplate(title: "Coda", sections: [])
        placeholder.emptyViewTitleVariants = ["Coda 正在连接…"]
        interfaceController.setRootTemplate(placeholder, animated: false, completion: nil)
        CarPlayDiag.log("boot: placeholder installed, handing over to CarPlayConnector")

        CarPlayConnector.shared.didConnect(
            interfaceController: interfaceController,
            window: window
        )
        CarPlayDiag.log("boot: CarPlayConnector.didConnect returned")
    }
}
