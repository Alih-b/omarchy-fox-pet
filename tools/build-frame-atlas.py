#!/usr/bin/env python3
"""Generate scratch/frame-atlas.html, the private frame-naming reference.

Reads assets/pet.json and assets/frame-names.json, validates them against
each other, and bakes both into a self-contained HTML viewer that works
over file:// (all data inlined, only the spritesheet referenced relatively).

Rerun this after editing frame names:
    python3 tools/build-frame-atlas.py
"""

import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PET_PATH = ROOT / "assets" / "pet.json"
NAMES_PATH = ROOT / "assets" / "frame-names.json"
OUT_PATH = ROOT / "scratch" / "frame-atlas.html"


def fail(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def validate(pet, names):
    sprite = pet["sprite"]
    cell = names["cell"]
    if names["spriteVersion"] != pet["spriteVersionNumber"]:
        fail(
            f"spriteVersion {names['spriteVersion']} != pet.json "
            f"spriteVersionNumber {pet['spriteVersionNumber']} — "
            "the sheet changed, re-check every name before bumping."
        )
    if cell["columns"] != sprite["columns"] or cell["rows"] != sprite["rowCount"]:
        fail("frame-names.json cell grid does not match pet.json sprite grid")
    if cell["width"] != sprite["cellWidth"] or cell["height"] != sprite["cellHeight"]:
        fail("frame-names.json cell size does not match pet.json")

    rows_to_keys = {}
    for key, row in sprite["rows"].items():
        rows_to_keys.setdefault(row["row"], []).append(key)

    seen_pos, seen_names = {}, {}
    for frame in names["frames"]:
        pos = (frame["row"], frame["col"])
        if pos in seen_pos:
            fail(f"duplicate cell {frame['id']}")
        if frame["id"] != f"r{frame['row']}c{frame['col']}":
            fail(f"{frame['id']}: id does not match row/col")
        if frame["name"] in seen_names:
            fail(f"name '{frame['name']}' used by both {seen_names[frame['name']]} and {frame['id']}")
        if not 0 <= frame["row"] < cell["rows"] or not 0 <= frame["col"] < cell["columns"]:
            fail(f"{frame['id']} outside the {cell['columns']}x{cell['rows']} grid")
        if frame["row"] not in rows_to_keys:
            fail(f"{frame['id']}: row {frame['row']} has no animation in pet.json")
        for key in frame["usedBy"]:
            if key not in sprite["rows"]:
                fail(f"{frame['id']}: usedBy '{key}' is not a pet.json row")
            if sprite["rows"][key]["row"] != frame["row"]:
                fail(f"{frame['id']}: usedBy '{key}' maps to row {sprite['rows'][key]['row']}, not {frame['row']}")
        seen_pos[pos] = frame["id"]
        seen_names[frame["name"]] = frame["id"]

    # Only cells carrying art in this sheet version need names: the declared
    # frame count of every physical row referenced by pet.json.
    declared = {r: sprite["rows"][k]["frames"] for r, keys in rows_to_keys.items() for k in keys}
    stale = [
        seen_pos[(r, c)]
        for (r, c) in seen_pos
        if c >= declared.get(r, 0)
    ]
    if stale:
        fail(f"named but undeclared by pet.json (stale?): {', '.join(sorted(stale))}")
    missing = [
        f"r{r}c{c}"
        for r, count in declared.items()
        for c in range(count)
        if (r, c) not in seen_pos
    ]
    if missing:
        fail(f"missing names for declared frames: {', '.join(missing)}")
    total = sum(declared.values())
    print(f"ok: {total} frames named ({len(seen_names)} unique names)")


HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Folio frame atlas — private reference</title>
<style>
  :root {
    --cell-w: 148px;
    --sheet-cols: __COLS__;
    --sheet: url("../assets/spritesheet.webp");
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; padding: 24px;
    background: #101418; color: #d7dde3;
    font: 13px/1.45 system-ui, sans-serif;
  }
  .topbar {
    display: flex; flex-wrap: wrap; align-items: center; gap: 12px;
    margin-bottom: 20px;
  }
  h1 { font-size: 18px; margin: 0; }
  h1 .sub { font-size: 12px; color: #7d8894; font-weight: 400; }
  #search {
    flex: 1; min-width: 220px; max-width: 420px;
    background: #1a2129; border: 1px solid #2b3540; border-radius: 8px;
    color: #d7dde3; padding: 8px 12px; font-size: 13px; outline: none;
  }
  #search:focus { border-color: #f0b64a; }
  #count { color: #7d8894; font-size: 12px; }
  #count b { color: #f0b64a; }

  .rowsec {
    margin-bottom: 28px;
    border: 1px solid #232b33; border-radius: 10px;
    overflow: hidden; background: #141a20;
  }
  .rowsec.hidden { display: none; }
  .rowhead {
    display: flex; flex-wrap: wrap; gap: 8px 20px; align-items: center;
    padding: 10px 14px; background: #1a2129;
    border-bottom: 1px solid #232b33;
  }
  .rowhead .key { font-weight: 700; font-size: 14px; color: #f0b64a; }
  .rowhead .meta { color: #8a95a1; font-size: 12px; }
  .rowhead .meta b { color: #c3ccd5; font-weight: 600; }
  .preview-wrap { margin-left: auto; display: flex; align-items: center; gap: 8px; }
  .preview-wrap .meta { font-size: 11px; color: #7d8894; }

  .grid {
    display: grid;
    grid-template-columns: repeat(var(--sheet-cols), var(--cell-w));
  }
  .cell {
    position: relative;
    aspect-ratio: __AR__;
    background-image: var(--sheet);
    background-repeat: no-repeat;
    outline: 1px solid #232b33;
    cursor: zoom-in;
    transition: filter .12s;
  }
  .cell:hover { filter: brightness(1.25); z-index: 1; }
  .cell.dimmed { filter: brightness(.25); }
  .cell.match { outline: 2px solid #f0b64a; z-index: 1; }
  .cell .tag {
    position: absolute; left: 0; right: 0; bottom: 0;
    padding: 2px 5px;
    background: rgba(10, 13, 16, .82);
    font-size: 10.5px; line-height: 1.3;
    pointer-events: none;
  }
  .cell .tag .n { color: #f0b64a; font-weight: 600; }
  .cell .tag .i { color: #7d8894; }

  #overlay {
    display: none;
    position: fixed; inset: 0;
    background: rgba(5, 8, 10, .92);
    z-index: 10;
    align-items: center; justify-content: center; flex-direction: column;
    gap: 14px;
  }
  #overlay.open { display: flex; }
  #stage {
    background: repeating-conic-gradient(#232b33 0% 25%, #161c22 0% 50%) 0 0 / 28px 28px;
    border-radius: 8px; padding: 6px; max-width: 92vw;
  }
  #ov-sprite {
    background-image: var(--sheet);
    background-repeat: no-repeat;
    display: block;
    max-width: calc(92vw - 12px);
  }
  .ovnav { display: flex; align-items: center; gap: 10px; }
  .ovnav button {
    background: #1a2129; color: #d7dde3; border: 1px solid #2b3540;
    border-radius: 6px; padding: 6px 12px; cursor: pointer; font-size: 13px;
  }
  .ovnav button:hover { border-color: #f0b64a; color: #f0b64a; }
  #ov-zoom { min-width: 52px; font-weight: 700; }
  #ov-index { color: #8a95a1; font-size: 12px; min-width: 84px; text-align: center; }
  #overlay .info { text-align: center; max-width: 680px; }
  #ov-name { font-size: 17px; font-weight: 700; color: #f0b64a; }
  #ov-ids { color: #8a95a1; margin: 4px 0; }
  #ov-note { color: #c3ccd5; }
  .hint { color: #5d6873; font-size: 11px; }
</style>
</head>
<body>
<div class="topbar">
  <h1>Folio frame atlas <span class="sub">sprite v__VERSION__ · private reference</span></h1>
  <input id="search" type="search" placeholder="filter by name, id, animation, or note…" autofocus>
  <span id="count"></span>
</div>
<div id="rows"></div>
<div id="overlay">
  <div class="ovnav">
    <button id="ov-prev" title="previous frame (←)">‹</button>
    <span id="ov-index"></span>
    <button id="ov-next" title="next frame (→)">›</button>
    <button id="ov-zoom" title="cycle zoom">2×</button>
  </div>
  <div id="stage"><div id="ov-sprite"></div></div>
  <div class="info">
    <div id="ov-name"></div>
    <div id="ov-ids"></div>
    <div id="ov-note"></div>
  </div>
  <div class="ovnav">
    <button id="ov-copy">copy name</button>
    <button id="ov-copyid">copy id</button>
  </div>
  <div class="hint">← → step between frames · click backdrop or Esc to close</div>
</div>
<script type="application/json" id="data">__DATA__</script>
<script>
const data = JSON.parse(document.getElementById('data').textContent);
const pet = __PET__;
const W = data.cell.width, H = data.cell.height;
const COLS = data.cell.columns, ROWS = data.cell.rows;
const frames = data.frames; // row-major order

function cellStyle(row, col, dispW) {
  const scale = dispW / W;
  return `background-size:${COLS * dispW}px ${ROWS * H * scale}px;` +
         `background-position:${-col * dispW}px ${-row * H * scale}px;`;
}

const rowKeys = {};
for (const [key, r] of Object.entries(pet.sprite.rows)) (rowKeys[r.row] ??= []).push(key);

const rowsEl = document.getElementById('rows');
const rowSecs = [];
for (let r = 0; r < ROWS; r++) {
  const sec = document.createElement('div');
  sec.className = 'rowsec';
  const keys = rowKeys[r] || [];
  const first = pet.sprite.rows[keys[0]] || {};
  const head = document.createElement('div');
  head.className = 'rowhead';
  head.innerHTML =
    `<span class="key">${keys.join(' / ') || 'row ' + r}</span>` +
    `<span class="meta">fps <b>${first.fps ?? '—'}</b></span>` +
    `<span class="meta">frames <b>${first.frames ?? '—'}</b></span>` +
    `<span class="meta">row <b>${r}</b></span>` +
    (first.sequence ? `<span class="meta">sequence <b>[${first.sequence.join(', ')}]</b></span>` : '') +
    (first.durations ? `<span class="meta">durations <b>[${first.durations.join(', ')}]</b></span>` : '') +
    `<span class="preview-wrap"><span class="prevsprite"></span><span class="meta">live cadence</span></span>`;
  sec.appendChild(head);

  const grid = document.createElement('div');
  grid.className = 'grid';
  for (let c = 0; c < COLS; c++) {
    const f = frames.find(f => f.row === r && f.col === c);
    const d = document.createElement('div');
    d.className = 'cell';
    d.style.cssText = cellStyle(r, c, 148);
    if (f) {
      d.dataset.id = f.id;
      d.title = `${f.name} · ${f.id}`;
      d.innerHTML = `<span class="tag"><span class="n">${f.name}</span><br><span class="i">${f.id} · ${f.usedBy.join('/')}</span></span>`;
      d.onclick = () => openOverlay(f);
    } else {
      d.title = 'empty cell — no art declared for this slot';
      d.classList.add('dimmed');
    }
    grid.appendChild(d);
  }
  sec.appendChild(grid);
  rowsEl.appendChild(sec);
  rowSecs.push(sec);

  // live preview: play the row's sequence at its cadence
  const pv = sec.querySelector('.prevsprite');
  if (!keys.length || !first.frames) { pv.style.filter = 'brightness(.25)'; continue; }
  const seq = first.sequence ?? [...Array(first.frames).keys()];
  const durs = first.durations ?? [];
  const fps = first.fps ?? 5;
  let i = 0;
  const step = () => {
    const col = seq[i % seq.length];
    pv.style.backgroundImage = 'var(--sheet)';
    pv.style.backgroundRepeat = 'no-repeat';
    pv.style.backgroundSize = `${COLS * 60}px ${ROWS * H * 60 / W}px`;
    pv.style.backgroundPosition = `${-col * 60}px ${-r * H * 60 / W}px`;
    pv.style.width = '60px';
    pv.style.height = `${H * 60 / W}px`;
    pv.style.display = 'block';
    const d = durs[i % durs.length];
    setTimeout(step, d ? d : 1000 / fps);
  };
  step();
}

// search filter
const searchEl = document.getElementById('search');
const countEl = document.getElementById('count');
function applyFilter() {
  const q = searchEl.value.trim().toLowerCase();
  let shown = 0;
  for (const sec of rowSecs) {
    let secHas = false;
    for (const cell of sec.querySelectorAll('.cell')) {
      const f = frames.find(f => f.id === cell.dataset.id);
      const hit = !f
        ? !q // empty slots only visible when not searching
        : !q ||
          f.name.toLowerCase().includes(q) ||
          f.id.includes(q) ||
          f.usedBy.some(k => k.toLowerCase().includes(q)) ||
          f.note.toLowerCase().includes(q);
      cell.style.display = hit ? '' : 'none';
      cell.classList.toggle('match', !!q && hit && !!f);
      if (hit && f) { secHas = true; shown++; }
    }
    sec.classList.toggle('hidden', !secHas);
  }
  countEl.innerHTML = q
    ? `<b>${shown}</b> / ${frames.length} frames match`
    : `${frames.length} frames · click any cell to zoom`;
}
searchEl.addEventListener('input', applyFilter);
applyFilter();

// overlay
const overlay = document.getElementById('overlay');
const spriteEl = document.getElementById('ov-sprite');
const zooms = [2, 3, 4, 1];
let zoomIdx = 0, ovIdx = 0;

function renderOverlay() {
  const f = frames[ovIdx];
  const z = zooms[zoomIdx];
  spriteEl.style.width = `${W * z}px`;
  spriteEl.style.height = `${H * z}px`;
  spriteEl.style.backgroundSize = `${COLS * W * z}px ${ROWS * H * z}px`;
  spriteEl.style.backgroundPosition = `${-f.col * W * z}px ${-f.row * H * z}px`;
  document.getElementById('ov-name').textContent = f.name;
  document.getElementById('ov-index').textContent = `${ovIdx + 1} / ${frames.length}`;
  document.getElementById('ov-ids').textContent =
    `${f.id} · row ${f.row} col ${f.col} · used by ${f.usedBy.join(', ')}`;
  document.getElementById('ov-note').textContent = f.note;
  document.getElementById('ov-zoom').textContent = `${z}×`;
  const match = document.querySelector(`.cell[data-id="${f.id}"]`);
  if (match) match.scrollIntoView({ block: 'nearest' });
}
function openOverlay(f) {
  ovIdx = frames.indexOf(f);
  renderOverlay();
  overlay.classList.add('open');
}
function closeOverlay() { overlay.classList.remove('open'); }
function stepOverlay(delta) {
  ovIdx = (ovIdx + delta + frames.length) % frames.length;
  renderOverlay();
}

document.getElementById('ov-prev').onclick = () => stepOverlay(-1);
document.getElementById('ov-next').onclick = () => stepOverlay(1);
document.getElementById('ov-zoom').onclick = e => {
  e.stopPropagation();
  zoomIdx = (zoomIdx + 1) % zooms.length;
  renderOverlay();
};
overlay.onclick = e => { if (e.target === overlay) closeOverlay(); };
document.addEventListener('keydown', e => {
  if (!overlay.classList.contains('open')) return;
  if (e.key === 'Escape') closeOverlay();
  if (e.key === 'ArrowLeft') stepOverlay(-1);
  if (e.key === 'ArrowRight') stepOverlay(1);
});
function copyText(text, btn) {
  navigator.clipboard.writeText(text).then(() => {
    const old = btn.textContent;
    btn.textContent = 'copied!';
    setTimeout(() => btn.textContent = old, 900);
  });
}
document.getElementById('ov-copy').onclick = e => { e.stopPropagation(); copyText(frames[ovIdx].name, e.target); };
document.getElementById('ov-copyid').onclick = e => { e.stopPropagation(); copyText(frames[ovIdx].id, e.target); };
</script>
</body>
</html>
"""


def main():
    pet = json.loads(PET_PATH.read_text())
    names = json.loads(NAMES_PATH.read_text())
    validate(pet, names)

    html = (
        HTML
        .replace("__COLS__", str(names["cell"]["columns"]))
        .replace("__AR__", f'{names["cell"]["width"]} / {names["cell"]["height"]}')
        .replace("__VERSION__", str(names["spriteVersion"]))
        .replace("__DATA__", json.dumps(names))
        .replace("__PET__", json.dumps(pet))
    )
    OUT_PATH.parent.mkdir(exist_ok=True)
    OUT_PATH.write_text(html)
    print(f"wrote {OUT_PATH.relative_to(ROOT)} ({OUT_PATH.stat().st_size // 1024} KiB)")


if __name__ == "__main__":
    main()
