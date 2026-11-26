import SwiftUI
import WebKit

/// Where FluidCraft lives online.
enum FluidCraftLinks {
    static let website = URL(string: "https://perseus-sepahi.github.io/software/fluidcraft/")!
    static let repository = URL(string: "https://github.com/perseus-sepahi/fluidcraft")!
    static let issues = URL(string: "https://github.com/perseus-sepahi/fluidcraft/issues")!
}

struct HelpCommands: Commands {
    let ws: Workspace
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("fluidcraft.settingsTab") private var settingsTab = "general"

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("FluidCraft Guide") { openWindow(id: "guide") }
            Button("Console Commands") { ws.execute("help") }
            Divider()
            Button("Install OpenFOAM, Gmsh and Other Tools…") { settingsTab = "tools"; openSettings() }
            Button("Validation Suite") { ws.selection = .validation }
            Divider()
            Button("FluidCraft Website") { NSWorkspace.shared.open(FluidCraftLinks.website) }
            Button("Report an Issue…") { NSWorkspace.shared.open(FluidCraftLinks.issues) }
        }
    }
}

/// The user guide bundled with the app (Contents/Resources/Guide), shown offline.
struct GuideView: View {
    var body: some View {
        if let url = GuideView.guideURL {
            GuideWebView(url: url).frame(minWidth: 720, minHeight: 520)
        } else {
            ContentUnavailableView {
                Label("The guide is not in this build", systemImage: "book.closed")
            } description: {
                Text("It is online at the FluidCraft website.")
            } actions: {
                Button("Open the Website") { NSWorkspace.shared.open(FluidCraftLinks.website) }
            }
        }
    }

    /// In the app bundle; when run from the build folder, the copy in the source tree.
    static var guideURL: URL? {
        let fm = FileManager.default
        if let r = Bundle.main.resourceURL?.appendingPathComponent("Guide/index.html"), fm.fileExists(atPath: r.path) { return r }
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Docs/Guide/index.html").standardized
        return fm.fileExists(atPath: src.path) ? src : nil
    }
}

struct GuideWebView: NSViewRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> WKWebView {
        let w = WKWebView()
        w.navigationDelegate = context.coordinator
        w.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        return w
    }
    func updateNSView(_ nsView: WKWebView, context: Context) {}

    /// Links to the web open in the default browser; the guide itself stays local.
    final class Coordinator: NSObject, WKNavigationDelegate {
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
            if let u = action.request.url, u.scheme == "http" || u.scheme == "https" {
                NSWorkspace.shared.open(u)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
