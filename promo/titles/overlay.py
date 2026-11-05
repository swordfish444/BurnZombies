"""2D kinetic type composited over the Blender frames.
Usage: python overlay.py <frames_dir> <out_dir> [--scale 0.5] [--only 120,260]
Coordinates and sizes are authored at 1920x1080 and scaled.
"""
import sys, os, json, math, glob
from PIL import Image, ImageDraw, ImageFont, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
T = json.load(open(os.path.join(HERE, "..", "timeline.json")))
VO_DIR = os.path.join(HERE, "..", "narration", "lines")
VO = {m["id"]: m for m in json.load(open(os.path.join(VO_DIR, "durations.json")))}
WORDS = json.load(open(os.path.join(VO_DIR, "words.json")))


def wl(vo_id, labels, first=0):
    """Pair the overlay's words with the spoken words' start times (ms), skipping `first` spoken words."""
    spoken = WORDS[vo_id][first:]
    return [(lab, int(w[1] * 1000)) for lab, w in zip(labels, spoken)]


def said(vo_id, word):
    for w, a, b in WORDS[vo_id]:
        if w.lower().strip(".,").startswith(word):
            return VO[vo_id]["at"] + a
    return VO[vo_id]["at"]
FPS = 30
ANTON = os.path.normpath(os.path.join(HERE, "..", "..", "Sources", "BurnApp", "Resources", "Anton-Regular.ttf"))
INTER_SEMI = os.path.join(HERE, "fonts", "InterDisplay-SemiBold.ttf")
INTER_BOLD = os.path.join(HERE, "fonts", "InterDisplay-Bold.ttf")
CREAM = (246, 239, 220); ORANGE = (255, 90, 31); DIM = (196, 188, 172)

src, dst = sys.argv[1], sys.argv[2]
SC = float(sys.argv[sys.argv.index("--scale") + 1]) if "--scale" in sys.argv else 1.0
ONLY = None
if "--only" in sys.argv:
    ONLY = [int(x) for x in sys.argv[sys.argv.index("--only") + 1].split(",")]
os.makedirs(dst, exist_ok=True)

_fonts = {}
def font(kind, px):
    key = (kind, px)
    if key not in _fonts:
        if kind == "anton":
            _fonts[key] = ImageFont.truetype(ANTON, px)
        else:
            _fonts[key] = ImageFont.truetype(INTER_BOLD if kind == "sfb" else INTER_SEMI, px)
    return _fonts[key]


def ease_out_cubic(u): return 1 - (1 - u) ** 3
def ease_out_back(u, s=1.6): u -= 1; return 1 + u * u * ((s + 1) * u + s)
def clamp(u): return max(0.0, min(1.0, u))


