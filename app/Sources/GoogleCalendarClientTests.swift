import Foundation

func runGoogleCalendarClientTests() throws {
    func check(_ value:Bool,_ message:String)throws{if !value{throw StoreError(message:"Google Calendar client fixture: "+message)}}
    let bookingID="00112233-4455-6677-8899-aabbccddeeff",eventID="sprout00112233445566778899aabbccddeeff",token="fixture-token"
    let start:Record=["dateTime":"2026-11-05T16:00:00Z","timeZone":"America/Chicago"],end:Record=["dateTime":"2026-11-05T16:30:00Z","timeZone":"America/Chicago"]
    let event:Record=["id":eventID,"summary":"Sprout recruiting meeting — Fixture","start":start,"end":end,"attendees":[["email":"agent@example.com"],["email":"manager@example.com"]],"extendedProperties":["private":["sproutBookingID":bookingID,"sproutAgentID":"fixture-agent"]]]
    var provider=event;provider["status"]="confirmed";provider["iCalUID"]="fixture-event@google.com";provider["organizer"]=["email":"recruiter@example.com","self":true]
    let missing=GmailAPIError(code:"not_found",message:"Fixture HTTP 404"),network=GmailAPIError(code:"network_unavailable",message:"Fixture network error"),conflict=GmailAPIError(code:"request_rejected",message:"Fixture HTTP 409"),unauthorized=GmailAPIError(code:"authorization_required",message:"Fixture HTTP 401")
    func bytes(_ value:Record)throws->Data{try JSONSerialization.data(withJSONObject:value,options:.sortedKeys)}
    func run(_ responses:[Result<Data,Error>],event input:Record?=nil,token access:String?=nil,allowInsert:Bool=true)throws->(Result<Record,Error>,[URLRequest]){
        var requests=[URLRequest](),remaining=responses,answer:Result<Record,Error>?
        let client=GoogleCalendarClient{request,completion in requests.append(request);guard !remaining.isEmpty else{completion(.failure(StoreError(message:"Unexpected extra fixture request")));return};completion(remaining.removeFirst())}
        client.ensureEvent(event:input ?? event,token:access ?? token,allowInsert:allowInsert){answer=$0}
        guard let answer=answer else{throw StoreError(message:"Calendar fixture did not complete synchronously")}
        return (answer,requests)
    }
    func fails(_ result:Result<Record,Error>,code:String?=nil)throws{switch result{case .success:throw StoreError(message:"Google Calendar fixture expected rejection");case .failure(let error):if let code=code{try check((error as? GmailAPIError)?.code==code,"expected error "+code)}}}
    try check(GoogleCalendarClient.scopes==Set([GmailAPIClient.readScope,"https://www.googleapis.com/auth/calendar.events.owned"]),"only Gmail identity/read and owned calendar event scopes are requested")
    let exists=try run([.success(bytes(provider))]);_=try exists.0.get()
    try check(exists.1.count==1 && exists.1[0].httpMethod=="GET","existing confirmed event never inserts")
    let read=exists.1[0]
    try check(read.url?.absoluteString=="https://www.googleapis.com/calendar/v3/calendars/primary/events/"+eventID && read.httpBody==nil,"exact primary event GET has no body or side-effect query")
    try check(read.value(forHTTPHeaderField:"Authorization")=="Bearer fixture-token" && read.value(forHTTPHeaderField:"Accept")=="application/json" && read.timeoutInterval==25,"bounded authenticated JSON request")
    let created=try run([.failure(missing),.success(bytes(provider)),.success(bytes(provider))]);_=try created.0.get()
    try check(created.1.map{$0.httpMethod ?? ""}==["GET","POST","GET"],"new event has one insert and independent GET readback")
    let insert=created.1[1]
    try check(insert.url?.absoluteString=="https://www.googleapis.com/calendar/v3/calendars/primary/events?sendUpdates=all" && insert.value(forHTTPHeaderField:"Content-Type")=="application/json","only the fixed primary endpoint sends guest updates")
    let inserted=try JSONSerialization.jsonObject(with:insert.httpBody!) as! Record
    try check(NSDictionary(dictionary:inserted).isEqual(to:event),"exact prepared envelope is submitted, with deterministic id and private booking marker")
    try check(created.1[2].url==created.1[0].url && created.1[2].httpBody==nil,"post-insert reconciliation reads the same event id")
    for outcome:Result<Data,Error> in [.failure(network),.failure(conflict),.success(Data("not-json".utf8))]{
        let recovered=try run([.failure(missing),outcome,.success(bytes(provider))]);_=try recovered.0.get()
        try check(recovered.1.map{$0.httpMethod ?? ""}==["GET","POST","GET"],"uncertain/conflict/malformed insert resolves by one read and never another insert")
    }
    let unknown=try run([.failure(missing),.failure(network),.failure(missing)]);try fails(unknown.0,code:"pending_unknown")
    try check(unknown.1.filter{$0.httpMethod=="POST"}.count==1 && unknown.1.count==3,"unconfirmed submission is pending with one POST maximum")
    let stillUnknown=try run([.failure(missing)],allowInsert:false);try fails(stillUnknown.0,code:"pending_unknown")
    try check(stillUnknown.1.count==1 && stillUnknown.1[0].httpMethod=="GET","persisted prior submission never causes another POST")
    let reconcile=try run([.success(bytes(provider))],allowInsert:false);_=try reconcile.0.get();try check(reconcile.1.count==1,"reconcile-only retry can confirm the existing event")
    for error in [network,unauthorized]{let denied=try run([.failure(error)]);try fails(denied.0,code:error.code);try check(denied.1.count==1,"initial GET failure never inserts")}
    var foreign=provider;foreign["extendedProperties"]=["private":["sproutBookingID":"ffffffff-ffff-ffff-ffff-ffffffffffff"]]
    let rejectedForeign=try run([.success(bytes(foreign))]);try fails(rejectedForeign.0,code:"calendar_identity_mismatch");try check(rejectedForeign.1.count==1,"same id with foreign marker is rejected without a write")
    foreign=provider;foreign["id"]="sproutffffffffffffffffffffffffffffffff";try fails(try run([.success(bytes(foreign))]).0,code:"calendar_identity_mismatch")
    var wrongAgent=provider;wrongAgent["extendedProperties"]=["private":["sproutBookingID":bookingID,"sproutAgentID":"other-agent"]]
    let rejectedAgent=try run([.success(bytes(wrongAgent))]);try fails(rejectedAgent.0,code:"calendar_identity_mismatch");try check(rejectedAgent.1.count==1,"actual two-marker envelope rejects a foreign contact without POST")
    var missingAgent=provider;missingAgent["extendedProperties"]=["private":["sproutBookingID":bookingID]]
    try fails(try run([.success(bytes(missingAgent))]).0,code:"calendar_identity_mismatch")
    var legacy=provider;legacy.removeValue(forKey:"extendedProperties")
    var legacyRequest=event;legacyRequest["extendedProperties"]=["private":["sproutBookingID":bookingID]]
    try fails(try run([.success(bytes(legacy))]).0,code:"calendar_identity_mismatch")
    let legacyOwned=try run([.success(bytes(legacy))],event:legacyRequest);_=try legacyOwned.0.get();try check(legacyOwned.1.count==1,"exact legacy envelope without an expected contact marker plus self-organizer confirms ownership without a write")
    legacy["organizer"]=["email":"someone-else@example.com","self":false];try fails(try run([.success(bytes(legacy))],event:legacyRequest).0,code:"calendar_identity_mismatch")
    for key in ["summary","start","attendees"]{
        var changed=provider
        if key=="summary"{changed[key]="Different meeting"}
        if key=="start"{changed[key]=["dateTime":"2026-11-05T17:00:00Z","timeZone":"America/Chicago"]}
        if key=="attendees"{changed[key]=[["email":"foreign@example.com"],["email":"manager@example.com"]]}
        let held=try run([.success(bytes(changed))]);try fails(held.0,code:"calendar_event_changed");try check(held.1.count==1,"changed "+key+" is not overwritten or reinvited")
    }
    var equivalent=provider;equivalent["start"]=["dateTime":"2026-11-05T10:00:00-06:00","timeZone":"America/Chicago"];equivalent["attendees"]=[["email":"MANAGER@example.com","responseStatus":"accepted"],["email":"agent@example.com","responseStatus":"needsAction"]]
    _=try run([.success(bytes(equivalent))]).0.get()
    var malformedOwnership=provider;malformedOwnership["extendedProperties"]=["private":"not-an-object"]
    try fails(try run([.success(bytes(malformedOwnership))]).0,code:"calendar_identity_mismatch")
    var noMarker=event;noMarker.removeValue(forKey:"extendedProperties")
    let enriched=try run([.failure(missing),.success(bytes(provider)),.success(bytes(provider))],event:noMarker);_=try enriched.0.get()
    let enrichedBody=try JSONSerialization.jsonObject(with:enriched.1[1].httpBody!) as! Record
    try check(((enrichedBody["extendedProperties"] as? Record)?["private"] as? Record)?["sproutBookingID"] as? String==bookingID,"legacy prepared envelope is given its derived private marker before one insert")
    for invalidToken in ["", "bad token", "bad\nheader", "bad\0token",String(repeating:"a",count:16384)]{
        let rejected=try run([],token:invalidToken);try fails(rejected.0,code:"authorization_required");try check(rejected.1.isEmpty,"invalid credential shape makes no request")
    }
    for invalidAgentID in ["",String(repeating:"a",count:201),"bad\0id"]{
        var invalid=event;invalid["extendedProperties"]=["private":["sproutBookingID":bookingID,"sproutAgentID":invalidAgentID]]
        let rejected=try run([],event:invalid);try fails(rejected.0,code:"calendar_invalid_event");try check(rejected.1.isEmpty,"invalid contact marker is rejected before transport")
    }
    for key in ["id","extendedProperties","attendees","end"]{
        var invalid=event
        if key=="id"{invalid[key]="../../other?sendUpdates=all"}
        if key=="extendedProperties"{invalid[key]=["private":["sproutBookingID":"different"]]}
        if key=="attendees"{invalid[key]=[["email":"agent@example.com"],["email":"agent@example.com"]]}
        if key=="end"{invalid[key]=start}
        let rejected=try run([],event:invalid);try fails(rejected.0,code:"calendar_invalid_event");try check(rejected.1.isEmpty,"invalid "+key+" cannot reach a provider endpoint")
    }
    let malformed=try run([.success(Data("[]".utf8))]);try fails(malformed.0,code:"calendar_invalid_response");try check(malformed.1.count==1,"malformed GET response never inserts")
    let oversize=try run([.success(Data(repeating:32,count:1_000_001))]);try fails(oversize.0,code:"calendar_invalid_response")
    var detailed=event
    detailed["description"]="A reviewed agenda"
    detailed["location"]="https://example.com/room"
    var detailedProvider=provider
    detailedProvider["description"]=detailed["description"]
    detailedProvider["location"]=detailed["location"]
    _=try run([.success(bytes(detailedProvider))],event:detailed).0.get()
    let detailedInsert=try run([.failure(missing),.success(bytes(detailedProvider)),.success(bytes(detailedProvider))],event:detailed)
    _=try detailedInsert.0.get()
    let detailedBody=try JSONSerialization.jsonObject(with:detailedInsert.1[1].httpBody!) as! Record
    try check(detailedBody["description"] as? String=="A reviewed agenda" &&
              detailedBody["location"] as? String=="https://example.com/room","the exact reviewed description and location are submitted")
    var wrongLocation=detailedProvider;wrongLocation["location"]="Another room"
    try fails(try run([.success(bytes(wrongLocation))],event:detailed).0,code:"calendar_event_changed")
    detailedProvider["description"]="Changed invitation"
    try fails(try run([.success(bytes(detailedProvider))],event:detailed).0,code:"calendar_event_changed")
    var refreshRequests=[URLRequest]()
    var cancelled:Record?
    let refreshClient=GoogleCalendarClient { request,completion in
        refreshRequests.append(request)
        completion(Result { try bytes(["id":eventID,"status":"cancelled"]) })
    }
    refreshClient.readBookedEvent(id:eventID,token:token) { cancelled=try? $0.get() }
    try check(cancelled?["status"] as? String=="cancelled" && refreshRequests.count==1 &&
              refreshRequests[0].httpMethod=="GET" && refreshRequests[0].url==read.url,
              "refresh reads the exact existing event and accepts a sparse cancellation for local reconciliation")
    refreshClient.readBookedEvent(id:"../../other",token:token) { cancelled=try? $0.get() }
    try check(cancelled==nil && refreshRequests.count==1,"malformed refresh IDs never reach the transport")
    print("PASS: Google Calendar fixed primary endpoints, exact invitations, GET-first idempotency, owned-event readback, uncertain/conflict reconciliation, prior-submission hold and bounded requests; injected transport only, no network.")
}

