#!/usr/bin/env python3
"""يولّد ar.lproj وen.lproj من نصوص L("…") في كود التطبيق ومن ملف الترجمة en.json.
يفشل لو فيه نص بدون ترجمة إنجليزية، عشان ما يطلع عربي وسط الواجهة الإنجليزية."""
import json, pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
app = root / "App" / "QB"
pat = re.compile(r'\bL\("((?:[^"\\]|\\.)*)"')
keys = set()
for f in app.rglob("*.swift"):
    for m in pat.finditer(f.read_text(encoding="utf-8")):
        keys.add(m.group(1))

en = json.loads((app / "Localization" / "en.json").read_text(encoding="utf-8"))
missing = sorted(k for k in keys if k not in en)
if missing:
    print("❌ نصوص بدون ترجمة إنجليزية:", *missing, sep="\n  ")
    sys.exit(1)

def esc(s: str) -> str:
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")

for lang, table in (("ar", {k: k for k in keys}), ("en", {k: en[k] for k in keys})):
    d = app / "Resources" / f"{lang}.lproj"
    d.mkdir(parents=True, exist_ok=True)
    lines = [f'"{esc(k)}" = "{esc(v)}";' for k, v in sorted(table.items())]
    (d / "Localizable.strings").write_text("\n".join(lines) + "\n", encoding="utf-8")
    names = {"ar": ("QB", "QB يتصل بالإضافات والخوادم على شبكتك المحلية لتشغيل الفيديو."),
             "en": ("QB", "QB connects to add-ons and servers on your local network to play video.")}[lang]
    (d / "InfoPlist.strings").write_text(
        f'"CFBundleDisplayName" = "{names[0]}";\n"NSLocalNetworkUsageDescription" = "{esc(names[1])}";\n',
        encoding="utf-8")

print(f"✔ {len(keys)} نص، كلها مترجمة (ar + en)")