def render_runs(runs, kind, px, tracking=0.0, shadow=True):
    """runs: [(text, rgb)] -> RGBA image of the line (with soft shadow) and per-run x offsets."""
    f = font(kind, int(px * SC))
    tr = tracking * SC
    widths = []
    for text, _ in runs:
        w = sum(f.getlength(ch) + tr for ch in text) if tr else f.getlength(text)
        widths.append(w)
    W = int(sum(widths)) + int(40 * SC); asc, desc = f.getmetrics(); H = asc + desc + int(40 * SC)
    pad = int(20 * SC)
    img = Image.new("RGBA", (W + pad * 2, H + pad * 2), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    x = pad + int(20 * SC); offsets = []
    for (text, rgb), w in zip(runs, widths):
        offsets.append(x)
        if tr:
            xx = x
            for ch in text:
                d.text((xx, pad + int(10 * SC)), ch, font=f, fill=rgb + (255,))
                xx += f.getlength(ch) + tr
        else:
            d.text((x, pad + int(10 * SC)), text, font=f, fill=rgb + (255,))
        x += w
    bbox = img.getbbox()
    if shadow:
        a = img.split()[3].filter(ImageFilter.GaussianBlur(10 * SC))
        sh = Image.new("RGBA", img.size, (8, 5, 4, 0)); sh.putalpha(a.point(lambda v: int(v * 0.75)))
        out = Image.alpha_composite(sh, img)
    else:
        out = img
    return out, bbox


class El:
    def __init__(self, runs, kind, px, x, y, t_in, t_out, anchor="mm", anim="rise", tracking=0.0, dyn=None, word_times=None, plate=False):
        self.runs, self.kind, self.px, self.x, self.y, self.plate = runs, kind, px, x, y, plate
        self.t_in, self.t_out, self.anchor, self.anim, self.tracking = t_in, t_out, anchor, anim, tracking
        self.dyn, self.word_times = dyn, word_times
        self.cache = None

    def image(self, t):
        if self.dyn:
            return render_runs(self.dyn(t), self.kind, self.px, self.tracking)
        if self.cache is None:
            self.cache = render_runs(self.runs, self.kind, self.px, self.tracking)
        return self.cache

    def draw(self, frame, t):
        if t < self.t_in or t > self.t_out + 0.25:
            return
        img, bbox = self.image(t)
        u_in = clamp((t - self.t_in) / 0.3)
        u_out = clamp((t - self.t_out) / 0.2)
        alpha = ease_out_cubic(u_in) * (1 - u_out)
        dy = 0.0; scale = 1.0
        if self.plate and bbox:
            # a soft dark plate behind the ink, so light text holds over bright 3D
            x0, y0, x1, y1 = bbox; pad = int(18 * SC)
            pl = Image.new("RGBA", img.size, (0, 0, 0, 0)); ImageDraw.Draw(pl).rounded_rectangle(
                [x0 - pad, y0 - pad * 0.7, x1 + pad, y1 + pad * 0.7], radius=int(14 * SC), fill=(8, 5, 4, 150))
            img = Image.alpha_composite(pl.filter(ImageFilter.GaussianBlur(6 * SC)), img)
        if self.anim == "rise":
            dy = (1 - ease_out_cubic(u_in)) * 34
        elif self.anim == "pop":
            scale = 0.82 + 0.18 * ease_out_back(clamp((t - self.t_in) / 0.32))
        if self.word_times:  # reveal word by word: mask columns beyond the current word
            img = self.reveal(img, t)
        if scale != 1.0:
            img = img.resize((max(1, int(img.width * scale)), max(1, int(img.height * scale))), Image.LANCZOS)
        if alpha < 1.0:
            a = img.split()[3].point(lambda v: int(v * alpha)); img = img.copy(); img.putalpha(a)
        cx, cy = self.x * SC, (self.y + dy) * SC
        ax = {"l": 0.0, "m": 0.5, "r": 1.0}[self.anchor[0]]; ay = {"t": 0.0, "m": 0.5, "b": 1.0}[self.anchor[1]]
        # anchor on the ink box, not the padded canvas
        bx0, by0, bx1, by1 = bbox if bbox else (0, 0, img.width, img.height)
        bx0, by0, bx1, by1 = [v * scale for v in (bx0, by0, bx1, by1)]
        px = int(cx - (bx0 + (bx1 - bx0) * ax)); py = int(cy - (by0 + (by1 - by0) * ay))
        frame.alpha_composite(img, (max(0, px), max(0, py)), (max(0, -px), max(0, -py)))

    def reveal(self, img, t):
        # word_times: list of (x_end_fraction, time) ; show ink up to the last word whose time has passed, with a soft edge
        frac = 0.0
        for xe, wt in self.word_times:
            if t >= wt:
                frac = max(frac, xe + 0.0)
            else:
                # partially reveal the word that is just starting (0.12 s wipe)
                pass
        frac = max(frac, 0.0)
        out = img.copy()
        W = img.width
        cut = int(W * frac)
        a = out.split()[3]
        mask = Image.new("L", img.size, 0)
        ImageDraw.Draw(mask).rectangle([0, 0, cut, img.height], fill=255)
        mask = mask.filter(ImageFilter.GaussianBlur(6 * SC))
        from PIL import ImageChops
        out.putalpha(ImageChops.multiply(a, mask))
        return out


class Img:
    def __init__(self, path, x, y, height, t_in, t_out):
        im = Image.open(path).convert("RGBA"); h = int(height * SC); w = int(im.width * h / im.height)
        im = im.resize((w, h), Image.LANCZOS)
        pad = int(40 * SC); base = Image.new("RGBA", (w + 2 * pad, h + 2 * pad), (0, 0, 0, 0))
        sh = Image.new("RGBA", base.size, (0, 0, 0, 0)); ox, oy = pad + int(8 * SC), pad + int(14 * SC); sh.paste((4, 3, 2, 170), (ox, oy, ox + w, oy + h), mask=im.split()[3])
        base = Image.alpha_composite(sh.filter(ImageFilter.GaussianBlur(18 * SC)), base); base.alpha_composite(im, (pad, pad))
        self.img, self.pad, self.x, self.y, self.t_in, self.t_out = base, pad, x, y, t_in, t_out

    def draw(self, frame, t):
        if t < self.t_in or t > self.t_out + 0.25:
            return
        u = ease_out_cubic(clamp((t - self.t_in) / 0.4)); a = u * (1 - clamp((t - self.t_out) / 0.2))
        img = self.img.copy(); img.putalpha(img.split()[3].point(lambda v: int(v * a)))
        px = int(self.x * SC + (1 - u) * 70 * SC) - self.pad; py = int(self.y * SC) - self.pad
        frame.alpha_composite(img, (max(0, px), max(0, py)))


def words_reveal(runs, kind, px, vo_id, words, tracking=0.0):
    """Map each word to its spoken time; returns [(x_end_fraction, time)]."""
    full = "".join(t for t, _ in runs)
    f = font(kind, int(px * SC)); pad = int(20 * SC) + int(20 * SC)
    img, _ = render_runs(runs, kind, px, tracking)
    W = img.width
    out = []; pos = 0
    for w, ms in words:
        i = full.upper().find(w.upper(), pos)
        if i < 0:
            continue
        pos = i + len(w)
        x_end = pad + f.getlength(full[:pos]) + 6 * SC
        out.append((x_end / W, VO[vo_id]["at"] + ms / 1000.0 - 0.04))
    return out


S_ = T["shots"]; L_ = T["labels"]
els = []
# Shot A: the hook, word by word with the VO, top centre
r1 = [("YOUR AI AGENTS ", CREAM), ("NEVER SLEEP.", ORANGE)]
els.append(El(r1, "anton", 96, 960, 150, VO["V1"]["at"], VO["V2"]["at"] - 0.12, "mm", "rise", 1.0,
              word_times=words_reveal(r1, "anton", 96, "V1", wl("V1", ["YOUR", "AI", "AGENTS", "NEVER", "SLEEP."]), 1.0)))
r2 = [("BUT THEY LEAVE A ", CREAM), ("MESS.", ORANGE)]
els.append(El(r2, "anton", 96, 960, 150, VO["V2"]["at"], S_["B1"] - 0.05, "mm", "rise", 1.0,
              word_times=words_reveal(r2, "anton", 96, "V2", wl("V2", ["BUT", "THEY", "LEAVE", "A", "MESS."]), 1.0)))
# Shots B: labels, lower left
for key, title, sub, t_end in (("zombies", "ZOMBIE PROCESSES", "Still running after the chat is gone", S_["B2"]),
                               ("worktrees", "STALE WORKTREES", "Copies of your repo nothing uses any more", S_["B3"]),
                               ("junk", "BUILD JUNK", "node_modules · DerivedData · build output", S_["C"])):
    els.append(El([(title, CREAM)], "anton", 124, 112, 860, L_[key], t_end - 0.12, "lb", "rise", 1.5))
    els.append(El([(sub, CREAM)], "sf", 36, 116, 920, L_[key] + 0.12, t_end - 0.12, "lt", "rise", plate=True))
# Shot C: what BZ does
r4 = [("BURNS IT ALL. ", CREAM), ("ON ITS OWN.", ORANGE)]
V4_END = VO["V4"]["at"] + max(w[2] for w in WORDS["V4"])
els.append(El(r4, "anton", 88, 960, 960, said("V4", "burns") - 0.1, V4_END + 0.2, "mm", "rise", 1.0,
              word_times=words_reveal(r4, "anton", 88, "V4", wl("V4", ["BURNS", "IT", "ALL.", "ON", "ITS", "OWN."], first=2), 1.0)))
# Shot D: the proof
GB = 685.6
def counter_runs(t):
    u = clamp((t - T["counter0"]) / (T["counter1"] - T["counter0"]))
    v = GB * ease_out_cubic(u)
    return [(f"{v:.1f}", CREAM), (" GB", CREAM)]
els.append(El(None, "anton", 218, 830, 548, T["counter0"] - 0.15, S_["E"] - 0.1, "mm", "pop", 2.0, dyn=counter_runs))
els.append(El([("FREED IN 2 DAYS", ORANGE)], "anton", 72, 830, 730, said("V6", "freed") - 0.05, S_["E"] - 0.1, "mm", "rise", 3.0))
els.append(El([("and 453 stale worktrees cleaned, on the author's Mac", DIM)], "sf", 32, 830, 792, said("V6", "freed") + 0.35, S_["E"] - 0.1, "mm", "rise"))
PANEL = os.path.normpath(os.path.join(HERE, "..", "..", "docs", "media", "panel-real.png"))
els.append(Img(PANEL, 1478, 452, 470, said("V6", "freed") - 0.05, S_["E"] - 0.1))
els.append(El([("The real menu-bar panel", DIM)], "sf", 24, 1632, 948, said("V6", "freed") + 0.25, S_["E"] - 0.1, "mm", "rise"))
# Shot C2: how the backup works
els.append(El([("Every commit and uncommitted change is saved to a Git ref first. Restore in one click.", CREAM)], "sf", 34, 960, 1006,
              T["backup"] + 0.35, S_["D"] - 0.15, "mm", "rise", plate=True))
# Shot E: end card
els.append(El([("BURNZOMBIES", CREAM)], "anton", 120, 960, 128, T["title"], 99, "mm", "pop", 4.0))
els.append(El([("YOU BUILD.", CREAM)], "anton", 104, 948, 952, VO["V7a"]["at"], 99, "rm", "pop", 1.5))
els.append(El([("WE BURN.", ORANGE)], "anton", 104, 972, 952, VO["V7b"]["at"], 99, "lm", "pop", 1.5))
els.append(El([("Free and open source  ·  lives in your Mac's menu bar", DIM)], "sf", 32, 960, 1032, VO["V7b"]["at"] + 0.55, 99, "mm", "rise"))


def vignette(size, strength=0.55):
    w, h = size
    v = Image.new("L", (w, h), 0); d = ImageDraw.Draw(v)
    # top & bottom bands to keep type legible
    for i in range(h):
        y = i / h
        a = max(0.0, 0.32 - y) / 0.32 * 0.55 + max(0.0, y - 0.72) / 0.28 * 0.6
        d.line([(0, i), (w, i)], fill=int(255 * a * strength / 0.55))
    return v


POSTER = sys.argv[sys.argv.index("--poster") + 1] if "--poster" in sys.argv else None


def make_poster(base_png):
    fr = Image.open(base_png).convert("RGBA")
    if fr.size != (int(1920 * SC), int(1080 * SC)):
        fr = fr.resize((int(1920 * SC), int(1080 * SC)), Image.LANCZOS)
    v = vignette(fr.size, 0.75); dark = Image.new("RGBA", fr.size, (6, 4, 3, 255))
    fr = Image.alpha_composite(fr, Image.merge("RGBA", (*dark.split()[:3], v)))
    for e in (El([("RUN YOUR AGENTS ", CREAM), ("FOREVER.", ORANGE)], "anton", 124, 960, 132, -1, 99, "mm", "none", 1.5),
              El([("A free Mac menu-bar app that cleans up after Claude Code, Codex and Cursor.", CREAM)], "sfb", 38, 960, 222, -1, 99, "mm", "none"),
              El([("Zombie processes  ·  stale worktrees  ·  build junk", DIM)], "sf", 32, 960, 1010, -1, 99, "mm", "none")):
        e.draw(fr, 0.5)
    return fr


frames = sorted(glob.glob(os.path.join(src, "f_*.png")))
vig = None
for fp in frames:
    n = int(os.path.basename(fp)[2:-4])
    if ONLY and n not in ONLY:
        continue
    t = (n - 1) / FPS
    if n == 1 and POSTER:
        make_poster(POSTER).convert("RGB").save(os.path.join(dst, os.path.basename(fp)), compress_level=1)
        continue
    fr = Image.open(fp).convert("RGBA")
    if vig is None:
        vig = vignette(fr.size)
        dark = Image.new("RGBA", fr.size, (6, 4, 3, 255))
        band = Image.new("L", fr.size, 0); bd = ImageDraw.Draw(band)
        for i in range(int(fr.size[1] * 0.36)):
            bd.line([(0, i), (fr.size[0], i)], fill=int(170 * (1 - i / (fr.size[1] * 0.36)) ** 1.3))
    fr = Image.alpha_composite(fr, Image.merge("RGBA", (*dark.split()[:3], vig)))
    # the opening headline sits over the bright terminal close-up: a darker top band until the camera pulls back
    if t < 2.4:
        k = 1.0 if t < 2.0 else (2.4 - t) / 0.4
        fr = Image.alpha_composite(fr, Image.merge("RGBA", (*dark.split()[:3], band.point(lambda v: int(v * k)))))
    for e in els:
        e.draw(fr, t)
    fr.convert("RGB").save(os.path.join(dst, os.path.basename(fp)), compress_level=1)
print("done", len(frames))