func runCalendarConnectionTests() throws {
    func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw StoreError(message:"Calendar connection fixture: " + message) }
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sprout-calendar-connect-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store = try Store(path:directory.appendingPathComponent("SproutRecruit.sqlite").path)
    let account = "recruiter@example.com"
    let clientID = "123456-fixture.apps.googleusercontent.com"
    try store.put("settings",["id":"gmail-client-configuration","clientId":clientID])
    _ = try store.command("gmailSync.connection",["connected":true,"accountAddress":account])
    let gmailBefore = try store.get("settings","gmail-sync")
    let profile = try JSONSerialization.data(withJSONObject:["emailAddress":account,"historyId":"900"])
    let tokens = try JSONSerialization.data(withJSONObject:[
        "access_token":"calendar-access","refresh_token":"calendar-refresh","expires_in":3600,
        "token_type":"Bearer","scope":GoogleCalendarClient.scopes.sorted().joined(separator:" ")
    ])
    let pending = GmailAPIError(code:"keychain_read_pending",message:"Fixture cold Keychain")
    var credentialReads = 0
    var calendarCredentials: Record?
    var authorization: ((Result<(code:String,redirectURI:String),Error>)->Void)?
    var authorizationCount = 0
    let oauth = GmailOAuth(
        client:GmailAPIClient { _, done in done(.success(profile)) },
        load:{
            credentialReads += 1
            if credentialReads <= 2 { throw pending }
            return calendarCredentials
        },
        save:{ calendarCredentials = $0 },
        run:{ _, done in done(.success(tokens)) },
        authorize:{ _, _, _, done in authorizationCount += 1; authorization = done },
        scopes:GoogleCalendarClient.scopes)
    let calendar = CalendarController(store:store,oauth:oauth)
    var response: Record?, failure: String?, finished = false
    calendar.handle("calendar.connect",["confirmed":true]) { value, error in
        response = value as? Record
        failure = error
        finished = true
    }
    try check(!finished && authorizationCount == 0,"a cold lookup keeps the confirmed request alive")
    calendar.handle("calendar.connect",["confirmed":true]) { _, error in failure = error }
    try check(failure?.contains("in progress") == true,"duplicate submits cannot open another authorization")
    let deadline = Date().addingTimeInterval(3)
    while authorization == nil && !finished && Date() < deadline {
        RunLoop.main.run(until:Date().addingTimeInterval(0.05))
    }
    try check(authorizationCount == 1 && !finished && credentialReads == 3,"one submit resumes through both cold reads")
    var available = false
    calendar.storeAvailable = { available }
    authorization?(.success(("calendar-code","http://127.0.0.1:49152/oauth/callback")))
    try check(!finished,"provider completion waits for an available workspace")
    available = true
    while !finished && Date() < deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.05)) }
    try check(failure == nil && response?["connected"] as? Bool == true && response?["accountAddress"] as? String == account,"consent returns saved connected metadata")
    try check(credentialReads == 3 && calendarCredentials?["refreshToken"] as? String == "calendar-refresh","confirmation does not reread the cold credential cache")
    let saved = try store.get("settings","google-calendar-connection")
    let gmailAfter = try store.get("settings","gmail-sync")
    try check(saved["connected"] as? Bool == true && saved["accountAddress"] as? String == account,"connection metadata persists in the workspace")
    try check(NSDictionary(dictionary:gmailBefore).isEqual(to:gmailAfter),"Calendar leaves Gmail history sync state intact")
    print("Calendar cold connection tests passed")
}

