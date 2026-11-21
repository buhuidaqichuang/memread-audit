#!/bin/sh
# MemRead v7：干净重装，且不重启 SpringBoard
# 用法：curl -sL http://192.168.3.103:8000/install.sh -o /tmp/i.sh && echo 1 | sudo -S sh /tmp/i.sh
set -e

BASE=http://192.168.3.103:8000
T=/tmp/memread_install7
APP_DIR=/Applications/memread.app

echo "[1/6] 下载 ipa / entitlements"
rm -rf "$T"
mkdir -p "$T/x"
curl -fL -m 180 --connect-timeout 5 --retry 3 --retry-delay 2 -o "$T/memread.ipa" "$BASE/memread.ipa"
curl -fL -m 30 --connect-timeout 5 --retry 3 --retry-delay 2 -o "$T/ent.plist" "$BASE/ent.plist"
echo "ipa_bytes: $(stat -f '%z' "$T/memread.ipa")"

echo "[2/6] 解包并删除 macOS codesign 残留封条"
unzip -o "$T/memread.ipa" -d "$T/x" >/dev/null
SRC="$T/x/Payload/memread.app"
test -f "$SRC/memread"
rm -rf "$SRC/_CodeSignature"

echo "[3/6] ldid 重签并校验 entitlements"
ldid -S"$T/ent.plist" "$SRC/memread"
chmod 755 "$SRC/memread"
if ldid -e "$SRC/memread" | grep -q "task_for_pid-allow"; then
  echo "entitlement task_for_pid-allow: OK"
else
  echo "entitlement task_for_pid-allow: MISSING -> abort"
  exit 1
fi

echo "[4/6] 结束正在运行的 App，整目录替换"
killall -9 memread 2>/dev/null || true
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR"
cp -R "$SRC/." "$APP_DIR/"
date "+install %Y-%m-%d %H:%M:%S" > "$APP_DIR/VERSIONS.txt"
echo "bundle_files: $(ls "$APP_DIR" | wc -l)"

echo "[5/6] 刷新图标缓存（不重启桌面）"
if command -v uicache >/dev/null 2>&1; then
  uicache -p "$APP_DIR" >/dev/null 2>&1 || uicache -a >/dev/null 2>&1 || true
  echo "uicache: done (no respring)"
else
  echo "uicache: NOT FOUND"
fi

echo "[6/6] verify"
ls -l "$APP_DIR/memread" "$APP_DIR/Info.plist"
echo "codesig_dir: $( [ -d "$APP_DIR/_CodeSignature" ] && echo STILL_THERE || echo REMOVED )"
echo "marker: $(cat "$APP_DIR/VERSIONS.txt")"
echo "class_check: $(grep -a -q ValueScanViewController "$APP_DIR/memread" && echo HAS_VALSCAN || echo NO_VALSCAN)"
ldid -e "$APP_DIR/memread" | head -6

echo "MEMREAD INSTALL OK（未重启桌面，直接点图标打开即可）"
