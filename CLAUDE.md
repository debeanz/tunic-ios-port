# Tunic iOS port (CyPort-style)

Run the user's own GOG **Mac** copy of Tunic natively on iPhone/iPad the way CyPort runs Cyberpunk 2077: retarget the Mac arm64 binaries to iOS, replace macOS-only pieces with a UIKit shim, import game data into the app's Documents folder. No game files go in the repo.

## Layout
- `tunic_enUS_1_0_t1483_b37_59078.pkg` — the user's GOG Mac installer (1.5 GB). Never commit or redistribute.
- Repo root = this folder, GitHub `debeanz/tunic-ios-port` (public). Code copied from https://github.com/Thijs2004/CyPort (MIT, commit 65e2e57), not forked: retargeter (`tools/ios_retarget.py`), shim (`shim/`), launcher (`app/`), `build.sh`, `Build Tunic Port.command` (double-click launcher; `build.sh` behind it is still CyPort's and needs adapting). Keep CyPort's LICENSE line and credit. CyPort's original README is `docs/CYPORT_README.md`; its Cyberpunk-style icons were removed (Tunic's icon comes from the user's copy at build time).

## What the GOG Mac build is (checked 2026-10-27)
- Extracted to `extracted/` (gitignored). GOG puts the game in the pkg's `package.pkg/Scripts` cpio archive, not `Payload`; the app contents are `extracted/package.pkg-Scripts/payload/Contents/`. No 7-Zip on this PC: a stdlib Python xar/cpio extractor did it (`py -I pkg_extract.py <pkg> <out>`; Python is `py`, `python` is the Store stub).
- **arm64: yes.** Universal x86_64 + arm64 (macOS min 11.0): executable `MacOS/Secret Legend`, `Frameworks/UnityPlayer.dylib`, `Frameworks/GameAssembly.dylib`, PlugIns `fmodstudio`, `InControlNative`, `resonanceaudio`, `steam_api`. **The CyPort route works.**
- x86_64-only PlugIns: `fmod`, `fmodL`, `gvraudio`. Unused leftovers: GameAssembly loads only `fmodstudio` and `InControlNative` by name, and the Mac game already runs natively on Apple Silicon without them. Leave them out of the iOS app.
- Unity **2020.3.17f1**, **IL2CPP** (`Data/il2cpp_data`), bundle id `com.AndrewShouldice.SecretLegend` (internal name "Secret Legend"), app version 1.0. Nearly all assets are in one LZ4 `UnityFS` file `Data/data.unity3d` (934 MB). Audio: FMOD Studio banks in `StreamingAssets` (music_main.bank 379 MB).
- Frameworks to shim or redirect (UnityPlayer): Cocoa/AppKit, Carbon, IOKit, IOSurface, OpenGL (unused under Metal; stub it), Quartz, SecurityFoundation, CoreServices, MediaToolbox, plus the iOS-available ones (Foundation, QuartzCore, GameController, AudioUnit, CoreAudio, AVFoundation, CoreMedia, CoreVideo, CoreGraphics, CFNetwork, Security, SystemConfiguration). InControlNative adds ForceFeedback and Carbon. fmodstudio adds Carbon, AudioUnit and CoreAudio.

