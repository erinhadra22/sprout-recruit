import Foundation
import CoreFoundation

extension Store {
    static func weeklyReportWindow(at now:Date = Date(),timeZone identifier:String) throws -> Record {
        guard let zone=TimeZone(identifier:identifier) else{throw StoreError(message:"Choose a valid weekly-report time zone.")}
        var calendar=Calendar(identifier:.gregorian);calendar.timeZone=zone;calendar.firstWeekday=2;calendar.minimumDaysInFirstWeek=4
        guard let current=calendar.dateInterval(of:.weekOfYear,for:now),let from=calendar.date(byAdding:.day,value:-7,to:current.start),let through=calendar.date(byAdding:.day,value:-1,to:current.start) else{throw StoreError(message:"Cannot calculate the previous completed report week.")}
        let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=zone;formatter.dateFormat="yyyy-MM-dd"
        return ["fromDate":formatter.string(from:from),"toDate":formatter.string(from:through),"timeZone":identifier,"includeSamples":false,"title":"Weekly recruiting activity"]
    }
    static func weeklyReportDefaultPlan() -> Record {
        ["id":"weekly-report-delivery","recipients":["cody@sprouthomes.com"],"weekday":1,"time":"09:00","timeZone":"America/Chicago","subject":"Weekly recruiting activity","revision":0,"enabled":false,"deliveryStatus":"awaiting_activation"]
    }
    func weeklyReportDeliveryPlan() throws -> Record {
        try all("settings").first{$0["id"] as? String=="weekly-report-delivery"} ?? Store.weeklyReportDefaultPlan()
    }
    static func weeklyReportAutomationMatches(_ plan:Record,_ automation:Record) -> Bool {
        guard automation["enabled"] as? Bool==true,automation["status"] as? String=="active",
              automation["mechanism"] as? String=="codex_heartbeat",
              let recipients=plan["recipients"] as? [String],recipients.count==1,
              automation["recipient"] as? String==recipients[0],
              let planRevision=plan["revision"] as? Int,planRevision>0,
              automation["planRevision"] as? Int==planRevision,
              automation["weekday"] as? Int==plan["weekday"] as? Int,
              automation["time"] as? String==plan["time"] as? String,
              automation["timeZone"] as? String==plan["timeZone"] as? String,
              let id=automation["automationId"] as? String,!id.isEmpty else{return false}
        return true
    }
    func saveWeeklyReportAutomation(_ p:Record) throws {
        guard Set(p.keys)==["automationId","planRevision","enabled"],
              let id=p["automationId"] as? String,!id.isEmpty,id.count<=200,!id.contains("\n"),!id.contains("\r"),
              let revision=p["planRevision"] as? Int,revision>0,(p["planRevision"] as? NSNumber).map{CFGetTypeID($0) != CFBooleanGetTypeID()} == true,
              let boolean=p["enabled"] as? NSNumber,CFGetTypeID(boolean)==CFBooleanGetTypeID() else {
            throw StoreError(message:"Save a verified weekly-report automation ID and its exact delivery-plan revision.")
        }
        let plan=try weeklyReportDeliveryPlan()
        guard plan["revision"] as? Int==revision,let recipients=plan["recipients"] as? [String],recipients.count==1 else {
            throw StoreError(message:"The weekly delivery plan changed or has no single verified recipient. Reconcile the schedule before activating it.")
        }
        let old=try all("settings").first{$0["id"] as? String=="weekly-report-automation"}
        var record:Record=["id":"weekly-report-automation","automationId":id,"enabled":boolean.boolValue,"status":boolean.boolValue ? "active":"paused","recipient":recipients[0],"weekday":plan["weekday"] ?? 1,"time":plan["time"] ?? "09:00","timeZone":plan["timeZone"] ?? "America/Chicago","planRevision":revision,"mechanism":"codex_heartbeat","updatedAt":Store.now()]
        if old?["automationId"] as? String==id,old?["planRevision"] as? Int==revision {
            for key in ["lastSentAt","lastError","lastSentProviderMessageId","lastSentWeekFrom","lastSentWeekTo"]{if let value=old?[key]{record[key]=value}}
        }
        try put("settings",record)
    }

