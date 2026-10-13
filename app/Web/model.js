'use strict';
const Model = {
  escape(v) { return String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c])); },
  money(v,compact=false) { if(v==null)return '—'; return new Intl.NumberFormat('en-US',{style:'currency',currency:'USD',maximumFractionDigits:compact?1:0,...(compact?{notation:'compact'}:{})}).format(v); },
  initials(s) { return (s||'?').split(' ').filter(Boolean).slice(0,2).map(x=>x[0]).join(''); },
  date(s) { if(!s)return '—';return new Date(s.length===10?s+'T12:00:00':s).toLocaleDateString('en-US',{month:'short',day:'numeric',year:'numeric'}); },
  dateTime(s) { if(!s)return '—'; if(s.length===10)return new Date(s+'T12:00:00').toLocaleDateString('en-US',{month:'short',day:'numeric',year:'numeric'})+' · time not recorded'; const d=new Date(s); return Number.isNaN(d.getTime())?'—':d.toLocaleString('en-US',{dateStyle:'medium',timeStyle:'short'}); },
  filter(agents,f={}) { return agents.filter(a=>{
    const text=[a.name,a.office,a.city,a.email,a.phone,a.mlsId,a.license].join(' ').toLowerCase();
    return (!f.q||text.includes(f.q.toLowerCase()))&&(!f.city||a.city===f.city)&&(!f.move||a.move===f.move)&&(!f.status||a.status===f.status)&&(!f.minVolume||(a.volume??-1)>=Number(f.minVolume))&&(!f.maxVolume||(a.volume??Infinity)<=Number(f.maxVolume))&&(!f.minYears||(a.years??-1)>=Number(f.minYears))&&((f.maxActive==null||f.maxActive==='')||(a.active??Infinity)<=Number(f.maxActive));
  }); },
  candidates(agents,p={}) {return agents.filter(a=>(a.datasetId==='sample'||String(a.id||'').startsWith('sample-'))&&!a.manual&&!a.disposition&&!['Recruited','Not interested','Not qualified','Do not contact','Lost'].includes(a.status)).filter(a=>{
    const avg=a.units?a.volume/a.units:null;
    const range=(v,lo,hi,on)=>!on||(v!=null&&v>=Number(lo||0)&&(!Number(hi)||v<=Number(hi)));
    return (!p.cities?.length||p.cities.includes(a.city))&&range(a.volume,p.minVolume,p.maxVolume,p.mustVolume)&&range(a.years,p.minYears,p.maxYears,p.mustYears)&&range(a.units,p.minUnits,p.maxUnits,p.mustUnits)&&range(avg,p.minPrice,p.maxPrice,p.mustPrice);
  }).slice(0,Number(p.dailyLimit)||20);},
  sort(items,key,dir=1) {const value=a=>key.startsWith('custom:')?a.customValues?.[key.slice(7)]:a[key];return [...items].sort((a,b)=>{const x=value(a),y=value(b);if(x==null&&y==null)return 0;if(x==null)return 1;if(y==null)return -1;return (typeof x==='number'&&typeof y==='number'?x-y:String(x).localeCompare(String(y),undefined,{numeric:true}))*dir;});},
  pipeline(agents) {return agents.filter(a=>a.status&&!['Not qualified','Do not contact'].includes(a.status));},
  csv(agents) {const safe=v=>'"'+String(v??'').replace(/^[=+@\-\t\r]/,"'$&").replace(/"/g,'""')+'"';const privateHeaders=new Set(["Agent's Home Address","Most Recent Mutual Connection Address","Note 1","Note 2","Note 3"]);const sourceHeaders=[...new Set(agents.flatMap(a=>Object.keys(a.courtedFields||{})))].filter(x=>!privateHeaders.has(x)).sort();const header=['CRM ID','Dataset','Name','Office','City','Email','Phone','LinkedIn profile URL','CRM status','Move potential','LTM sales volume','Source',...sourceHeaders.map(x=>'Courted: '+x)];const rows=agents.map(a=>[a.id,a.datasetId||'sample',a.name,a.office,a.city,a.email,a.phone,a.linkedinUrl,a.status,a.move,a.volume,a.source,...sourceHeaders.map(x=>a.courtedFields?.[x]||'')]);return [header,...rows].map(r=>r.map(safe).join(',')).join('\r\n');},
  transactions(a,period,today,custom={}) {const end=new Date(today+'T23:59:59');let start=new Date(today+'T00:00:00');
    if(period==='LTM')start.setFullYear(start.getFullYear()-1);else if(period==='YTD')start=new Date(end.getFullYear(),0,1);else if(period==='5Y')start.setFullYear(start.getFullYear()-5);else if(period==='All time')start=new Date(0);else if(period==='Custom'){start=new Date(custom.from+'T00:00:00');end.setTime(new Date(custom.to+'T23:59:59').getTime());}else{start=new Date(Number(period),0,1);end.setTime(new Date(Number(period),11,31,23,59,59).getTime());}
    return (a.transactions||[]).filter(t=>{const d=new Date(t.date+'T12:00:00');return d>=start&&d<=end;});},
  metrics(txs){const volume=txs.reduce((n,t)=>n+t.price,0),buy=txs.filter(t=>t.side==='Buy-side').length;return{volume,units:txs.length,avg:txs.length?volume/txs.length:null,buy,list:txs.length-buy,gci:volume*.0275};},
  tasks(tasks,bucket,today,q=''){return tasks.filter(t=>bucket==='Completed'?t.completed:!t.completed).filter(t=>bucket==='Today'?t.dueDate===today:bucket==='Overdue'?t.dueDate<today:bucket==='Upcoming'?t.dueDate>today:true).filter(t=>!q||(t.title+' '+t.description).toLowerCase().includes(q.toLowerCase())).sort((a,b)=>a.dueDate.localeCompare(b.dueDate));},
};
if(typeof module!=='undefined')module.exports=Model;
