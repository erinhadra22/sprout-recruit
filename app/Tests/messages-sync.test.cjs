'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname,'../Web/messages-sync.js'),'utf8');
const clone = value => JSON.parse(JSON.stringify(value));
const initial = changes => ({enabled:false,status:'disabled',uniqueCandidateCount:3,ambiguousCandidateCount:0,importedReplies:0,newReplyCount:0,...changes});

function setup(state = initial(), customNative) {
 let snapshot = state === null ? {agents:[]} : {agents:[],messagesSync:clone(state)};
 let renders = 0, adopted = 0, intervals = 0;
 const calls = [], toasts = [], roots = [];
 const document = {querySelectorAll:selector => selector === '[data-messages-sync]' ? roots : [],activeElement:null};
 const context = vm.createContext({Date,Number,Set,Promise,Array,document,setInterval:() => intervals++});
 vm.runInContext(source + ';globalThis.ui=MessagesSyncUI;', context);
 const defaultNative = async (action,payload) => {
  const before = snapshot.messagesSync || initial();
  switch (action) {
   case 'messagesSync.status': return clone(before);
   case 'messagesSync.configure':
    snapshot = {...snapshot,messagesSync:{...before,enabled:payload.enabled,status:payload.enabled ? 'ready' : 'disabled',since:before.since || (payload.enabled ? '2026-10-28T20:00:00Z' : undefined)}};
    return clone(snapshot);
   case 'messagesSync.scan': snapshot.messagesSync = {...before,status:'syncing'}; return clone(snapshot.messagesSync);
   case 'messagesSync.openPrivacy': return {opened:true};
   default: throw Error('Unexpected native action: ' + action);
  }
 };
 context.ui.bind({
  getData:() => snapshot,
  adoptSnapshot:value => { snapshot = clone(value); adopted++; },
  native:async (action,payload) => { calls.push({action,payload:clone(payload || {})}); return customNative ? customNative(action,payload,{defaultNative,get snapshot(){return snapshot;}}) : defaultNative(action,payload); },
  render:() => renders++,
  toast:(message,options) => toasts.push({message,options})
 });
 return {ui:context.ui,calls,toasts,roots,document,get snapshot(){return snapshot;},get renders(){return renders;},get adopted(){return adopted;},get intervals(){return intervals;}};
}
const click = (fixture,action) => fixture.ui.handle('messages-sync-' + action,{dataset:{action:'messages-sync-' + action}});
const buttonMarkup = (html,action) => html.match(new RegExp('<button[^>]*data-action="messages-sync-' + action + '"[^>]*>[^<]*</button>'))?.[0] || '';
const lastSuccess = html => html.match(/<dt>Last successful scan<\/dt><dd>(.*?)<\/dd>/)?.[1];

test('default-off rendering, binding and polling cannot enable or start a scan', async () => {
 const t = setup(null);
 const html = t.ui.renderConnection();
 assert.match(html,/data-messages-sync/);
 assert.match(html,/>Off<\/span>/);
 assert.match(html,/When you enable sync/);
 assert.match(html,/data-action="messages-sync-review-enable"/);
 assert.doesNotMatch(html,/data-action="messages-sync-enable"/);
 assert.equal(t.calls.length,0);
 assert.equal(t.intervals,0);
 await click(t,'enable');
 assert.equal(t.calls.length,0,'direct confirmation without visible review cannot enable sync');
 await t.ui.poll();
 assert.deepEqual(t.calls,[{action:'messagesSync.status',payload:{}}]);
 assert.equal(t.toasts.length,0);
});

test('rendered enable flow discloses broad permission and requires a separate explicit choice', async () => {
 const t = setup();
 await click(t,'review-enable');
 const html = t.ui.renderConnection();
 assert.equal(t.calls.length,0);
 assert.match(html,/Full Disk Access is a broad macOS permission/);
 assert.match(html,/app filter does not narrow the operating-system permission/);
 assert.match(html,/Earlier conversation history is not imported/);
 assert.match(html,/Group chats and email-handle chats are excluded/);
 assert.match(html,/Replies from shared numbers stay unlinked and pause outreach for identity review/);
 assert.match(html,/no cloud upload or LLM processing/);
 assert.match(html,/does not send outreach or automatically change CRM status/);
 assert.match(buttonMarkup(html,'enable'),/Enable local reply sync/);
 await click(t,'enable');
 assert.deepEqual(t.calls,[{action:'messagesSync.configure',payload:{enabled:true,confirmed:true}}]);
 assert.equal(t.snapshot.messagesSync.enabled,true);
 assert.match(t.ui.renderConnection(),/First scan pending/);
 assert.doesNotMatch(t.ui.renderConnection(),/id="messages-sync-consent-title"/);
 assert.equal(t.adopted,1,'full native snapshot is adopted after configuration');
});

