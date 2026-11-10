enum BlazerMapTheme {
  static let css = #"""
#bz-blazer-map[data-design="treemap"] {
  --bg:#140d0a; --panel:#231812; --raised:#342318; --line:#4e3527;
  --ink:#fff0d9; --muted:#ddbd9c; --ember:#ffc37f;
  --cache:#ff963a; --worktree:#ce91ef; --folder:#6bdbcc;
  background:radial-gradient(ellipse at 28% 15%,#381a0e,var(--bg) 63%);
}
#bz-blazer-map[data-design="treemap"] .bz-emblem {
  background:#452211;
  border-color:#90502c;
  font-size:0;
}
#bz-blazer-map[data-design="treemap"] .bz-emblem::before {
  content:"";
  width:22px;
  height:25px;
  background:linear-gradient(0deg,#fff1ac,#ff872c 62%,#ee4e2e);
  clip-path:polygon(46% 0,67% 28%,71% 48%,86% 34%,97% 66%,86% 89%,64% 100%,33% 100%,10% 87%,3% 68%,17% 42%,28% 59%,41% 39%);
}
#bz-blazer-map[data-design="treemap"] .bz-stage {
  background:linear-gradient(135deg,#2e1d14,#1c1310 66%);
}
#bz-blazer-map[data-design="treemap"] .bz-maphead h2 {
  color:#ffcf91;
  font-size:25px;
}
#bz-blazer-map .bz-furnace {
  background:
    radial-gradient(circle at 8px 8px,#ffc086 0 1px,#381c13 1.5px 3px,transparent 3.5px),
    radial-gradient(circle at calc(100% - 8px) 8px,#ffc086 0 1px,#381c13 1.5px 3px,transparent 3.5px),
    radial-gradient(circle at 8px calc(100% - 8px),#ffc086 0 1px,#381c13 1.5px 3px,transparent 3.5px),
    radial-gradient(circle at calc(100% - 8px) calc(100% - 8px),#ffc086 0 1px,#381c13 1.5px 3px,transparent 3.5px),
    linear-gradient(180deg,#63422e,#302016 26%,#4b2a1d 86%,#67412b);
  padding:12px;
  border:1px solid #8d5d3e;
  border-radius:10px 10px 6px 6px;
  box-shadow:inset 0 1px #ab6f43, 0 5px 0 #130c09;
}
#bz-blazer-map .bz-furnace-mouth {
  padding:5px;
  border:1px solid #a35f35;
  border-radius:5px;
  background:#2d120b;
  box-shadow:inset 0 0 7px #0e0604;
}
#bz-blazer-map .bz-furnace .bz-treemap {
  height:274px;
  isolation:isolate;
  border-radius:3px;
  background:#7b2810;
}
#bz-blazer-map .bz-furnace .bz-treemap::before {
  content:"";
  position:absolute;
  inset:0;
  pointer-events:none;
  background:radial-gradient(ellipse at 45% 85%,#ffc767,#ff7c2a 46%,#a23219 75%);
  opacity:var(--glow-opacity,.85);
}
#bz-blazer-map .bz-furnace .bz-tile {
  --slab:#47190d;
  position:absolute;
  container-type:size;
  display:grid;
  align-items:end;
  padding:0;
  border:2px solid transparent;
  border-radius:5px;
  overflow:hidden;
  text-align:left;
  background:
    repeating-linear-gradient(172deg,transparent 0 11px,#ffdeb209 11px 12px,transparent 12px 19px) padding-box,
    linear-gradient(153deg,color-mix(in srgb,var(--mark) 25%,var(--slab)),var(--slab) 74%) padding-box;
  box-shadow:inset 1px 1px 0 color-mix(in srgb,var(--mark) 64%,#52251c),
    inset -2px -3px 0 #10090677;
  transition:filter .13s ease,box-shadow .13s ease;
}
#bz-blazer-map .bz-furnace .bz-tile[data-kind="worktree"] { --slab:#362333; }
#bz-blazer-map .bz-furnace .bz-tile[data-kind="folder"] { --slab:#173b36; }
#bz-blazer-map .bz-furnace .bz-tile:hover { filter:brightness(1.22); }
#bz-blazer-map .bz-furnace .bz-tile:focus-visible { z-index:3; }
#bz-blazer-map .bz-furnace .bz-tile[aria-pressed="true"] {
  box-shadow:inset 0 0 0 2px var(--mark),inset 0 -12px 32px color-mix(in srgb,var(--mark) 27%,transparent);
}
#bz-blazer-map .bz-slab-label {
  min-width:0;
  display:grid;
  gap:2px;
  padding:clamp(4px,1.1vw,12px);
}
#bz-blazer-map .bz-slab-label :is(small,span,strong) {
  overflow:hidden;
  white-space:nowrap;
  text-overflow:ellipsis;
}
#bz-blazer-map .bz-slab-label span { font-weight:650; }
#bz-blazer-map .bz-slab-label strong {
  color:#fff0c1;
  font-size:clamp(13px,2.6vw,28px);
  letter-spacing:-.04em;
}
#bz-blazer-map .bz-slab-label small {
  color:var(--mark);
  font:600 11px ui-monospace,monospace;
  text-transform:uppercase;
  letter-spacing:.05em;
}
@container (max-width:109px) or (max-height:72px) {
  #bz-blazer-map .bz-slab-label small { display:none; }
  #bz-blazer-map .bz-slab-label strong { font-size:17px; }
}
@container (max-width:70px) or (max-height:43px) {
  #bz-blazer-map .bz-slab-label { padding:4px; }
  #bz-blazer-map .bz-slab-label span { display:none; }
  #bz-blazer-map .bz-slab-label strong { font-size:13px; }
}
@container (max-width:43px) or (max-height:22px) {
  #bz-blazer-map .bz-slab-label { display:none; }
}
#bz-blazer-map .bz-furnace-vents {
  height:11px;
  margin:9px 12% 0;
  border-radius:2px;
  background:repeating-linear-gradient(90deg,#150d08 0 5px,#2d1b12 5px 6px,transparent 6px 10px);
}
#bz-blazer-map .bz-furnace + .bz-legend { margin-top:13px; }