    // A provider message ID records an already-completed send. This command has
    // no transport and never sends or retries email. The calling Store command
    // owns the consistent backup and transaction around these two saved records.
    func recordWeeklyReportDelivery(_ p:Record) throws {
        let keys:Set<String>=["fromDate","toDate","recipient","subject","bodySHA256","planRevision","automationId","sentAt","providerMessageId"]
        guard Set(p.keys)==keys,
              let from=p["fromDate"] as? String,let to=p["toDate"] as? String,Store.parseDay(from) != nil,Store.parseDay(to) != nil,
              let rawRecipient=p["recipient"] as? String,let subject=p["subject"] as? String,!subject.contains("\n"),!subject.contains("\r"),subject.count<=200,
              let hash=p["bodySHA256"] as? String,hash.range(of:"^[a-fA-F0-9]{64}$",options:.regularExpression) != nil,
              let revision=p["planRevision"] as? Int,revision>0,(p["planRevision"] as? NSNumber).map{CFGetTypeID($0) != CFBooleanGetTypeID()} == true,
              let automationID=p["automationId"] as? String,!automationID.isEmpty,automationID.count<=200,
              let sentAt=p["sentAt"] as? String,let providerID=p["providerMessageId"] as? String,providerID.range(of:"^[A-Za-z0-9_-]{1,200}$",options:.regularExpression) != nil else {
            throw StoreError(message:"Record the verified provider message ID, exact weekly window, recipient, body hash, send time and active plan revision.")
        }
        let recipient=rawRecipient.trimmingCharacters(in:.whitespacesAndNewlines).lowercased(),id="weekly-report-delivery-receipt:"+from+":"+to
        let core:Record=["fromDate":from,"toDate":to,"recipient":recipient,"subject":subject,"bodySHA256":hash.lowercased(),"planRevision":revision,"automationId":automationID,"sentAt":sentAt,"providerMessageId":providerID]
        let settings=try all("settings")
        if let old=settings.first(where:{$0["id"] as? String==id}) {
            var prior:Record=[:];for key in keys{if let value=old[key]{prior[key]=value}}
            guard NSDictionary(dictionary:core).isEqual(to:prior) else{throw StoreError(message:"This report week already has a different send receipt. Reconcile that exact provider message; do not send it again.")}
            return
        }
        guard !settings.contains(where:{($0["id"] as? String ?? "").hasPrefix("weekly-report-delivery-receipt:") && $0["providerMessageId"] as? String==providerID}) else {throw StoreError(message:"This provider message already belongs to another report week.")}
        let plan=try weeklyReportDeliveryPlan()
        guard var automation=settings.first(where:{$0["id"] as? String=="weekly-report-automation"}),Store.weeklyReportAutomationMatches(plan,automation),
              automation["automationId"] as? String==automationID,automation["planRevision"] as? Int==revision,
              automation["recipient"] as? String==recipient else {throw StoreError(message:"The saved automation does not match this recipient and plan revision. Reconcile the actual send before recording it.")}
        let parser=ISO8601DateFormatter();parser.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let plain=ISO8601DateFormatter()
        guard let sent=parser.date(from:sentAt) ?? plain.date(from:sentAt),sent<=Date().addingTimeInterval(300),let zone=plan["timeZone"] as? String else{throw StoreError(message:"Use the actual provider send time, with a time zone, not a future timestamp.")}
        let window=try Store.weeklyReportWindow(at:sent,timeZone:zone)
        guard window["fromDate"] as? String==from,window["toDate"] as? String==to,
              subject==(plan["subject"] as? String ?? "Weekly recruiting activity")+" · "+from+"–"+to else {throw StoreError(message:"The receipt window and subject must match the previous completed week in the saved delivery plan.")}
        var receipt=core;receipt["id"]=id;receipt["provider"]="gmail";receipt["confirmationSource"]="provider_message_id";receipt["state"]="sent_history_recorded";receipt["recordedAt"]=Store.now();receipt["timeZone"]=zone
        automation["lastSentAt"]=sentAt;automation["lastSentProviderMessageId"]=providerID;automation["lastSentWeekFrom"]=from;automation["lastSentWeekTo"]=to;automation.removeValue(forKey:"lastError");automation["updatedAt"]=Store.now()
        try put("settings",receipt);try put("settings",automation)
    }

