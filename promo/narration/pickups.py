"""Several Umbriel takes of single lines, for pickups. Usage: python line_takes.py <out_dir> <n> <id>=<text> ..."""
import sys, os, json, subprocess, urllib.request
from concurrent.futures import ThreadPoolExecutor
OUT = sys.argv[1]; N = int(sys.argv[2]); LINES = [a.split("=", 1) for a in sys.argv[3:]]
os.makedirs(OUT, exist_ok=True)
KEY = os.environ.get("OPENROUTER_API_KEY") or open(os.path.expanduser("~/.config/bz-video/gemini.key")).read().strip()
STYLE = ("Warm, confident premium commercial voiceover for a developer tool. A seasoned engineer talking to another "
         "engineer: grounded mid-low register, a slight knowing smile, clear and natural, never hype. This line is a "
         "flat, declarative statement that closes a thought: the pitch steps DOWN on the last word and lands low and "
         "final, like a period. Never lift the end, never sound like a question or a list that continues.")
def one(job):
    lid, text, i = job
    body = {"model": "google/gemini-3.8-flash-tts", "input": text, "voice": "Umbriel", "response_format": "pcm", "instructions": STYLE}
    req = urllib.request.Request("https://openrouter.ai/api/v1/audio/speech", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    data = urllib.request.urlopen(req, timeout=120).read()
    raw = os.path.join(OUT, f"{lid}_{i}.pcm"); open(raw, "wb").write(data)
    wav = raw.replace(".pcm", ".wav")
    # trim leading/trailing silence
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "s16le", "-ar", "24000", "-ac", "1", "-i", raw, "-af",
                    "silenceremove=start_periods=1:start_threshold=-45dB:start_silence=0.03,areverse,silenceremove=start_periods=1:start_threshold=-48dB:start_silence=0.09,areverse", wav], check=True)
    return wav
jobs = [(lid, text, i) for lid, text in LINES for i in range(1, N + 1)]
with ThreadPoolExecutor(8) as ex:
    for w in ex.map(one, jobs):
        print(w)
