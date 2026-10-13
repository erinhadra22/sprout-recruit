import Cocoa
import WebKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    let store: Store
    let resources: URL
    private var pendingCSVPaths: [String] = []
    private var pendingCSVMappings: [Record] = []
    private var pendingCSVToken: String = ""
    lazy var communications = CommunicationsController(store:store)
    init(store: Store, resources: URL) { self.store = store; self.resources = resources }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle:"About Sprout Recruit",action:#selector(about),keyEquivalent:"").target = self
        appMenu.addItem(withTitle:"Show Workspace",action:#selector(showWorkspace),keyEquivalent:"0").target = self
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle:"Quit Sprout Recruit",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        appItem.submenu = appMenu; menu.addItem(appItem)
        let editItem = NSMenuItem(); editItem.title = "Edit"; let edit = NSMenu(title:"Edit")
        for (title, action, key) in [("Undo","undo:","z"),("Cut","cut:","x"),("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] { edit.addItem(withTitle:title,action:Selector(action),keyEquivalent:key) }
        editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(self,contentWorld:.page,name:"sprout")
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame:.zero,configuration:config); web.navigationDelegate = self
        web.setValue(false,forKey:"drawsBackground")
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1400,height:940),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "Sprout Recruit — Local workspace"
        window.minSize = NSSize(width:1080,height:720)
        window.contentView = web
        communications.window = window
        window.center(); window.makeKeyAndOrderFront(nil)
        web.loadFileURL(resources.appendingPathComponent("index.html"),allowingReadAccessTo:resources)
        NSApp.activate(ignoringOtherApps:true)
    }
    @objc func showWorkspace() {
        guard window != nil else { return }
        NSApp.unhide(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWorkspace()
        return true
    }
    private func showLoadFailure(_ message: String) {
        guard window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Sprout couldn't load the workspace"
        alert.informativeText = message + " Your saved records are still on this Mac. Reloading discards any unsaved form."
        alert.addButton(withTitle:"Reload workspace")
        alert.addButton(withTitle:"Quit")
        alert.beginSheetModal(for:window) { response in
            if response == .alertFirstButtonReturn {
                self.web.loadFileURL(self.resources.appendingPathComponent("index.html"),allowingReadAccessTo:self.resources)
            } else { NSApp.terminate(nil) }
        }
        showWorkspace()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        showLoadFailure("The display process stopped.")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadFailure(error.localizedDescription)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadFailure(error.localizedDescription)
    }
    @objc func about() {
        let alert = NSAlert(); alert.messageText = "Sprout Recruit"; alert.informativeText = "Version 0.4.8 · Local desktop preview\nYour recruiting workspace, on your Mac.\nCSV contacts and sample intelligence. Optional Messages and Telnyx test connections."; alert.runModal()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url, url.scheme == "https",
           url.host?.lowercased() == "www.linkedin.com", url.path.lowercased().hasPrefix("/in/") {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        guard let url = navigationAction.request.url, url.isFileURL, url.standardizedFileURL.path.hasPrefix(resources.standardizedFileURL.path + "/") else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.standardizedFileURL == resources.appendingPathComponent("index.html").standardizedFileURL,
              let request = message.body as? Record, let action = request["action"] as? String else { replyHandler(nil,"Only the bundled app can access local records."); return }
        let p = request["payload"] as? Record ?? [:]
        if action.hasPrefix("communications.") { communications.handle(action,p,reply:replyHandler); return }
        do {
            guard !action.hasPrefix("communication.") else { throw StoreError(message:"Communication outcomes must come from the native adapter or an explicit review.") }
            if action == "csv.import.pick" {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
                panel.allowedContentTypes = [.commaSeparatedText]
                guard panel.runModal() == .OK else { replyHandler(["cancelled":true],nil); return }
                let paths = panel.urls.map(\.path)
                let inspection = try store.inspectGenericImport(["paths":paths])
                pendingCSVPaths = paths; pendingCSVMappings = []; pendingCSVToken = ""
                replyHandler(inspection,nil)
            } else if action == "csv.import.preview" {
                guard !pendingCSVPaths.isEmpty, let mappings = p["mappings"] as? [Record] else {
                    throw StoreError(message:"Choose CSV files and review every mapping first.")
                }
                let preview = try store.previewGenericImport(["paths":pendingCSVPaths,"mappings":mappings])
                pendingCSVMappings = mappings; pendingCSVToken = preview["token"] as? String ?? ""
                replyHandler(preview,nil)
            } else if action == "csv.import.commit" {
                guard !pendingCSVPaths.isEmpty, !pendingCSVMappings.isEmpty,
                      let token = p["token"] as? String, token == pendingCSVToken else {
                    throw StoreError(message:"Choose and review the CSV files again.")
                }
                let result = try store.commitGenericImport(["paths":pendingCSVPaths,"mappings":pendingCSVMappings,"token":token])
                pendingCSVPaths = []; pendingCSVMappings = []; pendingCSVToken = ""
                replyHandler(result,nil)
            } else if action == "context.knowledge.pick" {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
                guard panel.runModal() == .OK, let url = panel.url else { replyHandler(["cancelled":true],nil); return }
                replyHandler(["path":url.path],nil)
            } else if action == "context.knowledge.preview" {
                replyHandler(try LocalKnowledge.preview(p),nil)
            } else if action == "report.export" {
                let report = try (p["id"] as? String).map { try store.get("reports",$0) } ?? store.managerReport(p)
                let panel = NSSavePanel(); panel.nameFieldStringValue = "Sprout-manager-report-\(Store.day()).txt"; panel.allowedContentTypes = [.plainText]
                guard panel.runModal() == .OK, let url = panel.url else { replyHandler(["cancelled":true],nil); return }
                try Data(Store.managerReportText(report).utf8).write(to:url,options:.atomic); replyHandler(["ok":true],nil)
            } else if action == "copy" {
                let text = p["text"] as? String ?? ""
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string)
                replyHandler(["ok":true],nil)
            } else if action == "export" || action == "backup" {
                let panel = NSSavePanel(); panel.canCreateDirectories = true
                panel.nameFieldStringValue = action == "backup" ? "Sprout-backup-\(Store.day()).json" : "Sprout-agents-\(Store.day()).csv"
                panel.allowedContentTypes = [action == "backup" ? .json : .commaSeparatedText]
                guard panel.runModal() == .OK, let url = panel.url else { replyHandler(["cancelled":true],nil); return }
                let data = action == "backup" ? try JSONSerialization.data(withJSONObject:store.snapshot(),options:[.prettyPrinted,.sortedKeys]) : Data((p["text"] as? String ?? "").utf8)
                try data.write(to:url,options:.atomic); replyHandler(["ok":true],nil)
            } else { replyHandler(try store.command(action,p),nil) }
        } catch { replyHandler(nil,error.localizedDescription) }
    }
}

