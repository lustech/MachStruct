import SwiftUI

// MARK: - OnboardingFeature

private struct OnboardingFeature: Identifiable {
    let id:          Int
    let icon:        String
    let color:       Color
    let title:       String
    let description: String
}

// MARK: - OnboardingView

/// First-launch welcome sheet shown once.
///
/// Displayed by `WelcomeView` when `AppSettings.Keys.hasSeenOnboarding` is
/// false.  The "Get Started" button sets the flag so the sheet never appears
/// again.
struct OnboardingView: View {

    @AppStorage(AppSettings.Keys.hasSeenOnboarding)
    private var hasSeenOnboarding = false

    @Environment(\.dismiss) private var dismiss

    private let features: [OnboardingFeature] = [
        OnboardingFeature(
            id: 0,
            icon: "list.bullet.indent",
            color: .blue,
            title: "Navigate Any Structure",
            description: "Explore JSON, XML, YAML, and CSV as an expandable tree. Collapse large subtrees to focus on what matters."
        ),
        OnboardingFeature(
            id: 1,
            icon: "pencil",
            color: .orange,
            title: "Edit In Place",
            description: "Click any value to edit it. Full undo and redo via ⌘Z so you can experiment without risk."
        ),
        OnboardingFeature(
            id: 2,
            icon: "magnifyingglass",
            color: .purple,
            title: "Instant Search",
            description: "Press ⌘F to search every key and value instantly, even in documents with hundreds of thousands of nodes."
        ),
        OnboardingFeature(
            id: 3,
            icon: "arrow.left.arrow.right",
            color: .teal,
            title: "Convert & Export",
            description: "Convert between JSON, YAML, and CSV with a single click. Copy any subtree to the clipboard as formatted JSON."
        ),
        OnboardingFeature(
            id: 4,
            icon: "doc.plaintext",
            color: Color(red: 0.5, green: 0.3, blue: 0.8),
            title: "Syntax-Highlighted Raw View",
            description: "Switch to raw text at any time. Syntax highlighting makes reading large files effortless."
        ),
        OnboardingFeature(
            id: 5,
            icon: "sparkles",
            color: .green,
            title: "Quick Look & Spotlight",
            description: "Preview files with Space bar in Finder, and find content inside your documents with Spotlight search."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {

            // ── Hero ────────────────────────────────────────────────────────
            VStack(spacing: 8) {
                Image(systemName: "curlybraces.square.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(.blue)

                Text("Welcome to MachStruct")
                    .font(.title.bold())

                Text("A fast, native viewer and editor for structured data.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 32)
            .padding(.bottom, 24)
            .padding(.horizontal, 32)

            Divider()

            // ── Feature grid ────────────────────────────────────────────────
            ScrollView {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 16),
                        GridItem(.flexible(), spacing: 16),
                    ],
                    spacing: 16
                ) {
                    ForEach(features) { f in
                        FeatureCard(feature: f)
                    }
                }
                .padding(20)
            }

            Divider()

            // ── Footer ──────────────────────────────────────────────────────
            HStack {
                Text("You can revisit this any time from the Help menu.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Get Started") {
                    hasSeenOnboarding = true
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.regularMaterial)
        }
        .frame(width: 520, height: 520)
    }
}

// MARK: - FeatureCard

private struct FeatureCard: View {
    let feature: OnboardingFeature

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: feature.icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(feature.color)
                .frame(width: 32, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.system(size: 12, weight: .semibold))
                Text(feature.description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.primary.opacity(0.07))
        )
    }
}

// MARK: - Preview

#Preview {
    OnboardingView()
}
