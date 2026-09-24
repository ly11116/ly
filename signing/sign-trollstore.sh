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
# 5. 打包
# 注意：下面会 cd 进临时目录，必须先把输出路径解析成绝对路径，
# 否则相对路径在 cd 之后失效 → zip: Could not create output file。
OUT_DIR=$(dirname "$OUT_IPA")
OUT_NAME=$(basename "$OUT_IPA")
mkdir -p "$OUT_DIR"
OUT_ABS="$(cd "$OUT_DIR" && pwd)/$OUT_NAME"

echo "--- step 5: packaging ---"
echo "OUT_ABS=$OUT_ABS"
( cd "$WORK" && zip -qry "$OUT_ABS" Payload )
test -s "$OUT_ABS" || { echo "FATAL: zip 未产出文件"; exit 1; }
echo "OK -> $OUT_ABS"
ls -la "$OUT_ABS"

# 6. 自检：确认强化 entitlements 真的嵌进去了
#
# 注意：codesign 不同版本把 --entitlements 的输出写到 stdout 或 stderr 不确定，
# 所以这里 **两个流都抓**（2>&1）。之前只抓 stdout 并 2>/dev/null，
# 在输出走 stderr 的版本上会得到空文件 → 误报「权限未嵌入」。
echo "--- step 6: entitlement self-check ---"
ENT_DUMP="$(codesign -d --entitlements :- "$APP" 2>&1 || true)"
printf '%s' "$ENT_DUMP" > /tmp/_ent.plist
printf '%s\n' "$ENT_DUMP" | head -50

# 兜底：若 codesign 输出解析不到 <key>，直接从二进制里找 entitlement 字串
if ! grep -q "<key>" /tmp/_ent.plist; then
  echo "NOTE: codesign 输出未含 plist，改用二进制字串兜底检查"
  strings "$APP/Minis" > /tmp/_ent_bin.txt 2>/dev/null || true
  cat /tmp/_ent.txt 2>/dev/null >> /tmp/_ent_bin.txt || true
  cp /tmp/_ent_bin.txt /tmp/_ent.plist
fi

fail=0
for k in com.apple.security.application-groups \
         com.apple.private.hid.client.event-dispatch \
         com.apple.private.hid.client.event-filter \
         com.apple.private.iosurface \
         com.apple.private.mobileinstall.allowedSPI \
         com.apple.security.cs.allow-jit; do
  if grep -q "$k" /tmp/_ent.plist; then echo "  OK $k"; else echo "  MISSING $k"; fail=1; fi
done
if [ $fail -ne 0 ]; then
  echo "FATAL: entitlements 未完整嵌入（上面列出缺失项）"
  exit 1
fi

# 关键断言：App Group 的值必须是 group.com.ly.minis。
# 缺了它 Minis 启动时拿不到共享容器 → EXC_BREAKPOINT/SIGTRAP（实测过）。
if grep -q "group.com.ly.minis" /tmp/_ent.plist; then
  echo "  OK group.com.ly.minis (app group value)"
else
  echo "  FATAL: 缺少 group.com.ly.minis —— 启动会 SIGTRAP"
  exit 1
fi

# 反向断言：确认那些会破坏沙箱语义的激进权限没有被带进来
for k in platform-application \
         com.apple.private.security.no-sandbox \
         com.apple.private.security.no-container \
         task_for_pid-allow; do
  if grep -q "$k" /tmp/_ent.plist; then
    echo "  WARNING: 含有激进权限 $k（已知会导致启动问题）"
  fi
done

echo "用 TrollStore 安装此 IPA。安装后检查: 设置里确认 Minis 出现, 启动不闪退。"
