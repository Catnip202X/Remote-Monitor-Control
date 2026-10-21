#!/bin/bash
# Double-click to build and install Remote Monitor Control. Output is also saved to build.log.
cd "$(dirname "$0")"
./build.sh 2>&1 | tee build.log
echo
echo "Press Return to close."
read -r _
