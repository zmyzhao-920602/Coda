import SwiftUI
import CodaCore

@main
struct CodaIOSApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var downloadDelegate
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

// MARK: - CarPlay

import CarPlay
import UIKit

/// CarPlay template scene delegate — instantiated automatically by UIApplicationSceneManifest in Info.plist.
/// It just forwards the connect/disconnect callbacks into `CarPlayConnector` inside CodaCore;
/// the app target itself stays as a thin bridge and owns no CarPlay logic of its own.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {}

extension CarPlaySceneDelegate {
    // iOS 14+ (including 16.5) calls the three-argument variant that carries a CPWindow.
    // The old two-argument `didConnect interfaceController:` form is a leftover iOS 13
    // signature: it is no longer part of the protocol, so it is never invoked and the
    // root template is never installed — which is exactly why CarPlay showed a black screen.
    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController,
        to window: CPWindow
    ) {
        CarPlayConnector.shared.didConnect(
            interfaceController: interfaceController,
            window: window
        )
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        CarPlayConnector.shared.didDisconnect()
    }
}
