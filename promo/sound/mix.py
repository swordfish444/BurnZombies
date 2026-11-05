"""BurnZombies promo: music + effects from recorded, licensed Pixabay files (no synthesis), the
voice-over on its cues, a sidechain duck and a dialogue-first EQ. The encode step sets -14 LUFS.

    python mix.py <timeline.json> <events.json> <vo_dir> <sound-src dir> <out.wav>

Missing sources are fetched from Pixabay's CDN into <sound-src dir>/<id>/<id>.mp3 (Pixabay Content
License: free for commercial use, no attribution; the raw files may not be redistributed, so they are
never committed). Titles, authors and links are in ../licenses.md.

Cue fields: (pixabay id, source start s, length s, film time s, level dB under the source's own
peak, fade in s, fade out s, pan -1..1, speed). Each source is peak-normalised before its level.
Titles, authors and links are in licenses.md.
"""
import os, sys, json, subprocess, numpy as np, soundfile as sf
from scipy import signal

SR = 48000
T = json.load(open(sys.argv[1])); EV = json.load(open(sys.argv[2])); VO_DIR = sys.argv[3]; SRC = sys.argv[4]; OUT = sys.argv[5]
DUR = T["end"]; N = int(DUR * SR)
rng = np.random.default_rng(5)
_cache = {}
CDN = "https://cdn.pixabay.com/download/audio/"
SOURCES = {  # Pixabay id -> CDN path
    "330416": "2025/04/21/audio_ed6f0ed574.mp3",  # music: Brain Implant (Cyberpunk Sci-Fi Trailer Action Intro)
    "351337": "2025/05/29/audio_145c0e7b22.mp3",  # bubble pop
    "423717": "2025/10/21/audio_3880ed67e2.mp3",  # pop
    "346045": "2025/05/23/audio_024cb96743.mp3",  # whoosh riser
    "561960": "2026/07/04/audio_09b02518f9.mp3",  # fire ignite whoosh
    "123876": "2022/10/24/audio_75bc71dae3.mp3",  # trailer boom
    "370400": "2025/07/05/audio_44f058bfb5.mp3",  # bass boom
    "450456": "2025/12/12/audio_800c0ace20.mp3",  # deep sub drop
    "561961": "2026/07/04/audio_d512f856b7.mp3",  # big fire blast whoosh
    "628045": "2026/10/28/audio_a47f804c09.mp3",  # fire flame rush
    "584730": "2026/08/12/audio_28a8e5bbe7.mp3",  # crackling fire
    "487898": "2026/02/20/audio_547f040f5a.mp3",  # clear bell chime
    "384159": "2025/08/03/audio_b2e0617d43.mp3",  # glass tink
    "390309": "2025/08/15/audio_ef53277d11.mp3",  # swoosh riser reverb
}


def load(pid):
    path = f"{SRC}/{pid}/{pid}.mp3"
    if not os.path.exists(path):
        os.makedirs(os.path.dirname(path), exist_ok=True)
        subprocess.run(["curl", "-sfL", "-o", path, CDN + SOURCES[pid]], check=True)
    if pid not in _cache:
        raw = subprocess.run(["ffmpeg", "-v", "error", "-i", f"{SRC}/{pid}/{pid}.mp3", "-f", "f32le", "-ac", "2", "-ar", str(SR), "-"],
                             capture_output=True, check=True).stdout
        x = np.frombuffer(raw, dtype=np.float32).reshape(-1, 2).copy()
        _cache[pid] = x / (np.abs(x).max() + 1e-9)
    return _cache[pid]


def cue(buf, pid, src_start, length, at, level_db, fade_in=0.0, fade_out=0.05, pan=0.0, speed=1.0, lowpass=None):
    x = load(pid)
    a = int(src_start * SR); b = a + int(length * SR * speed)
    seg = x[a:b]
    if speed != 1.0:  # varispeed (pitch moves with speed), like a tape nudge
        seg = signal.resample(seg, max(1, int(len(seg) / speed)), axis=0)
    if lowpass:
        seg = signal.sosfiltfilt(signal.butter(4, lowpass, "low", fs=SR, output="sos"), seg, axis=0)
    n = len(seg); g = np.ones(n)
    fi, fo = int(fade_in * SR), int(fade_out * SR)
    if fi: g[:fi] *= np.linspace(0, 1, fi) ** 2
    if fo: g[-fo:] *= np.linspace(1, 0, fo) ** 2
    l, r = np.cos((pan + 1) * np.pi / 4) * np.sqrt(2), np.sin((pan + 1) * np.pi / 4) * np.sqrt(2)
    seg = seg * g[:, None] * (10 ** (level_db / 20)) * np.array([l, r])[None, :] if pan else seg * g[:, None] * (10 ** (level_db / 20))
    i = int(at * SR)
    if i < 0:
        seg = seg[-i:]; i = 0
    j = min(N, i + len(seg)); buf[i:j] += seg[: j - i]


