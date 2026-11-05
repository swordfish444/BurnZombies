"""Cut one full-script take into the film's lines, using whisper word times, and place them on cues.
Usage: python cut_take.py <take.wav> <out_dir> [--tempo 1.0]
Writes <out_dir>/<id>.wav per line and <out_dir>/durations.json (id, at, dur, text). Cues come from LINES;
a line that would run into the next cue is reported, not silently overlapped.
"""
import sys, os, re, json, subprocess, difflib, tempfile
import numpy as np, soundfile as sf

TAKE, OUT = sys.argv[1], sys.argv[2]; os.makedirs(OUT, exist_ok=True)
TEMPO = float(sys.argv[sys.argv.index("--tempo") + 1]) if "--tempo" in sys.argv else 1.0
LINES = [  # id, words, cue (film seconds)
    ("V1", "Your AI agents never sleep.", 0.35),
    ("V2", "But they leave a mess.", 2.15),
    ("V3a", "Zombie processes.", 3.92),
    ("V3b", "Stale worktrees.", 5.26),
    ("V3c", "Gigabytes of build junk.", 6.42),
    ("V4", "BurnZombies burns it all, on its own.", 9.15),
    ("V5", "Every worktree is backed up first.", 11.2),
    ("V6", "Six hundred and eighty-five gigabytes, freed in two days.", 13.05),
    ("V7a", "You build.", 16.8),
    ("V7b", "We burn.", 17.7),
]


def norm(w):
    w = w.lower().replace("worktrees", "work trees").replace("worktree", "work tree").replace("burnzombies", "burn zombies")
    w = w.replace("six hundred and eighty-five", "685").replace("six hundred eighty-five", "685")
    return re.sub(r"[^a-z0-9 ]", " ", w).split()


x, sr = sf.read(TAKE)
if x.ndim == 2:
    x = x.mean(1)
TMP = tempfile.mkdtemp(prefix="bz-cut-")
tmp = os.path.join(TMP, "take16.wav")
subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", TAKE, "-ar", "16000", "-ac", "1", tmp], check=True)
subprocess.run(["whisper-cli", "-m", os.path.expanduser("~/.cache/whisper/ggml-base.en.bin"), "-f", tmp, "-ml", "1", "-sow",
                "-ocsv", "-of", os.path.join(TMP, "words"), "-np"], capture_output=True)
words = []
for row in open(os.path.join(TMP, "words.csv")).read().splitlines()[1:]:
    a, b, t = row.split(",", 2)
    t = t.strip().strip('"').strip()
    for tok in norm(t):
        words.append((tok, int(a) / 1000, int(b) / 1000))
hyp = [w for w, _, _ in words]
ref, owner = [], []
for i, (_, text, _) in enumerate(LINES):
    toks = norm(text); ref += toks; owner += [i] * len(toks)
sm = difflib.SequenceMatcher(a=ref, b=hyp, autojunk=False)
span = {}
for blk in sm.get_matching_blocks():
    for k in range(blk.size):
        i = owner[blk.a + k]; _, s, e = words[blk.b + k]
        lo, hi = span.get(i, (s, e)); span[i] = (min(lo, s), max(hi, e))
missing = [LINES[i][0] for i in range(len(LINES)) if i not in span]
if missing:
    sys.exit(f"could not find lines {missing} in the take")

# speech boundaries from the energy envelope (10 ms frames, dB under the take's peak)
hop = int(0.01 * sr)
fr = np.array([np.sqrt(np.mean(x[k:k + hop] ** 2)) for k in range(0, len(x) - hop, hop)])
db = 20 * np.log10(fr / fr.max() + 1e-9)
def frame(t): return max(0, min(len(db) - 1, int(t / 0.01)))
def speech_bounds(i):
    ws, we = span[i]
    prev_end = span[i - 1][1] if i else 0.0
    nxt = span[i + 1][0] if i + 1 < len(LINES) else len(x) / sr
    a = frame(max(prev_end, ws - 0.3))
    while a < frame(ws + 0.2) and db[a] < -38:
        a += 1
    b = frame(min(nxt - 0.03, we + 0.45))
    while b > frame(we - 0.3) and db[b] < -42:
        b -= 1
    return a * 0.01 - 0.03, b * 0.01 + 0.09

meta = []
for i, (lid, text, cue) in enumerate(LINES):
    s, e = speech_bounds(i)
    s = max(0.0, s)
    seg = x[int(s * sr):int(e * sr)].copy()
    f = int(0.006 * sr); seg[:f] *= np.linspace(0, 1, f); seg[-f * 4:] *= np.linspace(1, 0, f * 4)
    fn = os.path.join(OUT, f"{lid}.wav"); sf.write(fn, seg, sr)
    if TEMPO != 1.0:
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", fn, "-af", f"atempo={TEMPO}", fn + ".t.wav"], check=True)
        os.replace(fn + ".t.wav", fn); seg, _ = sf.read(fn)
    meta.append({"id": lid, "at": cue, "dur": round(len(seg) / sr, 3), "text": text})
json.dump(meta, open(os.path.join(OUT, "durations.json"), "w"), indent=1)
for a, b in zip(meta, meta[1:]):
    end = a["at"] + a["dur"]; flag = "  <-- runs into next cue" if end > b["at"] - 0.05 else ""
    print(f"{a['id']:4s} {a['at']:5.2f}-{end:5.2f}s ({a['dur']:.2f}s)  next {b['id']} at {b['at']:.2f}{flag}")
print(f"{meta[-1]['id']:4s} {meta[-1]['at']:5.2f}-{meta[-1]['at'] + meta[-1]['dur']:5.2f}s ({meta[-1]['dur']:.2f}s)")
