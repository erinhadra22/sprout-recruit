const test=require('node:test'),assert=require('node:assert/strict');
const UI=require('../Web/sourcing-rules.js');
test('target audience preserves full explicit names and deduplicates only normalized exact variants',()=>{
 const p=UI.payload({expectedRevision:'4',name:'Local experienced agents',description:'Evidence first',excludedBrokerages:'Acme Realty\n ACME-Realty \nAcme Realty West\n',excludedTeams:'Café Team\nCafe Team'});
 assert.deepEqual(p.excludedBrokerages,['Acme Realty','Acme Realty West']);assert.deepEqual(p.excludedTeams,['Café Team']);assert.equal(p.expectedRevision,4);assert.equal(p.schemaVersion,1);
});
test('target audience rejects malformed and unbounded values',()=>{
 const base={name:'Audience',expectedRevision:0};
 for(const change of [{name:''},{expectedRevision:-1},{expectedRevision:'x'},{description:'x'.repeat(6001)},{excludedTeams:'--'},{excludedBrokerages:'a'.repeat(201)},{excludedTeams:Array.from({length:101},(_,i)=>'Team '+i)}])assert.throws(()=>UI.payload({...base,...change}));
});
test('target audience card renders actual saved rules with escaped evidence and revision',()=>{
 const html=UI.render({settings:[{id:'ai-context',name:'Wrong'},{id:'sourcing-rules',revision:7,name:'<Audience>',description:'Use <source>',excludedBrokerages:['A & B'],excludedTeams:['<Team>'],updatedAt:'2026-11-04T15:00:00Z'}]});
 assert(html.includes('value="7"'));assert(html.includes('&lt;Audience&gt;'));assert(html.includes('A &amp; B'));assert(html.includes('&lt;Team&gt;'));assert(html.includes('2 exclusions'));assert(!html.includes('<Team>'));assert(!html.includes('Wrong'));assert(html.includes('external schedule'));assert(html.includes('sourcing-rules-form'));
});
test('empty target audience invents no business exclusions',()=>{
 const r=UI.record({settings:[]});assert.deepEqual(r.excludedBrokerages,[]);assert.deepEqual(r.excludedTeams,[]);assert.equal(r.revision,0);assert(UI.render({settings:[]}).includes('0 exclusions'));
});
