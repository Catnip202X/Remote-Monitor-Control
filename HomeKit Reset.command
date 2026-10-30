#!/bin/bash
# Double-click to make the Apple Home TV forget its pairings and start over with a new
# identity and setup code (use when the Home app says the TV is already in a home).
CLI="/Applications/Remote Monitor Control.app/Contents/MacOS/monitorctl"
[[ -x "$CLI" ]] || CLI="$HOME/Applications/Remote Monitor Control.app/Contents/MacOS/monitorctl"
"$CLI" homekit reset
sleep 2
echo
"$CLI" homekit
