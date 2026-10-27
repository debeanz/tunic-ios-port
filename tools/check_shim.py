#!/usr/bin/env python3
"""Fail if a symbol the retargeted game binaries bind to the shim is neither exported by libMacShim.dylib nor by one
of the libraries it re-exports. A miss would make dyld refuse to start the app (non-lazy) or crash on first call.

usage: check_shim.py <iOS SDK> <exports.txt from nm -gU> <shim_needs.txt>
"""
import os, re, sys

sdk, exports_file, needs_file = sys.argv[1:4]
REEXPORTED = ["/System/Library/Frameworks/%s.framework/%s" % (f, f) for f in
              ("Foundation", "CoreGraphics", "Security", "Metal", "CoreVideo", "AVFoundation", "AudioToolbox")] + ["/usr/lib/libiconv.2.dylib"]
LIST_KEYS = ("symbols", "weak-symbols", "objc-classes", "objc-eh-types", "objc-ivars", "thread-local-symbols")
seen = {}


def tbd_symbols(install_name, depth=0):
    if install_name in seen:
        return seen[install_name]
    seen[install_name] = set()
    p = install_name.lstrip("/")
    path = next((c for c in (os.path.join(sdk, p + ".tbd"), os.path.join(sdk, os.path.splitext(p)[0] + ".tbd")) if os.path.exists(c)), None)
    if not path:
        print("  (no stub for %s)" % install_name)
        return set()
    out = set()
    for key, body in re.findall(r"(\b[\w-]+):\s*\[([^\]]*)\]", open(path, encoding="utf-8", errors="replace").read(), re.S):
        items = [x.strip().strip("'\"") for x in body.replace("\n", " ").split(",") if x.strip()]
        if key == "objc-classes":
            out |= {pre + i for i in items for pre in ("_OBJC_CLASS_$_", "_OBJC_METACLASS_$_")}
        elif key == "objc-eh-types":
            out |= {"_OBJC_EHTYPE_$_" + i for i in items}
        elif key == "objc-ivars":
            out |= {"_OBJC_IVAR_$_" + i for i in items}
        elif key in LIST_KEYS:
            out |= set(items)
        elif key == "libraries" and depth < 6:
            for lib in items:
                out |= tbd_symbols(lib, depth + 1)
    seen[install_name] = out
    return out


have = {l.strip() for l in open(exports_file) if l.strip()}
for lib in REEXPORTED:
    have |= tbd_symbols(lib)
need = {l.split()[0] for l in open(needs_file) if l.strip() and not l.startswith("#")}
missing = sorted(need - have)
if missing:
    print("==> MISSING from the shim (the game would fail to load or crash on first use):")
    for m in missing:
        print("   ", m)
    sys.exit(1)
print("==> all %d symbols the game binds to the shim are there" % len(need))
