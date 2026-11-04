const test=require('node:test');
const assert=require('node:assert/strict');
const P=require('../Web/performance.js');
const data={today:'2026-09-29',performance:[{agentId:'a',year:2025,buyerUnits:0,buyerVolume:0,sellerUnits:3,sellerVolume:1500000,dualSidedUnits:0,dualSidedVolume:0,periodStart:'2025-01-01',periodEnd:'2025-12-31',asOfDate:'2026-01-02',coverage:'complete',attribution:'individual',source:{label:'Annual <source>'},revision:2}]};
test('five years are distinct calendar periods without LTM fallback',()=>{const rows=P.fiveYears('a',data);assert.deepEqual(rows.map(r=>r.year),[2026,2025,2024,2023,2022]);assert.equal(rows[0].record,null);assert.equal(rows[1].record.buyerUnits,0);const html=P.renderProfile({id:'a',volume:90000000,units:200,transactions:[{date:'2026-01-02',price:90000000}]},data);assert.match(html,/Unknown/);assert.doesNotMatch(html,/90,000,000/);assert.match(html,/Annual &lt;source&gt;/);});
test('unique totals require overlap and never double count dual sides',()=>{assert.deepEqual(P.totals({buyerUnits:4,sellerUnits:3,buyerVolume:2000000,sellerVolume:1800000,dualSidedUnits:1,dualSidedVolume:600000}),{creditedSides:7,uniqueUnits:6,uniqueVolume:3200000});assert.deepEqual(P.totals({buyerUnits:4,sellerUnits:3,buyerVolume:2000000,sellerVolume:1800000}),{creditedSides:7,uniqueUnits:null,uniqueVolume:null});assert.deepEqual(P.totals({buyerUnits:0,sellerUnits:0,dualSidedUnits:0,buyerVolume:0,sellerVolume:0,dualSidedVolume:0}),{creditedSides:0,uniqueUnits:0,uniqueVolume:0});assert.equal(P.totals({buyerUnits:'4',sellerUnits:3}).creditedSides,null);});
test('partial period label is independent of source coverage',()=>{assert.match(P.periodLabel({year:2026,periodStart:'2026-01-01',periodEnd:'2026-09-01',coverage:'complete'},data.today),/Year to date \/ partial period/);assert.match(P.periodLabel({year:2025,periodStart:'2025-02-01',periodEnd:'2025-10-01',coverage:'partial'},data.today),/Partial calendar year/);assert.match(P.periodLabel(data.performance[0],data.today),/Full calendar year/);});
test('manual payload keeps zero and missing distinct with source and revision',()=>{const p=P.payloadFromValues({buyerUnits:'0',buyerVolume:'0',sellerUnits:'',sourceLabel:'Source',sourceReference:'Annual.csv',changeReason:'Initial',coverage:'partial',attribution:'team'},'a','2025','2');assert.equal(p.buyerUnits,0);assert.equal(p.sellerUnits,null);assert.equal(p.dualSidedVolume,null);assert.equal(p.expectedRevision,2);assert.deepEqual(p.source,{label:'Source',reference:'Annual.csv',method:'manual'});for(const invalid of ['-1','NaN','1,000','1e3','<script>'])assert.throws(()=>P.payloadFromValues({buyerUnits:invalid},'a',2025,0));});
test('imports preserve source metadata and bind current contact/revision without guessed metrics',()=>{const row={year:2025,periodStart:'2025-01-01',periodEnd:'2025-12-31',asOfDate:'2026-01-02',source:{label:'Imported annual',reference:'annual.json'},coverage:'complete',attribution:'team',buyerUnits:0,sellerUnits:null};const rows=P.parseImport(JSON.stringify([row]),'a',data);assert.equal(rows[0].agentId,'a');assert.equal(rows[0].expectedRevision,2);assert.equal(rows[0].source.method,'import');assert.equal(rows[0].sellerUnits,null);assert.equal(rows[0].buyerVolume,undefined);assert.throws(()=>P.parseImport(JSON.stringify([row,row]),'a',data));assert.throws(()=>P.parseImport(JSON.stringify([{...row,agentId:'other'}]),'a',data));assert.throws(()=>P.parseImport(JSON.stringify([{...row,buyerUnits:'5'}]),'a',data));assert.throws(()=>P.parseImport(JSON.stringify([{...row,source:{label:'Source',method:'manual'}}]),'a',data));assert.throws(()=>P.parseImport('[]','a',data));});
test('report rendering escapes names, distinguishes evidence, and omits private bodies',()=>{const report={id:'r',filters:{title:'<script>alert(1)</script>',fromDate:'2026-01-01',toDate:'2026-01-31',includeSamples:false,timeZone:'America/Chicago'},metrics:{calls:1,connectedCalls:0,messages:2,emails:0,notes:1,tasksCompleted:0},rates:{taskCompletion:{numerator:0,denominator:0,percent:null},contactCoverage:{numerator:1,denominator:4,percent:25}},verificationCounts:{manual:2,user:1,provider:1},events:[{date:'2026-01-01',agentName:'<img src=x>',label:'Message sent',verification:'provider',dataset:'real',body:'Secret body'}]};const html=P.reportMarkup(report);assert.doesNotMatch(html,/<script>|<img src=x>|Secret body/);assert.match(html,/&lt;script&gt;/);assert.match(html,/Provider-confirmed/);assert.match(html,/1 \/ 4 \(25.0%\)/);assert.match(html,/no denominator/);assert.match(html,/Real contacts only/);assert.match(P.reportMarkup({...report,filters:{...report.filters,includeSamples:true}}),/Includes illustrative sample activity/);});

