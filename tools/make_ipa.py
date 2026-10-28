#!/usr/bin/env python3
"""Build the unsigned Tunic IPA from YOUR copy of Tunic for Mac (GOG). Runs on Windows, macOS or Linux; nothing is
uploaded anywhere. Needs libMacShim.dylib, built by GitHub Actions (or tools/build_shim.sh on a Mac):

    gh run download -n libMacShim -D build/shim
    py tools/make_ipa.py --game tunic_enUS_....pkg          (or the Tunic.app folder, or its Contents folder)

Output: build/Tunic-unsigned.ipa (install with SideStore / LiveContainer / Sideloadly, which sign it).

  Payload/Tunic.app/Tunic                     game executable (retargeted)
  Payload/Tunic.app/Frameworks/               UnityPlayer, GameAssembly, the plugins (all retargeted) + libMacShim
  Payload/Tunic.app/Game/Resources/           the Mac app's Contents/Resources (Data/ etc.); --no-data leaves it out,
                                              the app then asks to import it into Documents
  Payload/Tunic.app/Game/Info.plist           the Mac Info.plist (Unity reads it through the shim's Mac-style folder)
"""
import argparse, os, plistlib, shutil, struct, sys, zipfile

HERE = os.path.dirname(os.path.abspath(__file__)); ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import ios_retarget as rt          # noqa: E402

PLUGINS = ["fmodstudio", "InControlNative", "resonanceaudio"]      # x86-only fmod/fmodL/gvraudio are never loaded
EXE = "Tunic"


def find_contents(game, work):
    if game.lower().endswith(".pkg"):
        import pkg_extract
        out = os.path.join(work, "extracted")
        if not os.path.isdir(out):
            print("==> extracting", game)
            sys.argv = ["pkg_extract", game, out]; pkg_extract.main()
        game = out
    if os.path.isdir(os.path.join(game, "Contents")):
        game = os.path.join(game, "Contents")
    for dp, dn, fn in os.walk(game):              # the folder with Info.plist + MacOS/ + Frameworks/UnityPlayer.dylib
        if "Info.plist" in fn and os.path.exists(os.path.join(dp, "Frameworks", "UnityPlayer.dylib")):
            return dp
    sys.exit("no Tunic Mac app found in " + game)


def shim_needs(path):
    """symbols a retargeted binary binds to the shim (dyld-info bind + lazy streams; weak imports skipped)"""
    d = open(path, "rb").read(); m = rt.parse(d)
    libs = [rt.name_of(d, off, sz)[1] for cmd, off, sz in m["cmds"] if cmd in rt.DYLIB_CMDS]
    shim = {i + 1 for i, l in enumerate(libs) if l.endswith("/libMacShim.dylib")}
    info = [off for cmd, off, sz in m["cmds"] if cmd in (0x22, 0x80000022)]
    if not shim or not info: return set()
    v = struct.unpack_from("<10I", d, info[0] + 8)
    out = set()
    for start, size in ((v[2], v[3]), (v[6], v[7])):
        i, end, ordinal = start, start + size, 0
        def uleb(i):
            x = s = 0
            while True:
                b = d[i]; i += 1; x |= (b & 0x7f) << s; s += 7
                if not b & 0x80: return x, i
        while i < end:
            b = d[i]; op, imm = b & 0xf0, b & 0x0f; i += 1
            if op == 0x10: ordinal = imm
            elif op == 0x20: ordinal, i = uleb(i)
            elif op == 0x30: ordinal = -imm
            elif op == 0x40:
                j = d.index(b"\0", i); sym = d[i:j].decode(); i = j + 1
                if ordinal in shim and not imm & 1: out.add(sym)                 # imm & 1: weak import
            elif op in (0x60, 0x70, 0x80, 0xa0): i = uleb(i)[1]
            elif op == 0xc0: i = uleb(uleb(i)[1])[1]
    return out


