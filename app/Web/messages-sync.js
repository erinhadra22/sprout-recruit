'use strict';

// This surface reads native status. The native coordinator owns scan scheduling,
// permission checks, coverage cursors, reply imports and cancellation.
const MessagesSyncUI = (() => {
 const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const states = new Set(['disabled','ready','syncing','blocked','error']);
 const actions = new Set(['review-enable','enable','cancel','pause','scan','privacy']);
 let api = {}, status = null, reviewOpen = false, localError = '', polling = false, epoch = 0, baseline = false, pendingScan = null, lastNotifiedTotal = null;
 const busy = new Set();
 const data = () => api.getData?.() || {};
 const current = () => status || data().messagesSync || {enabled:false,status:'disabled'};
 const count = value => Number.isSafeInteger(value) && value >= 0 ? value : null;
 const quantity = value => count(value) === null ? 'Not checked' : String(value);
 const time = value => {
  if (!value) return 'Not yet';
  const parsed = new Date(value);
  return Number.isNaN(parsed.getTime()) ? String(value) : parsed.toLocaleString();
 };
 const button = (label, action, disabled = false, primary = false) => `<button type="button" class="button${primary ? ' primary' : ''}" data-action="messages-sync-${action}"${disabled ? ' disabled' : ''}>${esc(label)}</button>`;
 const accessBlocked = s => s.status === 'blocked' && /access|permission/.test(String(s.errorCode || '').toLowerCase());

 function stateLabel(s) {
  if (localError) return 'Status needs attention';
  if (!states.has(s.status)) return 'Status unavailable';
  if (!s.enabled) return s.since ? 'Paused' : 'Off';
  if (s.status === 'syncing') return 'Syncing…';
  if (s.status === 'blocked') return accessBlocked(s) ? 'Access blocked' : 'Sync needs attention';
  if (s.status === 'error') return 'Sync needs attention';
  if (s.status === 'ready') return pendingScan ? (pendingScan.lastSuccessAt ? 'Catch-up pending' : 'First scan pending') : (s.lastSuccessAt ? 'Up to date' : 'First scan pending');
  return 'Waiting for a scan';
 }

 function renderReview(s) {
  if (!reviewOpen || s.enabled) return '';
  const resume = !!s.since;
  return `<section class="messages-sync-consent" aria-labelledby="messages-sync-consent-title">
   <h3 id="messages-sync-consent-title">${resume ? 'Resume' : 'Enable'} local reply sync?</h3>
   <p><strong>Full Disk Access is a broad macOS permission.</strong> It can allow Sprout to read protected data beyond Messages. Sprout's reply reader filters Messages locally to exact, unique candidate phone matches; that app filter does not narrow the operating-system permission.</p>
   <ul>
    <li>${resume ? 'Keep the original coverage start and catch up since the last successful scan.' : 'Import only incoming replies after you enable sync. Earlier conversation history is not imported.'}</li>
    <li>Match one-to-one conversations by a unique saved candidate phone number. Group chats and email-handle chats are excluded. Replies from shared numbers stay unlinked and pause outreach for identity review.</li>
    <li>Unsupported message bodies appear as clearly labeled placeholders; Sprout does not invent their text.</li>
    <li>Process locally with no cloud upload or LLM processing. This does not send outreach or automatically change CRM status.</li>
   </ul>
   <p class="hint">Scans run about every 15 seconds while Sprout is open. You may need to enable Full Disk Access manually in Privacy Settings. This button does not grant that permission.</p>
   <div class="messages-sync-actions">${button('Keep sync off','cancel',busy.has('configure'))}${button(resume ? 'Resume local reply sync' : 'Enable local reply sync','enable',busy.has('configure'),true)}</div>
  </section>`;
 }

 function renderInner() {
  const s = current(), enabled = s.enabled === true, configuring = busy.has('configure');
  const attention = !!localError || ['blocked','error'].includes(s.status) || !states.has(s.status);
  const scanBusy = busy.has('scan') || s.status === 'syncing';
  const ambiguity = count(s.ambiguousCandidateCount);
  const nativeError = typeof s.lastError === 'string' ? s.lastError : '';
  const gap = enabled && (attention || !!pendingScan || !s.lastSuccessAt);
  return `<div class="messages-sync-heading"><div><h2>Capture Messages replies</h2><p class="sub">Local, automatic reply checks · new replies only</p></div><span class="messages-sync-state${attention ? ' needs-attention' : ''}${s.status === 'syncing' && enabled ? ' is-syncing' : ''}" role="status">${s.status === 'syncing' && enabled ? '<span class="messages-sync-spinner" aria-hidden="true"></span>' : ''}${esc(stateLabel(s))}</span></div>
   <p class="messages-sync-intro">Add incoming Messages replies to matching candidate activity while you work. Scans run about every 15 seconds while this app is open. Closing the app or sleeping the Mac pauses local checks.</p>
   <dl class="messages-sync-coverage"><div><dt>Coverage starts</dt><dd>${s.since ? esc(time(s.since)) : 'When you enable sync'}</dd></div><div><dt>Last successful scan</dt><dd>${esc(time(s.lastSuccessAt))}</dd></div>${s.lastAttemptAt ? `<div><dt>Last attempt</dt><dd>${esc(time(s.lastAttemptAt))}</dd></div>` : ''}</dl>
   ${gap ? `<p class="messages-sync-notice" role="status">${s.lastSuccessAt ? 'Reply coverage has a gap after the last successful scan. Newer replies may be missing until a scan succeeds.' : 'Reply coverage is not established yet. A successful first scan is required before replies can appear.'}</p>` : ''}
   ${!enabled && s.since ? '<p class="messages-sync-notice">Sync is paused. Resuming keeps the original coverage start and catches up since the last successful scan.</p>' : ''}
   ${nativeError ? `<p class="messages-sync-error" role="alert">${esc(nativeError)}</p>` : ''}
   ${localError ? `<p class="messages-sync-error" role="alert">${esc(localError)}</p>` : ''}
   <dl class="messages-sync-metrics"><div><dt>Candidates with a unique phone</dt><dd>${esc(quantity(s.uniqueCandidateCount))}</dd></div><div><dt>Ambiguous candidates excluded</dt><dd>${esc(quantity(s.ambiguousCandidateCount))}</dd></div><div><dt>Replies imported</dt><dd>${esc(quantity(s.importedReplies))}</dd></div><div><dt>New in last scan</dt><dd>${esc(quantity(s.newReplyCount))}</dd></div></dl>
   ${ambiguity > 0 ? '<p class="messages-sync-notice">Replies from shared numbers stay unlinked and pause outreach for identity review. Review the matching candidate phone numbers before those replies can be linked.</p>' : ''}
   <div class="messages-sync-actions">${enabled ? button(configuring ? 'Pausing…' : 'Pause sync','pause',configuring) + button(scanBusy ? 'Checking…' : 'Check access / Sync now','scan',configuring || scanBusy,!attention) : button(s.since ? 'Review & resume' : 'Review & enable','review-enable',configuring || reviewOpen,true)}${button(busy.has('privacy') ? 'Opening Privacy Settings…' : 'Open Privacy Settings','privacy',busy.has('privacy'),accessBlocked(s))}</div>
   ${renderReview(s)}
   <p class="messages-sync-boundary">Only one-to-one replies with an exact, unique candidate phone match are imported. Group conversations and email-handle chats are excluded. Replies from shared numbers stay unlinked and pause outreach for identity review. Unsupported bodies use labeled placeholders. Later edits or deletions in Messages are not mirrored. Everything stays local; no cloud upload or LLM processing, outbound messages, or automatic CRM status changes.</p>`;
 }

 function renderConnection() {
  return `<section class="card messages-sync" data-messages-sync>${renderInner()}</section>`;
 }

 function refresh(fallback = false) {
  const roots = typeof document === 'undefined' ? [] : Array.from(document.querySelectorAll?.('[data-messages-sync]') || []);
  const html = renderInner();
  for (const root of roots) {
   if (root.innerHTML === html) continue;
   const focused = document.activeElement;
   const action = root.contains?.(focused) ? focused?.dataset?.action : '';
   root.innerHTML = html;
   if (action?.startsWith('messages-sync-') && actions.has(action.slice('messages-sync-'.length))) root.querySelector?.(`[data-action="${action}"]`)?.focus?.({preventScroll:true});
  }
  // Polls must never replace a draft editor elsewhere in the app.
  if (!roots.length && fallback) api.render?.();
 }

 function extract(value) {
  if (!value || typeof value !== 'object') return null;
  const result = value.messagesSync && typeof value.messagesSync === 'object' ? value.messagesSync : value;
  return typeof result.enabled === 'boolean' && typeof result.status === 'string' ? result : null;
 }

 function acceptStatus(value) {
  const next = extract(value);
  if (!next) return false;
  const wasBaseline = baseline, nextTotal = count(next.importedReplies);
  if (value.messagesSync && typeof value.messagesSync === 'object') api.adoptSnapshot?.(value);
  status = {...next}; baseline = true; localError = '';
  if (!status.enabled || (pendingScan && status.lastSuccessAt && status.lastSuccessAt !== pendingScan.lastSuccessAt)) pendingScan = null;
  if (status.enabled) reviewOpen = false;
  if (!wasBaseline || !status.enabled) lastNotifiedTotal = nextTotal;
  else if (status.status === 'ready' && status.hasMore !== true && status.lastSuccessAt) {
   if (lastNotifiedTotal !== null && nextTotal !== null && nextTotal > lastNotifiedTotal) {
    const added = nextTotal - lastNotifiedTotal;
    api.toast?.(`${added} new Messages ${added === 1 ? 'reply added' : 'replies added'} to candidate activity.`, {kind:'success'});
   }
   // Intermediate pages may import real replies, but only a completed scan
   // consumes their notification delta. Polling cannot announce them twice.
   lastNotifiedTotal = nextTotal;
  }
  refresh();
  return true;
 }

 async function poll() {
  if (polling || busy.has('configure') || !api.native) return;
  polling = true;
  const generation = epoch;
  try {
   const result = await api.native('messagesSync.status', {});
   if (generation === epoch && !acceptStatus(result)) throw Error('Reply sync status could not be read.');
  } catch (error) {
   if (generation === epoch) { localError = `Reply sync status is unavailable. ${error.message || 'Try checking again.'}`; refresh(); }
  } finally { polling = false; }
 }

 async function configure(enabled) {
  if (busy.has('configure')) return;
  pendingScan = enabled ? {lastSuccessAt:current().lastSuccessAt || null} : null;
  busy.add('configure'); const generation = ++epoch; localError = ''; refresh(true);
  try {
   const result = await api.native('messagesSync.configure', {enabled,confirmed:true});
   if (generation !== epoch) return;
   if (!acceptStatus(result) || current().enabled !== enabled) throw Error('The saved reply sync setting could not be verified. Check its status before trying again.');
   reviewOpen = false;
   api.toast?.(enabled ? (current().status === 'blocked' ? 'Reply sync enabled; local Messages access needs attention.' : 'Reply sync enabled. Local access will be checked.') : 'Reply sync paused. Previously imported replies stay in candidate activity.');
  } catch (error) { if (generation === epoch) localError = error.message || String(error); }
  finally { busy.delete('configure'); refresh(true); }
 }

 async function handle(action, el) {
  const raw = String(action || el?.dataset?.action || '');
  if (!raw.startsWith('messages-sync-')) return false;
  const name = raw.slice('messages-sync-'.length);
  if (!actions.has(name)) return false;
  if (name === 'review-enable') {
   if (!current().enabled && !busy.has('configure')) { reviewOpen = true; localError = ''; refresh(true); }
   return true;
  }
  if (name === 'cancel') { if (!busy.has('configure')) { reviewOpen = false; refresh(true); } return true; }
  if (name === 'enable') {
   if (reviewOpen && !current().enabled) await configure(true);
   return true;
  }
  if (name === 'pause') { if (current().enabled) await configure(false); return true; }
  if (busy.has(name) || !api.native) return true;
  if (name === 'scan' && (!current().enabled || current().status === 'syncing' || busy.has('configure'))) return true;
  busy.add(name); const generation = epoch; localError = ''; refresh(true);
  try {
   if (name === 'privacy') {
    await api.native('messagesSync.openPrivacy', {});
    api.toast?.('In Privacy Settings, review Full Disk Access for Sprout. Opening settings does not grant permission.');
   } else {
    const result = await api.native('messagesSync.scan', {});
    if (generation === epoch && !acceptStatus(result)) throw Error('Scan status is unavailable. Check again to verify its outcome.');
   }
  } catch (error) { if (generation === epoch) localError = error.message || String(error); }
  finally { busy.delete(name); refresh(true); }
  return true;
 }

 function bind(options) {
  api = {...api,...options};
  const initial = extract(data());
  if (initial) { status = {...initial}; baseline = true; lastNotifiedTotal = count(initial.importedReplies); }
 }

 return Object.freeze({bind,renderConnection,acceptStatus,poll,handle});
})();