func runCalendarBookingCredentialTests() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-calendar-booking-credentials-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store=try Store(path:directory.appendingPathComponent("workspace/SproutRecruit.sqlite").path)
    _ = try store.command("onboarding.save",["name":"Fixture","company":"Sprout","timezone":"UTC"])
    try store.put("agents",["id":"credential-agent","name":"Fixture Agent","email":"agent@example.com","status":"Connected"])
    let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=TimeZone(identifier:"UTC");formatter.dateFormat="yyyy-MM-dd'T'HH:mm"
    var payload:Record=["id":UUID().uuidString.lowercased(),"agentId":"credential-agent","expectedAgentEmail":"agent@example.com",
        "expectedParticipantsRevision":0,"internalParticipants":[String](),"localDateTime":formatter.string(from:Date().addingTimeInterval(86400)),
        "timeZone":"UTC","durationMinutes":60]
    payload["previewToken"]=try store.previewMeetingBooking(payload)["previewToken"]
    let saved:Record=["accountAddress":"recruiter@example.com","clientID":"123-fixture.apps.googleusercontent.com",
        "refreshToken":"fixture-refresh","accessToken":"fixture-access","expiresAt":Date().timeIntervalSince1970+3600,
        "scopes":GoogleCalendarClient.scopes.sorted()]
    var loads=0,requests=[String]()
    let pending=GmailAPIError(code:"keychain_read_pending",message:"Fixture warming credentials")
    let oauth=GmailOAuth(client:GmailAPIClient(),load:{
        loads += 1
        if loads==1 || loads==3 { throw pending }
        return saved
    },save:{ _ in },run:{ _,done in done(.failure(StoreError(message:"Unexpected token HTTP"))) },scopes:GoogleCalendarClient.scopes)
    let client=GoogleCalendarClient { request,done in
        requests.append(request.httpMethod ?? "")
        if requests.count==1 {
            done(.failure(GmailAPIError(code:"not_found",message:"Fixture absence")))
            return
        }
        do {
            let meeting=try store.get("meetings",payload["id"] as! String)
            var event=meeting["googleEvent"] as! Record
            event["status"]="confirmed";event["iCalUID"]="credential-fixture@google.com"
            done(.success(try JSONSerialization.data(withJSONObject:event)))
        } catch { done(.failure(error)) }
    }
    let calendar=CalendarController(store:store,oauth:oauth,client:client)
    var finished=false,failure:String?
    calendar.handle("meetings.book",payload) { _,error in finished=true;failure=error }
    guard !finished && requests.isEmpty else { throw StoreError(message:"Cold credentials reached Calendar transport early.") }
    var duplicateRejected=false
    calendar.handle("meetings.book",payload) { _,error in duplicateRejected=error?.contains("in progress")==true }
    guard duplicateRejected else { throw StoreError(message:"Cold booking allowed a duplicate operation.") }
    let deadline=Date().addingTimeInterval(3)
    while !finished && Date()<deadline { RunLoop.main.run(until:Date().addingTimeInterval(0.03)) }
    guard finished,failure==nil,loads==4,requests==["GET","POST","GET"],
          try store.get("agents","credential-agent")["status"] as? String=="Meeting scheduled" else {
        throw StoreError(message:"The same reviewed booking did not resume once through both cold credential checks.")
    }
    print("PASS: cold Calendar status and token reads resume one reviewed booking with one POST and exact saved status.")
}