const current={today:'2026-10-29',agents:[{id:'a',name:'Ana'},{id:'b',name:'Bea'}],teams:[{id:'t',name:'Waco <Team>'}],teamMemberships:[{agentId:'a',teamId:'t',startDate:'2024-01-01'}],performance:[]};
const sourceRow=(overrides={})=>({agentId:'a',year:2025,periodType:'annual',periodStart:'2025-01-01',periodEnd:'2025-12-31',asOfDate:'2026-01-15',coverage:'complete',attribution:'individual',source:{label:'Authorized export',reference:'export.json',checkedAt:'2026-10-29',providerId:'fixture-provider',recordIds:['close-1']},buyerUnits:2,buyerVolume:1000000,sellerUnits:3,sellerVolume:1500000,dualSidedUnits:0,dualSidedVolume:0,...overrides});

test('individual calendar display excludes team, LTM and unknown attribution even when listed first',()=>{
 const individual={...sourceRow(),id:'individual-2025'},team={...sourceRow({teamId:'t',attribution:'team',buyerVolume:9000000}),id:'team-2025'},ltm={...sourceRow({year:2026,periodType:'ltm',periodStart:'2025-10-30',periodEnd:'2026-10-29',asOfDate:'2026-10-29'}),id:'ltm'},unknown={...sourceRow({attribution:'unknown'}),id:'unknown'};
 const d={...current,performance:[team,ltm,unknown,individual]};
 assert.equal(P.fiveYears('a',d)[1].record.id,'individual-2025');assert.equal(P.fiveYears('a',d)[0].record,null);
 const html=P.renderProfile(current.agents[0],d);assert.match(html,/Five-year individual production/);assert.match(html,/Other sourced periods and team production/);assert.match(html,/Waco &lt;Team&gt;/);assert.match(html,/Last 12 months/);assert.match(html,/data-record-id="team-2025"/);
});

test('multiple individual periods remain separately reviewable instead of silently picking one',()=>{
 const d={...current,performance:[{...sourceRow(),id:'full'},{...sourceRow({periodEnd:'2025-06-30',coverage:'partial'}),id:'partial'}]};
 assert.equal(P.fiveYears('a',d)[1].record,null);assert.equal(P.fiveYears('a',d)[1].conflicts,2);
 assert.match(P.renderProfile(current.agents[0],d),/2 separate periods; review below/);
});

