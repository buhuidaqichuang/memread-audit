#!/bin/sh
# MemRead 一键更新（NewTerm 里以 root 执行）
# 用法： curl -sL https://raw.githubusercontent.com/buhuidaqichuang/memread-audit/main/update.sh -o /tmp/update.sh && echo 1 | sudo -S sh /tmp/update.sh
#
# 下载源自动加速：优先用设备 /var/mobile/Media 里的 memread.ipa（可用电脑经 AFC 预置），
# 其次走国内 GitHub 镜像，最后才直连。entitlements 内嵌在脚本里，不需要再联网拉。
set -e

REPO=buhuidaqichuang/memread-audit
IPA_URL="https://github.com/$REPO/releases/download/latest/memread.ipa"
APP_DIR=/Applications/memread.app
T=/tmp/memread_update

echo "[1/5] 获取最新包"
rm -rf "$T"
mkdir -p "$T/x"
ENT="$T/ent.plist"
cat > "$ENT" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>task_for_pid-allow</key>
	<true/>
	<key>com.apple.private.cs.debugger</key>
	<true/>
	<key>get-task-allow</key>
	<true/>
	<key>run-unsigned-code</key>
	<true/>
	<key>platform-application</key>
	<true/>
	<key>com.apple.private.skip-library-validation</key>
	<true/>
	<key>com.apple.private.security.no-container</key>
	<true/>
	<key>com.apple.private.security.no-sandbox</key>
	<true/>
	<key>com.apple.private.security.container-required</key>
	<false/>
	<key>com.apple.security.iokit-user-client-class</key>
	<array>
		<string>IOUserClient</string>
		<string>AGXDevice</string>
		<string>AGXDeviceUserClient</string>
		<string>AGXCommandQueue</string>
		<string>AGXGLContext</string>
		<string>AGXSharedUserClient</string>
		<string>IOAccelContext</string>
		<string>IOAccelContext2</string>
		<string>IOAccelDevice</string>
		<string>IOAccelDevice2</string>
		<string>IOAccelSharedUserClient</string>
		<string>IOAccelSharedUserClient2</string>
		<string>IOAccelSubmitter2</string>
		<string>IOSurfaceRootUserClient</string>
		<string>IOSurfaceAcceleratorClient</string>
		<string>IOMobileFramebufferUserClient</string>
	</array>
</dict>
</plist>
PLIST

valid_size() {
  # 至少 100 KB 才算一个完整 ipa
  [ -f "$1" ] && [ "$(wc -c < "$1" 2>/dev/null || echo 0)" -gt 100000 ]
}

IPA=""
for p in /private/var/mobile/Media/memread.ipa /var/mobile/Media/memread.ipa; do
  if valid_size "$p"; then
    echo "  使用本机已有 ipa：$p"
    cp "$p" "$T/memread.ipa"
    IPA="$T/memread.ipa"
    break
  fi
done

if [ -z "$IPA" ]; then
  for src in "https://ghfast.top/$IPA_URL" "https://gh-proxy.com/$IPA_URL" "https://github.moeyy.xyz/$IPA_URL" "$IPA_URL"; do
    echo "  尝试下载：$src"
    if curl -fL -m 45 --retry 2 --retry-delay 2 --retry-all-errors -o "$T/memread.ipa" "$src" 2>/dev/null; then
      if valid_size "$T/memread.ipa"; then
        IPA="$T/memread.ipa"
        echo "  下载成功：$src"
        break
      fi
    fi
    echo "  该源失败，换下一个"
  done
fi

if [ -z "$IPA" ]; then
  echo "所有下载源都失败。可以用电脑把 memread.ipa 放进 /var/mobile/Media 后再跑一次本脚本。"
  exit 1
fi
ls -l "$IPA"

echo "[2/5] 解包"
unzip -o "$IPA" -d "$T/x" >/dev/null
test -f "$T/x/Payload/memread.app/memread"

echo "[3/5] 替换 App"
rm -rf "$APP_DIR"
cp -R "$T/x/Payload/memread.app" /Applications/

echo "[4/5] 重新签名（带 entitlements）"
ldid -S"$ENT" "$APP_DIR/memread"

echo "[5/5] 刷新图标缓存"
uicache -a

echo "MEMREAD UPDATE OK"
