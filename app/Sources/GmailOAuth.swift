import AppKit
import CryptoKit
import Foundation
import Network
import LocalAuthentication
import Security

// Desktop OAuth per Google's native-app guide. The public client ID is app
// configuration; tokens and an optional client secret never enter Store/WebKit.
// https://developers.google.com/identity/protocols/oauth2/native-app
final class GmailOAuth {
    typealias Load = () throws -> Record?
    typealias Save = (Record?) throws -> Void
    typealias Authorize = (String,String,String,@escaping(Result<(code:String,redirectURI:String),Error>)->Void)->Void
    // The native app can persist these bounded stages across WebKit navigation.
    // Never pass URLs, provider text, codes, account addresses or credentials.
    var onEvent: ((String,String?) -> Void)?
    private enum ConnectStage { case idle, authorization, token, profile }
    private var connectStage: ConnectStage = .idle
    private let requiredScopes: Set<String>
    private let client: GmailAPIClient
    private let load: Load
    private let save: Save
    private let run: GmailAPIClient.Run
    private let authorize: Authorize?
    private var pendingConnectReply: ((Result<Record,Error>)->Void)?
    private var browser: GmailOAuthLoopback?
    private var epoch = 0
    private var connecting = false
    private var refreshing = false
    private var refreshWaiters: [(Result<String,Error>) -> Void] = []
    init(workspacePath: String, client: GmailAPIClient = GmailAPIClient(), scopes: Set<String> = [GmailAPIClient.readScope], keychainService: String = "com.sprout-recruit.gmail.oauth") {
        let vault = GmailOAuthKeychain(workspacePath:workspacePath,service:keychainService)
        self.requiredScopes=scopes
        self.client = client
        if keychainService == "com.sprout-recruit.gmail.oauth" { load=vault.load }
        else { let existing=GmailOAuthKeychain(workspacePath:workspacePath);load={
            if let saved=try vault.load(){return saved}
            guard let config=try existing.load() else{return nil}
            var result:Record=[:];for key in ["clientID","clientSecret"]{result[key]=config[key]};return result
        } }
        save = vault.save; run = GmailHTTPTransport.run;authorize=nil
    }
    // Disposable fixtures inject memory storage and HTTP responses; no real
    // Keychain/browser/listener is accessed by those tests.
    init(client: GmailAPIClient, load: @escaping Load, save: @escaping Save, run: @escaping GmailAPIClient.Run, authorize: Authorize? = nil, scopes:Set<String> = [GmailAPIClient.readScope]) {
        self.requiredScopes=scopes;self.client=client;self.load=load;self.save=save;self.run=run;self.authorize=authorize
    }
    func status() throws -> Record {
        guard let value = try load(), let account = (value["accountAddress"] as? String).flatMap(GmailAPIClient.email),
              value["refreshToken"] is String,Set(value["scopes"] as? [String] ?? []) == requiredScopes else { return ["connected":false] }
        return ["connected":true,"accountAddress":account]
    }
    // Native secure-input path only. A partial Keychain entry is configuration,
    // never mailbox authorization; connect() still requires browser consent.
    func configureClientSecret(clientID:String,secret:String) throws {
        try Self.validateClientID(clientID);try Self.validateClientSecret(secret)
        guard !connecting && !refreshing else { throw GmailAPIError(code:"authorization_busy",message:"Finish or cancel the current Gmail connection before changing its configuration.") }
        let existing=try load()
        guard existing?["accessToken"] == nil && existing?["refreshToken"] == nil else {
            throw GmailAPIError(code:"invalid_configuration",message:"Disconnect Gmail before replacing its Desktop client configuration.")
        }
        try save(["clientID":clientID,"clientSecret":secret])
    }
    func clientSecretConfigured(clientID:String) throws -> Bool {
        try Self.validateClientID(clientID)
        guard let saved=try load(),saved["clientID"] as? String == clientID,let secret=saved["clientSecret"] as? String else { return false }
        return (try? Self.validateClientSecret(secret)) != nil
    }
    func connect(clientID: String, clientSecret: String? = nil, completion: @escaping (Result<Record,Error>) -> Void) {
        guard !connecting else { completion(.failure(GmailAPIError(code:"authorization_busy",message:"A Gmail sign-in is already open."))); return }
        do {
            try Self.validateClientID(clientID)
            var resolvedSecret=clientSecret
            if resolvedSecret == nil,let saved=try load(),saved["clientID"] as? String == clientID {
                resolvedSecret=saved["clientSecret"] as? String
            }
            if let resolvedSecret { try Self.validateClientSecret(resolvedSecret) }
            let clientSecret=resolvedSecret
            let verifier=try Self.random(),state=try Self.random()
            finishRefresh(.failure(GmailAPIError(code:"connection_changed",message:"A new Gmail sign-in started.")))
            epoch &+= 1; connecting=true;connectStage = .authorization;pendingConnectReply=completion; let generation=epoch
            onEvent?("authorization.started",nil)
            let complete: (Result<Record,Error>) -> Void = { [weak self] result in
                guard let self,self.epoch==generation,self.connecting else { return }
                self.connecting=false;self.connectStage = .idle;self.pendingConnectReply=nil
                switch result {
                case .success: self.onEvent?("connection.completed",nil)
                case .failure(let error): self.onEvent?("connection.failed",Self.diagnosticCode(error))
                }
                completion(result)
            }
            let authorized: (Result<(code:String,redirectURI:String),Error>)->Void = { [weak self] result in
                guard let self,self.epoch==generation,self.connecting,self.connectStage == .authorization else { return };self.browser=nil
                do {
                    let response=try result.get()
                    self.onEvent?("authorization.received",nil)
                    self.connectStage = .token
                    var form=["client_id":clientID,"code":response.code,"code_verifier":verifier,"redirect_uri":response.redirectURI,"grant_type":"authorization_code"]
                    if let clientSecret { form["client_secret"]=clientSecret }
                    self.onEvent?("token.requested",nil)
                    self.token(form) { result in
                        guard self.epoch==generation,self.connecting,self.connectStage == .token else { return }
                        do {
                            let value=try result.get()
                            self.onEvent?("token.received",nil)
                            let parsed=try Self.tokens(value,previous:nil,requiredScopes:self.requiredScopes)
                            let access=parsed["accessToken"] as! String
                            self.connectStage = .profile
                            self.onEvent?("profile.requested",nil)
                            self.client.profile(token:access) { profileResult in
                                guard self.epoch==generation,self.connecting,self.connectStage == .profile else { return }
                                do {
                                    let profile=try profileResult.get()
                                    self.onEvent?("profile.verified",nil)
                                    var credentials=parsed;credentials["clientID"]=clientID;credentials["accountAddress"]=profile["accountAddress"]
                                    if let clientSecret { credentials["clientSecret"]=clientSecret }
                                    try self.save(credentials)
                                    self.onEvent?("credentials.saved",nil)
                                    complete(.success(["connected":true,"accountAddress":profile["accountAddress"]!,"historyId":profile["historyId"]!]))
                                } catch { complete(.failure(error)) }
                            }
                        } catch { complete(.failure(error)) }
                    }
                } catch { complete(.failure(error)) }
            }
            if let authorize { authorize(clientID,verifier,state,authorized) }
            else { let flow=GmailOAuthLoopback(clientID:clientID,verifier:verifier,state:state,scopes:requiredScopes.sorted());browser=flow;flow.start(authorized) }
        } catch { onEvent?("connection.failed",Self.diagnosticCode(error));completion(.failure(error)) }
    }
    func accessToken(completion: @escaping (Result<String,Error>) -> Void) {
        guard !connecting else { completion(.failure(GmailAPIError(code:"authorization_busy",message:"Finish Gmail sign-in before scanning.")));return }
        do {
            guard let saved=try load(),let refresh=saved["refreshToken"] as? String,!refresh.isEmpty,let clientID=saved["clientID"] as? String,
                  let account=(saved["accountAddress"] as? String).flatMap(GmailAPIClient.email),Set(saved["scopes"] as? [String] ?? [])==requiredScopes else { throw GmailAPIError(code:"authorization_required",message:"Connect your Gmail account to capture correspondence.") }
            if let access=saved["accessToken"] as? String,let expiry=saved["expiresAt"] as? Double,expiry>Date().timeIntervalSince1970+60 { completion(.success(access));return }
            refreshWaiters.append(completion)
            guard !refreshing else { return };refreshing=true
            let generation=epoch
            var form=["client_id":clientID,"refresh_token":refresh,"grant_type":"refresh_token"]
            if let secret=saved["clientSecret"] as? String { form["client_secret"]=secret }
            token(form) { [weak self] result in
                guard let self,self.epoch==generation else { return }
                do {
                    var renewed=try Self.tokens(try result.get(),previous:saved,requiredScopes:self.requiredScopes)
                    renewed["clientID"]=clientID;renewed["accountAddress"]=account
                    if let secret=saved["clientSecret"] { renewed["clientSecret"]=secret }
                    try self.save(renewed);self.finishRefresh(.success(renewed["accessToken"] as! String))
                } catch { self.finishRefresh(.failure(error)) }
            }
        } catch { completion(.failure(error)) }
    }
    func disconnect() throws {
        // Remove credentials first: failure must not report a completed disconnect.
        try save(nil);epoch &+= 1;connecting=false;connectStage = .idle
        let reply=pendingConnectReply;pendingConnectReply=nil
        browser?.cancel();browser=nil
        if reply != nil { onEvent?("connection.failed","authorization_canceled") }
        reply?(.failure(GmailAPIError(code:"authorization_canceled",message:"Gmail sign-in was canceled by disconnect.")))
        finishRefresh(.failure(GmailAPIError(code:"disconnected",message:"Gmail was disconnected on this Mac.")))
    }
    private func finishRefresh(_ result:Result<String,Error>) { refreshing=false;let callbacks=refreshWaiters;refreshWaiters=[];callbacks.forEach{$0(result)} }
    private static func diagnosticCode(_ error:Error) -> String {
        let allowed:Set<String>=["authorization_busy","authorization_canceled","authorization_timed_out","authorization_declined","callback_unavailable","browser_unavailable","invalid_callback","state_mismatch","network_unavailable","invalid_response","request_rejected","authorization_required","access_denied","not_found","rate_limited","provider_unavailable","response_too_large","invalid_token_response","scope_mismatch","keychain_unavailable","invalid_configuration","missing_client_configuration","oauth_client_secret_required","authorization_expired","oauth_client_rejected"]
        guard let code=(error as? GmailAPIError)?.code,allowed.contains(code) else { return "connection_failed" }
        return code
    }
    private func token(_ fields:[String:String], completion:@escaping(Result<Record,Error>)->Void) {
        var request=URLRequest(url:URL(string:"https://oauth2.googleapis.com/token")!)
        request.httpMethod="POST";request.timeoutInterval=25
        request.setValue("application/x-www-form-urlencoded",forHTTPHeaderField:"Content-Type")
        request.setValue("application/json",forHTTPHeaderField:"Accept")
        request.httpBody=Self.form(fields)
        run(request) { result in completion(result.flatMap { data in
            do { guard data.count<=65536,let record=try JSONSerialization.jsonObject(with:data) as? Record else { throw GmailAPIError(code:"invalid_token_response",message:"Google returned an invalid authorization response.") };return .success(record) }
            catch { return .failure(error) }
        }) }
    }
    static func validateClientID(_ value:String) throws {
        guard value.count <= 250,value.range(of:"^[A-Za-z0-9_-]+\\.apps\\.googleusercontent\\.com$",options:.regularExpression) != nil else { throw GmailAPIError(code:"missing_client_configuration",message:"Configure a Google Desktop OAuth client ID before connecting Gmail.") }
    }
    private static func validateClientSecret(_ value:String) throws {
        guard !value.isEmpty,value.utf8.count<=4096,
              !value.unicodeScalars.contains(where:{CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)}) else {
            throw GmailAPIError(code:"invalid_configuration",message:"The Google client configuration secret is invalid. Enter its exact value without spaces or line breaks.")
        }
    }
    static func random() throws -> String {
        var bytes=[UInt8](repeating:0,count:48)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes)==errSecSuccess else { throw GmailAPIError(code:"random_unavailable",message:"Secure Gmail sign-in could not be prepared.") }
        return base64(Data(bytes))
    }
    static func base64(_ data:Data)->String { data.base64EncodedString().replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"") }
    static func authorizationURL(clientID:String,redirectURI:String,verifier:String,state:String,scopes:[String] = [GmailAPIClient.readScope]) throws -> URL {
        try validateClientID(clientID)
        guard (43...128).contains(verifier.count),verifier.range(of:"^[A-Za-z0-9._~-]+$",options:.regularExpression) != nil,state.count>=43,
              let redirect=URLComponents(string:redirectURI),redirect.scheme=="http",redirect.host=="127.0.0.1",redirect.port != nil,redirect.path=="/oauth/callback",redirect.user==nil,redirect.password==nil,redirect.query==nil,redirect.fragment==nil else { throw GmailAPIError(code:"invalid_authorization_request",message:"The Gmail sign-in callback is invalid.") }
        guard !scopes.isEmpty,Set(scopes).isSubset(of:[GmailAPIClient.readScope,"https://www.googleapis.com/auth/calendar.events.owned"]) else {throw GmailAPIError(code:"scope_mismatch",message:"Unsupported Google permission request.")}
        var url=URLComponents(string:"https://accounts.google.com/o/oauth2/v2/auth")!
        let query=["client_id":clientID,"redirect_uri":redirectURI,"response_type":"code","scope":scopes.sorted().joined(separator:" "),"code_challenge":base64(Data(SHA256.hash(data:Data(verifier.utf8)))),"code_challenge_method":"S256","state":state,"access_type":"offline","prompt":"consent select_account"]
        url.queryItems=query.keys.sorted().map{URLQueryItem(name:$0,value:query[$0])};return url.url!
    }
    static func callback(_ request:String,port:UInt16,state:String) throws -> String {
        guard request.utf8.count<=16384,let first=request.components(separatedBy:"\r\n").first else { throw GmailAPIError(code:"invalid_callback",message:"The Gmail sign-in callback is invalid.") }
        let pieces=first.split(separator:" ",omittingEmptySubsequences:false)
        guard pieces.count==3,pieces[0]=="GET",pieces[2]=="HTTP/1.1",pieces[1].hasPrefix("/oauth/callback?"),
              let url=URLComponents(string:"http://127.0.0.1:\(port)"+String(pieces[1])),url.path=="/oauth/callback",url.fragment==nil else { throw GmailAPIError(code:"invalid_callback",message:"The Gmail sign-in callback is invalid.") }
        let lines=request.components(separatedBy:"\r\n").dropFirst()
        let hosts=lines.filter{$0.lowercased().hasPrefix("host:")}.map{String($0.dropFirst(5)).trimmingCharacters(in:.whitespaces)}
        guard hosts==["127.0.0.1:\(port)"] else { throw GmailAPIError(code:"invalid_callback",message:"The Gmail callback host is invalid.") }
        var values:[String:String]=[:]
        for item in url.queryItems ?? [] { guard values[item.name]==nil,let value=item.value else { throw GmailAPIError(code:"invalid_callback",message:"The Gmail callback contains duplicate parameters.") };values[item.name]=value }
        guard values["state"]==state else { throw GmailAPIError(code:"state_mismatch",message:"The Gmail callback did not match this sign-in attempt.") }
        if values["error"] != nil { throw GmailAPIError(code:"authorization_declined",message:"Gmail sign-in was declined or canceled. No account was connected.") }
        guard let code=values["code"],!code.isEmpty,code.count<=8192,!code.contains(where:{$0.isNewline}) else { throw GmailAPIError(code:"invalid_callback",message:"Google returned no authorization code.") }
        return code
    }
    static func form(_ fields:[String:String])->Data {
        let allowed=CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return Data(fields.keys.sorted().map{($0.addingPercentEncoding(withAllowedCharacters:allowed)!)+"="+(fields[$0]!.addingPercentEncoding(withAllowedCharacters:allowed)!)}.joined(separator:"&").utf8)
    }
    static func tokens(_ record:Record,previous:Record?,requiredScopes:Set<String> = [GmailAPIClient.readScope]) throws -> Record {
        guard let access=record["access_token"] as? String,!access.isEmpty,access.count<=16384,!access.contains(where:{$0.isWhitespace}),
              (record["token_type"] as? String)?.lowercased()=="bearer",let lifetime=record["expires_in"] as? NSNumber,CFGetTypeID(lifetime) != CFBooleanGetTypeID(),lifetime.doubleValue>0,lifetime.doubleValue<=86400,
              let refresh=record["refresh_token"] as? String ?? previous?["refreshToken"] as? String,!refresh.isEmpty,refresh.count<=16384 else { throw GmailAPIError(code:"invalid_token_response",message:"Google did not return renewable Gmail authorization. Reconnect with consent.") }
        let scopes=(record["scope"] as? String)?.split(separator:" ").map(String.init) ?? previous?["scopes"] as? [String] ?? []
        guard Set(scopes)==requiredScopes else { throw GmailAPIError(code:"scope_mismatch",message:"Google did not return the exact requested permissions. Reconnect with the intended permissions.") }
        return ["accessToken":access,"refreshToken":refresh,"expiresAt":Date().timeIntervalSince1970+lifetime.doubleValue,"scopes":scopes]
    }
}

