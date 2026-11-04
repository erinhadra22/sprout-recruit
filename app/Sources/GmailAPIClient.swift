import Foundation
import CryptoKit

struct GmailAPIError: LocalizedError {
    let code: String
    let message: String
    var errorDescription: String? { message }
}

// Fixed Google endpoints, no cookies/cache/redirects, and bounded response memory.
// OAuth and Calendar reuse this bounded transport for their fixed POST endpoints.
final class GmailHTTPTransport: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var body = Data()
    private var response: HTTPURLResponse?
    private var done: ((Result<Data,Error>) -> Void)?
    private let maximum = 8_000_000
    static func run(_ request: URLRequest, completion: @escaping (Result<Data,Error>) -> Void) {
        let transport = GmailHTTPTransport()
        transport.done = completion
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 35
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        transport.session = URLSession(configuration:config,delegate:transport,delegateQueue:queue)
        transport.session!.dataTask(with:request).resume()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response as? HTTPURLResponse
        if response.expectedContentLength > Int64(maximum) { finish(.failure(GmailAPIError(code:"response_too_large",message:"Gmail returned an oversized response. The scan was not advanced."))); completionHandler(.cancel) }
        else { completionHandler(.allow) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard body.count <= maximum - data.count else { finish(.failure(GmailAPIError(code:"response_too_large",message:"Gmail returned an oversized response. The scan was not advanced."))); dataTask.cancel(); return }
        body.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard done != nil else { return }
        if error != nil { finish(.failure(GmailAPIError(code:"network_unavailable",message:"Gmail could not be reached. The scan was not advanced."))); return }
        guard let response else { finish(.failure(GmailAPIError(code:"invalid_response",message:"Gmail returned no HTTP response."))); return }
        if (200...299).contains(response.statusCode) { finish(.success(body)); return }
        if task.originalRequest?.url?.absoluteString == "https://oauth2.googleapis.com/token",
           let error=Self.authorizationFailure(status:response.statusCode,body:body) {
            finish(.failure(error));return
        }
        let code: String
        switch response.statusCode {
        case 401: code = "authorization_required"
        case 403: code = "access_denied"
        case 404: code = "not_found"
        case 429: code = "rate_limited"
        case 500...599: code = "provider_unavailable"
        default: code = "request_rejected"
        }
        // Provider error bodies can contain addresses or token details; never expose them.
        finish(.failure(GmailAPIError(code:code,message:"Google rejected the request (HTTP \(response.statusCode)). Check the connection before retrying.")))
    }
    private func finish(_ result: Result<Data,Error>) {
        guard let callback = done else { return }; done = nil
        session?.invalidateAndCancel(); session = nil
        DispatchQueue.main.async { callback(result) }
    }
    // Only fixed error classes escape the token endpoint. Never return a provider
    // body or description, which may echo an authorization code or credential.
    static func authorizationFailure(status:Int,body:Data)->GmailAPIError? {
        guard status==400 || status==401,body.count<=65536,
              let value=try? JSONSerialization.jsonObject(with:body) as? [String:Any],
              let error=value["error"] as? String else { return nil }
        if error=="invalid_request",let description=value["error_description"] as? String,
           description=="client_secret is missing." {
            return GmailAPIError(code:"oauth_client_secret_required",message:"Google requires the Desktop client’s configuration secret to finish this connection. The account is not connected.")
        }
        switch error {
        case "invalid_grant":return GmailAPIError(code:"authorization_expired",message:"Google rejected this sign-in code. Start a fresh sign-in after checking the app configuration.")
        case "invalid_client","unauthorized_client":return GmailAPIError(code:"oauth_client_rejected",message:"Google rejected the Desktop client configuration. Check it before reconnecting.")
        default:return nil
        }
    }
}

