# BurnZombies visual identity

Cream type, charcoal surfaces and a small amount of orange flame. The main headline is **TAME THE HORDE**. The compact panel says **Dead weight. Gone.** The closing line is **You build. We burn.** Keep the default surface focused on results; evidence belongs in a drilldown.

The current layout uses a 360 × 550-point compact surface and a 1008 × 930-point Impact window. Display type is Anton; supporting text uses the macOS system font. The compact panel uses a 22-point wordmark, a 28-point headline, and four metrics in a two-by-two grid: zombies burned, memory released, disk reclaimed and worktrees cleaned. Above them, three small-caps tabs (Today, 7 days, All time) switch only those four totals. Before the first cleanup, it shows zero counters, “Still warming up.” and “Ready for your first burn”. The 98-point Impact headline uses actual glyph ink bounds in two 85-point rows, with an eight-point gap, instead of font line boxes that introduce excessive leading. Numbers carry the emphasis and units are smaller. The agent boost card shows reclaimed memory and helpers cleared after a verified cleanup. A supported speed improvement can replace those results with a percentage. Quiet days acknowledge lifetime cleanups; they never return to first-use messaging. The card is 160 points tall in Impact and 84 in the compact view, with no “Local tool responsiveness” subtext. Native macOS window controls remain native. A short flame perk, six rising embers and numeric transitions celebrate newly verified receipts; Reduce Motion suppresses those animations.

## Artwork

`Sources/BurnApp/Resources/EmberSkull.png` was created with OpenAI's image-generation tool from the operator-provided design reference. The tool was instructed to extract the large flaming-skull character, retain the warm ivory skull, orange flames, scattered embers and soft oval shadow, remove all interface/text/background elements, and use a transparent background. No machine screenshots or private diagnostic data are part of this asset.

The artwork is also the status item image. System flame and gear symbols are provided by macOS.

## Font

Anton is bundled from the [Google Fonts Anton directory](https://github.com/google/fonts/tree/main/ofl/anton), under the SIL Open Font License 1.1. Copyright 2020 The Anton Project Authors. Its license is preserved as `Sources/BurnApp/Resources/Anton-OFL.txt`.

## Public previews

The README opens with `docs/media/readme-hero.png`, rendered from `docs/media/readme-hero.html`. Its panel, `docs/media/panel-real.png`, is the author's own compact panel on the All time tab after two days of Autopilot (2026-11-02 to 11-04), rendered offscreen from a copy of that Mac's catalog and Autopilot tally. It shows totals only: no names, paths or process details. Phones get `docs/media/readme-hero-phone.png` (from `readme-hero-phone.html`, rendered the same way at 390 × 470) with the same two-day totals in larger type. The question card uses the app's isolated example data, and the README says so.

Refresh the example question card without opening a window or starting an observer:

```sh
swift build --product BurnZombiesApp
.build/debug/BurnZombiesApp --autopilot-proof /tmp/bz-readme-autopilot
sips -s format jpeg -s formatOptions 90 /tmp/bz-readme-autopilot/teach-caches.png --out docs/media/readme-question.jpg
```

Then render the hero at 2x, transparent outside its rounded card (the phone hero likewise), and the 1280 × 640 link-preview card (upload it in the repository's **Settings → Social preview**):

```sh
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --hide-scrollbars \
  --window-size=900,440 --force-device-scale-factor=2 --default-background-color=00000000 \
  --virtual-time-budget=3000 --screenshot=docs/media/readme-hero.png "file://$PWD/docs/media/readme-hero.html"
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless --hide-scrollbars \
  --window-size=1280,640 --virtual-time-budget=3000 --screenshot=/tmp/social-card.png "file://$PWD/docs/media/social-card.html"
sips -s format jpeg -s formatOptions 88 /tmp/social-card.png --out docs/media/social-card.jpg
```

The render checks exercise the shipped views in memory and use OCR to check what they show. They prohibit app activation and do not create an observer, signal processes, or save production state.

`menu-bar-empty.png`, `menu-bar.png`, `impact.png` and `hunt-zombies.png` were the README gallery until November 2026; `--mini-proof` (`empty.png`, `unmeasured.png`) and `--impact-proof` (`reclaimed.png`) still render their current versions. The older JPGs and GIFs remain historical media. `preview.gif` is a timed sequence of earlier Impact and Burn Log captures; `burn.gif` shows the demo-only success animation. `live-cleanup.gif` and `live-cleanup.mp4` are earlier controlled cleanup walkthroughs, separate from the real-workload trial.
