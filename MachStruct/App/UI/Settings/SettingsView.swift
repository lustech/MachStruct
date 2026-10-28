import SwiftUI
import MachStructCore

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
        static let singleClickExpand    = "singleClickExpand"
        static let colorTheme           = "colorTheme"
    }
    enum Defaults {
        static let rawFontSize: Double  = 13
        static let treeFontSize: Double = 12
        static let defaultRawPretty     = true
        static let showWelcomeOnLaunch  = true
        static let singleClickExpand    = true
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

    @AppStorage(AppSettings.Keys.singleClickExpand)
    private var singleClickExpand = AppSettings.Defaults.singleClickExpand

    var body: some View {
        Form {
            Section {
                Toggle("Show welcome window at launch", isOn: $showWelcomeOnLaunch)
            } header: {
                Text("Startup")
            }

            Section {
                Toggle("Single-click to expand tree rows", isOn: $singleClickExpand)
            } header: {
                Text("Tree View")
            } footer: {
                Text("When on, clicking anywhere on an expandable row toggles it. The disclosure chevron always works regardless.")
                    .foregroundStyle(.secondary)
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

    @AppStorage(AppSettings.Keys.colorTheme)
    private var colorTheme = ColorTheme.standard

    private let treeSizes: [Double] = [11, 12, 13, 14]

    var body: some View {
        Form {
            Section {
                Picker("Theme", selection: $colorTheme) {
                    ForEach(ColorTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                ThemeSample(theme: colorTheme)
            } header: {
                Text("Colours")
            } footer: {
                Text("Colours for keys and values in the tree, table and raw views. Each theme has a light and a dark version that follow the system appearance.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

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

/// A line of JSON in `theme`'s colours, to preview it in Settings.
private struct ThemeSample: View {
    let theme: ColorTheme

    var body: some View {
        HStack(spacing: 0) {
            Text("\"city\"").foregroundStyle(theme.color(\.key))
            Text(": ").foregroundStyle(theme.color(\.muted))
            Text("\"Oslo\"").foregroundStyle(theme.color(\.string))
            Text(", ").foregroundStyle(theme.color(\.muted))
            Text("59.33").foregroundStyle(theme.color(\.number))
            Text(", ").foregroundStyle(theme.color(\.muted))
            Text("true").foregroundStyle(theme.color(\.boolean))
            Spacer(minLength: 0)
        }
        .font(.system(.body, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(theme.color(\.background), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sample of the \(theme.displayName) theme")
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
