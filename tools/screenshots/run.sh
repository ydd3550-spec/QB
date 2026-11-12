#!/usr/bin/env bash
# يشغّل QB على محاكي آيفون (داكن، بالعربي)، يمشي على الشاشات بـ XCUITest ويصوّرها،
# بعدين يطلّع الصور PNG في build/shots ويضغطها build/shots.zip
set -uo pipefail
mkdir -p build/shots/raw

UDID=$(xcrun simctl list devices available -j | python3 -c '
import json, sys, re
d = json.load(sys.stdin)["devices"]
def ver(rt):
    m = re.search(r"iOS-(\d+)-(\d+)", rt)
    return (int(m.group(1)), int(m.group(2))) if m else (0, 0)
rts = sorted([rt for rt in d if "iOS" in rt and ver(rt) >= (26, 0)], key=ver, reverse=True)
prefs = ["iPhone 17 Pro", "iPhone 16 Pro", "iPhone 17", "iPhone 16", "iPhone Air"]
for p in prefs:
    for rt in rts:
        for dev in d[rt]:
            if dev["name"] == p:
                print(dev["udid"], file=sys.stdout); sys.stderr.write(p + " " + rt + "\n"); sys.exit(0)
for rt in rts:
    for dev in d[rt]:
        if dev["name"].startswith("iPhone"):
            print(dev["udid"]); sys.stderr.write(dev["name"] + " " + rt + "\n"); sys.exit(0)
')
[ -n "$UDID" ] || { echo "no iOS 26 iPhone simulator"; xcrun simctl list runtimes; exit 1; }
echo "simulator: $UDID"

xcrun simctl boot "$UDID" || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl ui "$UDID" appearance dark
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryState charged --batteryLevel 100 \
  --wifiBars 3 --cellularBars 4 --dataNetwork wifi || true

set -o pipefail
xcodebuild test -workspace QB.xcworkspace -scheme QBShots -destination "id=$UDID" \
  -derivedDataPath build/DD -resultBundlePath build/shots.xcresult \
  CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
  2>&1 | tee build/shots-test.log | grep -E "TOUR:|error:|Test Case|TEST (SUCCEEDED|FAILED)|\*\* " | grep -v "debugDescription" | cut -c1-200
echo "xcodebuild exit: ${PIPESTATUS[0]}"

xcrun xcresulttool export attachments --path build/shots.xcresult --output-path build/shots/raw \
  || echo "attachment export failed"
ls -la build/shots/raw | head -60

# شاشة التنبيه لما الحفظ يفشل: نسد مجلدات الحفظ بملفات بنفس الاسم، فالنواة تشتغل بالذاكرة وتطلع رسالة الخطأ الحقيقية
DATA=$(xcrun simctl get_app_container "$UDID" com.y.qb data 2>/dev/null || true)
if [ -n "$DATA" ]; then
  xcrun simctl terminate "$UDID" com.y.qb 2>/dev/null || true
  rm -rf "$DATA/Library/Application Support/QB" "$DATA/Library/Caches/QB" "$DATA/tmp/QB"
  mkdir -p "$DATA/Library/Application Support" "$DATA/Library/Caches" "$DATA/tmp"
  touch "$DATA/Library/Application Support/QB" "$DATA/Library/Caches/QB" "$DATA/tmp/QB"
  xcrun simctl launch "$UDID" com.y.qb -AppleLanguages "(ar)" -AppleLocale ar_SA
  sleep 15
  xcrun simctl io "$UDID" screenshot build/shots/30_storage_warning.png
  xcrun simctl terminate "$UDID" com.y.qb 2>/dev/null || true
else
  echo "app container not found"
fi

# سجل الجهاز للتشخيص
xcrun simctl spawn "$UDID" log show --last 20m --predicate 'subsystem == "app.qb"' --style compact > build/shots/app-log.txt 2>&1 || true
grep -E "TOUR:" build/shots-test.log | grep -v "^ *$" | cut -c1-2000 > build/shots/tour.txt || true

cd build && rm -f shots.zip && zip -qr shots.zip shots shots-test.log && ls -la shots.zip