music = np.zeros((N, 2)); fx = np.zeros((N, 2))
M = T["music"]; S_ = T["shots"]; imp = T["impact"]

# ---- score: "Brain Implant (Cyberpunk Sci-Fi Trailer Action Intro)" (330416)
# Its drop-out (9.7-10.0 s) sits under the cut to the wide shot and the skull's fall; its hit (10.12 s)
# lands on the impact. At the end-card cut it crossfades into the track's own ending, whose last
# accent (44.0 s) lands on "We burn."
end_from = M["end_from"]
cue(music, M["id"], M["offset"], end_from + 0.35, 0.0, -17, 0.25, 0.35)
cue(music, M["id"], end_from + M["end_offset"] - 0.05, DUR - end_from + 0.05, end_from - 0.05, -17, 0.3, 0.6)

# a softer top on the score: its glitch hits sit above 6 kHz, so shelve them 5 dB down
hi = signal.sosfiltfilt(signal.butter(4, 6000, "high", fs=SR, output="sos"), music, axis=0)
music = music - hi * (1 - 10 ** (-5 / 20))

# ride the score down 4 dB under the lines that follow the hit (its loudest stretch), back up for the counter
ride = np.ones(N)
def ramp(a, b, g0, g1):
    i, j = int(a * SR), int(b * SR); ride[i:j] = np.linspace(10 ** (g0 / 20), 10 ** (g1 / 20), j - i)
ramp(imp + 0.45, imp + 0.95, 0, -4); ride[int((imp + 0.95) * SR):int(S_["D"] * SR)] = 10 ** (-4 / 20); ramp(S_["D"], S_["D"] + 0.4, -4, 0)
music *= ride[:, None]

# the close: the score cuts out after "You build." so "We burn." lands in silence; the flare's hit rings out alone
VO_META = {m["id"]: m for m in json.load(open(f"{VO_DIR}/durations.json"))}
cut_at = VO_META["V7a"]["at"] + VO_META["V7a"]["dur"] + 0.04; back_at = T["flare"] - 0.02
i0, i1 = int(cut_at * SR), int((cut_at + 0.25) * SR)
music[i0:i1] *= np.linspace(1, 0, i1 - i0)[:, None]; music[i1:] = 0

# ---- the mess appears: a pop per item, pitch nudged so a pile never sounds like one sample
for e in EV["spawn"]:
    pan = max(-0.8, min(0.8, e["x"] / 4.0))
    if e["kind"] == "crate":
        cue(fx, "423717", 0.10, 0.4, e["t"] - 0.04, -22, 0.0, 0.1, pan, speed=rng.uniform(0.78, 0.9))
    else:
        cue(fx, "351337", 0.07, 0.4, e["t"] - 0.03, -21 if e["kind"] == "zombie" else -23, 0.0, 0.1, pan,
            speed=rng.uniform(0.85, 0.98) if e["kind"] == "zombie" else rng.uniform(1.05, 1.22))
# the horde groans, low, as we cut to it

# ---- into the wide shot: a riser that dies with the music's drop-out, the skull's fall, the impact
cue(fx, "346045", 0.0, 2.32, S_["C"] - 2.22, -22, 0.3, 0.06)
cue(fx, "561960", 0.0, 0.8, imp - 0.44, -9)
cue(fx, "123876", 0.0, 1.0, imp - 0.01, -11, 0.0, 0.6)
cue(fx, "584730", 20.0, 1.6, imp + 0.02, -26, 0.0, 0.9)  # real flame texture right after the hit
cue(fx, "370400", 0.12, 1.4, imp, -7, 0.0, 0.8)
cue(fx, "450456", 0.75, 1.6, imp + 0.01, -11, 0.01, 0.8)  # sub at full level from the first frame
cue(fx, "561961", 0.12, 1.0, imp, -9, 0.0, 0.5)
cue(fx, "628045", 0.0, 1.2, imp + 0.03, -14, 0.0, 0.6)

