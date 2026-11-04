'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const source=fs.readFileSync(path.join(__dirname,'../Web/gmail-sync.js'),'utf8');
const clone=v=>JSON.parse(JSON.stringify(v));
const clientId='123456-desktop.apps.googleusercontent.com';
const initial=changes=>({enabled:false,connected:false,status:'disabled',configuredClientId:clientId,uniqueCandidateCount:3,ambiguousCandidateCount:0,importedMessages:0,importedReplies:0,importedSent:0,automaticNotices:0,...changes});
function setup(state=initial(),custom){
 let snapshot=state===null?{agents:[]}:{agents:[],gmailSync:clone(state)},renders=0,adopted=0;
 const calls=[],toasts=[],roots=[],document={querySelectorAll:s=>s==='[data-gmail-sync]'?roots:[],activeElement:null};
 const context=vm.createContext({Date,Number,Set,Promise,Array,document});vm.runInContext(source+';globalThis.ui=GmailSyncUI;',context);
 const defaultNative=async(action,payload)=>{const before=snapshot.gmailSync||initial();switch(action){
  case 'gmailSync.status':return clone(before);
  case 'gmailSync.setClientSecret':snapshot.gmailSync={...before,clientSecretConfigured:true};return clone(snapshot);
  case 'gmailSync.setClientID':snapshot.gmailSync={...before,configuredClientId:payload.clientId};return clone(snapshot);
  case 'gmailSync.connect':snapshot.gmailSync={...before,connected:true,accountAddress:'recruiter@example.com',status:'disabled',enabled:false};return clone(snapshot);
  case 'gmailSync.configure':snapshot.gmailSync={...before,enabled:payload.enabled,status:payload.enabled?'ready':'disabled',...(payload.enabled?{since:before.since||'2026-10-29T15:00:00Z',historyMode:before.historyMode||payload.historyMode}:{})};return clone(snapshot);
  case 'gmailSync.rescan':snapshot.gmailSync={...before,status:'ready',lastError:null};return clone(snapshot);
  case 'gmailSync.scan':snapshot.gmailSync={...before,status:'syncing'};return clone(snapshot.gmailSync);
  case 'gmailSync.disconnect':snapshot.gmailSync={...before,enabled:false,connected:false,status:'disabled'};return clone(snapshot);
  default:throw Error('Unexpected endpoint '+action);
 }};
 context.ui.bind({getData:()=>snapshot,adoptSnapshot:v=>{snapshot=clone(v);adopted++;},native:async(action,payload)=>{calls.push({action,payload:clone(payload||{})});return custom?custom(action,payload,{defaultNative,get snapshot(){return snapshot;}}):defaultNative(action,payload);},toast:(message,options)=>toasts.push({message,options}),render:()=>renders++});
 return {ui:context.ui,calls,toasts,roots,document,get snapshot(){return snapshot;},get renders(){return renders;},get adopted(){return adopted;}};
}
const click=(t,name)=>t.ui.handle('gmail-sync-'+name,{dataset:{action:'gmail-sync-'+name}});
const choose=(t,value)=>t.ui.handleInput({target:{dataset:{gmailHistoryMode:''},value}});
const markup=(html,name)=>html.match(new RegExp('<button[^>]*data-action="gmail-sync-'+name+'"[^>]*>[^<]*</button>'))?.[0]||'';

