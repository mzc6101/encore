import Foundation
import SwiftUI

/// App preferences, stored in the app's standard defaults.
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    @Published var showOnLockScreen: Bool { didSet { defaults.set(showOnLockScreen, forKey: "showOnLockScreen") } }
    @Published var showFullscreenHotkeyEnabled: Bool { didSet { defaults.set(showFullscreenHotkeyEnabled, forKey: "showFullscreenHotkeyEnabled") } }
    @Published var useClearGlass: Bool { didSet { defaults.set(useClearGlass, forKey: "useClearGlass") } }
    @Published var useAnimatedArtwork: Bool { didSet { defaults.set(useAnimatedArtwork, forKey: "useAnimatedArtwork") } }
    @Published var lyricsEnabled: Bool { didSet { defaults.set(lyricsEnabled, forKey: "lyricsEnabled") } }
    @Published var storefront: String { didSet { defaults.set(storefront, forKey: "storefront") } }
    @Published var preferredBackend: String { didSet { defaults.set(preferredBackend, forKey: "preferredBackend") } }

    private init() {
        let d = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool { d.object(forKey: key) as? Bool ?? fallback }
        showOnLockScreen = bool("showOnLockScreen", true)
        showFullscreenHotkeyEnabled = bool("showFullscreenHotkeyEnabled", false)
        useClearGlass = bool("useClearGlass", true)
        useAnimatedArtwork = bool("useAnimatedArtwork", true)
        lyricsEnabled = bool("lyricsEnabled", true)
        storefront = d.string(forKey: "storefront") ?? "us"
        preferredBackend = d.string(forKey: "preferredBackend") ?? "auto"
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        Form {
            Section("Display") {
                Toggle("Show on lock screen", isOn: $settings.showOnLockScreen)
                Toggle("Fullscreen hotkey", isOn: $settings.showFullscreenHotkeyEnabled)
                Toggle("Clear glass", isOn: $settings.useClearGlass)
                Toggle("Lyrics", isOn: $settings.lyricsEnabled)
            }
            Section("Animated artwork") {
                Toggle("Use animated artwork", isOn: $settings.useAnimatedArtwork)
                TextField("Storefront", text: $settings.storefront)
            }
            Section("Playback source") {
                Picker("Backend", selection: $settings.preferredBackend) {
                    Text("Automatic").tag("auto")
                    Text("MediaRemote").tag("mediaremote")
                    Text("Browser / AppleScript").tag("applescript")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding(.vertical, 8)
    }
}
