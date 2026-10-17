#!/bin/zsh
# Builds dist/Veer AI Editor.app: a single native process plus the bundled Mihomo validator.
set -eu
cd "${0:A:h}/.."
# The macOS 27 Command Line Tools SDK needs Xcode's SwiftUI macro plugin; 26.5 does not.
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
validator="${VEER_MIHOMO_BIN:-$PWD/../../prototype/ai-editor/.cache/mihomo}"
if [[ ! -x "$validator" ]]; then
  print -u2 "未找到 Mihomo 校验器：$validator"
  print -u2 "请在 go_core/third_party/mihomo 构建，或设置 VEER_MIHOMO_BIN。"
  exit 1
fi
arch="$(uname -m)"
lipo -verify_arch "$arch" "$validator"
swift build -c release --product VeerAIEditor
bin_dir="$(swift build -c release --show-bin-path)"
app="$PWD/dist/Veer AI Editor.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/bin" "$app/Contents/Resources/licenses"
cp "$bin_dir/VeerAIEditor" "$app/Contents/MacOS/VeerAIEditor"
cp Resources/Info.plist "$app/Contents/Info.plist"
cp "$validator" "$app/Contents/Resources/bin/mihomo"
cp ../../go_core/third_party/mihomo/LICENSE "$app/Contents/Resources/licenses/mihomo-LICENSE"
cp .build/checkouts/Yams/LICENSE "$app/Contents/Resources/licenses/Yams-LICENSE"
codesign --force --sign - "$app/Contents/Resources/bin/mihomo"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
print -r -- "$app"
