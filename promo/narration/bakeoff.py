"""TTS bake-off over OpenRouter's /audio/speech: one full-script take per (model, voice).
Usage: python bakeoff.py <out_dir> [--only substr]
The key is read from ~/.config/bz-video/gemini.key and never printed.
"""
import sys, os, json, subprocess, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

OUT = sys.argv[1]; os.makedirs(OUT, exist_ok=True)
ONLY = sys.argv[sys.argv.index("--only") + 1] if "--only" in sys.argv else None
KEY = os.environ.get("OPENROUTER_API_KEY") or open(os.path.expanduser("~/.config/bz-video/gemini.key")).read().strip()

SCRIPT = """Your AI agents never sleep.
But they leave a mess.
Zombie processes. Stale worktrees. Gigabytes of build junk.
BurnZombies burns it all, on its own.
Every worktree is backed up first.
Six hundred and eighty-five gigabytes, freed in two days.
You build. We burn."""

STYLE = ("Warm, confident, unhurried premium commercial voiceover for a developer tool. A seasoned engineer talking "
         "to another engineer: grounded mid-low register, a slight knowing smile, clear and natural, never hype. "
         "Clean pauses between sentences, and a short beat between 'Zombie processes.', 'Stale worktrees.' and "
         "'Gigabytes of build junk.' Land the last line, 'You build. We burn.', with quiet confidence.")

TAKES = [("google/gemini-3.8-flash-tts", v) for v in ("Algieba", "Charon", "Orus", "Achird", "Umbriel")] + \
        [("microsoft/mai-voice-2.1", v) for v in ("en-US-Grant:MAI-Voice-2.1", "en-US-Jasper:MAI-Voice-2.1", "en-US-Ethan:MAI-Voice-2.1")] + \
        [("elevenlabs/eleven-v4", v) for v in ("brian", "adam", "george", "roger")] + \
        [("minimax/speech-2.8-hd", v) for v in ("English_expressive_narrator", "English_magnetic_voiced_man", "English_Trustworth_Man", "English_Deep-VoicedGentleman")]


def name(model, voice):
    return f"{model.split('/')[1]}__{voice.split(':')[0]}"


def take(mv):
    model, voice = mv
    body = {"model": model, "input": SCRIPT, "voice": voice, "response_format": "pcm" if "gemini" in model else "mp3", "instructions": STYLE}
    req = urllib.request.Request("https://openrouter.ai/api/v1/audio/speech", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            data = r.read(); ctype = r.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        return {"take": name(model, voice), "error": f"HTTP {e.code}: {e.read().decode()[:200]}"}
    ext = "wav" if "wav" in ctype else ("mp3" if "mpeg" in ctype or "mp3" in ctype else "bin")
    raw = os.path.join(OUT, name(model, voice) + "." + ext)
    open(raw, "wb").write(data)
    wav = os.path.join(OUT, name(model, voice) + ".n.wav")
    fmt = [] if ext != "bin" else ["-f", "s16le", "-ar", "24000", "-ac", "1"]
    subprocess.run(["ffmpeg", "-v", "error", "-y", *fmt, "-i", raw, "-ac", "1", "-ar", "24000", wav], check=True)
    dur = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", wav],
                               capture_output=True, text=True).stdout or 0)
    return {"take": name(model, voice), "ctype": ctype, "sec": round(dur, 2), "bytes": len(data)}


todo = [t for t in TAKES if not ONLY or ONLY in name(*t)]
with ThreadPoolExecutor(6) as ex:
    for res in ex.map(take, todo):
        print(json.dumps(res), flush=True)
