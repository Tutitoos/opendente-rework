import SwiftUI

@main
struct OpenDenteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var language = LanguageManager.shared

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(\.locale, language.locale)
        }
    }
}
