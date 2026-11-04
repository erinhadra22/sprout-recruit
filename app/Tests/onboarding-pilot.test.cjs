'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const Model=require('../Web/model.js');
function context(workspace={}){
 const source=fs.readFileSync(path.join(__dirname,'../Web/app.js'),'utf8');
 const c=vm.createContext({Model,Intl,icon:()=>'',CommunicationsUI:{render:()=>'<p>Apple handoff</p>'},document:{getElementById(){return {};}},window:{}});
 for(const file of ['task-controls.js','weekly-reports.js','sourcing-rules.js','meetings.js'])vm.runInContext(fs.readFileSync(path.join(__dirname,'../Web',file),'utf8'),c);
 vm.runInContext(source.slice(0,source.indexOf("document.addEventListener('click'"))+`;D={settings:[{id:'workspace',...${JSON.stringify(workspace)}}],databasePath:'/fixture/workspace.sqlite'};globalThis.ui={needsOnboarding,renderOnboarding,renderSettings,renderRecovery,shell,setTab:x=>S.settingsTab=x,setRecovery:x=>recoveryState=x};`,c);
 return c;
}
test('fresh onboarding requires identity and includes company and time zone without Erin defaults',()=>{
 const c=context({name:'',onboardingRequired:true,company:'Sprout Realty'});
 assert.equal(c.ui.needsOnboarding(),true);
 const html=c.ui.renderOnboarding();
 for(const name of ['name','company','timezone'])assert.match(html,new RegExp(`name="${name}"[^>]*required`));
 assert.doesNotMatch(html,/Erin|Head of Recruiting/);
 assert.match(html,/does not connect an account or send a message/);
});
test('existing identity remains usable and all settings text is escaped',()=>{
 const c=context({name:'Fixture <Recruiter>',company:'Sprout Realty'});
 assert.equal(c.ui.needsOnboarding(),false);
 assert.match(c.ui.renderSettings(),/Fixture &lt;Recruiter&gt;/);
 assert.doesNotMatch(c.ui.renderSettings(),/data-value="AI connection"|data-value="AI context"/);
});
test('experimental settings route cannot render provider or AI connection controls',()=>{
 const c=context({name:'Fixture'});c.ui.setTab('AI connection');
 const html=c.ui.renderSettings();
 assert.match(html,/Other account connections/);
 assert.doesNotMatch(html,/ai-job-form|comm-configure|telnyxMessage/);
});
test('recovery screen discloses replacement, restart, retention and device-loss limits',()=>{
 const c=context({name:'Fixture'});c.ui.setRecovery({root:'/fixture/recovery',snapshots:[{createdAt:'2026-10-13T10:15:00Z',reason:'manual <fixture>',path:'/fixture/recovery/one'}]});
 const html=c.ui.renderRecovery();
 assert.match(html,/replaces this workspace/);assert.match(html,/requires restarting/);
 assert.match(html,/retained until a cleanup policy is approved/);
 assert.match(html,/do not protect against loss of the device/);
 assert.match(html,/manual &lt;fixture&gt;/);
 for(const action of ['recovery-create','recovery-restore','recovery-refresh'])assert.match(html,new RegExp(action));
});
test('communication settings retain saved history but disable provider sends and setup',()=>{
 const c=vm.createContext({D:{agents:[],communications:[{id:'fixture',transport:'telnyx',state:'unknown',phone:'+12025550123',body:'Saved <message>'}]}});
 vm.runInContext(fs.readFileSync(path.join(__dirname,'../Web/communications.js'),'utf8')+';globalThis.ui=CommunicationsUI;',c);
 assert.equal(c.ui.directSMSAvailable(),false);
 const html=c.ui.render();
 assert.match(html,/Saved &lt;message&gt;/);
 assert.match(html,/Provider checks are unavailable/);
 assert.doesNotMatch(html,/comm-configure|comm-refresh|communications-test-form/);
});

test('normal task edit prefills saved fields while linked draft edit only reschedules',()=>{
 const c=context({name:'Fixture'});
 vm.runInContext(`D.tasks=[{id:'normal',title:'Follow up <carefully>',dueDate:'2026-10-20',type:'Call',priority:'High',description:'Saved note',repeatDays:7},{id:'linked',draftId:'draft',title:'Exact draft review',dueDate:'2026-10-22',priority:'Medium'}];modal=(title,body,kind,footer,attrs)=>globalThis.captured={title,body,kind,footer,attrs};editTask('normal');`,c);
 assert.match(c.captured.body,/Follow up &lt;carefully&gt;/);
 assert.match(c.captured.body,/value="2026-10-20"/);
 assert.match(c.captured.body,/<option selected value="7">/);
 assert.equal(c.captured.kind,'task-edit');
 vm.runInContext("editTask('linked')",c);
 assert.match(c.captured.body,/name="dueDate"/);assert.match(c.captured.body,/name="priority"/);
 assert.doesNotMatch(c.captured.body,/name="title"|name="body"|name="type"|name="description"|name="repeatDays"/);
});
test('busy CSV work cannot be closed by Cancel or Escape',()=>{
 const c=context({name:'Fixture'});
 vm.runInContext("globalThis.CSVImportUI={isBusy:()=>true};toast=message=>globalThis.notice=message;closeModal=()=>{throw Error('must not close')};globalThis.closed=requestCloseModal();",c);
 assert.equal(c.closed,false);assert.match(c.notice,/Wait for the CSV operation/);
});
test('recorded instants use saved display zone while date-only records retain unknown time',()=>{
 const c=context({name:'Fixture',timezone:'America/Chicago'});
 const actual=vm.runInContext("dateTime('2026-10-13T01:15:00Z')",c);
 const expected=new Date('2026-10-13T01:15:00Z').toLocaleString('en-US',{timeZone:'America/Chicago',year:'numeric',month:'short',day:'numeric',hour:'numeric',minute:'2-digit',timeZoneName:'short'});
 assert.equal(actual,expected);assert.match(actual,/Oct 12/);
 assert.match(vm.runInContext("dateTime('2026-10-13')",c),/Oct 13.*time not recorded/);
 assert.match(c.ui.renderSettings(),/Manual date\/time entry uses this Mac’s local time zone/);
});
test('read-only history audit shows findings and truncation without repair controls',()=>{
 const c=context({name:'Fixture'});
 vm.runInContext("historyAuditState={generatedAt:'2026-10-13T12:00:00Z',totalFindings:201,findingCounts:{creation_time_unrecorded:201},findings:[{code:'creation_time_unrecorded',kind:'agents',recordId:'fixture<id>',recommendation:'Keep <original>'}],detailsTruncated:true,interpretation:'No records were changed.'}",c);
 const html=c.ui.renderRecovery();
 assert.match(html,/201 findings/);assert.match(html,/fixture&lt;id&gt;/);assert.match(html,/Keep &lt;original&gt;/);
 assert.match(html,/first 200 record references/);assert.match(html,/No records were changed/);
 assert.doesNotMatch(html,/data-action="repair/);
});
test('legacy backup action creates verified recovery snapshot instead of JSON backup',async()=>{
 const c=context({name:'Fixture'});
 vm.runInContext("globalThis.calls=[];native=async(action)=>{calls.push(action);return {verified:true}};toast=message=>globalThis.notice=message;refreshRecovery=async()=>{}",c);
 await vm.runInContext("handleAction({dataset:{action:'backup'}})",c);
 assert.deepEqual(Array.from(c.calls),['recovery.create']);
 assert.equal(c.notice,'Recovery snapshot created and verified');
});
