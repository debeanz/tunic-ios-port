# tunic-ios-port

**Run your own copy of Tunic for Mac natively on iPhone and iPad.**
No emulation, no streaming: the goal is to run the Mac build directly on iOS / iPadOS, the same way [CyPort](https://github.com/Thijs2004/CyPort) runs Cyberpunk 2077.

> **This repo contains no game files.** You need your own legally bought copy of *Tunic* for Mac (GOG).
> The app is built on your Mac from that copy, and the game data is imported into the app afterwards.
> This is an independent fan project, **not affiliated with or endorsed by Isometricorp Games or Finji**. *Tunic* is a trademark of its owners.

## Status

🚧 **Early work, nothing playable yet.** The code here is CyPort's, as the starting point. It hasn't been adapted to Tunic yet.

| Step | State |
|---|---|
| CyPort base imported | ✅ |
| Check the Mac build has arm64 code (required for this approach) | ⏳ next |
| Retarget Tunic's binaries (game, `UnityPlayer.dylib`, `GameAssembly.dylib`) to iOS | ⏳ |
| Shim for what Unity's Mac player needs from macOS | ⏳ |
| Tunic-themed launcher | ⏳ |
| Touch controls and in-game Phone Settings panel | ⏳ |

## Planned settings

Everything CyPort already has stays as it is: resolution, performance overlay (Off / FPS / Detailed), smooth frame pacing, low-latency input, look sensitivity, cloud saves and game data import.

Added on top:
- **Display:** aspect ratio (iPhone Default, 1.943:1, 16:9, 4:3), scaling (Fit / Stretch), frame rate (30 / 60 / 120 FPS), UI size
- **Touch controls:** on/off, opacity, size, fixed or floating stick, haptics
- **In-game Phone Settings panel** behind a gear button, using the same saved settings as the launcher

Overlays, touch controls and menus are drawn separately from the game, so they stay smooth even when the game's framerate drops.

## Credits

Built on **[CyPort](https://github.com/Thijs2004/CyPort)** by Thijs Mussig (MIT). CyPort's original README is kept in [docs/CYPORT_README.md](docs/CYPORT_README.md).
Third-party code (LZMA decoder from the 7-Zip SDK, zstd decompressor) is included under its own licenses, as in CyPort.

## License

MIT, see [LICENSE](LICENSE).
