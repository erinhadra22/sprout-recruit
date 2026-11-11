'use strict';
const CSVImportUI = (()=>{
 let inspection=null,preview=null,mappings=null,busy=false;
 // The native worker reports phases, not invented completion percentages.
 async function working(label,operation){
  if(busy)throw Error('A CSV operation is already running. Please wait for it to finish.');
  busy=true;
  const host=document.querySelector('.modal');
  const controls=[...document.querySelectorAll('.modal button,.modal input,.modal select,.modal textarea,[data-action="csv-import-pick"]')];
  const disabled=controls.map(control=>control.disabled);
  const priorBusy=host?.getAttribute('aria-busy');
  host?.setAttribute('aria-busy','true');
  controls.forEach(control=>{control.disabled=true;});
  const status=document.createElement('p');
  status.className='hint';status.setAttribute('role','status');status.setAttribute('aria-live','polite');status.setAttribute('tabindex','-1');
  status.textContent=label+' Please keep Sprout open until this finishes.';
  if(!host)status.setAttribute('style','position:fixed;bottom:24px;left:50%;transform:translateX(-50%);z-index:1000;background:white;border:1px solid #b9c8ba;border-radius:10px;padding:14px 20px;box-shadow:0 5px 24px #0002;max-width:80vw;');
  (host?.querySelector('.modal-body')||document.getElementById('content')||document.body).appendChild(status);
  try {
   // Yield so the status is painted before the asynchronous native request.
   await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
   return await operation();
  } finally {
   busy=false;status.remove();
   if(priorBusy==null)host?.removeAttribute('aria-busy');else host?.setAttribute('aria-busy',priorBusy);
   controls.forEach((control,index)=>{if(control.isConnected)control.disabled=disabled[index];});
  }
 }
 const privateFields=new Set(["Agent's Home Address","Most Recent Mutual Connection Address","Note 1","Note 2","Note 3"]);
 const privateCore=new Set(['recentMutualAddress','note1','note2','note3']);
 const numericCore=new Set(['years','officeYears','volume','change','units','buySideVolume','listSideVolume','buySideUnits','listSideUnits','active','pending','rentals','avgRentalPrice','avgSalesPrice','approxGCI','closedTransactions','closeRatio','dom','ytdVolume','ytdUnits','ytdAvgSalesPrice','mutualConnections','recentMutualClosePrice']);
 const dateCore=new Set(['recentMutualCloseDate','sourceLastViewedDate']);
 const appFieldLabels={name:'Name',firstName:'First name',lastName:'Last name',office:'Office',city:'Most transacted city',email:'Email',phone:'Phone',linkedinUrl:'LinkedIn profile URL',courtedProfileURL:'Courted profile URL',mls:'MLS affiliation',mlsId:'MLS ID',license:'License number',licenseRaw:'License number (as published)',licenseJurisdiction:'License jurisdiction',licenseType:'License type',licenseJurisdictionRaw:'License jurisdiction (as published)',licenseTypeRaw:'License type (as published)',sourceAliases:'Source identifiers',brand:'Brand',officeCity:'Office city',officeZip:'Office ZIP',mlsHomeCity:'Agent MLS home city',mlsHomeZip:'Agent MLS home ZIP',years:'Time in industry',officeYears:'Time at office',volume:'LTM sales volume',change:'LTM sales volume growth',buySideVolume:'Buy-side sales volume',listSideVolume:'List-side sales volume',buySideUnits:'Buy-side units',listSideUnits:'List-side units',active:'Active listings',pending:'Pending sales',rentals:'Closed rentals',avgRentalPrice:'Average rental price',avgSalesPrice:'Average sales price',approxGCI:'Approximate GCI',closedTransactions:'Closed transactions',closeRatio:'LTM closed/list price ratio',dom:'LTM average days on market',move:'Potential to move',growth:'Potential to grow',ytdVolume:'YTD sales volume',ytdUnits:'YTD units',ytdAvgSalesPrice:'YTD average sales price',mutualConnections:'Mutual connections',recentMutualCloseDate:'Most recent mutual close date',recentMutualAgentName:'Most recent mutual agent',recentMutualAddress:'Most recent mutual address',recentMutualClosePrice:'Most recent mutual close price',sourceStatus:'Courted status (source)',sourceAssignee:'Courted assigned to (source)',sourceLastViewedDate:'Courted last viewed date (source)',note1:'Courted note 1 (source)',note2:'Courted note 2 (source)',note3:'Courted note 3 (source)'};
 function tableFields(customFields=[]){
  const fields=Object.fromEntries(Object.entries(appFieldLabels).filter(([key])=>key!=='name').map(([key,label])=>[key,privateCore.has(key)?label+' (private)':label]));
  for(const field of customFields)fields['custom:'+field.id]=field.label+(field.private===true?' (private)':'');
  return fields;
 }
 function profile(agent){
  const fields=agent.courtedFields||{};
  const rows=items=>items.map(([label,value])=>`<div class="detail-pair"><label>${E(label)}</label><span style="overflow-wrap:anywhere">${E(value==null||value===''?'—':value)}</span></div>`).join('');
  const entries=Object.entries(fields);
  const custom=Object.entries(agent.customValues||{}).map(([id,value])=>{const field=D.customFields?.find(f=>f.id===id);return {label:field?.label||id,value,private:field?.private===true||privateFields.has(field?.label)};});
  const core=agent.importedCoreValues||{};
  const mapped=Object.keys(core).sort((a,b)=>Object.keys(appFieldLabels).indexOf(a)-Object.keys(appFieldLabels).indexOf(b)).filter(key=>!privateCore.has(key)).map(key=>[appFieldLabels[key]||key,agent[key]]);
  const privateMapped=Object.keys(core).filter(key=>privateCore.has(key)).map(key=>[appFieldLabels[key]||key,agent[key]]);
  const visibleCustom=custom.filter(f=>!f.private).map(f=>[f.label,f.value]);
  const hiddenCustom=custom.filter(f=>f.private).map(f=>[f.label,f.value]);
  const populatedCore=Object.keys(core).filter(key=>agent[key]!=null&&agent[key]!=='').length;
  return `<div class="card"><h2>Imported source data</h2><p class="sub" style="margin:10px 0 20px">${entries.length} CSV columns were retained for this contact. ${populatedCore} app fields and ${custom.length} custom fields have values; empty CSV cells remain blank. Source production cutoffs and status change dates may be unavailable. Import does not create interactions or verified interest.</p><h3>Mapped app fields</h3><div class="details">${rows(mapped)}</div><h3 style="margin-top:22px">Mapped custom fields</h3><div class="details">${rows(visibleCustom)||'<p class="sub">No populated custom fields.</p>'}</div><details style="margin-top:22px"><summary>Original CSV columns (${entries.length})</summary><div class="details">${rows(entries.filter(([key])=>!privateFields.has(key)))}</div></details><details style="margin-top:22px"><summary>Private address and source notes</summary><p class="hint">These values stay local and do not drive identity matching or recommendations.</p><div class="details">${rows(privateMapped)}${rows(hiddenCustom)}${rows(entries.filter(([key])=>privateFields.has(key)))}</div></details></div>`;
 }
 function renderProfile(agent){
  const i=S.reviewIds.indexOf(agent.id),lists=D.watchlists.filter(w=>w.agentIds.includes(agent.id));
  return `<div class="profile-nav"><div class="row"><button class="text-button" data-action="profile-close">← Back to ${E(S.returnPage==='contacts'?'CRM contacts':S.returnPage)}</button><span style="color:#d4dcd5">|</span><strong>${E(agent.name)}</strong></div><span class="sub">Imported contact</span><div class="row">${ib('Previous agent','profile-prev','left',i<=0?'disabled':'')}<span class="sub">${Math.max(1,i+1)} of ${Math.max(1,S.reviewIds.length)}</span>${ib('Next agent','profile-next','right',i<0||i>=S.reviewIds.length-1?'disabled':'')}${ib('Close profile','profile-close','close')}</div></div><div class="profile-layout"><aside class="card profile-sidebar"><div class="sidebar-block"><div class="row" style="justify-content:flex-end">${ib('Like agent','like','like',`data-id="${agent.id}"`,agent.liked?'active':'')}${ib('Add to watchlist','add-watchlist','folder',`data-id="${agent.id}"`)}${ib('Edit contact','edit-contact','note',`data-id="${agent.id}"`)}</div><div class="profile-title">${avatar(agent,'large')}<div style="min-width:0"><h2>${E(agent.name)}</h2><p class="agent-office">${E(agent.office||'Office not supplied')}</p><p class="hint">${E(agent.source||'CSV import')}</p></div></div><div class="profile-actions">${[['Interaction','interaction','message'],['Task','task-create','task'],['Note','note','note'],['Draft text','draft','spark']].map(([label,action,ic])=>`<button class="profile-action" data-action="${action}" data-id="${agent.id}"><span class="action-tile">${icon(ic,19)}</span>${label}</button>`).join('')}</div></div><div class="sidebar-block"><h3>Prospect management</h3><div class="details"><div class="detail-pair"><label>CRM status</label><select aria-label="Prospect status" data-agent-field="status" data-id="${agent.id}">${selectOptions(D.stages,agent.status,'No status')}</select></div><div class="detail-pair"><label>Source status</label><span>${E(agent.sourceStatus||'Not supplied')}</span></div><div class="detail-pair"><label>Potential to move</label><select aria-label="Potential to move" data-agent-field="move" data-id="${agent.id}">${selectOptions(['High','Moderate','Low','Unknown'],agent.move,'No assessment')}</select></div></div></div><div class="sidebar-block"><h3>Contact info</h3><div class="details">${contactInfoLine('Phone','phone',agent.phone)}${contactInfoLine('Email','mail',agent.email)}${contactInfoLine('City','location',agent.city)}${linkedinContactInfo(agent)}${contactInfoLine('Added to Sprout','clock',dateTime(agent.createdAt||agent.importedAt))}${contactInfoLine('Last imported','clock',dateTime(agent.lastImportedAt||agent.importedAt))}${typeof candidateProvenanceInfo==='function'?candidateProvenanceInfo(agent):''}</div>${emailCompanyReviewInfo(agent)}<p class="hint">Imported contact details should be reviewed before outreach. No message or call was sent by this import.</p>${CommunicationsUI.profileActions(agent)}</div><div class="sidebar-block"><h3>Agent identity</h3><div class="details">${[['MLS affiliation',agent.mls],['MLS ID',agent.mlsId],['License number',agent.licenseRaw||agent.license],['License jurisdiction (published)',agent.licenseJurisdictionRaw||agent.licenseJurisdiction],['License type (published)',agent.licenseTypeRaw||agent.licenseType],['Canonical license jurisdiction/type',[agent.licenseJurisdiction,agent.licenseType].filter(Boolean).join(' · ')],['Brand',agent.brand]].map(([label,value])=>`<div class="detail-pair"><label>${label}</label><span>${E(value||'—')}</span></div>`).join('')}</div></div><div class="sidebar-block"><h3>Watchlists</h3><div class="row" style="flex-wrap:wrap;margin-top:13px">${lists.map(w=>`<span class="chip">${E(w.name)}</span>`).join('')||'<span class="sub">Not on a watchlist yet</span>'}</div></div></aside><section class="profile-main">${pageTabs(['Source data','Five-year performance','Professional evidence','Activity log'],S.profileTab,'profile-tab')}${S.profileTab==='Professional evidence'&&typeof ProspectingUI!=='undefined'?ProspectingUI.recruitingEvidenceSection(agent,D)+ProspectingUI.professionalSection(agent,D):S.profileTab==='Activity log'?renderTimeline(agent.id):S.profileTab==='Five-year performance'?PerformanceUI.renderProfile(agent,D):profile(agent)}</section></div>`;
 }
 function decorate(){
  const tag=document.querySelector('.sample-tag');
  if(tag)tag.textContent=D.agents.some(a=>a.datasetId==='live')?'MY CONTACTS':'EMPTY WORKSPACE';
  if(S.profile)return;
  if(S.page==='settings'&&S.settingsTab==='Local data'){
   document.querySelector('.settings-grid>div')?.insertAdjacentHTML('beforeend',`<div class="card"><h2>Import contacts</h2><p class="sub" style="margin:10px 0 16px">Choose CSV exports, review field mappings and identity matches, then add them to your local CRM. ${D.agents.filter(a=>a.datasetId==='live').length} live contacts are currently saved.</p>${btn('Choose CSV files','csv-import-pick','download')}</div>`);
  }
 }
 // Explicit saved Call tasks are the daily list. This view does not source,
 // score, schedule, complete, or send anything, and never rolls yesterday forward.
 function teamCallDay(now=new Date()){
  const parts=new Intl.DateTimeFormat('en-US',{timeZone:'America/Chicago',year:'numeric',month:'2-digit',day:'2-digit'}).formatToParts(now);
  const values=Object.fromEntries(parts.map(part=>[part.type,part.value]));
  return `${values.year}-${values.month}-${values.day}`;
 }
 function teamCallPlan(snapshot,now=new Date()){
  const day=teamCallDay(now),normal=value=>String(value||'').trim().toLowerCase();
  const ids=new Set((snapshot.watchlists||[]).filter(list=>normal(list.name)==='team acquisition').flatMap(list=>list.agentIds||[]));
  const tasks=snapshot.tasks||[],rows=[],byContact=new Map();
  for(const task of tasks){
   if(task.completed||task.type!=='Call'||!ids.has(task.agentId)||!/^team acquisition call\s*[—–:-]\s*\S/i.test(task.title||'')||!/^\d{4}-\d{2}-\d{2}$/.test(task.dueDate||'')||Number.isNaN(Date.parse(task.dueDate+'T12:00:00Z'))||new Date(task.dueDate+'T12:00:00Z').toISOString().slice(0,10)!==task.dueDate)continue;
   const agent=(snapshot.agents||[]).find(contact=>contact.id===task.agentId&&contact.datasetId==='live');
   if(!agent)continue;
   const key=agent.id+'|'+task.dueDate;
   let row=byContact.get(key);
   if(!row){
    const own=tasks.filter(value=>value.agentId===agent.id&&!value.completed),holds=[];
    const status=normal(agent.status);
    if(agent.doNotContact||['do not contact','not interested','not qualified','recruited','lost'].includes(status))holds.push('Current contact status requires review before outreach.');
    if(['skipped','snoozed'].includes(normal(agent.disposition)))holds.push('This contact is skipped or snoozed.');
    const phoneKey=value=>{const digits=String(value||'').replace(/\D/g,'');return digits.length===10?'1'+digits:digits;};
    const sharedPhoneReview=tasks.some(value=>!value.completed&&value.reviewKind==='messages-sync-ambiguous-phone'&&(value.candidateIDs||[]).includes(agent.id));
    const pendingPhoneHold=(snapshot.settings||[]).some(value=>value.reasonCode==='ambiguous_reply_identity'&&value.state==='pending'&&(value.pendingReplies||[]).length&&phoneKey(value.phone)&&phoneKey(value.phone)===phoneKey(agent.phone));
    if(['conflict','held','needs_review'].includes(normal(agent.identityReviewState))||own.some(value=>value.identityHoldId||normal(value.pauseReason).includes('identity'))||sharedPhoneReview||pendingPhoneHold)holds.push('Identity review is still open.');
    if(own.some(value=>normal(value.followUpState).includes('paused'))||(snapshot.sequences||[]).some(value=>value.agentId===agent.id&&(normal(value.state)==='paused'||normal(value.pendingOutputState).includes('paused')||normal(value.pauseReason)==='inbound_reply'||normal(value.pauseReason).includes('identity'))))holds.push('Follow-ups are paused. Review the latest reply or meeting response.');
    row={agent,dueDate:task.dueDate,tasks:[],teams:[],holds};byContact.set(key,row);rows.push(row);
   }
   row.tasks.push(task);
   const team=task.title.replace(/^team acquisition call\s*[—–:-]\s*/i,'').trim();
   if(!row.teams.includes(team))row.teams.push(team);
  }
  const priorities={High:0,Medium:1,Low:2,None:3};
  const order=(a,b)=>Math.min(...a.tasks.map(task=>priorities[task.priority]??3))-Math.min(...b.tasks.map(task=>priorities[task.priority]??3))||String(a.tasks[0].createdAt||'').localeCompare(String(b.tasks[0].createdAt||''))||String(a.tasks[0].id).localeCompare(String(b.tasks[0].id));
  return {date:day,today:rows.filter(row=>row.dueDate===day&&!row.holds.length).sort(order),held:rows.filter(row=>row.dueDate===day&&row.holds.length).sort(order),overdue:rows.filter(row=>row.dueDate<day).sort((a,b)=>a.dueDate.localeCompare(b.dueDate)||order(a,b))};
 }
 function teamCallsSection(snapshot=D,now=new Date()){
  const plan=teamCallPlan(snapshot,now);
  const cards=rows=>`<div class="team-call-grid">${rows.map(row=>{
   const task=row.tasks[0],description=String(task.description||'').trim(),preview=description.length>240?description.slice(0,240)+'…':description;
   return `<article class="card team-call-card"><div class="between"><h3>${E(row.teams.join(' / '))}</h3><span class="badge">${row.holds.length?'Needs review':'Planned call'}</span></div><p class="team-call-contact"><strong>${E(row.agent.name)}</strong>${row.agent.phone?' · '+E(row.agent.phone):' · Phone not recorded'}</p><p class="hint">Due ${E(row.dueDate)}</p>${preview?`<p class="team-call-objective">${E(preview)}</p>`:''}${row.holds.map(reason=>`<p class="contact-review-alert">${E(reason)}</p>`).join('')}<div class="row team-call-actions">${btn('Open contact','profile','',`data-id="${E(row.agent.id)}"`,'small')}${row.tasks.map(value=>btn('Open call task','task-detail','',`data-id="${E(value.id)}"`,'small')).join('')}</div></article>`;
  }).join('')}</div>`;
  return `<section class="team-call-section" aria-labelledby="team-calls-heading"><div class="between section-head"><div><h2 id="team-calls-heading">Today’s Texas team calls</h2><p class="sub">${E(plan.date)} · Central Time · ${plan.today.length} planned ${plan.today.length===1?'call':'calls'}${plan.held.length?' · '+plan.held.length+' held for review':''}</p></div>${btn('View tasks','navigate','task','data-page="tasks"','small')}</div>${plan.today.length?cards(plan.today):'<div class="card"><p class="sub">No team calls are planned for today yet. Saved team-acquisition Call tasks due today appear here.</p></div>'}${plan.held.length?`<details class="team-call-review"><summary>Held for review (${plan.held.length})</summary>${cards(plan.held)}</details>`:''}${plan.overdue.length?`<details class="team-call-review"><summary>Overdue team calls (${plan.overdue.length})</summary><p class="hint">Original due dates are preserved. These have not been moved into today’s plan.</p>${cards(plan.overdue)}</details>`:''}<p class="hint">This list reflects saved tasks, not a new sourcing score. Open the call task for the full objective and evidence. No call or message is sent from this page.</p></section>`;
 }

 // One dated Review task carries the reviewed prospect run. It is deliberately
 // separate from Call tasks, imports, scoring and outreach. See the producer contract.
 const dailyProspectMarker='SPROUT_DAILY_DASHBOARD_V1\n';
 function dailyProspectPlan(snapshot,now=new Date()){
  const date=teamCallDay(now),validDay=v=>/^\d{4}-\d{2}-\d{2}$/.test(v||'')&&!Number.isNaN(Date.parse(v+'T12:00:00Z'))&&new Date(v+'T12:00:00Z').toISOString().slice(0,10)===v;
  const normalize=v=>String(v||'').normalize('NFKD').replace(/[\u0300-\u036f]/g,'').toLowerCase().replace(/[^\p{L}\p{N}]+/gu,' ').trim();
  const safeURL=v=>{try{const u=new URL(String(v));return u.protocol==='https:'&&!u.username&&!u.password?u.href:null;}catch{return null;}};
  const weekday=new Date(date+'T12:00:00Z').getUTCDay(),runs=[],errors=[];
  for(const task of snapshot.tasks||[]){
   if(task.type!=='Review'||task.reviewKind!=='daily-prospect-dashboard')continue;
   const description=String(task.description||''),start=description.indexOf(dailyProspectMarker);
   if(start<0){if(task.dueDate===date)errors.push('The saved dashboard has no readable prospect data.');continue;}
   try{
    const run=JSON.parse(description.slice(start+dailyProspectMarker.length));
    if(run.schemaVersion!==1||run.timeZone!=='America/Chicago'||!validDay(run.date)||run.date!==task.dueDate||!run.runId||!Array.isArray(run.rows)||run.rows.length>30||!run.generatedAt||!Number.isFinite(Date.parse(run.generatedAt))||teamCallDay(new Date(run.generatedAt))!==run.date)throw Error('invalid');
    runs.push({task,run});
   }catch{if(task.dueDate===date)errors.push('The saved dashboard data needs repair; no prospect count is claimed.');}
  }
  runs.sort((a,b)=>b.run.date.localeCompare(a.run.date)||b.run.generatedAt.localeCompare(a.run.generatedAt)||String(a.task.id).localeCompare(String(b.task.id)));
  const selected=runs.find(value=>value.run.date===date),last=runs.find(value=>value.run.date<date),result={date,weekend:weekday===0||weekday===6,rows:[],held:[],errors,lastDate:last?.run.date||'',task:selected?.task||null,run:selected?.run||null};
  if(!selected)return result;
  if((snapshot.tasks||[]).filter(task=>task.type==='Review'&&task.reviewKind==='daily-prospect-dashboard'&&task.dueDate===date).length!==1){result.errors.push('More than one dashboard run is saved for today. Reconcile the duplicate runs before using this list.');return result;}
  const settings=(snapshot.settings||[]).filter(value=>value.id==='sourcing-rules');
  const rules=settings.length===0?{schemaVersion:1,revision:0,excludedBrokerages:[],excludedTeams:[]}:settings[0];
  const lists=value=>Array.isArray(value)&&value.every(name=>typeof name==='string'&&normalize(name));
  if(settings.length>1||rules.schemaVersion!==1||!Number.isInteger(rules.revision)||rules.revision<0||!lists(rules.excludedBrokerages)||!lists(rules.excludedTeams)){
   result.errors.push('Current target-audience rules are unreadable. The saved prospect list is held.');return result;
  }
  const {run}=selected,prior=run.rulesSnapshot;
  const keys=values=>values.map(normalize).sort().join('|');
  if(run.rulesRevision!==rules.revision||!prior||!lists(prior.excludedBrokerages)||!lists(prior.excludedTeams)||keys(prior.excludedBrokerages)!==keys(rules.excludedBrokerages)||keys(prior.excludedTeams)!==keys(rules.excludedTeams)){
   result.errors.push('Target-audience rules changed after this run. Recheck the prospects before publication.');return result;
  }
  const seen=new Set(),seenAgents=new Set(),seenNames=new Set(),seenLeaders=new Set();
  for(const item of run.rows){
   const row={...item},holds=[],nameKey=normalize(row.name),agent=(snapshot.agents||[]).find(value=>value.id===row.agentId&&value.datasetId==='live');
   if(!row.id||!['team','agent'].includes(row.kind)||!nameKey||!['qualified','needs_evidence'].includes(row.state)||typeof row.summary!=='string'||!row.summary.trim())holds.push('The prospect identity or review summary is incomplete.');
   const entityName=normalize(row.kind==='team'?(row.teamName||row.name):row.name),leaderKey=normalize(row.kind==='team'?(row.leaderName||(normalize(row.name)!==normalize(row.teamName)?row.name:'')):row.name);
   if(seen.has(row.id)||row.agentId&&seenAgents.has(row.agentId)||seenNames.has(row.kind+'|'+entityName)||leaderKey&&seenLeaders.has(leaderKey))holds.push('Duplicate identity in this run.');
   seen.add(row.id);if(row.agentId)seenAgents.add(row.agentId);seenNames.add(row.kind+'|'+entityName);if(leaderKey)seenLeaders.add(leaderKey);
   if(row.agentId&&!agent)holds.push('The linked saved contact is unavailable.');
   if(agent&&(!leaderKey||normalize(agent.name)!==leaderKey))holds.push('The linked contact does not match the sourced prospect identity.');
   const identityMatches=(snapshot.agents||[]).filter(value=>value.datasetId==='live'&&leaderKey&&normalize(value.name)===leaderKey);
   if(identityMatches.length>1||identityMatches.length===1&&identityMatches[0].id!==row.agentId)holds.push('Resolve the existing contact identity before using this prospect.');
   const urls=Array.isArray(row.sourceUrls)?row.sourceUrls.map(safeURL).filter(Boolean):[];
   row.sourceUrls=urls;
   if(!urls.length)holds.push('Candidate-level professional source evidence is missing.');
   if(!validDay(row.checkedAt)||row.checkedAt>date||(Date.parse(date)-Date.parse(row.checkedAt))/86400000>90)holds.push('Professional source evidence needs a current check.');
   if(!String(row.location||'').trim()||row.jurisdiction!=='TX')holds.push('Texas service location is not verified.');
   const brokerages=[row.brokerage,agent?.office,agent?.brand,agent?.brokerage].filter(value=>normalize(value));
   const currentTeamNames=agent?(snapshot.teamMemberships||[]).filter(m=>m.agentId===agent.id&&validDay(m.startDate)&&m.startDate<=date&&(!m.endDate||validDay(m.endDate)&&m.endDate>=date)).map(m=>(snapshot.teams||[]).find(t=>t.id===m.teamId)?.name).filter(Boolean):[];
   const teams=[row.currentTeamAffiliation,row.teamName,agent?.teamName,...currentTeamNames].filter(value=>normalize(value));
   if(row.affiliationVerified!==true||rules.excludedBrokerages.length&&!brokerages.length||rules.excludedTeams.length&&!teams.length)holds.push('Current brokerage and team affiliation need verification.');
   if(rules.excludedBrokerages.some(value=>brokerages.some(name=>normalize(value)===normalize(name)))||rules.excludedTeams.some(value=>teams.some(name=>normalize(value)===normalize(name))))holds.push('Excluded by the current target-audience rules.');
   if(row.state==='qualified'&&!String(row.eligibilityEvidence||'').trim())holds.push('Full-criteria qualification evidence is missing.');
   if(agent){
    const own=(snapshot.tasks||[]).filter(value=>value.agentId===agent.id&&!value.completed),status=normalize(agent.status);
    if(agent.doNotContact||['do not contact','not interested','not qualified','recruited','lost'].includes(status)||['skipped','snoozed'].includes(normalize(agent.disposition)))holds.push('Current saved status or disposition requires review.');
    const phone=value=>{const digits=String(value||'').replace(/\D/g,'');return digits.length===10?'1'+digits:digits;};
    if(['conflict','held','needs review'].includes(normalize(agent.identityReviewState))||own.some(value=>value.identityHoldId||normalize(value.pauseReason).includes('identity'))||(snapshot.tasks||[]).some(value=>!value.completed&&value.reviewKind==='messages-sync-ambiguous-phone'&&(value.candidateIDs||[]).includes(agent.id))||(snapshot.settings||[]).some(value=>value.reasonCode==='ambiguous_reply_identity'&&value.state==='pending'&&(value.pendingReplies||[]).length&&phone(value.phone)&&phone(value.phone)===phone(agent.phone)))holds.push('Identity review is still open.');
    if(own.some(value=>normalize(value.followUpState).includes('paused'))||(snapshot.sequences||[]).some(value=>value.agentId===agent.id&&(normalize(value.state)==='paused'||normalize(value.pendingOutputState).includes('paused')||normalize(value.pauseReason).includes('reply')||normalize(value.pauseReason).includes('identity'))))holds.push('Follow-ups are paused. Review the latest reply or meeting response.');
   }
   row.agent=agent;row.holds=holds;(holds.length?result.held:result.rows).push(row);
  }
  // Team-first presentation is not a new score or alteration to source order.
  result.rows.sort((a,b)=>(a.kind==='team'?0:1)-(b.kind==='team'?0:1));
  return result;
 }
 function dailyProspectsSection(snapshot=D,now=new Date()){
  const plan=dailyProspectPlan(snapshot,now),teams=plan.rows.filter(row=>row.kind==='team').length;
  const cards=rows=>`<div class="team-call-grid">${rows.map(row=>`<article class="card team-call-card"><div class="between"><h3>${E(row.kind==='team'?(row.teamName||row.name):row.name)}</h3><span class="badge">${row.holds.length?'Held':row.kind==='team'?'Team prospect':'Agent prospect'}</span></div><p class="hint">${row.kind==='team'?E(row.leaderName?'Leader: '+row.leaderName:'Research contact: '+row.name)+' · ':''}${E(row.location||'Texas location unverified')} · ${E(row.brokerage||'Brokerage unverified')}</p>${row.kind==='team'?`<p class="hint">Team size: ${E(row.teamSize||'Unknown')} · Team founded: ${E(row.teamSince||'Unknown')}</p>`:''}<p class="team-call-objective">${E(row.summary||'Review needed')}</p><p class="hint">${row.state==='qualified'?'Full criteria evidenced in this run.':'Research prospect; full recruiting criteria are not yet verified.'} ${E(row.caveat||'')} Source checked ${E(row.checkedAt||'Unknown')}.</p>${row.holds.map(reason=>`<p class="contact-review-alert">${E(reason)}</p>`).join('')}<div class="row team-call-actions">${row.agent?btn('Open contact','profile','',`data-id="${E(row.agent.id)}"`,'small'):''}${row.sourceUrls.map((url,index)=>`<a class="button small" href="${E(url)}">Source ${index+1}</a>`).join('')}</div></article>`).join('')}</div>`;
  return `<section class="team-call-section" aria-labelledby="daily-prospects-heading"><div class="between section-head"><div><h2 id="daily-prospects-heading">Today’s recruiting prospects</h2><p class="sub">${E(plan.date)} · Central Time · ${plan.rows.length} of about 30 prospects · ${teams} teams${plan.rows.length-teams?' · '+(plan.rows.length-teams)+' agents':''}</p></div>${plan.task?btn('Open daily review','task-detail','',`data-id="${E(plan.task.id)}"`,'small'):''}</div><p class="hint">Monday–Friday. Texas teams first; individual agents supplement the list. Prospects are separate from the saved calls below and do not create calls or outreach.</p>${plan.errors.map(error=>`<p class="contact-review-alert">${E(error)}</p>`).join('')}${plan.rows.length?cards(plan.rows):`<div class="card"><p class="sub">${plan.weekend?'The prospect dashboard runs on weekdays.':'Today’s reviewed prospect list is not ready yet.'}${plan.lastDate?' Last saved run: '+E(plan.lastDate)+'.':''} Previous runs are not relabeled as today.</p></div>`}${plan.run?.shortfallReason?`<p class="hint">Shortfall: ${E(plan.run.shortfallReason)}</p>`:''}${plan.held.length?`<details class="team-call-review"><summary>Prospects held for review (${plan.held.length})</summary>${cards(plan.held)}</details>`:''}<p class="hint">This is a sourced review queue, not proof of interest or permission to contact. Missing evidence stays visible. A local scheduled refresh needs this Mac and the required sources available.</p></section>`;
 }

 function dashboard(){
  const agents=D.agents.filter(a=>a.datasetId==='live'),active=agents.filter(a=>a.status&& !['Not interested','Not qualified','Do not contact','Lost'].includes(a.status));
  const due=D.tasks.filter(t=>!t.completed&&t.dueDate<=D.today&&agents.some(a=>a.id===t.agentId));
  const stages=['Identified','Called','Contacted','Connected','Meeting scheduled','Meeting held','Negotiating','Contract out','Recruited'];
  return `${pageHeader('Your recruiting CRM','Imported and locally entered contacts on this Mac.',btn('Open CRM contacts','navigate','users','data-page="contacts"','primary'))}${dailyProspectsSection()}${teamCallsSection()}<div class="insights">${insight('CRM contacts',agents.length)}${insight('With a pipeline status',active.length)}${insight('Due tasks',due.length)}${insight('Import batches',(D.importBatches||[]).length)}</div><div class="profile-section"><h2>Pipeline</h2><div class="stage-grid">${stages.map(stage=>`<button class="card stage" data-action="stage-filter" data-value="${E(stage)}" style="text-align:left"><h3>${E(stage)}</h3><div class="number">${agents.filter(a=>a.status===stage).length}</div></button>`).join('')}</div></div><div class="card" style="margin-top:20px"><h2>Imported candidates</h2><p class="sub" style="margin:10px 0">Browse saved contacts in Candidates or review Sourcing & priorities. Importing a contact does not assess recruiting fit.</p>${btn('View candidates','navigate','target','data-page="candidates"')}</div>`;
 }
 function mapForm(){
  if(!inspection)return;
  const core=inspection.coreTargets||[],existing=inspection.customFields||[];
  const options=selected=>{
   const coreOptions=core.map(x=>typeof x==='string'?['core:'+x,appFieldLabels[x]||x.replace(/([a-z])([A-Z])/g,'$1 $2').replace(/^./,c=>c.toUpperCase())]:[x.target,x.label]);
   const render=entries=>entries.map(([value,label])=>`<option value="${E(value)}" ${value===selected?'selected':''}>${E(label)}</option>`).join('');
   return `<optgroup label="App fields">${render(coreOptions)}</optgroup>${existing.length?`<optgroup label="Existing custom fields">${render(existing.map(x=>['custom:'+x.id,x.label]))}</optgroup>`:''}<optgroup label="New field">${render([['custom:new','Create a new field…']])}</optgroup>`;
  };
  const rows=inspection.columns.map(column=>{
   const prior=mappings?.find(x=>x.header===column.header),target=prior?.target||column.suggestedTarget||'custom:new';
   const selectedType=prior?.type||column.inferredType||'text';
   return `<tr data-map-row data-header="${E(column.header)}" data-inferred-type="${E(column.inferredType||'text')}"><td><strong>${E(column.header)}</strong><div class="sub">${column.filled} filled · ${E(column.inferredType||'text')}</div></td><td><select aria-label="Destination for ${E(column.header)}" data-map-target>${options(target)}</select><div class="csv-new-field" ${target==='custom:new'?'':'hidden'}><label>Field name<input data-map-label aria-label="New field name for ${E(column.header)}" value="${E(prior?.label||column.suggestedLabel||column.header)}" maxlength="120"></label><label>Data type<select data-map-type aria-label="Data type for ${E(column.header)}">${['text','number','date'].map(type=>`<option value="${type}" ${selectedType===type?'selected':''}>${type}</option>`).join('')}</select></label></div></td></tr>`;
  }).join('');
  const files=inspection.fileNames.map(name=>`<li>${E(name)}</li>`).join('');
  const body=`<p class="sub">${inspection.rows} rows in ${inspection.fileNames.length} selected files. Each CSV column maps to an existing app field or to a new field you name in Destination. Original CSV values remain in the source snapshot.</p><ul class="sub">${files}</ul><p class="hint">Review the suggested destinations, especially license jurisdiction/type, source identifiers, status, production periods and private addresses. Courted URLs are optional; preserve license leading zeros and suffixes. Creating a field does not import contacts until you confirm the next review.</p><div class="csv-map-scroll"><table class="csv-map-table"><thead><tr><th>CSV column</th><th>Destination</th></tr></thead><tbody>${rows}</tbody></table></div>`;
  modal('Map CSV fields',body,'','<button type="button" class="button primary" data-action="csv-import-review">Review import</button>','',false,true);
  document.querySelector('.modal')?.classList.add('csv-map-modal');
 }
 document.addEventListener('change',event=>{
  if(!event.target.matches('[data-map-target]'))return;
  const row=event.target.closest('[data-map-row]');
  row?.querySelector('.csv-new-field')?.toggleAttribute('hidden',event.target.value!=='custom:new');
 });
 async function pick(){
  const result=await working('Reading selected CSV files.',()=>native('csv.import.pick'));
  if(result.cancelled)return;
  inspection=result;preview=null;mappings=null;mapForm();
 }
 async function review(){
  if(busy)throw Error('A CSV operation is already running. Please wait for it to finish.');
  if(!inspection)throw Error('Choose CSV files first.');
  const existing=inspection.customFields||[];
  mappings=[...document.querySelectorAll('[data-map-row]')].map(row=>{
   const target=row.querySelector('[data-map-target]').value;
   const type=target==='custom:new'?row.querySelector('[data-map-type]').value:target.startsWith('custom:')?existing.find(f=>f.id===target.slice(7))?.type:target.startsWith('core:')?numericCore.has(target.slice(5))?'number':dateCore.has(target.slice(5))?'date':'text':row.dataset.inferredType||'text';
   return {header:row.dataset.header,target,label:target==='custom:new'?row.querySelector('[data-map-label]').value.trim():row.dataset.header,type};
  });
  if(mappings.length!==inspection.columns.length||mappings.some(m=>m.target==='custom:new'&&!m.label))throw Error('Give every new custom field a name.');
  preview=await working('Checking mappings and contact matches.',()=>native('csv.import.preview',{mappings}));
  const files=preview.fileNames.map(name=>`<li>${E(name)}</li>`).join('');
  const newFields=Array.isArray(preview.customFieldsToCreate)?preview.customFieldsToCreate.length:preview.customFieldsToCreate;
  const conflicts=(preview.conflictDetails||[]).map(x=>`<li>${E(x)}</li>`).join('');
  const emailCompanyReviews=(preview.emailCompanyReviewDetails||[]).map(x=>`<li>${E(x)}</li>`).join('');
  const body=`<p class="sub">The app re-read the files using your reviewed mapping. No contacts have been added yet.</p><div class="details" style="margin:17px 0"><div class="detail-pair"><label>Rows</label><strong>${preview.rows}</strong></div><div class="detail-pair"><label>New agents</label><strong>${preview.newAgents}</strong></div><div class="detail-pair"><label>Existing agents updated</label><strong>${preview.updateAgents}</strong></div><div class="detail-pair"><label>Identity conflicts</label><strong>${preview.hardConflicts}</strong></div><div class="detail-pair"><label>Shared email or phone values</label><strong>${preview.possibleMatches}</strong></div><div class="detail-pair"><label>Email and brokerage to review</label><strong>${preview.emailCompanyReviewCount||0}</strong></div><div class="detail-pair"><label>New custom fields</label><strong>${newFields}</strong></div></div>${conflicts?`<details><summary>Review identity conflicts</summary><ul>${conflicts}</ul></details>`:''}${emailCompanyReviews?`<details><summary>Review email and brokerage</summary><p class="hint">These are possible mismatches or unverified domains, not proof an address is invalid. Check current sources before outreach.</p><ul>${emailCompanyReviews}</ul></details>`:''}<p class="hint">A consistent SQLite backup will be made before the app commits this batch. Existing CRM notes, tasks and locally edited status stay in place. Shared email or phone values are not merged.</p><ul class="sub">${files}</ul>${preview.alreadyImported?'<p class="hint">This exact batch and mapping were already imported.</p>':''}`;
  const canImport=!preview.hardConflicts&&!preview.alreadyImported&&(preview.newAgents||preview.updateAgents);
  modal('Review import counts',body,'',`${btn('Edit mapping','csv-import-edit')}${canImport?'<button type="button" class="button primary" data-action="csv-import-commit">Import contacts</button>':''}`,'',false,true);
 }
 function edit(){if(busy)throw Error('Wait for the CSV operation to finish before editing mappings.');mapForm();}
 async function commit(){
  if(!preview||preview.hardConflicts||preview.alreadyImported)throw Error('Review the CSV mapping and counts again before importing.');
  const result=await working('Backing up and importing contacts.',async()=>{
   const saved=await native('csv.import.commit',{token:preview.token});
   // The native commit receipt is authoritative even if refreshing the view fails.
   inspection=null;preview=null;mappings=null;
   try {D=await native('snapshot');} catch(error){
    throw Error('Import saved successfully, but the view could not refresh. Reopen the workspace to see your saved contacts. '+error.message);
   }
   return saved;
  });
  closeModal();render();
  toast(`${result.newAgents} new and ${result.updateAgents} updated contacts saved on this Mac.`);
 }
 return {profile,renderProfile,decorate,dashboard,teamCallDay,teamCallPlan,teamCallsSection,dailyProspectPlan,dailyProspectsSection,pick,review,edit,commit,tableFields,isBusy:()=>busy};
})();
