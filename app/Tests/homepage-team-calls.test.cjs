'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const root=path.join(__dirname,'../Web');
const escape=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function context(snapshot){
 const c=vm.createContext({D:snapshot,E:escape,console,Date,Intl,document:{addEventListener:()=>{}},btn:(label,action,icon='',attrs='')=>`<button data-action="${action}" ${attrs}>${escape(label)}</button>`,pageHeader:(title,sub,actions)=>`<h1>${title}</h1>${actions}`,insight:label=>`<span>${label}</span>`});
 vm.runInContext(fs.readFileSync(path.join(root,'csv-import.js'),'utf8')+';globalThis.ui=CSVImportUI',c);
 return c;
}
const now=new Date('2026-11-10T18:00:00Z');
function fixture(){return {agents:[{id:'a',datasetId:'live',name:'Alex Leader',phone:'512-555-0100',status:'Identified'},{id:'b',datasetId:'live',name:'Bailey Leader',status:'Identified'},{id:'sample',datasetId:'sample',name:'Sample Person'}],watchlists:[{id:'w',name:'Team Acquisition',agentIds:['a','b','sample']}],tasks:[{id:'call-a',agentId:'a',type:'Call',title:'Team acquisition call — Austin Team',description:'Ask about a team acquisition conversation.\nSource: verified source reference.',dueDate:'2026-11-10',priority:'High',createdAt:'2026-11-10T17:00:00Z',completed:false}],sequences:[],importBatches:[]};}
const plan=(data,date=now)=>context(data).ui.teamCallPlan(data,date);
test('daily list uses explicit open Call tasks for the saved team-acquisition group',()=>{
 const data=fixture();data.tasks.push(
  {...data.tasks[0],id:'done',agentId:'b',completed:true},
  {...data.tasks[0],id:'future',agentId:'b',dueDate:'2026-11-11'},
  {...data.tasks[0],id:'review',type:'Review'},
  {...data.tasks[0],id:'unrelated',title:'Routine follow-up'},
  {...data.tasks[0],id:'sample',agentId:'sample'},
  {...data.tasks[0],id:'missing',agentId:'missing'},
  {...data.tasks[0],id:'invalid',dueDate:'not-a-day'},
  {...data.tasks[0],id:'invalid-day',dueDate:'2026-02-30'}
 );
 const result=plan(data);assert.equal(result.date,'2026-11-10');assert.equal(result.today.length,1);assert.equal(result.today[0].agent.id,'a');assert.equal(result.today[0].tasks[0].id,'call-a');assert.equal(result.held.length,0);
 data.watchlists=[];assert.equal(plan(data).today.length,0);
});
test('same-contact objectives collapse into one call while all saved task IDs remain reachable',()=>{
 const data=fixture();data.tasks.push({...data.tasks[0],id:'second',title:'Team acquisition call — Partner Team'});
 const result=plan(data);assert.equal(result.today.length,1);assert.deepEqual(Array.from(result.today[0].tasks,task=>task.id),['call-a','second']);
 const html=context(data).ui.teamCallsSection(data,now);assert.match(html,/Austin Team \/ Partner Team/);assert.match(html,/data-id="call-a"/);assert.match(html,/data-id="second"/);
});
test('Central working day handles midnight and DST without carrying prior calls into today',()=>{
 const data=fixture();data.tasks[0].dueDate='2026-11-09';
 assert.equal(plan(data,new Date('2026-11-10T05:59:59Z')).today.length,1);
 const next=plan(data,new Date('2026-11-10T06:00:00Z'));assert.equal(next.today.length,0);assert.equal(next.overdue.length,1);assert.equal(next.overdue[0].dueDate,'2026-11-09');
 const c=context(data);assert.equal(c.ui.teamCallDay(new Date('2026-07-10T04:59:59Z')),'2026-07-09');assert.equal(c.ui.teamCallDay(new Date('2026-07-10T05:00:00Z')),'2026-07-10');
 assert.equal(c.ui.teamCallDay(new Date('2026-11-01T06:30:00Z')),'2026-11-01');assert.equal(c.ui.teamCallDay(new Date('2026-11-01T07:30:00Z')),'2026-11-01');
});
test('DNC, identity, snooze and reply or meeting pauses are held separately, never labeled planned calls',()=>{
 for(const change of [data=>data.agents[0].doNotContact=true,data=>data.agents[0].status='Not interested',data=>data.agents[0].disposition='snoozed',data=>data.agents[0].identityReviewState='conflict',data=>data.tasks.push({id:'hold',agentId:'a',identityHoldId:'identity-review'}),data=>data.tasks.push({id:'reply',agentId:'a',followUpState:'paused_reply'}),data=>data.sequences.push({id:'s',agentId:'a',pendingOutputState:'paused_reply'})]){
  const data=fixture();change(data);const result=plan(data);assert.equal(result.today.length,0);assert.equal(result.held.length,1);assert.ok(result.held[0].holds.length);
  const html=context(data).ui.teamCallsSection(data,now);assert.match(html,/Held for review \(1\)/);assert.match(html,/Needs review/);assert.doesNotMatch(html,/>Planned call</);
 }
});
test('completion, reschedule and new records are reflected from the current snapshot without writes',()=>{
 const data=fixture(),before=JSON.stringify(data),c=context(data);c.ui.teamCallsSection(data,now);c.ui.teamCallsSection(data,now);assert.equal(JSON.stringify(data),before);
 data.tasks[0].completed=true;assert.equal(c.ui.teamCallPlan(data,now).today.length,0);
 data.tasks[0].completed=false;data.tasks[0].dueDate='2026-11-11';assert.equal(c.ui.teamCallPlan(data,now).today.length,0);
 data.tasks[0].dueDate='2026-11-10';assert.equal(c.ui.teamCallPlan(data,now).today.length,1);
});
test('task priority then creation order is stable and no due obligations are silently truncated',()=>{
 const data=fixture();data.tasks[0].priority='Low';data.tasks.push({...data.tasks[0],id:'b',agentId:'b',priority:'High',title:'Team acquisition call — Dallas Team'});
 assert.deepEqual(Array.from(plan(data).today,row=>row.agent.id),['b','a']);
 for(let i=0;i<11;i++){const id='extra-'+i;data.agents.push({id,datasetId:'live',name:id});data.watchlists[0].agentIds.push(id);data.tasks.push({...data.tasks[0],id,agentId:id});}
 assert.equal(plan(data).today.length,13);
});
test('homepage cards escape content and provide only exact contact/task navigation',()=>{
 const data=fixture();data.agents[0].name='<script>unsafe</script>';data.tasks[0].title='Team acquisition call — <Team & Co>';data.tasks[0].description='<img src=x>\n'+ 'x'.repeat(1000);
 const html=context(data).ui.teamCallsSection(data,now);
 assert.match(html,/Today’s Texas team calls/);assert.match(html,/Central Time/);assert.match(html,/&lt;Team &amp; Co&gt;/);assert.match(html,/&lt;script&gt;unsafe&lt;\/script&gt;/);assert.match(html,/&lt;img src=x&gt;/);assert.doesNotMatch(html,/<script>|<img |x{250}/);
 assert.match(html,/data-action="profile" data-id="a"/);assert.match(html,/data-action="task-detail" data-id="call-a"/);assert.doesNotMatch(html,/tel:|sms:|data-action="(?:call|send|task-complete)"/);
});
test('empty, held-only and overdue lists retain honest dates and the original dashboard sections',()=>{
 const data=fixture();data.tasks[0].dueDate='2026-11-09';const c=context(data),html=c.ui.teamCallsSection(data,now);assert.match(html,/No team calls are planned for today yet/);assert.match(html,/Overdue team calls \(1\)/);assert.match(html,/Original due dates are preserved/);
 const full=c.ui.dashboard();assert.ok(full.indexOf('Today’s Texas team calls')<full.indexOf('<span>CRM contacts'));assert.match(full,/Pipeline/);assert.match(full,/Imported candidates/);
 const source=fs.readFileSync(path.join(root,'app.js'),'utf8');assert.match(source,/const S=\{page:'dashboard'/);
});

test('shared-phone identity reviews and native paused-sequence representations remain held',()=>{
 for(const change of [data=>data.sequences.push({agentId:'a',state:'paused',pauseReason:'ambiguous_reply_identity'}),data=>data.tasks.push({id:'identity-review',reviewKind:'messages-sync-ambiguous-phone',candidateIDs:['a','b'],completed:false}),data=>data.settings=[{reasonCode:'ambiguous_reply_identity',state:'pending',phone:'+15125550100',pendingReplies:[{providerMessageId:'guid'}]}]]){
  const data=fixture();change(data);const result=plan(data);assert.equal(result.today.length,0);assert.equal(result.held.length,1);
 }
 const data=fixture();data.tasks.push({id:'old-review',reviewKind:'messages-sync-ambiguous-phone',candidateIDs:['a'],completed:true});data.settings=[{reasonCode:'ambiguous_reply_identity',state:'resolved',phone:'+15125550100',pendingReplies:[]}];assert.equal(plan(data).today.length,1);
});
test('unchanged-database polling refreshes an idle homepage on Central day rollover and respects pending edits',async()=>{
 const source=fs.readFileSync(path.join(root,'app.js'),'utf8'),snapshot=fixture(),calls=[];
 const document={hidden:false,activeElement:null,getElementById:id=>id==='overlay'?{children:[]}:{scrollTop:15},querySelectorAll:()=>[]};
 let day='2026-11-10';
 const c=vm.createContext({Model:require('../Web/model.js'),CSVImportUI:{teamCallDay:()=>day},document,window:{},console,icon:()=>'',snapshot,calls});
 vm.runInContext(source.slice(0,source.indexOf("document.addEventListener('click'"))+`;D=snapshot;lastDatabaseVersion=7;lastRenderedTeamCallDay='2026-11-09';native=async action=>{calls.push(action);return action==='workspace.version'?{dataVersion:7}:snapshot};render=()=>{globalThis.renderCount=(globalThis.renderCount||0)+1;lastRenderedTeamCallDay=CSVImportUI.teamCallDay()};globalThis.refresh=refreshLocalChanges;`,c);
 await c.refresh();assert.equal(c.renderCount,1);assert.deepEqual(calls,['workspace.version','snapshot']);
 await c.refresh();assert.equal(c.renderCount,1);assert.deepEqual(calls,['workspace.version','snapshot','workspace.version']);
 day='2026-11-11';document.activeElement={isContentEditable:true};await c.refresh();assert.equal(c.renderCount,1);
 document.activeElement=null;await c.refresh();assert.equal(c.renderCount,2);
});