# ---- the burn: a crackle bed, a rush where each group ignites, a chime as the worktrees are saved
cue(fx, "584730", 2.0, T["chip_out"] - T["burn_zombies"] + 0.6, T["burn_zombies"], -31, 0.6, 0.9)
cue(fx, "628045", 0.0, 1.0, T["burn_zombies"], -21, 0.0, 0.4, -0.5)
cue(fx, "628045", 0.0, 0.8, T["burn_crates"], -26, 0.0, 0.4, 0.15)
cue(fx, "628045", 0.0, 1.1, T["burn_folders"], -25, 0.0, 0.5, 0.55)
V4_END = [m["at"] + m["dur"] for m in json.load(open(f"{VO_DIR}/durations.json")) if m["id"] == "V4"][0]
cue(fx, "487898", 0.0, 1.2, max(T["backup"] - 0.04, V4_END + 0.03), -15, 0.0, 0.5, 0.45)

# ---- the counter lands
cue(fx, "384159", 0.0, 1.2, T["counter1"] - 0.07, -14, 0.0, 0.4)

# ---- end card: a swoosh hides the music edit at the cut, then "We burn." gets the boom and the blast
cue(fx, "390309", 0.6, 1.5, end_from - 1.26, -17, 0.4, 0.25)
cue(fx, "450456", 0.75, DUR - T["flare"] + 0.05, T["flare"] - 0.01, -10, 0.01, 1.8)  # clean sub-drop under the flare
cue(fx, "370400", 0.12, 2.0, T["flare"], -9, 0.0, 1.2)
cue(fx, "561961", 0.12, 1.6, T["flare"], -14, 0.0, 0.5, lowpass=5000)

# ---- voice
vo = np.zeros((N, 2))
for m in json.load(open(f"{VO_DIR}/durations.json")):
    x, sr = sf.read(f"{VO_DIR}/{m['id']}.wav")
    if x.ndim == 2: x = x.mean(1)
    x = signal.resample_poly(x, SR, sr)
    x = signal.sosfilt(signal.butter(2, 75, "high", fs=SR, output="sos"), x)
    i = int(m["at"] * SR); j = min(N, i + len(x)); vo[i:j] += x[: j - i, None]
vo *= 0.5 / (np.abs(vo).max() + 1e-9)

# ---- sidechain: the bed dips up to 13 dB under the voice, with 60 ms attack and 350 ms release
env = np.abs(vo).max(1)
win = int(0.03 * SR); env = np.sqrt(np.convolve(env ** 2, np.ones(win) / win, mode="same"))
act = np.clip(env / (np.percentile(env[env > 1e-4], 90) + 1e-9), 0, 1)
gain = np.ones(N); g = 1.0; a_att = np.exp(-1 / (0.06 * SR)); a_rel = np.exp(-1 / (0.35 * SR))
target = 1 - act * (1 - 10 ** (-13 / 20))
act_s = np.convolve(act, np.ones(int(0.08 * SR)) / int(0.08 * SR), mode="same")
for k in range(0, N, 48):  # control rate 1 kHz
    tg = target[k]
    g = tg + (g - tg) * (a_att ** 48 if tg < g else a_rel ** 48)
    gain[k:k + 48] = g
# dialogue-first EQ: the score's speech band (160 Hz - 5 kHz) dips a further 6 dB while the voice speaks
fir = signal.firwin(2047, [160, 5000], pass_zero=False, fs=SR)
mid = np.stack([signal.fftconvolve(music[:, k], fir, mode="same") for k in (0, 1)], 1)
band = 1 - act_s * (1 - 10 ** (-6 / 20))
music = (music - mid) + mid * band[:, None]
bed = (music + fx) * gain[:, None]
mix = bed + vo
peak = np.abs(mix).max(); mix /= max(peak, 1e-9) / 0.89
sf.write(OUT, mix.astype(np.float32), SR, subtype="FLOAT")
sf.write(OUT.replace(".wav", "_bed.wav"), (bed / (max(peak, 1e-9) / 0.89)).astype(np.float32), SR, subtype="FLOAT")
sf.write(OUT.replace(".wav", "_vo.wav"), (vo / (max(peak, 1e-9) / 0.89)).astype(np.float32), SR, subtype="FLOAT")
sc_ = 1 / (max(peak, 1e-9) / 0.89)
sf.write(OUT.replace(".wav", "_music.wav"), (music * gain[:, None] * sc_).astype(np.float32), SR, subtype="FLOAT")
sf.write(OUT.replace(".wav", "_fx.wav"), (fx * gain[:, None] * sc_).astype(np.float32), SR, subtype="FLOAT")
print("wrote", OUT)
