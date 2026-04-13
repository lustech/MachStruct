import AppKit
import SwiftUI

/// A read-only, syntax-coloured text view backed by `NSTextView`.
///
/// Replaces the SwiftUI `Text(AttributedString)` approach in the raw view.
/// `NSTextView`'s layout manager is incremental — only glyphs in the visible
/// viewport are laid out, so files up to 10+ MB render without stalls.
///
/// Supports both highlighted (`NSAttributedString`) and plain-text fallback.
/// Scrolling (horizontal + vertical) is handled natively by the embedded
/// `NSScrollView`; no wrapping SwiftUI `ScrollView` is needed.
struct HighlightedTextView: NSViewRepresentable {

    /// Syntax-highlighted content. When `nil`, `plainText` is rendered with the
    /// monospaced system font at `fontSize`.
    let attributedText: NSAttributedString?

    /// Plain-text fallback shown while highlighting is being computed.
    let plainText: String

    /// Point size for the monospaced font (used for the plain-text fallback and
    /// passed through to `SyntaxHighlighter` when building `attributedText`).
    let fontSize: CGFloat

    // MARK: - NSViewRepresentable

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }

        textView.isEditable                     = false
        textView.isSelectable                   = true
        textView.drawsBackground                = true
        textView.backgroundColor                = .textBackgroundColor
        textView.textContainerInset             = NSSize(width: 8, height: 8)
        textView.usesFontPanel                  = false
        textView.usesRuler                      = false
        textView.isAutomaticQuoteSubstitutionEnabled = false

        // Allow lines longer than the viewport width (minified JSON, CSV, etc.)
        // without forced wrapping, enabling horizontal scrolling.
        textView.isHorizontallyResizable        = true
        textView.maxSize                        = NSSize(width:  CGFloat.greatestFiniteMagnitude,
                                                         height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize   = NSSize(width:  CGFloat.greatestFiniteMagnitude,
                                                          height: CGFloat.greatestFiniteMagnitude)

        scrollView.hasVerticalScroller          = true
        scrollView.hasHorizontalScroller        = true
        scrollView.autohidesScrollers           = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        let newContent: NSAttributedString
        if let attributed = attributedText {
            newContent = attributed
        } else {
            let mono = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
            newContent = NSAttributedString(string: plainText,
                                             attributes: [.font: mono])
        }

        // Avoid resetting the scroll position when the content hasn't changed.
        guard textView.textStorage?.string != newContent.string else { return }
        textView.textStorage?.setAttributedString(newContent)
    }
}
