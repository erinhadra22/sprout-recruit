import Foundation

func runWorkflowTests() throws {
    let dir=FileManager.default.temporaryDirectory.appendingPathComponent("sprout-workflows-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:dir) }
    let s=try Store(path:dir.appendingPathComponent("fixture.sqlite").path,seed:false)
    func check(_ value: Bool,_ message: String) throws { if !value { throw StoreError(message:"Workflow test: "+message) } }
    func reject(_ action: String,_ payload: Record) throws {
        do { _=try s.command(action,payload) } catch is StoreError { return }; throw StoreError(message:"Workflow test expected rejection: "+action)
    }
    for (id,status) in [("a","Identified"),("advanced","Meeting held"),("dnc","Do not contact"),("noanswer","Identified")] {
        try s.put("agents",["id":id,"name":"Fixture","manual":true,"status":status])
    }
    func call(_ id: String,_ aid: String,_ outcome: String="connected") -> Record { ["eventId":"event-"+id,"callId":id,"agentId":aid,"source":"user_confirmed","confirmed":true,"outcome":outcome,"occurredOn":Store.day()] }
    let first=call("one","a")
    var untrusted=first;untrusted["source"]="provider";try reject("workflow.call",untrusted)
    _=try s.command("workflow.call",first);_=try s.command("workflow.call",first)
    try check(try s.all("workflows").count == 1,"duplicate call is idempotent")
    try check(try s.all("activities").count == 1,"duplicate call does not duplicate interaction")
    try check(try s.get("agents","a")["status"] as? String == "Called","early status advances to Called")
    var conflict=first;conflict["outcome"]="failed";try reject("workflow.call",conflict)
    for aid in ["advanced","dnc"] { _=try s.command("workflow.call",call(aid,aid)) }
    try check(try s.get("agents","advanced")["status"] as? String == "Meeting held","advanced stage preserved")
    try check(try s.get("agents","dnc")["status"] as? String == "Do not contact","DNC preserved")
    _=try s.command("workflow.call",call("none","noanswer","no_answer"))
    try check(try s.get("agents","noanswer")["status"] as? String == "Identified","no answer is not a connected call")
    let transcript="Erin: Could we follow up Friday? Agent: Yes, send a brief text Friday."
    let artifact: Record=["eventId":"transcript-one","workflowId":"call-one","callId":"one","source":"user_transcript","confirmed":true,"kind":"transcript_ready","sourceRef":"Fixture transcript","transcript":transcript]
    var outOfOrder=artifact;outOfOrder["workflowId"]="call-unknown";outOfOrder["eventId"]="early";try reject("workflow.artifact",outOfOrder)
    var noAnswer=artifact;noAnswer["workflowId"]="call-none";noAnswer["callId"]="none";try reject("workflow.artifact",noAnswer)
    var result: Record=["eventId":"result-one","workflowId":"call-one","transcriptHash":WorkflowValidation.transcriptHash(transcript),"contextRevision":0,"model":"fixture-local","summary":"The agent agreed to a Friday follow-up text.","evidenceQuotes":["Yes, send a brief text Friday."],"nextSteps":[["title":"Review Friday follow-up","dueDate":Store.day(),"evidenceQuote":"Yes, send a brief text Friday."]],"textDraft":"Thank you for speaking with me. I will follow up Friday.","emailDraft":"Thanks for the conversation."]
    try reject("workflow.result",result)
    try check(try s.all("drafts").isEmpty,"missing transcript never generates draft")
    _=try s.command("workflow.artifact",artifact);_=try s.command("workflow.artifact",artifact)
    var mismatch=artifact;mismatch["eventId"]="wrong-call";mismatch["callId"]="other";try reject("workflow.artifact",mismatch)
    // A failed model pass leaves the transcript intact for a later valid result.
    try s.recordWorkflowArtifact(["eventId":"ai-failed","workflowId":"call-one","callId":"one","source":"local_model","kind":"ai_failed","sourceRef":"fixture job","error":"Fixture model unavailable"],trustedProvider:true)
    try check(try s.get("workflows","call-one")["summaryState"] as? String == "failed","AI failure visible")
    var bad=result;bad["nextSteps"]=[["title":"Valid first step","dueDate":Store.day(),"evidenceQuote":"Yes, send a brief text Friday."],["title":"Bad step","dueDate":"bad-date","evidenceQuote":"Invented promise"]]
    try reject("workflow.result",bad)
    try check(try s.all("tasks").isEmpty && s.all("drafts").isEmpty,"partial invalid result leaves no partial outputs")
    bad=result;bad["evidenceQuotes"]=["I want to join Sprout"];try reject("workflow.result",bad)
    _=try s.command("workflow.result",result);_=try s.command("workflow.result",result)
    try check(try s.all("tasks").count == 3 && s.all("drafts").count == 2,
              "one result yields its suggested task and two draft review tasks")
    result["eventId"]="other-result";try reject("workflow.result",result)
    let draft=try s.get("drafts","call-one-textDraft")
    var review: Record=["eventId":"reject-draft","draftId":"call-one-textDraft","body":draft["body"]!,"decision":"rejected","confirmed":true]
    _=try s.command("workflow.review",review);_=try s.command("workflow.review",review)
    review["eventId"]="approve-rejected";review["decision"]="approved";try reject("workflow.review",review)
    try check(try s.get("drafts","call-one-textDraft")["state"] as? String == "draft","review never marks sent")
    let seq: Record=["eventId":"seq-create","id":"seq-one","agentId":"a","name":"Fixture sequence","confirmed":true,"steps":[["delayDays":0,"channel":"Message","body":"First fixture draft"],["delayDays":0,"channel":"Email","body":"Second fixture draft"]]]
    _=try s.command("sequence.save",seq);_=try s.command("sequence.save",seq)
    _=try s.command("sequence.evaluate",[:])
    try check(try s.all("drafts").count == 3,"one due step at a time")
    let reply: Record=["eventId":"reply-one","agentId":"a","kind":"inbound_reply","confirmed":true]
    _=try s.command("sequence.event",reply);_=try s.command("sequence.event",reply);_=try s.command("sequence.evaluate",[:])
    try check(try s.all("drafts").count == 3,"reply pauses future steps")
    try check(try s.get("drafts","seq-one-step-0")["approvalState"] as? String == "paused_reply","reply also pauses prepared draft")
    review=["eventId":"approve-paused","draftId":"seq-one-step-0","body":"First fixture draft","decision":"approved","confirmed":true];try reject("workflow.review",review)
    _=try s.command("sequence.event",["eventId":"resume-one","agentId":"a","kind":"resume","confirmed":true]);_=try s.command("sequence.evaluate",[:]);_=try s.command("sequence.evaluate",[:])
    try check(try s.all("drafts").count == 4,"resume generates remaining step once")
    let optionA: Record=["id":"A","label":"Question","body":"How is your market changing?","instructions":"Open with a question.","references":["https://example.test/source-a"]]
    let optionB: Record=["id":"B","label":"Direct","body":"I would welcome a conversation.","instructions":"Keep it brief.","references":["https://example.test/source-b"]]
    let variantStep: Record=["delayDays":0,"channel":"Email","variants":[optionA,optionB]]
    let variantSequence: Record=["eventId":"seq-variants","id":"seq-variants","agentId":"noanswer","name":"Variant fixture","confirmed":true,"steps":[variantStep]]
    _=try s.command("sequence.save",variantSequence)
    let savedSequence=try s.get("sequences","seq-variants")
    let chosen=(savedSequence["steps"] as! [Record])[0]["selectedVariantId"] as? String
    try check(["A","B"].contains(chosen ?? ""),"one stable variant assigned")
    var changedStep=variantStep;var changedA=optionA;changedA["instructions"]="Ask one grounded question.";changedStep["variants"]=[changedA,optionB]
    let update: Record=["eventId":"seq-variants-edit","id":"seq-variants","name":"Variant fixture edited","confirmed":true,"steps":[changedStep]]
    _=try s.command("sequence.update",update);_=try s.command("sequence.update",update)
    try check(try s.get("sequences","seq-variants")["name"] as? String == "Variant fixture edited","future step instructions editable")
    _=try s.command("sequence.evaluate",[:])
    let prepared=try s.get("drafts","seq-variants-step-0")
    let expected=chosen == "A" ? "How is your market changing?" : "I would welcome a conversation."
    try check(prepared["body"] as? String == expected && prepared["variantId"] as? String == chosen,"draft uses assigned variant")
    try check((prepared["variantReferences"] as? [String])?.count == 1,"draft retains variant reference")
    var lateEdit=update;lateEdit["eventId"]="seq-variants-late";try reject("sequence.update",lateEdit)
    var invalidVariant=variantSequence;invalidVariant["eventId"]="seq-variants-invalid";invalidVariant["id"]="seq-variants-invalid";invalidVariant["steps"]=[["delayDays":0,"channel":"Message","variants":[optionA,optionB,optionA,optionB,optionA,optionB]]]
    try reject("sequence.save",invalidVariant)
    let reopened=try Store(path:dir.appendingPathComponent("fixture.sqlite").path,seed:false)
    try check(try reopened.all("drafts").count == 5,"workflow outputs persist on reopen")
    print("Workflow tests passed: replay, trust, ordering, no answer, missing transcript, atomic validation, rejection, reply pause, resume, variants, persistence")
}
