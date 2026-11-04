'use strict';
// Explicit periods and attribution are never inferred from summary/LTM fields.
const PerformanceUI=(()=>{
 const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 const known=v=>typeof v==='number'&&Number.isFinite(v);
 const number=v=>known(v)?v.toLocaleString('en-US',{maximumFractionDigits:2}):'Unknown';
 const money=v=>known(v)?v.toLocaleString('en-US',{style:'currency',currency:'USD',maximumFractionDigits:0}):'Unknown';
 const numericKeys=['buyerUnits','buyerVolume','sellerUnits','sellerVolume','dualSidedUnits','dualSidedVolume'];
 let selectedReport='',importBusy=false;
 const button=(label,action,attrs='',style='')=>`<button type="button" class="button ${style}" data-action="perf-${action}" ${attrs}>${esc(label)}</button>`;
 const input=(label,name,type,value='',extra='')=>`<div class="field"><label for="perf-${esc(name)}">${esc(label)}</label><input id="perf-${esc(name)}" name="${esc(name)}" type="${esc(type)}" value="${esc(value)}" ${extra}></div>`;
 const select=(label,name,value,options,extra='')=>`<div class="field"><label for="perf-${esc(name)}">${esc(label)}</label><select id="perf-${esc(name)}" name="${esc(name)}" ${extra}>${options.map(([v,l])=>`<option value="${esc(v)}" ${v===value?'selected':''}>${esc(l)}</option>`).join('')}</select></div>`;
 function totals(r){const sideVolume=known(r.buyerVolume)&&known(r.sellerVolume)&&known(r.dualSidedVolume)?r.buyerVolume+r.sellerVolume-r.dualSidedVolume:null;return {creditedSides:known(r.buyerUnits)&&known(r.sellerUnits)?r.buyerUnits+r.sellerUnits:null,uniqueUnits:known(r.buyerUnits)&&known(r.sellerUnits)&&known(r.dualSidedUnits)?r.buyerUnits+r.sellerUnits-r.dualSidedUnits:null,uniqueVolume:sideVolume!==null?sideVolume:(r.volumeDefinition==='unique_closed_volume'&&known(r.reportedVolume)?r.reportedVolume:null)};}
 const annual=r=>(r.periodType||'annual')==='annual';
 function fiveYears(agentId,data){
  const year=Number(String(data.today).slice(0,4));if(!Number.isInteger(year))return [];
  return Array.from({length:5},(_,i)=>{const y=year-i,matches=(data.performance||[]).filter(p=>p.agentId===agentId&&p.year===y&&p.attribution==='individual'&&!p.teamId&&annual(p));return {year:y,record:matches.length===1?matches[0]:null,conflicts:matches.length>1?matches.length:0};});
 }
 function periodLabel(r,today){
  if(!r)return 'No individual calendar-year source';
  if(!annual(r))return `Last 12 months · ${r.periodStart} to ${r.periodEnd} · ${r.coverage||'unknown'} source coverage`;
  const year=Number(String(today).slice(0,4)),full=r.periodStart===`${r.year}-01-01`&&r.periodEnd===`${r.year}-12-31`;
  return `${full?'Full calendar year':r.year===year?'Year to date / partial period':'Partial calendar year'} · ${r.periodStart} to ${r.periodEnd} · ${r.coverage||'unknown'} source coverage`;
 }
 function subjectName(r,data){if(r.teamId)return (data.teams||[]).find(t=>t.id===r.teamId)?.name||`Team ${r.teamId}`;return (data.agents||[]).find(a=>a.id===r.agentId)?.name||r.agentId||'Unknown subject';}
 function sourceText(r){return `${r?.source?.label||'Not entered'}${r?` · as of ${r.asOfDate}`:''}${r?.source?.checkedAt?` · checked ${r.source.checkedAt}`:''}`;}
 function relevantSeries(agentId,data){const teamIds=new Set((data.teamMemberships||[]).filter(m=>m.agentId===agentId).map(m=>m.teamId));return (data.performance||[]).filter(r=>r.agentId===agentId||(r.teamId&&teamIds.has(r.teamId)));}
 function renderProfile(agent,data){
  const years=fiveYears(agent.id,data),shown=new Set(years.map(y=>y.record).filter(Boolean)),extra=relevantSeries(agent.id,data).filter(r=>!shown.has(r));
  const other=extra.length?`<h3>Other sourced periods and team production</h3><p class="hint">Team figures describe the team and do not qualify this contact’s individual production. Membership can change; each figure keeps its own source window.</p><div class="table-scroller"><table><thead><tr><th>Subject / attribution</th><th>Period</th><th>Unique volume</th><th>Source</th><th></th></tr></thead><tbody>${extra.map(r=>`<tr><td>${esc(subjectName(r,data))}<div class="sub">${esc(r.attribution||'unknown')}${r.teamId?' · team entity':''}</div></td><td>${esc(periodLabel(r,data.today))}</td><td>${money(totals(r).uniqueVolume)}</td><td>${esc(sourceText(r))}</td><td>${r.id?button('Edit / history','edit',`data-id="${esc(agent.id)}" data-year="${r.year}" data-record-id="${esc(r.id)}"`):'<span class="sub">Reload to edit</span>'}</td></tr>`).join('')}</tbody></table></div>`:'';
  return `<section class="card"><div class="between"><div><h2>Five-year individual production</h2><p class="sub">Buyer and seller sides by calendar year. Blank evidence stays unknown.</p></div><div class="row">${button('Add sourced period','new',`data-id="${esc(agent.id)}"`)}${button('Import production','import',`data-id="${esc(agent.id)}"`)}</div></div><div class="table-scroller"><table><thead><tr><th>Year / source window</th><th>Buyer units</th><th>Buyer volume</th><th>Seller units</th><th>Seller volume</th><th>Unique sales</th><th>Attribution / source</th><th></th></tr></thead><tbody>${years.map(({year,record:r,conflicts})=>{const t=totals(r||{});return `<tr><td><strong>${year}</strong><div class="sub">${conflicts?`${conflicts} separate periods; review below`:esc(periodLabel(r,data.today))}</div></td><td>${number(r?.buyerUnits)}</td><td>${money(r?.buyerVolume)}</td><td>${number(r?.sellerUnits)}</td><td>${money(r?.sellerVolume)}</td><td>${number(t.uniqueUnits)}<div class="sub">${money(t.uniqueVolume)}</div></td><td>${esc(r?.attribution||'Unknown')}<div class="sub">${esc(sourceText(r))}</div></td><td>${button(r?'Edit / history':'Add source','edit',`data-id="${esc(agent.id)}" data-year="${year}"${r?.id?` data-record-id="${esc(r.id)}"`:''}`)}</td></tr>`;}).join('')}</tbody></table></div><p class="hint">Unique sales require dual-sided overlap. Unique volume needs either that overlap or an explicit source-defined unique closed-sale total; buyer and seller volumes are not simply added. Team production is labeled separately. Last-12-month totals are never spread across these years.</p>${other}</section>`;
 }
 function payloadFromValues(values,agentId,year,revision,recordId=''){
  const p={agentId,year:Number(values.year||year),periodStart:values.periodStart,periodEnd:values.periodEnd,asOfDate:values.asOfDate,coverage:values.coverage,attribution:values.attribution,source:{label:values.sourceLabel,reference:values.sourceReference||'',method:'manual'},expectedRevision:Number(revision),changeReason:values.changeReason};
  if(values.periodType)p.periodType=values.periodType;
  if(values.teamId)p.teamId=values.teamId;
  if(recordId)p.recordId=recordId;
  if(values.sourceCheckedAt)p.source.checkedAt=values.sourceCheckedAt;
  if(values.sourceProviderId)p.source.providerId=values.sourceProviderId;
  if(values.sourceRecordIds){try{p.source.recordIds=JSON.parse(values.sourceRecordIds);}catch(_){throw Error('Source record IDs must be a JSON array of strings.');}if(!Array.isArray(p.source.recordIds)||p.source.recordIds.some(id=>typeof id!=='string'||!id.trim()))throw Error('Source record IDs must be a JSON array of strings.');}
  if(values.coverageNotes!==undefined)p.coverageNotes=values.coverageNotes;
  const reported=String(values.reportedVolume??'').trim();if(reported){if(!/^\d+(?:\.\d+)?$/.test(reported))throw Error('Use a nonnegative source-reported volume without commas.');if(values.volumeDefinition!=='unique_closed_volume')throw Error('Confirm the source defines this as unique closed-sale volume.');p.reportedVolume=Number(reported);p.volumeDefinition=values.volumeDefinition;}
  for(const key of numericKeys){const v=String(values[key]??'').trim();if(v&&!/^\d+(?:\.\d+)?$/.test(v))throw Error('Use a nonnegative number without commas, or leave unavailable values blank.');p[key]=v?Number(v):null;}
  return p;
 }
 function editor(agentId,year,recordId='',forceNew=false){
  const agent=D.agents.find(a=>a.id===agentId);if(!agent)throw Error('That contact is no longer available.');
  const r=recordId?(D.performance||[]).find(x=>x.id===recordId):forceNew?null:fiveYears(agentId,D).find(x=>x.year===year)?.record;
  if(recordId&&!r)throw Error('That period is no longer available. Reload before editing.');
  const current=Number(D.today.slice(0,4)),value=r||{year,periodType:'annual',periodStart:`${year}-01-01`,periodEnd:year===current?D.today:`${year}-12-31`,asOfDate:D.today,coverage:'unknown',attribution:'individual'};
  const history=(r?.revisions||[]).slice().reverse(),fixed=r?'disabled':'',readonly=r?'readonly':'';
  const identity=`${input('Year ending','year','number',value.year,`required min="1900" max="${current}" ${readonly}`)}${select('Period type','periodType',value.periodType||'annual',[['annual','Calendar year / partial year'],['ltm','Last 12 months (365 or 366 days)']],fixed)}${select('Production attribution','attribution',value.attribution,[['unknown','Unknown attribution'],['individual','Individual agent'],['team','Team production']],fixed)}${select('Team (required for new team figures)','teamId',value.teamId||'',[['','No team selected'],...(D.teams||[]).map(t=>[t.id,t.name])],fixed)}${input('Period start','periodStart','date',value.periodStart,`required ${readonly}`)}${input('Period end','periodEnd','date',value.periodEnd,`required max="${esc(D.today)}" ${readonly}`)}`;
  modal(`${agent.name} · sourced production`,`${r?'<p class="hint">This edits the selected source record only. Its subject, attribution and window stay fixed; add a separate period to change them. Prior values and source remain in history.</p>':'<p class="hint">Choose the actual source period. Team figures stay separate from individual qualification. This saves local evidence, not a provider connection.</p>'}<div class="field-row">${identity}${input('Source as of','asOfDate','date',value.asOfDate,`required max="${esc(D.today)}"`)}${select('Source coverage','coverage',value.coverage,[['unknown','Unknown coverage'],['partial','Partial source coverage'],['complete','Complete for this period']])}${input('Source name','sourceLabel','text',r?.source?.label||'','required maxlength="200"')}${input('Source reference / file','sourceReference','text',r?.source?.reference||'','maxlength="2000"')}${input('Source checked on (optional)','sourceCheckedAt','date',r?.source?.checkedAt||'',`max="${esc(D.today)}"`)}${input('Provider identifier (optional)','sourceProviderId','text',r?.source?.providerId||'','maxlength="200"')}${input('Source record IDs (JSON array)','sourceRecordIds','text',r?.source?.recordIds?JSON.stringify(r.source.recordIds):'','maxlength="10000"')}${input('Coverage notes','coverageNotes','text',r?.coverageNotes||'','maxlength="2000"')}${input('Source-reported unique volume (optional)','reportedVolume','number',known(r?.reportedVolume)?r.reportedVolume:'','min="0" step="any"')}${select('Reported total definition','volumeDefinition',r?.volumeDefinition||'',[['','No source-defined total'],['unique_closed_volume','Source confirms unique closed-sale volume']])}</div><p class="hint">Leave an unavailable value blank. Enter 0 only when the source confirms zero. Dollar values use USD. LTM must cover 365 or 366 inclusive days, ending in the selected year.</p><div class="field-row">${[['buyerUnits','Buyer units'],['buyerVolume','Buyer volume'],['sellerUnits','Seller units'],['sellerVolume','Seller volume'],['dualSidedUnits','Sales counted on both sides'],['dualSidedVolume','Volume counted on both sides']].map(([key,label])=>input(label,key,'number',known(r?.[key])?r[key]:'','min="0" step="any"')).join('')}</div>${input('Reason for this entry or edit','changeReason','text','','required maxlength="1000"')}${r?`<details><summary>Source history · ${history.length} prior revisions</summary>${history.map(h=>`<p class="sub"><strong>Revision ${esc(h.revision)}</strong> · ${esc(h.updatedAt)} · ${esc(h.source?.label)} · ${esc(h.attribution)}<br>${esc(h.periodStart)} to ${esc(h.periodEnd)} · as of ${esc(h.asOfDate)}<br>Buyer: ${number(h.buyerUnits)} / ${money(h.buyerVolume)} · Seller: ${number(h.sellerUnits)} / ${money(h.sellerVolume)}<br>${esc(h.changeReason)}</p>`).join('')||'<p class="sub">This is the first saved source.</p>'}</details>`:''}`,'perf-edit','',`data-agent-id="${esc(r?(r.agentId||''):agentId)}" data-year="${value.year}" data-revision="${r?.revision||0}" data-record-id="${esc(r?.id||'')}"`,false,true);
  if(r)document.getElementById('modal-form')._performanceRecord=r;
 }
 function validDay(day){if(typeof day!=='string'||!/^\d{4}-\d{2}-\d{2}$/.test(day))return false;const d=new Date(day+'T00:00:00Z');return !Number.isNaN(d.getTime())&&d.toISOString().slice(0,10)===day;}
 function validatePeriod(row,today){
  if(!Number.isInteger(row.year)||row.year<1900||row.year>Number(today.slice(0,4)))throw Error('Choose a valid year through the current year.');
  if(!['annual','ltm'].includes(row.periodType||'annual'))throw Error('Period type must be annual or ltm.');
  if(![row.periodStart,row.periodEnd,row.asOfDate].every(validDay)||row.periodStart>row.periodEnd||row.periodEnd>row.asOfDate||row.asOfDate>today)throw Error('Use valid source dates: period end through source as-of, no later than today.');
  if(row.periodEnd.slice(0,4)!==String(row.year))throw Error('The selected year must match the period end.');
  if(annual(row)&&row.periodStart.slice(0,4)!==String(row.year))throw Error('Annual periods must stay within the selected year.');
  if(!annual(row)){const days=(Date.parse(row.periodEnd)-Date.parse(row.periodStart))/86400000+1;if(days!==365&&days!==366)throw Error('An LTM period must cover 365 or 366 inclusive days.');}
  if(!['complete','partial','unknown'].includes(row.coverage)||!['individual','team','unknown'].includes(row.attribution))throw Error('Choose explicit source coverage and production attribution.');
  if(row.source?.checkedAt&&(!validDay(row.source.checkedAt)||row.source.checkedAt<row.asOfDate||row.source.checkedAt>today))throw Error('Source checked date must be between the as-of date and today.');
 }
 function seriesKey(r){return JSON.stringify([r.teamId?`team:${r.teamId}`:`agent:${r.agentId}`,r.attribution,r.periodType||'annual',r.periodStart,r.periodEnd]);}
 function parseImport(text,agentId,data){
  let rows;try{rows=JSON.parse(text);}catch(_){throw Error('Paste a JSON array of sourced production records.');}
  if(!Array.isArray(rows)||rows.length<1||rows.length>250)throw Error('Import between 1 and 250 source periods.');
  const seen=new Set(),ids=new Set();
  return rows.map(row=>{
   if(!row||typeof row!=='object'||Array.isArray(row))throw Error('Each imported row must be an object.');
   const allowed=new Set(['agentId','teamId','recordId','year','periodType','periodStart','periodEnd','asOfDate','coverage','coverageNotes','attribution','source','reportedVolume','volumeDefinition',...numericKeys]);
   if(Object.keys(row).some(k=>!allowed.has(k)))throw Error('An imported row contains unsupported fields. Use the displayed format.');
   if(agentId&&row.agentId&&row.agentId!==agentId)throw Error('A contact import cannot change the contact. Use the multi-agent import.');
   const aid=row.agentId||agentId||'',explicit=!!row.periodType||!!row.teamId||!!row.recordId||!agentId;
   if(row.teamId&&row.attribution!=='team')throw Error('A team ID requires team attribution.');
   const legacyTeamEdit=row.recordId&&(data.performance||[]).some(r=>r.id===row.recordId&&r.attribution==='team'&&!r.teamId);
   if(explicit&&row.attribution==='team'&&!row.teamId&&!legacyTeamEdit)throw Error('Choose a saved team for team production.');
   if(!row.teamId&&!aid)throw Error('Each individual or unknown row needs a saved agentId.');
   if(aid&&Array.isArray(data.agents)&&!data.agents.some(a=>a.id===aid))throw Error('An agentId is not in this workspace. Import the verified contact first.');
   if(row.teamId&&!(data.teams||[]).some(t=>t.id===row.teamId))throw Error('A teamId is not in this workspace. Save the team first.');
   if(!row.source||typeof row.source!=='object'||Array.isArray(row.source)||typeof row.source.label!=='string'||!row.source.label.trim())throw Error('Each row needs a source label.');
   if(Object.keys(row.source).some(k=>!['label','reference','providerId','recordIds','checkedAt'].includes(k)))throw Error('Source accepts label, reference, providerId, recordIds and checkedAt.');
   for(const key of ['reference','providerId','checkedAt'])if(row.source[key]!==undefined&&typeof row.source[key]!=='string')throw Error('Source references and dates must be text.');
   if(row.source.recordIds!==undefined&&(!Array.isArray(row.source.recordIds)||row.source.recordIds.some(x=>typeof x!=='string'||!x.trim())||new Set(row.source.recordIds).size!==row.source.recordIds.length))throw Error('Source recordIds must be distinct nonempty strings.');
   const p={...row,...(aid?{agentId:aid}:{}),source:{...row.source,method:'import'}};
   if(!agentId&&!p.periodType)p.periodType='annual';
   validatePeriod(p,data.today);
   for(const key of numericKeys)if(p[key]!==undefined&&p[key]!==null&&(!known(p[key])||p[key]<0))throw Error('Use nonnegative numbers or null for production fields.');
   for(const suffix of ['Units','Volume'])if(known(p['dualSided'+suffix])&&(!known(p['buyer'+suffix])||!known(p['seller'+suffix])||p['dualSided'+suffix]>Math.min(p['buyer'+suffix],p['seller'+suffix])))throw Error('Dual-side overlap needs both side values and cannot exceed either side.');
   for(const prefix of ['buyer','seller','dualSided'])if(known(p[prefix+'Units'])&&known(p[prefix+'Volume'])&&((p[prefix+'Units']===0)!==(p[prefix+'Volume']===0)))throw Error('Known units and volume must agree; leave unavailable values blank.');
   if(p.reportedVolume!==undefined){if(p.volumeDefinition!=='unique_closed_volume'||(p.reportedVolume!==null&&(!known(p.reportedVolume)||p.reportedVolume<0)))throw Error('Reported volume requires a nonnegative number or null and unique_closed_volume definition.');const side=known(p.buyerVolume)&&known(p.sellerVolume)&&known(p.dualSidedVolume)?p.buyerVolume+p.sellerVolume-p.dualSidedVolume:null;if(known(p.reportedVolume)&&side!==null&&Math.abs(p.reportedVolume-side)>0.01)throw Error('The source total conflicts with the side-derived unique volume.');}else if(p.volumeDefinition!==undefined)throw Error('A volume definition requires reportedVolume.');
   const key=explicit?seriesKey(p):JSON.stringify([aid,row.year]);if(seen.has(key)||(row.recordId&&ids.has(row.recordId)))throw Error('Each source period must appear once.');seen.add(key);if(row.recordId)ids.add(row.recordId);
   let prior;
   if(row.recordId){prior=(data.performance||[]).find(x=>x.id===row.recordId);if(!prior)throw Error('A recordId is no longer available. Reload before importing.');if(seriesKey(prior)!==seriesKey(p))throw Error('An edit cannot change its subject, attribution or source window. Add a new series instead.');}
   else if(!explicit){prior=(data.performance||[]).find(x=>x.agentId===aid&&x.year===row.year&&(!x.id||x.id===`${aid}:${row.year}`));}
   else {const matches=(data.performance||[]).filter(x=>seriesKey(x)===seriesKey(p));if(matches.length>1)throw Error('Multiple saved sources match this period. Resolve the conflict first.');prior=matches[0];if(prior?.id)p.recordId=prior.id;}
   return {...p,expectedRevision:prior?.revision||0,changeReason:'Imported sourced production data'};
  });
 }
 function importForm(agentId=''){
  const agent=agentId?D.agents.find(a=>a.id===agentId):null;if(agentId&&!agent)throw Error('That contact is no longer available.');
  const year=Number(D.today.slice(0,4))-1,example=JSON.stringify([{...(agentId?{}:{agentId:'EXISTING_AGENT_ID'}),periodType:'annual',year,periodStart:`${year}-01-01`,periodEnd:`${year}-12-31`,asOfDate:D.today,coverage:'unknown',attribution:'individual',source:{label:'Your authorized export',reference:'Local filename or source reference',checkedAt:D.today},buyerUnits:null,buyerVolume:null,sellerUnits:null,sellerVolume:null,dualSidedUnits:null,dualSidedVolume:null}],null,2);
  modal(`Import production${agent?` · ${agent.name}`:' · multiple agents or teams'}`,`<p class="sub">Paste explicitly sourced periods ${agent?'for this contact':'using existing agentId or teamId values'}. Review each source before saving. This does not connect an MLS feed.</p><details><summary>Supported JSON format</summary><pre>${esc(example)}</pre><p class="hint">For a team, set attribution to team and include a saved teamId. Use periodType ltm only for a complete 365/366-day window. A source-defined aggregate may use reportedVolume with volumeDefinition unique_closed_volume; never map an ambiguous volume field into this total. Optional recordId identifies an existing source to revise. Optional source providerId and recordIds preserve provider references.</p></details>${!agent?`<details><summary>Saved subject identifiers</summary><div class="table-scroller"><table><tbody>${(D.agents||[]).map(a=>`<tr><td>Agent</td><td>${esc(a.name)}</td><td><code>${esc(a.id)}</code></td></tr>`).join('')}${(D.teams||[]).map(t=>`<tr><td>Team</td><td>${esc(t.name)}</td><td><code>${esc(t.id)}</code></td></tr>`).join('')}</tbody></table></div></details>`:''}<div class="field"><label for="perf-import">Source records</label><textarea id="perf-import" name="records" rows="13" required spellcheck="false" placeholder="Paste the array here"></textarea></div><p class="hint">Use null for unavailable values. Never substitute LTM totals for calendar years. All rows validate together; one invalid row cancels the batch.</p>`,'perf-import',button('Review import','import-preview',`data-id="${esc(agentId)}"`),`data-agent-id="${esc(agentId)}"`,false,true);
 }
 function renderReport(data){const reports=[...(data.reports||[])].sort((a,b)=>String(b.generatedAt).localeCompare(String(a.generatedAt)));const report=reports.find(r=>r.id===selectedReport)||reports[0];return `<div class="page-head between"><div><h1>Recruiting activity</h1><p class="sub">A dated report of what has actually been logged in this local workspace.</p></div>${button('Create report','report-new','','primary')}</div><section class="card"><h2>Saved reports</h2><p class="hint">Each report is a frozen snapshot. Create a new one after adding or correcting activity. Export saves a local text file for you to review and share.</p>${reports.length?`<div class="comm-actions">${reports.map(r=>button((r.filters.title||'Activity report')+` · ${r.filters.fromDate}–${r.filters.toDate}`,'report-select',`data-id="${esc(r.id)}"`,r.id===report?.id?'primary':'')).join('')}</div>`:'<p class="sub">No saved reports. Choose a date window to create one.</p>'}</section>${report?reportMarkup(report):''}`;}
 function rateText(rate){if(!rate)return 'Unavailable';return `${number(rate.numerator)} / ${number(rate.denominator)}${known(rate.percent)?` (${rate.percent.toFixed(1)}%)`:' · no denominator'}`;}
 function reportMarkup(report){const f=report.filters||{},m=report.metrics||{},rates=report.rates||{},v=report.verificationCounts||{},events=report.events||[];return `<section class="card"><div class="between"><div><h2>${esc(f.title||'Recruiting activity report')}</h2><p class="sub">${esc(f.fromDate)} to ${esc(f.toDate)} · ${esc(f.timeZone)} · saved ${esc(report.generatedAt)}</p></div>${button('Export report','report-export',`data-id="${esc(report.id)}"`)}</div>${f.includeSamples?'<p class="form-error">Includes illustrative sample activity. Do not present these counts as real recruiting activity.</p>':'<p class="hint">Real contacts only · sample and test records excluded</p>'}<div class="table-scroller"><table><thead><tr><th>Calls logged</th><th>Explicitly connected</th><th>Messages logged</th><th>Emails logged</th><th>Notes added</th><th>Tasks completed</th></tr></thead><tbody><tr>${['calls','connectedCalls','messages','emails','notes','tasksCompleted'].map(k=>`<td><strong>${number(m[k])}</strong></td>`).join('')}</tr></tbody></table></div><p>Tasks due completed by the end: <strong>${rateText(rates.taskCompletion)}</strong></p><p>Contacts with a recorded interaction: <strong>${rateText(rates.contactCoverage)}</strong></p><p class="sub">Evidence: ${number(v.provider)} provider-confirmed · ${number(v.user)} confirmed by you · ${number(v.manual)} manually logged activities/tasks.</p><details><summary>Counting rules and exclusions</summary>${(report.definitions||[]).map(d=>`<p class="hint">${esc(d)}</p>`).join('')}<p class="sub">${Object.entries(report.exclusions||{}).map(([k,v])=>`${esc(k)}: ${number(v)}`).join(' · ')}</p></details><h3>Counted activity</h3>${events.length?`<div class="table-scroller"><table><thead><tr><th>Date</th><th>Contact</th><th>Activity</th><th>Evidence</th><th>Data</th></tr></thead><tbody>${events.map(e=>`<tr><td>${esc(e.date)}</td><td>${esc(e.agentName)}</td><td>${esc(e.label)}</td><td>${esc({provider:'Provider-confirmed',user:'Confirmed by you',manual:'Manual log'}[e.verification]||e.verification)}</td><td>${esc(e.dataset)}</td></tr>`).join('')}</tbody></table></div>`:'<p class="sub">No eligible activity was recorded in this window.</p>'}</section>`;}
 function reportForm(){const today=D.today,from=today.slice(0,8)+'01';modal('Create activity report',`${input('Report title','title','text','Recruiting activity','maxlength="150"')}${input('From','fromDate','date',from,`required max="${esc(today)}"`)}${input('Through','toDate','date',today,`required max="${esc(today)}"`)}<p class="sub">Time zone: ${esc(Intl.DateTimeFormat().resolvedOptions().timeZone)}</p><label class="checkbox-label"><input type="checkbox" name="includeSamples"> Include sample activity, clearly labeled</label><p class="hint">Drafts, failed or uncertain sends, test contacts, and unclassified records are excluded. This saves a local snapshot; it does not send a report.</p>`,'perf-report','',`data-report-id="${esc(crypto.randomUUID())}"`);}
 function showImportPreview(form,agentId=''){
  const rows=parseImport(form.elements.records.value,agentId,D),message=rows.map(r=>`<li><strong>${esc(subjectName(r,D))}</strong> · ${esc(r.attribution)} · ${esc(r.periodType||'annual')} · ${esc(r.source.label)}<br>${esc(r.periodStart)} to ${esc(r.periodEnd)} · as of ${esc(r.asOfDate)} · ${esc(r.coverage)} coverage · ${r.expectedRevision?'revises selected saved source':'new source'} · unique volume ${money(totals(r).uniqueVolume)}</li>`).join('');
  modal('Review production import',`<p>${rows.length} sourced period${rows.length===1?'':'s'} will be saved together.</p><ul>${message}</ul><p class="hint">Unknown values stay unknown. Team values stay separate from individual production. Source edits retain prior versions. Invalid or stale rows cancel the entire import.</p>`,'perf-import-confirm',button('Save reviewed import','import-save','','primary'));
  document.getElementById('modal-form')._performanceImport=rows;
 }
 async function saveImport(form,control){
  if(importBusy||form?._performanceSaving)return;
  const rows=form?._performanceImport;if(!rows)throw Error('Review the import again.');
  importBusy=true;form._performanceSaving=true;if(control)control.disabled=true;
  try{await mutate('performance.import',{records:rows},'Production sources imported');delete form._performanceImport;closeModal();}
  finally{importBusy=false;form._performanceSaving=false;if(control)control.disabled=false;}
 }
 async function handleAction(b){
  const action=b.dataset.action.replace('perf-',''),id=b.dataset.id||'';
  if(importBusy)return;
  switch(action){
   case 'edit':editor(id,Number(b.dataset.year),b.dataset.recordId||'');break;
   case 'new':editor(id,Number(D.today.slice(0,4)),'',true);break;
   case 'import':importForm(id);break;
   case 'import-preview':showImportPreview(b.closest('form'),id);break;
   case 'import-save':await saveImport(b.closest('form'),b);break;
   case 'report-new':reportForm();break;
   case 'report-select':selectedReport=id;render();break;
   case 'report-export':{const result=await native('report.export',{id});if(!result.cancelled)toast('Report saved locally');break;}
  }
 }
 async function handleSubmit(form){
  if(form._performanceSaving||importBusy)return;
  if(form.dataset.kind==='perf-import'){showImportPreview(form,form.dataset.agentId||'');return;}
  if(form.dataset.kind==='perf-import-confirm'){await saveImport(form,form.querySelector?.('[data-action="perf-import-save"]'));return;}
  const values=Object.fromEntries(new FormData(form).entries());
  if(form.dataset.kind==='perf-edit'){
   const r=form._performanceRecord;
   if(r){values.attribution=r.attribution;values.teamId=r.teamId||'';if(r.periodType)values.periodType=r.periodType;else delete values.periodType;}
   const p=payloadFromValues(values,form.dataset.agentId,form.dataset.year,form.dataset.revision,form.dataset.recordId||'');
   if(!r&&p.attribution==='team'&&!p.teamId)throw Error('Choose a saved team for team production.');
   if(p.teamId&&p.attribution!=='team')throw Error('Only team-attributed figures may select a team.');
   validatePeriod(p,D.today);
   form._performanceSaving=true;const control=form.querySelector?.('button[type="submit"]');if(control)control.disabled=true;
   try{await mutate('performance.save',p,'Production source saved');closeModal();}finally{form._performanceSaving=false;if(control)control.disabled=false;}
   return;
  }
  if(form.dataset.kind==='perf-report'){
   form._performanceSaving=true;try{const id=form.dataset.reportId;await mutate('report.save',{id,title:values.title,fromDate:values.fromDate,toDate:values.toDate,timeZone:Intl.DateTimeFormat().resolvedOptions().timeZone,includeSamples:values.includeSamples==='on'},'Report snapshot saved');selectedReport=id;closeModal();render();}finally{form._performanceSaving=false;}
  }
 }
 return {renderProfile,renderReport,handleAction,handleSubmit,fiveYears,totals,periodLabel,payloadFromValues,parseImport,reportMarkup,rateText,importForm,validatePeriod,seriesKey,relevantSeries};
})();
if(typeof module!=='undefined')module.exports=PerformanceUI;