    // The sending adapter consumes this aggregate-only payload. It contains no
    // contact names, addresses, message bodies, notes or detailed event ledger.
    static func weeklyReportEmailContent(_ report:Record,plan:Record) throws -> Record {
        guard let filters=report["filters"] as? Record,filters["includeSamples"] as? Bool==false,
              let from=filters["fromDate"] as? String,let to=filters["toDate"] as? String,
              let zone=filters["timeZone"] as? String,let recipients=plan["recipients"] as? [String],!recipients.isEmpty else {
            throw StoreError(message:"Use a real-contact report and a saved weekly-report recipient before preparing delivery.")
        }
        let metrics=report["metrics"] as? Record ?? [:],rate=(report["rates"] as? Record)?["conversationToMeeting"] as? Record ?? [:]
        let percent=(rate["percent"] as? Double).map{String(format:"%.1f%%",$0)} ?? "Unavailable — insufficient verified linkage"
        var lines=["Recruiting activity: \(from) through \(to) (\(zone))","Generated: \(report["generatedAt"] ?? "Unknown")",""]
        for (key,label) in [("calls","Calls logged"),("connectedCalls","Conversations explicitly connected"),("emails","Outbound emails logged"),("messages","Outbound texts logged"),("appointmentsBooked","Appointments booked"),("meetingsHeld","Meetings held"),("convertedConversations","Conversations linked to a booked appointment")] {
            lines.append("\(label): \(metrics[key] ?? 0)")
        }
        lines += ["Conversation to appointment conversion: \(rate["numerator"] ?? 0) / \(rate["denominator"] ?? 0) (\(percent))", "", "Coverage: recorded activity in the local Sprout workspace. Manual/provider calls, imported texts/emails and verified calendar bookings only; older, unconnected and out-of-app history may be missing. This is recorded conversion, not a complete causal response rate. Each converted conversation requires an exact call-to-booking link. A completed task or calendar event does not prove a conversation or held meeting. Missing linkage does not become a zero conversion.","", "Counts exclude drafts, uncertain sends, samples and test contacts. Sent history does not prove delivery. Contact details, message bodies, notes and the individual activity ledger are omitted."]
        let subject=(plan["subject"] as? String ?? "Weekly recruiting activity")+" · "+from+"–"+to
        return ["recipients":recipients,"subject":subject,"body":lines.joined(separator:"\n"),"fromDate":from,"toDate":to,"reportGeneratedAt":report["generatedAt"] ?? ""]
    }