test('multi-agent import accepts independent subjects and separate team totals in the same year',()=>{
 const rows=P.parseImport(JSON.stringify([sourceRow(),sourceRow({agentId:'b'}),sourceRow({agentId:undefined,teamId:'t',attribution:'team'})]),'',current);
 assert.equal(rows.length,3);assert.equal(rows[0].agentId,'a');assert.equal(rows[1].agentId,'b');assert.equal(rows[2].teamId,'t');assert.equal(rows[2].agentId,undefined);
 assert.deepEqual(rows[0].source,{...sourceRow().source,method:'import'});assert.equal(rows[0].expectedRevision,0);
 assert.throws(()=>P.parseImport(JSON.stringify([sourceRow({agentId:'missing'})]),'',current),/not in this workspace/);
 assert.throws(()=>P.parseImport(JSON.stringify([sourceRow({teamId:'absent',attribution:'team'})]),'',current),/teamId is not/);
 assert.throws(()=>P.parseImport(JSON.stringify([sourceRow({attribution:'team'})]),'',current),/saved team/);
 assert.throws(()=>P.parseImport(JSON.stringify([sourceRow({teamId:'t'})]),'',current),/requires team attribution/);
});

test('explicit source imports reject duplicate periods and edits to the wrong record identity',()=>{
 const existing={...sourceRow(),id:'saved',revision:3},d={...current,performance:[existing]};
 assert.throws(()=>P.parseImport(JSON.stringify([sourceRow(),sourceRow()]),'',d),/once/);
 const [update]=P.parseImport(JSON.stringify([sourceRow()]),'',d);assert.equal(update.recordId,'saved');assert.equal(update.expectedRevision,3);
 assert.throws(()=>P.parseImport(JSON.stringify([sourceRow({recordId:'saved',agentId:'b'})]),'',d),/cannot change/);
 assert.throws(()=>P.parseImport(JSON.stringify([sourceRow({recordId:'saved',periodStart:'2025-02-01'})]),'',d),/cannot change/);
 assert.throws(()=>P.parseImport(JSON.stringify([sourceRow({recordId:'gone'})]),'',d),/no longer available/);
});

test('LTM windows stay explicit and are never split into annual history',()=>{
 const ltm=sourceRow({year:2026,periodType:'ltm',periodStart:'2025-10-30',periodEnd:'2026-10-29',asOfDate:'2026-10-29'});
 const rows=P.parseImport(JSON.stringify([ltm]),'',current);assert.equal(rows.length,1);assert.equal(rows[0].periodStart,'2025-10-30');assert.match(P.periodLabel(rows[0],current.today),/^Last 12 months/);
 assert.throws(()=>P.parseImport(JSON.stringify([{...ltm,periodStart:'2026-01-01'}]),'',current),/365 or 366/);
 assert.throws(()=>P.parseImport(JSON.stringify([{...ltm,periodType:'annual'}]),'',current),/within the selected year/);
 const leap=sourceRow({year:2024,periodType:'ltm',periodStart:'2023-03-01',periodEnd:'2024-02-29',asOfDate:'2024-03-01'});assert.equal(P.parseImport(JSON.stringify([leap]),'',current).length,1);
});

test('source dates and unknown values validate without filling evidence gaps',()=>{
 const row=sourceRow({buyerUnits:null,buyerVolume:null,dualSidedUnits:null,dualSidedVolume:null});
 const [parsed]=P.parseImport(JSON.stringify([row]),'',current);assert.equal(parsed.buyerVolume,null);assert.equal(P.totals(parsed).uniqueVolume,null);
 for(const invalid of [sourceRow({periodEnd:'2025-02-30'}),sourceRow({asOfDate:'2027-01-01'}),sourceRow({source:{label:'Source',checkedAt:'2025-01-01'}}),sourceRow({source:{label:'Source',checkedAt:'2027-01-01'}})])assert.throws(()=>P.parseImport(JSON.stringify([invalid]),'',current));
 assert.throws(()=>P.parseImport(JSON.stringify([sourceRow({buyerUnits:0,buyerVolume:100})]),'',current),/must agree/);
 assert.throws(()=>P.parseImport(JSON.stringify([sourceRow({dualSidedUnits:9})]),'',current),/cannot exceed/);
 assert.throws(()=>P.parseImport(JSON.stringify([sourceRow({source:{label:'Source',recordIds:['x','x']}})]),'',current),/distinct/);
});