#bz-blazer-map[data-design="graveyard"] {
  --bg:#0d1518; --panel:#142126; --raised:#1c2b2e; --line:#30454b;
  --ink:#e9f3e6; --muted:#b6cdc6; --ember:#b9edb4;
  --worktree:#9dd3bb; --zombie:#f19aab; --cache:#e9ae68; --folder:#a9c9fc;
  background:radial-gradient(ellipse at 30% 10%,#193431,var(--bg) 67%);
}
#bz-blazer-map[data-design="graveyard"] .bz-emblem {
  background:#1c3634;
  border-color:#466762;
  font-size:0;
}
#bz-blazer-map[data-design="graveyard"] .bz-emblem::before {
  content:"+";
  font:600 15px ui-monospace,monospace;
  text-align:center;
  width:16px;
  height:20px;
  border:2px solid;
  border-radius:10px 10px 2px 2px;
}
#bz-blazer-map[data-design="graveyard"] .bz-maphead h2 {
  font-family:Georgia,serif;
  font-size:26px;
  letter-spacing:-.02em;
}
#bz-blazer-map .bz-graveyard {
  position:relative;
  isolation:isolate;
  container-type:inline-size;
  overflow:hidden;
  border-radius:8px;
  border:1px solid #416660;
  background:linear-gradient(174deg,#19303c 3%,#1d3e41 31%,#253b3b 52%,#0d171b 92%);
}
#bz-blazer-map .bz-graveyard::before {
  content:"";
  position:absolute;
  top:13px;
  right:10%;
  width:48px;
  height:48px;
  border-radius:50%;
  background:radial-gradient(circle at 35% 33%,#f1ffcf,#b7e5bd);
  box-shadow:0 0 30px #b6e4c17d;
  pointer-events:none;
}
#bz-blazer-map .bz-ridgeline {
  position:absolute;
  inset:32px 0 0;
  z-index:-1;
  pointer-events:none;
  background:linear-gradient(#11262a,#0c1b20);
  clip-path:polygon(0 18%,7% 12%,13% 16%,19% 11%,25% 17%,29% 9%,34% 16%,40% 19%,47% 13%,53% 14%,59% 9%,66% 15%,72% 12%,82% 21%,89% 15%,96% 18%,100% 11%,100% 100%,0 100%);
}
#bz-blazer-map .bz-graveyard::after {
  content:"";
  position:absolute;
  inset:18% 0 0;
  z-index:-1;
  pointer-events:none;
  background:radial-gradient(ellipse at 34% 54%,#a5d5c03b,transparent 55%),
    radial-gradient(ellipse at 76% 85%,#77b3b237,transparent 57%);
  opacity:var(--fog-opacity,.8);
}
#bz-blazer-map .bz-plots {
  position:relative;
  display:grid;
  grid-template-columns:repeat(4,minmax(0,1fr));
  padding:65px 8px 10px;
  gap:8px;
}
#bz-blazer-map .bz-plot {
  min-width:0;
  padding:0 3px 4px;
  border-left:1px solid #6894884d;
}
#bz-blazer-map .bz-plot:first-child { border-left:none; }
#bz-blazer-map .bz-plot-heading {
  display:flex;
  justify-content:space-between;
  gap:2px 5px;
  align-items:baseline;
  flex-wrap:wrap;
  color:#d4efdb;
  font:600 11px ui-monospace,monospace;
  margin:0 0 7px;
  text-transform:uppercase;
  letter-spacing:.035em;
}
#bz-blazer-map .bz-plot-count {
  color:#c5e0d7;
  font-weight:400;
  font-variant-numeric:tabular-nums;
}
#bz-blazer-map .bz-grave {
  display:block;
  width:min(100%,132px);
  min-height:67px;
  padding:8px 7px 4px;
  margin:0 auto 6px;
  color:var(--ink);
  text-align:center;
  border:1px solid #64817b;
  border-bottom:4px solid #435b55;
  border-radius:46% 46% 4px 4px / 23px 23px 4px 4px;
  background:
    repeating-linear-gradient(168deg,transparent 0 9px,#defcda07 9px 10px,transparent 10px 14px),
    linear-gradient(#314844,#172825);
  box-shadow:inset 1px 1px #88a69a66,0 3px 0 #0a1418;
}
#bz-blazer-map .bz-grave[data-kind="zombie"] {
  border-color:#856371;
  border-bottom-color:#59434e;
  background:linear-gradient(#47313f,#241e2a);
}
#bz-blazer-map .bz-grave:hover { filter:brightness(1.18); }
#bz-blazer-map .bz-grave[aria-pressed="true"] {
  outline:1px solid var(--mark);
  outline-offset:1px;
  box-shadow:0 0 12px color-mix(in srgb,var(--mark) 34%,transparent);
}
#bz-blazer-map .bz-grave:focus-visible {
  outline:2px solid var(--ink);
  outline-offset:2px;
}
#bz-blazer-map .bz-engraving {
  display:block;
  color:var(--mark);
  font:600 13px/1 ui-monospace,monospace;
  margin-bottom:2px;
}
#bz-blazer-map .bz-grave-name {
  display:block;
  overflow:hidden;
  white-space:nowrap;
  text-overflow:ellipsis;
  font-size:12px;
  font-weight:650;
}
#bz-blazer-map .bz-grave-state {
  display:block;
  overflow:hidden;
  white-space:nowrap;
  text-overflow:ellipsis;
  color:#d2e7de;
  font-size:11px;
}
#bz-blazer-map .bz-grave-live { color:#ffb4c4; }
#bz-blazer-map .bz-plot-empty { color:#d0e7dc; font-size:11px; }
#bz-blazer-map .bz-graveyard + .bz-legend { margin-top:10px; }
#bz-blazer-map .bz-ledger-toggle {
  padding:7px 10px;
  border:1px solid var(--line);
  background:var(--panel);
  border-radius:8px;
}
#bz-blazer-map .bz-ledger-toggle[aria-pressed="true"] {
  border-color:var(--ember);
  color:var(--ember);
}
@container (max-width:390px) {
  #bz-blazer-map .bz-plots { grid-template-columns:repeat(2,minmax(0,1fr)); }
  #bz-blazer-map .bz-plot:nth-child(odd) { border-left:none; }
}
@media (max-width:390px) {
  #bz-blazer-map .bz-furnace { padding:8px; }
  #bz-blazer-map .bz-furnace .bz-treemap { height:246px; }
}
@media (prefers-reduced-motion:reduce) {
  #bz-blazer-map .bz-furnace .bz-tile { transition:none; }
}
"""#
}
