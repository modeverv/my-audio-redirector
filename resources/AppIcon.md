# My Redirector app icon

Created with the built-in image generation tool on 2026-09-28. The generated PNG is stored as `AppIcon.png`; its transparent outer margin is preserved. `AppIcon.icns` includes 16, 32, 128, 256 and 512 point representations at 1x and 2x, for Finder and Dock.

Regenerate the macOS container with `./scripts/build-icon.sh`, then run `./scripts/build-app.sh release`. Only the packaging is scripted; the source artwork is kept in the repository.

## Generation prompt

Validation: all 10 ICNS variants decode to their expected sizes (16–1024 px); the bundle's `CFBundleIconFile` points to the copied ICNS. Release build and code-sign verification passed, the app reopened OFF, and Finder displayed the new small icon and large preview. Dock uses the same bundle icon; its direct screenshot could not be obtained because the GUI tool timed out.

```text
Use case: logo-brand.
Asset type: production macOS application icon, a single square icon for "My Redirector", an audio routing and mixing utility.
Create a polished original icon: a dark graphite softly beveled rounded-square tile with two bold sculpted signal paths, one cool teal and one warm amber. The paths convey audio travelling in opposing directions and joining a compact central waveform. Make the central motif large, very simple and recognizable at 32 pixels; thick uninterrupted shapes, excellent contrast, generous breathing room, subtle professional studio-hardware material and controlled highlights. Front-facing orthographic view. A restrained, finely crafted native Mac app aesthetic.
1024 by 1024 square composition. Rounded tile centered with a small even transparent margin around all four sides (approximately 8% of canvas); everything outside the tile is truly transparent. Tile itself is opaque dark graphite. Crisp silhouette, clean edges, modest depth, no strong drop shadow.
No text, no letters, no numbers, no labels, no logos of audio manufacturers, no additional objects, no mockup, no desktop, no border around the full canvas. Deliver one final icon, not a sheet of alternatives.
```
