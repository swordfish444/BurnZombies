# The README film

The 24.5-second film at the top of the [README](../README.md): 1920 × 1080, 30 fps, H.264 + AAC at −14 LUFS. It is rendered entirely in 3D with Blender, and every part of it is a script here, so any frame, line or sound can be rebuilt from this folder.

| Time | Shot | What it says |
| --- | --- | --- |
| 0.0–4.6 s | Agents at work, the mess piling up | "Your AI agents never sleep. But they leave a mess." |
| 4.6–9.6 s | Zombies, worktrees, build junk, the disk at 98% | "Zombie processes. Stale worktrees. Gigabytes of build junk." |
| 9.6–16.2 s | The skull lands, the junk burns, worktrees are saved first | "BurnZombies burns it all, on its own. Every worktree is backed up first." |
| 16.2–20.3 s | The disk drains, 685.6 GB counts up | "Six hundred and eighty-five gigabytes, freed in two days." |
| 20.3–24.5 s | End card | "You build. We burn." |

The 685.6 GB and 453 worktrees are the author's first two days of Autopilot (November 2–4, 2026), the same totals as the README; the film says so on screen.

## Layout

```
timeline.json        every cue in seconds: shots, spawns, impact, burns, counter, titles, music offsets
scene/build.py       the whole film as one Blender scene: stage, laptop, junk, gauge, skull, cameras
scene/bzkit.py       helpers: Cycles setup, SVG icons, burn shader, embers, dust, bloom and dispersion
scene/art/           the skull traced from Sources/BurnApp/Resources/EmberSkull.png, zombie and folder icons,
                     the laptop screen (screen.html, rendered to screen.png with headless Chrome)
titles/overlay.py    the titles layer, composited over the frames; frame 1 becomes the poster
titles/fonts/        Inter Display (SIL Open Font License); Anton comes from Sources/BurnApp/Resources
narration/lines/     the ten narration lines placed in the film, with their cues and word times
narration/*.py       how they were made: the TTS bake-off, the takes, pickups and the cutter
sound/mix.py         score and effects from recorded Pixabay files, ducked under the voice
make.sh              everything above, in order
```

## Rebuild

Needs Blender 5.2 (`brew install --cask blender`), ffmpeg, whisper-cpp for the narration tools, and Python 3 with numpy, scipy, soundfile and Pillow.

```sh
promo/make.sh
```

Output goes to `promo/build/` (ignored by Git). The 3D render is the slow part: about 6–9 s a frame on an M4 Max at 128 samples. To split it across Macs, render frame ranges anywhere the folder and Blender 5.2.3 exist, then copy the PNGs into one `build/frames/`:

```sh
FRAMES=1-370 promo/make.sh render     # on one Mac
FRAMES=371-736 promo/make.sh render   # on another
promo/make.sh finish                  # titles, sound and encode, once all frames are in
```

Draft a few frames small before a full render:

```sh
blender -b --factory-startup -P promo/scene/build.py -- --preview --scale 50 --samples 32 --stills 1.5,10.6,23.0
```

## Change it

- **Words on screen:** `titles/overlay.py`, then `make.sh finish`. No 3D render needed.
- **Timing:** `timeline.json`. Shot, spawn and burn times change the 3D, so render again. Captions follow the narration's own word times in `narration/lines/words.json`.
- **Narration:** see [narration/narration.md](narration/narration.md). New takes need new cues in `narration/lines/durations.json`; check that every line still ends before the next cue.
- **Sound:** cues in `sound/mix.py`, levels in dB under each file's own peak.

Checks used before publishing: a whisper transcript of the final mix must match the script word for word; every line must sit at least about 10 dB over the bed in the speech band (300 Hz–4 kHz); contact sheets of the frames, and a brightness scan of every frame for render glitches; blind listening judges (see narration.md); and first-time viewers, video-capable models that watch the finished film with sound as three kinds of visitor (`review.py`).
