import Foundation

struct TelnyxReceipt {
    let id: String
    let state: String
    let providerStatus: String
    let sentAt: Date?
}

enum TelnyxMessageAPI {
    static func timestamp(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let f = ISO8601DateFormatter()
        if let date = f.date(from:text) { return date }
        f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]
        return f.date(from:text)
    }
    static func sendRequest(key: String, sender: String, phone: String, body: String) throws -> URLRequest {
        var request = try request(key: key, path: "messages", method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["from":sender,"to":phone,"text":body,"type":"SMS","encoding":"ucs2","use_profile_webhooks":false])
        return request
    }
    static func receiptRequest(key: String, id: String) throws -> URLRequest {
        guard UUID(uuidString:id) != nil else { throw StoreError(message:"This message has no valid Telnyx receipt ID.") }
        return try request(key:key,path:"messages/"+id,method:"GET")
    }
    private static func request(key: String, path: String, method: String) throws -> URLRequest {
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r") else { throw StoreError(message:"Enter a valid API key in Calling & texts settings.") }
        var r = URLRequest(url:URL(string:"https://api.telnyx.com/v2/"+path)!)
        r.httpMethod = method; r.timeoutInterval = 30
        r.setValue("Bearer "+key,forHTTPHeaderField:"Authorization")
        r.setValue("application/json",forHTTPHeaderField:"Content-Type")
        r.setValue("application/json",forHTTPHeaderField:"Accept")
        return r
    }
    // Match the complete outgoing message before treating any status as evidence.
    static func receipt(_ data: Data, sender: String, phone: String, body: String, expectedID: String? = nil) throws -> TelnyxReceipt {
        guard data.count < 1_000_000,
              let root = try JSONSerialization.jsonObject(with:data) as? Record,
              let item = root["data"] as? Record,
              let id = item["id"] as? String, UUID(uuidString:id) != nil,
              expectedID == nil || UUID(uuidString:id) == UUID(uuidString:expectedID!),
              item["direction"] as? String == "outbound",
              let from = item["from"] as? Record, from["phone_number"] as? String == sender,
              let to = item["to"] as? [Record], to.count == 1,
              to[0]["phone_number"] as? String == phone,
              item["text"] as? String == body,
              let status = to[0]["status"] as? String
        else { throw StoreError(message:"The provider response did not match this exact message. Check Telnyx before trying another send.") }
        let state: String
        switch status {
        case "delivered": state = "delivered"
        case "sending_failed", "delivery_failed": state = "failed"
        case "queued", "sending", "sent", "delivery_unconfirmed": state = "accepted"
        default: throw StoreError(message:"Telnyx returned an unfamiliar message status. Check its message log before trying another send.")
        }
        return TelnyxReceipt(id:id,state:state,providerStatus:status,sentAt:timestamp(item["sent_at"]))
    }
}

// Never forward an API credential through a redirect or persist an HTTP cache.
final class TelnyxTransport: NSObject, URLSessionTaskDelegate {
    lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil; c.urlCache = nil; c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 30; c.timeoutIntervalForResource = 40
        return URLSession(configuration:c,delegate:self,delegateQueue:nil)
    }()
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func run(_ request: URLRequest, completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        session.dataTask(with:request) { data,response,error in
            DispatchQueue.main.async { completion(data,response as? HTTPURLResponse,error) }
        }.resume()
    }
}

func runTelnyxMessageTests() throws {
    func check(_ ok: Bool,_ label: String) throws { if !ok { throw StoreError(message:"Telnyx fixture test: "+label) } }
    let id = UUID().uuidString, sender = "+15125550100", recipient = "+15125550101", body = "Sprout fixture."
    func fixture(_ status: String, number: String = "+15125550101", text: String = "Sprout fixture.") throws -> Data {
        try JSONSerialization.data(withJSONObject:["data":["id":id,"direction":"outbound","from":["phone_number":sender],"to":[["phone_number":number,"status":status]],"text":text]])
    }
    let request = try TelnyxMessageAPI.sendRequest(key:"fixture-only",sender:sender,phone:recipient,body:body)
    try check(request.httpMethod == "POST" && request.url?.host == "api.telnyx.com","fixed endpoint")
    let payload = try JSONSerialization.jsonObject(with:request.httpBody!) as! Record
    try check(payload["use_profile_webhooks"] as? Bool == false,"no external callback destinations")
    try check(try TelnyxMessageAPI.receipt(fixture("queued"),sender:sender,phone:recipient,body:body).state == "accepted","queued is not delivered")
    try check(try TelnyxMessageAPI.receipt(fixture("sent"),sender:sender,phone:recipient,body:body).state == "accepted","sent is not delivered")
    try check(try TelnyxMessageAPI.receipt(fixture("delivered"),sender:sender,phone:recipient,body:body,expectedID:id).state == "delivered","exact delivered receipt")
    try check(try TelnyxMessageAPI.receipt(fixture("delivery_failed"),sender:sender,phone:recipient,body:body).state == "failed","failed receipt")
    for data in [try fixture("delivered",number:"+15125550102"),try fixture("delivered",text:"Different text"),try fixture("new_unknown_status")] {
        var rejected = false
        do { _ = try TelnyxMessageAPI.receipt(data,sender:sender,phone:recipient,body:body) } catch { rejected = true }
        try check(rejected,"mismatched or unknown receipt rejected")
    }
    var wrongID = false
    do { _ = try TelnyxMessageAPI.receipt(fixture("delivered"),sender:sender,phone:recipient,body:body,expectedID:UUID().uuidString) } catch { wrongID = true }
    try check(wrongID,"wrong provider ID rejected")
    let sent = "2026-09-20T12:34:56.123Z"
    var dated = try JSONSerialization.jsonObject(with:fixture("delivered")) as! Record
    var item = dated["data"] as! Record; item["sent_at"] = sent; dated["data"] = item
    let datedReceipt = try TelnyxMessageAPI.receipt(JSONSerialization.data(withJSONObject:dated),sender:sender,phone:recipient,body:body)
    try check(datedReceipt.sentAt == TelnyxMessageAPI.timestamp(sent),"delayed delivery keeps actual send timestamp")
    try check(TelnyxMessageAPI.timestamp("not a date") == nil,"invalid timestamp does not become today")
    print("PASS: Telnyx request and exact-recipient/body/ID receipt fixtures; no network requests.")
}
