'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const path=require('node:path');
const source=fs.readFileSync(path.join(__dirname,'../Web/outbox.js'),'utf8');
const clone=x=>JSON.parse(JSON.stringify(x));
function fixture(){return {settings:[{id:'imessage',enabled:true,accountId:'account-1',accountLabel:'Messages default sending identity'}],agents:[{id:'a1',name:'Morgan Example',phone:'+15125550101',manual:true,status:'Identified',source:'Manual'}],drafts:[{id:'d1',agentId:'a1',state:'draft',channel:'Message',body:'Hello Morgan.\nCan we talk?',updatedAt:'2026-10-28T15:00:00Z'}],communications:[],outboxJobs:[],outboxEvents:[]};}
function setup(initial=fixture(),custom,storage){
 let snapshot=clone(initial),sequence=0,uuid=0,globalRenders=0;
 const calls=[],toasts=[],dom=new Map(),dialogs=[];
 const document={querySelectorAll:s=>dom.get(s)||[],body:{appendChild:d=>dialogs.push(d)},createElement:()=>({setAttribute(){},addEventListener(){},showModal(){this.open=true;},close(){this.open=false;},remove(){this.removed=true;}})};
 const c=vm.createContext({console,Date,Set,Map,Promise,document,sessionStorage:storage,crypto:{randomUUID:()=>`job-${++uuid}`}});
 vm.runInContext(source+';globalThis.ui=OutboxUI',c);
 const status=()=>({jobs:clone(snapshot.outboxJobs),events:clone(snapshot.outboxEvents),connection:clone(snapshot.settings[0])});
 const defaultNative=async(action,p)=>{switch(action){
  case 'snapshot':return clone(snapshot);
  case 'outbox.status':return status();
  case 'outbox.ack':return {};
  case 'draft.save':{const d=snapshot.drafts.find(d=>d.id===p.id);if(d.updatedAt!==p.expectedUpdatedAt)throw Error('Draft changed. Refresh and review.');d.body=p.body;d.updatedAt='2026-10-28T15:01:00Z';return clone(snapshot);}
  case 'outbox.enqueue':{snapshot.outboxJobs.push({...clone(p),state:'queued',contactName:snapshot.agents.find(a=>a.id===p.agentId).name,sequenceNumber:++sequence,createdAt:'2026-10-28T15:02:00Z'});return clone(snapshot);}
  case 'outbox.confirm':{Object.assign(snapshot.outboxJobs.find(j=>j.id===p.id),clone(p));return clone(snapshot);}
  case 'outbox.resume':{snapshot.outboxJobs.find(j=>j.id===p.id).state='queued';return clone(snapshot);}
  case 'outbox.cancel':{snapshot.outboxJobs.find(j=>j.id===p.id).state='cancelled';return clone(snapshot);}
  default:return status();
 }};
 c.ui.bind({getData:()=>snapshot,adoptSnapshot:s=>{snapshot=clone(s);},native:async(action,p)=>{calls.push({action,p:clone(p||{})});return custom?custom(action,p,{get snapshot(){return snapshot;},defaultNative,status}):defaultNative(action,p);},render:()=>globalRenders++,toast:(message,options)=>toasts.push({message,options})});
 return {ui:c.ui,calls,toasts,dom,dialogs,status,get snapshot(){return snapshot;},get globalRenders(){return globalRenders;},setSnapshot:s=>{snapshot=clone(s);c.ui.acceptStatus(snapshot,{notify:false});}};
}
function action(ui,name,id){return ui.handleAction({dataset:{action:`outbox-${name}`,id},isConnected:false,disabled:false});}
function input(ui,id,value){return ui.handleInput({target:{dataset:{outboxBody:id},value}});}
function job(overrides={}){return {id:'j1',draftId:'d1',agentId:'a1',contactName:'Morgan Example',phone:'+15125550101',body:'Hello Morgan.\nCan we talk?',state:'queued',createdAt:'2026-10-28T15:03:00Z',sequenceNumber:1,revision:1,...overrides};}

