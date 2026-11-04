import Foundation

func runGoogleCalendarClientTests() throws {
    func check(_ value:Bool,_ message:String)throws{if !value{throw StoreError(message:"Google Calendar client fixture: "+message)}}
    let bookingID="00112233-4455-6677-8899-aabbccddeeff",eventID="sprout00112233445566778899aabbccddeeff",token="fixture-token"
    let start:Record=["dateTime":"2026-11-05T16:00:00Z","timeZone":"America/Chicago"],end:Record=["dateTime":"2026-11-05T16:30:00Z","timeZone":"America/Chicago"]
    let event:Record=["id":eventID,"summary":"Sprout recruiting meeting — Fixture","start":start,"end":end,"attendees":[["email":"agent@example.com"],["email":"manager@example.com"]],"extendedProperties":["private":["sproutBookingID":bookingID]]]
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
    var legacy=provider;legacy.removeValue(forKey:"extendedProperties")
    let legacyOwned=try run([.success(bytes(legacy))]);_=try legacyOwned.0.get();try check(legacyOwned.1.count==1,"exact legacy envelope plus self-organizer confirms ownership without a write")
    legacy["organizer"]=["email":"someone-else@example.com","self":false];try fails(try run([.success(bytes(legacy))]).0,code:"calendar_identity_mismatch")
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
    print("PASS: Google Calendar fixed primary endpoints, exact invitations, GET-first idempotency, owned-event readback, uncertain/conflict reconciliation, prior-submission hold and bounded requests; injected transport only, no network.")
}