private final class GmailOAuthKeychain {
    private let account:String
    private let service:String
    init(workspacePath:String,service:String = "com.sprout-recruit.gmail.oauth") {
        self.service=service
        let path=URL(fileURLWithPath:workspacePath).standardizedFileURL.resolvingSymlinksInPath().path
        account=SHA256.hash(data:Data(path.utf8)).map{String(format:"%02x",$0)}.joined()
    }
    private var query:[String:Any] {
        let context=LAContext();context.interactionNotAllowed=true
        return [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:account,kSecUseAuthenticationContext as String:context]
    }
    func load() throws -> Record? {
        var q=query;q[kSecReturnData as String]=true;q[kSecMatchLimit as String]=kSecMatchLimitOne
        var result:CFTypeRef?;let code=SecItemCopyMatching(q as CFDictionary,&result)
        if code==errSecItemNotFound { return nil }
        guard code==errSecSuccess,let data=result as? Data,data.count<=65536,let value=try JSONSerialization.jsonObject(with:data) as? Record else { throw GmailAPIError(code:"keychain_unavailable",message:"Sprout could not read its Gmail connection from this Mac's Keychain.") };return value
    }
    func save(_ value:Record?) throws {
        guard let value else { let code=SecItemDelete(query as CFDictionary);guard code==errSecSuccess || code==errSecItemNotFound else { throw GmailAPIError(code:"keychain_unavailable",message:"Sprout could not remove its Gmail connection from Keychain.") };return }
        let data=try JSONSerialization.data(withJSONObject:value)
        let attrs:[String:Any]=[kSecValueData as String:data,kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var code=SecItemUpdate(query as CFDictionary,attrs as CFDictionary)
        if code==errSecItemNotFound { var q=query;q.removeValue(forKey:kSecUseAuthenticationContext as String);q.merge(attrs){_,new in new};code=SecItemAdd(q as CFDictionary,nil) }
        guard code==errSecSuccess else { throw GmailAPIError(code:"keychain_unavailable",message:"Sprout could not save its Gmail connection in this Mac's Keychain.") }
    }
}

private final class GmailOAuthLoopback {
    let clientID:String,verifier:String,state:String
    let scopes:[String]
    private var listener:NWListener?
    private var connections:[NWConnection]=[]
    private var callback:((Result<(code:String,redirectURI:String),Error>)->Void)?
    private var timer:DispatchWorkItem?
    init(clientID:String,verifier:String,state:String,scopes:[String]) { self.clientID=clientID;self.verifier=verifier;self.state=state;self.scopes=scopes }
    func start(_ completion:@escaping(Result<(code:String,redirectURI:String),Error>)->Void) {
        callback=completion
        do {
            let parameters=NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host:"127.0.0.1",port:.any)
            let server=try NWListener(using:parameters);listener=server
            server.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            server.stateUpdateHandler = { [weak self] status in
                guard let self else { return }
                switch status {
                case .ready:
                    guard let port=server.port?.rawValue else { self.finish(.failure(GmailAPIError(code:"callback_unavailable",message:"The Gmail callback port is unavailable.")));return }
                    do {
                        let url=try GmailOAuth.authorizationURL(clientID:self.clientID,redirectURI:"http://127.0.0.1:\(port)/oauth/callback",verifier:self.verifier,state:self.state,scopes:self.scopes)
                        guard NSWorkspace.shared.open(url) else { throw GmailAPIError(code:"browser_unavailable",message:"Open your default browser to connect Gmail.") }
                    } catch { self.finish(.failure(error)) }
                case .failed: self.finish(.failure(GmailAPIError(code:"callback_unavailable",message:"The local Gmail callback could not start.")))
                default:break
                }
            }
            let timeout=DispatchWorkItem { [weak self] in self?.finish(.failure(GmailAPIError(code:"authorization_timed_out",message:"Gmail sign-in timed out. Connect again when ready."))) }
            timer=timeout;DispatchQueue.main.asyncAfter(deadline:.now()+180,execute:timeout)
            server.start(queue:.main)
        } catch { finish(.failure(error)) }
    }
    func cancel() { finish(.failure(GmailAPIError(code:"authorization_canceled",message:"Gmail sign-in was canceled."))) }
    private func accept(_ connection:NWConnection) {
        guard connections.count<8 else { connection.cancel();return };connections.append(connection);connection.start(queue:.main)
        var buffer=Data()
        func receive() {
            connection.receive(minimumIncompleteLength:1,maximumLength:16384) { [weak self] data,_,complete,error in
                guard let self,self.callback != nil else { connection.cancel();return }
                if let data { buffer.append(data) }
                guard buffer.count<=16384,error==nil else { connection.cancel();return }
                if let text=String(data:buffer,encoding:.utf8),text.contains("\r\n\r\n"),let port=self.listener?.port?.rawValue {
                    do {
                        let code=try GmailOAuth.callback(text,port:port,state:self.state)
                        let body="Authorization received. Return to Sprout Recruit to finish connecting."
                        let response="HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"+body
                        connection.send(content:Data(response.utf8),completion:.contentProcessed { _ in self.finish(.success((code,"http://127.0.0.1:\(port)/oauth/callback"))) })
                    } catch {
                        connection.cancel()
                        if (error as? GmailAPIError)?.code == "authorization_declined" { self.finish(.failure(error)) }
                    }
                } else if complete { connection.cancel() } else { receive() }
            }
        }
        receive()
        DispatchQueue.main.asyncAfter(deadline:.now()+10) { connection.cancel() }
    }
    private func finish(_ result:Result<(code:String,redirectURI:String),Error>) {
        guard let completion=callback else { return };callback=nil;timer?.cancel();timer=nil
        listener?.cancel();listener=nil;connections.forEach{$0.cancel()};connections=[];completion(result)
    }
}