test('draft editor escapes contact and text, and states exact capability without a delivery claim',()=>{
 const f=fixture();f.agents[0].name='Morgan <Example>';f.drafts[0].body='Hello <script> & "Morgan"';const t=setup(f),html=t.ui.renderDraft(t.snapshot.drafts[0],t.snapshot.agents[0]);
 assert.match(html,/Text draft · not sent/);assert.match(html,/Messages default sending identity/);assert.match(html,/Morgan &lt;Example&gt;/);assert.match(html,/Hello &lt;script&gt; &amp; &quot;Morgan&quot;/);assert.match(html,/data-action="outbox-send"/);assert.doesNotMatch(html,/<script>/);
 f.settings[0].enabled=false;const offline=setup(f).ui.renderDraft(f.drafts[0],f.agents[0]);assert.match(offline,/Connect iMessage/);assert.doesNotMatch(offline,/data-action="outbox-send"/);
});
test('unsaved edits survive rendering and require an exact saved revision before send',async()=>{
 const t=setup(),body='Hello Morgan.\n  A specific detail & question.';input(t.ui,'d1',body);assert.match(t.ui.renderDraft(t.snapshot.drafts[0]),/Unsaved changes/);
 await action(t.ui,'send','d1');assert.equal(t.calls.filter(c=>c.action==='outbox.enqueue').length,0);
 await action(t.ui,'save','d1');const save=t.calls.find(c=>c.action==='draft.save');assert.equal(save.p.expectedUpdatedAt,'2026-10-28T15:00:00Z');assert.equal(save.p.expectedBody,'Hello Morgan.\nCan we talk?');assert.equal(save.p.body,body);assert.equal(t.snapshot.drafts[0].body,body);
 await action(t.ui,'send','d1');const send=t.calls.find(c=>c.action==='outbox.enqueue');assert.deepEqual(send.p,{id:'job-1',draftId:'d1',agentId:'a1',phone:'+15125550101',body,confirmed:true,expectedUpdatedAt:'2026-10-28T15:01:00Z',expectedService:'iMessage'});assert.match(t.ui.renderDraft(t.snapshot.drafts[0]),/Queued · 0 ahead/);assert.equal(t.globalRenders,0);
});
test('stale draft save preserves typed work and refuses implicit send',async()=>{
 const t=setup();input(t.ui,'d1','My changed message');const changed=clone(t.snapshot);changed.drafts[0].updatedAt='2026-10-28T15:01:00Z';changed.drafts[0].body='Another saved version';t.setSnapshot(changed);await action(t.ui,'save','d1');
 assert.match(t.ui.renderDraft(t.snapshot.drafts[0]),/My changed message/);assert.match(t.ui.renderDraft(t.snapshot.drafts[0]),/Draft changed/);assert.equal(t.calls.filter(c=>c.action==='outbox.enqueue').length,0);
});
test('double click cannot create two jobs while enqueue is pending',async()=>{
 let release;const t=setup(fixture(),async(a,p,env)=>{if(a==='outbox.enqueue')await new Promise(r=>release=r);return env.defaultNative(a,p);});const first=action(t.ui,'send','d1');await action(t.ui,'send','d1');assert.equal(t.calls.filter(c=>c.action==='outbox.enqueue').length,1);release();await first;await action(t.ui,'send','d1');assert.equal(t.calls.filter(c=>c.action==='outbox.enqueue').length,1);
});
test('quick individual sends preserve independent recipients and show queue position',async()=>{
 const f=fixture();f.agents.push({...f.agents[0],id:'a2',name:'Taylor Example',phone:'+15125550102'});f.drafts.push({...f.drafts[0],id:'d2',agentId:'a2',body:'Hi Taylor'});const t=setup(f);await action(t.ui,'send','d1');await action(t.ui,'send','d2');assert.equal(t.snapshot.outboxJobs.length,2);assert.equal(t.snapshot.outboxJobs[1].phone,'+15125550102');assert.match(t.ui.renderDraft(t.snapshot.drafts[1]),/Queued · 1 ahead/);
});
test('legacy handoff, suppression, and unreviewed imported identities block new send',async()=>{
 const f=fixture();f.communications=[{id:'legacy-1',draftId:'d1',agentId:'a1',channel:'Message',state:'handoff_opened',phone:f.agents[0].phone,body:f.drafts[0].body}];const legacy=setup(f);await action(legacy.ui,'send','d1');assert.equal(legacy.calls.length,0);assert.match(legacy.ui.renderDraft(f.drafts[0],f.agents[0]),/Review earlier attempt/);
 for(const candidate of [{...f.agents[0],doNotContact:true},{...f.agents[0],manual:false,datasetId:'sample'},{...f.agents[0],manual:false,datasetId:'live'}])assert.equal(legacy.ui.eligible(candidate),false);
 const verified={...f.agents[0],manual:false,datasetId:'live'};verified.communicationVerification={name:verified.name,phone:verified.phone,source:verified.source,confirmed:true,reviewedAt:'2026-10-28'};assert.equal(legacy.ui.eligible(verified),true);verified.phone='+15125550999';assert.equal(legacy.ui.eligible(verified),false);
});
test('submitted and unknown jobs stay immutable and cannot silently resume',()=>{
 const f=fixture();f.outboxJobs=[job({state:'submitted'})];const t=setup(f);let html=t.ui.renderDraft(t.snapshot.drafts[0]);assert.match(html,/Submitted · verification pending/);assert.match(html,/readonly/);assert.match(html,/Confirm outcome/);assert.doesNotMatch(html,/outbox-send"|outbox-review-resume/);
 f.outboxJobs[0].state='unknown';t.setSnapshot(f);html=t.ui.render();assert.match(html,/This may already have sent/);assert.doesNotMatch(html,/outbox-review-resume/);
 f.outboxJobs[0].state='paused_restart';t.setSnapshot(f);assert.match(t.ui.render(),/Review &amp; resume/);
 f.outboxJobs=[];f.drafts[0].state='sent';t.setSnapshot(f);html=t.ui.renderDraft(t.snapshot.drafts[0]);assert.match(html,/Saved send · see history/);assert.match(html,/readonly/);assert.doesNotMatch(html,/Text draft · not sent|outbox-send"/);
});
test('outcome events create global truthful popups and acknowledgments without navigation or re-render',async()=>{
 const t=setup();const status={jobs:[job({state:'submitted'})],connection:t.snapshot.settings[0],events:[{id:'event-1',jobId:'j1',state:'submitted',contactName:'Morgan Example'}]};t.ui.acceptStatus(status);t.ui.acceptStatus(status);await Promise.resolve();assert.equal(t.toasts.length,1);assert.equal(t.toasts[0].message,'Morgan Example: Submitted · verification pending');assert.equal(t.toasts[0].options.jobId,'j1');assert.deepEqual(t.calls.find(c=>c.action==='outbox.ack').p.ids,['event-1']);assert.equal(t.globalRenders,0);
});
test('status refresh preserves other unsaved drafts and displays the exact in-flight message',()=>{
 const t=setup(),body={value:'A half-written edit',readOnly:false},state={},footer={},error={},card={dataset:{outboxDraft:'d1'},querySelector:s=>({'[data-outbox-body]':body,'[data-outbox-draft-state]':state,'[data-outbox-draft-footer]':footer,'[data-outbox-draft-error]':error}[s])};t.dom.set('[data-outbox-draft]',[card]);t.ui.acceptStatus({jobs:[job({draftId:'another-draft',state:'sending'})],events:[]});assert.equal(body.value,'A half-written edit');assert.equal(body.readOnly,false);t.ui.acceptStatus({jobs:[job({state:'sending'})],events:[]});assert.equal(body.value,job().body);assert.equal(body.readOnly,true);assert.match(state.innerHTML,/Sending…/);assert.equal(t.globalRenders,0);
});
test('outcome dialog requires actual time and sends the frozen exact message and recipient',async()=>{
 const f=fixture();f.outboxJobs=[job({state:'unknown'})];const t=setup(f);await action(t.ui,'review-outcome','j1');assert.equal(t.dialogs.length,1);assert.match(t.dialogs[0].innerHTML,/does not establish a provider delivery or read receipt/);const error={},submit={isConnected:true};const form={dataset:{kind:'outbox-review'},elements:{outcome:{value:'user_confirmed_sent'},occurredAt:{value:''}},querySelector:s=>s==='button[type="submit"]'?submit:error};await t.ui.handleSubmit(form);assert.match(error.textContent,/actual local time/);assert.equal(t.calls.filter(c=>c.action==='outbox.confirm').length,0);form.elements.occurredAt.value='2026-01-01T10:30';await t.ui.handleSubmit(form);const confirmation=t.calls.find(c=>c.action==='outbox.confirm').p;assert.equal(confirmation.phone,f.outboxJobs[0].phone);assert.equal(confirmation.body,f.outboxJobs[0].body);assert.equal(confirmation.state,'user_confirmed_sent');assert.equal(confirmation.confirmed,true);assert.equal(t.dialogs[0].removed,true);
});
test('resuming after restart requires a separate exact snapshot review',async()=>{
 const f=fixture();f.outboxJobs=[job({state:'paused_restart'})];const t=setup(f);await action(t.ui,'review-resume','j1');assert.equal(t.calls.length,0);assert.match(t.dialogs[0].innerHTML,/for a real send/);const form={dataset:{kind:'outbox-review'},querySelector:()=>({})};await t.ui.handleSubmit(form);const resume=t.calls.find(c=>c.action==='outbox.resume');assert.deepEqual(resume.p,{id:'j1',phone:f.outboxJobs[0].phone,body:f.outboxJobs[0].body,confirmed:true});
});
test('an uncertain enqueue with unavailable readback keeps repeat sends locked',async()=>{
 const t=setup(fixture(),async()=>{throw Error('Native bridge interrupted');});await action(t.ui,'send','d1');await action(t.ui,'send','d1');assert.equal(t.calls.filter(c=>c.action==='outbox.enqueue').length,1);assert.match(t.ui.renderDraft(t.snapshot.drafts[0]),/Checking queue…/);
});

test('queued draft shows frozen destination and body after the contact changes',()=>{
 const f=fixture();f.outboxJobs=[job()];f.agents[0].phone='+15125550999';f.agents[0].name='Changed name';f.drafts[0].body='Changed draft';const t=setup(f),html=t.ui.renderDraft(t.snapshot.drafts[0]);assert.match(html,/To \+15125550101/);assert.match(html,/Morgan Example/);assert.match(html,/Hello Morgan/);assert.doesNotMatch(html,/To \+15125550999|Changed draft/);
});
test('all native terminal contact statuses and skipped disposition are blocked',()=>{
 const t=setup();for(const status of ['Lost','Recruited','Not qualified','Not interested','Do not contact'])assert.equal(t.ui.eligible({...t.snapshot.agents[0],status}),false);assert.equal(t.ui.eligible({...t.snapshot.agents[0],disposition:'skipped'}),false);
});
test('connection check performs a real native account check',async()=>{
 const t=setup();await action(t.ui,'status');assert.equal(t.calls[0].action,'communications.imessageConnect');
});

test('SMS requires an explicit connection choice and the displayed service travels with the send',async()=>{
 const offline=fixture();offline.settings[0].enabled=false;const t=setup(offline);
 assert.match(t.ui.renderConnection(),/Connect SMS relay/);
 await action(t.ui,'connect-sms');assert.deepEqual(t.calls[0],{action:'communications.imessageConnect',p:{service:'SMS'}});
 const sms=fixture();sms.settings[0].service='SMS';const ready=setup(sms);
 assert.match(ready.ui.renderDraft(sms.drafts[0]),/\+15125550101 · SMS/);
 await action(ready.ui,'status');assert.equal(ready.calls[0].p.service,'SMS');
 await action(ready.ui,'send','d1');assert.equal(ready.calls.find(c=>c.action==='outbox.enqueue').p.expectedService,'SMS');
 const frozen=fixture();frozen.outboxJobs=[job({senderService:'SMS'})];
 assert.match(setup(frozen).ui.renderDraft(frozen.drafts[0]),/\+15125550101 · SMS/);
});

test('bulk selection must be reviewed again after changing the sending service',async()=>{
 const t=setup();select(t.ui,'d1');const changed=clone(t.snapshot);changed.settings[0].service='SMS';t.setSnapshot(changed);
 await action(t.ui,'bulk-send');assert.equal(t.calls.filter(c=>c.action==='outbox.enqueue').length,0);
 assert.match(t.ui.render(),/Sending account or service changed/);
});

function select(ui,id,checked=true){return ui.handleInput({target:{dataset:{outboxBulkSelect:id},checked}});}
function twoDrafts(){const f=fixture();f.agents.push({...f.agents[0],id:'a2',name:'Taylor Example',phone:'+15125550102'});f.drafts.push({...f.drafts[0],id:'d2',agentId:'a2',body:'Hi Taylor'});return f;}
test('bulk selection reviews separate exact recipients and waits for each enqueue receipt',async()=>{
 let release,active=0,maxActive=0;const t=setup(twoDrafts(),async(a,p,env)=>{if(a==='outbox.enqueue'){active++;maxActive=Math.max(maxActive,active);if(p.draftId==='d1')await new Promise(r=>release=r);const result=await env.defaultNative(a,p);active--;return result;}return env.defaultNative(a,p);});
 select(t.ui,'d1');select(t.ui,'d2');assert.match(t.ui.render(),/Queue selected 2 texts/);assert.match(t.ui.render(),/To|\+15125550102/);const work=action(t.ui,'bulk-send');await new Promise(r=>setImmediate(r));assert.equal(t.calls.filter(c=>c.action==='outbox.enqueue').length,1);release();await work;const sends=t.calls.filter(c=>c.action==='outbox.enqueue');assert.equal(sends.length,2);assert.equal(maxActive,1);assert.deepEqual(sends.map(c=>c.p.id),['job-1','job-2']);assert.deepEqual(sends.map(c=>c.p.phone),['+15125550101','+15125550102']);assert.equal(sends[1].p.body,'Hi Taylor');assert.equal(sends[1].p.expectedUpdatedAt,'2026-10-28T15:00:00Z');assert.equal(t.calls.filter(c=>c.action==='snapshot').length,2);assert.match(t.ui.render(),/2 of 2 texts added to outbox/);
});
test('bulk partial failure preserves the failed selection without retrying or claiming full success',async()=>{
 const t=setup(twoDrafts(),async(a,p,env)=>{if(a==='outbox.enqueue'&&p.draftId==='d1')throw Error('New reply needs review');return env.defaultNative(a,p);});select(t.ui,'d1');select(t.ui,'d2');await action(t.ui,'bulk-send');assert.equal(t.snapshot.outboxJobs.length,1);assert.match(t.ui.render(),/1 of 2 texts added to outbox · 1 need review/);assert.match(t.ui.render(),/New reply needs review/);assert.match(t.ui.render(),/This selection will not be retried/);assert.match(t.ui.render(),/data-outbox-bulk-select="d1" checked/);await action(t.ui,'bulk-send');assert.equal(t.calls.filter(c=>c.action==='outbox.enqueue').length,2);
});
test('bulk rechecks the selected exact saved revision before each enqueue',async()=>{
 let snapshots=0;const t=setup(twoDrafts(),async(a,p,env)=>{if(a==='snapshot'&&++snapshots===2)env.snapshot.drafts[1].updatedAt='2026-10-28T15:09:00Z';return env.defaultNative(a,p);});select(t.ui,'d1');select(t.ui,'d2');await action(t.ui,'bulk-send');assert.equal(t.calls.filter(c=>c.action==='outbox.enqueue').length,1);assert.match(t.ui.render(),/Changed since selected/);assert.match(t.ui.render(),/1 of 2 texts added to outbox/);
});
test('bulk changed recipient and disconnected transport cannot enqueue a selected message',async()=>{
 const t=setup();select(t.ui,'d1');const changed=clone(t.snapshot);changed.agents[0].phone='+15125550999';t.setSnapshot(changed);await action(t.ui,'bulk-send');assert.equal(t.calls.filter(c=>c.action==='outbox.enqueue').length,0);assert.match(t.ui.render(),/Changed since selected/);
 const f=fixture();f.settings[0].enabled=false;const off=setup(f);select(off.ui,'d1');await action(off.ui,'bulk-send');assert.equal(off.calls.filter(c=>c.action==='outbox.enqueue').length,0);assert.match(off.toasts[0].message,/Connect Messages/);
});
test('bulk selection excludes unsaved edits and is limited to 20 individual drafts',()=>{
 const t=setup();input(t.ui,'d1','Unsaved content');select(t.ui,'d1');assert.match(t.ui.render(),/Queue selected 0 texts/);assert.doesNotMatch(t.ui.render(),/data-outbox-bulk-select="d1"/);
 const f=fixture();for(let i=2;i<=21;i++){f.agents.push({...f.agents[0],id:`a${i}`,name:`Agent ${i}`,phone:`+1512555${String(i).padStart(4,'0')}`});f.drafts.push({...f.drafts[0],id:`d${i}`,agentId:`a${i}`});}const bounded=setup(f);for(let i=1;i<=21;i++)select(bounded.ui,`d${i}`);assert.match(bounded.ui.render(),/Queue selected 20 texts/);assert.match(bounded.toasts[0].message,/up to 20/);
});
test('unsaved text recovers only in session storage and preserves its original save revision',async()=>{
 const values=new Map(),storage={getItem:k=>values.get(k)||null,setItem:(k,v)=>values.set(k,v),removeItem:k=>values.delete(k)};const t=setup(fixture(),null,storage);input(t.ui,'d1','Recovered text');assert.equal(values.size,1);const reload=setup(fixture(),null,storage);assert.match(reload.ui.renderDraft(reload.snapshot.drafts[0]),/Recovered unsaved changes/);assert.match(reload.ui.renderDraft(reload.snapshot.drafts[0]),/Recovered text/);assert.equal(reload.calls.length,0);await action(reload.ui,'save','d1');assert.equal(reload.calls[0].p.expectedUpdatedAt,'2026-10-28T15:00:00Z');assert.equal(reload.calls[0].p.expectedBody,'Hello Morgan.\nCan we talk?');assert.equal(values.size,0);assert.doesNotMatch(source,/localStorage/);
});
