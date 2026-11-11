import Foundation

/// Only the native controller can authorize Calendar or submit invitations.
/// WebKit receives connection metadata and saved records, never credentials.
final class CalendarController {
    private let store: Store
    private let oauth: GmailOAuth
    private let client: GoogleCalendarClient
    private var busy = false
    var storeAvailable: () -> Bool = { true }
    init(store:Store, oauth: GmailOAuth? = nil) {
        self.store=store
        self.oauth=oauth ?? GmailOAuth(workspacePath:store.path,scopes:GoogleCalendarClient.scopes,keychainService:"com.sprout-recruit.calendar.oauth")
        client=GoogleCalendarClient()
    }
    func status() throws -> Record {
        var result=try oauth.status()
        let config=try store.gmailClientConfiguration()
        result["clientConfigured"] = !(config["clientId"] as? String ?? "").isEmpty
        result["requestedScopes"] = GoogleCalendarClient.scopes.sorted()
        result["busy"] = busy
        return result
    }
    private func saveConnection(_ value:Record) throws {
        _ = try store.consistentBackup(label:"before-calendar-connection")
        try store.transaction {
            try store.put("settings",["id":"google-calendar-connection","connected":value["connected"] as? Bool ?? false,"accountAddress":value["accountAddress"] as? String ?? "","updatedAt":Store.now()])
        }
    }
    func handle(_ action:String,_ payload:Record,_ reply:@escaping(Any?,String?)->Void) {
        do {
            if action=="calendar.status" { reply(try status(),nil);return }
            guard !busy else {throw StoreError(message:"A Calendar operation is in progress. Wait for its result.")}
            if action=="calendar.disconnect" {
                guard payload["confirmed"] as? Bool==true else {throw StoreError(message:"Confirm disconnecting Calendar.")}
                try oauth.disconnect()
                let connection: Record = ["connected":false]
                try saveConnection(connection)
                reply(connection,nil)
                return
            }
            if action=="calendar.connect" {
                guard Set(payload.keys)==["confirmed"],payload["confirmed"] as? Bool==true else {throw StoreError(message:"Review Calendar event creation and attendee invitation access before connecting.")}
                guard let clientID=try store.gmailClientConfiguration()["clientId"] as? String,!clientID.isEmpty else {throw StoreError(message:"Configure the Google Desktop client in Gmail integrations first.")}
                _ = try store.consistentBackup(label:"before-calendar-authorization")
                busy=true
                connect(clientID:clientID,deadline:DispatchTime.now() + 10,reply:reply)
                return
            }
            guard ["meetings.book","meetings.reconcile","meetings.refresh"].contains(action) else {throw StoreError(message:"Unsupported Calendar action.")}
            let connection=try oauth.status()
            guard connection["connected"] as? Bool==true else {throw StoreError(message:"Connect Google Calendar in Settings → Meetings before working with a calendar event. No event was submitted.")}
            let meeting:Record
            if action != "meetings.book" {
                guard Set(payload.keys)==["id"],let id=payload["id"] as? String else {throw StoreError(message:"Select the saved booking to check.")}
                meeting=try store.get("meetings",id)
            } else {meeting=try store.prepareMeetingBooking(payload)}
            if action=="meetings.refresh" || (action=="meetings.reconcile" && meeting["state"] as? String=="booked") {
                try refresh(meeting,account:connection["accountAddress"] as? String ?? "",reply)
                return
            }
            if meeting["state"] as? String=="booked" {reply(try store.snapshot(),nil);return}
            guard let id=meeting["id"] as? String,let event=meeting["googleEvent"] as? Record else {throw StoreError(message:"This saved booking has no frozen Calendar request.")}
            let allowInsert=action=="meetings.book" && meeting["state"] as? String=="prepared"
            busy=true
            oauth.accessToken { tokenResult in
                do {
                    let token=try tokenResult.get()
                    if allowInsert {_ = try self.store.markMeetingSubmitted(id)}
                    self.client.ensureEvent(event:event,token:token,allowInsert:allowInsert) { result in
                        self.busy=false
                        do {
                            _ = try self.store.applyMeetingBookingResult(["id":id,"event":try result.get(),"calendarAccountAddress":connection["accountAddress"] as? String ?? ""])
                            reply(try self.store.snapshot(),nil)
                        } catch {reply(nil,error.localizedDescription+" Check this saved booking before creating another invitation.")}
                    }
                } catch {self.busy=false;reply(nil,error.localizedDescription)}
            }
        } catch {reply(nil,error.localizedDescription)}
    }
    private func connect(clientID:String,deadline:DispatchTime,reply:@escaping(Any?,String?)->Void) {
        oauth.connect(clientID:clientID) { result in
            if case .failure(let error) = result, (error as? GmailAPIError)?.code == "keychain_read_pending" {
                // Both the Calendar vault and the shared Desktop client configuration
                // can be cold. Each retry joins the existing nonblocking read.
                guard DispatchTime.now() < deadline else {
                    self.busy=false
                    reply(nil,"The Mac Keychain took too long to check the Google credentials. Try connecting Calendar again.")
                    return
                }
                DispatchQueue.main.asyncAfter(deadline:.now() + 0.2) {
                    self.connect(clientID:clientID,deadline:deadline,reply:reply)
                }
                return
            }
            self.finishConnect(result,reply:reply)
        }
    }

    private func finishConnect(_ result:Result<Record,Error>,reply:@escaping(Any?,String?)->Void) {
        guard storeAvailable() else {
            DispatchQueue.main.asyncAfter(deadline:.now() + 0.2) { self.finishConnect(result,reply:reply) }
            return
        }
        busy=false
        do {
            let connection=try result.get()
            if let expected=try store.gmailSyncStatus()["accountAddress"] as? String,!expected.isEmpty,connection["accountAddress"] as? String != expected {
                try oauth.disconnect()
                throw StoreError(message:"Connect Calendar with the same work account shown in Gmail integrations.")
            }
            try saveConnection(connection)
            reply(["connected":true,"accountAddress":connection["accountAddress"] ?? ""],nil)
        } catch {reply(nil,error.localizedDescription)}
    }

    private func refresh(_ meeting:Record,account:String,_ reply:@escaping(Any?,String?)->Void) throws {
        guard meeting["state"] as? String=="booked",let id=meeting["id"] as? String,
              let eventID=meeting["googleEventId"] as? String else {
            throw StoreError(message:"Select a verified booking to refresh from Google Calendar.")
        }
        if let original=meeting["calendarAccountAddress"] as? String,original != account {
            throw StoreError(message:"Reconnect the Google account that created this booking before refreshing it.")
        }
        busy=true
        oauth.accessToken { result in
            do {
                self.client.readBookedEvent(id:eventID,token:try result.get()) { event in
                    self.busy=false
                    do {
                        try self.store.applyCalendarRefresh(id:id,event:try event.get())
                        reply(try self.store.snapshot(),nil)
                    } catch {reply(nil,error.localizedDescription)}
                }
            } catch {self.busy=false;reply(nil,error.localizedDescription)}
        }
    }

}
