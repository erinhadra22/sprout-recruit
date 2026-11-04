import Foundation

func runReplySyncDispatchGateTests() throws {
    func check(_ value:Bool,_ label:String) throws { if !value { throw StoreError(message:"Combined reply gate test: "+label) } }
    final class Fixture {
        var now=Date(timeIntervalSince1970:1_800_000_000),available=true
        var gmail:Record=["enabled":true,"generation":1,"status":"ready","hasMore":false]
        var messages:Record=["enabled":true,"generation":1,"status":"ready","hasMore":false]
        var gmailCallbacks:[(Bool)->Void]=[],messageCallbacks:[(Bool)->Void]=[],results:[Bool]=[]
        var gmailCalls=0,messageCalls=0,failStatus=false
        lazy var gate=ReplySyncDispatchGate(gmailScan:{ callback in self.gmailCalls+=1;self.gmailCallbacks.append(callback) },messagesScan:{ callback in self.messageCalls+=1;self.messageCallbacks.append(callback) },gmailStatus:{ if self.failStatus { throw StoreError(message:"Fixture status failure") };return self.gmail },messagesStatus:{ self.messages },available:{ self.available },clock:{ self.now })
        init() { freshGmail();freshMessages() }
        func stamp()->String { ISO8601DateFormatter().string(from:now) }
        func freshGmail() { gmail["lastSuccessAt"]=stamp() }
        func freshMessages() { messages["lastSuccessAt"]=stamp() }
        func start() { gate.check{self.results.append($0)} }
        func gmailDone(_ ok:Bool=true) { gmailCallbacks.removeFirst()(ok) }
        func messagesDone(_ ok:Bool=true) { messageCallbacks.removeFirst()(ok) }
    }
    let fresh=Fixture();fresh.start();fresh.gmailDone();fresh.messagesDone()
    try check(fresh.results==[true] && fresh.gmailCalls==1 && fresh.messageCalls==1,"both fresh readers grant exactly once")

    let staleMessages=Fixture();staleMessages.start();staleMessages.now.addTimeInterval(30);staleMessages.freshGmail();staleMessages.gmailDone()
    try check(staleMessages.results.isEmpty && staleMessages.messageCalls==1,"long Gmail wait still requires Messages scan afterward")
    staleMessages.messagesDone()
    try check(staleMessages.results.isEmpty && staleMessages.gmailCalls==2,"a stale Messages success cannot pass the joint check")
    staleMessages.freshGmail();staleMessages.gmailDone();staleMessages.freshMessages();staleMessages.messagesDone()
    try check(staleMessages.results==[true],"refreshing stale Messages permits one final grant")

    let staleGmail=Fixture();staleGmail.start();staleGmail.gmailDone();staleGmail.now.addTimeInterval(30);staleGmail.freshMessages();staleGmail.messagesDone()
    try check(staleGmail.results.isEmpty && staleGmail.gmailCalls==2,"long Messages wait cannot leave Gmail's older grant valid")
    staleGmail.freshGmail();staleGmail.gmailDone();staleGmail.freshMessages();staleGmail.messagesDone()
    try check(staleGmail.results==[true],"both are rechecked at one final instant")

    for source in ["gmail","messages"] {
        let changed=Fixture();changed.start();changed.gmailDone()
        if source=="gmail" { changed.gmail["generation"]=2 } else { changed.messages["generation"]=2 }
        changed.messagesDone();try check(changed.results==[false] && changed.gmailCalls==1,"configuration generation change fails closed")
        let disabled=Fixture();disabled.start();disabled.gmailDone()
        if source=="gmail" { disabled.gmail["enabled"]=false } else { disabled.messages["enabled"]=false }
        disabled.messagesDone();try check(disabled.results==[false],"changing enabled state during a check cancels its grant")
    }
    let off=Fixture();off.gmail=["enabled":false,"generation":0];off.messages=["enabled":false,"generation":0]
    off.start();off.gmailDone();off.messagesDone();try check(off.results==[true],"explicitly disabled readers do not require unavailable history")
    let gmailFailure=Fixture();gmailFailure.start();gmailFailure.gmailDone(false)
    try check(gmailFailure.results==[false] && gmailFailure.messageCalls==0,"Gmail failure prevents a subsequent reader or grant")
    let messagesFailure=Fixture();messagesFailure.start();messagesFailure.gmailDone();messagesFailure.messagesDone(false)
    try check(messagesFailure.results==[false],"Messages failure fails closed")
    let busy=Fixture();busy.available=false;busy.start();try check(busy.results==[false] && busy.gmailCalls==0,"busy Store prevents starting a gate")
    let laterBusy=Fixture();laterBusy.start();laterBusy.gmailDone();laterBusy.available=false;laterBusy.messagesDone()
    try check(laterBusy.results==[false],"workspace ownership must remain available at dispatch")
    let unavailable=Fixture();unavailable.failStatus=true;unavailable.start()
    try check(unavailable.results==[false] && unavailable.gmailCalls==0,"status read errors fail without scanning")

    let cancelled=Fixture();cancelled.start();let late=cancelled.gmailCallbacks.removeFirst();cancelled.gate.cancel();cancelled.gate.cancel();late(true);late(false)
    try check(cancelled.results==[false] && cancelled.messageCalls==0,"cancel and late or duplicate scan callbacks complete only once")
    cancelled.start();late(true);cancelled.gmailDone();cancelled.messagesDone()
    try check(cancelled.results==[false,true],"a late callback from the canceled run cannot corrupt a new run")
    let duplicate=Fixture();duplicate.start();let gmailCallback=duplicate.gmailCallbacks.removeFirst();gmailCallback(true);gmailCallback(false)
    let messageCallback=duplicate.messageCallbacks.removeFirst();messageCallback(true);messageCallback(false)
    try check(duplicate.results==[true] && duplicate.messageCalls==1,"duplicate reader callbacks cannot alter a completed grant")
    let overlap=Fixture();overlap.start();var second:[Bool]=[];overlap.gate.check{second.append($0)}
    overlap.gmailDone();overlap.messagesDone();try check(second==[false] && overlap.results==[true],"overlapping callers cannot replace an in-flight completion")

    for badState:Record in [["status":"blocked"],["hasMore":true],["lastSuccessAt":"not-a-time"],["lastSuccessAt":ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:1_800_000_100))]] {
        let neverFresh=Fixture();for (key,value) in badState { neverFresh.gmail[key]=value };neverFresh.start()
        for _ in 0..<3 { neverFresh.gmailDone();neverFresh.messagesDone() }
        try check(neverFresh.results==[false] && neverFresh.gmailCalls==3 && neverFresh.messageCalls==3,"blocked, partial, invalid or future coverage is bounded to three attempts")
    }
    print("PASS: combined Gmail/Messages gate joint freshness, cross-reader delays, configuration changes, failures, cancellation, callback uniqueness and bounded retries; pure fixtures only.")
}
