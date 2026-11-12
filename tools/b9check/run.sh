#!/usr/bin/env bash
# يشغّل فحص المشغّل على محاكي آيفون ويطلّع الصور والنصوص في build/check.zip
set -uo pipefail
mkdir -p build/check/raw

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys, re
d = json.load(sys.stdin)["devices"]
def ver(rt):
    m = re.search(r"iOS-(\d+)-(\d+)", rt)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
rts = sorted([rt for rt in d if "iOS" in rt and ver(rt) >= (26, 0)], key=ver, reverse=True)
for p in ["iPhone 17 Pro", "iPhone 16 Pro", "iPhone 17", "iPhone 16"]:
    for rt in rts:
        for dev in d[rt]:
            if dev["name"] == p:
                print(dev["udid"]); sys.stderr.write(p + " " + rt + "\n"); sys.exit(0)
for rt in rts:
    for dev in d[rt]:
        if dev["name"].startswith("iPhone"):
            print(dev["udid"]); sys.exit(0)
')
[ -n "$UDID" ] || { echo "no iOS 26 iPhone simulator"; exit 1; }
echo "simulator: $UDID"
xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance dark

set -o pipefail
xcodebuild test -workspace QB.xcworkspace -scheme QBCheck -destination "id=$UDID" \
  -derivedDataPath build/DDC -resultBundlePath build/check.xcresult \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  2>&1 | tee build/check-test.log | grep -E "CHECK:|error:|Test Case|TEST (SUCCEEDED|FAILED)|\*\* " | grep -v debugDescription | cut -c1-300
echo "xcodebuild exit: ${PIPESTATUS[0]}"
xcrun xcresulttool export attachments --path build/check.xcresult --output-path build/check/raw || echo "attachment export failed"
xcrun simctl spawn "$UDID" log show --last 30m --predicate 'subsystem == "app.qb"' --style compact > build/check/app-log.txt 2>&1 || true
grep -E "CHECK:" build/check-test.log > build/check/check.txt || true
cd build && rm -f check.zip && zip -qr check.zip check check-test.log && ls -la check.zip
