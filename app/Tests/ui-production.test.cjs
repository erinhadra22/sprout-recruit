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
 vm.runInContext(source.slice(0,source.indexOf("document.addEventListener('click'"))+';globalThis.helpers={btn,ib,agentCell,requestCloseModal,closeModal,markDirty:form=>dirtyForms.add(form)}',context);
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
test('imported profile distinguishes first added timestamp from latest import',()=>{
 const context=vm.createContext({E:Model.escape,dateTime:x=>`STAMP:${x||'unknown'}`,S:{reviewIds:['fixture-live'],returnPage:'contacts',profileTab:'Source data'},D:{watchlists:[],customFields:[]},ib:()=>'',avatar:()=>'',selectOptions:()=>'',icon:()=>'',linkedinContactInfo:()=>'',emailCompanyReviewInfo:()=>'',CommunicationsUI:{profileActions:()=>''},pageTabs:()=>'',document:{addEventListener(){}}});
 vm.runInContext(fs.readFileSync(path.join(web,'csv-import.js'),'utf8')+';globalThis.ui=CSVImportUI',context);
 const html=context.ui.renderProfile({id:'fixture-live',name:'Fixture Contact',source:'CSV import <source>',courtedFields:{},createdAt:'2026-10-03T10:15:00Z',importedAt:'2026-10-12T21:35:00Z'});
 assert.match(html,/<label>Added to Sprout<\/label><span>STAMP:2026-10-03T10:15:00Z/);
 assert.match(html,/<label>Last imported<\/label><span>STAMP:2026-10-12T21:35:00Z/);
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