    // Saving a delivery plan records intent only. It cannot grant sending rights,
    // expand the read-only Gmail scope, or create an unattended scheduler.
    func saveWeeklyReportDeliveryPlan(_ p: Record) throws {
        guard Set(p.keys)==["recipients","weekday","time","timeZone","subject","expectedRevision"],
              let raw=p["recipients"] as? [String],raw.count<=10,
              let weekday=p["weekday"] as? Int,(1...7).contains(weekday),(p["weekday"] as? NSNumber).map{CFGetTypeID($0) != CFBooleanGetTypeID()} == true,
              let time=p["time"] as? String,time.range(of:"^([01][0-9]|2[0-3]):[0-5][0-9]$",options:.regularExpression) != nil,
              let zone=p["timeZone"] as? String,TimeZone.knownTimeZoneIdentifiers.contains(zone),
              let subject=p["subject"] as? String,!subject.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              subject.count<=150,!subject.contains("\n"),!subject.contains("\r"),
              let expected=p["expectedRevision"] as? Int,expected>=0,(p["expectedRevision"] as? NSNumber).map{CFGetTypeID($0) != CFBooleanGetTypeID()} == true else {
            throw StoreError(message:"Enter recipients, weekday, local time, time zone and a subject for the weekly report delivery plan.")
        }
        let recipients=raw.map{$0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()}
        guard Set(recipients).count==recipients.count,recipients.allSatisfy({$0.count<=254 && $0.range(of:"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?(?:\\.[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?)+$",options:.regularExpression) != nil}) else {
            throw StoreError(message:"Use up to ten distinct email addresses without display names.")
        }
        let old=try all("settings").first{$0["id"] as? String=="weekly-report-delivery"},revision=old?["revision"] as? Int ?? 0
        guard revision==expected else { throw StoreError(message:"The report delivery plan changed. Reload before saving.") }
        if let old,old["recipients"] as? [String]==recipients,old["weekday"] as? Int==weekday,old["time"] as? String==time,old["timeZone"] as? String==zone,old["subject"] as? String==subject.trimmingCharacters(in:.whitespacesAndNewlines){return}
        let record:Record=["id":"weekly-report-delivery","schemaVersion":1,"revision":revision+1,"recipients":recipients,"weekday":weekday,"time":time,"timeZone":zone,"subject":subject.trimmingCharacters(in:.whitespacesAndNewlines),"window":"previous_completed_monday_sunday","content":"aggregate_recruiting_activity","includeSamples":false,"includeContactDetails":false,"includeMessageBodies":false,"enabled":false,"deliveryStatus":"awaiting_activation","createdAt":old?["createdAt"] ?? Store.now(),"updatedAt":Store.now()]
        try put("settings",record)
    }
}

func runWeeklyReportDeliveryPlanTests() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-weekly-reports-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:directory)}
    let path=directory.appendingPathComponent("fixture.sqlite").path
    let iso=ISO8601DateFormatter()
    for (stamp,from,to) in [("2026-11-04T15:00:00Z","2026-10-26","2026-11-01"),("2026-11-02T14:00:00Z","2026-10-26","2026-11-01"),("2026-11-02T04:30:00Z","2026-10-19","2026-10-25"),("2024-03-04T14:00:00Z","2024-02-26","2024-03-03")] {
        let window=try Store.weeklyReportWindow(at:iso.date(from:stamp)!,timeZone:"America/Chicago")
        guard window["fromDate"] as? String==from,window["toDate"] as? String==to else{throw StoreError(message:"Weekly reporting calendar window must follow the saved zone across DST and midnight.")}
    }
    var store:Store?=try Store(path:path,seed:false)
    var p:Record=["recipients":["Manager@Example.com"],"weekday":1,"time":"08:00","timeZone":"America/Chicago","subject":"Weekly recruiting activity","expectedRevision":0]
    try store!.saveWeeklyReportDeliveryPlan(p)
    let record=try store!.get("settings","weekly-report-delivery")
    guard record["enabled"] as? Bool==false,record["deliveryStatus"] as? String=="awaiting_activation",record["recipients"] as? [String]==["manager@example.com"],record["revision"] as? Int==1 else {throw StoreError(message:"Weekly delivery plan must stay disabled and retain validated values.")}
    func fails(_ change:Record) throws {
        var invalid=p;invalid["expectedRevision"]=1
        for (key,value) in change{invalid[key]=value}
        do {try store!.saveWeeklyReportDeliveryPlan(invalid)} catch{return}
        throw StoreError(message:"Weekly delivery plan accepted an invalid payload.")
    }
    for change:Record in [["recipients":["manager@example.com\r\nBcc:other@example.com"]],["recipients":["a@example.com","A@example.com"]],["time":"24:00"],["time":"8:00"],["weekday":8],["weekday":true],["timeZone":"Invalid/Zone"],["subject":"Hello\nBCC"],["enabled":true],["expectedRevision":true]] {try fails(change)}
    do {try store!.saveWeeklyReportDeliveryPlan(p);throw StoreError(message:"Stale delivery plan revision accepted.")}catch let error as StoreError {guard error.message.contains("changed") else{throw error}}
    store=nil;store=try Store(path:path,seed:false)
    guard try store!.get("settings","weekly-report-delivery")["revision"] as? Int==1 else {throw StoreError(message:"Weekly delivery plan did not persist.")}
    try store!.saveWeeklyReportAutomation(["automationId":"fixture-heartbeat","planRevision":1,"enabled":true])
    let automation=try store!.get("settings","weekly-report-automation")
    guard Store.weeklyReportAutomationMatches(record,automation) else{throw StoreError(message:"Saved automation must match its exact plan.")}
    var changedPlan=record;changedPlan["time"]="09:00"
    guard !Store.weeklyReportAutomationMatches(changedPlan,automation) else{throw StoreError(message:"Schedule must stop matching a changed delivery plan.")}
    p["expectedRevision"]=1;try store!.saveWeeklyReportDeliveryPlan(p)
    guard try store!.get("settings","weekly-report-delivery")["revision"] as? Int==1 else{throw StoreError(message:"An unchanged plan must preserve its active schedule revision.")}
    p["recipients"]=[];p["expectedRevision"]=1
    try store!.saveWeeklyReportDeliveryPlan(p)
    let edited=try store!.get("settings","weekly-report-delivery")
    guard !Store.weeklyReportAutomationMatches(edited,automation) else{throw StoreError(message:"Changing the recipient must invalidate automatic delivery.")}
    try runWeeklyReportDeliveryReceiptTests()
    print("PASS: weekly report plans validate addresses/schedule, persist, reject stale or unsafe fields, and bind automation to the exact saved revision")
}

