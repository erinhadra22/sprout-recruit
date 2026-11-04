'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const UI=require('../Web/meetings.js');
const data=()=>({agents:[{id:'a',name:'Agent <Example>',email:'agent@example.com'},{id:'no-email',name:'Missing Email'}],settings:[{id:'workspace',timezone:'America/Chicago'},{id:'meeting-participants',participants:['recruiter@example.com','manager@example.com'],defaultDurationMinutes:60,revision:2}],workflows:[],activities:[],meetings:[]});
test('booking requires saved agent email and shows exact fixed participants with editable duration',()=>{
 const d=data(),form=UI.bookingForm(d,'a','uuid');
 assert.equal(form.kind,'meeting-booking');assert.match(form.body,/Agent &lt;Example&gt;/);
 for(const email of ['agent@example.com','recruiter@example.com','manager@example.com'])assert.match(form.body,new RegExp(email));
 assert.match(form.body,/name="durationMinutes"[^>]*value="60"/);
 assert.doesNotMatch(form.body,/name="agentEmail"|name="internalParticipants"/);
 assert.match(form.body,/Google sends invitations/);assert.match(form.body,/Contact notes and call content are omitted/);
 const missing=UI.bookingForm(d,'no-email','uuid');assert.equal(missing.kind,'');assert.match(missing.footer,/data-action="edit-contact"/);assert.doesNotMatch(missing.footer,/type="submit"/);
 assert.deepEqual(UI.defaults({}).participants,[]);assert.equal(UI.defaults({}).defaultDurationMinutes,60);
});
test('conversation selection includes only explicit connected calls for the exact contact',()=>{
 const d=data();d.workflows=[{id:'w',agentId:'a',outcome:'connected',interactionId:'linked',occurredOn:'2026-11-04'},{id:'completed',agentId:'a',outcome:'completed'}];d.activities=[{id:'linked',agentId:'a',kind:'interaction',title:'Call — Connected'},{id:'manual',agentId:'a',kind:'interaction',title:'Call — Connected'},{id:'other',agentId:'b',kind:'interaction',title:'Call — Connected'},{id:'voicemail',agentId:'a',kind:'interaction',title:'Call — Left voicemail'}];
 assert.deepEqual(UI.connectedConversations(d,'a').map(c=>c.id),['workflow:w','activity:manual']);
});
test('saved meetings expose honest pending reconciliation, provider link and explicit held action',()=>{
 const d=data();d.meetings=[{id:'pending<id',agentId:'a',state:'submitted',googleEventId:'exact-event',attendees:['agent@example.com']},{id:'booked',agentId:'a',state:'booked',providerVerifiedAt:'2026-11-04T12:00:00Z',startsAt:'2026-11-05T16:00:00Z',googleHtmlLink:'https://www.google.com/calendar/event?eid=exact',attendees:['agent@example.com']},{id:'held',agentId:'a',state:'booked',providerVerifiedAt:'yes',heldAt:'2026-11-04T12:00:00Z',googleHtmlLink:'javascript:alert(1)'}];
 const html=UI.renderContact(d,'a');assert.match(html,/pending&lt;id/);assert.match(html,/exact-event/);assert.match(html,/data-action="meeting-reconcile"/);assert.match(html,/data-action="meeting-held"[^>]*data-id="booked"/);assert.doesNotMatch(html,/data-action="meeting-held"[^>]*data-id="held"|javascript:/);
 assert.equal(UI.calendarLink('https://evil.invalid/calendar'),null);
});
function harness(){
 const c=vm.createContext({D:data(),Intl,Date,URL,JSON,console,crypto:{randomUUID:()=> '11111111-1111-4111-8111-111111111111'},FormData:class {constructor(form){this.form=form;}entries(){return Object.entries(this.form.values||{})[Symbol.iterator]();}},modal:(...args)=>{c.dialog=args;},closeModal:()=>{c.closed=(c.closed||0)+1;},render:()=>{},document:{getElementById:()=>({innerHTML:''})},native:async(action,p)=>{c.previews=(c.previews||[]).concat([{action,p}]);return {title:'Meeting title',previewToken:'token',attendees:['agent@example.com','manager@example.com']};},mutate:async(action,p)=>{c.mutations=(c.mutations||[]).concat([{action,p}]);}});
 vm.runInContext(fs.readFileSync(require.resolve('../Web/meetings.js'),'utf8')+';globalThis.UI=MeetingBookingUI',c);return c;
}
test('booking first previews then requires the explicit create action; duplicate submit sends once',async()=>{
 const c=harness();const form={dataset:{kind:'meeting-booking',bookingId:'11111111-1111-4111-8111-111111111111',agentId:'a',agentEmail:'agent@example.com',participantsRevision:'2',internalParticipants:'["recruiter@example.com","manager@example.com"]'},values:{localDateTime:'2026-11-05T10:00',timeZone:'America/Chicago',durationMinutes:'60',linkedConversationID:''}};
 await c.UI.handleSubmit(form);assert.equal(c.previews[0].action,'meetings.preview');assert.equal(c.mutations,undefined);assert.equal(c.dialog[2],'meeting-confirm');assert.match(c.dialog[3],/Create Google Calendar event/);
 const confirm={dataset:{kind:'meeting-confirm',bookingId:form.dataset.bookingId},querySelector:()=>({})};
 await Promise.all([c.UI.handleSubmit(confirm),c.UI.handleSubmit(confirm)]);assert.equal(c.mutations.length,1);assert.equal(c.mutations[0].action,'meetings.book');assert.equal(c.mutations[0].p.previewToken,'token');assert.equal(c.mutations[0].p.durationMinutes,60);
});
test('fixed participants can be edited in Settings and remain a saved explicit list',async()=>{
 const c=harness();await c.UI.handleSubmit({dataset:{kind:'meeting-settings',revision:'2'},values:{participants:'recruiter@example.com\nmanager@example.com\nadditional@example.com',defaultDurationMinutes:'60'}});
 assert.equal(c.mutations[0].action,'meetings.participants.save');assert.equal(c.mutations[0].p.participants.length,3);assert.equal(c.mutations[0].p.expectedRevision,2);
 const html=UI.renderSettings(data());assert.match(html,/Connect Google Calendar/);assert.match(html,/create events in your own calendar and send invitations/);
});
test('status dropdown opens the real booking form before any contact or calendar mutation',async()=>{
 const path=require('node:path'),web=path.join(__dirname,'../Web'),Model=require('../Web/model.js'),handlers={},mutations=[];
 const c=vm.createContext({Model,Intl,Date,URL,crypto:{randomUUID:()=> '11111111-1111-4111-8111-111111111111'},icon:()=>'',document:{getElementById:()=>({}),addEventListener:(name,handler)=>{handlers[name]=handler;}},window:{},console});
 for(const file of ['meetings.js','task-controls.js','weekly-reports.js','sourcing-rules.js'])vm.runInContext(fs.readFileSync(path.join(web,file),'utf8'),c);
 const app=fs.readFileSync(path.join(web,'app.js'),'utf8');vm.runInContext(app.slice(0,app.indexOf("document.addEventListener('click'")),c);
 c.fixture=data();c.fixture.agents[0].status='Connected';c.mutations=mutations;
 vm.runInContext("D=fixture;mutate=async(action,p)=>{mutations.push([action,p]);};native=async()=>{throw Error('Opening the booking form must not contact a provider.');};modal=(...args)=>{globalThis.bookingDialog=args;};",c);
 const start=app.indexOf("document.addEventListener('change',async"),end=app.indexOf('let inputTimer;',start);assert.ok(start>=0&&end>start);vm.runInContext(app.slice(start,end),c);
 const element={dataset:{agentField:'status',id:'a'},value:'Meeting scheduled',disabled:false};await handlers.change({target:element});
 assert.equal(element.value,'Connected');assert.equal(c.fixture.agents[0].status,'Connected');assert.equal(mutations.length,0);assert.equal(c.bookingDialog[0],'Book a meeting');assert.equal(c.bookingDialog[2],'meeting-booking');assert.match(c.bookingDialog[1],/agent@example.com/);assert.match(c.bookingDialog[3],/Review meeting/);
 const missing={dataset:{agentField:'status',id:'no-email'},value:'Meeting scheduled'};await handlers.change({target:missing});assert.equal(c.bookingDialog[0],'Add the agent email first');assert.equal(mutations.length,0);
});
