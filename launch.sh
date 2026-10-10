#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
swift scripts/relaunch-app.swift "$PWD/build/MediaAnalysis Explorer.app"
./build-app.sh
if (( $# > 0 )); then
    open "$PWD/build/MediaAnalysis Explorer.app" --args "$@"
else
    open "$PWD/build/MediaAnalysis Explorer.app"
fi
