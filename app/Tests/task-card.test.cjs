'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const root=path.join(__dirname,'../Web');
const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function appContext(){
 const source=fs.readFileSync(path.join(root,'app.js'),'utf8');
 const prefix=source.slice(0,source.indexOf("document.addEventListener('click'"));
 const context=vm.createContext({Model:{escape:esc,money:()=>'',date:x=>x,dateTime:x=>x,tasks:tasks=>tasks},CommunicationsUI:{allowed:a=>!!a?.communicationVerification,canVerify:a=>a?.datasetId==='live',directSMSAvailable:()=>false},CSVImportUI:{},ContextUI:{},PerformanceUI:{},WorkflowUI:{},icon:()=>'',document:{getElementById:()=>({})},window:{},console});
 for(const file of ['task-controls.js','weekly-reports.js','sourcing-rules.js','meetings.js'])vm.runInContext(fs.readFileSync(path.join(root,file),'utf8'),context);
 vm.runInContext(prefix+';globalThis.__renderTaskDetail=taskDetail;globalThis.__renderTimeline=renderTimeline;globalThis.__taskCardActions=taskCardActions;',context);
 vm.runInContext('modal=(title,body,kind,footer)=>{globalThis.__captured={title,body,footer}}',context);
 return context;
}
test('meeting-response review tasks and accepted-meeting pauses use specific labels',()=>{
 const c=appContext();c.__fixture={agents:[{id:'agent-1',name:'Morgan Example'}],drafts:[],tasks:[{id:'meeting-review',agentId:'agent-1',type:'Review',title:'Review meeting response — Morgan Example',reviewKind:'gmail-sync-meeting-response',description:'Review the accepted invitation before resuming outreach.',sourceRefs:['gmail:recruiter@example.com:1a18d92434a91d59'],relatedMessageIds:['1a18d92434a91d59'],dueDate:'2026-10-30',priority:'High',repeatDays:0},{id:'follow-up',agentId:'agent-1',type:'Check-in',title:'Follow up with Morgan',description:'Check the meeting details.',followUpState:'paused_reply',pauseReason:'meeting_accepted',dueDate:'2026-10-30',priority:'Medium',repeatDays:0}],today:'2026-10-30'};vm.runInContext('D=globalThis.__fixture',c);
 c.__renderTaskDetail('meeting-review');assert.match(c.__captured.body,/<h3>Review category<\/h3><p>Meeting response<\/p>/);assert.match(c.__captured.body,/1a18d92434a91d59/);assert.doesNotMatch(c.__captured.body,/>gmail-sync-meeting-response</);assert.match(c.__captured.body,/does not send a message or authorize an external action/);
 c.__renderTaskDetail('follow-up');assert.match(c.__captured.body,/Paused · meeting acceptance needs review/);assert.doesNotMatch(c.__captured.body,/Paused · reply needs review/);c.__fixture.tasks[1].pauseReason='inbound_reply';c.__renderTaskDetail('follow-up');assert.match(c.__captured.body,/Paused · reply needs review/);
});
test('synced Messages reply appears once in the candidate timeline with a review action and honest pause state',()=>{
 const c=appContext();
 c.__fixture={agents:[{id:'a',name:'Candidate'},{id:'b',name:'Other'}],activities:[{id:'note',agentId:'a',kind:'note',title:'Earlier note',date:'2026-10-28T20:00:00Z'}],drafts:[],tasks:[],communications:[],messagesSync:{enabled:true},externalMessages:[
  {id:'reply',agentId:'a',channel:'Message',provider:'apple-messages',direction:'inbound',from:'+15125550000',occurredAt:'2026-10-28T20:01:00Z',body:'Yes <please> & thanks',providerMessageId:'actual-guid',providerThreadId:'actual-chat',accountScope:'local-messages',bodyKind:'text',followUpsPaused:true,reviewTaskId:'review-reply'},
  {id:'other',agentId:'b',channel:'Message',direction:'inbound',body:'Private other reply',occurredAt:'2026-10-28T20:02:00Z'}]};
 vm.runInContext('D=globalThis.__fixture;S.activityKind="All"',c);
 const html=c.__renderTimeline('a');
 assert.equal((html.match(/Text reply received/g)||[]).length,1);
 assert.match(html,/Yes &lt;please&gt; &amp; thanks/);
 assert.match(html,/Follow-ups paused for review/);
 assert.match(html,/data-action="task-detail"[^>]*data-id="review-reply"/);
 assert.ok(html.indexOf('Text reply received')<html.indexOf('Earlier note'));
 assert.doesNotMatch(html,/Private other reply|Apple Messages are not automatically synced/);
 vm.runInContext('S.activityKind="message"',c);
 assert.doesNotMatch(c.__renderTimeline('a'),/Earlier note/);
 c.__fixture.externalMessages[0].followUpsPaused=false;
 assert.doesNotMatch(c.__renderTimeline('a'),/Follow-ups paused for review/);
});
test('linked message task exposes exact draft without requiring the operator to verify the phone',()=>{
 const c=appContext();
 c.D={agents:[{id:'agent-1',name:'Morgan Example',phone:'+15125550000',source:'Courted',datasetId:'live'}],drafts:[{id:'draft-1',agentId:'agent-1',channel:'Message',state:'draft',body:'Hello Morgan'}],tasks:[{id:'task-1',agentId:'agent-1',type:'Message',draftId:'draft-1',draftBody:'Hello Morgan',title:'Review unsent draft',dueDate:'2026-10-14',priority:'Medium',repeatDays:0}]};
 c.__fixture=c.D;vm.runInContext('D=globalThis.__fixture',c);
 c.__renderTaskDetail('task-1');
 assert.match(c.__captured.body,/Morgan Example/);
 assert.match(c.__captured.body,/\+15125550000/);
 assert.match(c.__captured.body,/Hello Morgan/);
 assert.doesNotMatch(c.__captured.footer,/Verify contact and phone/);
 assert.doesNotMatch(c.__captured.footer,/Review send in Messages/);
 c.D.agents[0].communicationVerification={name:'Morgan Example',phone:'+15125550000',source:'Courted',confirmed:true,reviewedAt:'now'};
 c.__renderTaskDetail('task-1');
 assert.doesNotMatch(c.__captured.footer,/Review send in Messages/);
 c.CommunicationsUI.directSMSAvailable=()=>true;c.__renderTaskDetail('task-1');
 assert.match(c.__captured.footer,/Review direct SMS/);
 c.D.drafts[0].body='Changed text';
 c.__renderTaskDetail('task-1');
 assert.match(c.__captured.body,/changed or is unavailable/);
 assert.doesNotMatch(c.__captured.footer,/Review send in Messages/);
});
test('saved draft activity opens its linked review task',()=>{
 const c=appContext();
 c.__fixture={agents:[{id:'agent-1',name:'Taylor Example'}],activities:[{id:'activity-1',agentId:'agent-1',kind:'draft',title:'Message draft saved — not sent',body:'Hello Taylor',date:'2026-10-12T19:00:00Z',author:'Test Operator',pinned:false,draftId:'draft-1'}],drafts:[{id:'draft-1',agentId:'agent-1',channel:'Message',state:'draft',body:'Hello Taylor'}],tasks:[{id:'task-1',agentId:'agent-1',type:'Message',draftId:'draft-1',draftBody:'Hello Taylor'}],communications:[],externalMessages:[]};
 vm.runInContext('D=globalThis.__fixture;S.activityKind="All"',c);
 const html=c.__renderTimeline('agent-1');
 assert.match(html,/data-action="task-detail" data-id="task-1"/);
 assert.match(html,/Open draft/);
});
test('verified imported emails appear once in the contact activity log with complete escaped bodies',()=>{
 const c=appContext();
 c.__fixture={agents:[{id:'agent-1',name:'Robert Example'},{id:'agent-2',name:'Other Contact'}],activities:[{id:'status-1',agentId:'agent-1',kind:'status',title:'Not interested',body:'Status updated',date:'2026-10-12T18:00:00Z',author:'Erin',pinned:false}],drafts:[],tasks:[],communications:[],externalMessages:[
  {id:'external-sent',agentId:'agent-1',channel:'Email',provider:'gmail',direction:'outbound',from:'erin@example.com',to:'robert@example.com',subject:'A quick introduction',body:'Hi Robert,\n\nI am Erin.\nSecond paragraph.',occurredAt:'2026-10-12T16:00:00Z',providerMessageId:'gmail-sent-1',providerThreadId:'thread-1'},
  {id:'external-reply',agentId:'agent-1',channel:'Email',provider:'gmail',direction:'inbound',from:'robert@example.com',to:'erin@example.com',subject:'Re: A quick introduction',body:'Thanks Erin, <not moving> & staying put.',occurredAt:'2026-10-12T19:00:00Z',providerMessageId:'gmail-reply-1',providerThreadId:'thread-1'},
  {id:'external-other',agentId:'agent-2',channel:'Email',provider:'gmail',direction:'outbound',from:'erin@example.com',to:'other@example.com',subject:'Hello',body:'Unrelated private email',occurredAt:'2026-10-12T20:00:00Z',providerMessageId:'gmail-other-1',providerThreadId:'thread-2'}]};
 vm.runInContext('D=globalThis.__fixture;S.activityKind="All"',c);
 const html=c.__renderTimeline('agent-1');
 assert.match(html,/3 activities/);
 assert.match(html,/Email received · Re: A quick introduction/);
 assert.match(html,/Email sent · saved history · A quick introduction/);
 assert.ok(html.indexOf('Email received')<html.indexOf('Not interested')&&html.indexOf('Not interested')<html.indexOf('Email sent'));
 assert.match(html,/Hi Robert,\n\nI am Erin\.\nSecond paragraph\./);
 assert.match(html,/Thanks Erin, &lt;not moving&gt; &amp; staying put\./);
 assert.match(html,/Message ID: gmail-reply-1 · Thread ID: thread-1/);
 assert.doesNotMatch(html,/Unrelated private email|Imported correspondence|data-id="external-reply"/);
 const globalHtml=c.__renderTimeline();
 assert.match(globalHtml,/4 activities/);
 assert.match(globalHtml,/Other Contact ·/);
 assert.match(globalHtml,/Unrelated private email/);
 vm.runInContext('S.activityKind="email"',c);
 assert.match(c.__renderTimeline('agent-1'),/2 activities/);
 assert.doesNotMatch(c.__renderTimeline('agent-1'),/Status updated/);
});
test('imported contact requires exact persisted identity and destination',()=>{
 const source=fs.readFileSync(path.join(root,'communications.js'),'utf8');
 const c=vm.createContext({console});vm.runInContext(source+';globalThis.__ui=CommunicationsUI',c);
 const a={name:'Morgan Example',phone:'+15125550000',source:'Courted',datasetId:'live',manual:false,status:'Identified'};
 assert.equal(c.__ui.allowed(a),false);
 a.communicationVerification={name:a.name,phone:a.phone,source:a.source,confirmed:true,reviewedAt:'now'};
 assert.equal(c.__ui.allowed(a),true);
 a.phone='+15125550001';assert.equal(c.__ui.allowed(a),false);
 a.phone='+15125550000';a.status='Do not contact';assert.equal(c.__ui.allowed(a),false);
});
test('verified sent draft shows receipt timestamp and removes message send actions',()=>{
 const c=appContext();
 c.__fixture={agents:[{id:'agent-1',name:'Morgan Example',phone:'+15125550000',communicationVerification:{confirmed:true}}],drafts:[{id:'draft-1',agentId:'agent-1',channel:'Message',state:'sent',body:'Hello Morgan',sentAt:'2026-10-12T19:35:00Z',sentOn:'2026-10-12',communicationId:'receipt-1'}],tasks:[{id:'task-1',agentId:'agent-1',type:'Message',draftId:'draft-1',draftBody:'Hello Morgan',title:'Message sent — review outcome',dueDate:'2026-10-14',priority:'Medium',completed:false}],communications:[{id:'receipt-1',agentId:'agent-1',phone:'+15125550000'}]};
 vm.runInContext('D=globalThis.__fixture',c);
 c.CommunicationsUI.directSMSAvailable=()=>true;
 c.__renderTaskDetail('task-1');
 assert.match(c.__captured.body,/Saved sent message/);
 assert.match(c.__captured.body,/2026-10-12T19:35:00Z/);
 assert.doesNotMatch(c.__captured.body,/Unsent message draft/);
 assert.doesNotMatch(c.__captured.footer,/Review send in Messages|Review direct SMS/);
 assert.match(c.__captured.footer,/Mark complete/);
 assert.doesNotMatch(c.__taskCardActions(c.__fixture.tasks[0],c.__fixture.agents[0]),/Review message/);
});
test('review task card shows instructions and exact references without granting approval',()=>{
 const c=appContext();
 c.__fixture={agents:[{id:'agent-1',name:'Trinity Example'}],drafts:[],tasks:[{id:'review-1',agentId:'agent-1',type:'Review',title:'Review ambiguous reply',description:'Check the reply before changing status.',reviewKind:'Reply classification',reviewInstructions:'Decide whether this is a decline.',decisionOptions:['Mark not interested','Keep on hold'],sourceRefs:['https://example.com/reply?a=1&b=2'],relatedMessageIds:['gmail-msg-123'],dueDate:'2026-10-23',priority:'High',repeatDays:0}]};
 vm.runInContext('D=globalThis.__fixture',c);
 c.__renderTaskDetail('review-1');
 const html=c.__captured.body;
 assert.match(html,/Instructions for Erin/);
 assert.match(html,/Decide whether this is a decline/);
 assert.match(html,/Reply classification/);
 assert.match(html,/Mark not interested/);
 assert.match(html,/gmail-msg-123/);
 assert.match(html,/example\.com\/reply\?a=1&amp;b=2/);
 assert.match(html,/does not send a message or authorize an external action/);
 assert.doesNotMatch(c.__captured.footer,/Approve|Send/);
 const form=vm.runInContext('taskFields(globalThis.__fixture.tasks[0])',c);
 assert.match(form,/selected value="Review"/);
 assert.match(form,/name="reviewInstructions"/);
 assert.match(form,/name="relatedMessageIdsText"/);
});
test('review task metadata is parsed into bounded arrays',()=>{
 const c=appContext();
 const p=vm.runInContext('taskPayload({type:"Approval",title:"Review address",sourceRefsText:" https://example.com/a \\n\\n https://example.com/b ",relatedMessageIdsText:"msg-1\\nmsg-2",decisionOptionsText:"Approve\\nReject"})',c);
 assert.equal(p.type,'Approval');
 assert.deepEqual(Array.from(p.sourceRefs),['https://example.com/a','https://example.com/b']);
 assert.deepEqual(Array.from(p.relatedMessageIds),['msg-1','msg-2']);
 assert.deepEqual(Array.from(p.decisionOptions),['Approve','Reject']);
 assert.throws(()=>vm.runInContext('taskLines("x\\n".repeat(21),20,500)',c),/Use up to 20 lines/);
});
test('general review tasks can be created and viewed without a linked contact',()=>{
 const c=appContext();
 c.__fixture={agents:[{id:'agent-1',name:'Morgan Example'}],drafts:[],tasks:[{id:'general-1',type:'Review',title:'Review unresolved account issue',description:'Choose the next step.',reviewInstructions:'Check the source evidence.',dueDate:'2026-10-23',priority:'High',repeatDays:0,completed:false}],today:'2026-10-23'};
 vm.runInContext('D=globalThis.__fixture',c);
 vm.runInContext('taskForm()',c);
 assert.match(c.__captured.body,/<option value="" selected>General workspace task<\/option>/);
 assert.match(c.__captured.body,/<option selected value="Review">Review<\/option>/);
 c.__renderTaskDetail('general-1');
 assert.match(c.__captured.body,/General workspace · Review/);
 assert.doesNotMatch(c.__captured.footer,/View contact/);
 const list=vm.runInContext('renderTasks()',c);
 assert.match(list,/General workspace<\/span>/);
 assert.doesNotMatch(list,/data-action="profile" data-id="undefined"/);
 const mini=vm.runInContext('taskMini(globalThis.__fixture.tasks[0])',c);
 assert.match(mini,/General workspace task/);
});

