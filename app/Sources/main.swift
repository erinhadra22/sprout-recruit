import Cocoa
import WebKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    var window: NSWindow!
    var web: WKWebView!
    private(set) var store: Store!
    private var startup: (() throws -> Store)?
    private var startupFolder:URL?
    private var selectedWorkspaceFolder:URL?
    let resources: URL
    private let worker = DispatchQueue(label:"com.sprout.workspace",qos:.userInitiated)
    private var storeBusy = false
    private func work(_ reply: @escaping (Any?,String?) -> Void, _ body: @escaping () throws -> Any) {
        storeBusy=true
        worker.async {
            do { let result=try body();DispatchQueue.main.async { self.storeBusy=false;reply(result,nil) } }
            catch { DispatchQueue.main.async { self.storeBusy=false;reply(nil,error.localizedDescription) } }
        }
    }
    private var pendingCSVPaths: [String] = []
    private var pendingCSVMappings: [Record] = []
    private var pendingCSVToken: String = ""
    lazy var communications = CommunicationsController(store:store)
    init(store: Store, resources: URL) { self.store = store; self.resources = resources.standardizedFileURL.resolvingSymlinksInPath() }
    init(resources:URL,workspacePath:String,startup:@escaping () throws -> Store) { self.resources=resources.standardizedFileURL.resolvingSymlinksInPath();self.startup=startup;self.startupFolder=URL(fileURLWithPath:workspacePath).deletingLastPathComponent() }
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
        if let startup=startup {
            window=NSWindow(contentRect:NSRect(x:0,y:0,width:540,height:200),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            window.title="Sprout Recruit — Opening workspace"
            let label=NSTextField(wrappingLabelWithString:"Opening your saved workspace…\n\nIf macOS requests access to your workspace folder, review that prompt. Your records are not being replaced.")
            label.frame=NSRect(x:28,y:75,width:480,height:100);window.contentView?.addSubview(label)
            let access=NSButton(title:"Choose this workspace folder…",target:self,action:#selector(selectWorkspaceAccess))
            access.frame=NSRect(x:28,y:25,width:280,height:32);window.contentView?.addSubview(access)
            window.center();window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            worker.async {
                do { let opened=try startup();DispatchQueue.main.async { self.store=opened;self.openWorkspaceWindow() } }
                catch { DispatchQueue.main.async {
                    let alert=NSAlert();alert.messageText="Sprout couldn’t open the workspace";alert.informativeText=error.localizedDescription
                    alert.addButton(withTitle:"Quit");alert.beginSheetModal(for:self.window) { _ in NSApp.terminate(nil) }
                } }
            }
        } else { openWorkspaceWindow() }
    }
    @objc private func selectWorkspaceAccess() {
        guard store == nil,let expected=startupFolder else { return }
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.allowsMultipleSelection=false;panel.directoryURL=expected
        panel.message="Choose the existing workspace folder to confirm local file access. This does not move, import or replace your records."
        guard panel.runModal() == .OK,let selected=panel.url else { return }
        guard selected.standardizedFileURL.resolvingSymlinksInPath()==expected.standardizedFileURL.resolvingSymlinksInPath() else {
            let alert=NSAlert();alert.messageText="Choose the existing workspace folder";alert.informativeText=expected.path;alert.runModal();return
        }
        _ = selected.startAccessingSecurityScopedResource();selectedWorkspaceFolder=selected
    }
    private func openWorkspaceWindow() {
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(self,contentWorld:.page,name:"sprout")
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame:.zero,configuration:config); web.navigationDelegate = self
        web.setValue(false,forKey:"drawsBackground")
        if window == nil { window = NSWindow(contentRect:NSRect(x:0,y:0,width:1400,height:940),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false) }
        window.styleMask=[.titled,.closable,.miniaturizable,.resizable]
        window.setContentSize(NSSize(width:1400,height:940))
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
        let alert = NSAlert(); alert.messageText = "Sprout Recruit"; alert.informativeText = "Version 0.5.0 · Internal pilot candidate\nYour recruiting workspace, on your Mac.\nLocal contacts, reviewed drafts and workspace recovery. External integrations are a later phase."; alert.runModal()
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
        guard let url = navigationAction.request.url, url.isFileURL, url.standardizedFileURL.resolvingSymlinksInPath().path.hasPrefix(resources.path + "/") else { decisionHandler(.cancel); return }
        decisionHandler(.allow)
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage, replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.standardizedFileURL.resolvingSymlinksInPath() == resources.appendingPathComponent("index.html").standardizedFileURL.resolvingSymlinksInPath(),
              let request = message.body as? Record, let action = request["action"] as? String else { replyHandler(nil,"Only the bundled app can access local records."); return }
        let p = request["payload"] as? Record ?? [:]
        guard !storeBusy else { replyHandler(nil,"A workspace operation is in progress. Please wait.");return }
        let deferred:Set<String>=["ai.prepare","ai.result","workflow.call","workflow.artifact","workflow.result","sequence.evaluate"]
        guard !deferred.contains(action) else { replyHandler(nil,"This feature is outside the internal pilot.");return }
        if action.hasPrefix("communications.") {
            guard ["communications.status","communications.appleMessage","communications.phone","communications.confirm"].contains(action) else { replyHandler(nil,"Provider connections are planned for the next phase.");return }
            storeBusy=true
            communications.handle(action,p) { result,error in self.storeBusy=false;replyHandler(result,error) }
            return
        }
        do {
            guard !action.hasPrefix("communication.") else { throw StoreError(message:"Communication outcomes must come from the native adapter or an explicit review.") }
            if action == "csv.import.pick" {
                let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
                panel.allowedContentTypes = [.commaSeparatedText]
                guard panel.runModal() == .OK else { replyHandler(["cancelled":true],nil); return }
                let paths = panel.urls.map(\.path)
                pendingCSVPaths = paths; pendingCSVMappings = []; pendingCSVToken = ""
                work(replyHandler) { try self.store.inspectGenericImport(["paths":paths]) }
            } else if action == "csv.import.preview" {
                guard !pendingCSVPaths.isEmpty, let mappings = p["mappings"] as? [Record] else {
                    throw StoreError(message:"Choose CSV files and review every mapping first.")
                }
                let paths=pendingCSVPaths
                work({ result,error in
                    if let preview=result as? Record { self.pendingCSVMappings=mappings;self.pendingCSVToken=preview["token"] as? String ?? "" }
                    replyHandler(result,error)
                }) { try self.store.previewGenericImport(["paths":paths,"mappings":mappings]) }
            } else if action == "csv.import.commit" {
                guard !pendingCSVPaths.isEmpty, !pendingCSVMappings.isEmpty,
                      let token = p["token"] as? String, token == pendingCSVToken else {
                    throw StoreError(message:"Choose and review the CSV files again.")
                }
                let paths=pendingCSVPaths,mappings=pendingCSVMappings
                work({ result,error in
                    if error==nil { self.pendingCSVPaths=[];self.pendingCSVMappings=[];self.pendingCSVToken="" }
                    replyHandler(result,error)
                }) { try self.store.commitGenericImport(["paths":paths,"mappings":mappings,"token":token]) }
            } else if action == "recovery.restore.pick" {
                let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true
                panel.message="Choose a local Sprout recovery snapshot. Restoration happens when you reopen the app."
                guard panel.runModal() == .OK,let url=panel.url else { replyHandler(["cancelled":true],nil);return }
                work({ result,error in
                    if let error=error { replyHandler(nil,error);return }
                    let alert=NSAlert();alert.messageText="Restore this workspace on next launch?"
                    alert.informativeText="This replaces your current records and managed attachments with the selected snapshot. Changes made since the snapshot will leave the active workspace. Your complete current workspace will be retained for recovery. Unsaved forms will be discarded. Quit now, then click the Sprout icon to finish restoration."
                    alert.addButton(withTitle:"Cancel");alert.addButton(withTitle:"Restore and quit")
                    if alert.runModal() == .alertSecondButtonReturn {
                        UserDefaults.standard.set(url.path,forKey:"pendingRestoreSnapshot")
                        UserDefaults.standard.set(self.store.path,forKey:"pendingRestoreDatabase")
                        replyHandler(["restartRequired":true],nil);NSApp.terminate(nil)
                    } else { replyHandler(["cancelled":true],nil) }
                }) {
                    let manifest=try WorkspaceRecovery.validate(url)
                    guard manifest["sourceDatabase"] as? String==self.store.path else { throw StoreError(message:"This snapshot belongs to another workspace.") }
                    return manifest
                }
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
            } else { work(replyHandler) { try self.store.command(action,p) } }
        } catch { replyHandler(nil,error.localizedDescription) }
    }
}