let args = CommandLine.arguments
func valueAfter(_ flag: String) -> String? { guard let i = args.firstIndex(of:flag), i+1 < args.count else { return nil }; return args[i+1] }
let explicitPath = valueAfter("--db") ?? ProcessInfo.processInfo.environment["SPROUT_DATA_PATH"]
do {
    if args.contains("--self-test") { try runTests(); exit(0) }
    let support = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        .appendingPathComponent("Sprout Recruit",isDirectory:true)
    let savedLegacy = UserDefaults.standard.string(forKey:"legacyWorkspacePath")
    let dbPath = try WorkspaceLocation.resolve(explicitPath:explicitPath, bundleURL:Bundle.main.bundleURL,
                                                supportURL:support, savedLegacyPath:savedLegacy)
    let store = try Store(path:dbPath)
    if explicitPath == nil && dbPath != support.appendingPathComponent("SproutRecruit.sqlite").path {
        UserDefaults.standard.set(dbPath,forKey:"legacyWorkspacePath")
    }
    if let action = valueAfter("--command") {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let payload = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with:data) as? Record ?? [:])
        let result = try store.command(action,payload)
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self)); exit(0)
    }
    let app = NSApplication.shared
    let resources = Bundle.main.resourceURL!.appendingPathComponent("Web")
    let delegate = AppDelegate(store:store,resources:resources)
    app.delegate = delegate; app.run()
} catch {
    fputs("Sprout Recruit: \(error.localizedDescription)\n",stderr)
    if !args.contains("--command") && !args.contains("--self-test") { let a=NSAlert();a.messageText="Sprout couldn’t open";a.informativeText=error.localizedDescription;a.runModal() }
    exit(1)
}
