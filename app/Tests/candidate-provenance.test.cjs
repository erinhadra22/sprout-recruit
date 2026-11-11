'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs');
const vm=require('node:vm');
const M=require('../Web/model.js');
const zone='America/Chicago';
const rows=[
 {id:'agent',datasetId:'live',name:'Agent lead',source:'Waco research',sourceType:'ai_agent',sourceActor:'Research assistant',sourceReference:'run-123',createdAt:'2026-11-04T01:00:00Z',sourcedAt:'2026-11-02T15:30:42Z',lastInteraction:'2026-10-30'},
 {id:'email',datasetId:'live',name:'Email lead',source:'Email import',sourceType:'email_import',createdAt:'2026-11-04T15:00:00Z',sourcedAt:'2026-11-02'},
 {id:'old',datasetId:'live',name:'Older contact',source:'Courted CSV export',importedAt:'2026-10-03T12:00:00Z',viewedAt:'2026-11-04T19:00:00Z'},
 {id:'unknown',datasetId:'live',name:'Unknown history',createdAt:'bad date',sourcedAt:'2026-02-30'}
];
const messages=[
 {agentId:'agent',direction:'inbound',occurredAt:'2026-11-03T16:30:00Z',messageClass:'received_reply'},
 {agentId:'agent',direction:'inbound',occurredAt:'2026-11-04T16:30:00Z',messageClass:'automatic_notice'},
 {agentId:'email',direction:'outbound',occurredAt:'2026-11-02T16:30:00Z',messageClass:'sent_copy'},
 {agentId:'old',direction:'inbound',occurredAt:'2026-11-04T17:30:00Z',messageClass:'held'}
];
const filter=f=>M.filter(rows,f,[],{timeZone:zone,externalMessages:messages}).map(a=>a.id);
test('candidate filters combine source method, label, added date, contact date and source time',()=>{
 assert.deepEqual(filter({sourceType:'ai_agent',source:'Waco research',addedFrom:'2026-11-03',addedTo:'2026-11-03',contactFrom:'2026-11-03',contactTo:'2026-11-03',sourcedFrom:'2026-11-02',sourcedTo:'2026-11-02',sourcedFromTime:'09:30',sourcedToTime:'09:30'}),['agent']);
 assert.deepEqual(filter({sourceType:'email_import'}),['email']);
 assert.deepEqual(filter({source:'Unknown source'}),['unknown']);
 assert.deepEqual(filter({sourceType:'unknown'}),['unknown']);
 assert.deepEqual(filter({sourceType:'courted_import'}),['old']);
 assert.deepEqual(filter({addedFrom:'2026-10-03',addedTo:'2026-10-03'}),['old']);
 assert.deepEqual(filter({addedFrom:'2026-11-04'}),['email']);
});
test('unknown dates and date-only source precision are honest',()=>{
 assert.deepEqual(filter({sourcedFrom:'2026-11-02',sourcedTo:'2026-11-02'}),['agent','email']);
 assert.deepEqual(filter({sourcedFrom:'2026-11-02',sourcedTo:'2026-11-02',sourcedFromTime:'09:30'}),['agent']);
 assert.deepEqual(filter({sourcedMode:'unknown'}),['old','unknown']);
 assert.deepEqual(filter({addedMode:'unknown'}),['unknown']);
 assert.deepEqual(filter({sourcedMode:'known'}),['agent','email']);
 assert.equal(M.dateParts('2026-11-02T15:00:00',zone),null);
 assert.equal(M.dateParts('2026-02-30T15:00:00Z',zone),null);
});
test('last contact excludes profile views, automatic notices and held messages',()=>{
 assert.equal(M.lastContactAt(rows[0],messages,zone),'2026-11-03T16:30:00Z');
 assert.deepEqual(filter({contactMode:'unknown'}),['old','unknown']);
 assert.deepEqual(filter({contactFrom:'2026-11-04'}),[]);
 assert.equal(M.lastContactAt({...rows[0],lastInteraction:'2026-11-03'},messages,zone),'2026-11-03');
 assert.equal(M.lastContactAt({id:'none',draftedAt:'2026-11-04',viewedAt:'2026-11-04'},messages,zone),null);
});
test('date range validation prevents inverted and contradictory filters',()=>{
 for(const prefix of ['added','contact','sourced']){
  assert.throws(()=>M.validateDateFilters({[prefix+'From']:'2026-11-04',[prefix+'To']:'2026-11-03'}),/End date/);
  assert.throws(()=>M.validateDateFilters({[prefix+'Mode']:'unknown',[prefix+'From']:'2026-11-04'}),/Clear the date range/);
 }
 assert.throws(()=>M.validateDateFilters({sourcedFromTime:'12:00',sourcedToTime:'11:00'}),/end time/);
 assert.doesNotThrow(()=>M.validateDateFilters({sourcedFrom:'2026-11-02',sourcedTo:'2026-11-03',sourcedFromTime:'12:00',sourcedToTime:'11:00'}));
});
test('source time spans endpoints and respects workspace time zone and DST',()=>{
 const a=[{id:'fall',sourcedAt:'2026-11-01T06:30:00Z'},{id:'later',sourcedAt:'2026-11-01T07:30:00Z'}];
 assert.deepEqual(M.filter(a,{sourcedFrom:'2026-11-01',sourcedTo:'2026-11-01',sourcedFromTime:'01:30',sourcedToTime:'01:30'},[],{timeZone:zone}).map(a=>a.id),['fall','later']);
 assert.deepEqual(filter({sourcedFrom:'2026-11-02',sourcedTo:'2026-11-03',sourcedFromTime:'10:00',sourcedToTime:'12:00'}),[]);
});
test('new date columns sort originals and export source attribution',()=>{
 assert.deepEqual(M.sort(rows,'addedAt',1).map(a=>a.id),['old','agent','email','unknown']);
 const known=rows.slice(0,3);
 assert.deepEqual(M.sort(known,'lastContactAt',-1,{externalMessages:messages,timeZone:zone}).map(a=>a.id),['agent','email','old']);
 const csv=M.csv([rows[0]]);
 assert.match(csv,/Source method.*Sourcing agent.*Date added.*Source date \/ time.*Source reference/);
 assert.match(csv,/AI agent.*Research assistant.*2026-11-04T01:00:00Z.*2026-11-02T15:30:42Z.*run-123/);
});
function context(){
 const c=vm.createContext({Model:M,icon:()=>'',document:{},window:{},console,rows,messages});
 const source=fs.readFileSync(require.resolve('../Web/app.js'),'utf8');
 vm.runInContext(source.slice(0,source.indexOf("document.addEventListener('click'"))+`;D={agents:rows,externalMessages:messages,settings:[{id:'workspace',timezone:'America/Chicago'}],stages:[],watchlists:[]};globalThis.helpers={visibleAgents,candidateProvenanceInfo,agentCell,filterForm};`,c);
 return c;
}
test('main candidate, contacts and search lists apply serialized saved filters and show provenance',()=>{
 const c=context(),saved=JSON.stringify({sourceType:'ai_agent',addedFrom:'2026-11-03',addedTo:'2026-11-03'});
 for(const page of ['candidates','contacts','search','pipeline']){
  vm.runInContext(`S.page='${page}';S.filters=JSON.parse('${saved}');globalThis.found=visibleAgents().map(a=>a.id)`,c);
  assert.deepEqual([...c.found],page==='pipeline'?[]:['agent']);
 }
 const html=c.helpers.candidateProvenanceInfo({...rows[0],sourceActor:'<script>'});
 assert.match(html,/Source date \/ time/);assert.match(html,/Sourcing agent/);assert.match(html,/run-123/);assert.match(html,/&lt;script&gt;/);assert.doesNotMatch(html,/<script>/);
 assert.match(c.helpers.agentCell(rows[1],'sourcedAt'),/time not recorded/);
 assert.match(c.helpers.agentCell(rows[2],'sourceType'),/Courted import/);
});
test('all filters form exposes source and three date ranges with explicit unknown choices',()=>{
 const c=context();vm.runInContext("modal=(_title,body)=>{globalThis.formHTML=body};S.filters={source:'Email import',sourceType:'email_import',contactMode:'unknown'};filterForm();",c);
 for(const name of ['source','sourceType','addedFrom','addedTo','contactFrom','contactTo','sourcedFrom','sourcedTo','sourcedFromTime','sourcedToTime'])assert.match(c.formHTML,new RegExp('name="'+name+'"'));
 assert.match(c.formHTML,/No recorded contact/);assert.match(c.formHTML,/America\/Chicago/);assert.match(c.formHTML,/Date-only sources are excluded/);
});

