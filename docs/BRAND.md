# BurnZombies visual identity

Cream type, charcoal surfaces and a small amount of orange flame. The main headline is **TAME THE HORDE**. The compact panel says **Dead weight. Gone.** The closing line is **You build. We burn.** Keep the default surface focused on results; evidence belongs in a drilldown.

The current layout uses a 360 × 488-point compact surface and a 1008 × 930-point Impact window. Display type is Anton; supporting text uses the macOS system font. The compact panel uses a 22-point wordmark, a 28-point headline, and three metrics in one row. Before the first cleanup, it shows zero counters, “Still warming up.” and “Ready for your first burn”. The 98-point Impact headline uses actual glyph ink bounds in two 85-point rows, with an eight-point gap, instead of font line boxes that introduce excessive leading. Numbers carry the emphasis and units are smaller. The agent boost card shows reclaimed memory and helpers cleared after a verified cleanup. A supported speed improvement can replace those results with a percentage. Quiet days acknowledge lifetime cleanups; they never return to first-use messaging. The card is 160 points tall in Impact and 84 in the compact view, with no “Local tool responsiveness” subtext. Native macOS window controls remain native. A short flame perk, six rising embers and numeric transitions celebrate newly verified receipts; Reduce Motion suppresses those animations.

## Artwork

`Sources/BurnApp/Resources/EmberSkull.png` was created with OpenAI's image-generation tool from the operator-provided design reference. The tool was instructed to extract the large flaming-skull character, retain the warm ivory skull, orange flames, scattered embers and soft oval shadow, remove all interface/text/background elements, and use a transparent background. No machine screenshots or private diagnostic data are part of this asset.

The artwork is also the status item image. System flame and gear symbols are provided by macOS.

## Font

Anton is bundled from the [Google Fonts Anton directory](https://github.com/google/fonts/tree/main/ofl/anton), under the SIL Open Font License 1.1. Copyright 2020 The Anton Project Authors. Its license is preserved as `Sources/BurnApp/Resources/Anton-OFL.txt`.

## Public previews

The README uses `docs/media/menu-bar-empty.png`, `docs/media/menu-bar.png` and `docs/media/impact.png`, rendered directly from the current native SwiftUI views. The compact images show first-use and populated states at the same scale. These are interface examples, not performance benchmarks or trial results. No desktop content, private process details or live cleanup history is included.

Refresh them without opening a window or starting an observer:

```sh
swift build --product BurnZombiesApp
.build/debug/BurnZombiesApp --mini-proof /tmp/bz-readme-mini
.build/debug/BurnZombiesApp --impact-proof /tmp/bz-readme-impact
cp /tmp/bz-readme-mini/empty.png docs/media/menu-bar-empty.png
cp /tmp/bz-readme-mini/unmeasured.png docs/media/menu-bar.png
cp /tmp/bz-readme-impact/reclaimed.png docs/media/impact.png
```

The render checks exercise the shipped views in memory with isolated example data and use OCR to check the compact labels and period counters. They prohibit app activation and do not create an observer, signal processes, or save production state.

The older JPGs and GIFs remain historical media, not the current README gallery. `preview.gif` is a timed sequence of earlier Impact and Burn Log captures; `burn.gif` shows the demo-only success animation. `live-cleanup.gif` and `live-cleanup.mp4` are earlier controlled cleanup walkthroughs, separate from the real-workload trial.
