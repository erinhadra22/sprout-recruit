import Foundation
import CoreFoundation

enum MeetingValidation {
    static func email(_ raw: String) throws -> String {
        let value=raw.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        guard value.count<=254,value.range(of:"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$",options:.regularExpression) != nil else { throw StoreError(message:"Use a complete email address without a display name.") }
        return value
    }
    static func participants(_ raw: Any?) throws -> [String] {
        guard let values=raw as? [String],values.count<=20 else { throw StoreError(message:"Use up to 20 internal participant email addresses.") }
        let emails=try values.map(email)
        guard Set(emails).count==emails.count else { throw StoreError(message:"Each meeting participant must have a distinct email address.") }
        return emails
    }
    static func integer(_ value: Any?,_ allowed: ClosedRange<Int>) -> Int? {
        guard let raw=value as? NSNumber,CFGetTypeID(raw) != CFBooleanGetTypeID(),raw.doubleValue==Double(raw.intValue),allowed.contains(raw.intValue) else { return nil }
        return raw.intValue
    }
    static func instant(_ text: String) -> Date? {
        let f=ISO8601DateFormatter();if let date=f.date(from:text) { return date }
        f.formatOptions=[.withInternetDateTime,.withFractionalSeconds];return f.date(from:text)
    }
    static func localDate(_ text: String,_ zoneName: String) throws -> Date {
        guard text.range(of:"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}$",options:.regularExpression) != nil,
              let zone=TimeZone(identifier:zoneName) else { throw StoreError(message:"Choose a valid meeting date, time and time zone.") }
        let f=DateFormatter();f.locale=Locale(identifier:"en_US_POSIX");f.timeZone=zone;f.dateFormat="yyyy-MM-dd'T'HH:mm";f.isLenient=false
        guard let date=f.date(from:text),f.string(from:date)==text else { throw StoreError(message:"That local meeting time does not exist in this time zone.") }
        for minutes in [-120,-90,-60,-30,30,60,90,120] where f.string(from:date.addingTimeInterval(Double(minutes*60)))==text {
            throw StoreError(message:"That local time repeats during a clock change. Choose an unambiguous time.")
        }
        return date
    }
}

