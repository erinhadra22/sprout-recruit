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
 const context=vm.createContext({Model:{escape:esc,money:()=>'',date:x=>x,dateTime:x=>x},CommunicationsUI:{allowed:a=>!!a?.communicationVerification,canVerify:a=>a?.datasetId==='live',directSMSAvailable:()=>false},CSVImportUI:{},ContextUI:{},PerformanceUI:{},WorkflowUI:{},icon:()=>'',document:{getElementById:()=>({})},window:{},console});
 vm.runInContext(prefix+';globalThis.__renderTaskDetail=taskDetail;globalThis.__renderTimeline=renderTimeline;globalThis.__taskCardActions=taskCardActions;',context);
 vm.runInContext('modal=(title,body,kind,footer)=>{globalThis.__captured={title,body,footer}}',context);
 return context;
}
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
 assert.match(c.__captured.footer,/Review send in Messages/);
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
 assert.match(html,/Email sent · A quick introduction/);
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