def icns_png(path):
    """largest PNG inside the Mac icon (ic10 1024, ic14 512@2x, ic09 512, ...)"""
    d = open(path, "rb").read(); best = b""
    i = 8
    while i + 8 <= len(d):
        kind, size = d[i:i + 4], struct.unpack(">I", d[i + 4:i + 8])[0]
        body = d[i + 8:i + size]
        if body[:8] == b"\x89PNG\r\n\x1a\n" and len(body) > len(best): best = body
        if size < 8: break
        i += size
    return best


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--game", required=True, help="Tunic .pkg (GOG Mac installer), Tunic.app, or its Contents folder")
    ap.add_argument("--shim", default=os.path.join(ROOT, "build", "shim", "libMacShim.dylib"))
    ap.add_argument("--bundle-id", default="com.debeanz.tunicport")
    ap.add_argument("--out", default=os.path.join(ROOT, "build"))
    ap.add_argument("--no-data", action="store_true", help="leave the game data out (import it in the app instead)")
    ap.add_argument("--needs-only", action="store_true", help="only write tools/shim_needs.txt (no shim needed)")
    a = ap.parse_args()

    contents = find_contents(a.game, a.out)
    print("==> Tunic Mac app:", contents)
    app = os.path.join(a.out, "Payload", "Tunic.app"); fw = os.path.join(app, "Frameworks")
    shutil.rmtree(os.path.join(a.out, "Payload"), ignore_errors=True); os.makedirs(fw)

    print("==> retargeting the game binaries (macOS -> iOS)")
    rt.PROFILE = "tunic"
    jobs = [(os.path.join(contents, "MacOS", "Secret Legend"), os.path.join(app, EXE)),
            (os.path.join(contents, "Frameworks", "UnityPlayer.dylib"), os.path.join(fw, "UnityPlayer.dylib")),
            (os.path.join(contents, "Frameworks", "GameAssembly.dylib"), os.path.join(fw, "GameAssembly.dylib"))]
    jobs += [(os.path.join(contents, "PlugIns", p + ".bundle", "Contents", "MacOS", p), os.path.join(fw, p + ".dylib")) for p in PLUGINS]
    needs = set()
    for src, dst in jobs:
        for line in rt.retarget(src, dst, "16.0", "18.0"):
            if "rerouted" in line or "NOT" in line or "CameraResizer" in line: print("   ", os.path.basename(dst) + ":", line)
        needs |= shim_needs(dst)
    with open(os.path.join(HERE, "shim_needs.txt"), "w", newline="\n") as f:
        f.write("# symbols Tunic's retargeted binaries bind to libMacShim.dylib (written by tools/make_ipa.py)\n")
        f.write("".join(s + "\n" for s in sorted(needs)))
    print("==> %d symbols bound to the shim -> tools/shim_needs.txt" % len(needs))
    if a.needs_only: return

    if not os.path.exists(a.shim):
        sys.exit("libMacShim.dylib not found at %s\n  download it: gh run download -n libMacShim -D build/shim" % a.shim)
    shutil.copy2(a.shim, os.path.join(fw, "libMacShim.dylib"))

    mac = plistlib.load(open(os.path.join(contents, "Info.plist"), "rb"))
    os.makedirs(os.path.join(app, "Game"))
    shutil.copy2(os.path.join(contents, "Info.plist"), os.path.join(app, "Game", "Info.plist"))
    if not a.no_data:
        print("==> copying the game data (Contents/Resources, %.1f GB)" % (sum(os.path.getsize(os.path.join(dp, f)) for dp, _, fn in os.walk(os.path.join(contents, "Resources")) for f in fn) / 1e9))
        shutil.copytree(os.path.join(contents, "Resources"), os.path.join(app, "Game", "Resources"),
                        ignore=shutil.ignore_patterns("MainMenu.nib", ".DS_Store"))

    tpl = open(os.path.join(ROOT, "app", "Info.plist"), encoding="utf-8").read()
    tpl = tpl.replace("__BUNDLE_ID__", a.bundle_id).replace("__EXECUTABLE__", EXE) \
             .replace("__VERSION__", str(mac.get("CFBundleShortVersionString", "1.0"))).replace("__BUILD__", str(mac.get("CFBundleVersion", "1")))
    open(os.path.join(app, "Info.plist"), "w", encoding="utf-8", newline="\n").write(tpl)
    png = icns_png(os.path.join(contents, "Resources", "PlayerIcon.icns"))
    if png:
        for name in ("AppIcon60x60@2x.png", "AppIcon60x60@3x.png", "AppIcon76x76@2x~ipad.png", "AppIcon83.5x83.5@2x~ipad.png"):
            open(os.path.join(app, name), "wb").write(png)
    else: print("    (no PNG in PlayerIcon.icns: no app icon)")

    ipa = os.path.join(a.out, "Tunic-unsigned.ipa" if not a.no_data else "Tunic-unsigned-nodata.ipa")
    print("==> packing", ipa)
    with zipfile.ZipFile(ipa, "w", allowZip64=True) as z:
        for dp, dn, fn in os.walk(os.path.join(a.out, "Payload")):
            dn.sort()
            rel_dir = os.path.relpath(dp, a.out).replace(os.sep, "/")
            zi = zipfile.ZipInfo(rel_dir + "/"); zi.external_attr = (0o40755 << 16) | 0x10; z.writestr(zi, b"")
            for f in sorted(fn):
                p = os.path.join(dp, f); rel = rel_dir + "/" + f
                zi = zipfile.ZipInfo.from_file(p, rel)
                exe = f == EXE or f.endswith(".dylib")
                zi.external_attr = ((0o100755 if exe else 0o100644) << 16)
                big = os.path.getsize(p) > 32 << 20 or f.endswith((".bank", ".unity3d", ".resS", ".resource"))
                zi.compress_type = zipfile.ZIP_STORED if big else zipfile.ZIP_DEFLATED
                with open(p, "rb") as src, z.open(zi, "w", force_zip64=True) as dst: shutil.copyfileobj(src, dst, 8 << 20)
    print("done: %s (%.2f GB)" % (ipa, os.path.getsize(ipa) / 1e9))


if __name__ == "__main__":
    main()
