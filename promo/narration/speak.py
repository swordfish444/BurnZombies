"""Final narration takes: Gemini 3.8 Flash TTS (Umbriel) over OpenRouter, the bake-off winner."""
import sys, os, json, subprocess, urllib.request
from concurrent.futures import ThreadPoolExecutor
OUT = sys.argv[1]; N = int(sys.argv[2]) if len(sys.argv) > 2 else 3; VOICE = sys.argv[3] if len(sys.argv) > 3 else "Umbriel"
os.makedirs(OUT, exist_ok=True)
KEY = os.environ.get("OPENROUTER_API_KEY") or open(os.path.expanduser("~/.config/bz-video/gemini.key")).read().strip()
SCRIPT = """Your AI agents never sleep.
But they leave a mess.
Zombie processes. Stale worktrees. Gigabytes of build junk.
BurnZombies burns it all, on its own.
Every worktree is backed up first.
Six hundred and eighty-five gigabytes, freed in two days.
You build. We burn."""
STYLE = ("Warm, confident premium commercial voiceover for a developer tool. A seasoned engineer talking to another "
         "engineer: grounded mid-low register, a slight knowing smile, clear and natural, never hype. Keep it moving: "
         "about 2.7 words per second, with short, clean pauses of about half a second between sentences and a brief beat "
         "between 'Zombie processes.', 'Stale worktrees.' and 'Gigabytes of build junk.' Say 'worktree' and 'worktrees' "
         "as one word with the stress on 'work', like 'workflow'. Say 'BurnZombies' as one brand name, stress on 'Zom'. "
         "End 'You build.' and 'We burn.' with a falling, final intonation: quiet confidence, not a question.")
def one(i):
    body = {"model": "google/gemini-3.8-flash-tts", "input": SCRIPT, "voice": VOICE, "response_format": "pcm", "instructions": STYLE}
    req = urllib.request.Request("https://openrouter.ai/api/v1/audio/speech", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    data = urllib.request.urlopen(req, timeout=180).read()
    raw = os.path.join(OUT, f"{VOICE}_take{i}.pcm"); open(raw, "wb").write(data)
    wav = raw.replace(".pcm", ".n.wav")
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "s16le", "-ar", "24000", "-ac", "1", "-i", raw, wav], check=True)
    return wav, round(len(data) / 48000, 2)
with ThreadPoolExecutor(N) as ex:
    for wav, sec in ex.map(one, range(1, N + 1)):
        print(os.path.basename(wav), sec, "s")
