#!/bin/sh
set -eu
ROOT=/var/jb
mkdir -p "$ROOT/usr/local/bin" "$ROOT/Library/LaunchDaemons" /var/mobile/Library/Logs
cp ly-executor.py "$ROOT/usr/local/bin/ly-executor.py"
chmod 755 "$ROOT/usr/local/bin/ly-executor.py"
cp com.ly.executor.plist "$ROOT/Library/LaunchDaemons/"
launchctl bootstrap system "$ROOT/Library/LaunchDaemons/com.ly.executor.plist" 2>/dev/null || launchctl kickstart -k system/com.ly.executor
curl -fsS http://127.0.0.1:8765/health
