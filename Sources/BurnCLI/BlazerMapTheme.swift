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
@media (max-width:390px) {
  #bz-blazer-map .bz-furnace { padding:8px; }
  #bz-blazer-map .bz-furnace .bz-treemap { height:246px; }
}
@media (prefers-reduced-motion:reduce) {
  #bz-blazer-map .bz-furnace .bz-tile { transition:none; }
}
"""#
}
