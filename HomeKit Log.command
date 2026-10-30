#!/bin/bash
# Double-click to save HomeKit troubleshooting info next to this file (homekit-debug.log):
# the pairing state, what the Mac advertises on the network, and the server's log.
cd "$(dirname "$0")"
CLI="/Applications/Remote Monitor Control.app/Contents/MacOS/monitorctl"
[[ -x "$CLI" ]] || CLI="$HOME/Applications/Remote Monitor Control.app/Contents/MacOS/monitorctl"
lookup() { "$@" > /tmp/rmc-dnssd.txt 2>&1 & local pid=$!; sleep 3; kill $pid 2>/dev/null; cat /tmp/rmc-dnssd.txt; }
{
  echo "== monitorctl homekit"
  "$CLI" homekit
  echo
  echo "== Bonjour: HomeKit accessories on this network"
  lookup dns-sd -B _hap._tcp local
  echo
  echo "== Bonjour: this accessory's record"
  NAME="$(sed -n 's/.* as "\(.*\)" id .*/\1/p' "$HOME/Library/Application Support/Remote Monitor Control/homekit.log" | tail -1)"
  [[ -n "$NAME" ]] && lookup dns-sd -L "$NAME" _hap._tcp local
  echo
  echo "== log"
  "$CLI" homekit log
} > homekit-debug.log 2>&1
echo "Saved homekit-debug.log"