func runWeeklyReportDeliveryReceiptTests() throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-weekly-delivery-receipts-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:directory)}
    let path=directory.appendingPathComponent("fixture.sqlite").path
    var store:Store?=try Store(path:path,seed:false)
    try store!.saveWeeklyReportDeliveryPlan(["recipients":["cody@sprouthomes.com"],"weekday":1,"time":"09:00","timeZone":"America/Chicago","subject":"Weekly recruiting activity","expectedRevision":0])
    try store!.saveWeeklyReportAutomation(["automationId":"fixture-heartbeat","planRevision":1,"enabled":true])
    let now=Store.now(),window=try Store.weeklyReportWindow(timeZone:"America/Chicago"),from=window["fromDate"] as! String,to=window["toDate"] as! String
    let receipt:Record=["fromDate":from,"toDate":to,"recipient":"cody@sprouthomes.com","subject":"Weekly recruiting activity · "+from+"–"+to,"bodySHA256":String(repeating:"a",count:64),"planRevision":1,"automationId":"fixture-heartbeat","sentAt":now,"providerMessageId":"fixturegmailmessage1"]
    try store!.transaction {try store!.recordWeeklyReportDelivery(receipt)}
    try store!.transaction {try store!.recordWeeklyReportDelivery(receipt)}
    func fails(_ change:Record) throws {
        var value=receipt;for(key,item) in change{value[key]=item}
        do {try store!.transaction {try store!.recordWeeklyReportDelivery(value)}}catch{return}
        throw StoreError(message:"Weekly report receipt accepted conflicting or invalid evidence.")
    }
    for change:Record in [["providerMessageId":"different-message"],["bodySHA256":String(repeating:"b",count:64)],["recipient":"other@example.com"],["subject":"Changed"],["sentAt":"2039-01-01T00:00:00Z"],["body":"Never store full message bodies here"],["planRevision":true],["providerMessageId":""],["bodySHA256":"not-a-hash"]] {try fails(change)}
    let rows=try store!.all("settings").filter{($0["id"] as? String ?? "").hasPrefix("weekly-report-delivery-receipt:")}
    guard rows.count==1,rows.first?["providerMessageId"] as? String=="fixturegmailmessage1",rows.first?["body"]==nil,try store!.get("settings","weekly-report-automation")["lastSentAt"] as? String==now else{throw StoreError(message:"One verified receipt must update the automation without storing full message bodies.")}
    store=nil;store=try Store(path:path,seed:false)
    guard try store!.get("settings","weekly-report-delivery-receipt:"+from+":"+to)["providerMessageId"] as? String=="fixturegmailmessage1" else{throw StoreError(message:"Weekly receipt did not survive reopen.")}
    print("PASS: weekly provider send receipts retain a stable week/provider ID, exact recipient/body hash and last-send time, replay once, reject conflicts and never store bodies")
}