## How the build works (since 2026-10-27)
- **Cloud (GitHub Actions, `.github/workflows/shim.yml`)**: `tools/build_shim.sh` compiles only `libMacShim.dylib` (shim + SwiftUI launcher) and `tools/check_shim.py` fails the build if any symbol in `tools/shim_needs.txt` isn't exported by the shim or a library it re-exports. No game files involved.
- **PC**: `gh run download -n libMacShim -D build/shim`, then `py tools/make_ipa.py --game <pkg | Tunic.app | Contents>` -> `build/Tunic-unsigned.ipa`. It retargets the binaries (`ios_retarget.py` profile `tunic`), rewrites `tools/shim_needs.txt`, copies `Contents/Resources` to `Game/Resources` (`--no-data` leaves it out; the app then imports into Documents/Tunic), icon from `PlayerIcon.icns`.
- **Unity binaries use dyld-info binds** (not chained fixups): libSystem/CF calls are rerouted through their lazy-bind records in place (`reroute_lazy`); frameworks iOS lacks or lacks symbols of go to the shim (`@loader_path/libMacShim.dylib`), which re-exports Foundation, CoreGraphics, Security, Metal, CoreVideo, AVFoundation, AudioToolbox, libiconv. GameAssembly reaches the shim through its libiconv dependency.
- **Shim at runtime**: `NSApplicationMain` boots UIKit + launcher first, Play restarts `main()`; Unity gets a Mac-style folder `Library/Application Support/MacShim/Tunic.app` (empty `Contents/MacOS/Secret Legend`, `Contents/Resources` -> game folder, `Contents/PlugIns/X.bundle/Contents/MacOS/X` -> `Frameworks/X.dylib`, `Contents/Frameworks` -> app Frameworks). FMOD's Mac HAL output becomes RemoteIO with a fake CoreAudio device. Log: Files > Tunic > macshim.log.
- The SwiftUI launcher is still CyPort's (Cyberpunk resolution list etc.); the Tunic-themed launcher and the added settings come after the game boots.

## Next steps
1. First device test of the IPA: read macshim.log, fix what fails to load or crashes.
2. Texture formats inside `data.unity3d` (BC/DXT vs ASTC): BC needs device support (A15+/M1 report it), else convert on import.
3. Unity's Mac loop runs on the main thread (as Cyberpunk's): overlays must not hitch with it (framerate-independence rule).
4. Tunic-themed launcher + the added settings + in-game gear panel.

## Rules the user set
- **Settings:** keep all of CyPort's settings and behaviour unchanged (Resolution, Performance overlay Off/FPS/Detailed, Smooth frame pacing, Low-latency input, Look sensitivity, Cloud saves, Game data import/download, 🎮 pad toggle, restart "quit?" prompt). Only ADD the unity-ios-port mobile kit settings CyPort lacks, with the kit's labels and defaults (`~/.claude/plugins/cache/debeanz-ports/unity-ios-port/1.2.0/shared/mobile-kit/MobileSettings.cs`, `MobileDisplay.cs`):
  - Aspect ratio: iPhone Default, 1.943:1, 16:9, 4:3 (default iPhone Default)
  - Scaling: Fit, Stretch (Fit)
  - Frame rate: 30, 60, 120 FPS (ProMotion) (60)
  - UI size: Small 0.85x, Default, Large 1.2x (Default). If it can't map cleanly onto Tunic, tell the user; don't silently drop it
  - Touch controls on/off (on), Touch opacity 10–100% (65), Touch size 50–200% (100), Left stick Fixed/Floating (Fixed), Haptics (on)
  - In-game gear "Phone Settings" panel (kit's smoked-glass style; touch, controller and on-screen pad navigation; the game gets no input while it's open), sharing saved values with the launcher.
- **Launcher look:** themed on Tunic's art style (soft pastel isometric world, warm light, paper "instruction manual" feel). It's an original design: real art (icon, key art, logo) is loaded at runtime from the user's imported copy and never shipped. Palette is sampled from that art. The restyle is visual only.
- **Not AI slop:** no purple/blue gradients, no glass everywhere, no emoji icons, no glow buttons, no stack of centered cards, no "Welcome!" copy. Build it like a real game title screen.
- **Clean, responsive, seamless:** grouped settings (Display, Controls, Performance, Data), instant tap feedback with haptics, 120 Hz-smooth animation, every iPhone/iPad size and orientation, fade launcher → game → back with no flashes.
- **Framerate independence:** overlays, touch controls, the gear panel, the FPS overlay and prompts are native UIKit/Core Animation layers above the game's Metal layer, never tied to the game's framerate. Touch input becomes buffered pad state the game polls. Test with a debug option that throttles the game to ~15 FPS.
- **Quality:** polished, not buggy, every setting verified end to end (logs plus an on-device checklist). The user tests on their iPhone; report anything not yet verified on a device.
