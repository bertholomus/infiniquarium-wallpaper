#!/bin/bash
# Removes the Infiniquarium wallpaper app. Your tank's save file is kept unless you pass --all.
ID="com.infiniquarium.wallpaper"
if pgrep -x Infiniquarium >/dev/null 2>&1; then
  pkill -TERM -x Infiniquarium || true
  for _ in $(seq 1 40); do pgrep -x Infiniquarium >/dev/null 2>&1 || break; sleep 0.2; done
fi
rm -rf "$HOME/Applications/Infiniquarium.app"
rm -f "$HOME/Library/LaunchAgents/$ID.plist"
defaults delete "$ID" >/dev/null 2>&1 || true
if [ "${1:-}" = "--all" ]; then
  rm -rf "$HOME/Library/Application Support/Infiniquarium"
  echo "Removed Infiniquarium and its saved tank."
else
  echo "Removed Infiniquarium. The tank is still saved in ~/Library/Application Support/Infiniquarium"
  echo "(run this with --all to delete it too)."
fi
