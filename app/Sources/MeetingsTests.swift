import Foundation

func runMeetingsTests() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-meetings-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    let store=try Store(path:directory.appendingPathComponent("workspace/SproutRecruit.sqlite").path)
    _ = try store.command("onboarding.save",["name":"Fixture Recruiter","company":"Sprout Realty","timezone":"America/Chicago"])
    try store.put("agents",["id":"meeting-agent","name":"Fixture Agent","email":"Agent@Example.com","status":"Identified"])
    func check(_ condition: Bool,_ message: String) throws { if !condition { throw StoreError(message:"Meetings fixture failed: "+message) } }
    func rejects(_ message: String,_ body: () throws -> Void) throws { var failed=false;do { try body() } catch { failed=true };try check(failed,message) }
    let empty=try store.meetingParticipantsSettings()
    try check(empty["participants"] as? [String]==[] && empty["defaultDurationMinutes"] as? Int==60,"no guessed internal participants")
    try store.saveMeetingParticipants(["participants":["Manager@Example.com"],"defaultDurationMinutes":45,"expectedRevision":0])
    let settings=try store.meetingParticipantsSettings()
    try check(settings["participants"] as? [String]==["manager@example.com"] && settings["revision"] as? Int==1,"internal participants and duration persist")
    for invalid:Record in [["participants":["a@example.com","A@example.com"],"defaultDurationMinutes":30,"expectedRevision":1],["participants":["Bad\r\nBcc:other@example.com"],"defaultDurationMinutes":30,"expectedRevision":1],["participants":[],"defaultDurationMinutes":true,"expectedRevision":1],["participants":[],"defaultDurationMinutes":30,"expectedRevision":0]] {
        try rejects("invalid or stale settings reject") { try store.saveMeetingParticipants(invalid) }
    }
    let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone=TimeZone(identifier:"UTC");f.dateFormat="yyyy-MM-dd'T'HH:mm"
    let future=f.string(from:Date().addingTimeInterval(86400))
    let p:Record=["id":UUID().uuidString.lowercased(),"agentId":"meeting-agent","expectedAgentEmail":"Agent@Example.com","expectedParticipantsRevision":1,"localDateTime":future,"timeZone":"UTC","durationMinutes":45,"internalParticipants":["manager@example.com"],"linkedConversationID":""]
    let preview=try store.previewMeetingBooking(p)
    try check(preview["attendees"] as? [String]==["agent@example.com","manager@example.com"],"exact contact plus fixed participant emails")
    try check(try store.all("meetings").isEmpty && store.get("agents","meeting-agent")["status"] as? String=="Identified","preview does not update status or create booking")
    var preparedPayload=p;preparedPayload["previewToken"]=preview["previewToken"]
    let prepared=try store.prepareMeetingBooking(preparedPayload),id=prepared["id"] as! String
    try check(prepared["state"] as? String=="prepared" && prepared["bookedAt"]==nil,"prepared event has no claimed success")
    try check(try store.get("agents","meeting-agent")["status"] as? String=="Identified","prepared event does not update contact status")
    let submitted=try store.markMeetingSubmitted(id)
    try check(submitted["state"] as? String=="submitted" && submitted["submittedAt"] as? String != nil,"submission state persists before transport")
    try check(try store.markMeetingSubmitted(id)["submittedAt"] as? String==submitted["submittedAt"] as? String,"repeated submission does not reset attempt identity")
    var changed=preparedPayload;changed["durationMinutes"]=30
    try rejects("same booking ID cannot change envelope") { _ = try store.prepareMeetingBooking(changed) }
    var event=prepared["googleEvent"] as! Record;event["iCalUID"]="fixture-calendar-uid";event["status"]="confirmed";event["htmlLink"]="https://www.google.com/calendar/event?eid=fixture"
    for patch:Record in [["id":"another-event"],["status":"cancelled"],["attendees":[["email":"other@example.com"]]],["start":["dateTime":"not-an-instant","timeZone":"UTC"]]] {
        var wrong=event;for(k,v) in patch { wrong[k]=v }
        try rejects("mismatched provider readback cannot book") { _ = try store.applyMeetingBookingResult(["id":id,"event":wrong]) }
    }
    let booked=try store.applyMeetingBookingResult(["id":id,"event":event])
    try check(booked["state"] as? String=="booked" && booked["status"] as? String=="confirmed" && booked["iCalUID"] as? String=="fixture-calendar-uid" && booked["providerVerifiedAt"] as? String != nil,"exact provider readback records booking evidence")
    try check(try store.get("agents","meeting-agent")["status"] as? String=="Meeting scheduled","only verified event advances status")
    let activityCount=try store.all("activities").count
    let replay=try store.applyMeetingBookingResult(["id":id,"event":event])
    try check(replay["bookedAt"] as? String==booked["bookedAt"] as? String && (try store.all("activities").count)==activityCount,"verified replay preserves booked time and one activity")
    try store.saveMeetingParticipants(["participants":["manager@example.com","additional-person@example.com"],"defaultDurationMinutes":60,"expectedRevision":1])
    try check(try store.get("meetings",id)["attendees"] as? [String]==["agent@example.com","manager@example.com"],"adding an internal person leaves the existing calendar invitation unchanged")
    var stale=p;stale["id"]=UUID().uuidString
    try rejects("old participant form cannot omit added internal person") { _ = try store.previewMeetingBooking(stale) }
    try check(try store.prepareMeetingBooking(preparedPayload)["id"] as? String==id,"submitted/booked replay retains frozen request after defaults change")
    try rejects("future meeting cannot be marked held") { _ = try store.markMeetingHeld(["id":id,"heldAt":Store.now(),"confirmed":true]) }

    var refreshedEvent=event
    refreshedEvent["attendees"]=[["email":"agent@example.com","responseStatus":"accepted"],["email":"manager@example.com"]]
    refreshedEvent["start"]=["dateTime":"2030-01-10T13:00:00Z"]
    refreshedEvent["end"]=["dateTime":"2030-01-10T14:00:00Z"]
    var wrongRefresh=refreshedEvent;wrongRefresh["iCalUID"]="wrong-event"
    try rejects("refresh must match the saved Google UID") { try store.applyCalendarRefresh(id:id,event:wrongRefresh) }
    var missingAttendee=refreshedEvent;missingAttendee["attendees"]=[["email":"different@example.com"]]
    try rejects("refresh must still identify the exact candidate") { try store.applyCalendarRefresh(id:id,event:missingAttendee) }
    try store.applyCalendarRefresh(id:id,event:refreshedEvent)
    let refreshed=try store.get("meetings",id)
    try check(refreshed["agentCalendarResponse"] as? String=="accepted" && refreshed["startsAt"] as? String=="2030-01-10T13:00:00Z" &&
              refreshed["bookedAt"] as? String==booked["bookedAt"] as? String && refreshed["heldAt"]==nil,"readback saves RSVP and reschedule while preserving booking and attendance evidence")
    var declined=refreshedEvent;declined["attendees"]=[["email":"agent@example.com","responseStatus":"declined"],["email":"manager@example.com"]]
    try store.applyCalendarRefresh(id:id,event:declined)
    try check(try store.get("meetings",id)["agentCalendarResponse"] as? String=="declined" &&
              store.get("agents","meeting-agent")["status"] as? String=="Meeting scheduled","declined RSVP is saved while the event remains booked")
    let cancelled:Record=["id":booked["googleEventId"]!,"status":"cancelled"]
    try store.applyCalendarRefresh(id:id,event:cancelled)
    try check(try store.get("agents","meeting-agent")["status"] as? String=="Identified","verified cancellation restores the prior contact status")
    let beforeCancellationReplay=try store.all("activities").count
    try store.applyCalendarRefresh(id:id,event:cancelled)
    try check(try store.all("activities").count==beforeCancellationReplay && store.get("meetings",id)["bookedAt"] as? String==booked["bookedAt"] as? String,"cancellation replay preserves historical booking")
    try store.applyCalendarRefresh(id:id,event:refreshedEvent)
    try check(try store.get("agents","meeting-agent")["status"] as? String=="Meeting scheduled","restored Calendar event reactivates its unchanged stage")
    var advanced=try store.get("agents","meeting-agent");advanced["status"]="Negotiating";try store.put("agents",advanced)
    try store.applyCalendarRefresh(id:id,event:cancelled)
    try check(try store.get("agents","meeting-agent")["status"] as? String=="Negotiating","late cancellation preserves a subsequent contact stage")
    try store.applyCalendarRefresh(id:id,event:refreshedEvent)
    try check(try store.get("agents","meeting-agent")["status"] as? String=="Negotiating","reinstatement cannot overwrite a later contact stage")

    // Exact call linkage is a deliberate selection, never the most recent call.
    try store.put("activities",["id":"connected-call","agentId":"meeting-agent","kind":"interaction","title":"Call — Connected","date":Store.now()])
    try store.put("activities",["id":"no-answer","agentId":"meeting-agent","kind":"interaction","title":"Call — No answer","date":Store.now()])
    var linked=p;linked["id"]=UUID().uuidString;linked["expectedParticipantsRevision"]=2;linked["internalParticipants"]=["manager@example.com","additional-person@example.com"];linked["durationMinutes"]=60;linked["linkedConversationID"]="activity:connected-call"
    let linkedPreview=try store.previewMeetingBooking(linked)
    try check(linkedPreview["linkedConversationID"] as? String=="activity:connected-call","explicit connected call link persists")
    try check(linkedPreview["attendees"] as? [String]==["agent@example.com","manager@example.com","additional-person@example.com"] && linkedPreview["durationMinutes"] as? Int==60,"next booking uses the additional internal person and editable one-hour default")
    linked["linkedConversationID"]="activity:no-answer"
    try rejects("unconnected call cannot claim conversion") { _ = try store.previewMeetingBooking(linked) }
    linked["linkedConversationID"]="workflow:missing"
    try rejects("missing workflow cannot claim conversion") { _ = try store.previewMeetingBooking(linked) }
    try rejects("nonexistent DST time rejects") { _ = try MeetingValidation.localDate("2027-03-14T02:30","America/Chicago") }
    try rejects("ambiguous DST time rejects") { _ = try MeetingValidation.localDate("2027-11-07T01:30","America/Chicago") }

    // Synthetic past provider record exercises explicit attendance confirmation;
    // no elapsed-time heuristic or live calendar operation is involved.
    var past=booked;past["id"]="past-fixture";past["startsAt"]=ISO8601DateFormatter().string(from:Date().addingTimeInterval(-7200));past["endsAt"]=ISO8601DateFormatter().string(from:Date().addingTimeInterval(-3600))
    try store.put("meetings",past)
    let heldAt=ISO8601DateFormatter().string(from:Date().addingTimeInterval(-5400))
    let held=try store.transaction { try store.markMeetingHeld(["id":"past-fixture","heldAt":heldAt,"confirmed":true]) }
    try check(held["heldAt"] as? String==heldAt && held["heldSource"] as? String=="user_confirmed","explicit held timestamp persists")
    try check(try store.get("agents","meeting-agent")["status"] as? String=="Meeting held","held confirmation advances status")
    let heldActivities=try store.all("activities").count
    _ = try store.transaction { try store.markMeetingHeld(["id":"past-fixture","heldAt":heldAt,"confirmed":true]) }
    try check(try store.all("activities").count==heldActivities,"held replay creates no duplicate activity")
    try rejects("held requires explicit confirmation") { _ = try store.markMeetingHeld(["id":"past-fixture","heldAt":heldAt,"confirmed":false]) }
    print("PASS: meeting participant settings, frozen booking/retry, exact provider readback, status/activity gates, call links, DST and explicit held evidence.")
}
