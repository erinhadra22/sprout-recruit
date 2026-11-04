const test=require('node:test');
const assert=require('node:assert/strict');
const fs=require('node:fs'),vm=require('node:vm');
const W=require('../Web/weekly-reports.js');
const report={filters:{fromDate:'2026-10-26',toDate:'2026-11-01',timeZone:'America/Chicago'},generatedAt:'2026-11-04T15:00:00Z',metrics:{calls:4,connectedCalls:1,messages:2,emails:0,messageReplies:2,emailReplies:1,meetingResponses:3,tasksCompleted:8},verificationCounts:{manual:7,user:1,external_history:6},distinctContacts:3,events:[{date:'2026-10-26',metric:'calls'},{date:'2026-10-26',metric:'tasksCompleted'},{date:'2026-10-27',metric:'emails'},{date:'2026-10-27',metric:'emailReplies'},{date:'2026-10-29',metric:'meetingResponses'}]};
test('weekly window uses completed Monday through Sunday across DST, year and leap boundaries',()=>{
 assert.deepEqual(W.lastCompletedWeek('2026-11-04'),{fromDate:'2026-10-26',toDate:'2026-11-01'});
 assert.deepEqual(W.lastCompletedWeek('2026-11-02'),{fromDate:'2026-10-26',toDate:'2026-11-01'});
 assert.deepEqual(W.lastCompletedWeek('2026-11-01'),{fromDate:'2026-10-19',toDate:'2026-10-25'});
 assert.deepEqual(W.lastCompletedWeek('2027-01-01'),{fromDate:'2026-12-21',toDate:'2026-12-27'});
 assert.deepEqual(W.lastCompletedWeek('2024-03-04'),{fromDate:'2024-02-26',toDate:'2024-03-03'});
 for(const date of ['2026-02-30','2026-2-01','invalid'])assert.throws(()=>W.lastCompletedWeek(date));
});
test('charts show factual counts, do not call task completions outreach, and preserve zeros',()=>{
 const html=W.charts(report);assert.match(html,/Call attempts/);assert.match(html,/Meeting responses/);assert.match(html,/A completed task is not a call/);
 assert.match(html,/2026-10-26<\/span>.*?<strong>1<\/strong>/);assert.match(html,/2026-10-27<\/span>.*?<strong>1<\/strong>/);
 assert.match(html,/2026-10-29<\/span>.*?<strong>0<\/strong>/);assert.match(html,/Emails<\/span>.*?width:0%/);assert.doesNotMatch(html,/NaN|Infinity/);
 const empty=W.charts({...report,metrics:{},events:[]});assert.doesNotMatch(empty,/NaN|Infinity/);
});
test('email summary separates human replies, meeting responses and connected calls and omits private detail',()=>{
 const text=W.emailSummary({...report,events:[{agentName:'Private Contact',body:'Private Body'}]});
 assert.match(text,/Calls logged: 4/);assert.match(text,/Explicitly connected calls: 1/);assert.match(text,/Email replies imported: 1/);assert.match(text,/Meeting responses imported: 3/);assert.match(text,/Tasks completed: 8/);assert.match(text,/Contact details, message bodies and notes are omitted/);assert.doesNotMatch(text,/Private Contact|Private Body/);
});
test('panel escapes delivery-plan values and honestly shows inactive automatic delivery',()=>{
 const html=W.render({today:'2026-11-04',settings:[{id:'weekly-report-delivery',recipients:['<bad>'],weekday:1,time:'08:00',timeZone:'America/Chicago'}]});
 assert.match(html,/&lt;bad&gt;/);assert.doesNotMatch(html,/<bad>/);assert.match(html,/Automatic email: not active/);assert.match(html,/recruiting activity, not agent sales production/);assert.match(html,/Automatic delivery needs a verified Codex schedule and connected email sender/);
});
function ui(){let resolvePreview,renderCount=0,closed=0;const calls=[],D={today:'2026-11-04',settings:[],reports:[]};const c={module:{exports:{}},Date,Set,Map,JSON,Number,String,Array,Error,D,crypto:{randomUUID:()=> 'fixture-id'},FormData:class{constructor(f){this.f=f}entries(){return Object.entries(this.f.values||{})}},native:async(action,p)=>{calls.push([action,p]);if(action==='performance.report')return new Promise(r=>resolvePreview=r);return {};},mutate:async(action,p)=>{calls.push([action,p]);},render:()=>{renderCount++},toast:()=>{},closeModal:()=>closed++};vm.runInNewContext(fs.readFileSync(require.resolve('../Web/weekly-reports.js'),'utf8'),c);return {W:c.module.exports,c,calls,resolve:r=>resolvePreview(r),renderCount:()=>renderCount,closed:()=>closed};}
test('preview requests native evidence in saved zone with real contacts only; repeated clicks do not duplicate it',async()=>{
 const u=ui();const pending=u.W.handleAction({dataset:{action:'weekly-report-preview'}});await u.W.handleAction({dataset:{action:'weekly-report-preview'}});assert.equal(u.calls.length,1);assert.equal(u.calls[0][0],'performance.report');assert.equal(u.calls[0][1].includeSamples,false);assert.equal(u.calls[0][1].timeZone,'America/Chicago');u.resolve(report);await pending;assert.equal(u.renderCount(),2);assert.match(u.W.render(u.c.D),/Calls include attempts/);
 await u.W.handleAction({dataset:{action:'weekly-report-copy'}});assert.equal(u.calls[1][0],'copy');assert.equal(u.calls.length,2);assert.doesNotMatch(u.calls.map(x=>x[0]).join(','),/send|schedule/);
});
test('delivery plan submission saves only schedule intent through validated backend',async()=>{
 const u=ui();await u.W.handleSubmit({dataset:{revision:'3'},values:{recipients:'manager@example.com, other@example.com',weekday:'5',time:'09:30',timeZone:'America/Chicago',subject:'Recruiting summary'}});
 assert.equal(u.calls[0][0],'report.deliveryPlan.save');assert.equal(u.calls[0][1].expectedRevision,3);assert.equal(u.calls[0][1].weekday,5);assert.deepEqual(Array.from(u.calls[0][1].recipients),['manager@example.com','other@example.com']);assert.equal(u.calls[0][1].enabled,undefined);assert.equal(u.closed(),1);
});
test('app Performance route loads real weekly panel, saved reports and its native preview action',async()=>{
 const path=require('node:path'),web=path.join(__dirname,'../Web'),Model=require('../Web/model.js'),calls=[];
 const context=vm.createContext({Model,Date,Intl,Set,Map,JSON,Number,String,Array,Error,icon:()=>'',document:{getElementById:()=>({})},window:{},console});
 for(const file of ['performance.js','weekly-reports.js','sourcing-rules.js','task-controls.js','meetings.js'])vm.runInContext(fs.readFileSync(path.join(web,file),'utf8'),context);
 const app=fs.readFileSync(path.join(web,'app.js'),'utf8');vm.runInContext(app.slice(0,app.indexOf("document.addEventListener('click'")),context);
 context.fixture={today:'2026-11-04',settings:[{id:'workspace',name:'Fixture Recruiter'}],reports:[]};context.calls=calls;context.fixtureReport=report;
 vm.runInContext("D=fixture;native=async(action,p)=>{calls.push([action,p]);return fixtureReport;};render=()=>{};globalThis.performanceHTML=renderPerformance()",context);
 assert.match(context.performanceHTML,/Weekly manager report/);assert.match(context.performanceHTML,/2026-10-26 through 2026-11-01/);assert.match(context.performanceHTML,/Saved reports/);
 await vm.runInContext("handleAction({dataset:{action:'weekly-report-preview'}})",context);
 assert.equal(calls.length,1);assert.equal(calls[0][0],'performance.report');assert.equal(calls[0][1].fromDate,'2026-10-26');assert.equal(calls[0][1].toDate,'2026-11-01');
 const html=vm.runInContext('renderPerformance()',context);assert.match(html,/Daily outreach/);assert.match(html,/Meeting responses/);assert.match(html,/Saved reports/);
 const index=fs.readFileSync(path.join(web,'index.html'),'utf8');assert.ok(index.indexOf('src="weekly-reports.js"')<index.indexOf('src="app.js"'));assert.match(index,/href="weekly-reports.css"/);
});
test('manager default is Cody Monday morning and never implies an active schedule',()=>{
 const html=W.render({today:'2026-11-04',settings:[]});assert.match(html,/cody@sprouthomes.com/);assert.match(html,/Monday 09:00 America\/Chicago/);assert.match(html,/Automatic email: not active/);
});
test('automation badge requires the exact verified plan and exposes host and last-send limits',()=>{
 const p={id:'weekly-report-delivery',recipients:['cody@sprouthomes.com'],weekday:1,time:'08:00',timeZone:'America/Chicago',revision:2};
 const a={id:'weekly-report-automation',automationId:'saved-heartbeat',enabled:true,status:'active',mechanism:'codex_heartbeat',recipient:'cody@sprouthomes.com',weekday:1,time:'08:00',timeZone:'America/Chicago',planRevision:2,lastSentAt:'2026-11-02T14:00:00Z',lastError:'<provider failure>'};
 assert.equal(W.automationMatches(p,a),true);const html=W.render({today:'2026-11-04',settings:[p,a]});assert.match(html,/Scheduled via Codex/);assert.match(html,/This host Mac and the Codex desktop app must be running/);assert.match(html,/Last recorded send/);assert.match(html,/&lt;provider failure&gt;/);
 for(const change of [{recipient:'other@example.com'},{weekday:2},{time:'09:00'},{timeZone:'UTC'},{planRevision:1},{enabled:false},{status:'paused'},{automationId:''},{mechanism:'unknown'}])assert.equal(W.automationMatches(p,{...a,...change}),false);
 assert.match(W.render({today:'2026-11-04',settings:[{...p,revision:3},a]}),/Automatic email: not active/);
});
test('conversion UI shows exact linked numerator and denominator with incomplete coverage',()=>{
 const measured={...report,rates:{conversationToMeeting:{numerator:2,denominator:3,percent:200/3,coverageNote:'History may be incomplete.',unlinkedBookings:0}},metrics:{...report.metrics,appointmentsBooked:3,meetingsHeld:1,convertedConversations:2}};
 const html=W.conversionMarkup(measured);assert.match(html,/2 conversations linked/);assert.match(html,/3 explicit conversations/);assert.match(html,/66.7%/);assert.match(html,/History may be incomplete/);assert.match(html,/Each conversation counts once/);
 const unknown=W.conversionMarkup({...measured,rates:{conversationToMeeting:{numerator:0,denominator:3,percent:null,unlinkedBookings:2}}});assert.match(unknown,/Unavailable/);assert.match(unknown,/2 bookings have no conversation link/);assert.doesNotMatch(unknown,/>0.0%/);
 const summary=W.emailSummary(measured);assert.match(summary,/Appointments booked: 3/);assert.match(summary,/Meetings held: 1/);assert.match(summary,/2 \/ 3 \(66.7%\)/);assert.match(summary,/missing links do not imply zero conversions/);
 const charts=W.charts(measured);assert.match(charts,/Appointments booked/);assert.match(charts,/Meetings held/);assert.match(charts,/Conversations/);
});