test('legacy source methods use only exact known labels',()=>{
 for(const [source,expected] of Object.entries({'CSV import':'csv_import','Courted CSV export':'courted_import','Manual contact':'manual','Reviewed discovery import':'provider_import'}))assert.equal(M.sourceType({source}),expected);
 for(const source of ['Agent research','CSV import from email','courted csv export','A private source','toString','__proto__'])assert.equal(M.sourceType({source}),'unknown');
 assert.equal(M.sourceType({source:'CSV import',sourceType:'email_import'}),'email_import');
});
test('source and added date sorting compares instants across offsets',()=>{
 const input=[{id:'later',sourcedAt:'2026-11-04T10:00:00-06:00',createdAt:'2026-11-04T10:00:00-06:00'},{id:'first',sourcedAt:'2026-11-04T15:59:00Z',createdAt:'2026-11-04T15:59:00Z'},{id:'unknown',sourcedAt:'unknown',createdAt:'bad'}];
 for(const key of ['addedAt','sourcedAt']){assert.deepEqual(M.sort(input,key,1).map(a=>a.id),['first','later','unknown']);assert.deepEqual(M.sort(input,key,-1).map(a=>a.id),['later','first','unknown']);}
});
test('provenance date columns render the same workspace zone used for date filters',()=>{
 const c=context();
 const displayed=c.helpers.agentCell(rows[0],'addedAt');
 assert.match(displayed,/Nov 3, 2026/);assert.match(displayed,/7:00 PM/);
 assert.match(c.helpers.agentCell(rows[0],'sourcedAt'),/9:30 AM/);
});
