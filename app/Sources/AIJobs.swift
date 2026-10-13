import Foundation

// Local outbox: creating a job never launches a model or sends a message.
extension Store {
    func prepareAIJob(_ p: Record) throws {
        guard let aid = p["agentId"] as? String, let purpose = p["purpose"] as? String,
              ["text_followup","email_followup","check_in","call_summary"].contains(purpose) else { throw StoreError(message:"Choose an agent and supported AI task.") }
        let agent = try get("agents",aid)
        guard let instruction = p["instruction"] as? String, !instruction.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, instruction.count <= 10000 else { throw StoreError(message:"Add instructions for this draft.") }
        let context = try all("settings").first { $0["id"] as? String == "ai-context" } ?? [:]
        // File paths remain references. Contents are never read or uploaded here.
        let packet: Record = ["agent":agent,"context":context,"instruction":instruction,"purpose":purpose]
        try put("aiJobs",["id":UUID().uuidString,"agentId":aid,"purpose":purpose,"state":"awaiting_connection","adapter":"chatgpt_app_server","packet":packet,"createdAt":Store.now(),"externalProcessing":true,"sent":false])
    }
    func importAIJobResult(_ p: Record) throws {
        guard let id = p["id"] as? String, p["reviewed"] as? Bool == true,
              let body = p["body"] as? String, !body.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, body.count <= 20000,
              let source = p["source"] as? String, !source.isEmpty, source.count <= 500 else { throw StoreError(message:"Review the generated draft and identify its source before saving.") }
        var job = try get("aiJobs",id)
        guard job["state"] as? String != "completed" else { throw StoreError(message:"This result has already been saved.") }
        guard job["purpose"] as? String != "call_summary" else { throw StoreError(message:"Import call analysis through its transcript-linked workflow.") }
        let channel = job["purpose"] as? String == "email_followup" ? "Email" : "Message"
        let draftID = "ai-job-" + id
        try put("drafts",["id":draftID,"agentId":job["agentId"] ?? "","channel":channel,"body":body,"subject":p["subject"] as? String ?? "","state":"draft","source":source,"aiJobId":id,"createdAt":Store.now(),"updatedAt":Store.now()])
        job["state"] = "completed";job["resultSource"] = source;job["draftId"] = draftID;job["completedAt"] = Store.now();try put("aiJobs",job)
    }
}
