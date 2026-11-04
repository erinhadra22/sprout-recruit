import Foundation

/// Fixed primary-calendar booking adapter. Every invocation begins with a GET;
/// one confirmed absence may authorize one insert, followed by one GET readback.
/// The caller durably disables inserts after any prior submission attempt.
/// API contracts: https://developers.google.com/workspace/calendar/api/v3/reference/events/insert
/// and https://developers.google.com/workspace/calendar/api/v3/reference/events/get
final class GoogleCalendarClient {
    static let eventsScope="https://www.googleapis.com/auth/calendar.events.owned"
    static let scopes:Set<String>=[GmailAPIClient.readScope,eventsScope]
    private static let endpoint="https://www.googleapis.com/calendar/v3/calendars/primary/events"
    private let run:GmailAPIClient.Run
    init(run:@escaping GmailAPIClient.Run=GmailHTTPTransport.run){self.run=run}
    private static func error(_ code:String,_ message:String)->GmailAPIError{GmailAPIError(code:code,message:message)}
    private static func bookingID(_ eventID:String)->String?{
        guard eventID.range(of:"^sprout[0-9a-f]{32}$",options:.regularExpression) != nil else{return nil}
        let hex=Array(eventID.dropFirst(6)),lengths=[8,4,4,4,12]
        var offset=0,parts=[String]()
        for length in lengths{parts.append(String(hex[offset..<(offset+length)]));offset+=length}
        let value=parts.joined(separator:"-")
        return UUID(uuidString:value)?.uuidString.lowercased()
    }
    private static func envelope(_ raw:Record)throws->Record{
        let keys:Set<String>=["id","summary","start","end","attendees","extendedProperties"]
        guard Set(raw.keys).isSubset(of:keys),let id=raw["id"] as? String,let booking=bookingID(id),
              let title=raw["summary"] as? String,!title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,title.count<=500,!title.contains("\0"),
              let start=raw["start"] as? Record,let end=raw["end"] as? Record,
              Set(start.keys)==["dateTime","timeZone"],Set(end.keys)==["dateTime","timeZone"],
              let startString=start["dateTime"] as? String,let endString=end["dateTime"] as? String,
              let starts=GmailAPIClient.date(startString),let ends=GmailAPIClient.date(endString),ends>starts,ends.timeIntervalSince(starts)<=14400,
              let zone=start["timeZone"] as? String,TimeZone(identifier:zone) != nil,end["timeZone"] as? String==zone,
              let attendees=raw["attendees"] as? [Record],(1...21).contains(attendees.count) else{throw error("calendar_invalid_event","Preview a complete meeting with its exact booking ID, time zone and attendees before booking.")}
        let emails=try attendees.map{attendee -> String in
            guard Set(attendee.keys)==["email"],let raw=attendee["email"] as? String,let email=GmailAPIClient.email(raw),email==raw else{throw error("calendar_invalid_event","Meeting attendees must be distinct complete email addresses.")};return email
        }
        guard Set(emails).count==emails.count else{throw error("calendar_invalid_event","Meeting attendees must be distinct complete email addresses.")}
        if let value=raw["extendedProperties"]{
            guard let properties=value as? Record,Set(properties.keys)==["private"],let privateValues=properties["private"] as? [String:String],Set(privateValues.keys)==["sproutBookingID"],privateValues["sproutBookingID"]==booking else{throw error("calendar_invalid_event","The calendar ownership marker does not match this booking ID.")}
        }
        var result=raw;result["extendedProperties"]=["private":["sproutBookingID":booking]]
        return result
    }
    private static func owned(_ actual:Record,expected:Record)throws->Record{
        guard actual["id"] as? String==expected["id"] as? String,actual["status"] as? String=="confirmed",actual["attendeesOmitted"] as? Bool != true,
              let uid=actual["iCalUID"] as? String,!uid.isEmpty,uid.count<=2048 else{throw error("calendar_identity_mismatch","Google Calendar returned a different or incomplete event. Keep the booking pending for reconciliation.")}
        let expectedMarker=((expected["extendedProperties"] as? Record)?["private"] as? [String:String])?["sproutBookingID"]
        var actualPrivate:Record?
        if let rawProperties=actual["extendedProperties"]{
            guard let properties=rawProperties as? Record else{throw error("calendar_identity_mismatch","Calendar event ownership metadata is malformed. Keep the booking pending for reconciliation.")}
            if let rawPrivate=properties["private"]{
                guard let privateValues=rawPrivate as? Record else{throw error("calendar_identity_mismatch","Calendar event ownership metadata is malformed. Keep the booking pending for reconciliation.")};actualPrivate=privateValues
            }
        }
        if let marker=actualPrivate?["sproutBookingID"]{
            guard marker as? String==expectedMarker else{throw error("calendar_identity_mismatch","That calendar event belongs to a different booking. Keep this booking pending for reconciliation.")}
        }else{
            // Legacy events without a private marker require the exact envelope
            // below plus proof that the connected primary-calendar owner organizes it.
            guard (actual["organizer"] as? Record)?["self"] as? Bool==true else{throw error("calendar_identity_mismatch","Calendar event ownership could not be verified. Keep the booking pending for reconciliation.")}
        }
        guard actual["summary"] as? String==expected["summary"] as? String else{throw error("calendar_event_changed","The calendar meeting title changed. Reconcile the existing event before retrying.")}
        for key in ["start","end"]{
            guard let found=actual[key] as? Record,let wanted=expected[key] as? Record,
                  let foundString=found["dateTime"] as? String,let wantedString=wanted["dateTime"] as? String,
                  let foundDate=GmailAPIClient.date(foundString),let wantedDate=GmailAPIClient.date(wantedString),foundDate==wantedDate,
                  found["timeZone"] as? String==wanted["timeZone"] as? String else{throw error("calendar_event_changed","The calendar meeting time changed. Reconcile the existing event before retrying.")}
        }
        guard let actualAttendees=actual["attendees"] as? [Record],let expectedAttendees=expected["attendees"] as? [Record],actualAttendees.count==expectedAttendees.count else{throw error("calendar_event_changed","The calendar attendee list changed. Reconcile the existing event before retrying.")}
        let actualEmails=actualAttendees.compactMap{($0["email"] as? String).flatMap(GmailAPIClient.email)},expectedEmails=expectedAttendees.compactMap{$0["email"] as? String}
        guard actualEmails.count==actualAttendees.count,Set(actualEmails).count==actualEmails.count,Set(actualEmails)==Set(expectedEmails) else{throw error("calendar_event_changed","The calendar attendee list changed. Reconcile the existing event before retrying.")}
        return actual
    }
    private func request(method:String,id:String?,event:Record?,token:String,completion:@escaping(Result<Record,Error>)->Void){
        var url=URLComponents(string:Self.endpoint+(id.map{"/"+$0} ?? ""))!
        if method=="POST"{url.queryItems=[URLQueryItem(name:"sendUpdates",value:"all")]}
        var request=URLRequest(url:url.url!);request.httpMethod=method;request.timeoutInterval=25
        request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization");request.setValue("application/json",forHTTPHeaderField:"Accept")
        if let event=event{
            do{let bytes=try JSONSerialization.data(withJSONObject:event,options:.sortedKeys);guard bytes.count<=131072 else{throw Self.error("calendar_invalid_event","This meeting exceeds the calendar request limit.")};request.httpBody=bytes;request.setValue("application/json",forHTTPHeaderField:"Content-Type")}
            catch{completion(.failure(Self.error("calendar_invalid_event","This meeting could not be encoded for Google Calendar.")));return}
        }
        run(request){result in completion(result.flatMap{data in
            do{guard data.count<=1_000_000,let value=try JSONSerialization.jsonObject(with:data) as? Record else{throw Self.error("calendar_invalid_response","Google Calendar returned an invalid event response.")};return .success(value)}
            catch{return .failure(Self.error("calendar_invalid_response","Google Calendar returned an invalid event response."))}
        })}
    }
    func ensureEvent(event:Record,token:String,allowInsert:Bool=true,completion:@escaping(Result<Record,Error>)->Void){
        guard !token.isEmpty,token.count<16384,!token.contains(where:{$0.isWhitespace || $0.isNewline}),!token.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{completion(.failure(Self.error("authorization_required","Reconnect Google Calendar before booking.")));return}
        let expected:Record
        do{expected=try Self.envelope(event)}catch{completion(.failure(error));return}
        let id=expected["id"] as! String
        let validate:(Result<Record,Error>)->Void={result in completion(result.flatMap{value in Result{try Self.owned(value,expected:expected)}})}
        request(method:"GET",id:id,event:nil,token:token){result in
            switch result{
            case .success:validate(result)
            case .failure(let error):
                guard (error as? GmailAPIError)?.code=="not_found" else{completion(.failure(error));return}
                guard allowInsert else{completion(.failure(Self.error("pending_unknown","A previous calendar submission is still unconfirmed. Reconcile its existing event ID; another invitation was not sent.")));return}
                self.request(method:"POST",id:nil,event:expected,token:token){_ in
                    // Even a successful insert is verified with a GET. Conflicts,
                    // malformed responses and transport failures use this same
                    // single reconciliation read; no branch can issue another POST.
                    self.request(method:"GET",id:id,event:nil,token:token){readback in
                        if case .failure=readback{completion(.failure(Self.error("pending_unknown","Google Calendar booking could not be verified after submission. Reconcile this event ID before any further invitation.")));return}
                        validate(readback)
                    }
                }
            }
        }
    }
}
