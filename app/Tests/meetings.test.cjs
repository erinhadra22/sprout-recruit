'use strict';
const test=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const UI=require('../Web/meetings.js');
const data=()=>({agents:[{id:'a',name:'Agent <Example>',email:'agent@example.com'},{id:'no-email',name:'Missing Email'}],settings:[{id:'workspace',timezone:'America/Chicago'},{id:'meeting-participants',participants:['recruiter@example.com','manager@example.com'],defaultDurationMinutes:60,revision:2}],workflows:[],activities:[],meetings:[]});
test('booking requires saved agent email and shows exact fixed participants with editable duration',()=>{
 const d=data(),form=UI.bookingForm(d,'a','uuid');
 assert.equal(form.kind,'meeting-booking');assert.match(form.body,/Agent &lt;Example&gt;/);
 for(const email of ['agent@example.com','recruiter@example.com','manager@example.com'])assert.match(form.body,new RegExp(email));
 assert.match(form.body,/name="title"[^>]*value="Sprout recruiting meeting — Agent &lt;Example&gt;"/);
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
test('disconnected failure before prepare keeps the unsaved booking retryable with its same ID',async()=>{
 const c=harness(),out={innerHTML:''},button={};c.document.getElementById=()=>out;
 const calls=[];c.native=async(action,p)=>{calls.push({action,p});return action==='meetings.status'?{exists:false}:{title:'Fixture meeting',previewToken:'frozen-token',attendees:['agent@example.com']};};
 c.mutate=async()=>{throw Error('Connect Google Calendar in Settings before creating an invitation. No event was submitted.');};
 const id='11111111-1111-4111-8111-111111111111',form={dataset:{kind:'meeting-booking',bookingId:id,agentId:'a',agentEmail:'agent@example.com',participantsRevision:'2',internalParticipants:'["recruiter@example.com","manager@example.com"]'},values:{localDateTime:'2026-11-05T10:00',timeZone:'America/Chicago',durationMinutes:'60'}};
 await c.UI.handleSubmit(form);const confirm={dataset:{kind:'meeting-confirm',bookingId:id},querySelector:()=>button};await c.UI.handleSubmit(confirm);
 assert.equal(button.disabled,false);assert.match(button.textContent,/Retry/);assert.match(out.innerHTML,/No calendar submission was recorded/);assert.match(out.innerHTML,/data-action="meeting-calendar-connect"/);assert.doesNotMatch(out.innerHTML,/Check this saved|data-action="meeting-reconcile"/);
 assert.equal(calls.find(x=>x.action==='meetings.status').p.id,id);
 let retried;c.mutate=async(action,p)=>{retried={action,p};};await c.UI.handleSubmit(confirm);assert.equal(retried.p.id,id);assert.equal(retried.p.previewToken,'frozen-token');
});
test('only a saved submitted booking locks the create action into exact-event reconciliation',async()=>{
 for(const [state,locked] of [['prepared',false],['submitted',true],['booked',true]]){
  const c=harness(),out={innerHTML:''},button={};c.document.getElementById=()=>out;
  c.native=async(action)=>action==='meetings.status'?{exists:true,state,googleEventId:'exact-event'}:{title:'Fixture',previewToken:'token',attendees:['agent@example.com']};c.mutate=async()=>{throw Error('Booking could not finish.');};
  const form={dataset:{kind:'meeting-booking',bookingId:'id',agentId:'a',agentEmail:'agent@example.com',participantsRevision:'2',internalParticipants:'[]'},values:{localDateTime:'2026-11-05T10:00',timeZone:'America/Chicago',durationMinutes:'60'}};
  await c.UI.handleSubmit(form);await c.UI.handleSubmit({dataset:{kind:'meeting-confirm',bookingId:'id'},querySelector:()=>button});assert.equal(button.disabled,locked);
  if(locked){assert.match(out.innerHTML,/exact-event/);assert.match(out.innerHTML,/data-action="meeting-reconcile"/);}else assert.doesNotMatch(out.innerHTML,/data-action="meeting-reconcile"/);
 }
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
test('saved meetings expose Calendar refresh, exact RSVP and cancellation without a held action',async()=>{
 const c=harness(),d=data();
 d.meetings=[{id:'active',agentId:'a',state:'booked',providerVerifiedAt:'yes',agentCalendarResponse:'accepted'},
  {id:'cancelled',agentId:'a',state:'booked',providerVerifiedAt:'yes',status:'cancelled'}];
 const html=UI.renderContact(d,'a');
 assert.match(html,/Google Calendar booking verified · Accepted/);
 assert.match(html,/Cancelled in Google Calendar/);
 assert.match(html,/data-action="meeting-refresh"[^>]*data-id="cancelled"/);
 assert.doesNotMatch(html,/data-action="meeting-held"[^>]*data-id="cancelled"/);
 await c.UI.handleAction({dataset:{action:'meeting-refresh',id:'active'}});
 assert.equal(c.mutations[0].action,'meetings.refresh');
 assert.equal(c.mutations[0].p.id,'active');
});
test('one Calendar submit shows progress and renders the saved connection without a status reread',async()=>{
 const c=harness(),button={},progress={},error={textContent:'Prior error'},calls=[];
 let complete;
 c.native=(action,payload)=>{
  calls.push({action,payload});
  return new Promise(resolve=>{complete=resolve;});
 };
 const form={dataset:{kind:'meeting-calendar-connect'},querySelector:selector=>({
  'button[type=submit]':button,'[data-calendar-progress]':progress,'.form-error':error
 })[selector]};
 const pending=c.UI.handleSubmit(form);
 await c.UI.handleSubmit(form);
 assert.equal(button.disabled,true);
 assert.match(progress.textContent,/Opening Google sign-in/);
 assert.equal(error.textContent,'');
 assert.equal(calls.length,1);
 assert.equal(calls[0].action,'calendar.connect');
 assert.equal(calls[0].payload.confirmed,true);
 complete({connected:true,accountAddress:'recruiter@example.com'});
 await pending;
 assert.equal(calls.length,1);
 assert.equal(c.closed,1);
 assert.match(c.UI.renderSettings(c.D),/Connected · recruiter@example.com/);
});

test('every saved contact exposes Book meeting before its first booking',()=>{
 const d=data(),html=UI.renderContact(d,'a');
 assert.match(html,/data-action="meeting-open"[^>]*data-id="a"/);
 assert.match(html,/Book meeting/);
 assert.equal(UI.renderContact(d,'missing-contact'),'');
});
test('meeting proposals prefill only shared meeting details and retain the exact review identity',async()=>{
 const c=harness();
 c.D.meetingProposals=[{id:'11111111-1111-4111-8111-111111111111',agentId:'a',state:'needs_details',title:'TEST — Meeting <review>',missingFields:['localDateTime'],timeZone:'America/Denver',durationMinutes:45,location:'Office <A>',description:'Discuss the role & next steps',privateNotes:'Private notes are not invitation details',internalParticipants:['foreign@example.com'],agentEmail:'foreign@example.com'}];
 const html=c.UI.renderOutbox(c.D);
 assert.match(html,/Details needed · date and time/);
 assert.match(html,/Office &lt;A&gt;/);
 assert.match(html,/data-action="meeting-review-proposal"/);
 assert.doesNotMatch(html,/Private notes|foreign@example.com/);
 await c.UI.handleAction({dataset:{action:'meeting-review-proposal',id:c.D.meetingProposals[0].id}});
 assert.match(c.dialog[1],/name="title"[^>]*maxlength="500"[^>]*value="TEST — Meeting &lt;review&gt;"/);
 assert.match(c.dialog[1],/name="timeZone" value="America\/Denver"/);
 assert.match(c.dialog[1],/name="durationMinutes"[^>]*value="45"/);
 assert.match(c.dialog[1],/name="location"[^>]*value="Office &lt;A&gt;"/);
 assert.match(c.dialog[1],/Discuss the role &amp; next steps/);
 assert.match(c.dialog[1],/agent@example.com/);
 assert.doesNotMatch(c.dialog[1],/Private notes|foreign@example.com/);
 assert.match(c.dialog[4],/data-proposal-id="11111111-1111-4111-8111-111111111111"/);
 assert.equal(c.mutations,undefined);
 const form={dataset:{kind:'meeting-booking',bookingId:c.D.meetingProposals[0].id,proposalId:c.D.meetingProposals[0].id,agentId:'a',agentEmail:'agent@example.com',participantsRevision:'2',internalParticipants:'["recruiter@example.com","manager@example.com"]'},values:{title:'TEST — Sprout Calendar workflow',localDateTime:'2027-01-05T10:00',timeZone:'America/Denver',durationMinutes:'45',location:'Office <A>',description:'Discuss the role & next steps'}};
 c.native=async(action,payload)=>{c.reviewPayload=payload;return {...payload,title:'Sprout recruiting meeting',previewToken:'reviewed',attendees:['agent@example.com','manager@example.com']};};
 await c.UI.handleSubmit(form);
 assert.equal(c.reviewPayload.proposalId,c.D.meetingProposals[0].id);
 assert.equal(c.reviewPayload.title,'TEST — Sprout Calendar workflow');
 assert.equal(c.reviewPayload.location,'Office <A>');
 assert.equal(c.reviewPayload.description,'Discuss the role & next steps');
 assert.match(c.dialog[1],/Office &lt;A&gt;/);
 assert.match(c.dialog[1],/Discuss the role &amp; next steps/);
 assert.equal(c.mutations,undefined);
 await c.UI.handleSubmit({dataset:{kind:'meeting-confirm',bookingId:form.dataset.bookingId},querySelector:()=>({})});
 assert.equal(c.mutations[0].action,'meetings.book');
 assert.equal(c.mutations[0].p.previewToken,'reviewed');
 assert.equal(c.mutations[0].p.title,'TEST — Sprout Calendar workflow');
 assert.equal(c.mutations[0].p.proposalId,form.dataset.proposalId);
});
test('completed proposals leave the review queue and saved meeting details are escaped',()=>{
 const d=data();
 d.meetingProposals=[{id:'done',agentId:'a',state:'booked'}];
 assert.equal(UI.renderOutbox(d),'');
 d.meetings=[{id:'booked',agentId:'a',state:'booked',providerVerifiedAt:'yes',location:'Office <A>',description:'Agenda & details'}];
 const html=UI.renderContact(d,'a');
 assert.match(html,/Office &lt;A&gt;/);
 assert.match(html,/Agenda &amp; details/);
});

test('a meeting request with a missing date saves to Outbox without previewing or creating an invitation',async()=>{
 const c=harness(),id='11111111-1111-4111-8111-111111111111';
 const form={dataset:{kind:'meeting-booking',bookingId:id,agentId:'a',proposalRevision:'3'},values:{title:'Discuss next steps',localDateTime:'',timeZone:'America/Chicago',durationMinutes:'60',description:'Reviewed agenda',location:'Office A',linkedConversationID:''}};
 const button={dataset:{action:'meeting-save-request'},closest:selector=>selector==='form'?form:null};
 const dialog=c.UI.bookingForm(c.D,'a',id,{revision:3});
 assert.match(dialog.footer,/<button[^>]*type="button"[^>]*data-action="meeting-save-request"/);
 assert.match(dialog.attrs,/data-proposal-revision="3"/);
 assert.equal(c.previews,undefined);
 await c.UI.handleAction(button);
 assert.equal(c.previews,undefined);
 assert.equal(c.mutations.length,1);
 assert.equal(c.mutations[0].action,'meetings.propose');
 assert.equal(c.mutations[0].p.id,id);
 assert.equal(c.mutations[0].p.agentId,'a');
 assert.equal(c.mutations[0].p.expectedRevision,3);
 assert.equal(c.mutations[0].p.localDateTime,'');
 assert.equal(c.mutations[0].p.sourceActor,'Reviewed UI');
 assert.equal(c.mutations[0].p.sourceReference,'contact:a');
 assert.equal(c.closed,1);
});
