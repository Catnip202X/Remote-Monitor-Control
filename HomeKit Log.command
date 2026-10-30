#!/bin/bash
# Double-click to save the HomeKit server's log next to this file (homekit-debug.log),
# for troubleshooting pairing with the Home app.
cd "$(dirname "$0")"
CLI="/Applications/Remote Monitor Control.app/Contents/MacOS/monitorctl"
[[ -x "$CLI" ]] || CLI="$HOME/Applications/Remote Monitor Control.app/Contents/MacOS/monitorctl"
{
  echo "== monitorctl homekit"
  "$CLI" homekit
  echo
  echo "== log"
  "$CLI" homekit log
} > homekit-debug.log 2>&1
echo "Saved homekit-debug.log"
