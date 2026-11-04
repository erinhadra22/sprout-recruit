'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const Model=require('../Web/model.js');
const web=path.join(__dirname,'../Web');
function appContext(){
 const form={},overlay={innerHTML:'draft remains'},error={innerHTML:'',querySelector:()=>({focus(){}})};
 const elements={'modal-form':form,overlay,'form-error':error};
 const context=vm.createContext({Model,icon:()=>'',document:{getElementById:id=>elements[id]},window:{},console});
 const source=fs.readFileSync(path.join(web,'app.js'),'utf8');
 for(const file of ['task-controls.js','weekly-reports.js','sourcing-rules.js','meetings.js'])vm.runInContext(fs.readFileSync(path.join(web,file),'utf8'),context);
 vm.runInContext(source.slice(0,source.indexOf("document.addEventListener('click'"))+';globalThis.helpers={btn,ib,agentCell,recruitingEligibilityNotice,requestCloseModal,closeModal,markDirty:form=>dirtyForms.add(form)}',context);
 return {context,form,overlay,error,helpers:context.helpers};
}
test('action controls never become the default form submit button',()=>{
 const {helpers}=appContext();
 assert.match(helpers.btn('Cancel','close-modal'),/^<button type="button"/);
 assert.match(helpers.ib('Close','close-modal','close'),/^<button type="button"/);
});
test('dirty modal close keeps edits until an explicit discard while completed saves can close',()=>{
 const {helpers,form,overlay,error}=appContext();
 helpers.markDirty(form);
 assert.equal(helpers.requestCloseModal(),false);
 assert.equal(overlay.innerHTML,'draft remains');
 assert.match(error.innerHTML,/data-action="discard-modal"/);
 helpers.closeModal();
 assert.equal(overlay.innerHTML,'');
});
test('clean modal closes immediately',()=>{
 const {helpers,overlay}=appContext();
 assert.equal(helpers.requestCloseModal(),true);
 assert.equal(overlay.innerHTML,'');
});
test('contact activity columns include available time and mark date-only history honestly',()=>{
 const {helpers}=appContext();
 const instant='2026-10-12T21:35:00Z';
 assert.equal(helpers.agentCell({viewedAt:instant},'viewedAt'),Model.dateTime(instant));
 assert.match(helpers.agentCell({lastInteraction:'2026-10-12'},'lastInteraction'),/time not recorded/);
});
test('contact avatars load a saved local photo on demand and retain initials as fallback',async()=>{
 const calls=[],agent={id:'fixture-agent',name:'Fixture Agent',photoAvailable:true};
 const node={dataset:{agentPhotoId:agent.id},isConnected:true,classList:{add(value){this.value=value;}},replaceChildren(image){this.image=image;}};
 const document={querySelectorAll:()=>[node],createElement:()=>({})};
 const dataUri='data:image/png;base64,aGVsbG8=';
 const context=vm.createContext({Model,icon:()=>'',document,window:{webkit:{messageHandlers:{sprout:{postMessage:async request=>{calls.push(request);return {dataUri};}}}}},console,agent});
 const source=fs.readFileSync(path.join(web,'app.js'),'utf8');
 for(const file of ['task-controls.js','weekly-reports.js','sourcing-rules.js','meetings.js'])vm.runInContext(fs.readFileSync(path.join(web,file),'utf8'),context);
 vm.runInContext(source.slice(0,source.indexOf("document.addEventListener('click'"))+';D={agents:[agent]};globalThis.photoHelpers={avatar,loadAgentPhoto}',context);
 const helpers=context.photoHelpers;
 assert.match(helpers.avatar(agent),/data-agent-photo-id="fixture-agent"/);
 assert.match(helpers.avatar({...agent,photoAvailable:false}),/>FA<\/span>/);
 assert.equal(calls.length,0);
 await helpers.loadAgentPhoto(agent.id);
 assert.equal(calls.length,1);
 assert.equal(calls[0].action,'agent.photo.get');
 assert.equal(calls[0].payload.agentId,agent.id);
 assert.equal(node.image.src,dataUri);
 assert.equal(node.image.alt,'');
 await helpers.loadAgentPhoto(agent.id);
 assert.equal(calls.length,1);
});
test('imported profile distinguishes first added timestamp from latest import',()=>{
 const context=vm.createContext({E:Model.escape,dateTime:x=>`STAMP:${x||'unknown'}`,S:{reviewIds:['fixture-live'],returnPage:'contacts',profileTab:'Source data'},D:{watchlists:[],customFields:[]},ib:()=>'',avatar:()=>'',selectOptions:()=>'',icon:()=>'',contactInfoLine:(label,_icon,value)=>`${label}: ${value}`,linkedinContactInfo:()=>'',emailCompanyReviewInfo:()=>'',CommunicationsUI:{profileActions:()=>''},pageTabs:()=>'',document:{addEventListener(){}}});
 vm.runInContext(fs.readFileSync(path.join(web,'csv-import.js'),'utf8')+';globalThis.ui=CSVImportUI',context);
 const html=context.ui.renderProfile({id:'fixture-live',name:'Fixture Contact',source:'CSV import <source>',courtedFields:{},createdAt:'2026-10-03T10:15:00Z',importedAt:'2026-10-12T21:35:00Z'});
 assert.match(html,/Added to Sprout: STAMP:2026-10-03T10:15:00Z/);
 assert.match(html,/Last imported: STAMP:2026-10-12T21:35:00Z/);
 assert.match(html,/CSV import &lt;source&gt;/);
 assert.doesNotMatch(html,/October 2, 2026/);
});
test('workflow picker marks only sample dataset records as samples',()=>{
 let captured='';
 const context=vm.createContext({D:{today:'2026-10-12',agents:[{id:'fixture-live',datasetId:'live',manual:false,name:'Imported fixture'},{id:'sample-fixture',datasetId:'sample',name:'Sample fixture'}]},modal:(_title,body)=>{captured=body},console,toast:()=>{}});
 vm.runInContext(fs.readFileSync(path.join(web,'workflows.js'),'utf8')+';globalThis.ui=WorkflowUI',context);
 context.ui.handleAction({dataset:{action:'workflow-new-call'}});
 assert.match(captured,/>Imported fixture<\/option>/);
 assert.match(captured,/>Sample fixture \(sample\)<\/option>/);
});
test('call form captures an actual local date and time',()=>{
 let captured='';
 const context=vm.createContext({D:{today:'2026-10-12',agents:[]},modal:(_title,body)=>{captured=body},console,toast:()=>{}});
 vm.runInContext(fs.readFileSync(path.join(web,'workflows.js'),'utf8')+';globalThis.ui=WorkflowUI',context);
 context.ui.handleAction({dataset:{action:'workflow-new-call'}});
 assert.match(captured,/type="datetime-local" name="occurredAtLocal"/);
 assert.doesNotMatch(captured,/type="date"/);
});
test('call timestamp conversion preserves local calendar date and saves UTC instant',()=>{
 const W=require('../Web/workflows.js');
 const value='2026-01-10T13:45',expected=new Date(value).toISOString();
 assert.deepEqual(W.occurrencePayload(value,new Date('2026-01-12T00:00:00Z')),{occurredOn:'2026-01-10',occurredAt:expected});
 for(const invalid of ['', '2026-02-30T13:45','2099-01-10T13:45'])assert.throws(()=>W.occurrencePayload(invalid,new Date('2026-01-12T00:00:00Z')),/actual call date and time/);
});

