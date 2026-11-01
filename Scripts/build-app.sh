#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_dir/.." && pwd)"
app_path="$project_root/dist/PAPower.app"

plutil -lint "$project_root/Resources/Info.plist" >/dev/null
swift build --package-path "$project_root" -c release --product PAPower
binary_dir="$(swift build --package-path "$project_root" -c release --show-bin-path)"

if [[ -d "$app_path" ]]; then
    rm -rf "$app_path"
fi

mkdir -p "$app_path/Contents/MacOS"
cp "$binary_dir/PAPower" "$app_path/Contents/MacOS/PAPower"
cp "$project_root/Resources/Info.plist" "$app_path/Contents/Info.plist"

# 应用图标：Icon Composer 格式（Resources/AppIcon.icon），由 actool 编译为 Assets.car 与旧系统用的 AppIcon.icns。
mkdir -p "$app_path/Contents/Resources"
icon_plist="$(mktemp -t papower-icon)"
xcrun actool "$project_root/Resources/AppIcon.icon" \
    --compile "$app_path/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target 13.0 \
    --app-icon AppIcon \
    --target-device mac \
    --output-partial-info-plist "$icon_plist" >/dev/null
rm -f "$icon_plist"
codesign --force --sign - "$app_path" >/dev/null

echo "已生成：$app_path"
