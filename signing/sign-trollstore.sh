#!/bin/sh
# TrollStore 签名流水线：给 unsigned IPA 追加/保留 entitlements 并重签
#
# 用法: sh sign-trollstore.sh <unsigned.ipa> [输出.ipa]
#
# ⚠️ 核心原则（踩过坑）：
#   必须使用 **App 自带的 entitlements**（src/ios/Minis.entitlements），
#   不能替换成一份自己写的清单。
#
#   原因：代码里硬编码了 `group.com.openminis.app`（app group / iCloud
#   container / UserDefaults suite）。若签名只授予别的 group，
#   `containerURL(forSecurityApplicationGroupIdentifier:)` 返回 nil，
#   而代码里有强制解包 → 启动即 EXC_BREAKPOINT/SIGTRAP。
#
#   上游的 Minis.entitlements 本就为 TrollStore 设计，已含
#   group.com.openminis.app / HID 注入 / iosurface / SPI 等全部权限。
#
# 前提: macOS + Xcode(codesign)。输出必须用 TrollStore 安装。
set -eu

IN_IPA="${1:?usage: sign-trollstore.sh <unsigned.ipa> [out.ipa]}"
OUT_IPA="${2:-${IN_IPA%.ipa}-trollstore.ipa}"
HERE=$(cd "$(dirname "$0")" && pwd)
SRC_ROOT="$(cd "$HERE/.." && pwd)/src/ios"

MAIN_ENT="${SRC_ROOT}/Minis.entitlements"
[ -f "$MAIN_ENT" ] || { echo "FATAL: 找不到 $MAIN_ENT"; exit 1; }

command -v codesign >/dev/null 2>&1 || { echo 'codesign not found (need macOS/Xcode)'; exit 1; }

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

unzip -q "$IN_IPA" -d "$WORK"
APP="$WORK/Payload/Minis.app"
[ -d "$APP" ] || { echo "Payload/Minis.app not found in $IN_IPA"; exit 1; }

echo "--- step 1: Frameworks ---"
find "$APP/Frameworks" -maxdepth 2 -type f -perm -111 2>/dev/null | while read -r f; do
  codesign --force --sign - --timestamp=none "$f"
done

echo "--- step 2: app extensions ---"
# 每个扩展必须带上 app group，否则扩展进程读不到共享容器。
# 优先用该扩展目录下的 .entitlements；找不到就用一份只含 app group 的生成文件。
GEN_APPEX_ENT="$WORK/_appex.entitlements"
cat > "$GEN_APPEX_ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.com.ly.minis</string>
	</array>
</dict>
</plist>
PLIST

for appex in "$APP"/PlugIns/*.appex; do
  [ -d "$appex" ] || continue
  base=$(basename "$appex" .appex)
  ent=""
  # 在源码树里找同名/近名的 entitlements
  for cand in "$SRC_ROOT"/FileProvider/FileProvider.entitlements \
              "$SRC_ROOT"/ShareExtension/ShareExtension.entitlements \
              "$SRC_ROOT"/AgentWidget/AgentWidget.entitlements; do
    [ -f "$cand" ] || continue
    nm=$(basename "$cand" .entitlements)
    case "$base$nm" in
      *FileProvider*) [ -z "$ent" ] && ent="$cand" ;;
      *Share*)        [ -z "$ent" ] && ent="$cand" ;;
      *Widget*)       [ -z "$ent" ] && ent="$cand" ;;
    esac
  done
  [ -n "$ent" ] || ent="$GEN_APPEX_ENT"
  echo "    $base  <- $(basename "$ent")"
  codesign --force --sign - --entitlements "$ent" --timestamp=none "$appex"
done

echo "--- step 3: main app ---"
# 直接使用 App 自带的 entitlements —— 与代码里硬编码的
# group.com.openminis.app 完全一致，这是启动不崩的关键。
codesign --force --sign - --entitlements "$MAIN_ENT" --timestamp=none "$APP"

echo "--- step 4: verify ---"
codesign --verify --verbose=2 "$APP" || true

echo "--- step 5: packaging ---"
OUT_DIR=$(dirname "$OUT_IPA")
OUT_NAME=$(basename "$OUT_IPA")
mkdir -p "$OUT_DIR"
OUT_ABS="$(cd "$OUT_DIR" && pwd)/$OUT_NAME"

( cd "$WORK" && zip -qry "$OUT_ABS" Payload )
test -s "$OUT_ABS" || { echo "FATAL: zip 未产出文件"; exit 1; }
echo "OK -> $OUT_ABS"
ls -la "$OUT_ABS"

echo "--- step 6: entitlement self-check ---"
ENT_DUMP="$(codesign -d --entitlements :- "$APP" 2>&1 || true)"
printf '%s' "$ENT_DUMP" > /tmp/_ent.plist
printf '%s\n' "$ENT_DUMP" | head -60

fail=0
# 必需：app group 必须与代码一致（否则启动 SIGTRAP）
for k in com.apple.security.application-groups \
         com.apple.private.hid.client.event-dispatch \
         com.apple.private.iosurface \
         com.apple.private.mobileinstall.allowedSPI; do
  if grep -q "$k" /tmp/_ent.plist; then echo "  OK $k"; else echo "  MISSING $k"; fail=1; fi
done
# app group 的值必须包含代码要求的那个
if grep -q "group\.com\.ly\.minis" /tmp/_ent.plist; then
  echo "  OK group.com.ly.minis (代码与 entitlements 一致的那个)"
else
  echo "  FATAL: 缺少 group.com.ly.minis —— 启动会 SIGTRAP"
  fail=1
fi
[ $fail -eq 0 ] || { echo "FATAL: entitlements 校验失败"; exit 1; }

echo "--- step 7: 扩展的 app group ---"
for appex in "$APP"/PlugIns/*.appex; do
  [ -d "$appex" ] || continue
  if codesign -d --entitlements :- "$appex" 2>&1 | grep -q "group.com.ly.minis"; then
    echo "  OK $(basename "$appex")"
  else
    echo "  WARN $(basename "$appex") 未包含 app group"
  fi
done

echo "用 TrollStore 安装此 IPA。"