test('interim admission notice preserves its date and never claims unknown production met',()=>{
 const {helpers}=appContext();
 const html=helpers.recruitingEligibilityNotice({recruitingEligibility:{mode:'interim_license_tenure',state:'interim_eligible',checkedAt:'2026-11-02',productionThresholdMet:false}});
 assert.match(html,/Interim eligible at intake/);assert.match(html,/2026-11-02/);
 assert.match(html,/production remains unverified/);assert.match(html,/threshold is not marked met/);
 assert.match(html,/Check current evidence/);
 assert.equal(helpers.recruitingEligibilityNotice({}), '');
 const unsafe=helpers.recruitingEligibilityNotice({recruitingEligibility:{mode:'interim_license_tenure',state:'needs_evidence',checkedAt:'<script>'}});
 assert.match(unsafe,/needs review/);assert.doesNotMatch(unsafe,/<script>/);
});

test('main list and global search include all ten sourced Waco contacts without a transaction-city override',()=>{
 const rows=Array.from({length:10},(_,i)=>({id:'discovery-'+i,name:'Professional '+i,datasetId:'live',city:'',office:'Official Brokerage'}));
 const evidence=rows.map(a=>({agentId:a.id,evidenceStatus:'reviewed',serviceCities:['Waco'],serviceJurisdiction:'TX',source:{reference:'https://official.example/'+a.id},checkedAt:'2026-11-02'}));
 const globalResultsElement={innerHTML:''};
 const context=vm.createContext({Model,icon:()=>'',document:{getElementById:()=>globalResultsElement},window:{},console,rows,evidence});
 const source=fs.readFileSync(path.join(web,'app.js'),'utf8');
 for(const file of ['task-controls.js','weekly-reports.js','sourcing-rules.js','meetings.js'])vm.runInContext(fs.readFileSync(path.join(web,file),'utf8'),context);
 vm.runInContext(source.slice(0,source.indexOf("document.addEventListener('click'"))+";D={agents:rows,prospectingEvidence:evidence,watchlists:[]};S.filters={q:'Waco'};globalThis.list=visibleAgents();globalResults('Waco');",context);
 assert.equal(context.list.length,10);
 assert.match(globalResultsElement.innerHTML,/Show all 10 matches/);
 assert.match(globalResultsElement.innerHTML,/Serves Waco/);
 vm.runInContext("S.filters={serviceCity:'Waco'};globalThis.serviceList=visibleAgents();",context);
 assert.equal(context.serviceList.length,10);
 assert.ok(rows.every(a=>a.city===''));
});