test('manual explicit source payload retains period, team and source identifiers',()=>{
 const p=P.payloadFromValues({year:'2026',periodType:'ltm',teamId:'t',attribution:'team',sourceLabel:'Export',sourceProviderId:'ntreis-fixture',sourceRecordIds:'["001","002","003"]',sourceCheckedAt:'2026-10-29',buyerUnits:'0',buyerVolume:'0'},'a',2025,4,'series-id');
 assert.equal(p.year,2026);assert.equal(p.periodType,'ltm');assert.equal(p.teamId,'t');assert.equal(p.recordId,'series-id');assert.deepEqual(p.source.recordIds,['001','002','003']);assert.equal(p.source.providerId,'ntreis-fixture');assert.equal(p.source.checkedAt,'2026-10-29');assert.equal(p.sellerUnits,null);
});

const fs=require('node:fs'),vm=require('node:vm');
function uiContext(){let rendered=null,mutations=[],resolveMutation;const form={dataset:{kind:'perf-import-confirm'},_performanceImport:[sourceRow()],querySelector:()=>null};const context={module:{exports:{}},D:current,Date,Intl,Set,Map,JSON,Number,String,Array,Error,FormData:class{constructor(f){this.f=f;}entries(){return Object.entries(this.f.values||{});}},modal:(...args)=>{rendered=args;},document:{getElementById:()=>form},mutate:async(...args)=>{mutations.push(args);await new Promise(resolve=>{resolveMutation=resolve;});},closeModal:()=>{},render:()=>{},toast:()=>{},native:async()=>({})};vm.runInNewContext(fs.readFileSync(require.resolve('../Web/performance.js'),'utf8'),context);return {P:context.module.exports,form,context,mutations,getRendered:()=>rendered,release:()=>resolveMutation?.()};}

test('workspace import opens a preview-only multi-agent form and provides subject IDs',()=>{
 const ui=uiContext();ui.P.importForm();const modal=ui.getRendered();assert.match(modal[0],/multiple agents or teams/);assert.match(modal[1],/EXISTING_AGENT_ID/);assert.match(modal[1],/Waco &lt;Team&gt;/);assert.match(modal[1],/does not connect an MLS feed/);assert.equal(ui.mutations.length,0);
});

test('reviewed multi-agent import ignores a double save while one mutation is pending',async()=>{
 const ui=uiContext(),button={dataset:{action:'perf-import-save'},disabled:false,closest:()=>ui.form};
 const first=ui.P.handleAction(button);assert.equal(ui.mutations.length,1);assert.equal(button.disabled,true);
 await ui.P.handleAction(button);await ui.P.handleSubmit(ui.form);assert.equal(ui.mutations.length,1);
 ui.release();await first;assert.equal(button.disabled,false);assert.equal(ui.form._performanceImport,undefined);
 await assert.rejects(ui.P.handleAction(button),/Review the import again/);
});

