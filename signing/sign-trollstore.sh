#!/bin/sh
# TrollStore 签名流水线：给 unsigned IPA 的主 App 追加强化 entitlements 并重签
# 用法: sh sign-trollstore.sh <unsigned.ipa> [输出.ipa]
# 前提: macOS + Xcode(codesign) 或 ldid 可用。输出必须用 TrollStore 安装。
set -eu

IN_IPA="${1:?usage: sign-trollstore.sh <unsigned.ipa> [out.ipa]}"
OUT_IPA="${2:-${IN_IPA%.ipa}-trollstore.ipa}"
HERE=$(cd "$(dirname "$0")" && pwd)
ENT="${HERE}/TrollStore-entitlements.plist"

command -v codesign >/dev/null 2>&1 || { echo 'codesign not found (need macOS/Xcode)'; exit 1; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

unzip -q "$IN_IPA" -d "$WORK"
APP="$WORK/Payload/Minis.app"
[ -d "$APP" ] || { echo "Payload/Minis.app not found in $IN_IPA"; exit 1; }

# 1. Frameworks 先签
find "$APP/Frameworks" -maxdepth 2 -type f -perm -111 2>/dev/null | while read -r f; do
  codesign --force --sign - --timestamp=none "$f"
done

# 2. appex 重签(用各自目录里的 entitlements 如有, 没有则裸签保持可用)
for appex in "$APP"/PlugIns/*.appex; do
  [ -d "$appex" ] || continue
  if [ -f "$appex.appex.entitlements" ]; then
    codesign --force --sign - --entitlements "$appex.appex.entitlements" --timestamp=none "$appex"
  else
    codesign --force --sign - --timestamp=none "$appex"
  fi
done

# 3. 主 App：ad-hoc 签 + 强化 entitlements(TrollStore CoreTrust bypass 接收它)
codesign --force --sign - --entitlements "$ENT" --timestamp=none "$APP"

# 4. 验证
codesign --verify --verbose=2 "$APP" || true

# 5. 打包
mkdir -p "$(dirname "$OUT_IPA")"
cd "$WORK" && zip -qry "$OUT_IPA" Payload
echo "OK -> $OUT_IPA"
echo "用 TrollStore 安装此 IPA。安装后检查: 设置里确认 Minis 出现, 启动不闪退。"
