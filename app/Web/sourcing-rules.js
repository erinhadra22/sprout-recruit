'use strict';
// Structured exclusions are enforced by the native sourcing commands, not by a prompt.
const SourcingRulesUI=(()=>{
 const esc=value=>String(value??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
 let hooks={};
 function bind(value){hooks={...hooks,...value};}
 function normalizedName(value){return String(value||'').normalize('NFKD').replace(/\p{M}/gu,'').toLowerCase().split(/[^\p{L}\p{N}]+/u).filter(Boolean).join(' ');}
 function names(value,label){
  const rows=Array.isArray(value)?value:String(value||'').split(/\r?\n|\r/),seen=new Set(),result=[];
  for(const raw of rows){const name=String(raw).trim();if(!name)continue;const key=normalizedName(name);if(!key||name.length>200||/[\r\n]/.test(name))throw Error(`Each ${label} needs a name on one line, up to 200 characters.`);if(!seen.has(key)){seen.add(key);result.push(name);}}
  if(result.length>100)throw Error(`Use up to 100 ${label}.`);return result;
 }
 function record(snapshot=hooks.getData?.()||{}){return (snapshot.settings||[]).find(r=>r.id==='sourcing-rules')||{id:'sourcing-rules',revision:0,name:'Recruiting target audience',description:'',excludedBrokerages:[],excludedTeams:[]};}
 function payload(values){
  const name=String(values.name||'').trim(),description=String(values.description||'').trim(),revision=Number(values.expectedRevision);
  if(!name||name.length>120)throw Error('Name the target audience using up to 120 characters.');
  if(description.length>6000)throw Error('Keep target-audience notes within 6,000 characters.');
  if(!Number.isSafeInteger(revision)||revision<0)throw Error('Reopen the target audience form before saving.');
  return {schemaVersion:1,expectedRevision:revision,name,description,excludedBrokerages:names(values.excludedBrokerages,'excluded brokerage entries'),excludedTeams:names(values.excludedTeams,'excluded team entries')};
 }
 function render(snapshot){const r=record(snapshot),brokerages=r.excludedBrokerages||[],teams=r.excludedTeams||[];
  return `<section class="card sourcing-rules-card" aria-labelledby="sourcing-rules-title"><div class="between"><div><h2 id="sourcing-rules-title">ICP / target audience</h2><p class="sub">Define who the sourcing agent should consider.</p></div><span class="sourcing-rules-count">${brokerages.length+teams.length} exclusions</span></div><div class="sourcing-rules-summary"><div><strong>${brokerages.length}</strong><span>Brokerage names</span></div><div><strong>${teams.length}</strong><span>Team names</span></div><div><strong>${Number(r.revision||0)}</strong><span>Saved revision</span></div></div><form id="sourcing-rules-form"><input type="hidden" name="expectedRevision" value="${Number(r.revision||0)}"><div class="field"><label for="sourcing-rules-name">Target audience name</label><input id="sourcing-rules-name" name="name" maxlength="120" required value="${esc(r.name)}"></div><div class="field"><label for="sourcing-rules-description">Target profile and research guidance</label><textarea id="sourcing-rules-description" name="description" maxlength="6000" rows="3">${esc(r.description)}</textarea><p class="hint">These notes provide research context. Use the structured lists below for enforced exclusions.</p></div><div class="sourcing-rules-columns"><div class="field"><label for="sourcing-rules-brokerages">Exclude brokerages</label><textarea id="sourcing-rules-brokerages" name="excludedBrokerages" rows="6" spellcheck="false">${esc(brokerages.join('\n'))}</textarea><p class="hint">One full brokerage name per line. Add each known name variant explicitly.</p></div><div class="field"><label for="sourcing-rules-teams">Exclude teams</label><textarea id="sourcing-rules-teams" name="excludedTeams" rows="6" spellcheck="false">${esc(teams.join('\n'))}</textarea><p class="hint">One full team name per line. Current dated membership is checked for saved contacts.</p></div></div><p class="hint">Matching ignores capitalization, accents, spacing and punctuation. Whole names must match; similar names and franchise relationships are not inferred. When a list is active, missing affiliation requires evidence before new sourcing intake. Existing contacts and tasks are retained.</p><p class="hint">Applies to this app’s sourcing previews, imports and recommendations. External sourcing workflows must read the saved rules before their run; saving here does not reconfigure an external schedule.</p><p id="sourcing-rules-error" class="form-error" role="alert"></p><button type="submit" class="button primary">Save target audience</button>${r.updatedAt?`<span class="hint sourcing-rules-saved">Saved ${esc(r.updatedAt)}</span>`:''}</form></section>`;
 }
 async function handleSubmit(form){const error=form.querySelector('#sourcing-rules-error'),button=form.querySelector('button[type="submit"]');if(error)error.textContent='';if(button)button.disabled=true;
  try{const p=payload(Object.fromEntries(new FormData(form).entries()));await hooks.mutate('sourcingRules.save',p,'Target audience saved on this Mac');return true;}
  catch(e){if(error)error.textContent=e.message;else throw e;return false;}finally{if(button?.isConnected)button.disabled=false;}
 }
 return Object.freeze({bind,record,render,payload,names,normalizedName,handleSubmit});
})();
if(typeof module!=='undefined')module.exports=SourcingRulesUI;