test('manual period editor binds a record ID and prevents duplicate pending saves',async()=>{
 const ui=uiContext();ui.form.dataset={kind:'perf-edit',agentId:'a',year:'2025',revision:'2',recordId:'a:2025'};ui.form._performanceRecord={...sourceRow(),id:'a:2025',revision:2};ui.form.values={...sourceRow(),sourceLabel:'Source',sourceCheckedAt:'2026-10-29',changeReason:'Verified revision',buyerUnits:'0',buyerVolume:'0',sellerUnits:'',sellerVolume:'',dualSidedUnits:'',dualSidedVolume:''};
 const first=ui.P.handleSubmit(ui.form);assert.equal(ui.mutations.length,1);assert.equal(ui.mutations[0][1].recordId,'a:2025');assert.equal(ui.mutations[0][1].sellerVolume,null);
 await ui.P.handleSubmit(ui.form);assert.equal(ui.mutations.length,1);ui.release();await first;
});


test('source IDs preserve punctuation and coverage notes survive payload conversion',()=>{
 const p=P.payloadFromValues({sourceLabel:'Source',sourceRecordIds:'["0001,A","ID-02/3"]',coverageNotes:'Legacy feed incomplete before transition'},'a',2025,0);
 assert.deepEqual(p.source.recordIds,['0001,A','ID-02/3']);assert.equal(p.coverageNotes,'Legacy feed incomplete before transition');
 assert.throws(()=>P.payloadFromValues({sourceRecordIds:'0001,A'},'a',2025,0),/JSON array/);
});

test('explicit unique aggregate is preserved without inventing buyer or seller splits',()=>{
 const row=sourceRow({buyerUnits:null,buyerVolume:null,sellerUnits:null,sellerVolume:null,dualSidedUnits:null,dualSidedVolume:null,reportedVolume:2500000,volumeDefinition:'unique_closed_volume'});
 const [saved]=P.parseImport(JSON.stringify([row]),'',current);assert.equal(P.totals(saved).uniqueVolume,2500000);assert.equal(P.totals(saved).uniqueUnits,null);assert.equal(saved.buyerVolume,null);assert.equal(saved.sellerVolume,null);
 assert.equal(P.totals({...saved,volumeDefinition:'unverified_total'}).uniqueVolume,null);
 assert.throws(()=>P.parseImport(JSON.stringify([{...row,volumeDefinition:undefined}]),'',current),/unique_closed_volume/);
 assert.throws(()=>P.parseImport(JSON.stringify([sourceRow({reportedVolume:99000000,volumeDefinition:'unique_closed_volume'})]),'',current),/conflicts/);
 const p=P.payloadFromValues({sourceLabel:'Verified source',reportedVolume:'2500000',volumeDefinition:'unique_closed_volume'},'a',2025,0);assert.equal(p.reportedVolume,2500000);assert.equal(p.volumeDefinition,'unique_closed_volume');assert.equal(p.buyerVolume,null);
 assert.throws(()=>P.payloadFromValues({reportedVolume:'2500000'},'a',2025,0),/Confirm the source/);
});

test('legacy unlinked team sources can be revised by exact record ID without inventing a team',()=>{
 const legacy={...sourceRow({periodType:undefined,attribution:'team'}),id:'a:2025',revision:2};
 const d={...current,performance:[legacy]},row=sourceRow({periodType:undefined,attribution:'team',recordId:'a:2025'});
 const [saved]=P.parseImport(JSON.stringify([row]),'',d);assert.equal(saved.recordId,'a:2025');assert.equal(saved.expectedRevision,2);assert.equal(saved.teamId,undefined);
});

test('editing a team-owned source preserves its empty agent association and aggregate evidence',async()=>{
 const ui=uiContext(),team={...sourceRow({agentId:'',teamId:'t',attribution:'team',reportedVolume:2500000,volumeDefinition:'unique_closed_volume'}),id:'team-series',revision:1};ui.context.D={...current,performance:[team]};
 await ui.P.handleAction({dataset:{action:'perf-edit',id:'a',year:'2025',recordId:'team-series'}});
 const rendered=ui.getRendered();assert.match(rendered[4],/data-agent-id=""/);assert.match(rendered[1],/name="reportedVolume"[^>]*value="2500000"/);assert.match(rendered[1],/Source record IDs \(JSON array\)/);assert.equal(ui.form._performanceRecord.id,'team-series');
});