extension Store {
    func meetingParticipantsSettings() throws -> Record {
        try all("settings").first { $0["id"] as? String == "meeting-participants" } ?? ["id":"meeting-participants","participants":[String](),"defaultDurationMinutes":60,"revision":0]
    }
    func saveMeetingParticipants(_ p: Record) throws {
        guard Set(p.keys)==["participants","defaultDurationMinutes","expectedRevision"],
              let duration=MeetingValidation.integer(p["defaultDurationMinutes"],5...240),
              let expected=MeetingValidation.integer(p["expectedRevision"],0...Int.max) else { throw StoreError(message:"Enter participant emails, a duration from 5 to 240 minutes and the current settings revision.") }
        let participants=try MeetingValidation.participants(p["participants"]),old=try meetingParticipantsSettings()
        guard expected==old["revision"] as? Int else { throw StoreError(message:"Meeting participants changed. Reload before saving.") }
        try put("settings",["id":"meeting-participants","participants":participants,"defaultDurationMinutes":duration,"revision":expected+1,"updatedAt":Store.now()])
    }
    private func meetingConversation(_ key: String,_ aid: String) throws -> Record {
        guard !key.isEmpty else { return [:] }
        if key.hasPrefix("workflow:") {
            let id=String(key.dropFirst(9)),call=try get("workflows",id)
            guard call["agentId"] as? String==aid,call["outcome"] as? String=="connected",let callID=call["callId"] as? String,!callID.isEmpty else { throw StoreError(message:"Link a call explicitly logged as Connected for this contact.") }
            var result:Record=["linkedConversationID":key,"sourceCallId":callID]
            if let activityID=call["interactionId"] as? String { result["sourceActivityId"]=activityID }
            return result
        }
        if key.hasPrefix("activity:") {
            let id=String(key.dropFirst(9)),activity=try get("activities",id)
            guard activity["agentId"] as? String==aid,activity["kind"] as? String=="interaction",activity["title"] as? String=="Call — Connected" else { throw StoreError(message:"Link a call explicitly logged as Connected for this contact.") }
            return ["linkedConversationID":key,"sourceActivityId":id]
        }
        throw StoreError(message:"Choose a verified connected conversation or leave the call link empty.")
    }
    private func meetingBookingPlan(_ p: Record) throws -> Record {
        let allowed:Set<String>=["id","agentId","expectedAgentEmail","expectedParticipantsRevision","localDateTime","timeZone","durationMinutes","internalParticipants","linkedConversationID","previewToken"]
        guard Set(p.keys).isSubset(of:allowed),let rawID=p["id"] as? String,let uuid=UUID(uuidString:rawID),
              let aid=p["agentId"] as? String,let expectedEmail=p["expectedAgentEmail"] as? String,
              let expectedRevision=MeetingValidation.integer(p["expectedParticipantsRevision"],0...Int.max),
              let local=p["localDateTime"] as? String,let zone=p["timeZone"] as? String,
              let duration=MeetingValidation.integer(p["durationMinutes"],5...240) else { throw StoreError(message:"Complete the meeting date, time, duration, contact and participants.") }
        let agent=try get("agents",aid),email=try MeetingValidation.email(agent["email"] as? String ?? ""),settings=try meetingParticipantsSettings()
        guard try email==MeetingValidation.email(expectedEmail),expectedRevision==settings["revision"] as? Int else { throw StoreError(message:"The contact email or fixed participants changed. Reopen the meeting form.") }
        let internalEmails=try MeetingValidation.participants(p["internalParticipants"])
        guard !internalEmails.contains(email) else { throw StoreError(message:"The agent email must not also be listed as an internal participant.") }
        // Staff defaults are fixed per current settings. Changing them belongs in
        // Settings, so a stale booking form cannot silently omit an invitee.
        guard internalEmails==settings["participants"] as? [String] else { throw StoreError(message:"Update fixed internal participants in Settings, then reopen this meeting.") }
        let start=try MeetingValidation.localDate(local,zone)
        guard start>Date() else { throw StoreError(message:"Choose a future meeting time.") }
        let end=start.addingTimeInterval(Double(duration*60)),iso=ISO8601DateFormatter(),id=uuid.uuidString.lowercased(),eventID="sprout"+id.replacingOccurrences(of:"-",with:"")
        let name=agent["name"] as? String ?? "Contact",attendees=[email]+internalEmails
        let title="Sprout recruiting meeting — "+name
        var record:Record=["id":id,"agentId":aid,"agentEmail":email,"agentName":name,"priorStatus":agent["status"] as? String ?? "","state":"prepared","source":"google_calendar","googleEventId":eventID,
            "startsAt":iso.string(from:start),"endsAt":iso.string(from:end),"localDateTime":local,"timeZone":zone,"durationMinutes":duration,
            "attendees":attendees,"internalParticipants":internalEmails,"participantsRevision":expectedRevision,"title":title]
        for (key,value) in try meetingConversation(p["linkedConversationID"] as? String ?? "",aid) { record[key]=value }
        let token=CourtedCSV.hash(try JSONSerialization.data(withJSONObject:record,options:.sortedKeys));record["previewToken"]=token
        record["googleEvent"]=["id":eventID,"summary":title,"start":["dateTime":record["startsAt"]!,"timeZone":zone],"end":["dateTime":record["endsAt"]!,"timeZone":zone],"attendees":attendees.map{["email":$0]},"extendedProperties":["private":["sproutBookingID":id,"sproutAgentID":aid]]]
        return record
    }
    func previewMeetingBooking(_ p: Record) throws -> Record { try meetingBookingPlan(p) }
    func prepareMeetingBooking(_ p: Record) throws -> Record {
        if let raw=p["id"] as? String,let uuid=UUID(uuidString:raw),let old=try all("meetings").first(where:{$0["id"] as? String==uuid.uuidString.lowercased()}),["submitted","booked"].contains(old["state"] as? String ?? "") {
            let submitted=old["requestPayload"] as? Record ?? [:],incoming=p.filter { $0.key != "previewToken" }
            guard p["previewToken"] as? String==old["previewToken"] as? String,
                  try JSONSerialization.data(withJSONObject:submitted,options:.sortedKeys)==JSONSerialization.data(withJSONObject:incoming,options:.sortedKeys) else { throw StoreError(message:"This booking ID belongs to a different frozen request. Reconcile the saved event instead.") }
            return old
        }
        let plan=try meetingBookingPlan(p)
        guard p["previewToken"] as? String==plan["previewToken"] as? String else { throw StoreError(message:"Preview this exact meeting before booking it.") }
        let id=plan["id"] as! String
        if let old=try all("meetings").first(where:{$0["id"] as? String==id}) {
            guard old["previewToken"] as? String==plan["previewToken"] as? String else { throw StoreError(message:"This booking ID already belongs to a different meeting. Reconcile it before retrying.") }
            return old
        }
        _ = try consistentBackup(label:"before-meeting-booking")
        return try transaction {
            let locked=try meetingBookingPlan(p)
            guard locked["previewToken"] as? String==plan["previewToken"] as? String else { throw StoreError(message:"The meeting details changed during backup. Preview again.") }
            var saved=locked;saved["createdAt"]=Store.now();saved["requestPayload"]=p.filter { $0.key != "previewToken" };try put("meetings",saved);return saved
        }
    }
    func markMeetingSubmitted(_ id: String) throws -> Record {
        let old=try get("meetings",id)
        if ["submitted","booked"].contains(old["state"] as? String ?? "") { return old }
        guard old["state"] as? String=="prepared",let payload=old["requestPayload"] as? Record else { throw StoreError(message:"This meeting is not ready for submission.") }
        let current=try meetingBookingPlan(payload)
        guard current["previewToken"] as? String==old["previewToken"] as? String else { throw StoreError(message:"The meeting changed before submission. Reopen the form before sending invitations.") }
        _ = try consistentBackup(label:"before-meeting-submission")
        return try transaction {
            var meeting=try get("meetings",id)
            guard meeting["state"] as? String=="prepared" else { return meeting }
            let latest=try meetingBookingPlan(payload)
            guard latest["previewToken"] as? String==meeting["previewToken"] as? String else { throw StoreError(message:"The meeting changed during submission backup. Preview again.") }
            meeting["state"]="submitted";meeting["submittedAt"]=Store.now();try put("meetings",meeting);return meeting
        }
    }
    // Called only by the trusted native calendar controller after provider readback.
    // Never route this method directly to the WebView command bridge.
    func applyMeetingBookingResult(_ p: Record) throws -> Record {
        guard let id=p["id"] as? String,let event=p["event"] as? Record else { throw StoreError(message:"A verified Google Calendar event is required.") }
        let old=try get("meetings",id)
        guard let eventID=event["id"] as? String,eventID==old["googleEventId"] as? String,
              let uid=event["iCalUID"] as? String,!uid.isEmpty,event["status"] as? String=="confirmed",
              let start=event["start"] as? Record,let end=event["end"] as? Record,
              let startString=start["dateTime"] as? String,let endString=end["dateTime"] as? String,
              MeetingValidation.instant(startString)==MeetingValidation.instant(old["startsAt"] as? String ?? ""),
              MeetingValidation.instant(endString)==MeetingValidation.instant(old["endsAt"] as? String ?? ""),
              start["timeZone"] as? String==old["timeZone"] as? String,end["timeZone"] as? String==old["timeZone"] as? String,
              let rawAttendees=event["attendees"] as? [Record],rawAttendees.count==(old["attendees"] as? [String])?.count else { throw StoreError(message:"Google Calendar readback does not match the prepared meeting. Keep the booking pending and reconcile the event ID.") }
        let attendees=try rawAttendees.map { try MeetingValidation.email($0["email"] as? String ?? "") }
        guard Set(attendees)==Set(old["attendees"] as? [String] ?? []),Set(attendees).count==attendees.count else { throw StoreError(message:"Google Calendar attendee readback does not match this meeting.") }
        if old["state"] as? String=="booked" {
            guard old["iCalUID"] as? String==uid else { throw StoreError(message:"The calendar event identity changed. Reconcile it before retrying.") };return old
        }
        _ = try consistentBackup(label:"before-meeting-confirmation")
        return try transaction {
            var record=try get("meetings",id),agent=try get("agents",record["agentId"] as! String)
            guard try MeetingValidation.email(agent["email"] as? String ?? "")==record["agentEmail"] as? String else { throw StoreError(message:"The contact email changed while booking. Reconcile the saved calendar event.") }
            guard agent["status"] as? String==record["priorStatus"] as? String || agent["status"] as? String=="Meeting scheduled" else { throw StoreError(message:"The contact status changed while booking. Reconcile the saved calendar event before changing it.") }
            let now=Store.now();record["state"]="booked";record["status"]="confirmed";record["iCalUID"]=uid;record["bookedAt"]=now;record["providerVerifiedAt"]=now;record["googleCalendarEvent"]=event
            if let link=event["htmlLink"] as? String { record["googleHtmlLink"]=link }
            try put("meetings",record)
            agent["status"]="Meeting scheduled";agent["statusAt"]=now;try put("agents",agent)
            try put("activities",["id":"meeting-booked-"+id,"agentId":record["agentId"]!,"meetingId":id,"kind":"interaction","title":"Meeting — Booked","date":now,"createdAt":now,"recordedAt":now,"author":try operatorName(),"body":"Google Calendar event confirmed for \(record["startsAt"] as? String ?? "") (\(record["timeZone"] as? String ?? "")).","provider":"google_calendar","providerEventId":eventID,"pinned":false])
            return record
        }
    }
    func markMeetingHeld(_ p: Record) throws -> Record {
        let keys=Set(p.keys)
        guard (keys==["id","heldAt","confirmed"] || keys==["id","localDateTime","timeZone","confirmed"]),p["confirmed"] as? Bool==true,let id=p["id"] as? String else { throw StoreError(message:"Confirm when this meeting actually took place, today or earlier.") }
        let date:Date
        if let held=p["heldAt"] as? String,let parsed=MeetingValidation.instant(held) { date=parsed }
        else if let local=p["localDateTime"] as? String,let zone=p["timeZone"] as? String { date=try MeetingValidation.localDate(local,zone) }
        else { throw StoreError(message:"Choose the actual meeting date, time and time zone.") }
        guard date<=Date() else { throw StoreError(message:"A meeting held time cannot be in the future.") }
        let held=ISO8601DateFormatter().string(from:date)
        var record=try get("meetings",id)
        guard record["state"] as? String=="booked",record["providerVerifiedAt"] as? String != nil,let start=MeetingValidation.instant(record["startsAt"] as? String ?? ""),date>=start else { throw StoreError(message:"Only a verified booked meeting can be marked held, at or after its scheduled start.") }
        if let old=record["heldAt"] as? String { guard MeetingValidation.instant(old)==date else { throw StoreError(message:"This meeting already has a different held time.") };return record }
        record["heldAt"]=held;record["heldRecordedAt"]=Store.now();record["heldSource"]="user_confirmed"
        if let zone=p["timeZone"] as? String { record["heldTimeZone"]=zone;record["heldLocalDateTime"]=p["localDateTime"] }
        try put("meetings",record)
        var agent=try get("agents",record["agentId"] as! String);agent["status"]="Meeting held";agent["statusAt"]=Store.now();try put("agents",agent)
        try put("activities",["id":"meeting-held-"+id,"agentId":record["agentId"]!,"meetingId":id,"kind":"interaction","title":"Meeting — Held","date":held,"createdAt":Store.now(),"recordedAt":Store.now(),"author":try operatorName(),"body":"Meeting attendance explicitly confirmed by the recruiter.","confirmationSource":"user_confirmed","pinned":false])
        return record
    }
}
