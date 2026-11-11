import Foundation

func runMeetingProposalsTests() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-meeting-proposals-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store=try Store(path:directory.appendingPathComponent("workspace/SproutRecruit.sqlite").path)
    _ = try store.command("onboarding.save",["name":"Fixture Recruiter","company":"Sprout","timezone":"America/Chicago"])
    try store.put("agents",["id":"proposal-agent","name":"Fixture Agent","email":"agent@example.com","status":"Connected"])
    try store.put("agents",["id":"no-email","name":"Missing Email","status":"Connected"])
    try store.saveMeetingParticipants(["participants":["manager@example.com"],"defaultDurationMinutes":60,"expectedRevision":0])
    func check(_ condition:Bool,_ message:String)throws { if !condition {throw StoreError(message:"Meeting proposal fixture: "+message)} }
    let context=try store.meetingContext(["agentId":"proposal-agent"])
    try check(context["durationMinutes"] as? Int==60 && context["missingFields"] as? [String]==["localDateTime"],"only the unknown meeting date is required")
    let id=UUID().uuidString.lowercased()
    var input:Record=["id":id,"agentId":"proposal-agent","sourceActor":"Leaf","sourceReference":"fixture://requested-meeting","expectedRevision":0]
    _ = try store.command("meetings.propose",input)
    var request=try store.get("meetingProposals",id)
    try check(request["state"] as? String=="needs_details" && (try store.all("meetings").isEmpty),"partial requests cannot submit an event")
    let taskID=request["reviewTaskId"] as! String
    try check(try store.get("tasks",taskID)["completed"] as? Bool==false && store.all("tasks").count==1,"one linked open review task")
    let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=TimeZone(identifier:"UTC");formatter.dateFormat="yyyy-MM-dd'T'HH:mm"
    input["localDateTime"]=formatter.string(from:Date().addingTimeInterval(86400));input["timeZone"]="UTC";input["expectedRevision"]=1
    input["title"]="TEST — reviewed meeting";input["description"]="Reviewed agenda";input["location"]="https://example.com/room"
    _ = try store.command("meetings.propose",input)
    request=try store.get("meetingProposals",id)
    try check(request["state"] as? String=="ready" && (try store.all("tasks").count)==1,"complete details await the same human review")
    var booking:Record=["id":id,"agentId":"proposal-agent","expectedAgentEmail":"agent@example.com","expectedParticipantsRevision":1,"internalParticipants":["manager@example.com"],
        "localDateTime":input["localDateTime"]!,"timeZone":"UTC","durationMinutes":60,"proposalId":id,
        "title":input["title"]!,"description":input["description"]!,"location":input["location"]!]
    let preview=try store.previewMeetingBooking(booking)
    try check((preview["googleEvent"] as? Record)?["description"] as? String=="Reviewed agenda","reviewed invitation details reach the exact event")
    booking["previewToken"]=preview["previewToken"]
    input["expectedRevision"]=2;input["description"]="Changed agenda"
    _ = try store.command("meetings.propose",input)
    var failed=false
    do { _ = try store.prepareMeetingBooking(booking) } catch { failed=true }
    try check(failed && (try store.all("meetings").isEmpty),"edited AI requests invalidate a reviewed preview")
    booking["previewToken"]=try store.previewMeetingBooking(booking)["previewToken"]
    _ = try store.prepareMeetingBooking(booking)
    input["expectedRevision"]=3;input["location"]="A revised location"
    _ = try store.command("meetings.propose",input)
    booking["location"]="A revised location"
    booking["previewToken"]=try store.previewMeetingBooking(booking)["previewToken"]
    _ = try store.prepareMeetingBooking(booking)
    booking["description"]="Agenda adjusted by the human reviewer"
    booking["previewToken"]=try store.previewMeetingBooking(booking)["previewToken"]
    let prepared=try store.prepareMeetingBooking(booking)
    try check(prepared["previousPreviewToken"] != nil,"a never-submitted request can be freshly reviewed with the same booking ID")
    try check(try store.get("tasks",taskID)["completed"] as? Bool==false,"preparing a booking leaves its review task open")
    _ = try store.markMeetingSubmitted(id)
    var event=prepared["googleEvent"] as! Record
    event["status"]="confirmed";event["iCalUID"]="proposal-fixture@google.com"
    _ = try store.applyMeetingBookingResult(["id":id,"event":event])
    try check(try store.get("meetingProposals",id)["state"] as? String=="booked" && store.get("tasks",taskID)["completed"] as? Bool==true,"only verified booking resolves the proposal and review task")
    let activity=try store.get("activities","meeting-booked-"+id)
    try check((activity["body"] as? String ?? "").contains("Agenda adjusted by the human reviewer") && (activity["body"] as? String ?? "").contains("manager@example.com"),"the timeline retains the reviewed details and attendees")
    failed=false
    do { input["expectedRevision"]=4; _ = try store.command("meetings.propose",input) } catch { failed=true }
    try check(failed,"submitted requests cannot be edited into another invitation")
    print("PASS: AI meeting context, missing details, stable review task, proposal revision invalidation, explicit preview and verified-only completion.")
}