test('default state is disconnected and polling cannot configure, connect, or scan',async()=>{
 const t=setup(null),html=t.ui.render();assert.match(html,/No account connected/);assert.match(html,/Choose before enabling/);assert.match(html,/Not established/);assert.match(markup(html,'review-connect'),/disabled/);assert.equal(t.calls.length,0);await click(t,'enable');await click(t,'connect');await click(t,'scan');assert.equal(t.calls.length,0);await t.ui.poll();assert.deepEqual(t.calls,[{action:'gmailSync.status',payload:{}}]);assert.equal(t.renders,0);
});
test('public Desktop client ID is validated and saved without authorizing Gmail',async()=>{
 const t=setup(initial({configuredClientId:''}));const form={dataset:{kind:'gmail-sync-client'},elements:{clientId:{value:'not-a-client'}}};await t.ui.handleSubmit(form);assert.equal(t.calls.length,0);assert.match(t.ui.render(),/Enter the Desktop OAuth client ID/);form.elements.clientId.value=' '+clientId+' ';await t.ui.handleSubmit(form);assert.deepEqual(t.calls,[{action:'gmailSync.setClientID',payload:{clientId}}]);assert.equal(t.snapshot.gmailSync.connected,false);assert.doesNotMatch(source,/\bclientSecret\b|refreshToken|accessToken|localStorage|sessionStorage/);
});
test('OAuth connection requires explicit visible review and never enables sync',async()=>{
 const t=setup();await click(t,'connect');assert.equal(t.calls.length,0);await click(t,'review-connect');assert.match(t.ui.render(),/filter does not narrow Google&#39;s mailbox permission|filter does not narrow Google's mailbox permission/);assert.match(t.ui.render(),/Connecting an account does not enable history sync/);await click(t,'connect');assert.deepEqual(t.calls,[{action:'gmailSync.connect',payload:{confirmed:true}}]);assert.equal(t.snapshot.gmailSync.enabled,false);assert.equal(t.snapshot.gmailSync.connected,true);assert.match(t.ui.render(),/recruiter@example.com/);assert.match(t.ui.render(),/Connected · sync off/);
});
test('first enable uses the reviewed history choice and not a silently applied default',async()=>{
 const t=setup(initial({connected:true,accountAddress:'recruiter@example.com'}));choose(t,'all');await click(t,'enable');assert.equal(t.calls.length,0);await click(t,'review-enable');assert.match(t.ui.render(),/<option value="last60days" selected>/);assert.equal(t.calls.length,0);choose(t,'newonly');await click(t,'enable');assert.deepEqual(t.calls,[{action:'gmailSync.configure',payload:{enabled:true,confirmed:true,historyMode:'newonly'}}]);assert.equal(t.snapshot.gmailSync.historyMode,'newonly');assert.match(t.ui.render(),/First scan pending/);assert.match(t.ui.render(),/Email coverage is not established yet/);
});
test('all-history selection explicitly describes incomplete initial coverage',async()=>{
 const t=setup(initial({connected:true,accountAddress:'recruiter@example.com'}));await click(t,'review-enable');choose(t,'all');assert.match(t.ui.render(),/All history can take multiple scans/);await click(t,'enable');assert.equal(t.calls[0].payload.historyMode,'all');t.ui.acceptStatus({...t.snapshot.gmailSync,status:'syncing',hasMore:true});assert.match(t.ui.render(),/initial import or catch-up is still incomplete/);
});
test('canceling a review makes no configuration or account change',async()=>{
 const t=setup();await click(t,'review-connect');await click(t,'cancel');await click(t,'connect');assert.equal(t.calls.length,0);assert.doesNotMatch(t.ui.render(),/Continue to Google/);
});
test('pause and resume preserve account scope, cursor floor and successful scan evidence',async()=>{
 const since='2026-08-30T15:00:00Z',lastSuccessAt='2026-10-29T15:15:00Z',t=setup(initial({enabled:true,connected:true,accountAddress:'recruiter@example.com',status:'ready',historyMode:'last60days',since,lastSuccessAt}));await click(t,'pause');assert.deepEqual(t.calls[0],{action:'gmailSync.configure',payload:{enabled:false,confirmed:true}});await click(t,'review-enable');assert.match(t.ui.render(),/Keep the original history scope/);assert.doesNotMatch(t.ui.render(),/data-gmail-history-mode/);choose(t,'all');await click(t,'enable');assert.deepEqual(t.calls[1],{action:'gmailSync.configure',payload:{enabled:true,confirmed:true}});assert.equal(t.snapshot.gmailSync.since,since);assert.equal(t.snapshot.gmailSync.lastSuccessAt,lastSuccessAt);assert.equal(t.snapshot.gmailSync.historyMode,'last60days');assert.match(t.ui.render(),/Catching up/);
});
test('disconnect is explicitly reviewed and leaves imported history visible',async()=>{
 const t=setup(initial({enabled:true,connected:true,status:'ready',accountAddress:'recruiter@example.com',importedMessages:8}));await click(t,'disconnect');assert.equal(t.calls.length,0);await click(t,'review-disconnect');assert.match(t.ui.render(),/Emails already imported into candidate activity remain available/);await click(t,'disconnect');assert.deepEqual(t.calls,[{action:'gmailSync.disconnect',payload:{confirmed:true}}]);assert.equal(t.snapshot.gmailSync.connected,false);assert.equal(t.snapshot.gmailSync.importedMessages,8);assert.match(t.toasts[0].message,/Imported activity stays on this Mac/);
});
test('native errors retain coverage, display escaped details, and do not claim delivery or read receipts',()=>{
 const t=setup(initial({enabled:true,connected:true,status:'error',accountAddress:'recruiter@example.com',since:'2026-08-30T15:00:00Z',lastSuccessAt:'2026-10-29T15:15:00Z',historyMode:'last60days',lastError:'Expired access <sign in> & retry',importedSent:5,importedReplies:2,automaticNotices:3}));const html=t.ui.render();assert.match(html,/Coverage has a gap/);assert.match(html,/Expired access &lt;sign in&gt; &amp; retry/);assert.match(html,/<dt>Sent history<\/dt><dd>5/);assert.match(html,/<dt>Human responses<\/dt><dd>2/);assert.match(html,/<dt>Automated notices<\/dt><dd>3/);assert.match(html,/Sent history is not a delivery or read receipt/);assert.match(html,/Human responses pause follow-up work/);
});
test('status polling preserves an unsaved client ID and cannot replace unrelated editors',async()=>{
 const t=setup();t.ui.handleInput({target:{dataset:{gmailClientId:''},value:'999-new.apps.googleusercontent.com'}});await t.ui.poll();assert.match(t.ui.render(),/value="999-new.apps.googleusercontent.com"/);assert.equal(t.renders,0);assert.equal(t.calls[0].action,'gmailSync.status');
});
test('stale poll response cannot re-enable a paused connection',async()=>{
 let resolve;const before=initial({enabled:true,connected:true,status:'ready',accountAddress:'recruiter@example.com',since:'2026-08-30T15:00:00Z',historyMode:'last60days'});const t=setup(before,async(action,payload,api)=>action==='gmailSync.status'?new Promise(r=>resolve=r):api.defaultNative(action,payload));const pending=t.ui.poll();await click(t,'pause');resolve(before);await pending;assert.equal(t.snapshot.gmailSync.enabled,false);assert.match(t.ui.render(),/Sync paused/);
});
test('late scan result cannot overwrite disconnect',async()=>{
 let resolve;const before=initial({enabled:true,connected:true,status:'ready',accountAddress:'recruiter@example.com',since:'2026-08-30T15:00:00Z',historyMode:'last60days'});const t=setup(before,async(action,payload,api)=>action==='gmailSync.scan'?new Promise(r=>resolve=r):api.defaultNative(action,payload));const scan=click(t,'scan');await click(t,'review-disconnect');await click(t,'disconnect');resolve({...before,lastSuccessAt:'2026-10-29T16:00:00Z'});await scan;assert.equal(t.snapshot.gmailSync.connected,false);assert.equal(t.snapshot.gmailSync.lastSuccessAt,undefined);
});
test('completed scan notices count imported emails once without labeling automated notices as responses',()=>{
 const t=setup(initial({enabled:true,connected:true,status:'ready',accountAddress:'recruiter@example.com',lastSuccessAt:'2026-10-29T15:00:00Z',importedMessages:5,importedReplies:1}));t.ui.acceptStatus(initial({enabled:true,connected:true,status:'syncing',hasMore:true,accountAddress:'recruiter@example.com',importedMessages:7}));assert.equal(t.toasts.length,0);const done=initial({enabled:true,connected:true,status:'ready',accountAddress:'recruiter@example.com',lastSuccessAt:'2026-10-29T16:00:00Z',importedMessages:8,automaticNotices:3,importedReplies:1});t.ui.acceptStatus(done);t.ui.acceptStatus(done);assert.equal(t.toasts.length,1);assert.equal(t.toasts[0].message,'3 Gmail emails added to candidate activity.');assert.doesNotMatch(t.toasts[0].message,/replies|responses|delivered/);
});
test('account switch resets the notification baseline and never labels old totals as new activity',()=>{
 const t=setup(initial({enabled:true,connected:true,status:'ready',accountAddress:'one@example.com',importedMessages:2,lastSuccessAt:'2026-10-29T15:00:00Z'}));t.ui.acceptStatus(initial({enabled:false,connected:true,status:'disabled',accountAddress:'two@example.com',importedMessages:30}));assert.equal(t.toasts.length,0);assert.match(t.ui.render(),/two@example.com/);assert.match(t.ui.render(),/Connected · sync off/);
});
test('missing or malformed native status does not fabricate connection success',async()=>{
 const t=setup(initial(),async()=>({ok:true}));await click(t,'review-connect');await click(t,'connect');assert.match(t.ui.render(),/saved Gmail setting could not be verified/);assert.match(t.ui.render(),/No account connected/);assert.equal(t.toasts.length,0);
});

test('a plain workspace snapshot does not erase public client setup from the latest native status',()=>{
 const t=setup();const plain=initial();delete plain.configuredClientId;t.ui.acceptStatus({agents:[],gmailSync:plain});assert.doesNotMatch(markup(t.ui.render(),'review-connect'),/disabled/);assert.match(t.ui.render(),new RegExp(clientId.replaceAll('.','\\.')));t.ui.acceptStatus({...plain,configuredClientId:''});assert.match(markup(t.ui.render(),'review-connect'),/disabled/);
});

function emailActivity(row){
 const appSource=fs.readFileSync(path.join(__dirname,'../Web/app.js'),'utf8'),start=appSource.indexOf('function renderEmailActivity('),end=appSource.indexOf('function renderTextWorkbench(',start);
 assert.ok(start>=0&&end>start,'the app exposes its actual email activity renderer');
 const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const context=vm.createContext({D:{agents:[{id:'a1',name:'Morgan Example'}]},E:escape,dateTime:v=>v||'Unknown',icon:()=>'',btn:(label,action,icon,attrs)=>`<button data-action="${escape(action)}" ${attrs}>${escape(label)}</button>`});
 vm.runInContext(appSource.slice(start,end)+';globalThis.renderEmail=renderEmailActivity',context);return context.renderEmail(row,'a1');
}
const email=changes=>({id:'email1',agentId:'a1',provider:'gmail',syncSource:'gmail-native',direction:'inbound',accountAddress:'recruiter@example.com',from:'morgan@example.com',to:'recruiter@example.com',body:'Thanks for the note. <details>',subject:'Re: Introduction',providerMessageId:'gmail-123',providerThreadId:'thread-456',occurredAt:'2026-10-29T15:00:00Z',importedAt:'2026-10-29T15:01:00Z',...changes});

test('candidate Gmail activity distinguishes automated notices from paused human replies',()=>{
 const automated=emailActivity(email({messageClass:'automatic_notice',followUpsPaused:false,reviewTaskId:'notice-review'}));assert.match(automated,/Automatic email notice/);assert.match(automated,/Review notice/);assert.match(automated,/data-id="notice-review"/);assert.doesNotMatch(automated,/Follow-ups paused for review|Review reply/);
 const human=emailActivity(email({messageClass:'received_reply',followUpsPaused:true,reviewTaskId:'reply-review'}));assert.match(human,/Email received/);assert.match(human,/Follow-ups paused for review/);assert.match(human,/Review reply/);assert.match(human,/data-id="reply-review"/);assert.match(human,/Mailbox: recruiter@example.com · Message ID: gmail-123 · Thread ID: thread-456/);assert.match(human,/Thanks for the note\. &lt;details&gt;/);
});

test('candidate sent-email activity retains evidence without manufacturing delivery or unreadable text',()=>{
 const sent=emailActivity(email({direction:'outbound',from:'recruiter@example.com',to:'morgan@example.com',messageClass:'sent_copy',body:'',bodyKind:'unavailable'}));assert.match(sent,/Email sent · saved history/);assert.match(sent,/A saved Sent copy does not establish delivery/);assert.match(sent,/Email content unavailable/);assert.match(sent,/Email text could not be decoded; open Gmail to read it/);assert.doesNotMatch(sent,/Follow-ups paused for review|Review reply/);
});

test('expired cursor recovery rechecks only the originally approved window after explicit review',async()=>{
 const t=setup(initial({enabled:true,connected:true,status:'blocked',accountAddress:'recruiter@example.com',historyMode:'last60days',since:'2026-08-30T15:00:00Z',lastSuccessAt:'2026-10-29T15:15:00Z',errorCode:'history_expired'}));await click(t,'rescan');assert.equal(t.calls.length,0);await click(t,'review-rescan');assert.match(t.ui.render(),/does not expand the history window/);assert.doesNotMatch(t.ui.render(),/data-gmail-history-mode/);await click(t,'rescan');assert.deepEqual(t.calls,[{action:'gmailSync.rescan',payload:{confirmed:true}}]);assert.equal(t.snapshot.gmailSync.historyMode,'last60days');assert.equal(t.snapshot.gmailSync.since,'2026-08-30T15:00:00Z');assert.match(t.ui.render(),/Catching up/);
});
test('history recovery is unavailable while disabled or healthy',async()=>{
 for(const state of [initial({enabled:false,connected:true,status:'blocked',accountAddress:'recruiter@example.com'}),initial({enabled:true,connected:true,status:'ready',accountAddress:'recruiter@example.com'})]){const t=setup(state);assert.doesNotMatch(t.ui.render(),/data-action="gmail-sync-review-rescan"/);await click(t,'review-rescan');await click(t,'rescan');assert.equal(t.calls.length,0);}
});

test('initial history review states date-only scope and mailbox exclusions for every choice',async()=>{
 const t=setup(initial({connected:true,accountAddress:'recruiter@example.com'}));await click(t,'review-enable');for(const mode of ['last60days','newonly','all']){choose(t,mode);const html=t.ui.render();assert.match(html,/All available history changes the date window only/);assert.match(html,/Drafts, Spam, and Trash are excluded/);assert.match(html,/Unsupported email envelopes are held for review/);}assert.equal(t.calls.length,0);
});

test('completed scans still surface held evidence without treating every held email as a reply',()=>{
 const state=initial({enabled:true,connected:true,status:'ready',accountAddress:'recruiter@example.com',lastSuccessAt:'2026-10-29T15:15:00Z',heldMessages:3,uniqueCandidateCount:3,ambiguousCandidateCount:0}),t=setup(state);assert.match(t.ui.render(),/3 emails need identity review/);assert.match(t.ui.render(),/Open Tasks to review unlinked Gmail evidence; possible replies keep outreach held/);assert.doesNotMatch(t.ui.render(),/3 replies/);t.ui.acceptStatus({...state,heldMessages:1});assert.match(t.ui.render(),/1 email needs identity review/);t.ui.acceptStatus({...state,heldMessages:0});assert.doesNotMatch(t.ui.render(),/emails? needs? identity review/);t.ui.acceptStatus({...state,heldMessages:'<img src=x onerror=alert(1)>'});assert.doesNotMatch(t.ui.render(),/<img|onerror=|emails? needs? identity review/);
});

test('successful status polls retain a failed OAuth connection error until an explicit successful retry',async()=>{
 let attempts=0;const t=setup(initial(),async(action,payload,api)=>{if(action==='gmailSync.connect'&&++attempts===1)throw Error('Google authorization could not be saved on this Mac.');return api.defaultNative(action,payload);});await click(t,'review-connect');await click(t,'connect');assert.match(t.ui.render(),/Google authorization could not be saved on this Mac/);assert.equal(t.snapshot.gmailSync.connected,false);await t.ui.poll();await t.ui.poll();t.ui.acceptStatus({agents:[],gmailSync:initial()});assert.match(t.ui.render(),/Google authorization could not be saved on this Mac/);assert.match(t.ui.render(),/No account connected/);assert.equal(t.calls.filter(c=>c.action==='gmailSync.connect').length,1);await click(t,'connect');assert.equal(t.snapshot.gmailSync.connected,true);assert.doesNotMatch(t.ui.render(),/Google authorization could not be saved on this Mac/);await t.ui.poll();assert.doesNotMatch(t.ui.render(),/Google authorization could not be saved on this Mac/);assert.equal(attempts,2);
});
test('status read failures do not overwrite a retained operation error and cancel clears it',async()=>{
 const t=setup(initial(),async(action,payload,api)=>{if(action==='gmailSync.connect')throw Error('Connection was not completed.');if(action==='gmailSync.status')throw Error('Read unavailable.');return api.defaultNative(action,payload);});await click(t,'review-connect');await click(t,'connect');await t.ui.poll();assert.match(t.ui.render(),/Connection was not completed/);assert.doesNotMatch(t.ui.render(),/Read unavailable/);await click(t,'cancel');assert.doesNotMatch(t.ui.render(),/Connection was not completed/);assert.equal(t.snapshot.gmailSync.connected,false);
});
test('a transient read error still clears when status polling recovers',async()=>{
 let reads=0;const t=setup(initial(),async(action,payload,api)=>{if(action==='gmailSync.status'&&++reads===1)throw Error('Temporary status failure');return api.defaultNative(action,payload);});await t.ui.poll();assert.match(t.ui.render(),/Temporary status failure/);await t.ui.poll();assert.doesNotMatch(t.ui.render(),/Temporary status failure/);assert.equal(t.calls.filter(c=>c.action!=='gmailSync.status').length,0);
});

test('client secret setup opens only the native prompt with a confirmation-only payload',async()=>{
 const t=setup();assert.match(markup(t.ui.render(),'set-secret'),/Set Desktop client secret…/);assert.doesNotMatch(t.ui.render(),/type="password"|name="clientSecret"|data-gmail-secret/);await click(t,'set-secret');assert.deepEqual(t.calls,[{action:'gmailSync.setClientSecret',payload:{confirmed:true}}]);assert.equal(t.snapshot.gmailSync.clientSecretConfigured,true);assert.equal(t.snapshot.gmailSync.connected,false);assert.equal(t.snapshot.gmailSync.enabled,false);assert.match(t.ui.render(),/Client configuration saved in Keychain/);
});
test('secret setup displays boolean readiness without rendering a secret or allowing connected edits',async()=>{
 const t=setup(initial({clientSecretConfigured:true,clientSecret:'fixture-value-that-must-stay-native'}));assert.match(t.ui.render(),/Client configuration saved in Keychain/);assert.doesNotMatch(t.ui.render(),/fixture-value-that-must-stay-native/);t.ui.acceptStatus(initial({clientSecretConfigured:'fixture-value-that-must-stay-native'}));assert.doesNotMatch(t.ui.render(),/Client configuration saved in Keychain|fixture-value-that-must-stay-native/);for(const state of [initial({configuredClientId:''}),initial({connected:true,accountAddress:'recruiter@example.com',clientSecretConfigured:true})]){const unavailable=setup(state);assert.doesNotMatch(unavailable.ui.render(),/data-action="gmail-sync-set-secret"/);await click(unavailable,'set-secret');assert.equal(unavailable.calls.length,0);}
});
test('native secret prompt is serialized and cancellation does not claim that a value was saved',async()=>{
 let reject;const t=setup(initial(),async(action,payload,api)=>action==='gmailSync.setClientSecret'?new Promise((_,r)=>reject=r):api.defaultNative(action,payload));const pending=click(t,'set-secret');await click(t,'set-secret');await t.ui.poll();assert.equal(t.calls.length,1);reject(Error('Client configuration was canceled.'));await pending;assert.match(t.ui.render(),/Client configuration was canceled/);assert.doesNotMatch(t.ui.render(),/Client configuration saved in Keychain/);await t.ui.poll();assert.match(t.ui.render(),/Client configuration was canceled/);assert.equal(t.toasts.length,0);
});

test('accepted meeting response keeps its actual email, Gmail link and recorded pause visible',()=>{
 const body='I accepted the invitation.\n\nSee you Friday <at noon> & thanks.\nMorgan',row=email({messageClass:'meeting_response',meetingResponse:'accepted',subject:'Accepted: Friday conversation',body,followUpsPaused:true,reviewTaskId:'meeting-review',providerMessageId:'1a18d92434a91d59'}),html=emailActivity(row);
 assert.match(html,/Meeting response · Accepted · Accepted: Friday conversation/);assert.match(html,/I accepted the invitation\.\n\nSee you Friday &lt;at noon&gt; &amp; thanks\.\nMorgan/);assert.match(html,/Follow-ups paused for review/);assert.match(html,/Review meeting response/);assert.match(html,/data-id="meeting-review"/);assert.match(html,/https:\/\/mail\.google\.com\/mail\/u\/\?authuser=recruiter%40example\.com#all\/1a18d92434a91d59/);assert.doesNotMatch(html,/<h3>Email received|Automatic email notice|>Review reply</);
 row.followUpsPaused=false;assert.doesNotMatch(emailActivity(row),/Follow-ups paused for review/,'the label alone cannot invent a saved outreach hold');
});

test('declined and tentative meeting responses are distinct without an invented acceptance or pause',()=>{
 for(const [response,label] of [['declined','Declined'],['tentative','Tentative']]){const html=emailActivity(email({messageClass:'meeting_response',meetingResponse:response,followUpsPaused:false,reviewTaskId:'meeting-review'}));assert.match(html,new RegExp('Meeting response · '+label));assert.match(html,/Review meeting response/);assert.doesNotMatch(html,/Meeting response · Accepted|Follow-ups paused for review|Automatic email notice/);}
 const unknown=emailActivity(email({messageClass:'meeting_response',meetingResponse:'<img src=x onerror=bad()>',followUpsPaused:false}));assert.match(unknown,/Meeting response · Outcome not specified/);assert.doesNotMatch(unknown,/<img|onerror=|Meeting response · Accepted/);
 const ordinary=emailActivity(email({messageClass:'received_reply',subject:'Accepted: an unrelated proposal',followUpsPaused:true}));assert.match(ordinary,/Email received · Accepted: an unrelated proposal/);assert.doesNotMatch(ordinary,/Meeting response/,'UI cannot classify a calendar reply from its subject alone');
});

test('Gmail statistics report meeting responses separately from human replies and automated notices',()=>{
 const t=setup(initial({importedMessages:12,importedSent:5,importedReplies:2,importedMeetingResponses:3,automaticNotices:2})),html=t.ui.render();assert.match(html,/<dt>Emails imported<\/dt><dd>12/);assert.match(html,/<dt>Sent history<\/dt><dd>5/);assert.match(html,/<dt>Human responses<\/dt><dd>2/);assert.match(html,/<dt>Meeting responses<\/dt><dd>3/);assert.match(html,/<dt>Automated notices<\/dt><dd>2/);assert.match(html,/Accepted meeting responses also pause follow-up work/);assert.doesNotMatch(html,/<dt>Human responses<\/dt><dd>5/);
 t.ui.acceptStatus(initial());assert.match(t.ui.render(),/<dt>Meeting responses<\/dt><dd>Not checked/);t.ui.acceptStatus(initial({importedMeetingResponses:'<script>bad()</script>'}));assert.doesNotMatch(t.ui.render(),/<script>|bad\(\)/);
});