test('canceling the permission review leaves sync off and performs no native write', async () => {
 const t = setup();
 await click(t,'review-enable');
 await click(t,'cancel');
 await click(t,'enable');
 assert.equal(t.calls.length,0);
 assert.doesNotMatch(t.ui.renderConnection(),/id="messages-sync-consent-title"/);
 assert.match(t.ui.renderConnection(),/>Off<\/span>/);
});

test('privacy action only opens settings and never claims that permission was granted', async () => {
 const t = setup();
 await click(t,'privacy');
 assert.deepEqual(t.calls,[{action:'messagesSync.openPrivacy',payload:{}}]);
 assert.equal(t.snapshot.messagesSync.enabled,false);
 assert.match(t.toasts[0].message,/Opening settings does not grant permission/);
});

test('blocked access preserves coverage and last-success evidence with explicit repair controls', async () => {
 const success = '2026-10-28T20:03:00Z';
 const t = setup(initial({enabled:true,status:'ready',since:'2026-10-28T20:00:00Z',lastSuccessAt:success,importedReplies:2}));
 const before = lastSuccess(t.ui.renderConnection());
 t.ui.acceptStatus(initial({enabled:true,status:'blocked',errorCode:'access_unavailable',since:'2026-10-28T20:00:00Z',lastSuccessAt:success,lastAttemptAt:'2026-10-28T20:05:00Z',lastError:'Allow Full Disk Access, then check again.',importedReplies:2}));
 const html = t.ui.renderConnection();
 assert.match(html,/Access blocked/);
 assert.match(html,/Reply coverage has a gap/);
 assert.match(html,/Newer replies may be missing/);
 assert.equal(lastSuccess(html),before);
 assert.match(buttonMarkup(html,'scan'),/Check access \/ Sync now/);
 assert.doesNotMatch(buttonMarkup(html,'scan'),/disabled/);
 assert.match(buttonMarkup(html,'privacy'),/Open Privacy Settings/);
 assert.match(html,/Allow Full Disk Access, then check again/);
 assert.equal(t.toasts.length,0);
});

test('schema, cursor and identity blocks do not imply a permission repair', () => {
 for (const errorCode of ['schema_unsupported','cursor_regression','sync_reconciliation_failed']) {
  const t = setup(initial({enabled:true,status:'blocked',errorCode,lastError:'Review the source evidence before retrying.'}));
  const html = t.ui.renderConnection();
  assert.match(html,/>Sync needs attention<\/span>/);
  assert.doesNotMatch(html,/>Access blocked<\/span>/);
  assert.doesNotMatch(buttonMarkup(html,'privacy'),/class="button primary"/);
  assert.match(html,/Review the source evidence before retrying/);
 }
});

test('unsupported status and bridge failures cannot claim up-to-date coverage or alter last success', async () => {
 const t = setup(initial({enabled:true,status:'ready',lastSuccessAt:'2026-10-28T20:00:00Z'}),async () => { throw Error('Bridge <unavailable>'); });
 const before = lastSuccess(t.ui.renderConnection());
 await t.ui.poll();
 const html = t.ui.renderConnection();
 assert.match(html,/Status needs attention/);
 assert.match(html,/Bridge &lt;unavailable&gt;/);
 assert.doesNotMatch(html,/>Up to date<\/span>|Bridge <unavailable>/);
 assert.equal(lastSuccess(html),before);
 assert.equal(t.toasts.length,0,'unchanged polling errors are inline, not repeated global toasts');
 t.ui.acceptStatus({enabled:true,status:'unexpected'});
 assert.match(t.ui.renderConnection(),/Status unavailable/);
 assert.doesNotMatch(t.ui.renderConnection(),/>Up to date<\/span>/);
});

