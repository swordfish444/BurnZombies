// Self-contained Burn Pit browser view for one read-only snapshot.
enum BlazerMapPage {
  static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
<title>BurnZombies · Burn Pit</title>
</head>
<body style="margin:0;background:#100e12">
<div id="bz-blazer-map" data-design="treemap">
<style>
#bz-blazer-map{--bg:#100e12;--panel:#1c181e;--raised:#262027;--line:#3a3038;--ink:#fff6ec;--muted:#c3b6bf;--ember:#ffa965;--cache:#e38a4a;--worktree:#9b96f0;--zombie:#f8768e;--folder:#76c6bd;box-sizing:border-box;background:var(--bg);color:var(--ink);font:14px/1.45 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;padding:clamp(12px,2.7vw,32px);color-scheme:dark}
#bz-blazer-map *{box-sizing:border-box}
#bz-blazer-map [hidden]{display:none!important}
#bz-blazer-map .bz-shell{max-width:1220px;margin:auto}
#bz-blazer-map .bz-head,#bz-blazer-map .bz-tools,#bz-blazer-map .bz-maphead{display:flex;align-items:center;justify-content:space-between;gap:12px;flex-wrap:wrap}
#bz-blazer-map .bz-brand{display:flex;align-items:center;gap:12px}
#bz-blazer-map .bz-emblem{display:grid;place-items:center;width:38px;height:38px;background:#3c2523;border:1px solid #694232;border-radius:11px;color:var(--ember);font-size:21px}
#bz-blazer-map .bz-kicker,#bz-blazer-map .bz-label,#bz-blazer-map .bz-table thead{color:var(--muted);font:600 11px/1.3 ui-monospace,monospace;letter-spacing:.09em;text-transform:uppercase}
#bz-blazer-map .bz-kicker{color:var(--ember)}
#bz-blazer-map h1,#bz-blazer-map h2,#bz-blazer-map h3,#bz-blazer-map p{margin:0}
#bz-blazer-map h1{font-size:clamp(24px,3vw,36px);line-height:1.08;letter-spacing:-.04em}
#bz-blazer-map h2{font-size:18px;letter-spacing:-.02em}
#bz-blazer-map h3{font-size:21px;line-height:1.18;letter-spacing:-.025em;overflow-wrap:anywhere}
#bz-blazer-map .bz-stamp{color:var(--muted);text-align:right;font-size:12px}
#bz-blazer-map .bz-stamp strong{display:block;color:var(--ember);font-size:12px}
#bz-blazer-map .bz-volume{display:grid;grid-template-columns:1.6fr 1fr 1fr;gap:16px;border-block:1px solid var(--line);padding:13px 0;margin:17px 0}
#bz-blazer-map .bz-metric strong{display:block;font-size:19px;font-variant-numeric:tabular-nums}
#bz-blazer-map .bz-metric span:not(.bz-label){color:var(--muted);font-size:12px}
#bz-blazer-map .bz-meter{height:5px;background:var(--raised);border-radius:5px;margin:6px 0;overflow:hidden}
#bz-blazer-map .bz-meter i{display:block;height:100%;background:linear-gradient(90deg,#a64445,#ffa965);border-radius:5px}
#bz-blazer-map .bz-tools{justify-content:flex-start;margin-bottom:12px}
#bz-blazer-map button,#bz-blazer-map input,#bz-blazer-map select{font:inherit;color:inherit}
#bz-blazer-map button{cursor:pointer}
#bz-blazer-map button:focus-visible,#bz-blazer-map input:focus-visible,#bz-blazer-map select:focus-visible,#bz-blazer-map summary:focus-visible{outline:2px solid var(--ember);outline-offset:3px}
#bz-blazer-map .bz-tools input,#bz-blazer-map .bz-tools select,#bz-blazer-map .bz-more{padding:7px 10px;border:1px solid var(--line);background:var(--panel);border-radius:8px}
#bz-blazer-map .bz-tools input{min-width:100px;flex:1;max-width:370px}
#bz-blazer-map .bz-tools input::placeholder{color:var(--muted)}
#bz-blazer-map .bz-tools select{max-width:100%}
#bz-blazer-map .bz-counter{margin-left:auto;color:var(--muted);font-size:12px}
#bz-blazer-map .bz-workspace{display:grid;grid-template-columns:minmax(0,1fr) minmax(188px,245px);gap:12px;align-items:stretch}
#bz-blazer-map .bz-stage,#bz-blazer-map .bz-inspector{background:var(--panel);border:1px solid var(--line);border-radius:12px;min-width:0}
#bz-blazer-map .bz-stage{padding:12px}
#bz-blazer-map .bz-maphead{margin-bottom:9px}
#bz-blazer-map .bz-caption,#bz-blazer-map .bz-note{color:var(--muted);font-size:12px;overflow-wrap:anywhere}
#bz-blazer-map .bz-chart{min-height:292px}
#bz-blazer-map .bz-inspector{padding:13px;display:flex;flex-direction:column;gap:9px}
#bz-blazer-map .bz-chip{display:inline-flex;align-items:center;gap:6px;width:fit-content;color:var(--ink);font-size:12px}
#bz-blazer-map .bz-chip:before,#bz-blazer-map .bz-legend b:before{content:"";display:inline-block;width:8px;height:8px;border-radius:2px;background:var(--mark);flex:none}
#bz-blazer-map [data-kind="cache"]{--mark:var(--cache)}
#bz-blazer-map [data-kind="worktree"]{--mark:var(--worktree)}
#bz-blazer-map [data-kind="zombie"]{--mark:var(--zombie)}
#bz-blazer-map [data-kind="folder"]{--mark:var(--folder)}
#bz-blazer-map .bz-path{overflow-wrap:anywhere;color:var(--muted);font:12px/1.45 ui-monospace,monospace}
#bz-blazer-map .bz-readout{border-top:1px solid var(--line);padding-top:9px;display:grid;gap:5px;margin:0}
#bz-blazer-map .bz-readout div{display:flex;justify-content:space-between;gap:8px;flex-wrap:wrap}
#bz-blazer-map .bz-readout dt{color:var(--muted);font-size:12px}
#bz-blazer-map .bz-readout dd{margin:0;text-align:right;font-size:12px;overflow-wrap:anywhere}
#bz-blazer-map .bz-treemap{height:296px;position:relative;background:#171319;border-radius:7px}
#bz-blazer-map .bz-legend{display:flex;gap:7px 13px;flex-wrap:wrap;margin:8px 0;color:var(--muted);font-size:12px}
#bz-blazer-map .bz-legend b{display:inline-flex;gap:5px;align-items:center;font-weight:500}
#bz-blazer-map .bz-table-box{max-height:337px;min-height:292px;overflow:auto}
#bz-blazer-map .bz-table{width:100%;border-collapse:collapse;text-align:left}
#bz-blazer-map .bz-table thead{background:var(--panel);position:sticky;top:0;z-index:1}
#bz-blazer-map .bz-table td,#bz-blazer-map .bz-table th{padding:7px 6px;border-bottom:1px solid var(--line);vertical-align:middle}
#bz-blazer-map .bz-table th button{border:0;padding:0;background:none;color:inherit;text-transform:inherit;letter-spacing:inherit;white-space:nowrap}
#bz-blazer-map .bz-table td:last-child,#bz-blazer-map .bz-table th:last-child{text-align:right;white-space:nowrap;font-variant-numeric:tabular-nums}
#bz-blazer-map .bz-table tr.bz-chosen td{background:var(--raised)}
#bz-blazer-map .bz-table .bz-item{background:none;border:0;padding:2px 0;display:block;text-align:left;font-weight:650;overflow-wrap:anywhere}
#bz-blazer-map .bz-table .bz-item:hover{color:var(--ember)}
#bz-blazer-map .bz-table .bz-state{font-size:12px}
#bz-blazer-map .bz-more{margin:8px 0}
#bz-blazer-map .bz-empty{padding:15px;color:var(--muted)}
#bz-blazer-map .bz-coverage{margin-top:10px;color:var(--muted);font-size:12px}
#bz-blazer-map .bz-coverage summary{cursor:pointer;width:fit-content}
#bz-blazer-map .bz-coverage ul{padding-left:20px;margin:6px 0}
@media(max-width:660px){#bz-blazer-map .bz-workspace{grid-template-columns:minmax(0,1fr)}#bz-blazer-map .bz-inspector{min-height:148px}#bz-blazer-map .bz-volume{gap:9px}#bz-blazer-map .bz-stamp{text-align:left}}
@media(max-width:390px){#bz-blazer-map .bz-table td:nth-child(2),#bz-blazer-map .bz-table th:nth-child(2),#bz-blazer-map .bz-table td:nth-child(3),#bz-blazer-map .bz-table th:nth-child(3){display:none}#bz-blazer-map .bz-counter{margin-left:0}}
@media(pointer:coarse){#bz-blazer-map .bz-ledger-toggle,#bz-blazer-map .bz-tools input,#bz-blazer-map .bz-tools select,#bz-blazer-map .bz-item{min-height:44px}}
\#(BlazerMapTheme.css)
</style>
<div class="bz-shell">
  <header class="bz-head">
    <div class="bz-brand"><span class="bz-emblem" aria-hidden="true">↯</span><div><div class="bz-kicker">BurnZombies / Blazer Edition</div><h1>Burn Pit</h1></div></div>
    <div class="bz-stamp" data-slot="stamp"></div>
  </header>
  <div class="bz-volume" data-slot="volume"></div>
  <div class="bz-tools">
    <input type="search" data-slot="search" aria-label="Search map items" placeholder="Search name, path or status">
    <select data-slot="filter" aria-label="Map layer">
      <option value="all">All findings</option><option value="worktree">Worktrees</option>
      <option value="cache">Caches</option><option value="zombie">Zombie signals</option><option value="folder">Disk folders</option>
    </select>
    <button type="button" class="bz-ledger-toggle cursor-interaction" data-slot="ledger" aria-pressed="false">Evidence Ledger</button>
    <span class="bz-counter" data-slot="counter" aria-live="polite"></span>
  </div>
  <div class="bz-workspace">
    <section class="bz-stage" data-slot="panel" aria-label="Burn Pit findings"></section>
    <aside class="bz-inspector" data-slot="inspector" aria-label="Selected evidence" aria-live="polite"></aside>
  </div>
  <details class="bz-coverage"><summary>Snapshot coverage</summary><ul data-slot="notes"></ul></details>
</div>
<script>
(() => {
  const root = document.getElementById('bz-blazer-map');
  const $ = name => root.querySelector('[data-slot="' + name + '"]');
  const panel = $('panel');
  const snapshot = JSON.parse(new TextDecoder().decode(Uint8Array.from(atob('__BLAZER_MAP_PAYLOAD__'), c => c.charCodeAt(0))));
  const rows = new Map(snapshot.rows.map(row => [row.id,row]));
  const labels = { cache:'Cache',worktree:'Worktree',zombie:'Zombie signal',folder:'Disk folder' };
  let showLedger = new URLSearchParams(location.search).get('variant') === 'ledger';
  let selected = null, limit = 60, order = 'size', reversed = false;
  const el = (tag, klass, text) => {
    const node = document.createElement(tag);
    if (klass) node.className = klass;
    if (text !== undefined) node.textContent = text;
    return node;
  };
  const append = (parent,...children) => (parent.append(...children),parent);
  const fmt = new Intl.NumberFormat(undefined,{maximumFractionDigits:1});
  const bytes = n => n == null ? 'Unknown' : n >= 1e12 ? fmt.format(n/1e12)+' TB' : n >= 1e9 ? fmt.format(n/1e9)+' GB' : n >= 1e6 ? fmt.format(n/1e6)+' MB' : n >= 1e3 ? fmt.format(n/1e3)+' KB' : fmt.format(n)+' B';
  const date = d => d ? new Date(d).toLocaleString(undefined,{dateStyle:'medium',timeStyle:'short'}) : 'Unknown';
  const age = row => row.lastUsed ? Math.max(0,(Date.parse(snapshot.observedAt)-Date.parse(row.lastUsed))/86400000) : null;
  const ageLabel = row => age(row) == null ? 'Unknown' : age(row) < 1 ? 'Today' : Math.floor(age(row))+'d ago';
  const amount = row => row.diskBytes ?? row.memoryBytes;
  const measure = row => row.diskBytes != null ? 'Disk estimate' : row.memoryBytes != null ? 'Resident RAM' : 'Size';
  const visible = () => {
    const kind = $('filter').value, query = $('search').value.trim().toLowerCase();
    return snapshot.rows.filter(row => (kind === 'all' || row.kind === kind) &&
      (!query || [row.name,row.path,row.state,row.detail,labels[row.kind]].some(s => s?.toLowerCase().includes(query))));
  };
  const largest = (a,b) => (b.diskBytes ?? -1)-(a.diskBytes ?? -1) || a.name.localeCompare(b.name);
  const empty = (panel,text) => panel.append(el('p','bz-empty',text));
  const head = (panel,title,description) => panel.append(append(el('div','bz-maphead'),
    el('h2','',title),el('p','bz-caption',description)));
  const mark = (row,kind,description) => {
    const button = el('button',kind+' cursor-interaction');
    button.type='button';button.dataset.id=row.id;button.dataset.kind=row.kind;
    button.setAttribute('aria-label',description);
    button.setAttribute('aria-pressed',String(row.id===selected));
    button.title=description;
    return button;
  };
  const legend = (panel,data) => {
    const items = [...new Set(data.map(row=>row.kind))];
    const list=el('div','bz-legend');
    for(const key of items){const b=el('b','',labels[key]);b.dataset.kind=key;list.append(b);}
    panel.append(list);
  };
  function volume(){
    const v=snapshot.volume, known=v.totalBytes>0;
    append($('stamp'),el('strong','',snapshot.demo?'DEMO DATA · READ ONLY':'PRIVATE SNAPSHOT · READ ONLY'),
      el('span','',date(snapshot.observedAt)+(snapshot.demo?'':' · '+snapshot.durationMS+' ms')));
    const capacity=append(el('div','bz-metric'),el('span','bz-label','Home volume'),
      el('strong','',known?bytes(v.freeBytes)+' free':'Unavailable'));
    if(known){
      const meter=el('div','bz-meter'), fill=el('i');
      meter.setAttribute('role','meter');meter.setAttribute('aria-label','Disk used');
      meter.setAttribute('aria-valuemin','0');meter.setAttribute('aria-valuemax','100');
      meter.setAttribute('aria-valuenow',String(Math.round(v.usedPercent)));
      fill.style.width=Math.min(100,Math.max(0,v.usedPercent))+'%';
      append(capacity,append(meter,fill),el('span','',bytes(v.totalBytes)+' total'));
    }
    const pressure=append(el('div','bz-metric'),el('span','bz-label','Disk pressure'),
      el('strong','',!known?'Unknown':v.overdriveActive?'Overdrive':'Nominal'),
      el('span','',!known ? 'No volume telemetry' : v.exhaustBytesPerHour ? '+'+bytes(v.exhaustBytesPerHour)+'/hr' : 'No growth detected'));
    append($('volume'),capacity,pressure,append(el('div','bz-metric'),
      el('span','bz-label','Agent sessions'),el('strong','',snapshot.liveSessions+' live'),
      el('span','',snapshot.indexedSessions+' indexed')));
    for (const note of snapshot.notes) $('notes').append(el('li','',note));
  }
  // Split around half the total mass; use the longer screen axis at each split.
  // Dimensions are percentages, so resize needs no layout work or script.
  function rectangles(items,box,emit){
    if(items.length===1){emit(items[0],box);return;}
    const total=items.reduce((sum,row)=>sum+row.diskBytes,0);
    let n=1, weight=items[0].diskBytes;
    while(n<items.length-1 && Math.abs(total/2-weight-items[n].diskBytes)<Math.abs(total/2-weight)){
      weight+=items[n++].diskBytes;
    }
    const [x,y,w,h]=box,r=weight/total;
    const split=w*1.65>=h;
    rectangles(items.slice(0,n),split?[x,y,w*r,h]:[x,y,w,h*r],emit);
    rectangles(items.slice(n),split?[x+w*r,y,w*(1-r),h]:[x,y+h*r,w,h*(1-r)],emit);
  }
  function treemap(panel,data){
    const folders=$('filter').value==='folder';
    head(panel,folders?'Disk folder allocation':'Cache and worktree allocation','Slab area shows estimated disk bytes');
    const eligible=data.filter(r=>r.diskBytes>0 && (folders?r.kind==='folder':r.kind==='cache'||r.kind==='worktree'));
    // Suppress nested and identical paths for area only. The ledger retains the underlying rows.
    const roots=[], paths=new Set();
    for(const r of eligible.sort((a,b)=>(a.path?.length??0)-(b.path?.length??0)||largest(a,b))){
      if(r.path){
        const path=r.path.toLowerCase().replace(/\/$/,'');
        let covered=paths.has(path);
        for(let pos=path.lastIndexOf('/');!covered&&pos>0;pos=path.lastIndexOf('/',pos-1)){
          covered=paths.has(path.slice(0,pos));
        }
        if(covered)continue;
        paths.add(path);
      }
      roots.push(r);
    }
    const top=roots.sort(largest).slice(0,24);
    if(!top.length){empty(panel,'No measured disk items in this layer. Evidence Ledger includes rows with unknown size.');return [];}
    const chart=el('div','bz-treemap');
    rectangles(top,[0,0,100,100],(row,[x,y,w,h])=>{
      const tile=mark(row,'bz-tile',row.name+' · '+labels[row.kind]+' · '+bytes(row.diskBytes)+' · '+row.state);
      Object.assign(tile.style,{left:x+'%',top:y+'%',width:w+'%',height:h+'%'});
      tile.append(append(el('div','bz-slab-label'),el('small','',labels[row.kind]),
        el('span','',row.name),el('strong','',bytes(row.diskBytes))));
      chart.append(tile);
    });
    const vents=el('div','bz-furnace-vents');
    vents.setAttribute('aria-hidden','true');
    panel.append(append(el('div','bz-furnace'),append(el('div','bz-furnace-mouth'),chart),vents));
    legend(panel,top);
    const extras=[top.length<roots.length?(roots.length-top.length)+' smaller items':null,
      eligible.length>roots.length?(eligible.length-roots.length)+' overlapping paths':null].filter(Boolean);
    if(extras.length)panel.append(el('p','bz-note','See Evidence Ledger for '+extras.join(' and ')+'.'));
    return top;
  }
  function ledger(panel,data){
    head(panel,'Evidence Ledger','Select any row for its source and evidence');
    if(!data.length){empty(panel,'No findings match this search and layer.');return [];}
    const table=el('table','bz-table'), header=el('tr','');
    for(const [name,key] of [['Finding','name'],['Status','state'],['Last activity','activity'],['Size','size']]){
      const th=el('th',''),button=el('button','',name+(order===key?(reversed?' ↑':' ↓'):''));
      th.scope='col';if(order===key)th.setAttribute('aria-sort',reversed?'ascending':'descending');
      button.type='button';button.dataset.order=key;append(th,button);header.append(th);
    }
    const sorted=[...data].sort((a,b)=>{
      if(order==='size'){
        const type=r=>r.diskBytes!=null?0:r.memoryBytes!=null?1:2;
        return type(a)-type(b) || (reversed?-1:1)*((amount(b)??0)-(amount(a)??0)) || a.name.localeCompare(b.name);
      }
      if(order==='activity'){
        const x=age(a), y=age(b);
        if(x==null || y==null)return Number(x==null)-Number(y==null) || a.name.localeCompare(b.name);
        return (reversed?-1:1)*(x-y) || a.name.localeCompare(b.name);
      }
      return (reversed?1:-1)*a[order].localeCompare(b[order]) || a.name.localeCompare(b.name);
    });
    const shown=sorted.slice(0,limit), body=el('tbody','');
    for(const row of shown){
      const tr=el('tr',''),button=mark(row,'bz-item',row.name+' · '+row.state);
      const badge=el('span','bz-chip',labels[row.kind]);badge.dataset.kind=row.kind;
      button.textContent=row.name;
      const size=amount(row)==null?'—':bytes(amount(row))+(row.memoryBytes!=null?' RAM':'');
      append(tr,append(el('td',''),button,badge),el('td','bz-state',row.state),el('td','bz-state',ageLabel(row)),el('td','',size));
      body.append(tr);
    }
    append(table,append(el('thead',''),header),body);
    const scroll=append(el('div','bz-table-box'),table);
    if(shown.length<sorted.length){
      const more=el('button','bz-more','Show 60 more · '+(sorted.length-shown.length)+' remaining');
      more.type='button';more.dataset.more='yes';scroll.append(more);
    }
    panel.append(scroll);
    return shown;
  }
  function inspect(row){
    const inspector=$('inspector');
    inspector.replaceChildren(el('div','bz-label','Selected evidence'));
    if(!row){inspector.append(el('p','bz-caption','Select a finding to see its details.'));return;}
    const chip=el('span','bz-chip',labels[row.kind]+' · '+row.state);chip.dataset.kind=row.kind;
    append(inspector,el('h3','',row.name),chip);
    if(row.path)inspector.append(el('code','bz-path',row.path));
    if(row.detail)inspector.append(el('p','bz-caption',row.detail));
    const info=el('dl','bz-readout');
    for(const [label,value] of [[measure(row),bytes(amount(row))],['Last activity',ageLabel(row)],
      ['Observed',date(row.observedAt)],['Source',row.source]]){
      info.append(append(el('div',''),el('dt','',label),el('dd','',value)));
    }
    inspector.append(info);
  }
  function highlight(){
    root.querySelectorAll('button[data-id]').forEach(b=>{
      const active=b.dataset.id===selected;
      b.setAttribute('aria-pressed',String(active));b.closest('tr')?.classList.toggle('bz-chosen',active);
    });
    inspect(rows.get(selected));
  }
  function render(){
    const data=visible();
    const zombieLayer=$('filter').value==='zombie';
    const list=showLedger||zombieLayer;
    panel.replaceChildren();
    $('ledger').hidden=zombieLayer;
    $('ledger').textContent=list?'Show Furnace':'Evidence Ledger';
    $('ledger').setAttribute('aria-pressed',String(list));
    const shown=(list?ledger:treemap)(panel,data);
    $('counter').textContent=data.length+' matching · '+shown.length+' shown';
    if(!shown.some(r=>r.id===selected))selected=shown[0]?.id??null;
    highlight();
  }
  function setURL(){
    try {
      const url=new URL(location.href);
      url.searchParams.set('variant',showLedger?'ledger':'treemap');
      history.replaceState(null,'',url);
    }catch{}
  }
  root.addEventListener('click',event=>{
    const button=event.target.closest('button');
    if(!button)return;
    if(button.dataset.id){selected=button.dataset.id;highlight();}
    if(button===$('ledger')){showLedger=!showLedger;setURL();render();}
    if(button.dataset.order){
      reversed=order===button.dataset.order?!reversed:button.dataset.order!=='size';order=button.dataset.order;
      render();panel.querySelector('[data-order="'+order+'"]')?.focus();
    }
    if(button.dataset.more){
      const index=limit;
      limit+=60;render();
      panel.querySelectorAll('button[data-id]')[index]?.focus();
    }
  });
  for(const name of ['search','filter']) $(name).addEventListener('input',()=>{limit=60;render();});
  volume();
  render();
})();
</script>
</div>
</body>
</html>
"""#
}
