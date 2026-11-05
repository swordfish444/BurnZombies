"""First-time viewers for the finished film: video-capable models on OpenRouter watch it with sound.
Usage: python review.py <film.mp4> [model ...]
"""
import os, sys, json, re, base64, urllib.request
from concurrent.futures import ThreadPoolExecutor

FILM = sys.argv[1]
MODELS = sys.argv[2:] or ["google/gemini-4-argon", "moonshotai/kimi-k3.1-pro"]
KEY = os.environ.get("OPENROUTER_API_KEY") or open(os.path.expanduser("~/.config/bz-video/gemini.key")).read().strip()
PERSONAS = {
    "skimmer": "a developer who just landed on this GitHub repo from a link, skims for five seconds, and presses play on the video at the top of the README with sound on",
    "agent_user": "an engineer who runs many Claude Code and Codex sessions in parallel every day and whose Mac keeps running out of disk",
    "skeptic": "a security-minded senior engineer who distrusts tools that delete files on their own",
}
PROMPT = """You are {who}. Watch this video, which sits at the very top of the BurnZombies README on GitHub.
BurnZombies is a free, open-source macOS menu-bar app that cleans up after AI coding agents: it stops orphaned
processes and deletes stale git worktrees and rebuildable junk, backing up every worktree first.
Answer honestly as that person. Score 1-10: hook (first 5 seconds), clarity (do you understand what it does),
excitement (do you want it), trust (do you trust it with your files), production (does it look and sound premium),
install_intent. Then list the three changes that would most improve it, with timestamps. Reply with JSON only:
{{"hook":n,"clarity":n,"excitement":n,"trust":n,"production":n,"install_intent":n,"what_it_does":"one sentence in your words","fixes":["..."],"verdict":"..."}}"""

data = "data:video/mp4;base64," + base64.b64encode(open(FILM, "rb").read()).decode()


def ask(job):
    model, persona = job
    body = {"model": model, "temperature": 0.3, "messages": [{"role": "user", "content": [
        {"type": "text", "text": PROMPT.format(who=PERSONAS[persona])},
        {"type": "video_url", "video_url": {"url": data}}]}]}
    req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", data=json.dumps(body).encode(),
                                 headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
    try:
        t = json.load(urllib.request.urlopen(req, timeout=300))["choices"][0]["message"]["content"] or ""
        m = re.search(r"\{.*\}", t, re.S)
        return model, persona, (json.loads(m.group(0)) if m else {"raw": t[:300]})
    except Exception as e:
        return model, persona, {"error": (e.read().decode()[:200] if hasattr(e, "read") else str(e)[:200])}


with ThreadPoolExecutor(6) as ex:
    results = list(ex.map(ask, [(m, p) for m in MODELS for p in PERSONAS]))
json.dump([{"model": m, "persona": p, **r} for m, p, r in results], open(FILM + ".review.json", "w"), indent=1)
for m, p, r in results:
    if "error" in r or "raw" in r:
        print(f"{m:28s} {p:11s} {r}")
        continue
    print(f"{m:28s} {p:11s} hook {r['hook']} clarity {r['clarity']} excite {r['excitement']} trust {r['trust']} prod {r['production']} install {r['install_intent']}")
    print(f"    sees: {r.get('what_it_does', '')[:150]}")
    for f in r.get("fixes", [])[:3]:
        print(f"    - {f[:170]}")
