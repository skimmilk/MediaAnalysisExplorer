#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
configuration="${1:-debug}"
swift build -c "$configuration" --disable-sandbox
app_dir="$PWD/build/MediaAnalysis Explorer.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$app_dir/Contents/Helpers"
cp -R ".build/$configuration/MediaAnalysisExplorer_MediaAnalysisExplorer.bundle" "$app_dir/Contents/Resources/"
cp ".build/$configuration/MediaAnalysisExplorer" "$app_dir/Contents/MacOS/MediaAnalysisExplorer"
cp ".build/$configuration/MediaAnalysisLauncher" "$app_dir/Contents/Helpers/MediaAnalysisLauncher"
cp scripts/Info.plist "$app_dir/Contents/Info.plist"
/usr/bin/codesign --force --sign - "$app_dir/Contents/Helpers/MediaAnalysisLauncher"
/usr/bin/codesign --force --sign - "$app_dir"
printf '%s\n' "$app_dir"