test('message task embeds the real inline editor and queue action',()=>{
 const c=appContext();
 vm.runInContext(fs.readFileSync(path.join(root,'outbox.js'),'utf8'),c);
 c.__fixture={agents:[{id:'agent-1',name:'Morgan',phone:'+15125550100',manual:true,source:'Manual contact'}],drafts:[{id:'draft-1',agentId:'agent-1',channel:'Message',state:'draft',body:'Exact saved text'}],tasks:[{id:'task-1',agentId:'agent-1',type:'Message',draftId:'draft-1',draftBody:'Exact saved text',dueDate:'2026-10-28'}],settings:[{id:'imessage',enabled:true,accountId:'test'}]};
 vm.runInContext('D=globalThis.__fixture;OutboxUI.bind({getData:()=>D})',c);
 c.__renderTaskDetail('task-1');
 assert.match(c.__captured.body,/data-outbox-body="draft-1"/);
 assert.match(c.__captured.body,/Exact saved text/);
 assert.match(c.__captured.body,/data-action="outbox-send"/);
 assert.doesNotMatch(c.__captured.footer,/comm-task-message/);
});

test('Review message task CTA opens the inline workbench instead of the legacy handoff',async()=>{
 const c=appContext();
 vm.runInContext(fs.readFileSync(path.join(root,'outbox.js'),'utf8'),c);
 c.__fixture={agents:[{id:'agent-1',name:'Morgan',phone:'+15125550100',manual:true,source:'Manual contact',communicationVerification:{confirmed:true}}],drafts:[{id:'draft-1',agentId:'agent-1',channel:'Message',state:'draft',body:'Exact saved text'}],tasks:[{id:'task-1',agentId:'agent-1',type:'Message',draftId:'draft-1',draftBody:'Exact saved text',dueDate:'2026-10-28'}],settings:[{id:'workspace',name:'Test Operator'},{id:'imessage',enabled:true,accountId:'test',service:'SMS'}]};
 vm.runInContext('D=globalThis.__fixture;OutboxUI.bind({getData:()=>D})',c);
 let refreshes=0;
 c.CommunicationsUI.refreshStatus=async()=>{refreshes++;};
 c.CommunicationsUI.handleAction=()=>{throw Error('Legacy message handoff must not open.');};
 const [task,agent]=[c.__fixture.tasks[0],c.__fixture.agents[0]];
 const button=c.__taskCardActions(task,agent).match(/<button\b([^>]*)>Review message<\/button>/);
 assert.ok(button,'saved Message draft exposes the review action');
 c.__button={action:button[1].match(/data-action="([^"]+)"/)[1],id:button[1].match(/data-id="([^"]+)"/)[1]};
 await vm.runInContext('handleAction({dataset:globalThis.__button})',c);
 assert.equal(refreshes,1);
 assert.match(c.__captured.body,/data-outbox-body="draft-1"/);
 assert.match(c.__captured.body,/Exact saved text/);
 assert.match(c.__captured.body,/data-action="outbox-send"/);
 c.__fixture.drafts[0].channel='Email';
 assert.doesNotMatch(c.__taskCardActions(task,agent),/Review message/);
 assert.match(c.__taskCardActions(task,agent),/data-action="task-detail"/);
});

test('opening a global outbox notification preserves an unsaved modal',()=>{
 const c=appContext();
 c.document.getElementById=()=>({children:[{}]});
 vm.runInContext('requestCloseModal=()=>false;closeModal=()=>{globalThis.closed=true};navigate=()=>{globalThis.navigated=true};showOutbox("job-1")',c);
 assert.equal(c.closed,undefined);assert.equal(c.navigated,undefined);
});