test('status renders unknown counts distinctly, unique/ambiguous candidates and reply totals', () => {
 const unknown = setup(null).ui.renderConnection();
 assert.match(unknown,/>Not checked<\/dd>/);
 const t = setup(initial({enabled:true,status:'ready',lastSuccessAt:'2026-10-28T20:00:00Z',uniqueCandidateCount:1021,ambiguousCandidateCount:6,importedReplies:12,newReplyCount:2}));
 const html = t.ui.renderConnection();
 assert.match(html,/Candidates with a unique phone<\/dt><dd>1021/);
 assert.match(html,/Ambiguous candidates excluded<\/dt><dd>6/);
 assert.match(html,/Replies imported<\/dt><dd>12/);
 assert.match(html,/New in last scan<\/dt><dd>2/);
 assert.match(html,/Replies from shared numbers stay unlinked and pause outreach for identity review/);
 assert.match(html,/Unsupported bodies use labeled placeholders/);
 assert.match(html,/Later edits or deletions in Messages are not mirrored/);
});

test('native errors and unparseable time values are escaped as text', () => {
 const t = setup(initial({enabled:true,status:'error',lastError:'<img src=x onerror="alert(1)"> & failure',since:'<script>time</script>'}));
 const html = t.ui.renderConnection();
 assert.match(html,/&lt;img src=x onerror=&quot;alert\(1\)&quot;&gt; &amp; failure/);
 assert.match(html,/&lt;script&gt;time&lt;\/script&gt;/);
 assert.doesNotMatch(html,/<img|<script>/);
});

test('manual scan is explicit, exposes syncing, and leaves pause available', async () => {
 const off = setup(); await click(off,'scan'); assert.equal(off.calls.length,0);
 const t = setup(initial({enabled:true,status:'ready',lastSuccessAt:'2026-10-28T20:00:00Z'}));
 await click(t,'scan');
 assert.deepEqual(t.calls,[{action:'messagesSync.scan',payload:{}}]);
 const html = t.ui.renderConnection();
 assert.match(html,/Syncing…/);
 assert.match(buttonMarkup(html,'scan'),/disabled/);
 assert.doesNotMatch(buttonMarkup(html,'pause'),/disabled/);
 assert.match(html,/about every 15 seconds while this app is open/);
});

test('pause is persisted explicitly and resume retains original coverage without backfill', async () => {
 const since = '2026-10-28T19:00:00Z', lastSuccessAt = '2026-10-28T20:00:00Z';
 const t = setup(initial({enabled:true,status:'ready',since,lastSuccessAt}));
 await click(t,'pause');
 assert.deepEqual(t.calls[0],{action:'messagesSync.configure',payload:{enabled:false,confirmed:true}});
 assert.match(t.ui.renderConnection(),/>Paused<\/span>/);
 assert.equal(t.snapshot.messagesSync.since,since);
 await click(t,'review-enable');
 assert.match(t.ui.renderConnection(),/Keep the original coverage start and catch up since the last successful scan/);
 assert.match(buttonMarkup(t.ui.renderConnection(),'enable'),/Resume local reply sync/);
 await click(t,'enable');
 assert.deepEqual(t.calls[1],{action:'messagesSync.configure',payload:{enabled:true,confirmed:true}});
 assert.equal(t.snapshot.messagesSync.since,since);
 assert.equal(t.snapshot.messagesSync.lastSuccessAt,lastSuccessAt);
 assert.match(t.ui.renderConnection(),/Catch-up pending/);
 assert.doesNotMatch(t.ui.renderConnection(),/>Up to date<\/span>/);
 t.ui.acceptStatus({...t.snapshot.messagesSync,lastSuccessAt:'2026-10-28T20:01:00Z'});
 assert.match(t.ui.renderConnection(),/>Up to date<\/span>/);
});

test('late status polling after pause cannot restore an enabled state', async () => {
 let resolve;
 const old = initial({enabled:true,status:'ready',since:'2026-10-28T19:00:00Z',lastSuccessAt:'2026-10-28T20:00:00Z'});
 const t = setup(old,async (action,payload,api) => action === 'messagesSync.status' ? new Promise(r => {resolve=r;}) : api.defaultNative(action,payload));
 const pending = t.ui.poll();
 await click(t,'pause');
 resolve(old); await pending;
 assert.match(t.ui.renderConnection(),/>Paused<\/span>/);
 assert.equal(t.snapshot.messagesSync.enabled,false);
});

