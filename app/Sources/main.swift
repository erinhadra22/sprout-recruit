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
    lazy var outbox = OutboxCoordinator(store:store)
    lazy var messagesSync = MessagesSyncCoordinator(store:store)
    lazy var gmailOAuth: GmailOAuth = {
        let auth=GmailOAuth(workspacePath:store.path)
        auth.onCredentialReadReady = { [weak self] in self?.credentialReadReady() }
        auth.onEvent = { [weak self] stage,code in
            guard let self else { return }
            GmailConnectionDiagnostics.record(databasePath:self.store.path,stage:stage,code:code)
        }
        return auth
    }()
    lazy var calendar: CalendarController = {
        let controller = CalendarController(store:store)
        controller.storeAvailable = { [weak self] in self?.storeBusy == false }
        return controller
    }()
    lazy var gmailClient = GmailAPIClient()
    lazy var gmailSync = GmailSyncCoordinator(store:store) { [weak self] request, completion in
        guard let self = self else { completion(.failure(StoreError(message:"Workspace closed."))); return }
        self.gmailOAuth.accessToken { result in
            switch result {
            case .success(let token): self.gmailClient.readSyncPage(request:request,token:token,completion:completion)
            case .failure(let error): completion(.failure(error))
            }
        }
    }
    lazy var replySyncDispatchGate = ReplySyncDispatchGate(
        gmailScan: { [weak self] done in guard let self=self else { done(false);return };self.gmailSync.scan(completion:done) },
        messagesScan: { [weak self] done in guard let self=self else { done(false);return };self.messagesSync.scan(completion:done) },
        gmailStatus: { [weak self] in guard let self=self else { throw StoreError(message:"Workspace closed.") };return try self.gmailSync.status() },
        messagesStatus: { [weak self] in guard let self=self else { throw StoreError(message:"Workspace closed.") };return try self.messagesSync.status() },
        available: { [weak self] in self?.storeBusy == false })
    private func checkRepliesForDispatch(completion:@escaping (Bool)->Void) {
        replySyncDispatchGate.check(completion:completion)
    }
    private var credentialRetryScheduled = false
    private func credentialReadReady() {
        guard !credentialRetryScheduled else { return }
        credentialRetryScheduled = true
        resumeAfterCredentialRead()
    }
    private func resumeAfterCredentialRead() {
        if storeBusy {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { [weak self] in self?.resumeAfterCredentialRead() }
            return
        }
        credentialRetryScheduled = false
        // The coordinator, Store and OAuth state remain on the main queue.
        // This retry reads the completed cache and preserves the saved cursor.
        gmailSync.scan()
        web?.evaluateJavaScript("window.dispatchEvent(new Event('sprout-gmail-sync'))",completionHandler:nil)
    }
    private var gmailConnectionEpoch: UInt64 = 0
    private var gmailConnecting = false
    private func saveGmailConnection(_ connection:Record, epoch:UInt64, reply:@escaping (Any?,String?)->Void) {
        guard epoch == gmailConnectionEpoch else { reply(nil,"Gmail connection was canceled.");return }
        if storeBusy { DispatchQueue.main.asyncAfter(deadline:.now()+0.2) { self.saveGmailConnection(connection,epoch:epoch,reply:reply) };return }
        gmailConnecting = false
        do {
            GmailConnectionDiagnostics.record(databasePath:store.path,stage:"workspace.save.started",code:nil)
            _ = try store.command("gmailSync.connection",["connected":true,"accountAddress":connection["accountAddress"] ?? ""])
            GmailConnectionDiagnostics.record(databasePath:store.path,stage:"connection.completed",code:nil)
            gmailSync.configured();reply(try gmailStatus(),nil)
        }
        catch {
            GmailConnectionDiagnostics.record(databasePath:store.path,stage:"connection.failed",code:"workspace_save_failed")
            reply(nil,error.localizedDescription)
        }
    }
    private func gmailStatus() throws -> Record {
        var status = try gmailSync.status()
        let config = try store.gmailClientConfiguration()
        let clientID=config["clientId"] as? String ?? ""
        status["configuredClientId"] = clientID
        status["clientConfigured"] = !clientID.isEmpty
        status["clientSecretConfigured"] = clientID.isEmpty ? false : try gmailOAuth.clientSecretConfigured(clientID:clientID)
        let auth = try gmailOAuth.status()
        if status["connected"] as? Bool != true {
            for (key,value) in GmailConnectionDiagnostics.status(databasePath:store.path) { status[key]=value }
        }
        if status["connected"] as? Bool == true && (auth["connected"] as? Bool != true || auth["accountAddress"] as? String != status["accountAddress"] as? String) {
            status["status"] = "blocked"; status["lastError"] = "Google authorization is unavailable. Disconnect and reconnect Gmail."
        }
        return status
    }
    private func gmailAction(_ action:String, _ payload:Record, _ reply:@escaping (Any?,String?)->Void) {
        do {
            switch action {
            case "gmailSync.status": reply(try gmailStatus(),nil)
            case "gmailSync.scan":
                guard payload.isEmpty else { throw StoreError(message:"Gmail checks use the saved candidate scope.") }
                gmailSync.scan(); reply(try gmailStatus(),nil)
            case "gmailSync.setClientID":
                _ = try store.command("gmailSync.clientConfiguration",payload)
                GmailConnectionDiagnostics.record(databasePath:store.path,stage:"configuration.saved",code:nil)
                reply(try gmailStatus(),nil)
            case "gmailSync.setClientSecret":
                guard Set(payload.keys)==["confirmed"],payload["confirmed"] as? Bool==true else { throw StoreError(message:"Review Desktop client configuration before saving it.") }
                guard !gmailConnecting else { throw StoreError(message:"Finish the current Google connection before changing its client configuration.") }
                let clientID=try store.gmailClientConfiguration()["clientId"] as? String ?? ""
                try GmailOAuth.validateClientID(clientID)
                let alert=NSAlert()
                alert.messageText="Save Google Desktop client configuration"
                alert.informativeText="Paste the client secret for Sprout Recruit macOS Pilot from your Google Cloud project sproutrecruit. This is the Desktop app’s configuration, not your Gmail password. Sprout saves it only in this workspace’s Mac Keychain entry. It is never sent to the page, saved in the recruiting database, or included in diagnostics. Saving does not connect Gmail or enable history sync."
                let field=NSSecureTextField(frame:NSRect(x:0,y:0,width:520,height:26))
                field.placeholderString="Google Desktop client secret"
                field.setAccessibilityLabel("Google Desktop client secret")
                alert.accessoryView=field
                alert.addButton(withTitle:"Save in Keychain")
                alert.addButton(withTitle:"Cancel")
                alert.beginSheetModal(for:window) { response in
                    defer { field.stringValue="" }
                    guard response == .alertFirstButtonReturn else { reply(nil,"Desktop client configuration was canceled.");return }
                    do {
                        try self.gmailOAuth.configureClientSecret(clientID:clientID,secret:field.stringValue)
                        GmailConnectionDiagnostics.record(databasePath:self.store.path,stage:"configuration.saved",code:nil)
                        reply(try self.gmailStatus(),nil)
                    } catch { reply(nil,error.localizedDescription) }
                }
            case "gmailSync.connect":
                guard Set(payload.keys)==["confirmed"], payload["confirmed"] as? Bool == true else { throw StoreError(message:"Review Gmail read-only access before connecting.") }
                guard !gmailConnecting else { throw StoreError(message:"A Google connection is already in progress.") }
                gmailConnectionEpoch &+= 1;let connectionEpoch = gmailConnectionEpoch
                let config = try store.gmailClientConfiguration()
                guard let clientID=config["clientId"] as? String,!clientID.isEmpty else { throw StoreError(message:"Configure the Google Desktop client ID first.") }
                work({ _,error in
                    if let error=error { reply(nil,error);return }
                    self.gmailConnecting = true
                    self.gmailOAuth.connect(clientID:clientID) { result in
                        do {
                            let connection = try result.get()
                            self.saveGmailConnection(connection,epoch:connectionEpoch,reply:reply)
                        } catch { self.gmailConnecting = false; reply(nil,error.localizedDescription) }
                    }
                }) { try WorkspaceRecovery.snapshot(self.store.path,reason:"before-gmail-connect") }
            case "gmailSync.configure":
                if payload["enabled"] as? Bool == true {
                    work({ _,error in
                        if let error=error { reply(nil,error);return }
                        do { _ = try self.store.command("gmailSync.configure",payload);self.gmailSync.configured();reply(try self.gmailStatus(),nil) }
                        catch { reply(nil,error.localizedDescription) }
                    }) { try WorkspaceRecovery.snapshot(self.store.path,reason:"before-gmail-sync") }
                } else { _ = try store.command("gmailSync.configure",payload);gmailSync.configured();reply(try gmailStatus(),nil) }
            case "gmailSync.rescan":
                _ = try store.command("gmailSync.rescan",payload);gmailSync.configured();reply(try gmailStatus(),nil)
            case "gmailSync.disconnect":
                guard Set(payload.keys)==["confirmed"], payload["confirmed"] as? Bool == true else { throw StoreError(message:"Confirm disconnecting Gmail.") }
                gmailConnectionEpoch &+= 1;gmailConnecting = false;gmailSync.invalidate();try gmailOAuth.disconnect()
                _ = try store.command("gmailSync.connection",["connected":false])
                GmailConnectionDiagnostics.record(databasePath:store.path,stage:"connection.disconnected",code:nil)
                reply(try gmailStatus(),nil)
            default: throw StoreError(message:"Only the native Gmail reader can apply email evidence.")
            }
        } catch { reply(nil,error.localizedDescription) }
    }
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
    private func startupStage(_ event:String,_ details:[String:String]=[:]) {
        StartupDiagnostics.record(databasePath:store.path,event:event,details:details)
    }
    private func openWorkspaceWindow() {
        StartupDiagnostics.record(databasePath:store.path,event:"workspace.open",details:["resources":resources.path],reset:true)
        let config = WKWebViewConfiguration()
        config.userContentController.addScriptMessageHandler(self,contentWorld:.page,name:"sprout")
        config.websiteDataStore = .nonPersistent()
        web = WKWebView(frame:.zero,configuration:config); web.navigationDelegate = self
        startupStage("webview.created")
        web.setValue(false,forKey:"drawsBackground")
        if window == nil { window = NSWindow(contentRect:NSRect(x:0,y:0,width:1400,height:940),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false) }
        window.styleMask=[.titled,.closable,.miniaturizable,.resizable]
        window.setContentSize(NSSize(width:1400,height:940))
        window.title = "Sprout Recruit — Local workspace"
        window.minSize = NSSize(width:1080,height:720)
        window.contentView = web
        communications.window = window
        outbox.storeAvailable = { [weak self] in self?.storeBusy == false }
        gmailSync.storeAvailable = { [weak self] in self?.storeBusy == false }
        gmailSync.onChange = { [weak self] in self?.web?.evaluateJavaScript("window.dispatchEvent(new Event('sprout-gmail-sync'))",completionHandler:nil) }
        messagesSync.storeAvailable = { [weak self] in self?.storeBusy == false }
        messagesSync.onChange = { [weak self] in self?.web?.evaluateJavaScript("window.dispatchEvent(new Event('sprout-messages-sync'))",completionHandler:nil) }
        outbox.beforeDispatch = { [weak self] completion in
            guard let self = self else { completion(false);return }
            self.checkRepliesForDispatch(completion:completion)
        }
        outbox.onChange = { [weak self] in self?.web?.evaluateJavaScript("window.dispatchEvent(new Event('sprout-outbox'))",completionHandler:nil) }
        startupStage("outbox.start.begin")
        do { try outbox.start() } catch { showLoadFailure("The text queue could not recover safely: " + error.localizedDescription) }
        startupStage("outbox.start.end")
        messagesSync.start()
        startupStage("messages.start.end")
        window.center(); window.makeKeyAndOrderFront(nil)
        startupStage("web.load.begin")
        let navigation=web.loadFileURL(resources.appendingPathComponent("index.html"),allowingReadAccessTo:resources)
        startupStage("web.load.requested",["accepted":String(navigation != nil)])
        NSApp.activate(ignoringOtherApps:true)
        gmailSync.start()
        startupStage("gmail.start.end")
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
        startupStage("web.process.terminated")
        showLoadFailure("The display process stopped.")
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        startupStage("web.navigation.failed",["domain":(error as NSError).domain,"code":String((error as NSError).code)]);showLoadFailure(error.localizedDescription)
    }
    func webView(_ webView:WKWebView,didStartProvisionalNavigation navigation:WKNavigation!) { startupStage("web.navigation.started") }
    func webView(_ webView:WKWebView,didCommit navigation:WKNavigation!) { startupStage("web.navigation.committed") }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) { startupStage("web.navigation.finished") }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        startupStage("web.navigation.failed",["domain":(error as NSError).domain,"code":String((error as NSError).code)]);showLoadFailure(error.localizedDescription)
    }
    @objc func about() {
        let alert = NSAlert(); alert.messageText = "Sprout Recruit"; alert.informativeText = "Version 0.9.4 · Interim eligibility and service-area search\nYour recruiting workspace, on your Mac.\nLicense-based intake, sourced profiles, teams and separate production periods. MLS discovery remains unconnected until provider access is verified. Daily scheduling is managed outside this app; no duplicate local scheduler is installed. Existing optional Messages and Gmail connections retain their reviewed settings."; alert.runModal()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url=navigationAction.request.url,
           url.scheme=="https",url.host=="mail.google.com",url.path=="/mail/u/" {
            NSWorkspace.shared.open(url);decisionHandler(.cancel);return
        }
        if navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url, url.scheme == "https",
           url.user == nil, url.password == nil, let host = url.host, !host.isEmpty {
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
        if action.hasPrefix("calendar.") || ["meetings.book","meetings.reconcile","meetings.refresh"].contains(action) {
            // Google consent may remain open for minutes. Only booking actions
            // need the workspace barrier across their provider request.
            let locksWorkspace = action.hasPrefix("meetings.")
            if locksWorkspace { storeBusy=true }
            calendar.handle(action,p) { value,error in
                if locksWorkspace { self.storeBusy=false }
                self.web?.evaluateJavaScript("window.dispatchEvent(new Event('sprout-calendar-sync'))",completionHandler:nil)
                replyHandler(value,error)
            }
            return
        }
        if action.hasPrefix("gmailSync.") { gmailAction(action,p,replyHandler); return }
        if action.hasPrefix("messagesSync.") {
            do {
                switch action {
                case "messagesSync.status": replyHandler(try messagesSync.status(),nil)
                case "messagesSync.scan":
                    guard p.isEmpty else { throw StoreError(message:"Sync uses only the saved candidate scope.") }
                    messagesSync.scan(); replyHandler(try messagesSync.status(),nil)
                case "messagesSync.configure":
                    guard Set(p.keys).isSubset(of:["enabled","confirmed"]), p["enabled"] is Bool else { throw StoreError(message:"Choose whether to enable Messages reply sync.") }
                    if p["enabled"] as? Bool == true {
                        guard p["confirmed"] as? Bool == true else { throw StoreError(message:"Review local Messages access before enabling sync.") }
                        work({ _,error in
                            if let error=error { replyHandler(nil,error);return }
                            do { replyHandler(try self.messagesSync.configure(p),nil) }
                            catch { replyHandler(nil,error.localizedDescription) }
                        }) { try WorkspaceRecovery.snapshot(self.store.path,reason:"before-messages-sync") }
                    } else { replyHandler(try messagesSync.configure(p),nil) }
                case "messagesSync.openPrivacy":
                    guard p.isEmpty, let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"), NSWorkspace.shared.open(url) else { throw StoreError(message:"Open System Settings → Privacy & Security → Full Disk Access.") }
                    replyHandler(["opened":true],nil)
                default: throw StoreError(message:"Only the native Messages reader can save a sync result.")
                }
            } catch { replyHandler(nil,error.localizedDescription) }
            return
        }
        let deferred:Set<String>=["ai.prepare","ai.result","workflow.call","workflow.artifact","workflow.result","sequence.evaluate"]
        guard !deferred.contains(action) else { replyHandler(nil,"This feature is outside the internal pilot.");return }
        if action == "communications.imessageStatus" || action == "outbox.status" {
            do { replyHandler(try store.outboxStatus(),nil) } catch { replyHandler(nil,error.localizedDescription) };return
        }
        if action == "communications.imessageConnect" {
            guard Set(p.keys).isSubset(of:["service"]), p["service"] == nil || p["service"] is String else {
                replyHandler(nil,"Choose iMessage or SMS for this connection.");return
            }
            outbox.connect(service:p["service"] as? String ?? "iMessage",replyHandler);return
        }
        if action == "communications.imessageDisconnect" {
            do { replyHandler(try outbox.disconnect(),nil) } catch { replyHandler(nil,error.localizedDescription) };return
        }
        if action.hasPrefix("outbox."), !["outbox.enqueue","outbox.cancel","outbox.resume","outbox.confirm","outbox.ack"].contains(action) {
            replyHandler(nil,"Only the native queue can claim jobs or record transport outcomes.");return
        }
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
                let data = action == "backup" ? try JSONSerialization.data(withJSONObject:store.snapshot(includePhotos:true),options:[.prettyPrinted,.sortedKeys]) : Data((p["text"] as? String ?? "").utf8)
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
    if args.contains("--imessage-worker") {
        let data=FileHandle.standardInput.readDataToEndOfFile()
        let input=try JSONSerialization.jsonObject(with:data) as? Record ?? [:]
        let result=IMessageWorker.run(input)
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:result));exit(0)
    }
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
