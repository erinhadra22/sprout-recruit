import Foundation

// One main-thread gate for all enabled reply readers. Individual scan freshness
// is insufficient when another reader completes later; check both together.
final class ReplySyncDispatchGate {
    typealias Scan = (@escaping (Bool)->Void)->Void
    typealias Status = () throws -> Record
    private let gmailScan:Scan, messagesScan:Scan
    private let gmailStatus:Status, messagesStatus:Status
    private let available:()->Bool, clock:()->Date
    private var completion:((Bool)->Void)?
    private var token:UInt64=0,phase:UInt64=0

    init(gmailScan:@escaping Scan,messagesScan:@escaping Scan,gmailStatus:@escaping Status,
         messagesStatus:@escaping Status,available:@escaping ()->Bool,clock:@escaping ()->Date={Date()}) {
        self.gmailScan=gmailScan;self.messagesScan=messagesScan
        self.gmailStatus=gmailStatus;self.messagesStatus=messagesStatus
        self.available=available;self.clock=clock
    }
    func check(completion:@escaping (Bool)->Void) {
        guard self.completion==nil else { completion(false);return }
        token &+= 1;self.completion=completion;attempt(0)
    }
    func cancel() { finish(false) }
    private func finish(_ allowed:Bool) {
        guard let callback=completion else { return }
        completion=nil;token &+= 1;phase &+= 1;callback(allowed)
    }
    private func current(_ run:UInt64,_ expectedPhase:UInt64)->Bool {
        completion != nil && token==run && phase==expectedPhase
    }
    private func attempt(_ number:Int) {
        guard number<3,available() else { finish(false);return }
        do {
            let beforeMessages=try messagesStatus(),beforeGmail=try gmailStatus()
            guard Self.validConfiguration(beforeMessages),Self.validConfiguration(beforeGmail) else { finish(false);return }
            let run=token;phase &+= 1;let gmailPhase=phase
            gmailScan { gmailOK in
                guard self.current(run,gmailPhase) else { return }
                self.phase &+= 1
                guard gmailOK,self.available() else { self.finish(false);return }
                let messagesPhase=self.phase
                self.messagesScan { messagesOK in
                    guard self.current(run,messagesPhase) else { return }
                    self.phase &+= 1
                    guard messagesOK,self.available() else { self.finish(false);return }
                    do {
                        let afterMessages=try self.messagesStatus(),afterGmail=try self.gmailStatus()
                        let pairs=[(beforeMessages,afterMessages),(beforeGmail,afterGmail)]
                        guard pairs.allSatisfy({Self.sameConfiguration($0.0,$0.1)}) else { self.finish(false);return }
                        let now=self.clock()
                        if pairs.allSatisfy({Self.fresh($0.1,at:now)}) { self.finish(true) }
                        else { self.attempt(number+1) }
                    } catch { self.finish(false) }
                }
            }
        } catch { finish(false) }
    }
    private static func validConfiguration(_ state:Record)->Bool { state["enabled"] is Bool && state["generation"] is Int }
    private static func sameConfiguration(_ before:Record,_ after:Record)->Bool {
        validConfiguration(after) && before["generation"] as? Int==after["generation"] as? Int && before["enabled"] as? Bool==after["enabled"] as? Bool
    }
    private static func fresh(_ state:Record,at now:Date)->Bool {
        if state["enabled"] as? Bool==false { return true }
        guard state["status"] as? String=="ready",state["hasMore"] as? Bool != true,let text=state["lastSuccessAt"] as? String else { return false }
        let formatter=ISO8601DateFormatter();formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        guard let time=formatter.date(from:text) ?? ISO8601DateFormatter().date(from:text) else { return false }
        let age=now.timeIntervalSince(time);return age>=0 && age<=5
    }
}
