"""Blind listening judges for the TTS bake-off (audio-capable models on OpenRouter).
Usage: python judge.py <bake_dir> <out.json> [judge_model ...]
"""
import sys, os, json, glob, base64, re, subprocess, urllib.request, urllib.error, random
from concurrent.futures import ThreadPoolExecutor

BAKE, OUT = sys.argv[1], sys.argv[2]
JUDGES = sys.argv[3:] or ["~google/gemini-pro-latest", "openai/gpt-audio"]
KEY = os.environ.get("OPENROUTER_API_KEY") or open(os.path.expanduser("~/.config/bz-video/gemini.key")).read().strip()
SCRIPT = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "bakeoff.py")).read().split('SCRIPT = """')[1].split('"""')[0]

PROMPT = """You are a senior casting director and audio producer for premium tech product commercials.
Listen to this voiceover take for a 20-second launch video of BurnZombies, a macOS menu-bar app that automatically
cleans up after AI coding agents (zombie processes, stale git worktrees, build junk).

Desired delivery: warm, confident, unhurried premium commercial voiceover; a seasoned engineer talking to another
engineer; grounded mid-low register; a slight knowing smile; clear and natural; never hype; clean pauses between
sentences; "You build. We burn." landed with quiet confidence.

Script:
""" + SCRIPT + """

Score each from 1 to 10 (10 = a top brand would ship it as is), being strict and using the whole range:
naturalness (sounds like a real person, no robotic or synthetic artifacts), delivery_fit (matches the desired
delivery above), clarity (every word intelligible and correctly pronounced, including "BurnZombies" and
"worktrees"), pacing (unhurried yet right for a 20-second spot), premium (production polish and appeal), overall.
List concrete problems with approximate timestamps (glitches, mispronunciations, wrong emphasis, odd pauses,
added or missing words). Reply with JSON only:
{"naturalness":n,"delivery_fit":n,"clarity":n,"pacing":n,"premium":n,"overall":n,"problems":["..."],"verdict":"one sentence"}"""


def mp3(path):
    out = path.replace(".n.wav", ".judge.mp3")
    if not os.path.exists(out):
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", path, "-b:a", "128k", out], check=True)
    return base64.b64encode(open(out, "rb").read()).decode()


def ask(judge, take, data):
    body = {"model": judge, "temperature": 0.2,
            "messages": [{"role": "user", "content": [
                {"type": "text", "text": PROMPT},
                {"type": "input_audio", "input_audio": {"data": data, "format": "mp3"}}]}]}
    if judge.startswith("openai/gpt-audio"):
        body["modalities"] = ["text"]
    req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=240) as r:
            resp = json.load(r)
        text = resp["choices"][0]["message"]["content"] or ""
        m = re.search(r"\{.*\}", text, re.S)
        if not m:
            return {"take": take, "judge": judge, "error": "no JSON: " + text[:160].replace("\n", " ")}
        return {"take": take, "judge": judge, **json.loads(m.group(0))}
    except Exception as e:  # keep going; report the failure
        msg = e.read().decode()[:200] if isinstance(e, urllib.error.HTTPError) else str(e)[:200]
        return {"take": take, "judge": judge, "error": msg}


takes = sorted(glob.glob(os.path.join(BAKE, "*.n.wav")))
if os.environ.get("ONLY"):
    takes = [t for t in takes if any(o in t for o in os.environ["ONLY"].split(","))]
blind = {os.path.basename(t)[:-6]: mp3(t) for t in takes}
jobs = [(j, k, v) for j in JUDGES for k, v in blind.items()]
random.Random(3).shuffle(jobs)
with ThreadPoolExecutor(8) as ex:
    res = list(ex.map(lambda a: ask(*a), jobs))
json.dump(res, open(OUT, "w"), indent=1)
for r in sorted(res, key=lambda r: (r["take"], r["judge"])):
    if "error" in r:
        print(f"{r['take']:46s} {r['judge'][:22]:22s} ERROR {r['error'][:90]}")
    else:
        print(f"{r['take']:46s} {r['judge'][:22]:22s} nat {r['naturalness']} fit {r['delivery_fit']} clar {r['clarity']} pace {r['pacing']} prem {r['premium']} ALL {r['overall']}")
