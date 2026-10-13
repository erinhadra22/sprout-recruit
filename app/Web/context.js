/* User-curated local context. This module never fetches URLs or accesses ChatGPT memory. */
const ContextUI = (() => {
  const escape = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const limits = {companyFacts:12, examples:8, corrections:8, knowledgeReferences:12, phrases:50};
  const sourceOptions = [['reference','Plain reference'],['file','Local file path'],['url','Web URL (reference only)']];
  const phraseArray = value => {
    const entries=Array.isArray(value)?value:typeof value==='string'?value.split(/\r?\n|\r/):[];
    const seen=new Set(); return entries.map(v=>String(v).trim()).filter(v=>v&&!seen.has(v.toLowerCase())&&seen.add(v.toLowerCase()));
  };
  function defaultRecord() {
    return {id:'ai-context',schemaVersion:2,revision:0,voice:'Warm, conversational, direct and professional. Specific, credible and easy to answer.',textStyle:'Keep texts brief and natural. Use one clear question or next step. Avoid hype, pressure and fake familiarity.',emailStyle:'Use concise paragraphs, a clear purpose and a simple next step. Sound like a person, not a campaign.',approvedWording:[],avoidWording:[],approvedRules:'',summaryInstructions:'Capture the agent’s priorities, concerns, commitments and agreed next steps. Separate what was said from interpretation. Mark uncertainty; do not invent details.',researchInstructions:'Separate verified facts, estimates and unknowns. Explain the evidence behind each recommendation.',companyFacts:[],examples:[],corrections:[],knowledgeReferences:[],chatGPTContext:{text:'',source:'',reviewed:false},changeReason:''};
  }
  function normalizeRecord(record) {
    const s={...defaultRecord(),...(record||{})};
    s.approvedWording=phraseArray(s.approvedWording);s.avoidWording=phraseArray(s.avoidWording);
    for(const key of ['companyFacts','examples','corrections','knowledgeReferences'])s[key]=Array.isArray(s[key])?s[key]:[];
    s.chatGPTContext={text:'',source:'',reviewed:false,...(s.chatGPTContext||{})};
    return s;
  }
  function area(label,name,value,hint='',rows=3,max=6000) {
    return '<div class="field"><label for="ctx-'+name+'">'+escape(label)+'</label><textarea id="ctx-'+name+'" name="'+name+'" rows="'+rows+'" maxlength="'+max+'">'+escape(value)+'</textarea>'+(hint?'<p class="hint">'+escape(hint)+'</p>':'')+'</div>';
  }
  function input(label,name,value,type='text',max=2000) {
    return '<div class="field"><label for="ctx-'+name+'">'+escape(label)+'</label><input id="ctx-'+name+'" name="'+name+'" type="'+type+'" value="'+escape(value)+'" maxlength="'+max+'"></div>';
  }
  function select(label,name,options,value) {
    return '<div class="field"><label for="ctx-'+name+'">'+escape(label)+'</label><select id="ctx-'+name+'" name="'+name+'">'+options.map(([key,title])=>'<option value="'+key+'" '+(value===key?'selected':'')+'>'+escape(title)+'</option>').join('')+'</select></div>';
  }
  function hidden(name,value) { return '<input type="hidden" name="'+name+'" value="'+escape(value)+'">'; }
  function slot(title,body,index) { return '<details data-context-entry data-context-index="'+index+'" style="border-top:1px solid #e7ebe7;padding:12px 0" open><summary style="cursor:pointer;font-weight:600;margin-bottom:12px">'+escape(title)+'</summary>'+body+'<button class="button" type="button" data-context-action="entry-remove">Remove</button></details>'; }
  function entryList(key,rows,label) {
    return '<div data-context-entries="'+key+'">'+rows.join('')+'</div><button class="button" type="button" data-context-action="entry-add" data-context-list="'+key+'">+ Add '+label+'</button>';
  }
  function factSlot(f={},i=0) {const prefix='fact-'+i,type=f.sourceType||'reference';return slot(f.claim?'Fact '+(i+1)+': '+f.claim.slice(0,65):'New company fact',area('Company fact',prefix+'-claim',f.claim,'Support offering, compensation term, policy or another sourced claim.',2)+hidden(prefix+'-suggestionId',f.suggestionId)+select('Source type',prefix+'-sourceType',sourceOptions,type)+input('Source, URL or absolute local path',prefix+'-source',f.source)+fileControls(prefix+'-source',prefix+'-sourceType',type)+'<div class="form-grid">'+input('Effective date',prefix+'-effectiveDate',f.effectiveDate,'date')+select('Verification',prefix+'-status',[['unverified','Needs verification'],['verified','Verified by me'],['retired','Retired — do not use']],f.status||'unverified')+'</div>',i);}
  function referenceSlot(r={},i=0) {const prefix='reference-'+i,type=r.type||'reference';return slot(r.title||'New reference',input('Reference title',prefix+'-title',r.title,'text',120)+select('Reference type',prefix+'-type',sourceOptions,type)+input('Reference, URL or absolute local path',prefix+'-locator',r.locator)+fileControls(prefix+'-locator',prefix+'-type',type)+area('Your notes about this reference',prefix+'-notes',r.notes,'Do not paste secrets. A reference does not override approved guidance.',2),i);}
  function exampleSlot(x={},i=0) {const prefix='example-'+i;return slot(x.label||'New writing example',input('Example name',prefix+'-label',x.label,'text',120)+hidden(prefix+'-suggestionId',x.suggestionId)+'<div class="form-grid">'+select('Channel',prefix+'-channel',[['Message','Text message'],['Email','Email']],x.channel||'Message')+select('Use as style guidance',prefix+'-status',[['pending','For review'],['approved','Approved by me']],x.status||'pending')+'</div>'+area('Example text',prefix+'-body',x.body)+input('Where this example came from',prefix+'-source',x.source),i);}
  function correctionSlot(c={},i=0) {const prefix='correction-'+i;return slot(c.feedback?'Feedback '+(i+1)+': '+c.feedback.slice(0,65):'New feedback',area('What should improve?',prefix+'-feedback',c.feedback,'Describe the correction or a short before/after excerpt.',2)+area('Proposed writing rule',prefix+'-rule',c.rule,'Company claims still require verification.',2)+input('Source draft or observation',prefix+'-source',c.source)+'<label class="checkbox-label"><input type="checkbox" name="'+prefix+'-promoted" '+(c.promoted?'checked':'')+'>I approve this rule for future drafts</label>',i);}
  function phraseRow(name,value,index) {
    return '<div data-context-phrase-row class="row" style="gap:8px;margin:8px 0"><input aria-label="'+(name==='approvedWording'?'Preferred':'Avoided')+' phrase '+(index+1)+'" name="'+name+'" value="'+escape(value)+'" maxlength="500" style="flex:1"><button type="button" class="button" data-context-action="phrase-remove" aria-label="Remove phrase '+(index+1)+'">Remove</button></div>';
  }
  function phraseList(label,name,values) {
    return '<fieldset style="border:1px solid #e7ebe7;border-radius:10px;padding:12px"><legend>'+escape(label)+'</legend><p class="hint">One phrase per entry. Saved as a list; up to 50 phrases.</p><div data-context-phrases="'+name+'">'+values.map((v,i)=>phraseRow(name,v,i)).join('')+'</div><button class="button" type="button" data-context-action="phrase-add" data-context-list="'+name+'">+ Add phrase</button></fieldset>';
  }
  function fileControls(pathName,typeName,type) {
    return '<div data-context-file-controls data-path-name="'+pathName+'" data-type-name="'+typeName+'"><div class="row" style="gap:8px;flex-wrap:wrap"><button class="button" type="button" data-context-action="pick-file">Choose local file</button><button class="button" type="button" data-context-action="preview-file" '+(type==='file'?'':'disabled')+'>Preview / search this file</button></div>'+input('Search within this selected file (optional)',pathName+'-query','')+'<div data-context-preview role="status" aria-live="polite"></div></div>';
  }
  function render(record,suggestions=[]) {
    const s=normalizeRecord(record);
    const form='<form id="context-form">'+hidden('expectedRevision',Number(s.revision)||0)+
      '<div class="card"><h2>Your AI context</h2><p class="sub" style="margin:12px 0">Your voice, reviewed company facts and references stay on this Mac. Saving context does not train a model or send messages.</p><p class="hint">File previews read only the file you choose. Web links are saved as references and are not fetched. Drafting connections remain a separate step.</p><p class="sub">'+(s.revision?'Revision '+Number(s.revision)+' · Saved '+escape(s.updatedAt||'locally'):'No saved revision yet')+'</p></div>'+
      '<div class="card"><h2>Voice and channel style</h2>'+area('Your voice','voice',s.voice)+area('Text message style','textStyle',s.textStyle)+area('Email style','emailStyle',s.emailStyle)+'<div class="form-grid">'+phraseList('Words and phrases to use','approvedWording',s.approvedWording)+phraseList('Words and phrases to avoid','avoidWording',s.avoidWording)+'</div>'+area('Approved writing rules','approvedRules',s.approvedRules,'Rules you have reviewed. Company claims belong below.')+'</div>'+
      '<div class="card"><h2>Company knowledge</h2><p class="sub" style="margin:12px 0">Only claims you mark verified may be used as company facts. A file preview, imported excerpt or approved suggestion does not verify a claim.</p>'+
      entryList('companyFacts',s.companyFacts.map(factSlot),'company fact')+'<h3>Supporting references</h3><p class="sub">Link a local document, website or plain reference. A reference is separate from a verified claim. File contents are previewed on request, never silently indexed or uploaded.</p>'+
      entryList('knowledgeReferences',s.knowledgeReferences.map(referenceSlot),'reference')+'</div>'+
      '<div class="card"><h2>Curated ChatGPT context</h2><p class="sub" style="margin:12px 0">Paste a useful excerpt that you choose from an earlier conversation. This app has no automatic access to ChatGPT conversations or memory.</p>'+area('Selected context','chatGPT-text',s.chatGPTContext.text,'Keep only relevant guidance. Review claims separately under Company knowledge.',5,20000)+input('Conversation title, date or source reference','chatGPT-source',s.chatGPTContext.source)+'<label class="checkbox-label"><input type="checkbox" name="chatGPT-reviewed" '+(s.chatGPTContext.reviewed?'checked':'')+'>I reviewed this excerpt as background context</label></div>'+
      '<div class="card"><h2>Writing examples</h2><p class="sub" style="margin:12px 0">Approval applies to style. Claims and recipient details still need separate verification.</p>'+
      entryList('examples',s.examples.map(exampleSlot),'writing example')+'</div>'+
      '<div class="card"><h2>Saved feedback</h2><p class="sub" style="margin:12px 0">Earlier feedback is preserved here. Use the Learning inbox below for new observations and reviewed promotions.</p>'+
      entryList('corrections',s.corrections.map(correctionSlot),'feedback')+'</div>'+
      '<div class="card"><h2>Summaries and research</h2>'+area('Call summary instructions','summaryInstructions',s.summaryInstructions)+area('Research and sourcing instructions','researchInstructions',s.researchInstructions)+'</div>'+
      '<div class="card">'+input('What changed? (optional)','changeReason','','text',500)+'<p class="hint">Each changed save preserves a local revision and its provenance. Nothing pending is promoted automatically.</p><p class="form-error" id="context-error" role="alert"></p><button class="button primary" type="submit">Save AI context</button></div></form>';
    return form+renderSuggestions(suggestions,s.revision);
  }
  function renderSuggestions(suggestions,contextRevision) {
    const rows=Array.isArray(suggestions)?suggestions:[], pending=rows.filter(r=>r.status==='pending'), reviewed=rows.filter(r=>r.status!=='pending');
    const names={writingRule:'Writing rule',companyFact:'Company fact',styleExample:'Style example'};
    return '<section class="card" id="context-learning"><h2>Learning inbox</h2><p class="sub" style="margin:12px 0">Save lessons from edits or call, text and email outcomes. Each proposal stays pending until you review it. Recording an outcome here is not proof a message was sent or a call occurred.</p><p>'+pending.length+' pending · '+reviewed.length+' reviewed</p>'+
      pending.map(r=>'<details style="border-top:1px solid #e7ebe7;padding:12px 0" data-context-suggestion="'+escape(r.id)+'" data-revision="'+Number(r.revision)+'" data-context-revision="'+Number(contextRevision)+'"><summary><strong>'+escape(names[r.proposedKind]||r.proposedKind)+': '+escape(r.observation)+'</strong></summary><p class="hint">'+escape(r.originType)+' · '+escape(r.source)+(r.sourceOccurredOn?' · '+escape(r.sourceOccurredOn):'')+'</p>'+(r.beforeText?'<h3>Before</h3><pre style="white-space:pre-wrap">'+escape(r.beforeText)+'</pre>':'')+(r.afterText?'<h3>After / outcome</h3><pre style="white-space:pre-wrap">'+escape(r.afterText)+'</pre>':'')+'<h3>Proposed change</h3><pre style="white-space:pre-wrap">'+escape(r.proposal)+'</pre><p class="hint">'+(r.proposedKind==='companyFact'?'Approval adds this as an unverified company fact. Source and effective-date verification are still required.':'Approval adds this to the saved AI context for future drafts.')+'</p>'+input('Review note (optional)','review-'+r.id,'','text',1000)+'<label class="checkbox-label"><input type="checkbox" data-context-review-confirm> I reviewed this exact proposal and approve adding it</label><div class="row" style="gap:8px;margin-top:12px"><button class="button primary" type="button" data-context-action="approve-suggestion">'+(r.proposedKind==='companyFact'?'Add for fact verification':'Approve suggestion')+'</button><button class="button" type="button" data-context-action="dismiss-suggestion">Dismiss</button></div><p class="form-error" data-context-review-error role="alert"></p></details>').join('')+
      (reviewed.length?'<details style="margin:16px 0"><summary>Reviewed history ('+reviewed.length+')</summary>'+reviewed.map(r=>'<p><strong>'+escape(r.status)+'</strong> · '+escape(r.observation)+'<br><span class="hint">'+escape(r.reviewedAt||r.updatedAt)+' · '+escape(r.source)+(r.promotedContextRevision?' · Context revision '+Number(r.promotedContextRevision):'')+'</span></p>').join('')+'</details>':'')+
      '<details style="border-top:1px solid #e7ebe7;padding-top:12px"><summary><strong>Add a learning suggestion</strong></summary><form id="context-suggestion-form">'+
      select('What did this come from?','suggest-originType',[['edit-example','An edited draft or example'],['call-outcome','A call outcome'],['text-outcome','A text outcome'],['email-outcome','An email outcome'],['manual-feedback','Other feedback']],'edit-example')+
      input('Source draft, conversation or local record reference','suggest-source','')+input('Observed on (optional)','suggest-sourceOccurredOn','','date')+
      select('Guidance channel','suggest-channel',[['Message','Text message'],['Email','Email']],'Message')+area('What did you learn?','suggest-observation','','A concise, supported observation; avoid guessing why someone responded.',2)+
      area('Original draft (optional)','suggest-beforeText','', '',2)+area('Your edit or observed outcome (optional)','suggest-afterText','', '',2)+select('Propose adding','suggest-proposedKind',[['writingRule','A writing rule'],['companyFact','A company fact needing verification'],['styleExample','A style example']],'writingRule')+
      area('Exact proposed rule, fact or example','suggest-proposal','','This will stay pending after you save.',3)+'<p class="form-error" id="context-suggestion-error" role="alert"></p><button class="button primary" type="submit">Save for review</button></form></details></section>';
  }
  function formToPayload(form) {
    const data=new FormData(form), text=name=>String(data.get(name)||'').trim();
    const entries=key=>Array.from(form.querySelectorAll('[data-context-entries="'+key+'"] [data-context-entry]')).map(row=>Number(row.dataset.contextIndex));
    const payload={schemaVersion:2,expectedRevision:Number(text('expectedRevision')||0)};
    for(const key of ['voice','textStyle','emailStyle','approvedRules','summaryInstructions','researchInstructions','changeReason'])payload[key]=text(key);
    payload.approvedWording=phraseArray(data.getAll('approvedWording'));payload.avoidWording=phraseArray(data.getAll('avoidWording'));
    payload.companyFacts=entries('companyFacts').map(i=>({claim:text('fact-'+i+'-claim'),source:text('fact-'+i+'-source'),sourceType:text('fact-'+i+'-sourceType')||'reference',effectiveDate:text('fact-'+i+'-effectiveDate'),status:text('fact-'+i+'-status')||'unverified',suggestionId:text('fact-'+i+'-suggestionId')})).filter(f=>f.claim||f.source||f.effectiveDate||f.status==='verified');
    payload.examples=entries('examples').map(i=>({label:text('example-'+i+'-label'),channel:text('example-'+i+'-channel')||'Message',body:text('example-'+i+'-body'),source:text('example-'+i+'-source'),status:text('example-'+i+'-status')||'pending',suggestionId:text('example-'+i+'-suggestionId')})).filter(x=>x.label||x.body||x.source||x.status==='approved');
    payload.corrections=entries('corrections').map(i=>({feedback:text('correction-'+i+'-feedback'),rule:text('correction-'+i+'-rule'),source:text('correction-'+i+'-source'),promoted:data.has('correction-'+i+'-promoted')})).filter(c=>c.feedback||c.rule||c.source||c.promoted);
    payload.knowledgeReferences=entries('knowledgeReferences').map(i=>({title:text('reference-'+i+'-title'),type:text('reference-'+i+'-type')||'reference',locator:text('reference-'+i+'-locator'),notes:text('reference-'+i+'-notes')})).filter(r=>r.title||r.locator||r.notes);
    payload.chatGPTContext={text:text('chatGPT-text'),source:text('chatGPT-source'),reviewed:data.has('chatGPT-reviewed')};
    return payload;
  }
  function suggestionPayload(form) {
    const data=new FormData(form), p={id:form.dataset.attemptId||(form.dataset.attemptId=crypto.randomUUID()),sourceRecordId:''};
    for(const key of ['originType','source','sourceOccurredOn','channel','observation','beforeText','afterText','proposedKind','proposal'])p[key]=String(data.get('suggest-'+key)||'').trim();
    return p;
  }
  function errorText(error) {return error?.message||String(error);}
  async function action(button) {
    const name=button.dataset.contextAction,form=document.getElementById('context-form');
    if(name==='entry-add') {
      const key=button.dataset.contextList,list=form.querySelector('[data-context-entries="'+key+'"]');
      if(!list||list.children.length>=limits[key])throw Error('Use up to '+limits[key]+' entries in this section.');
      const index=Math.max(-1,...Array.from(list.children).map(row=>Number(row.dataset.contextIndex)))+1;
      const create={companyFacts:factSlot,knowledgeReferences:referenceSlot,examples:exampleSlot,corrections:correctionSlot}[key];
      if(!create)throw Error('Unknown AI context section.');
      list.insertAdjacentHTML('beforeend',create({},index));list.lastElementChild.querySelector('input:not([type=hidden]),textarea')?.focus();form.dataset.dirty='true';return;
    }
    if(name==='entry-remove'){button.closest('[data-context-entry]').remove();form.dataset.dirty='true';return;}
    if(name==='phrase-add') {
      const list=form.querySelector('[data-context-phrases="'+button.dataset.contextList+'"]'),count=list.querySelectorAll('input').length;
      if(count>=limits.phrases)throw Error('Use up to 50 phrases in each list.');
      list.insertAdjacentHTML('beforeend',phraseRow(button.dataset.contextList,'',count));list.lastElementChild.querySelector('input').focus();form.dataset.dirty='true';return;
    }
    if(name==='phrase-remove'){button.closest('[data-context-phrase-row]').remove();form.dataset.dirty='true';return;}
    if(name==='pick-file'||name==='preview-file') {
      const group=button.closest('[data-context-file-controls]'),path=form.elements.namedItem(group.dataset.pathName),type=form.elements.namedItem(group.dataset.typeName),out=group.querySelector('[data-context-preview]');
      out.textContent='';button.disabled=true;
      try {
        if(name==='pick-file') {
          const selected=await native('context.knowledge.pick',{});
          if(selected?.cancelled)return;
          if(!selected?.path)throw Error('No local file was selected.');
          if(!group.isConnected)return;
          path.value=selected.path;type.value='file';group.querySelector('[data-context-action="preview-file"]').disabled=false;form.dataset.dirty='true';out.textContent='File selected. Preview reads only this document; saving keeps its path.';return;
        }
        if(type.value!=='file')throw Error('Select Local file path to preview a document.');
        const requestedPath=path.value.trim(),query=form.elements.namedItem(group.dataset.pathName+'-query').value.trim();
        out.textContent='Reading this selected file locally…';
        const result=await native('context.knowledge.preview',{path:requestedPath,query,readConfirmed:true});
        if(!group.isConnected)return;
        if(path.value.trim()!==requestedPath||type.value!=='file'){out.textContent='The reference changed. Preview again to read the new selection.';return;}
        const notice=result.extractionTruncated?'Only the first '+Number(result.charactersExamined)+' characters / '+Number(result.pagesRead||0)+' PDF pages were examined.':'Examined '+Number(result.charactersExamined)+' characters.';
        out.innerHTML='<p class="hint">'+escape(result.resolvedPath||result.path)+' · '+Number(result.byteCount)+' bytes · '+escape(result.modifiedAt)+'. '+escape(notice)+' No content saved or uploaded. Claims remain unverified.</p>'+
          (query?'<h3>Matches in examined text</h3>'+((result.matches||[]).length?(result.matches||[]).map(m=>'<p><strong>Line '+Number(m.line)+':</strong> '+escape(m.text)+'</p>').join(''):'<p>No matches in the examined text.</p>')+(result.matchLimitReached?'<p class="hint">Showing the first 50 matches.</p>':''):'<pre style="white-space:pre-wrap;max-height:320px;overflow:auto">'+escape(result.preview)+'</pre>'+(result.previewTruncated?'<p class="hint">Preview shortened to 8,000 characters; search examines the bounded extracted text.</p>':''));
      } catch(error){out.textContent=errorText(error);} finally {if(button.isConnected)button.disabled=name==='preview-file'&&type.value!=='file';}
      return;
    }
    if(name==='approve-suggestion'||name==='dismiss-suggestion') {
      const section=button.closest('[data-context-suggestion]'),out=section.querySelector('[data-context-review-error]');out.textContent='';
      if(form?.dataset.dirty==='true'){out.textContent='Save your AI context edits before reviewing suggestions so those edits are preserved.';return;}
      const approve=name==='approve-suggestion';
      if(approve&&!section.querySelector('[data-context-review-confirm]').checked){out.textContent='Check that you reviewed this exact proposal before approving it.';return;}
      button.disabled=true;
      try { await mutate('context.reviewSuggestion',{id:section.dataset.contextSuggestion,expectedRevision:Number(section.dataset.revision),expectedContextRevision:Number(section.dataset.contextRevision),decision:approve?'approve':'dismiss',confirmed:true,reviewNote:section.querySelector('input[name^="review-"]').value.trim()},approve?'Learning suggestion approved':'Learning suggestion dismissed');}
      catch(error){out.textContent=errorText(error);}finally{if(button.isConnected)button.disabled=false;}
    }
  }
  if(typeof document!=='undefined'){
    document.addEventListener('click',async event=>{const button=event.target.closest('[data-context-action]');if(!button||button.disabled)return;event.preventDefault();try{await action(button);}catch(error){const out=document.getElementById('context-error');if(out)out.textContent=errorText(error);}});
    const mark=event=>{
      const form=event.target.closest('#context-form');if(form&&!event.target.name?.endsWith('-query'))form.dataset.dirty='true';
      if(form)for(const group of form.querySelectorAll('[data-context-file-controls]')){if(event.target.name===group.dataset.typeName){group.querySelector('[data-context-action="preview-file"]').disabled=event.target.value!=='file';group.querySelector('[data-context-preview]').textContent='';}}
      const suggestion=event.target.closest('#context-suggestion-form');if(suggestion)delete suggestion.dataset.attemptId;
    };
    document.addEventListener('input',mark);document.addEventListener('change',mark);
    document.addEventListener('submit',async event=>{const form=event.target;if(form.id!=='context-suggestion-form')return;event.preventDefault();const out=document.getElementById('context-suggestion-error'),button=form.querySelector('button[type="submit"]');out.textContent='';
      if(document.getElementById('context-form')?.dataset.dirty==='true'){out.textContent='Save your AI context edits before adding a suggestion so those edits are preserved.';return;}
      button.disabled=true;try{await mutate('context.suggest',suggestionPayload(form),'Learning suggestion saved for review');}catch(error){out.textContent=errorText(error);}finally{if(button.isConnected)button.disabled=false;}
    });
  }
  return Object.freeze({render,formToPayload,defaultRecord,normalizeRecord,phraseArray,suggestionPayload});
})();
if(typeof module!=='undefined')module.exports=ContextUI;