let args = CommandLine.arguments
func valueAfter(_ flag: String) -> String? { guard let i = args.firstIndex(of:flag), i+1 < args.count else { return nil }; return args[i+1] }
var workspaceLease: WorkspaceLease?
let explicitPath = valueAfter("--db") ?? ProcessInfo.processInfo.environment["SPROUT_DATA_PATH"]
do {
    if args.contains("--self-test") { try runTests(); exit(0) }
    // Initialize the GUI before opening a protected user-folder workspace so
    // macOS can associate access prompts and startup errors with a real app.
    if args.count == 1 { _ = NSApplication.shared; NSApp.setActivationPolicy(.regular) }
    let support = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
        .appendingPathComponent("Sprout Recruit",isDirectory:true)
    let savedLegacy = UserDefaults.standard.string(forKey:"legacyWorkspacePath")
    let selectedPath = try WorkspaceLocation.resolve(explicitPath:explicitPath, bundleURL:Bundle.main.bundleURL,
                                                supportURL:support, savedLegacyPath:savedLegacy)
    let dbPath=URL(fileURLWithPath:selectedPath).standardizedFileURL.resolvingSymlinksInPath().path
    func printJSON(_ result: Record) throws { print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:.sortedKeys),as:UTF8.self)) }
    if args.contains("--workspace-location") { try printJSON(["sourceDatabase":dbPath]);exit(0) }
    if args.contains("--workspace-compatible") { try printJSON(WorkspaceRecovery.compatibility(dbPath));exit(0) }
    if let source=valueAfter("--backup-workspace") {
        let folder=valueAfter("--backup-root").map{URL(fileURLWithPath:$0)}
        try printJSON(WorkspaceRecovery.snapshot(source,at:folder,reason:valueAfter("--reason") ?? "manual"));exit(0)
    }
    if let source=valueAfter("--migrate-workspace") {
        guard let destination=valueAfter("--to") else { throw StoreError(message:"Specify a new destination with --to.") }
        let sourceLease=try WorkspaceLease(source),destinationLease=try WorkspaceLease(destination)
        try withExtendedLifetime((sourceLease,destinationLease)) {
            try WorkspaceRecovery.recoverInterrupted(source)
            try printJSON(WorkspaceMigration.migrate(source,to:destination))
        }
        exit(0)
    }
    func loadWorkspace() throws -> Store {
    workspaceLease=try WorkspaceLease(dbPath)
    try WorkspaceRecovery.recoverInterrupted(dbPath)
    if let restore=valueAfter("--restore-workspace") { try printJSON(WorkspaceRecovery.restore(URL(fileURLWithPath:restore),to:dbPath));exit(0) }
    if args.count == 1,explicitPath==nil,let restore=UserDefaults.standard.string(forKey:"pendingRestoreSnapshot") {
        do {
            guard UserDefaults.standard.string(forKey:"pendingRestoreDatabase")==dbPath else { throw StoreError(message:"The pending restore belongs to another workspace.") }
            _ = try WorkspaceRecovery.restore(URL(fileURLWithPath:restore),to:dbPath)
            UserDefaults.standard.removeObject(forKey:"pendingRestoreSnapshot");UserDefaults.standard.removeObject(forKey:"pendingRestoreDatabase")
        } catch {
            DispatchQueue.main.sync {
            let alert=NSAlert();alert.messageText="The pending restore could not finish";alert.informativeText=error.localizedDescription+" Your retained workspace has not been discarded."
            alert.addButton(withTitle:"Keep request and quit");alert.addButton(withTitle:"Cancel restore request")
            if alert.runModal() == .alertSecondButtonReturn { UserDefaults.standard.removeObject(forKey:"pendingRestoreSnapshot");UserDefaults.standard.removeObject(forKey:"pendingRestoreDatabase") }
            }
            throw error
        }
    }
    let store = try Store(path:dbPath)
    if explicitPath == nil && dbPath != support.appendingPathComponent("SproutRecruit.sqlite").path {
        UserDefaults.standard.set(dbPath,forKey:"legacyWorkspacePath")
    }
        return store
    }
    if args.count == 1 {
        let app=NSApplication.shared
        let delegate=AppDelegate(resources:Bundle.main.resourceURL!.appendingPathComponent("Web"),workspacePath:dbPath,startup:{
            let store=try loadWorkspace()
            do { try WorkspaceRecovery.daily(dbPath) }
            catch { DispatchQueue.main.sync { let alert=NSAlert();alert.messageText="Daily recovery snapshot unavailable";alert.informativeText=error.localizedDescription;alert.runModal() } }
            return store
        })
        app.delegate=delegate;app.run();exit(0)
    }
    let store=try loadWorkspace()
    if let action = valueAfter("--command") {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let payload = data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with:data) as? Record ?? [:])
        let result = try store.command(action,payload)
        print(String(decoding:try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]),as:UTF8.self)); exit(0)
    }
    // A failed scheduled recovery snapshot is visible; never claim protection that was not created.
    do { try WorkspaceRecovery.daily(dbPath) }
    catch { let a=NSAlert();a.messageText="Daily recovery snapshot unavailable";a.informativeText=error.localizedDescription+" You can retry in Settings → Recovery.";a.runModal() }
    let app = NSApplication.shared
    let resources = Bundle.main.resourceURL!.appendingPathComponent("Web")
    let delegate = AppDelegate(store:store,resources:resources)
    app.delegate = delegate; app.run()
} catch {
    fputs("Sprout Recruit: \(error.localizedDescription)\n",stderr)
    if args.count == 1 { let a=NSAlert();a.messageText="Sprout couldn’t open";a.informativeText=error.localizedDescription;a.runModal() }
    exit(1)
}
