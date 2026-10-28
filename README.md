# tunic-ios-port

**Run your own copy of Tunic for Mac natively on iPhone and iPad.**
No emulation, no streaming: the Mac build's own arm64 code runs on iOS, the same way [CyPort](https://github.com/Thijs2004/CyPort) runs Cyberpunk 2077.

> **This repo contains no game files.** You need your own legally bought copy of *Tunic* for Mac (GOG).
> The IPA is built from that copy on your own computer. Don't share an IPA you built: it contains the game.
> This is an independent fan project, **not affiliated with or endorsed by Isometricorp Games or Finji**. *Tunic* is a trademark of its owners.

## Status

**Playable.** Tunic boots, plays and has sound on an iPhone 15 Pro Max (A17 Pro, iOS 27), installed through LiveContainer. It holds 60 FPS, and 120 FPS at lower resolutions.

| | |
|---|---|
| Game boots, renders through Metal, plays | ✅ |
| Audio (FMOD) | ✅ |
| Tunic launcher with settings | ✅ |
| Touch controls + in-game Phone Settings panel | ✅ built, device testing in progress |
| Metal HUD, resolution readout | ✅ |
| Other iPhones and iPads | not tested yet |
| Importing the game data in the app (`--no-data` IPA) | not tested yet |

Tested with the GOG Mac installer `tunic_enUS_1_0_t1483_b37_59078.pkg` (version 1.0).

## How it works

- **Retargeting** (`tools/ios_retarget.py`): the Mac build is universal, with arm64 code. Its executable, `UnityPlayer.dylib`, `GameAssembly.dylib` and the plugins (FMOD Studio, InControl, Resonance Audio) are marked as iOS binaries. Frameworks iOS doesn't have are pointed at the shim.
- **Shim** (`shim/`, built into `libMacShim.dylib`): stands in for what Unity's Mac player expects from macOS, such as AppKit windows and events, IOKit, Carbon, CoreAudio devices and macOS-only Metal calls. It runs everything on UIKit.
- **Launcher**: a SwiftUI start screen opens before the game. Play then starts the game's own `main()`.
- **Overlays**: touch controls, the gear panel and the readouts are Core Animation layers above the game. They stay smooth even when the game's frame rate drops.

## Building

You need Python 3 and the [GitHub CLI](https://cli.github.com/). It works on Windows, macOS or Linux, and nothing about your game is uploaded.

1. **Shim.** GitHub Actions builds `libMacShim.dylib` on every push (`.github/workflows/shim.yml`). It needs no game files. Download it:
   ```bash
   gh run download -n libMacShim -D build/shim
   ```
   On a Mac with Xcode you can build it yourself instead with `bash tools/build_shim.sh build/shim`.
2. **IPA.** Point the script at your GOG installer (or the extracted `Tunic.app`, or its `Contents` folder):
   ```bash
   py tools/make_ipa.py --game tunic_enUS_1_0_t1483_b37_59078.pkg
   ```
   The result is `build/Tunic-unsigned.ipa`, about 1.7 GB with the game data inside. With `--no-data` the IPA leaves the data out, and the app asks you to import it into its Documents folder instead.
3. **Install.** Use LiveContainer, SideStore or Sideloadly. They sign the IPA.

`Build Tunic Port.command` and `build.sh` are still CyPort's Mac build scripts and are not adapted to Tunic yet. Use the steps above.

## Settings

The launcher's settings are laid out like a page from an instruction manual. Screen scaling, frame rate, the touch settings and the resolution readout are also in the game, behind the gear button.

**Display**
- **Resolution:** the size the game renders at, in steps from *Fastest* to *native*.
- **Screen scaling:**
  - **Fit:** Tunic's 16:9 picture with black bars at the sides.
  - **Stretch:** fills the whole screen.
  - **Stretch 1.943:1:** fills a centred 1.943:1 frame, with bars beside the Dynamic Island.
- **Frame rate:** 30, 60 or 120 FPS (ProMotion).

**Controls**
- **Touch controls:** an Xbox-style on-screen pad. Settings: on/off, opacity, size, fixed or floating left stick, vibration.
- **Look sensitivity, low-latency input:** CyPort's settings.

**Performance**
- **Performance overlay:** Off, FPS or Detailed.
- **Metal HUD:** Apple's frame rate, GPU time and memory HUD.
- **Resolution readout:** the exact render size, shown bottom-left in the game.
- **Smooth frame pacing:** holds 120, 60, 40 or 30 FPS, whichever the device keeps up with.

**In-game Phone Settings:** the gear button opens a panel with Screen Scaling, Frame Rate, the touch settings and Resolution Readout. You can use it by touch, with the on-screen pad or with a controller. The game gets no input while it's open.

### Left out, and why
- **Aspect ratio:** Tunic never draws wider than 16:9. Its own camera code adds black side bars on wider screens, so other shapes changed nothing. Screen scaling covers full screen and 1.943:1.
- **UI size:** Tunic's interface scale lives inside the game, and there's no clean way to change it from outside yet.
- **Cloud saves:** CyPort's cloud sync is written for Cyberpunk's GOG saves. Tunic's saves stay on the device.

## Logs

If something goes wrong, open the Files app and look in **Tunic**:
- `macshim.log`: the shim's log. It covers boot, display, audio, frame pacing, and a stack report of every thread if the game ever stops drawing frames.
- `unity_player.log`: Unity's own log.

## Credits

Built on **[CyPort](https://github.com/Thijs2004/CyPort)** by Thijs Mussig (MIT). CyPort's original README is kept in [docs/CYPORT_README.md](docs/CYPORT_README.md).
Third-party code (LZMA decoder from the 7-Zip SDK, zstd decompressor) is included under its own licenses, as in CyPort.

## License

MIT, see [LICENSE](LICENSE).
