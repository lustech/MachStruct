import SwiftUI

// MARK: - AppSettings

/// Centralised `UserDefaults` key names for the app.
///
/// Use `@AppStorage(AppSettings.Keys.foo)` anywhere in the view hierarchy
/// to read/write a persistent setting.  Default values are defined here as
/// constants so they stay in one place.
enum AppSettings {
    enum Keys {
        static let rawFontSize          = "rawFontSize"
        static let treeFontSize         = "treeFontSize"
        static let defaultRawPretty     = "defaultRawPretty"
        static let showWelcomeOnLaunch  = "showWelcomeOnLaunch"
        static let hasSeenOnboarding    = "hasSeenOnboarding"
    }
    enum Defaults {
        static let rawFontSize: Double  = 13
        static let treeFontSize: Double = 12
        static let defaultRawPretty     = true
        static let showWelcomeOnLaunch  = true
    }
}

// MARK: - SettingsView

/// Root view for the app's Preferences / Settings window (⌘,).
///
/// Three tabs — General, Appearance, Raw View — each backed by `@AppStorage`
/// so changes take effect immediately and persist across launches.
struct SettingsView: View {

    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General",    systemImage: "gearshape") }

            AppearanceTab()
                .tabItem { Label("Appearance", systemImage: "paintbrush") }

            RawViewTab()
                .tabItem { Label("Raw View",   systemImage: "doc.plaintext") }
        }
        .frame(width: 380)
        .fixedSize()
    }
}

// MARK: - GeneralTab

private struct GeneralTab: View {

    @AppStorage(AppSettings.Keys.showWelcomeOnLaunch)
    private var showWelcomeOnLaunch = AppSettings.Defaults.showWelcomeOnLaunch

    var body: some View {
        Form {
            Section {
                Toggle("Show welcome window at launch", isOn: $showWelcomeOnLaunch)
            } header: {
                Text("Startup")
            }

            Section {
                LabeledContent("Version") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                         as? String ?? "—")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Build") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion")
                         as? String ?? "—")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - AppearanceTab

private struct AppearanceTab: View {

    @AppStorage(AppSettings.Keys.treeFontSize)
    private var treeFontSize = AppSettings.Defaults.treeFontSize

    private let treeSizes: [Double] = [11, 12, 13, 14]

    var body: some View {
        Form {
            Section {
                Picker("Tree view font size", selection: $treeFontSize) {
                    ForEach(treeSizes, id: \.self) { size in
                        Text("\(Int(size)) pt").tag(size)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Tree View")
            } footer: {
                Text("Controls the font size of node keys and values in the outline.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - RawViewTab

private struct RawViewTab: View {

    @AppStorage(AppSettings.Keys.rawFontSize)
    private var rawFontSize = AppSettings.Defaults.rawFontSize

    @AppStorage(AppSettings.Keys.defaultRawPretty)
    private var defaultRawPretty = AppSettings.Defaults.defaultRawPretty

    private let rawSizes: [Double] = [11, 12, 13, 14, 16]

    var body: some View {
        Form {
            Section {
                Picker("Font size", selection: $rawFontSize) {
                    ForEach(rawSizes, id: \.self) { size in
                        Text("\(Int(size)) pt").tag(size)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Font")
            }

            Section {
                Picker("Default mode", selection: $defaultRawPretty) {
                    Text("Pretty-printed").tag(true)
                    Text("Minified").tag(false)
                }
                .pickerStyle(.radioGroup)
            } header: {
                Text("Output")
            } footer: {
                Text("Applies when first switching to Raw View for a document.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Preview

#Preview {
    SettingsView()
}
