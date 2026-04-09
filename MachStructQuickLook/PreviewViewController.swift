import Cocoa
import Quartz

// MARK: - PreviewViewController

/// Quick Look Preview Extension for MachStruct (P6-05).
///
/// Displays JSON, XML, YAML, and CSV files as formatted UTF-8 text in a
/// read-only, scrollable `NSTextView`.  The display is intentionally
/// minimal — the goal is fast Finder preview with no parsing overhead.
///
/// For large files (> 256 KB) the preview is truncated with a notice so
/// that the extension never blocks the Quick Look daemon.
class PreviewViewController: NSViewController, QLPreviewingController {

    private static let truncateThreshold = 256 * 1024  // 256 KB

    // MARK: - View

    private let scrollView = NSScrollView()
    private let textView   = NSTextView()

    override func loadView() {
        // Wire up the scroll view and text view manually (no nib).
        textView.isEditable      = false
        textView.isSelectable    = true
        textView.isRichText      = false
        textView.font            = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1,
                                                         weight: .regular)
        textView.textContainerInset = NSSize(width: 10, height: 10)
        textView.autoresizingMask   = [.width]

        scrollView.documentView          = textView
        scrollView.hasVerticalScroller   = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers    = true
        scrollView.drawsBackground       = true
        scrollView.backgroundColor       = .textBackgroundColor

        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.frame = NSRect(x: 0, y: 0, width: 640, height: 480)
    }

    // MARK: - QLPreviewingController

    /// Called by Quick Look daemon; must call `handler` when ready.
    func preparePreviewOfFile(at url: URL,
                              completionHandler handler: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let data = try Data(contentsOf: url)
                let raw  = String(data: data, encoding: .utf8)
                        ?? String(data: data, encoding: .isoLatin1)
                        ?? "<Could not decode file contents as UTF-8>"

                let truncated = data.count > PreviewViewController.truncateThreshold
                let display   = truncated
                    ? String(raw.prefix(PreviewViewController.truncateThreshold))
                      + "\n\n⋯  [truncated — open in MachStruct for full view]"
                    : raw

                DispatchQueue.main.async {
                    self?.textView.string = display
                    handler(nil)
                }
            } catch {
                DispatchQueue.main.async {
                    self?.textView.string = "Error reading file: \(error.localizedDescription)"
                    handler(nil)   // Don't propagate — show the error inline instead
                }
            }
        }
    }
}