test('late scan completion after pause is ignored without losing earlier coverage', async () => {
 let resolve;
 const old = initial({enabled:true,status:'ready',since:'2026-10-28T19:00:00Z',lastSuccessAt:'2026-10-28T20:00:00Z'});
 const t = setup(old,async (action,payload,api) => action === 'messagesSync.scan' ? new Promise(r => {resolve=r;}) : api.defaultNative(action,payload));
 const pending = click(t,'scan');
 await click(t,'pause');
 resolve({...old,lastSuccessAt:'2026-10-28T20:01:00Z',importedReplies:4,newReplyCount:4}); await pending;
 assert.match(t.ui.renderConnection(),/>Paused<\/span>/);
 assert.equal(t.snapshot.messagesSync.lastSuccessAt,old.lastSuccessAt);
 assert.equal(t.toasts.filter(t => /new Messages/.test(t.message)).length,0);
});

test('new-reply notification appears once for a real total increase, never at startup or unchanged polls', () => {
 const old = initial({enabled:true,status:'ready',lastSuccessAt:'2026-10-28T20:00:00Z',importedReplies:7,newReplyCount:3});
 const t = setup(old);
 t.ui.acceptStatus(old);
 assert.equal(t.toasts.length,0);
 const next = {...old,lastSuccessAt:'2026-10-28T20:01:00Z',importedReplies:9,newReplyCount:2};
 t.ui.acceptStatus(next); t.ui.acceptStatus(next);
 assert.equal(t.toasts.length,1);
 assert.match(t.toasts[0].message,/2 new Messages replies added to candidate activity/);
 t.ui.acceptStatus({...next,lastSuccessAt:'2026-10-28T20:02:00Z',newReplyCount:0});
 assert.equal(t.toasts.length,1);
 const firstRead = setup(null); firstRead.ui.acceptStatus(next); assert.equal(firstRead.toasts.length,0);
});

test('intermediate pages do not consume new-reply notification totals before scan completion', () => {
 const old = initial({enabled:true,status:'ready',lastSuccessAt:'2026-10-28T20:00:00Z',importedReplies:7,newReplyCount:0});
 const t = setup(old);
 t.ui.acceptStatus({...old,status:'syncing',hasMore:true,importedReplies:9,newReplyCount:2});
 t.ui.acceptStatus({...old,status:'syncing',hasMore:true,importedReplies:10,newReplyCount:1});
 assert.equal(t.toasts.length,0);
 const completed = {...old,status:'ready',hasMore:false,lastSuccessAt:'2026-10-28T20:01:00Z',importedReplies:10,newReplyCount:0};
 t.ui.acceptStatus(completed); t.ui.acceptStatus(completed);
 assert.equal(t.toasts.length,1);
 assert.match(t.toasts[0].message,/3 new Messages replies added/);
});

test('polling is deduplicated and refreshes only the connection card, not the whole app', async () => {
 let resolve;
 const t = setup(initial({enabled:true,status:'ready'}),async () => new Promise(r => {resolve=r;}));
 const root = {innerHTML:'',contains:() => false}; t.roots.push(root);
 const pending = t.ui.poll(); await t.ui.poll();
 assert.equal(t.calls.length,1);
 resolve(initial({enabled:true,status:'ready',lastSuccessAt:'2026-10-28T20:00:00Z'})); await pending;
 assert.match(root.innerHTML,/>Up to date<\/span>/);
 assert.equal(t.renders,0,'status refresh must not replace a user draft on another route');
 assert.equal(await t.ui.handle('unrelated-action',{}),false);
});

test('configuration failure never presents enabled state or a successful-save toast', async () => {
 const t = setup(initial(),async () => { throw Error('Access setup failed'); });
 await click(t,'review-enable'); await click(t,'enable');
 assert.equal(t.snapshot.messagesSync.enabled,false);
 assert.match(t.ui.renderConnection(),/Access setup failed/);
 assert.match(buttonMarkup(t.ui.renderConnection(),'enable'),/Enable local reply sync/);
 assert.equal(t.toasts.length,0);
});
