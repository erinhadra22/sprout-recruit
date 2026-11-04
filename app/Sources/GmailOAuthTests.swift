import Foundation

func runGmailOAuthTests() throws {
    func check(_ value:Bool,_ name:String) throws {if !value {throw StoreError(message:"Gmail OAuth fixture: "+name)}}
    let clientID="123-fixture.apps.googleusercontent.com",verifier=String(repeating:"a",count:64),state=String(repeating:"s",count:64)
    let url=try GmailOAuth.authorizationURL(clientID:clientID,redirectURI:"http://127.0.0.1:49152/oauth/callback",verifier:verifier,state:state)
    let q=Dictionary(uniqueKeysWithValues:URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!.map{($0.name,$0.value!)})
    try check(url.host=="accounts.google.com" && q["scope"]==GmailAPIClient.readScope && q["code_challenge_method"]=="S256" && q["access_type"]=="offline","system-browser authorization is minimal read-only PKCE")
    try check(q["code_challenge"]=="_-BU_nrgy23GXDr5th1SCfQ5hR20PQulmXM33xVGaOs","known SHA256 PKCE challenge")
    let request="GET /oauth/callback?state=\(state)&code=fixture%2Bcode HTTP/1.1\r\nHost: 127.0.0.1:49152\r\n\r\n"
    try check(try GmailOAuth.callback(request,port:49152,state:state)=="fixture+code","exact callback and percent-decoded code")
    for bad in [request.replacingOccurrences(of:state,with:"wrong"),request.replacingOccurrences(of:"Host: 127.0.0.1",with:"Host: evil.example"),request.replacingOccurrences(of:"&code=",with:"&state=duplicate&code="),request.replacingOccurrences(of:"GET ",with:"POST "),request.replacingOccurrences(of:"/oauth/callback?",with:"/wrong?")] {
        var rejected=false;do {_=try GmailOAuth.callback(bad,port:49152,state:state)} catch {rejected=true};try check(rejected,"invalid callback rejected")
    }
    let response:Record=["access_token":"access-fixture","refresh_token":"refresh-fixture","expires_in":3600,"token_type":"Bearer","scope":GmailAPIClient.readScope]
    let tokens=try GmailOAuth.tokens(response,previous:nil)
    try check(tokens["refreshToken"] as? String=="refresh-fixture","renewable token accepted")
    for replacement:Record in [["scope":"https://mail.google.com/"],["expires_in":true],["refresh_token":""],["access_token":"unsafe\nvalue"]] {
        var value=response;value.merge(replacement){_,new in new};var rejected=false
        do {_=try GmailOAuth.tokens(value,previous:nil)} catch {rejected=true};try check(rejected,"unexpected token contract rejected")
    }
    var storage:Record?=["clientID":clientID,"accountAddress":"recruiter@example.com","accessToken":"expired-fixture","refreshToken":"refresh-fixture","expiresAt":0.0,"scopes":[GmailAPIClient.readScope]]
    var requests:[URLRequest]=[]
    let api=GmailAPIClient {_,_ in fatalError("No mailbox request expected")}
    let oauth=GmailOAuth(client:api,load:{storage},save:{storage=$0},run:{request,done in
        requests.append(request);done(.success(try! JSONSerialization.data(withJSONObject:["access_token":"renewed-fixture","expires_in":3600,"token_type":"Bearer"])))
    })
    var access:Result<String,Error>?;oauth.accessToken{access=$0}
    try check(try access!.get()=="renewed-fixture","expired token refreshed")
    try check(storage?["refreshToken"] as? String=="refresh-fixture","refresh omission preserves existing credential")
    try check(requests.count==1 && requests[0].url?.absoluteString=="https://oauth2.googleapis.com/token" && requests[0].httpMethod=="POST","refresh uses fixed token endpoint")
    let status=try oauth.status();try check(status["connected"] as? Bool==true && status["accessToken"]==nil && status["refreshToken"]==nil,"status never exposes credentials")
    try oauth.disconnect();try check(storage==nil && (try oauth.status())["connected"] as? Bool==false,"disconnect removes local credentials")
    var authCallback: ((Result<(code:String,redirectURI:String),Error>)->Void)?
    var httpCallbacks: [(Result<Data,Error>)->Void] = []
    var current:Record?=["clientID":clientID,"accountAddress":"old@example.com","accessToken":"expired-fixture","refreshToken":"old-refresh","expiresAt":0.0,"scopes":[GmailAPIClient.readScope]]
    let verifiedClient=GmailAPIClient {_,done in done(.success(try! JSONSerialization.data(withJSONObject:["emailAddress":"new@example.com","historyId":"900"])))}
    let lifecycle=GmailOAuth(client:verifiedClient,load:{current},save:{current=$0},run:{_,done in httpCallbacks.append(done)},authorize:{_,_,_,done in authCallback=done})
    var oldRefreshResults:[Result<String,Error>]=[];lifecycle.accessToken{oldRefreshResults.append($0)}
    var connectResults:[Result<Record,Error>]=[];lifecycle.connect(clientID:clientID){connectResults.append($0)}
    try check(oldRefreshResults.count==1,"new authorization finishes stale refresh waiters")
    authCallback?(.success(("fixture-code","http://127.0.0.1:49152/oauth/callback")))
    var blocked:Error?;lifecycle.connect(clientID:clientID){if case .failure(let error)=$0 {blocked=error}}
    try check((blocked as? GmailAPIError)?.code=="authorization_busy","second connect blocked through exchange and profile")
    httpCallbacks[1](.success(try JSONSerialization.data(withJSONObject:response)))
    try check(connectResults.count==1 && current?["accountAddress"] as? String=="new@example.com","new mailbox saved once")
    httpCallbacks[0](.success(try JSONSerialization.data(withJSONObject:["access_token":"late-old-token","expires_in":3600,"token_type":"Bearer"])))
    try check(current?["accountAddress"] as? String=="new@example.com" && current?["accessToken"] as? String=="access-fixture","late old refresh cannot replace new credentials")
    lifecycle.connect(clientID:clientID){connectResults.append($0)}
    try lifecycle.disconnect();try check(connectResults.count==2 && current==nil,"disconnect finishes pending connect exactly once")
    authCallback?(.success(("late-code","http://127.0.0.1:49152/oauth/callback")))
    try check(connectResults.count==2 && current==nil,"late callback cannot reconnect after disconnect")

    // The browser callback is not a successful connection: wait for the token,
    // verified mailbox and durable credential write, with each stage observable.
    var events:[(String,String?)]=[],saved:Record?,saveCount=0
    var authorization:((Result<(code:String,redirectURI:String),Error>)->Void)?
    var tokenReplies:[(Result<Data,Error>)->Void]=[],profileReplies:[(Result<Data,Error>)->Void]=[]
    let stagedClient=GmailAPIClient { _,done in profileReplies.append(done) }
    let staged=GmailOAuth(client:stagedClient,load:{saved},save:{ saved=$0;saveCount+=1 },run:{ _,done in tokenReplies.append(done) },authorize:{ _,_,_,done in authorization=done })
    staged.onEvent={ events.append(($0,$1)) }
    var stagedResults:[Result<Record,Error>]=[]
    staged.connect(clientID:clientID){stagedResults.append($0)}
    try check(events.map{$0.0}==["authorization.started"] && stagedResults.isEmpty,"starting authorization does not finish connection")
    authorization?(.success(("secret-authorization-code","http://127.0.0.1:49152/oauth/callback")))
    try check(events.map{$0.0}==["authorization.started","authorization.received","token.requested"] && stagedResults.isEmpty && saved==nil,"loopback receipt waits for token exchange")
    authorization?(.success(("duplicate-code","http://127.0.0.1:49152/oauth/callback")))
    try check(tokenReplies.count==1,"duplicate browser callback cannot exchange a code twice")
    let tokenBytes=try JSONSerialization.data(withJSONObject:response)
    tokenReplies[0](.success(tokenBytes))
    try check(stagedResults.isEmpty && saved==nil && events.last?.0=="profile.requested","token response waits for verified mailbox")
    tokenReplies[0](.success(tokenBytes))
    try check(profileReplies.count==1,"duplicate token callback cannot start a second profile request")
    let profileBytes=try JSONSerialization.data(withJSONObject:["emailAddress":"new@example.com","historyId":"900"])
    profileReplies[0](.success(profileBytes));profileReplies[0](.success(profileBytes))
    try check(stagedResults.count==1 && saveCount==1 && saved?["accountAddress"] as? String=="new@example.com","credential persistence and completion happen once after verified profile")
    try check(events.map{$0.0}==["authorization.started","authorization.received","token.requested","token.received","profile.requested","profile.verified","credentials.saved","connection.completed"],"successful connection emits complete bounded stage sequence")
    try check(events.allSatisfy{$0.1==nil},"successful stage diagnostics contain no codes or provider data")

    // Capture failures at each boundary without making a network request or
    // permitting arbitrary provider text/error codes into persistent diagnostics.
    for failureStage in ["authorization","token","profile","save","unknown"] {
        var failureEvents:[(String,String?)]=[],failureResults:[Result<Record,Error>]=[],writes=0
        let safeCode=failureStage=="save" ? "keychain_unavailable" : "network_unavailable"
        let failure=GmailAPIError(code:failureStage=="unknown" ? "secret-code-from-provider" : safeCode,message:"Sensitive provider body with token secret-fixture")
        let failureClient=GmailAPIClient { _,done in done(failureStage=="profile" ? .failure(failure) : .success(profileBytes)) }
        let flow=GmailOAuth(client:failureClient,load:{nil},save:{ _ in writes+=1;if failureStage=="save" {throw failure} },run:{ _,done in done(failureStage=="token" || failureStage=="unknown" ? .failure(failure) : .success(tokenBytes)) },authorize:{ _,_,_,done in done(failureStage=="authorization" ? .failure(failure) : .success(("secret-code","http://127.0.0.1:49152/oauth/callback"))) })
        flow.onEvent={failureEvents.append(($0,$1))};flow.connect(clientID:clientID){failureResults.append($0)}
        try check(failureResults.count==1 && failureEvents.last?.0=="connection.failed","\(failureStage) failure completes once and records a failure stage")
        try check(failureEvents.last?.1==(failureStage=="unknown" ? "connection_failed" : safeCode),"\(failureStage) failure emits only an allowlisted diagnostic code")
        try check(!failureEvents.contains{$0.0=="credentials.saved" || $0.0=="connection.completed"},"\(failureStage) failure cannot claim saved or connected")
        try check(writes==(failureStage=="save" ? 1 : 0),"\(failureStage) failure cannot save unverified credentials")
        try check(!failureEvents.map{$0.0+($0.1 ?? "")}.joined().contains("secret"),"provider text and arbitrary codes do not enter stage diagnostics")
    }
    var configuration:Record?,configurationWrites=0,configurationRequests:[URLRequest]=[]
    var configurationAuthorize:((Result<(code:String,redirectURI:String),Error>)->Void)?
    let configured=GmailOAuth(client:verifiedClient,load:{configuration},save:{configuration=$0;configurationWrites+=1},run:{request,done in configurationRequests.append(request);done(.success(tokenBytes))},authorize:{_,_,_,done in configurationAuthorize=done})
    let fixtureSecret="GOCSPX-fixture-only_123",otherClientID="456-other.apps.googleusercontent.com"
    try configured.configureClientSecret(clientID:clientID,secret:fixtureSecret)
    try check(configurationWrites==1 && configurationRequests.isEmpty && configurationAuthorize==nil,"saving client configuration does not start browser consent or token exchange")
    try check(try (configured.status()["connected"] as? Bool)==false && configured.status()["clientSecret"]==nil,"partial Keychain configuration remains disconnected and secret-free in status")
    try check(try configured.clientSecretConfigured(clientID:clientID) && !configured.clientSecretConfigured(clientID:otherClientID),"configuration indicator is an exact client-ID match")
    var unconnectedAccess:Error?;configured.accessToken{if case .failure(let error)=$0 {unconnectedAccess=error}}
    try check((unconnectedAccess as? GmailAPIError)?.code=="authorization_required" && configurationRequests.isEmpty,"partial configuration does not authorize mailbox access")
    for invalid in [""," "," leading","embedded space","trailing\n","control\0value",String(repeating:"x",count:4097)] {
        var rejected=false;do {try configured.configureClientSecret(clientID:clientID,secret:invalid)} catch {rejected=true}
        try check(rejected && configurationWrites==1 && configuration?["clientSecret"] as? String==fixtureSecret,"invalid secret is rejected without replacing saved configuration")
    }
    var invalidClientRejected=false
    do {try configured.configureClientSecret(clientID:"invalid-client",secret:fixtureSecret)} catch {invalidClientRejected=true}
    try check(invalidClientRejected && configurationWrites==1,"invalid client ID cannot replace configuration")
    var configuredResult:Result<Record,Error>?
    configured.connect(clientID:clientID){configuredResult=$0}
    var busyConfigRejected=false
    do {try configured.configureClientSecret(clientID:otherClientID,secret:"another-fixture")} catch {busyConfigRejected=(error as? GmailAPIError)?.code=="authorization_busy"}
    try check(busyConfigRejected && configurationWrites==1,"in-flight authorization prevents changing its client configuration")
    configurationAuthorize?(.success(("fixture-code","http://127.0.0.1:49152/oauth/callback")))
    func tokenForm(_ request:URLRequest)->[String:String] {
        let body=String(data:request.httpBody ?? Data(),encoding:.utf8) ?? ""
        return Dictionary(uniqueKeysWithValues:(URLComponents(string:"https://fixture.invalid/?"+body)?.queryItems ?? []).map{($0.name,$0.value ?? "")})
    }
    try check(try configuredResult!.get()["connected"] as? Bool==true && tokenForm(configurationRequests[0])["client_secret"]==fixtureSecret,"matching client configuration is supplied only to the token exchange")
    try check(configuration?["clientSecret"] as? String==fixtureSecret && (try configured.status())["clientSecret"]==nil,"saved credentials retain the secret while public status omits it")
    var connectedConfigRejected=false
    do {try configured.configureClientSecret(clientID:clientID,secret:"replacement-fixture")} catch {connectedConfigRejected=true}
    try check(connectedConfigRejected && configuration?["clientSecret"] as? String==fixtureSecret,"connected credentials cannot be overwritten by partial configuration")
    configuration?["expiresAt"]=0.0
    var refreshed:Result<String,Error>?;configured.accessToken{refreshed=$0}
    try check(try refreshed!.get()=="access-fixture" && tokenForm(configurationRequests.last!)["client_secret"]==fixtureSecret && configuration?["clientSecret"] as? String==fixtureSecret,"refresh uses and preserves the same client secret")
    try configured.disconnect()
    try check(configuration==nil && !(try configured.clientSecretConfigured(clientID:clientID)),"disconnect clears both credentials and client configuration")
    try configured.configureClientSecret(clientID:clientID,secret:fixtureSecret)
    configured.connect(clientID:otherClientID){configuredResult=$0}
    configurationAuthorize?(.success(("fixture-other-code","http://127.0.0.1:49152/oauth/callback")))
    try check(tokenForm(configurationRequests.last!)["client_id"]==otherClientID && tokenForm(configurationRequests.last!)["client_secret"]==nil && configuration?["clientSecret"]==nil,"another client never inherits the saved client's secret")
    try configured.disconnect();try configured.configureClientSecret(clientID:clientID,secret:fixtureSecret)
    configured.connect(clientID:clientID,clientSecret:"explicit-fixture-override"){configuredResult=$0}
    configurationAuthorize?(.success(("fixture-override-code","http://127.0.0.1:49152/oauth/callback")))
    try check(tokenForm(configurationRequests.last!)["client_secret"]=="explicit-fixture-override" && configuration?["clientSecret"] as? String=="explicit-fixture-override","explicit native secret takes precedence and persists with its verified credentials")
    print("PASS: Gmail OAuth PKCE, callback validation, diagnostics, lifecycle, scoped secure configuration, minimal permissions, refresh and disconnect with injected storage; no browser, network, Keychain or permission access.")
}