final class GmailAPIClient {
    typealias Run = (URLRequest, @escaping (Result<Data,Error>) -> Void) -> Void
    private let run: Run
    init(run: @escaping Run = GmailHTTPTransport.run) { self.run = run }
    static let readScope = "https://www.googleapis.com/auth/gmail.readonly"
    static let headers = ["From","To","Cc","Bcc","Subject","Auto-Submitted","Precedence","Return-Path","In-Reply-To","Content-Type"]
    static func email(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in:.whitespacesAndNewlines).lowercased()
        guard value.count <= 320, value.range(of:"^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\\.[A-Za-z]{2,63}$",options:.regularExpression) != nil,
              !value.contains("..") else { return nil }
        return value
    }
    static func providerID(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty, s.count <= 200,
              s.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil else { return nil }; return s
    }
    static func historyID(_ value: Any?) -> String? {
        guard let s = value as? String, !s.isEmpty, s.count <= 30, s.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }; return s
    }
    private func request(_ path: String, token: String, query: [URLQueryItem] = [], completion: @escaping (Result<Record,Error>) -> Void) {
        guard !token.isEmpty, token.count < 16384, !token.contains(where:{$0.isWhitespace || $0.isNewline}) else { completion(.failure(GmailAPIError(code:"authorization_required",message:"Reconnect Gmail to continue."))); return }
        var url = URLComponents(string:"https://gmail.googleapis.com/gmail/v1/users/me/"+path)!
        url.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url:url.url!); request.httpMethod = "GET"; request.timeoutInterval = 25
        request.setValue("Bearer "+token,forHTTPHeaderField:"Authorization"); request.setValue("application/json",forHTTPHeaderField:"Accept")
        run(request) { result in completion(result.flatMap { data in
            do { guard data.count <= 8_000_000, let value = try JSONSerialization.jsonObject(with:data) as? Record else { throw GmailAPIError(code:"invalid_response",message:"Gmail returned an invalid response.") }; return .success(value) }
            catch { return .failure(error) }
        }) }
    }
    func profile(token: String, completion: @escaping (Result<Record,Error>) -> Void) {
        request("profile",token:token) { result in completion(result.flatMap { r in
            guard let email = (r["emailAddress"] as? String).flatMap(Self.email), let history = Self.historyID(r["historyId"]) else { return .failure(GmailAPIError(code:"invalid_profile",message:"Gmail did not identify the connected mailbox.")) }
            return .success(["accountAddress":email,"historyId":history])
        }) }
    }
    func listMessages(token: String, query: String, pageToken: String? = nil, completion: @escaping (Result<Record,Error>) -> Void) {
        guard query.count <= 2000, pageToken == nil || (pageToken!.count <= 4000 && !pageToken!.isEmpty) else { completion(.failure(GmailAPIError(code:"invalid_cursor",message:"The Gmail page cursor is invalid."))); return }
        var q = [URLQueryItem(name:"maxResults",value:"50"),URLQueryItem(name:"q",value:query),URLQueryItem(name:"includeSpamTrash",value:"false")]
        if let pageToken { q.append(URLQueryItem(name:"pageToken",value:pageToken)) }
        request("messages",token:token,query:q) { result in completion(result.flatMap { r in Self.page(r,history:false) }) }
    }
    func history(token: String, historyId: String, pageToken: String? = nil, completion: @escaping (Result<Record,Error>) -> Void) {
        guard Self.historyID(historyId) != nil, pageToken == nil || (pageToken!.count <= 4000 && !pageToken!.isEmpty) else { completion(.failure(GmailAPIError(code:"invalid_cursor",message:"The Gmail history cursor is invalid."))); return }
        var q = [URLQueryItem(name:"maxResults",value:"50"),URLQueryItem(name:"startHistoryId",value:historyId),URLQueryItem(name:"historyTypes",value:"messageAdded")]
        if let pageToken { q.append(URLQueryItem(name:"pageToken",value:pageToken)) }
        request("history",token:token,query:q) { result in
            if case .failure(let error) = result, (error as? GmailAPIError)?.code == "not_found" { completion(.failure(GmailAPIError(code:"history_expired",message:"Gmail's history cursor expired. Reconcile the approved history window before resuming."))); return }
            completion(result.flatMap { Self.page($0,history:true) })
        }
    }
    private static func page(_ r: Record, history: Bool) -> Result<Record,Error> {
        do {
            var ids: [String] = []
            if history {
                guard let h = historyID(r["historyId"]) else { throw GmailAPIError(code:"invalid_cursor",message:"Gmail returned no valid history checkpoint.") }
                _ = h
                guard r["history"] == nil || r["history"] is [Record] else { throw GmailAPIError(code:"invalid_response",message:"Gmail returned malformed history.") }
                for item in r["history"] as? [Record] ?? [] {
                    guard item["messagesAdded"] == nil || item["messagesAdded"] is [Record] else { throw GmailAPIError(code:"invalid_response",message:"Gmail returned malformed message additions.") }
                    for addition in item["messagesAdded"] as? [Record] ?? [] {
                        guard let message = addition["message"] as? Record, let id = providerID(message["id"]) else { throw GmailAPIError(code:"invalid_response",message:"Gmail returned an invalid message identity.") }; ids.append(id)
                    }
                }
            } else {
                guard r["messages"] == nil || r["messages"] is [Record] else { throw GmailAPIError(code:"invalid_response",message:"Gmail returned a malformed message page.") }
                for item in r["messages"] as? [Record] ?? [] { guard let id = providerID(item["id"]) else { throw GmailAPIError(code:"invalid_response",message:"Gmail returned an invalid message identity.") }; ids.append(id) }
            }
            var seen = Set<String>(); ids = ids.filter { seen.insert($0).inserted }
            guard ids.count <= 500 else { throw GmailAPIError(code:"page_too_large",message:"This Gmail history page exceeds the safe scan budget.") }
            var page: Record = ["messageIds":ids]
            if history { page["historyId"] = r["historyId"] }
            if let raw = r["nextPageToken"] { guard let token = raw as? String, !token.isEmpty, token.count <= 4000 else { throw GmailAPIError(code:"invalid_cursor",message:"Gmail returned an invalid next page token.") }; page["nextPageToken"] = token }
            return .success(page)
        } catch { return .failure(error) }
    }
    func message(token: String, id: String, full: Bool, completion: @escaping (Result<Record,Error>) -> Void) {
        guard Self.providerID(id) != nil else { completion(.failure(GmailAPIError(code:"invalid_message",message:"The Gmail message ID is invalid."))); return }
        var q = [URLQueryItem(name:"format",value:full ? "full":"metadata")]
        if !full { q += Self.headers.map { URLQueryItem(name:"metadataHeaders",value:$0) } }
        request("messages/"+id,token:token,query:q) { result in completion(result.flatMap { r in
            guard r["id"] as? String == id, Self.providerID(r["threadId"]) != nil else { return .failure(GmailAPIError(code:"identity_mismatch",message:"Gmail returned a different message identity.")) }
            return .success(r)
        }) }
    }
    // One bounded provider page. The caller persists this receipt atomically with
    // its imports/holds; this adapter never stores or advances a cursor itself.
    func readSyncPage(request: Record, token: String, completion: @escaping (Result<Record,Error>) -> Void) {
        guard let account = (request["accountAddress"] as? String).flatMap(Self.email), let sinceText = request["since"] as? String, let since = Self.date(sinceText),
              let emails = request["emails"] as? [String], emails.count <= 20000, emails.allSatisfy({Self.email($0)==$0}),
              let cursor = request["cursor"] as? Record else { completion(.failure(GmailAPIError(code:"invalid_request",message:"Gmail sync needs a verified mailbox, candidate emails and coverage window."))); return }
        let started = Self.iso(Date()), candidates = Set(emails)
        let ambiguous = Set(Dictionary(grouping:emails,by:{$0}).filter{$0.value.count>1}.keys)
        profile(token:token) { profileResult in
            do {
                let profile = try profileResult.get()
                guard profile["accountAddress"] as? String == account else { throw GmailAPIError(code:"account_changed",message:"The Gmail mailbox changed. Reconnect the intended account before importing.") }
                let mode = cursor["mode"] as? String ?? "full"
                let cursorKeys: Set<String> = mode == "full" ? ["mode","baselineHistoryId","pageToken"] : ["mode","historyId","pageToken"]
                let validFields = Set(cursor.keys).isSubset(of:cursorKeys) && (cursor["pageToken"] == nil || cursor["pageToken"] is String)
                let validCheckpoint = mode == "full" ? Self.historyID(cursor["baselineHistoryId"]) != nil : Self.historyID(cursor["historyId"]) != nil
                guard cursor.isEmpty || (["full","history"].contains(mode) && validFields && validCheckpoint) else { throw GmailAPIError(code:"invalid_cursor",message:"The Gmail scan mode is invalid.") }
                let baseline = cursor["baselineHistoryId"] as? String ?? profile["historyId"] as! String
                let fromHistory = cursor["historyId"] as? String ?? ""
                let receive: (Result<Record,Error>) -> Void = { pageResult in
                    do {
                        let page = try pageResult.get(), ids = page["messageIds"] as? [String] ?? []
                        var next: Record
                        if let pageToken = page["nextPageToken"] as? String {
                            next = mode == "full" ? ["mode":"full","baselineHistoryId":baseline,"pageToken":pageToken] : ["mode":"history","historyId":fromHistory,"pageToken":pageToken]
                        } else { next = ["mode":"history","historyId":mode == "full" ? baseline : page["historyId"]!] }
                        self.readMessages(ids,token:token,account:account,candidates:candidates,ambiguous:ambiguous,since:since) { result in
                            completion(result.map { values in ["accountAddress":account,"fromCursor":cursor,"nextCursor":next,"hasMore":page["nextPageToken"] != nil,"messages":values.messages,"held":values.held,"scannedCount":ids.count,"observedAt":started] })
                        }
                    } catch { completion(.failure(error)) }
                }
                if candidates.isEmpty { receive(.success(["messageIds":[String](),"historyId":profile["historyId"]!])); return }
                if mode == "full" {
                    guard Self.historyID(baseline) != nil else { throw GmailAPIError(code:"invalid_cursor",message:"Gmail's full scan checkpoint is invalid.") }
                    // Epoch seconds avoid Gmail search's date/timezone ambiguity. Exact milliseconds are checked below.
                    self.listMessages(token:token,query:"after:\(max(0,Int64(since.timeIntervalSince1970.rounded(.down))-1)) -in:drafts",pageToken:cursor["pageToken"] as? String,completion:receive)
                } else { self.history(token:token,historyId:fromHistory,pageToken:cursor["pageToken"] as? String,completion:receive) }
            } catch { completion(.failure(error)) }
        }
    }

    // RFC 5545 content-line folding and RFC 5546 REPLY evidence. Calendar prose,
    // subject prefixes, and delegated responders never establish an acceptance.
    static func meetingResponse(calendarText:String,sender:String,recipient:String)->Record? {
        guard calendarText.utf8.count<=65536,!calendarText.contains("\0"),let sender=email(sender),let recipient=email(recipient) else { return nil }
        let raw=calendarText.replacingOccurrences(of:"\r\n",with:"\n").components(separatedBy:"\n")
        guard raw.count<=1024,!raw.contains(where:{$0.contains("\r")}) else { return nil }
        var lines:[String]=[]
        for line in raw {
            if line.hasPrefix(" ") || line.hasPrefix("\t") {
                guard !lines.isEmpty else { return nil };lines[lines.count-1]+=String(line.dropFirst())
            } else if !line.isEmpty { lines.append(line) }
            guard (lines.last?.utf8.count ?? 0)<=4096 else { return nil }
        }
        func split(_ value:String,on separator:Character)->[String]? {
            var quoted=false,parts=[String](),part=""
            for char in value {
                if char=="\"" { quoted.toggle() }
                if char==separator && !quoted { parts.append(part);part="" } else { part.append(char) }
            }
            guard !quoted else { return nil };parts.append(part);return parts
        }
        var stack:[String]=[],method:String?,uid:String?,organizer:String?,attendee:String?,response:String?,events=0,closed=false
        for line in lines {
            var quoted=false,colon:String.Index?
            for index in line.indices {
                if line[index]=="\"" { quoted.toggle() }
                if line[index]==":" && !quoted { colon=index;break }
            }
            guard let colon,let fields=split(String(line[..<colon]),on:";"),let first=fields.first,!first.isEmpty else { return nil }
            let name=first.uppercased(),value=String(line[line.index(after:colon)...])
            var parameters:[String:String]=[:]
            for field in fields.dropFirst() {
                guard let at=field.firstIndex(of:"="),at != field.startIndex else { return nil }
                let key=field[..<at].uppercased();var val=String(field[field.index(after:at)...])
                if val.hasPrefix("\"") && val.hasSuffix("\"") { val=String(val.dropFirst().dropLast()) }
                guard parameters[key]==nil,!val.isEmpty else { return nil };parameters[key]=val
            }
            if name=="BEGIN" {
                guard parameters.isEmpty,!closed,stack.count<8 else { return nil }
                if stack.isEmpty { guard value=="VCALENDAR" else { return nil } }
                else if value=="VCALENDAR" { return nil }
                if value=="VEVENT" { guard stack==["VCALENDAR"],events==0 else { return nil };events+=1 }
                stack.append(value);continue
            }
            if name=="END" {
                guard parameters.isEmpty,stack.last==value else { return nil };stack.removeLast();if stack.isEmpty { closed=true };continue
            }
            guard !stack.isEmpty,!closed else { return nil }
            if name=="METHOD",stack==["VCALENDAR"] { guard method==nil,parameters.isEmpty else { return nil };method=value.uppercased() }
            if stack==["VCALENDAR","VEVENT"] {
                switch name {
                case "UID":guard uid==nil,parameters.isEmpty,!value.isEmpty,value.count<=1024 else { return nil };uid=value
                case "ORGANIZER":
                    guard organizer==nil,parameters["SENT-BY"]==nil,value.lowercased().hasPrefix("mailto:"),let address=email(String(value.dropFirst(7))),address==recipient else { return nil };organizer=address
                case "ATTENDEE":
                    guard attendee==nil,parameters["SENT-BY"]==nil,parameters["DELEGATED-TO"]==nil,parameters["DELEGATED-FROM"]==nil,value.lowercased().hasPrefix("mailto:"),let address=email(String(value.dropFirst(7))),address==sender,let partstat=parameters["PARTSTAT"]?.uppercased(),["ACCEPTED","DECLINED","TENTATIVE"].contains(partstat) else { return nil }
                    attendee=address;response=partstat.lowercased()
                default:break
                }
            }
        }
        guard closed,stack.isEmpty,events==1,method=="REPLY",let uid,let attendee,let response else { return nil }
        var result:Record=["method":"REPLY","response":response,"attendee":attendee,"uid":uid,"calendarSHA256":SHA256.hash(data:Data(calendarText.utf8)).map{String(format:"%02x",$0)}.joined()]
        if let organizer { result["organizer"]=organizer };return result
    }
    // Fetch only the bounded calendar MIME part of an already verified one-to-one
    // inbound message. Calendar bytes classify evidence; they never replace body.
    private func readCalendar(_ payload:Record,messageID:String,token:String,completion:@escaping(Result<String?,Error>)->Void) {
        var parts:[Record]=[],visited=0,invalid=false
        func walk(_ part:Record,_ depth:Int) {
            visited+=1;guard visited<=100,depth<=12 else { invalid=true;return }
            let mime=(part["mimeType"] as? String ?? "").lowercased()
            if mime=="text/calendar" { parts.append(part) }
            for child in part["parts"] as? [Record] ?? [] { if invalid { break };walk(child,depth+1) }
        }
        walk(payload,0)
        guard !invalid,parts.count<=1 else { completion(.success(""));return }
        guard let part=parts.first else { completion(.success(nil));return }
        let headers=part["headers"] as? [Record] ?? []
        for header in headers where (header["name"] as? String ?? "").lowercased()=="content-type" {
            let type=(header["value"] as? String ?? "").lowercased()
            if let range=type.range(of:"charset=") {
                let charset=type[range.upperBound...].split(separator:";").first?.trimmingCharacters(in:CharacterSet(charactersIn:" \t\"")) ?? ""
                guard ["utf-8","utf8","us-ascii","ascii"].contains(charset) else { completion(.success(""));return }
            }
        }
        guard let body=part["body"] as? Record else { completion(.success(""));return }
        func decode(_ object:Record)->String? {
            guard let encoded=object["data"] as? String,encoded.utf8.count<=90000 else { return nil }
            var base=encoded.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/");base+=String(repeating:"=",count:(4-base.count%4)%4)
            guard let data=Data(base64Encoded:base),data.count<=65536,let text=String(data:data,encoding:.utf8),!text.contains("\0") else { return nil }
            if let size=object["size"] as? Int,size != data.count { return nil }
            return text
        }
        if body["data"] is String { completion(.success(decode(body) ?? ""));return }
        guard let size=body["size"] as? Int,size>0,size<=65536,let id=body["attachmentId"] as? String,!id.isEmpty,id.count<=4096,id.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil else { completion(.success(""));return }
        request("messages/"+messageID+"/attachments/"+id,token:token) { result in
            completion(result.map { object in
                guard let text=decode(object),text.utf8.count==size else { return "" };return text
            })
        }
    }

    private func readMessages(_ ids: [String], token: String, account: String, candidates: Set<String>, ambiguous: Set<String>, since: Date, completion: @escaping (Result<(messages:[Record],held:[Record]),Error>) -> Void) {
        var messages: [Record] = [], held: [Record] = []
        let deadline = Date().addingTimeInterval(120)
        func next(_ index: Int) {
            guard Date() <= deadline else { completion(.failure(GmailAPIError(code:"scan_budget_exceeded",message:"The Gmail page took too long. No cursor was advanced."))); return }
            guard index < ids.count else { completion(.success((messages,held))); return }
            self.message(token:token,id:ids[index],full:false) { result in
                do {
                    let raw = try result.get(), env = try Self.envelope(raw)
                    guard let occurred = Self.date(env["occurredAt"] as! String), occurred >= since else { next(index+1); return }
                    let labels = env["labels"] as! [String]
                    if !Set(labels).isDisjoint(with:["DRAFT","SPAM","TRASH"]) { next(index+1); return }
                    let from = env["from"] as? String ?? "", to = env["to"] as! [String], cc = env["cc"] as! [String], bcc = env["bcc"] as! [String]
                    let hints = env["envelopeValid"] as? Bool == true ? [] : env["participantEmailHints"] as? [String] ?? []
                    let participants = Set([from]+to+cc+bcc+hints).filter { !$0.isEmpty }
                    guard !candidates.isDisjoint(with:participants) else { next(index+1); return }
                    let outbound = labels.contains("SENT")
                    let eligible = ambiguous.isDisjoint(with:participants) && env["envelopeValid"] as? Bool == true && cc.isEmpty && bcc.isEmpty && to.count == 1 && (outbound ? from == account && candidates.contains(to[0]) : candidates.contains(from) && to[0] == account)
                    guard eligible else {
                        held.append(["providerMessageId":ids[index],"providerThreadId":raw["threadId"]!,"reasonCode":!ambiguous.isDisjoint(with:participants) ? "ambiguous_identity" : (env["envelopeValid"] as? Bool == true ? "unsupported_envelope":"malformed_envelope"),"direction":outbound ? "outbound":"inbound","participantEmails":participants.sorted()]); next(index+1); return
                    }
                    self.message(token:token,id:ids[index],full:true) { fullResult in
                        do {
                            let full = try fullResult.get(), fullEnv = try Self.envelope(full)
                            // Message changes between metadata and body fetch cannot change attribution.
                            for field in ["providerMessageId","providerThreadId","from","to","cc","bcc","occurredAt","labels"] {
                                let left = try JSONSerialization.data(withJSONObject:["value":env[field] ?? NSNull()],options:.sortedKeys)
                                let right = try JSONSerialization.data(withJSONObject:["value":fullEnv[field] ?? NSNull()],options:.sortedKeys)
                                guard left == right else { throw GmailAPIError(code:"message_changed",message:"A Gmail message changed during the scan. Retry without advancing the cursor.") }
                            }
                            var row = fullEnv; row.removeValue(forKey:"envelopeValid"); row.removeValue(forKey:"participantEmailHints")
                            row["direction"] = outbound ? "outbound":"inbound"; row["accountAddress"] = account
                            let body = Self.body(full["payload"] as? Record ?? [:]); row["body"] = body.text; row["bodyKind"] = body.kind
                            if outbound { messages.append(row);next(index+1);return }
                            self.readCalendar(full["payload"] as? Record ?? [:],messageID:ids[index],token:token) { calendarResult in
                                do {
                                    if let calendar=try calendarResult.get() {
                                        guard Self.meetingResponse(calendarText:calendar,sender:from,recipient:account) != nil else {
                                            held.append(["providerMessageId":ids[index],"providerThreadId":fullEnv["providerThreadId"]!,"reasonCode":"calendar_response_unverified","direction":"inbound","participantEmails":[from,account]]);next(index+1);return
                                        }
                                        row["calendarText"]=calendar
                                    }
                                    messages.append(row);next(index+1)
                                } catch { completion(.failure(error)) }
                            }
                        } catch { completion(.failure(error)) }
                    }
                } catch {
                    // A concurrently deleted message has no body to import; record only its provider identity.
                    if (error as? GmailAPIError)?.code == "not_found" { held.append(["providerMessageId":ids[index],"reasonCode":"message_unavailable","participantEmails":[String]()]); next(index+1) }
                    else { completion(.failure(error)) }
                }
            }
        }
        next(0)
    }
    static func date(_ text: String) -> Date? { let f=ISO8601DateFormatter(); f.formatOptions=[.withInternetDateTime,.withFractionalSeconds]; return f.date(from:text) ?? ISO8601DateFormatter().date(from:text) }
    static func iso(_ date: Date) -> String { let f=ISO8601DateFormatter(); f.formatOptions=[.withInternetDateTime,.withFractionalSeconds]; return f.string(from:date) }
    static func envelope(_ raw: Record) throws -> Record {
        guard let id = providerID(raw["id"]), let thread = providerID(raw["threadId"]), let ms = raw["internalDate"] as? String, let value = Int64(ms), value >= 0,
              value <= Int64(Date().addingTimeInterval(300).timeIntervalSince1970*1000), let labels = raw["labelIds"] as? [String], labels.count <= 100,
              let payload = raw["payload"] as? Record, let headers = payload["headers"] as? [Record], headers.count <= 300 else { throw GmailAPIError(code:"invalid_message",message:"Gmail returned invalid message metadata.") }
        var h:[String:[String]] = [:]
        for header in headers {
            guard let name = header["name"] as? String, let val = header["value"] as? String, name.count < 100, val.utf8.count <= 32768 else { throw GmailAPIError(code:"invalid_message",message:"Gmail returned oversized message headers.") }
            h[name.lowercased(),default:[]].append(val)
        }
        var valid = true
        func addresses(_ name:String) -> [String] {
            guard let values=h[name] else { return [] }
            guard values.count == 1, let result=mailboxes(values[0]) else { valid=false; return [] }; return result
        }
        let from=addresses("from"),to=addresses("to"),cc=addresses("cc"),bcc=addresses("bcc")
        if from.count != 1 { valid=false }
        var result: Record = ["providerMessageId":id,"providerThreadId":thread,"from":from.first ?? "","to":to,"cc":cc,"bcc":bcc,"occurredAt":iso(Date(timeIntervalSince1970:Double(value)/1000)),"labels":labels.sorted(),"subject":String((h["subject"]?.first ?? "").prefix(500)),"envelopeValid":valid,"participantEmailHints":headerAddressHints(["from","to","cc","bcc"].flatMap{h[$0] ?? []})]
        for pair in [("auto-submitted","autoSubmitted"),("precedence","precedence"),("return-path","returnPath"),("in-reply-to","inReplyTo")] {
            if let values=h[pair.0] { result[pair.1]=String(values.joined(separator:", ").prefix(1000)) }
        }
        return result
    }
    // Literal address evidence from unsupported headers can justify a hold, but
    // never a body fetch or contact attribution. This keeps comment/group syntax
    // from hiding a possible candidate reply behind a failed envelope parse.
    static func headerAddressHints(_ values:[String])->[String] {
        let expression=try! NSRegularExpression(pattern:"[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?\\.[A-Za-z]{2,63}")
        var result=Set<String>()
        for value in values {
            let text=String(value.prefix(32768)),range=NSRange(text.startIndex..<text.endIndex,in:text)
            for match in expression.matches(in:text,range:range).prefix(100) {
                if let range=Range(match.range,in:text),let address=email(String(text[range])) { result.insert(address) }
            }
        }
        return result.sorted()
    }
    // Conservative RFC mailbox subset: quoted display names, angle addresses and
    // comma lists. Unsupported groups/comments are held, never guessed.
    static func mailboxes(_ raw: String) -> [String]? {
        let text=raw.replacingOccurrences(of:"\\r?\\n[\\t ]+",with:" ",options:.regularExpression)
        if text.trimmingCharacters(in:.whitespaces).isEmpty { return [] }
        guard !text.contains("\r"),!text.contains("\n"),text.count <= 32768 else { return nil }
        var quoted=false,escaped=false,angle=false,part="",parts:[String]=[]
        for c in text {
            if escaped { part.append(c);escaped=false;continue }
            if quoted && c == "\\" { part.append(c);escaped=true;continue }
            if c == "\"" { quoted.toggle();part.append(c);continue }
            if !quoted {
                if c == "<" { if angle { return nil };angle=true }
                if c == ">" { if !angle { return nil };angle=false }
                if c == ";" || c == ":" || c == "(" || c == ")" { return nil }
                if c == "," && !angle { parts.append(part);part="";continue }
            }
            part.append(c)
        }
        guard !quoted,!escaped,!angle else { return nil };parts.append(part)
        guard parts.count <= 100 else { return nil }
        var result:[String]=[]
        for part in parts {
            let candidate:String
            if let start=part.firstIndex(of:"<"), let end=part.lastIndex(of:">") {
                guard start < end,part[part.index(after:end)...].trimmingCharacters(in:.whitespaces).isEmpty else { return nil }
                candidate=String(part[part.index(after:start)..<end])
            } else { candidate=part }
            guard let address=email(candidate) else { return nil };result.append(address)
        }
        return result
    }
    static func body(_ payload: Record) -> (text:String,kind:String) {
        var count=0,bytes=0,plain:[String]=[]
        func walk(_ p:Record,_ depth:Int) -> Bool {
            count += 1
            guard count <= 100,depth <= 12 else { return false }
            if !(p["filename"] as? String ?? "").isEmpty { return true }
            let mime=(p["mimeType"] as? String ?? "").lowercased()
            if mime == "text/plain" {
                guard let body=p["body"] as? Record,let raw=body["data"] as? String,raw.count <= 400000,let data=base64URL(raw) else { return false }
                bytes += data.count;guard bytes <= 262144 else { return false }
                let contentType=(p["headers"] as? [Record] ?? []).first { ($0["name"] as? String)?.lowercased()=="content-type" }?["value"] as? String ?? ""
                let charset=contentType.lowercased().components(separatedBy:"charset=").dropFirst().first?.split(separator:";").first.map { String($0).trimmingCharacters(in:CharacterSet(charactersIn:" \"'")) } ?? "utf-8"
                let encoding: String.Encoding
                switch charset { case "utf-8","utf8","us-ascii","ascii":encoding = .utf8;case "iso-8859-1","latin1":encoding = .isoLatin1;case "windows-1252":encoding = .windowsCP1252;default:return false }
                guard let text=String(data:data,encoding:encoding) else { return false };plain.append(text)
            } else if mime.hasPrefix("multipart/") {
                guard let children=p["parts"] as? [Record] else { return false }
                for child in children { if !walk(child,depth+1) { return false } }
            }
            return true
        }
        if walk(payload,0),!plain.isEmpty {
            let text=plain.joined(separator:"\n\n")
            if !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.count <= 50000,!text.contains("\0") { return (text,"text") }
        }
        return ("[Email body unavailable in this read-only import. Open the original message in Gmail.]","unavailable")
    }
    static func base64URL(_ raw:String) -> Data? {
        guard raw.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45,95,61].contains($0) }) else { return nil }
        let text=raw.replacingOccurrences(of:"-",with:"+").replacingOccurrences(of:"_",with:"/")
        return Data(base64Encoded:text+String(repeating:"=",count:(4-text.count%4)%4))
    }
}
