import Foundation

func runCalendarAuthorizationTests() throws {
    func check(_ ok:Bool,_ message:String) throws {if !ok {throw StoreError(message:"Calendar authorization fixture: "+message)}}
    let scopes=GoogleCalendarClient.scopes
    let url=try GmailOAuth.authorizationURL(clientID:"123-fixture.apps.googleusercontent.com",redirectURI:"http://127.0.0.1:49152/oauth/callback",verifier:String(repeating:"a",count:64),state:String(repeating:"s",count:64),scopes:scopes.sorted())
    let items=URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems!
    let returned=Set(items.first{$0.name=="scope"}!.value!.split(separator:" ").map(String.init))
    try check(returned==scopes && !returned.contains("https://www.googleapis.com/auth/gmail.send"),"Calendar requests owned events and read-only account verification; no mail sending scope")
    var token:Record=["access_token":"fixture","refresh_token":"fixture-refresh","expires_in":3600,"token_type":"Bearer","scope":scopes.sorted().joined(separator:" ")]
    _ = try GmailOAuth.tokens(token,previous:nil,requiredScopes:scopes)
    var rejected=false;do{_ = try GmailOAuth.tokens(token,previous:nil)}catch{rejected=true}
    try check(rejected,"Calendar tokens cannot replace the read-only Gmail connection")
    token["scope"]=GmailAPIClient.readScope
    rejected=false;do{_ = try GmailOAuth.tokens(token,previous:nil,requiredScopes:scopes)}catch{rejected=true}
    try check(rejected,"Read-only Gmail tokens cannot authorize Calendar writes")
    rejected=false;do{_ = try GmailOAuth.authorizationURL(clientID:"123-fixture.apps.googleusercontent.com",redirectURI:"http://127.0.0.1:49152/oauth/callback",verifier:String(repeating:"a",count:64),state:String(repeating:"s",count:64),scopes:["https://mail.google.com/"])}catch{rejected=true}
    try check(rejected,"Broad unrequested scopes rejected")
    print("PASS: Calendar OAuth permission separation and strict scopes; no authorization or network.")
}
