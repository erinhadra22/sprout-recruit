'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const source=fs.readFileSync(path.join(__dirname,'../Web/prospecting.js'),'utf8');
function context(extra={}){
 const calls=[],modals=[],notices=[],d={today:'2026-10-29',agents:[{id:'agent-a',name:'Morgan Example'}],professionalProfiles:[],teams:[],teamMemberships:[],prospectingEvidence:[]};
 const c=vm.createContext({URL,Date,console,FormData:class {constructor(f){this.values=f.values||{};}entries(){return Object.entries(this.values);}},document:{querySelectorAll:()=>[]},...extra});
 vm.runInContext(source+';globalThis.ui=ProspectingUI;',c);
 const hooks={getData:()=>d,native:async(a,p)=>{calls.push({a,p});return {};},mutate:async(a,p)=>{calls.push({a,p});},modal:(...args)=>modals.push(args),closeModal(){},render(){},toast:m=>notices.push(m)};
 c.ui.bind(hooks);return {c,ui:c.ui,calls,modals,notices,d,hooks};
}
const form=(kind,values,dataset={})=>({dataset:{kind,...dataset},values,querySelectorAll:()=>[],setAttribute(){},removeAttribute(){}});
const evidence={sourceLabel:'Official team website',sourceReference:'https://example.com/team',checkedAt:'2026-10-29',evidence:'Official biography links this account.'};
test('license intake preserves leading zeros, suffix and exact alias IDs without Courted',()=>{
 const {ui}=context();
 const p=ui.contactPayload({name:'Morgan',licenseRaw:'0001234-A',licenseJurisdiction:'TX',licenseType:'broker',sourceAliasesText:'[{"provider":"ntreis","sourceId":"0012-A"}]'});
 assert.equal(p.licenseRaw,'0001234-A');assert.equal(p.sourceAliases[0].sourceId,'0012-A');assert.equal(p.courtedProfileURL,undefined);assert.equal(p.sourceAliasesText,undefined);
 assert.throws(()=>ui.contactPayload({sourceAliasesText:'[{"provider":"ntreis","sourceId":123}]'}),/provider and sourceId text/);
 assert.throws(()=>ui.contactPayload({sourceAliasesText:'not json'}),/JSON array/);
 const fields=ui.contactIdentityFields({license:'00002'});assert.match(fields,/value="00002"/);assert.match(fields,/Courted is optional/);assert.match(fields,/name="licenseJurisdiction"/);assert.doesNotMatch(fields,/type="number"/);
});
test('blank optional license fields preserve compatibility for legacy manual contact edits',()=>{
 const {ui}=context();const p=ui.contactPayload({name:'Legacy',licenseRaw:'',licenseJurisdiction:'',licenseType:'',sourceAliasesText:'[]'});
 assert.equal(p.name,'Legacy');assert.equal(p.licenseRaw,undefined);assert.equal(p.licenseJurisdiction,undefined);assert.deepEqual(Array.from(p.sourceAliases),[]);
});
test('profile evidence supports multiple platforms and requires an explanation for verified identity',()=>{
 const {ui}=context();
 for(const [platform,url] of [['Instagram','https://www.instagram.com/agent/'],['YouTube','https://www.youtube.com/@agent'],['Business website','https://example.com/about']]){
  const p=ui.profilePayload({...evidence,platform,url,matchStatus:'verified'},{agentId:'agent-a'});assert.equal(p.platform,platform);assert.equal(p.matchStatus,'verified');assert.equal(p.expectedRevision,0);
 }
 assert.throws(()=>ui.profilePayload({...evidence,platform:'Instagram',url:'https://person:password@example.com/a',matchStatus:'possible'},{agentId:'agent-a'}),/HTTPS/);
 assert.throws(()=>ui.profilePayload({...evidence,evidence:'',platform:'Instagram',url:'https://example.com/a',matchStatus:'verified'},{agentId:'agent-a'}),/Explain the evidence/);
 assert.throws(()=>ui.profilePayload({...evidence,checkedAt:'2026-02-30',platform:'Instagram',url:'https://example.com/a',matchStatus:'possible'},{agentId:'agent-a'}),/valid checked date/);
});
test('profile rendering retains multiple accounts and escapes untrusted evidence and unsafe links',()=>{
 const {ui,d}=context();d.professionalProfiles=[{id:'one',agentId:'agent-a',platform:'instagram',url:'https://instagram.com/a',matchStatus:'verified',source:{label:'<source>',reference:'https://example.com'},checkedAt:'2026-10-29',evidence:'<script>alert(1)</script>'},{id:'two',agentId:'agent-a',platform:'instagram',url:'javascript:alert(2)',matchStatus:'rejected',source:{},evidence:'Not this person'}];
 const html=ui.professionalSection(d.agents[0],d);assert.match(html,/data-id="one"/);assert.match(html,/data-id="two"/);assert.match(html,/&lt;script&gt;/);assert.match(html,/&lt;source&gt;/);assert.doesNotMatch(html,/href="javascript:/);assert.doesNotMatch(html,/<script>/);
});
test('dated memberships reject invented or reversed dates and preserve edit revision',()=>{
 const {ui}=context();const values={...evidence,teamId:'team-a',role:'leader',startDate:'2025-01-01',endDate:''};
 const p=ui.membershipPayload(values,{id:'membership-a',agentId:'agent-a',revision:3});assert.equal(p.expectedRevision,3);assert.equal(p.agentId,'agent-a');assert.equal(p.endDate,'');
 assert.throws(()=>ui.membershipPayload({...values,startDate:''},{agentId:'agent-a'}),/valid membership start/);
 assert.throws(()=>ui.membershipPayload({...values,endDate:'2024-01-01'},{agentId:'agent-a'}),/ordered/);
 assert.throws(()=>ui.membershipPayload({...values,role:'owner'},{agentId:'agent-a'}),/saved team and role/);
});
test('sourcing workspace displays distinct discovery/import counters and full-pool reasons without quota padding',async()=>{
 const {ui,calls,d}=context();ui.bind({native:async(a,p)=>{calls.push({a,p});return {selectedArea:{id:'broader-waco',name:'Broader Waco',cities:['Waco','Woodway']},sourceMappings:[],staged:[],plan:{date:d.today,counters:{discoveredToday:3,importedToday:1,newProspectsGoal:10,actionGoal:10,actionCount:1,actionShortfall:9},actions:[{agentId:'agent-a',name:'Morgan <Example>',action:'Call back as promised',reason:'Promise from existing task',taskIds:['task-a'],missingEvidence:['Production period unknown'],priorityKind:'due_follow_up'}],excluded:[],notices:['No invented likelihood score.']}};}});
 await ui.activate();assert.equal(calls[0].a,'prospecting.workspace');
 const html=ui.render();assert.match(html,/New identities discovered today/);assert.match(html,/New contacts imported today/);assert.match(html,/Daily action priorities/);assert.match(html,/9 priority slots remain unfilled/);assert.match(html,/Morgan &lt;Example&gt;/);assert.match(html,/Promise from existing task/);assert.match(html,/Production period unknown/);assert.match(html,/data-action="task-detail" data-id="task-a"/);assert.match(html,/MLS source: Unconnected/);assert.match(html,/America\/Chicago/);assert.match(html,/Managed by the external ChatGPT workflow/);assert.doesNotMatch(html,/Not activated/);
});
test('professional evidence does not infer experience or opportunity from blank values',()=>{
 const {ui}=context();const p=ui.evidencePayload({...evidence,serviceCitiesText:'Waco\nWoodway\nWaco',experienceYears:'',opportunityKind:'none'},{revision:2},'agent-a');
 assert.equal(p.experienceYears,null);assert.deepEqual(Array.from(p.serviceCities),['Waco','Woodway']);assert.equal(p.opportunity.kind,'none');assert.equal(p.expectedRevision,2);
 assert.throws(()=>ui.evidencePayload({...evidence,serviceCitiesText:'Waco',experienceYears:'2',opportunityKind:'expressed_interest',opportunitySummary:'Interested',opportunityDate:'',opportunityReference:'https://example.com'}, {},'agent-a'),/statement date/);
});
test('source preview is read-only; staging requires a separate explicit action and preserves token',async()=>{
 const {ui,calls,modals}=context();ui.bind({native:async(a,p)=>{calls.push({a,p});if(a==='prospecting.preview')return {count:1,rows:[{name:'Example',fields:{license:'001'},source:{kind:'fixture'},qualification:{state:'needs_evidence',missingEvidence:['production unknown']}}],hardConflicts:[],readyCount:0,previewToken:'exact-token'};return {selectedArea:{id:'broader-waco'},staged:[],plan:{counters:{}}};}});
 await ui.handleSubmit(form('prospect-source',{mappingId:'reso-member-2',providerId:'fixture',sourceLabel:'Fixture only',sourceReference:'fixture.json',sourceKind:'fixture',checkedAt:'2026-10-29',rowsJSON:'[{"MemberFullName":"Example","MemberStateLicense":"001"}]'}));
 assert.equal(calls.length,1);assert.equal(calls[0].a,'prospecting.preview');assert.match(modals[0][1],/No CRM contacts have been added/);assert.match(modals[0][3],/Save to discovery staging/);
 await ui.handleAction({dataset:{action:'prospect-stage'}});const stage=calls.find(x=>x.a==='discovery.stage');assert.equal(stage.p.previewToken,'exact-token');assert.equal(stage.p.source.kind,'fixture');assert.equal(stage.p.rows[0].MemberStateLicense,'001');assert.equal(calls.some(x=>x.a==='discovery.accept'),false);
});
test('sourcing operations prevent duplicate native writes while a request is pending',async()=>{
 const {ui,calls}=context();let resolve;ui.bind({mutate:async(a,p)=>{calls.push({a,p});await new Promise(r=>resolve=r);}});
 const f=form('prospect-profile',{...evidence,platform:'Instagram',url:'https://instagram.com/agent',matchStatus:'verified'},{agentId:'agent-a'});
 const pending=ui.handleSubmit(f);assert.equal(ui.isBusy(),true);await assert.rejects(ui.handleSubmit(f),/already running/);assert.equal(calls.length,1);resolve();await pending;assert.equal(ui.isBusy(),false);
});
test('app wires sourcing navigation, manual identity payload and professional tab for imported contacts',()=>{
 const app=fs.readFileSync(path.join(__dirname,'../Web/app.js'),'utf8'),csv=fs.readFileSync(path.join(__dirname,'../Web/csv-import.js'),'utf8');
 assert.match(app,/Sourcing & priorities','sourcing'/);assert.match(app,/ProspectingUI\.contactPayload\(values\)/);assert.match(app,/ProspectingUI\.contactIdentityFields\(a\)/);assert.match(csv,/Professional evidence/);assert.match(csv,/ProspectingUI\.professionalSection\(agent,D\)/);
});
test('reusable source mapping sends a stable ID and exact current revision',async()=>{
 const {ui,calls}=context();await ui.handleSubmit(form('prospect-mapping',{name:'Waco Member Export',fieldsJSON:'{"name":"MemberFullName","license":"MemberStateLicense"}',defaultsJSON:'{"licenseJurisdiction":"TX","licenseType":"sales-agent"}'}));
 const save=calls[0];assert.equal(save.a,'sourceMapping.save');assert.equal(save.p.id,'source-map-waco-member-export');assert.equal(save.p.expectedRevision,0);assert.equal(save.p.fields.license,'MemberStateLicense');assert.equal(save.p.defaults.licenseType,'sales-agent');
 await ui.handleSubmit(form('prospect-mapping',{name:'Waco Member Export',fieldsJSON:'{"license":"License"}',defaultsJSON:'{}'},{id:save.p.id,revision:'3'}));assert.equal(calls[1].p.expectedRevision,3);assert.equal(calls[1].p.id,save.p.id);
});
test('service area creation preserves fixed baseline and does not change a schedule',async()=>{
 const {ui,calls}=context();await ui.handleSubmit(form('prospect-area',{name:'Temple Area',jurisdiction:'TX',citiesText:'Temple\nBelton',minExperienceYears:'2',minIndividualVolume:'2000000',productionMaxAgeDays:'365',evidenceMaxAgeDays:'90'}));
 assert.equal(calls.length,1);assert.equal(calls[0].a,'serviceArea.save');assert.equal(calls[0].p.id,'area-temple-area-tx');assert.equal(calls[0].p.jurisdiction,'TX');assert.equal(calls[0].p.minIndividualVolume,2000000);assert.deepEqual(Array.from(calls[0].p.cities),['Temple','Belton']);
});
test('fixture staging cannot be selected for live import and no contact is imported by opening review',async()=>{
 const {ui,c,calls,modals}=context();const staged=[{id:'s1',revision:2,name:'Test fixture',serviceAreaId:'broader-waco',isFixture:true,fields:{license:'001'},qualification:{state:'needs_evidence'}}];
 ui.bind({native:async(a,p)=>{calls.push({a,p});return {selectedArea:{id:'broader-waco'},staged,plan:{actions:[],counters:{}}};}});await ui.activate();assert.match(ui.render(),/data-discovery-id="s1"[^>]*disabled/);
 c.document.querySelectorAll=()=>[{dataset:{discoveryId:'s1'}}];await assert.rejects(ui.handleAction({dataset:{action:'prospect-accept-review'}}),/fixture records cannot be imported/);assert.equal(calls.some(x=>x.a==='discovery.accept'),false);
 staged[0].isFixture=false;await ui.activate();await ui.handleAction({dataset:{action:'prospect-accept-review'}});assert.equal(calls.some(x=>x.a==='discovery.accept'),false);assert.match(modals.at(-1)[1],/does not make them today’s call priorities/);
 await ui.handleAction({dataset:{action:'prospect-accept-confirm'}});const accept=calls.find(x=>x.a==='discovery.accept');assert.equal(accept.p.expectedRevisions.s1,2);assert.equal(accept.p.reviewConfirmed,true);assert.deepEqual(Array.from(accept.p.recordIds),['s1']);
});
test('ten unknown identities do not satisfy the qualified-new goal',async()=>{
 const {ui}=context();ui.bind({native:async()=>({selectedArea:{id:'broader-waco',name:'Broader Waco',jurisdiction:'TX'},staged:[],plan:{actions:[],counters:{discoveredToday:10,importedToday:4,qualifiedDiscoveryToday:0,needsEvidenceDiscoveryToday:10,qualifiedDiscoveryShortfall:10,newProspectsGoal:10,actionCount:0,actionGoal:10,actionShortfall:10}}})});await ui.activate();const html=ui.render();
 assert.match(html,/New identities discovered today/);assert.match(html,/this is not a qualified-prospect count/);assert.match(html,/Production-qualified new prospects today/);assert.match(html,/10 new identities still need evidence/);assert.match(html,/10 production-qualified prospects short of the goal/);assert.match(html,/Broader Waco · TX/);
 assert.match(html,/New identities discovered today<\/span><strong>10<\/strong>/);assert.match(html,/Production-qualified new prospects today<\/span><strong>0 <small>\/ 10 goal/);
});
test('service-area editor requires jurisdiction and professional evidence preserves separate service scope',async()=>{
 const {ui,modals,calls}=context();await ui.handleAction({dataset:{action:'prospect-area'}});assert.match(modals[0][1],/name="jurisdiction"[^>]*value="TX"/);
 await assert.rejects(ui.handleSubmit(form('prospect-area',{name:'Springfield',jurisdiction:'',citiesText:'Springfield',minExperienceYears:'2',minIndividualVolume:'2000000',productionMaxAgeDays:'365',evidenceMaxAgeDays:'90'})),/service-area jurisdiction/);assert.equal(calls.length,0);
 const p=ui.evidencePayload({...evidence,serviceJurisdiction:'tx',serviceCitiesText:'Waco',experienceYears:'2',opportunityKind:'none'},{},'agent-a');assert.equal(p.serviceJurisdiction,'TX');
});


test('prospecting uses Central calendar days across UTC midnight and daylight saving changes',async()=>{
 const fixedInstant='2026-10-29T01:00:00Z';
 class FixedDate extends Date {constructor(...args){super(...(args.length?args:[fixedInstant]));}}
 const {ui,calls,d}=context({Date:FixedDate});d.today='2099-01-01';
 for(const [instant,expected] of [
  [fixedInstant,'2026-10-28'],['2026-10-29T05:00:00Z','2026-10-29'],
  ['2026-03-08T05:59:59Z','2026-03-07'],['2026-03-08T06:00:00Z','2026-03-08'],
  ['2026-03-09T04:59:59Z','2026-03-08'],['2026-03-09T05:00:00Z','2026-03-09'],
  ['2025-11-02T04:59:59Z','2025-11-01'],['2025-11-02T05:00:00Z','2025-11-02'],
  ['2025-11-03T05:59:59Z','2025-11-02'],['2025-11-03T06:00:00Z','2025-11-03']
 ])assert.equal(ui.calendarDay(new Date(instant)),expected,instant);
 await ui.activate();assert.equal(calls[0].p.asOfDate,'2026-10-28','global host date does not override the Central working day');
});

const stalePlan=/Saved records changed after this plan was calculated/;
const clone=value=>JSON.parse(JSON.stringify(value));
function planResult(day){return {selectedArea:{id:'broader-waco',name:'Broader Waco'},staged:[],plan:{date:day,actions:[],counters:{actionCount:0,actionShortfall:10}}};}
test('equivalent snapshots and unrelated polling or viewed timestamps keep priorities fresh',async()=>{
 const {ui,d}=context();let snapshot=clone(d);
 snapshot.agents.push({id:'agent-b',name:'Taylor Example',license:'0002',licenseJurisdiction:'TX'});
 snapshot.tasks=[{id:'task-a',agentId:'agent-a',title:'Promised call',dueDate:'2026-10-29',completed:false}];
 ui.bind({getData:()=>snapshot,native:async(a,p)=>planResult(p.asOfDate)});
 await ui.activate();assert.doesNotMatch(ui.render(),stalePlan);
 snapshot=clone(snapshot);assert.doesNotMatch(ui.render(),stalePlan,'cloning the whole snapshot is not an evidence change');
 snapshot.agents.reverse();snapshot.agents=snapshot.agents.map(a=>Object.fromEntries(Object.entries(a).reverse()));
 snapshot.tasks=snapshot.tasks.map(t=>Object.fromEntries(Object.entries(t).reverse()));
 assert.doesNotMatch(ui.render(),stalePlan,'record order and object key order do not affect freshness');
 snapshot.gmailSync={lastAttemptAt:'2026-10-30T14:30:00Z',revision:100};snapshot.messagesSync={cursor:222};snapshot.settings=[{id:'gmail-sync',revision:101}];
 snapshot.outboxJobs=[{id:'poll',updatedAt:'2026-10-30T14:31:00Z'}];snapshot.activities=[{id:'view-event'}];
 snapshot.agents[0].viewedAt='2026-10-30T14:31:00Z';snapshot.agents[0].updatedAt='2026-10-30T14:31:00Z';snapshot.agents[0].emailCompanyReview={computedAt:'now'};
 assert.doesNotMatch(ui.render(),stalePlan,'unrelated sync metadata and viewing a contact do not invalidate priorities');
});
test('contact eligibility and identity changes invalidate priorities until refreshed',async()=>{
 const {ui,d}=context();let snapshot=clone(d);
 ui.bind({getData:()=>snapshot,native:async(a,p)=>planResult(p.asOfDate)});
 for(const [field,value] of [['status','Do not contact'],['doNotContact',true],['disposition','snoozed'],['identityReviewState','held'],['recruitingEligibility',{mode:'interim_license_tenure',state:'interim_eligible',productionThresholdMet:false}],['datasetId','sample'],['source','Fictional sample'],['licenseRaw','000123-A'],['licenseJurisdiction','CA'],['licenseType','broker'],['sourceAliases',[{provider:'ntreis',sourceId:'001'}]],['phone','+12025550123'],['communicationVerification',{confirmed:true,name:'Morgan Example',phone:'+12025550123'}],['importedAt','2026-10-30T06:00:00Z']]){
  snapshot=clone(d);await ui.activate();assert.doesNotMatch(ui.render(),stalePlan);
  snapshot.agents[0][field]=value;assert.match(ui.render(),stalePlan,field+' affects eligibility, identity or counters');
  await ui.activate();assert.doesNotMatch(ui.render(),stalePlan,'refresh accepts current '+field);
 }
});
test('task edits and all saved sourcing evidence collections invalidate priorities',async()=>{
 const {ui,d}=context();let snapshot=clone(d);
 ui.bind({getData:()=>snapshot,native:async(a,p)=>planResult(p.asOfDate)});
 for(const kind of ['tasks','sequences','prospectingEvidence','performance','professionalProfiles','teams','teamMemberships','serviceAreas','sourceMappings','discoveryProspects']){
  snapshot=clone(d);snapshot[kind]=[{id:'record-a',revision:1}];await ui.activate();
  snapshot=clone(snapshot);snapshot[kind][0].revision=2;assert.match(ui.render(),stalePlan,kind+' update must invalidate');
  await ui.activate();assert.doesNotMatch(ui.render(),stalePlan);
  snapshot[kind]=[];assert.match(ui.render(),stalePlan,kind+' removal must invalidate');
 }
 snapshot=clone(d);snapshot.tasks=[{id:'task-a',agentId:'agent-a',title:'Call',dueDate:'2026-10-29',completed:false}];await ui.activate();
 snapshot.tasks[0].completed=true;assert.match(ui.render(),stalePlan,'completing a follow-up changes priorities');
 await ui.activate();snapshot.tasks[0].dueDate='2026-11-02';assert.match(ui.render(),stalePlan,'rescheduling a commitment changes priorities');
});
test('a refresh cannot claim fresh results when evidence changes while the native request is in flight',async()=>{
 const {ui,d}=context();let snapshot=clone(d),resolve;
 ui.bind({getData:()=>snapshot,native:async()=>new Promise(r=>resolve=r)});
 const pending=ui.activate();snapshot=clone(snapshot);snapshot.tasks=[{id:'new-promise',agentId:'agent-a',dueDate:'2026-10-30'}];
 resolve(planResult(ui.calendarDay()));await pending;assert.match(ui.render(),stalePlan);
 ui.bind({native:async(a,p)=>planResult(p.asOfDate)});await ui.activate();assert.doesNotMatch(ui.render(),stalePlan,'a second refresh binds the changed evidence');
});
test('equivalent polling snapshots during an in-flight refresh do not produce a false stale result',async()=>{
 const {ui,d}=context();let snapshot=clone(d),resolve;
 ui.bind({getData:()=>snapshot,native:async()=>new Promise(r=>resolve=r)});
 const pending=ui.activate();snapshot=clone(snapshot);snapshot.gmailSync={revision:44};snapshot.agents[0].viewedAt='2026-10-30T16:00:00Z';
 resolve(planResult(ui.calendarDay()));await pending;assert.doesNotMatch(ui.render(),stalePlan);
});
test('priorities become stale at Central midnight, including a rollover during refresh',async()=>{
 let instant='2026-10-30T04:59:59Z';
 class ClockDate extends Date {constructor(...args){super(...(args.length?args:[instant]));}}
 const {ui}=context({Date:ClockDate});ui.bind({native:async(a,p)=>planResult(p.asOfDate)});
 await ui.activate();assert.doesNotMatch(ui.render(),stalePlan);
 instant='2026-10-30T05:00:00Z';assert.match(ui.render(),stalePlan,'the old Central day is stale even without any new snapshot');
 await ui.activate();assert.doesNotMatch(ui.render(),stalePlan);
 instant='2026-10-31T04:59:59Z';let resolve;ui.bind({native:async()=>new Promise(r=>resolve=r)});
 const pending=ui.activate();instant='2026-10-31T05:00:00Z';resolve(planResult('2026-10-30'));await pending;
 assert.match(ui.render(),stalePlan,'crossing midnight while refreshing cannot mark yesterday fresh');
});


test('eligibility editor defaults to full criteria and saves explicit interim mode without changing production thresholds',async()=>{
 const {ui,calls,modals}=context();await ui.handleAction({dataset:{action:'prospect-area'}});
 assert.match(modals.at(-1)[1],/name="eligibilityMode"/);assert.match(modals.at(-1)[1],/value="full_production" selected/);assert.match(modals.at(-1)[1],/value="interim_license_tenure"/);
 const values={name:'Broader Waco',jurisdiction:'TX',citiesText:'Waco\nWoodway',minExperienceYears:'2',minIndividualVolume:'2000000',productionMaxAgeDays:'365',evidenceMaxAgeDays:'90'};
 await ui.handleSubmit(form('prospect-area',{...values,eligibilityMode:'interim_license_tenure'},{id:'broader-waco',revision:'3'}));
 const interim=calls.find(x=>x.a==='serviceArea.save').p;assert.equal(interim.eligibilityMode,'interim_license_tenure');assert.equal(interim.minIndividualVolume,2000000);assert.equal(interim.minExperienceYears,2);assert.equal(interim.expectedRevision,3);
 await ui.handleSubmit(form('prospect-area',{...values,eligibilityMode:'full_production'},{id:'broader-waco',revision:'4'}));assert.equal(calls.at(-1).p.eligibilityMode,'full_production');
 await assert.rejects(ui.handleSubmit(form('prospect-area',{...values,eligibilityMode:'ignore-evidence'})),/supported eligibility mode/);assert.equal(calls.length,2);
});
test('interim counters and review preserve production gaps and do not claim call readiness',async()=>{
 const {ui,c,calls,modals}=context();const row={id:'interim-one',revision:2,name:'Verified license prospect',serviceAreaId:'broader-waco',fields:{licenseRaw:'000123-SA',individualVolume:null},source:{label:'Official registry and professional site'},qualification:{state:'interim_eligible',productionThresholdMet:false,reasons:['Active verified individual license; two years since original licensure; Waco service corroborated'],missingEvidence:['Individual annual/LTM production unknown'],fullProductionQualification:{state:'needs_evidence',missingEvidence:['Individual annual/LTM production unknown']}}};
 const workspace={selectedArea:{id:'broader-waco',eligibilityMode:'interim_license_tenure'},staged:[row],plan:{actions:[],counters:{discoveredToday:10,importedToday:0,qualifiedDiscoveryToday:1,interimEligibleDiscoveryToday:9,eligibleDiscoveryToday:10,eligibleDiscoveryShortfall:0,newProspectsGoal:10,actionCount:0,actionGoal:10}}};
 ui.bind({native:async(a,p)=>{calls.push({a,p});return workspace;}});await ui.activate();const html=ui.render();
 assert.match(html,/Production-qualified new prospects today<\/span><strong>1<\/strong>/);assert.match(html,/Interim-eligible new prospects today<\/span><strong>9<\/strong>/);assert.match(html,/Eligible new prospects today<\/span><strong>10 <small>\/ 10 goal/);assert.match(html,/0 eligible prospects short of the goal/);
 assert.match(html,/Interim eligible/);assert.match(html,/Individual \$2M production threshold: unverified/);assert.match(html,/Individual annual\/LTM production unknown/);assert.match(html,/Recruiting interest and call readiness are not established/);assert.match(html,/Original licensure measures recorded license tenure, not uninterrupted practice/);assert.equal(row.fields.individualVolume,null);
 c.document.querySelectorAll=()=>[{dataset:{discoveryId:'interim-one'}}];await ui.handleAction({dataset:{action:'prospect-accept-review'}});assert.match(modals.at(-1)[1],/0 production-qualified; 1 interim-eligible/);assert.match(modals.at(-1)[1],/does not make them today’s call priorities/);assert.equal(calls.some(x=>x.a==='discovery.accept'),false);
});
test('missing interim evidence stays visibly held and switching modes reflects the native assessment',async()=>{
 const {ui}=context();const workspace={selectedArea:{id:'broader-waco',eligibilityMode:'interim_license_tenure'},staged:[{id:'held',fields:{},qualification:{state:'needs_evidence',blockingEvidence:['Verified identity missing','Active individual licensure missing','Original license date missing','Corroborated Waco service missing'],missingEvidence:['Verified identity missing','Active individual licensure missing','Original license date missing','Corroborated Waco service missing']}}],plan:{actions:[],counters:{qualifiedDiscoveryToday:0,interimEligibleDiscoveryToday:0,eligibleDiscoveryToday:0,eligibleDiscoveryShortfall:10}}};
 ui.bind({native:async()=>workspace});await ui.activate();let html=ui.render();assert.match(html,/Needs evidence/);for(const gap of workspace.staged[0].qualification.blockingEvidence)assert.ok(html.includes(gap));assert.doesNotMatch(html,/<strong>Interim eligible<\/strong>/);
 workspace.selectedArea.eligibilityMode='full_production';workspace.staged[0].qualification={state:'needs_evidence',missingEvidence:['Individual production unknown']};await ui.activate();html=ui.render();assert.match(html,/Full production mode: 2\+ years of verified experience/);assert.match(html,/Individual production unknown/);assert.doesNotMatch(html,/Eligible new prospects today<\/span>/);
});
test('professional evidence displays registry tenure separately from unknown continuous experience',()=>{
 const {ui,d}=context();d.prospectingEvidence=[{agentId:'agent-a',serviceCities:['Waco'],serviceJurisdiction:'TX',experienceYears:null,licenseStatus:'Active',originalLicenseDate:'2020-03-21',licenseCheckedAt:'2026-11-02',licenseReference:'https://data.texas.gov/example',identityMatchStatus:'verified',identityCheckedAt:'2026-11-02',identityReference:'Official profile <source>',source:{},checkedAt:'2026-11-02'}];
 const html=ui.recruitingEvidenceSection(d.agents[0],d);assert.match(html,/Original licensure: 2020-03-21/);assert.match(html,/Experience: Unknown/);assert.match(html,/Identity match: verified/);assert.match(html,/Official profile &lt;source&gt;/);assert.match(html,/does not establish uninterrupted practice or individual production/);assert.doesNotMatch(html,/Experience: 6 years/);
});
test('target-audience and affiliation edits invalidate a saved sourcing plan',async()=>{
 const {ui,d}=context();let snapshot=clone(d);snapshot.settings=[{id:'sourcing-rules',revision:1,excludedBrokerages:['Acme Realty'],excludedTeams:[]}];
 ui.bind({getData:()=>snapshot,native:async(a,p)=>planResult(p.asOfDate)});await ui.activate();assert.doesNotMatch(ui.render(),stalePlan);
 snapshot.settings[0].excludedTeams=['Blocked Team'];assert.match(ui.render(),stalePlan,'changing exclusions invalidates priorities');
 await ui.activate();assert.doesNotMatch(ui.render(),stalePlan);
 snapshot.settings.push({id:'sourcing-rules-revision-000001',revision:1});assert.doesNotMatch(ui.render(),stalePlan,'immutable history is not a current-rule change');
 for(const [field,value] of [['office','Acme Realty'],['brand','Acme Realty'],['brokerage','Acme Realty'],['teamName','Blocked Team']]){
  await ui.activate();snapshot.agents[0][field]=value;assert.match(ui.render(),stalePlan,field+' affects eligibility');
 }
 await ui.activate();snapshot.settings=[];assert.match(ui.render(),stalePlan,'removing current rules invalidates the prior result');
});
