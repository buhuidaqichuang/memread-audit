#!/bin/sh
# MemRead 一键更新（NewTerm 里以 root 执行）
# 用法： curl -sL https://raw.githubusercontent.com/buhuidaqichuang/memread-audit/main/update.sh -o /tmp/update.sh && echo 1 | sudo -S sh /tmp/update.sh
set -e

REPO=buhuidaqichuang/memread-audit
IPA_URL="https://github.com/$REPO/releases/download/latest/memread.ipa"
ENT_URL="https://raw.githubusercontent.com/$REPO/main/dist/ent.plist"
APP_DIR=/Applications/memread.app
T=/tmp/memread_update

echo "[1/5] 下载最新包"
rm -rf "$T"
mkdir -p "$T/x"
curl -fL --retry 4 --retry-delay 3 -o "$T/memread.ipa" "$IPA_URL"
curl -fL --retry 4 --retry-delay 3 -o "$T/ent.plist" "$ENT_URL"
ls -l "$T/memread.ipa"

echo "[2/5] 解包"
unzip -o "$T/memread.ipa" -d "$T/x" >/dev/null
test -f "$T/x/Payload/memread.app/memread"

echo "[3/5] 替换 App"
rm -rf "$APP_DIR"
cp -R "$T/x/Payload/memread.app" /Applications/

echo "[4/5] 重新签名（带 entitlements）"
ldid -S"$T/ent.plist" "$APP_DIR/memread"

echo "[5/5] 刷新图标缓存"
uicache -a

echo "MEMREAD UPDATE OK"
