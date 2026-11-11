'use strict';
const Model = {
  escape(v) { return String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); },
  money(v,compact=false) { if(v==null)return '—'; return new Intl.NumberFormat('en-US',{style:'currency',currency:'USD',maximumFractionDigits:compact?1:0,...(compact?{notation:'compact'}:{})}).format(v); },
  volumeCoverage(agents) { const known=agents.map(a=>a.volume).filter(v=>typeof v==='number'&&Number.isFinite(v)&&v>=0);return {total:known.length?known.reduce((sum,v)=>sum+v,0):null,knownCount:known.length,unknownCount:agents.length-known.length}; },
  volumeSummary(agents) { const c=Model.volumeCoverage(agents);return c.total===null?'Sales volume unknown':`${Model.money(c.total,true)} known sales volume${c.unknownCount?` · ${c.unknownCount} unknown`:''}`; },
  contactSourceNote(a) { return a.datasetId==='sample'||String(a.id||'').startsWith('sample-')?'Fictional contact details for this preview.':a.manual?'Entered locally.':a.datasetId==='live'?'Imported professional contact details; review source evidence before outreach.':'Source classification has not been verified.'; },
  initials(s) { return (s||'?').split(' ').filter(Boolean).slice(0,2).map(x=>x[0]).join(''); },
  date(s) { if(!s)return '—';return new Date(s.length===10?s+'T12:00:00':s).toLocaleDateString('en-US',{month:'short',day:'numeric',year:'numeric'}); },
  dateTime(s) { if(!s)return '—'; if(s.length===10)return new Date(s+'T12:00:00').toLocaleDateString('en-US',{month:'short',day:'numeric',year:'numeric'})+' · time not recorded'; const d=new Date(s); return Number.isNaN(d.getTime())?'—':d.toLocaleString('en-US',{dateStyle:'medium',timeStyle:'short'}); },
  recordedServiceCities(e) { return e?.evidenceStatus==='reviewed'&&e.source?.reference&&e.checkedAt&&Array.isArray(e.serviceCities)?e.serviceCities.filter(c=>typeof c==='string'&&c.trim()):[]; },
  sourceTypes: {manual:'Manual entry',ai_agent:'AI agent',email_import:'Email import',csv_import:'CSV import',courted_import:'Courted import',provider_import:'Provider import'},
  sourceLabel(a) { return String(a.source||'').trim()||'Unknown source'; },
  sourceType(a) { if(Object.hasOwn(Model.sourceTypes,a.sourceType))return a.sourceType;const legacy={'CSV import':'csv_import','Courted CSV export':'courted_import','Manual contact':'manual','Reviewed discovery import':'provider_import'};return Object.hasOwn(legacy,a.source)?legacy[a.source]:'unknown'; },
  dateParts(value,timeZone) {
    if(typeof value!=='string'||!/^\d{4}-\d{2}-\d{2}(?:T.*)?$/.test(value))return null;
    const calendar=new Date(value.slice(0,10)+'T12:00:00Z');if(Number.isNaN(calendar.getTime())||calendar.toISOString().slice(0,10)!==value.slice(0,10))return null;
    if(value.length===10){const d=new Date(value+'T12:00:00Z');return !Number.isNaN(d.getTime())&&d.toISOString().slice(0,10)===value?{day:value,time:null}:null;}
    if(!/[zZ]$|[+-]\d{2}:?\d{2}$/.test(value))return null;
    const d=new Date(value);if(Number.isNaN(d.getTime()))return null;
    try{const parts=new Intl.DateTimeFormat('en-CA',{timeZone:timeZone||undefined,year:'numeric',month:'2-digit',day:'2-digit',hour:'2-digit',minute:'2-digit',second:'2-digit',hourCycle:'h23'}).formatToParts(d),part=k=>parts.find(p=>p.type===k).value;return {day:part('year')+'-'+part('month')+'-'+part('day'),time:part('hour')+':'+part('minute')+':'+part('second')};}catch{return null;}
  },
  matchesDateRange(value,from,to,mode='',timeZone,fromTime='',toTime='') {
    if(!mode&&!from&&!to&&!fromTime&&!toTime)return true;
    const parts=Model.dateParts(value,timeZone);
    if(mode==='unknown')return !parts;
    if(mode==='known'&&!parts)return false;
    if(!from&&!to&&!fromTime&&!toTime)return true;
    if(!parts)return false;
    if((from&&parts.day<from)||(to&&parts.day>to))return false;
    // A date-only source never supplies invented time-of-day precision.
    if((fromTime||toTime)&&!parts.time)return false;
    if(fromTime&&(!from||parts.day===from)&&parts.time.slice(0,5)<fromTime)return false;
    if(toTime&&(!to||parts.day===to)&&parts.time.slice(0,5)>toTime)return false;
    return true;
  },
  lastContactAt(a,messages=[],timeZone) {
    const values=[a.lastInteraction,...messages.filter(m=>m.agentId===a.id&&['inbound','outbound'].includes(m.direction)&&!['automatic_notice','held','unverified'].includes(m.messageClass)).map(m=>m.occurredAt)].filter(v=>Model.dateParts(v,timeZone));
    // Preserve a date-only interaction when the latest day also lacks an exact time.
    return values.sort((x,y)=>{const p=Model.dateParts(x,timeZone),q=Model.dateParts(y,timeZone);return q.day.localeCompare(p.day)||(!p.time?-1:!q.time?1:new Date(y)-new Date(x));})[0]||null;
  },
  validateDateFilters(f) {
    for(const prefix of ['added','contact','sourced']){
      const from=f[prefix+'From'],to=f[prefix+'To'];
      if(from&&to&&from>to)throw Error('End date must be on or after start date.');
    }
    if(f.sourcedFromTime&&f.sourcedToTime&&(!f.sourcedFrom||!f.sourcedTo||f.sourcedFrom===f.sourcedTo)&&f.sourcedFromTime>f.sourcedToTime)throw Error('Source end time must be on or after start time.');
    for(const prefix of ['added','contact','sourced'])if(f[prefix+'Mode']==='unknown'&&(f[prefix+'From']||f[prefix+'To']||(prefix==='sourced'&&(f.sourcedFromTime||f.sourcedToTime))))throw Error('Clear the date range when filtering for an unknown date.');
    return f;
  },
  filter(agents,f={},evidence=[],options={}) { const serviceByAgent=new Map(evidence.map(e=>[e.agentId,Model.recordedServiceCities(e)]));return agents.filter(a=>{
    const cities=serviceByAgent.get(a.id)||[];
    const text=[a.name,a.office,a.city,a.email,a.phone,a.mlsId,a.license,...cities].join(' ').toLowerCase();
    return (!f.source||Model.sourceLabel(a)===f.source)&&(!f.sourceType||Model.sourceType(a)===f.sourceType)&&Model.matchesDateRange(a.createdAt||a.importedAt,f.addedFrom,f.addedTo,f.addedMode,options.timeZone)&&(!(f.contactFrom||f.contactTo||f.contactMode)||Model.matchesDateRange(Model.lastContactAt(a,options.externalMessages||[],options.timeZone),f.contactFrom,f.contactTo,f.contactMode,options.timeZone))&&Model.matchesDateRange(a.sourcedAt,f.sourcedFrom,f.sourcedTo,f.sourcedMode,options.timeZone,f.sourcedFromTime,f.sourcedToTime)&&(!f.q||text.includes(f.q.toLowerCase()))&&(!f.city||a.city===f.city)&&(!f.serviceCity||cities.some(c=>c.toLowerCase()===String(f.serviceCity).toLowerCase()))&&(!f.move||a.move===f.move)&&(!f.status||a.status===f.status)&&(!f.minVolume||(a.volume??-1)>=Number(f.minVolume))&&(!f.maxVolume||(a.volume??Infinity)<=Number(f.maxVolume))&&(!f.minYears||(a.years??-1)>=Number(f.minYears))&&((f.maxActive==null||f.maxActive==='')||(a.active??Infinity)<=Number(f.maxActive));
  }); },
  candidates(agents,p={}) {return agents.filter(a=>(a.datasetId==='sample'||String(a.id||'').startsWith('sample-'))&&!a.manual&&!a.disposition&&!['Recruited','Not interested','Not qualified','Do not contact','Lost'].includes(a.status)).filter(a=>{
    const avg=a.units?a.volume/a.units:null;
    const range=(v,lo,hi,on)=>!on||(v!=null&&v>=Number(lo||0)&&(!Number(hi)||v<=Number(hi)));
    return (!p.cities?.length||p.cities.includes(a.city))&&range(a.volume,p.minVolume,p.maxVolume,p.mustVolume)&&range(a.years,p.minYears,p.maxYears,p.mustYears)&&range(a.units,p.minUnits,p.maxUnits,p.mustUnits)&&range(avg,p.minPrice,p.maxPrice,p.mustPrice);
  }).slice(0,Number(p.dailyLimit)||20);},
  sort(items,key,dir=1,options={}) {
    const values=new Map(),dateKey=['addedAt','lastContactAt','sourcedAt'].includes(key);
    const value=a=>{if(values.has(a))return values.get(a);let v=key.startsWith('custom:')?a.customValues?.[key.slice(7)]:key==='addedAt'?(a.createdAt||a.importedAt):key==='lastContactAt'?Model.lastContactAt(a,options.externalMessages||[],options.timeZone):a[key];if(dateKey)v=Model.dateParts(v,options.timeZone)?new Date(v.length===10?v+'T12:00:00Z':v).getTime():null;values.set(a,v);return v;};
    return [...items].sort((a,b)=>{const x=value(a),y=value(b);if(x==null&&y==null)return 0;if(x==null)return 1;if(y==null)return -1;return (typeof x==='number'&&typeof y==='number'?x-y:String(x).localeCompare(String(y),undefined,{numeric:true}))*dir;});
  },
  pipeline(agents) {return agents.filter(a=>a.status&&!['Not qualified','Do not contact'].includes(a.status));},
  csv(agents) {const safe=v=>'"'+String(v??'').replace(/^[=+@\-\t\r]/,"'$&").replace(/"/g,'""')+'"';const privateHeaders=new Set(["Agent's Home Address","Most Recent Mutual Connection Address","Note 1","Note 2","Note 3"]);const sourceHeaders=[...new Set(agents.flatMap(a=>Object.keys(a.courtedFields||{})))].filter(x=>!privateHeaders.has(x)).sort();const header=['CRM ID','Dataset','Name','Office','City','Email','Phone','LinkedIn profile URL','CRM status','Move potential','LTM sales volume','Source','Source method','Sourcing agent','Date added','Source date / time','Source reference',...sourceHeaders.map(x=>'Courted: '+x)];const rows=agents.map(a=>[a.id,a.datasetId||'sample',a.name,a.office,a.city,a.email,a.phone,a.linkedinUrl,a.status,a.move,a.volume,a.source,Model.sourceTypes[Model.sourceType(a)]||'',a.sourceActor,a.createdAt||a.importedAt,a.sourcedAt,a.sourceReference,...sourceHeaders.map(x=>a.courtedFields?.[x]||'')]);return [header,...rows].map(r=>r.map(safe).join(',')).join('\r\n');},
  transactions(a,period,today,custom={}) {const end=new Date(today+'T23:59:59');let start=new Date(today+'T00:00:00');
    if(period==='LTM')start.setFullYear(start.getFullYear()-1);else if(period==='YTD')start=new Date(end.getFullYear(),0,1);else if(period==='5Y')start.setFullYear(start.getFullYear()-5);else if(period==='All time')start=new Date(0);else if(period==='Custom'){start=new Date(custom.from+'T00:00:00');end.setTime(new Date(custom.to+'T23:59:59').getTime());}else{start=new Date(Number(period),0,1);end.setTime(new Date(Number(period),11,31,23,59,59).getTime());}
    return (a.transactions||[]).filter(t=>{const d=new Date(t.date+'T12:00:00');return d>=start&&d<=end;});},
  metrics(txs){const volume=txs.reduce((n,t)=>n+t.price,0),buy=txs.filter(t=>t.side==='Buy-side').length;return{volume,units:txs.length,avg:txs.length?volume/txs.length:null,buy,list:txs.length-buy,gci:volume*.0275};},
  tasks(tasks,bucket,today,q=''){return tasks.filter(t=>bucket==='Completed'?t.completed:!t.completed).filter(t=>bucket==='Today'?t.dueDate===today:bucket==='Overdue'?t.dueDate<today:bucket==='Upcoming'?t.dueDate>today:true).filter(t=>!q||(t.title+' '+t.description).toLowerCase().includes(q.toLowerCase())).sort((a,b)=>a.dueDate.localeCompare(b.dueDate));},
};
if(typeof module!=='undefined')module.exports=Model;
