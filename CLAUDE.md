# Tunic iOS port (CyPort-style)

Run the user's own GOG **Mac** copy of Tunic natively on iPhone/iPad the way CyPort runs Cyberpunk 2077: retarget the Mac arm64 binaries to iOS, replace macOS-only pieces with a UIKit shim, import game data into the app's Documents folder. No game files go in the repo.

## Layout
- `tunic_enUS_1_0_t1483_b37_59078.pkg` — the user's GOG Mac installer (1.5 GB). Never commit or redistribute.
- Repo root = this folder, GitHub `debeanz/tunic-ios-port` (public). Code copied from https://github.com/Thijs2004/CyPort (MIT, commit 65e2e57), not forked: retargeter (`tools/ios_retarget.py`), shim (`shim/`), launcher (`app/`), `build.sh`, `Build Tunic Port.command` (double-click launcher; `build.sh` behind it is still CyPort's and needs adapting). Keep CyPort's LICENSE line and credit. CyPort's original README is `docs/CYPORT_README.md`; its Cyberpunk-style icons were removed (Tunic's icon comes from the user's copy at build time).

## Next steps
1. Extract the `.pkg` (e.g. 7-Zip or xar + cpio/pbzx) into its own folder and find `Tunic.app`.
2. Check `Contents/MacOS/*`, `UnityPlayer.dylib`, `GameAssembly.dylib` (or `Data/Managed/*.dll`) for an **arm64** slice. Intel-only means the CyPort route won't work; fall back to the unity-il2cpp/mono iOS port skills.
3. Record the Unity version, texture compression (BC/DXT vs others), bundled plugins (FMOD, Galaxy) and the macOS frameworks the binaries import, to size the shim.
4. Find out whether Unity's Mac player runs its loop on the main thread (decides whether the game loop must move off it).

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
