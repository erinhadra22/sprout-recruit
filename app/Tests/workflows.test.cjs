const test=require('node:test'),assert=require('node:assert/strict');
const W=require('../Web/workflows.js');
test('workflow rendering escapes source transcript, contact and draft text',()=>{
 const html=W.render('workflows',{agents:[{id:'a',name:'<script>bad</script>'}],workflows:[{id:'w',agentId:'a',outcome:'connected',state:'waiting_for_transcript',notes:'<img onerror=bad>',recordingState:'unavailable',transcriptState:'unavailable'}],drafts:[{id:'d',agentId:'a',workflowId:'w',body:'<script>send()</script>',approvalState:'pending_review'}]});
 assert(!html.includes('<script>'));assert(html.includes('&lt;script&gt;'));assert(html.includes('Waiting for transcript'));assert(!html.includes('data-action="workflow-generate"'));
});
test('review approval is withheld after reply, rejection or DNC',()=>{for(const state of ['paused_reply','rejected','approved','blocked_contact'])assert.equal(W.canApprove({approvalState:state},{status:'Identified'}),false);assert.equal(W.canApprove({approvalState:'pending_review'},{status:'Do not contact'}),false);assert.equal(W.canApprove({approvalState:'pending_review'},{status:'Called'}),true);});
test('sequence page states real local execution boundary',()=>{const html=W.render('sequences',{agents:[],sequences:[]});assert(html.includes('do not send'));assert(html.includes('app is closed'));assert(html.includes('Check due steps'));});
test('sequence variants show selected option, instructions and escaped references',()=>{
 const html=W.render('sequences',{agents:[{id:'a',name:'Agent'}],sequences:[{id:'s',agentId:'a',name:'Follow-up',state:'active',completedSteps:[],steps:[{channel:'Email',delayDays:2,selectedVariantId:'B',variants:[{id:'A',label:'Warm',body:'Hello',instructions:'Be warm',references:[]},{id:'B',label:'Direct',body:'Hi',instructions:'Be brief',references:['<script>'] }]}]}]});
 assert(html.includes('Selected variant: Direct'));assert(html.includes('Instructions: Be brief'));assert(html.includes('&lt;script&gt;'));assert(!html.includes('<script>'));assert(html.includes('Edit future steps'));
});
test('queue count excludes unrelated and already reviewed drafts',()=>assert.deepEqual(W.counts({workflows:[{}],drafts:[{workflowId:'w',approvalState:'pending_review'},{approvalState:'pending_review'},{sequenceId:'s',approvalState:'rejected'}],sequences:[{state:'paused'}]}),{calls:1,review:1,paused:1}));
