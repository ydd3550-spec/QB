#!/usr/bin/env bash
# يشغّل بناء QB على Codemagic بالمفتاح المحفوظ، يتابعه لين يخلص،
# وينزّل الـ IPA لو نجح، أو يطبع سبب الفشل من سجل الخطوة اللي فشلت.
#
# الاستخدام:  scripts/cm-build.sh [branch] [RUN_TESTS=0|1]
#   CM_BUILD_ID=<id> scripts/cm-build.sh   ← يتابع بناء شغّال بدل ما يشغّل جديد
#
# المخرجات في build/cm/: QB.ipa، سجلات الخطوات، وbuild.json
# رمز الخروج: 0 نجح، 1 فشل، 2 خطأ إعداد.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
KEY_FILE="${CM_KEY_FILE:-$HOME/.qbci/cm}"
APP_ID="${CM_APP_ID:-6af57b73c2ee784c332d3589}"      # تطبيق QB في Codemagic
WORKFLOW="${CM_WORKFLOW:-qb-unsigned-ipa}"
BRANCH="${1:-main}"
RUN_TESTS="${2:-0}"
API=https://api.codemagic.io
OUT="$ROOT/build/cm"
POLL="${CM_POLL_SECONDS:-30}"

[ -r "$KEY_FILE" ] || { echo "مفتاح Codemagic مو موجود: $KEY_FILE" >&2; exit 2; }
KEY="$(tr -d '\n\r ' < "$KEY_FILE")"
mkdir -p "$OUT"
rm -f "$OUT"/*.log "$OUT"/QB.ipa

api() { curl -sS --fail-with-body -H "x-auth-token: $KEY" -H "Content-Type: application/json" "$@"; }

if [ -n "${CM_BUILD_ID:-}" ]; then
  BUILD_ID="$CM_BUILD_ID"
else
  BODY=$(python3 -c 'import json,sys; print(json.dumps({"appId":sys.argv[1],"workflowId":sys.argv[2],"branch":sys.argv[3],"environment":{"variables":{"RUN_TESTS":sys.argv[4]}}}))' "$APP_ID" "$WORKFLOW" "$BRANCH" "$RUN_TESTS")
  BUILD_ID=$(api -X POST "$API/builds" -d "$BODY" | python3 -c 'import json,sys; print(json.load(sys.stdin)["buildId"])')
fi
URL="https://codemagic.io/app/$APP_ID/build/$BUILD_ID"
echo "▸ البناء: $URL"

TERMINAL="finished failed canceled timeout skipped warning"
STATUS=""
while :; do
  api "$API/builds/$BUILD_ID" > "$OUT/build.json" || { sleep "$POLL"; continue; }
  STATUS=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["build"]["status"])' "$OUT/build.json")
  STEP=$(python3 - "$OUT/build.json" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))["build"]
acts = b.get("buildActions") or []
cur = next((a for a in acts if a.get("status") in ("building", "preparing", "fetching", "testing", "publishing")), None)
print(cur["name"] if cur else "")
PY
)
  echo "  $(date +%H:%M:%S) $STATUS ${STEP:+— $STEP}"
  case " $TERMINAL " in *" $STATUS "*) break ;; esac
  sleep "$POLL"
done

# سجلات الخطوات + روابط الملفات
python3 - "$OUT/build.json" "$OUT" "$KEY" <<'PY'
import json, sys, urllib.request, re
build_json, out, key = sys.argv[1:4]
b = json.load(open(build_json))["build"]
def get(url):
    req = urllib.request.Request(url, headers={"x-auth-token": key})
    with urllib.request.urlopen(req, timeout=120) as r:
        return r.read()
failed = []
for i, a in enumerate(b.get("buildActions") or []):
    st = a.get("status")
    print(f"  [{st}] {a.get('name')}")
    if a.get("logUrl"):
        try:
            data = get(a["logUrl"]).decode("utf-8", "replace")
            name = re.sub(r"[^A-Za-z0-9]+", "_", a.get("name") or f"step{i}")[:50]
            open(f"{out}/{i:02d}_{name}.log", "w").write(data)
            if st == "failed":
                failed.append((a.get("name"), data))
        except Exception as e:
            print(f"    (تعذّر تنزيل السجل: {e})")
for name, data in failed:
    print(f"\n✖ الخطوة اللي فشلت: {name}")
    lines = data.splitlines()
    errs = [l for l in lines if re.search(r"error(\[E\d+\])?:|fatal|\[!\]", l)]
    show = errs[:80] if errs else lines[-80:]
    print("\n".join(show))
if b.get("message"):
    print("\nرسالة Codemagic:", b["message"])
with open(f"{out}/artifacts.txt", "w") as f:
    for art in b.get("artefacts") or []:
        f.write(f"{art.get('name')}\t{art.get('url')}\t{art.get('size')}\n")
PY

if [ "$STATUS" = "finished" ]; then
  IPA_URL=$(awk -F'\t' '$1 ~ /\.ipa$/ {print $2; exit}' "$OUT/artifacts.txt")
  [ -n "$IPA_URL" ] || { echo "البناء نجح بس ما لقيت ملف IPA في الملفات" >&2; exit 1; }
  curl -sSL --fail -H "x-auth-token: $KEY" -o "$OUT/QB.ipa" "$IPA_URL"
  for f in $(awk -F'\t' '$1 ~ /\.log$/ {print $1"|"$2}' "$OUT/artifacts.txt"); do
    curl -sSL -H "x-auth-token: $KEY" -o "$OUT/artifact_${f%%|*}" "${f#*|}" || true
  done
  echo "✔ نجح. IPA: $OUT/QB.ipa ($(du -h "$OUT/QB.ipa" | cut -f1))"
  echo "$URL"
  exit 0
fi
echo "✖ البناء انتهى بحالة: $STATUS"
echo "$URL"
exit 1
