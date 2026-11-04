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
  return `<div class="profile-nav"><div class="row"><button class="text-button" data-action="profile-close">← Back to ${E(S.returnPage==='contacts'?'CRM contacts':S.returnPage)}</button><span style="color:#d4dcd5">|</span><strong>${E(agent.name)}</strong></div><span class="sub">Imported contact</span><div class="row">${ib('Previous agent','profile-prev','left',i<=0?'disabled':'')}<span class="sub">${Math.max(1,i+1)} of ${Math.max(1,S.reviewIds.length)}</span>${ib('Next agent','profile-next','right',i<0||i>=S.reviewIds.length-1?'disabled':'')}${ib('Close profile','profile-close','close')}</div></div><div class="profile-layout"><aside class="card profile-sidebar"><div class="sidebar-block"><div class="row" style="justify-content:flex-end">${ib('Like agent','like','like',`data-id="${agent.id}"`,agent.liked?'active':'')}${ib('Add to watchlist','add-watchlist','folder',`data-id="${agent.id}"`)}${ib('Edit contact','edit-contact','note',`data-id="${agent.id}"`)}</div><div class="profile-title">${avatar(agent,'large')}<div style="min-width:0"><h2>${E(agent.name)}</h2><p class="agent-office">${E(agent.office||'Office not supplied')}</p><p class="hint">${E(agent.source||'CSV import')}</p></div></div><div class="profile-actions">${[['Interaction','interaction','message'],['Task','task-create','task'],['Note','note','note'],['Draft text','draft','spark']].map(([label,action,ic])=>`<button class="profile-action" data-action="${action}" data-id="${agent.id}"><span class="action-tile">${icon(ic,19)}</span>${label}</button>`).join('')}</div></div><div class="sidebar-block"><h3>Prospect management</h3><div class="details"><div class="detail-pair"><label>CRM status</label><select aria-label="Prospect status" data-agent-field="status" data-id="${agent.id}">${selectOptions(D.stages,agent.status,'No status')}</select></div><div class="detail-pair"><label>Source status</label><span>${E(agent.sourceStatus||'Not supplied')}</span></div><div class="detail-pair"><label>Potential to move</label><select aria-label="Potential to move" data-agent-field="move" data-id="${agent.id}">${selectOptions(['High','Moderate','Low','Unknown'],agent.move,'No assessment')}</select></div></div></div><div class="sidebar-block"><h3>Contact info</h3><div class="details">${contactInfoLine('Phone','phone',agent.phone)}${contactInfoLine('Email','mail',agent.email)}${contactInfoLine('City','location',agent.city)}${linkedinContactInfo(agent)}${contactInfoLine('Added to Sprout','clock',dateTime(agent.createdAt||agent.importedAt))}${contactInfoLine('Last imported','clock',dateTime(agent.lastImportedAt||agent.importedAt))}</div>${emailCompanyReviewInfo(agent)}<p class="hint">Imported contact details should be reviewed before outreach. No message or call was sent by this import.</p>${CommunicationsUI.profileActions(agent)}</div><div class="sidebar-block"><h3>Agent identity</h3><div class="details">${[['MLS affiliation',agent.mls],['MLS ID',agent.mlsId],['License number',agent.licenseRaw||agent.license],['License jurisdiction (published)',agent.licenseJurisdictionRaw||agent.licenseJurisdiction],['License type (published)',agent.licenseTypeRaw||agent.licenseType],['Canonical license jurisdiction/type',[agent.licenseJurisdiction,agent.licenseType].filter(Boolean).join(' · ')],['Brand',agent.brand]].map(([label,value])=>`<div class="detail-pair"><label>${label}</label><span>${E(value||'—')}</span></div>`).join('')}</div></div><div class="sidebar-block"><h3>Watchlists</h3><div class="row" style="flex-wrap:wrap;margin-top:13px">${lists.map(w=>`<span class="chip">${E(w.name)}</span>`).join('')||'<span class="sub">Not on a watchlist yet</span>'}</div></div></aside><section class="profile-main">${pageTabs(['Source data','Five-year performance','Professional evidence','Activity log'],S.profileTab,'profile-tab')}${S.profileTab==='Professional evidence'&&typeof ProspectingUI!=='undefined'?ProspectingUI.recruitingEvidenceSection(agent,D)+ProspectingUI.professionalSection(agent,D):S.profileTab==='Activity log'?renderTimeline(agent.id):S.profileTab==='Five-year performance'?PerformanceUI.renderProfile(agent,D):profile(agent)}</section></div>`;
 }
 function decorate(){
  const tag=document.querySelector('.sample-tag');
  if(tag)tag.textContent=D.agents.some(a=>a.datasetId==='live')?'MY CONTACTS':'EMPTY WORKSPACE';
  if(S.profile)return;
  if(S.page==='settings'&&S.settingsTab==='Local data'){
   document.querySelector('.settings-grid>div')?.insertAdjacentHTML('beforeend',`<div class="card"><h2>Import contacts</h2><p class="sub" style="margin:10px 0 16px">Choose CSV exports, review field mappings and identity matches, then add them to your local CRM. ${D.agents.filter(a=>a.datasetId==='live').length} live contacts are currently saved.</p>${btn('Choose CSV files','csv-import-pick','download')}</div>`);
  }
 }
 function dashboard(){
  const agents=D.agents.filter(a=>a.datasetId==='live'),active=agents.filter(a=>a.status&& !['Not interested','Not qualified','Do not contact','Lost'].includes(a.status));
  const due=D.tasks.filter(t=>!t.completed&&t.dueDate<=D.today&&agents.some(a=>a.id===t.agentId));
  const stages=['Identified','Called','Contacted','Connected','Meeting scheduled','Meeting held','Negotiating','Contract out','Recruited'];
  return `${pageHeader('Your recruiting CRM','Imported and locally entered contacts on this Mac.',btn('Open CRM contacts','navigate','users','data-page="contacts"','primary'))}<div class="insights">${insight('CRM contacts',agents.length)}${insight('With a pipeline status',active.length)}${insight('Due tasks',due.length)}${insight('Import batches',(D.importBatches||[]).length)}</div><div class="profile-section"><h2>Pipeline</h2><div class="stage-grid">${stages.map(stage=>`<button class="card stage" data-action="stage-filter" data-value="${E(stage)}" style="text-align:left"><h3>${E(stage)}</h3><div class="number">${agents.filter(a=>a.status===stage).length}</div></button>`).join('')}</div></div><div class="card" style="margin-top:20px"><h2>Imported candidates</h2><p class="sub" style="margin:10px 0">Browse saved contacts in Candidates or review Sourcing & priorities. Importing a contact does not assess recruiting fit.</p>${btn('View candidates','navigate','target','data-page="candidates"')}</div>`;
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
 return {profile,renderProfile,decorate,dashboard,pick,review,edit,commit,tableFields,isBusy:()=>busy};
})();
