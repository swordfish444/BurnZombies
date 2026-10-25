# BurnZombies visual identity

Cream type, charcoal surfaces and a small amount of orange flame. The main headline is **TAME THE HORDE**. The compact panel says **Dead weight. Gone.** The closing line is **You build. We burn.** Keep the default surface focused on results; evidence belongs in a drilldown.

The reference layout uses a 428 × 795-point compact surface and a 1008 × 930-point Impact window. Display type is Anton; supporting text uses the macOS system font. The 98-point headline uses actual glyph ink bounds in two 85-point rows, with an eight-point gap, instead of font line boxes that introduce excessive leading. Numbers carry the emphasis and units use 64% of their size. The speed card is 160 points tall in Impact and 84 in the compact view. Native macOS window controls remain native. A short flame perk, six rising embers and numeric transitions celebrate newly verified receipts; Reduce Motion suppresses those animations.

## Artwork

`Sources/BurnApp/Resources/EmberSkull.png` was created with OpenAI's image-generation tool from the operator-provided design reference. The tool was instructed to extract the large flaming-skull character, retain the warm ivory skull, orange flames, scattered embers and soft oval shadow, remove all interface/text/background elements, and use a transparent background. No machine screenshots or private diagnostic data are part of this asset.

The artwork is also the status item image. System flame and gear symbols are provided by macOS.

## Font

Anton is bundled from the [Google Fonts Anton directory](https://github.com/google/fonts/tree/main/ofl/anton), under the SIL Open Font License 1.1. Copyright 2020 The Anton Project Authors. Its license is preserved as `Sources/BurnApp/Resources/Anton-OFL.txt`.

## Public previews

`docs/media/impact.jpg` and `docs/media/menu-bar.jpg` are native app captures with synthetic data. The compact capture uses a persistent preview window hosting the exact popover view so it can be inspected without transient dismissal. `preview.gif` is a timed sequence of native Impact and Burn Log captures, not a live cleanup recording. `burn.gif` captures the brief success animation through the demo-only preview control. Demo mode cannot signal processes or save production state.
