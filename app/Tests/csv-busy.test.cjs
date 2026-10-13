'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');
const Model=require('../Web/model.js');
function fixture(native){
 const controls=[{disabled:false,isConnected:true},{disabled:true,isConnected:true}];
 const attrs={},messages=[],modals=[];
 const container={appendChild(node){messages.push(node.textContent);}};
 const host={classList:{add(){}},getAttribute:name=>attrs[name]??null,setAttribute:(name,value)=>{attrs[name]=value;},removeAttribute:name=>{delete attrs[name];},querySelector:()=>container};
 const row={dataset:{header:'Name',inferredType:'text'},querySelector:selector=>selector==='[data-map-target]'?{value:'core:name'}:{value:'Name'}};
 const document={body:container,addEventListener(){},querySelector:selector=>selector==='.modal'?host:null,
  querySelectorAll:selector=>selector==='[data-map-row]'?[row]:controls,getElementById:()=>container,
  createElement:()=>({setAttribute(){},remove(){}})};
 const context=vm.createContext({document,native,E:Model.escape,requestAnimationFrame:fn=>fn(),modal:(title,body)=>modals.push({title,body}),btn:()=>'',closeModal(){},render(){},toast(){},D:{}});
 vm.runInContext(fs.readFileSync(path.join(__dirname,'../Web/csv-import.js'),'utf8')+';globalThis.csv=CSVImportUI',context);
 return {csv:context.csv,controls,attrs,messages,modals};
}
const inspection={columns:[{header:'Name',filled:1,inferredType:'text',suggestedTarget:'core:name'}],coreTargets:['name'],customFields:[],fileNames:['fixture.csv'],rows:1};
const preview={...inspection,newAgents:1,updateAgents:0,hardConflicts:0,possibleMatches:0,customFieldsToCreate:[],token:'fixture-token'};
const tick=()=>new Promise(resolve=>setImmediate(resolve));
test('CSV pick exposes busy status and blocks duplicate native requests',async()=>{
 let resolvePick,calls=0;
 const state=fixture(()=>{calls++;return new Promise(resolve=>{resolvePick=resolve;});});
 const pending=state.csv.pick();
 assert.equal(state.csv.isBusy(),true);
 assert.deepEqual(state.controls.map(x=>x.disabled),[true,true]);
 assert.equal(state.attrs['aria-busy'],'true');
 assert.match(state.messages[0],/Reading selected CSV files/);
 await assert.rejects(state.csv.pick(),/already running/);
 await tick();assert.equal(calls,1);
 resolvePick({cancelled:true});await pending;
 assert.equal(state.csv.isBusy(),false);
 assert.deepEqual(state.controls.map(x=>x.disabled),[false,true]);
 assert.equal(state.attrs['aria-busy'],undefined);
});
test('CSV failed preview restores controls and allows review retry',async()=>{
 let previews=0;
 const state=fixture(async action=>{
  if(action==='csv.import.pick')return inspection;
  if(action==='csv.import.preview'){if(++previews===1)throw Error('Fixture preview error');return preview;}
  throw Error(action);
 });
 await state.csv.pick();
 await assert.rejects(state.csv.review(),/Fixture preview error/);
 assert.equal(state.csv.isBusy(),false);
 await state.csv.review();
 assert.equal(previews,2);
 assert.equal(state.modals.at(-1).title,'Review import counts');
 assert.match(state.messages.at(-1),/Checking mappings/);
});
test('CSV successful commit clears retry token even when snapshot refresh fails',async()=>{
 let commits=0;
 const state=fixture(async action=>{
  if(action==='csv.import.pick')return inspection;
  if(action==='csv.import.preview')return preview;
  if(action==='csv.import.commit'){commits++;return {newAgents:1,updateAgents:0};}
  if(action==='snapshot')throw Error('Fixture refresh unavailable');
  throw Error(action);
 });
 await state.csv.pick();await state.csv.review();
 await assert.rejects(state.csv.commit(),/Import saved successfully, but the view could not refresh/);
 assert.equal(state.csv.isBusy(),false);
 await assert.rejects(state.csv.commit(),/Review the CSV mapping/);
 assert.equal(commits,1);
 assert.match(state.messages.at(-1),/Backing up and importing contacts/);
});
test('CSV failed commit keeps reviewed batch for a deliberate retry',async()=>{
 let commits=0;
 const state=fixture(async action=>{
  if(action==='csv.import.pick')return inspection;
  if(action==='csv.import.preview')return preview;
  if(action==='csv.import.commit'){if(++commits===1)throw Error('Fixture disk error');return {newAgents:1,updateAgents:0};}
  if(action==='snapshot')return {};
  throw Error(action);
 });
 await state.csv.pick();await state.csv.review();
 await assert.rejects(state.csv.commit(),/Fixture disk error/);
 await state.csv.commit();assert.equal(commits,2);
});
test('imported profile shows last reimport separately from preserved first import',()=>{
 const context=vm.createContext({E:Model.escape,dateTime:x=>`STAMP:${x||'unknown'}`,S:{reviewIds:['fixture'],returnPage:'contacts',profileTab:'Source data'},D:{watchlists:[],customFields:[]},ib:()=>'',avatar:()=>'',selectOptions:()=>'',icon:()=>'',linkedinContactInfo:()=>'',emailCompanyReviewInfo:()=>'',CommunicationsUI:{profileActions:()=>''},pageTabs:()=>'',document:{addEventListener(){}}});
 vm.runInContext(fs.readFileSync(path.join(__dirname,'../Web/csv-import.js'),'utf8')+';globalThis.csv=CSVImportUI',context);
 const html=context.csv.renderProfile({id:'fixture',name:'Fixture Contact',createdAt:'2026-01-01T01:00:00Z',importedAt:'2026-01-02T01:00:00Z',lastImportedAt:'2026-01-03T01:00:00Z'});
 assert.match(html,/<label>Added to Sprout<\/label><span>STAMP:2026-01-01T01:00:00Z/);
 assert.match(html,/<label>Last imported<\/label><span>STAMP:2026-01-03T01:00:00Z/);
});
