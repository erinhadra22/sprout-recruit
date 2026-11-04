const test=require('node:test');
const assert=require('node:assert/strict');
const M=require('../Web/model.js');
const agents=[{id:'a',datasetId:'sample',name:'Taylor <Brooks>',city:'Austin',office:'Oak',status:'Contacted',move:'High',volume:3000000,years:4,units:8,active:0},{id:'b',datasetId:'sample',name:'Jamie',city:'Dallas',office:'Oak',status:'Do not contact',move:'Moderate',volume:8000000,years:8,units:16,active:3},{id:'c',datasetId:'live',name:'Manual',city:'Austin',manual:true,status:'Identified',move:'Unknown'}];
test('unknown production remains distinct from a measured zero and partial totals',()=>{
 assert.deepEqual(M.volumeCoverage([{volume:null},{}]),{total:null,knownCount:0,unknownCount:2});
 assert.equal(M.volumeSummary([{volume:null}]),'Sales volume unknown');
 assert.deepEqual(M.volumeCoverage([{volume:0},{volume:2000000},{volume:null},{volume:'5000000'}]),{total:2000000,knownCount:2,unknownCount:2});
 assert.match(M.volumeSummary([{volume:0},{volume:null}]),/\$0.*known sales volume.*1 unknown/);
 assert.deepEqual(M.volumeCoverage([]),{total:null,knownCount:0,unknownCount:0});
});
test('real discovery imports are never described as fictional contacts',()=>{
 assert.match(M.contactSourceNote({id:'discovery-new',datasetId:'live',manual:false}),/Imported professional/);
 assert.match(M.contactSourceNote({datasetId:'sample'}),/Fictional/);
 assert.equal(M.contactSourceNote({datasetId:'live',manual:true}),'Entered locally.');
 assert.match(M.contactSourceNote({}),/not been verified/);
});
test('Waco search and service-city filtering use reviewed footprint without inventing transaction city',()=>{
 const contacts=[{id:'new',name:'Reviewed Professional',city:'',county:'Travis'},{id:'county',name:'Registry Only',county:'Waco'},{id:'office',name:'Office Only',officeCity:'Waco'},{id:'unreviewed',name:'Unreviewed Match',city:''}];
 const evidence=[{agentId:'new',evidenceStatus:'reviewed',serviceCities:['Waco','Woodway'],source:{reference:'https://official.example/profile'},checkedAt:'2026-11-02'},{agentId:'unreviewed',serviceCities:['Waco'],source:{reference:'https://official.example'},checkedAt:'2026-11-02'}];
 assert.deepEqual(M.filter(contacts,{q:'waco'},evidence).map(a=>a.id),['new']);
 assert.deepEqual(M.filter(contacts,{serviceCity:'Waco'},evidence).map(a=>a.id),['new']);
 assert.deepEqual(M.filter(contacts,{city:'Waco'},evidence),[]);
 assert.equal(contacts[0].city,'');
 assert.deepEqual(M.filter(contacts,{q:'Reviewed Professional'},evidence).map(a=>a.id),['new']);
 assert.deepEqual(M.filter(contacts,{serviceCity:'Waco',status:'Contacted'},evidence),[]);
});
test('compound filters preserve missing values as unknown',()=>{assert.deepEqual(M.filter(agents,{city:'Austin',minVolume:2000000}).map(a=>a.id),['a']);assert.equal(M.filter(agents,{q:'oak',move:'Moderate'}).length,1);assert.equal(M.filter(agents,{maxVolume:1000000}).length,0);});
test('zero active-listing filter excludes unknown and active records',()=>{for(const maxActive of ['0',0])assert.deepEqual(M.filter(agents,{maxActive}).map(a=>a.id),['a']);});
test('timeline timestamps use local dates while task dates stay fixed',()=>{const old=process.env.TZ;process.env.TZ='America/Chicago';try{assert.equal(M.date('2026-09-29T01:30:00Z'),'Sep 28, 2026');assert.equal(M.date('2026-09-29'),'Sep 29, 2026');}finally{if(old===undefined)delete process.env.TZ;else process.env.TZ=old;}});
test('recommendations respect exclusion, must-have fields and limits',()=>{assert.deepEqual(M.candidates(agents,{mustVolume:true,minVolume:2500000,dailyLimit:10}).map(a=>a.id),['a']);assert.equal(M.candidates([{...agents[0],disposition:'skipped'}],{}).length,0);assert.equal(M.candidates([{...agents[0],datasetId:'live'}],{}).length,0);assert.equal(M.candidates(agents,{mustVolume:false,minVolume:5000000}).length,1);});
test('pipeline excludes explicitly disqualified states',()=>assert.deepEqual(M.pipeline(agents).map(a=>a.id),['a','c']));
test('numeric sort is stable and leaves missing values last',()=>{assert.deepEqual(M.sort(agents,'volume',-1).map(a=>a.id),['b','a','c']);assert.equal(agents[0].id,'a');});
test('period selection and production totals agree',()=>{const a={transactions:[{date:'2026-01-01',price:400000,side:'Buy-side'},{date:'2025-12-31',price:500000,side:'List-side'},{date:'2025-09-20',price:200000,side:'List-side'}]};const tx=M.transactions(a,'YTD','2026-09-28');assert.deepEqual(M.metrics(tx),{volume:400000,units:1,avg:400000,buy:1,list:0,gci:11000});assert.equal(M.transactions(a,'LTM','2026-09-28').length,2);assert.equal(M.transactions(a,'Custom','2026-09-28',{from:'2025-12-31',to:'2025-12-31'}).length,1);});
test('task buckets distinguish completion and overdue',()=>{const tasks=[{id:'a',title:'Call',description:'',dueDate:'2026-09-27',completed:false},{id:'b',title:'Email',description:'',dueDate:'2026-09-28',completed:false},{id:'c',title:'Call',description:'',dueDate:'2026-09-27',completed:true}];assert.deepEqual(M.tasks(tasks,'Overdue','2026-09-28').map(t=>t.id),['a']);assert.deepEqual(M.tasks(tasks,'Completed','2026-09-28').map(t=>t.id),['c']);});
test('user text is escaped and spreadsheet exports neutralize formulas',()=>{assert.equal(M.escape('<img onerror="x">'),'&lt;img onerror=&quot;x&quot;&gt;');assert.match(M.csv([{name:'=1+1',office:'A "quoted" office'}]),/"'=1\+1"/);assert.match(M.csv([{name:'N',office:'A "quoted" office'}]),/"A ""quoted"" office"/);});
