import Foundation

/// Only the native controller can authorize Calendar or submit invitations.
/// WebKit receives connection metadata and saved records, never credentials.
final class CalendarController {
    private let store: Store
    private let oauth: GmailOAuth
    private let client: GoogleCalendarClient
    private var busy = false
    init(store:Store) {
        self.store=store
        oauth=GmailOAuth(workspacePath:store.path,scopes:GoogleCalendarClient.scopes,keychainService:"com.sprout-recruit.calendar.oauth")
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
            if action=="calendar.disconnect" {
                guard payload["confirmed"] as? Bool==true else {throw StoreError(message:"Confirm disconnecting Calendar.")}
                try oauth.disconnect();busy=false;try saveConnection(["connected":false]);reply(try store.snapshot(),nil);return
            }
            guard !busy else {throw StoreError(message:"A Calendar operation is in progress. Wait for its result.")}
            if action=="calendar.connect" {
                guard Set(payload.keys)==["confirmed"],payload["confirmed"] as? Bool==true else {throw StoreError(message:"Review Calendar event creation and attendee invitation access before connecting.")}
                guard let clientID=try store.gmailClientConfiguration()["clientId"] as? String,!clientID.isEmpty else {throw StoreError(message:"Configure the Google Desktop client in Gmail integrations first.")}
                _ = try store.consistentBackup(label:"before-calendar-authorization")
                busy=true
                oauth.connect(clientID:clientID) { result in
                    self.busy=false
                    do {
                        let connection=try result.get()
                        if let expected=try self.store.gmailSyncStatus()["accountAddress"] as? String,!expected.isEmpty,connection["accountAddress"] as? String != expected {
                            try self.oauth.disconnect();throw StoreError(message:"Connect Calendar with the same work account shown in Gmail integrations.")
                        }
                        try self.saveConnection(connection);reply(try self.store.snapshot(),nil)
                    } catch {reply(nil,error.localizedDescription)}
                }
                return
            }
            guard ["meetings.book","meetings.reconcile"].contains(action) else {throw StoreError(message:"Unsupported Calendar action.")}
            guard try oauth.status()["connected"] as? Bool==true else {throw StoreError(message:"Connect Google Calendar in Settings → Meetings before creating an invitation. No event was submitted.")}
            let meeting:Record
            if action=="meetings.reconcile" {
                guard Set(payload.keys)==["id"],let id=payload["id"] as? String else {throw StoreError(message:"Select the saved booking to check.")}
                meeting=try store.get("meetings",id)
            } else {meeting=try store.prepareMeetingBooking(payload)}
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
                            _ = try self.store.applyMeetingBookingResult(["id":id,"event":try result.get()])
                            reply(try self.store.snapshot(),nil)
                        } catch {reply(nil,error.localizedDescription+" Check this saved booking before creating another invitation.")}
                    }
                } catch {self.busy=false;reply(nil,error.localizedDescription)}
            }
        } catch {reply(nil,error.localizedDescription)}
    }
}
