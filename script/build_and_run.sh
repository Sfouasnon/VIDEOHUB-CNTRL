#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
DISPLAY_NAME="Videohub On-Set"
EXECUTABLE_NAME="VideohubOnSet"
BUNDLE_ID="com.videohubonset.VideohubOnSet"
MIN_SYSTEM_VERSION="14.0"
SCHEME_NAME="VideohubOnSet"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/VideohubOnSet.xcodeproj"
XCODE_DERIVED_DATA="$ROOT_DIR/.build/xcode-derived-data"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE=""
APP_BINARY=""

# Codex machines can have the Command Line Tools selected even when the full
# Xcode app is installed. Prefer the project build without changing the user's
# global xcode-select setting; SwiftPM remains the fallback when Xcode is absent.
if ! xcodebuild -version >/dev/null 2>&1 \
  && [[ -x /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild ]]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

usage() {
  echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
}

case "$MODE" in
  run|--run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify)
    ;;
  *)
    usage
    exit 2
    ;;
esac

stop_previous_instance() {
  pkill -x "$EXECUTABLE_NAME" >/dev/null 2>&1 || true
}

has_usable_xcode() {
  command -v xcodebuild >/dev/null 2>&1 || return 1
  xcodebuild -version >/dev/null 2>&1 || return 1
  [[ -d "$PROJECT_PATH" ]]
}

build_with_xcode() {
  echo "Building $DISPLAY_NAME with Xcode..."
  xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME_NAME" \
    -configuration Debug \
    -destination "platform=macOS" \
    -derivedDataPath "$XCODE_DERIVED_DATA" \
    build

  APP_BUNDLE="$XCODE_DERIVED_DATA/Build/Products/Debug/$DISPLAY_NAME.app"
  APP_BINARY="$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"
  [[ -x "$APP_BINARY" ]] || {
    echo "error: Xcode build did not produce $APP_BINARY" >&2
    exit 1
  }
}

stage_swiftpm_bundle() {
  echo "Full Xcode is not selected; building $DISPLAY_NAME with SwiftPM..."
  swift build --package-path "$ROOT_DIR" --product "$EXECUTABLE_NAME"

  local swift_bin_dir
  local build_binary
  swift_bin_dir="$(swift build --package-path "$ROOT_DIR" --show-bin-path)"
  build_binary="$swift_bin_dir/$EXECUTABLE_NAME"
  [[ -x "$build_binary" ]] || {
    echo "error: SwiftPM build did not produce $build_binary" >&2
    exit 1
  }

  APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"
  APP_BINARY="$APP_BUNDLE/Contents/MacOS/$EXECUTABLE_NAME"

  case "$APP_BUNDLE" in
    "$ROOT_DIR"/dist/*.app) ;;
    *)
      echo "error: refusing to replace unexpected bundle path: $APP_BUNDLE" >&2
      exit 1
      ;;
  esac

  /bin/rm -rf -- "$APP_BUNDLE"
  /bin/mkdir -p "$APP_BUNDLE/Contents/MacOS"
  /bin/cp "$build_binary" "$APP_BINARY"
  /bin/chmod +x "$APP_BINARY"

  # The Xcode path gets its icon from the asset catalog. This hand-staged
  # bundle has no asset catalog, so compile the .iconset with iconutil and
  # install the result; without it the Dock falls back to the generic Unix
  # executable icon. iconutil ships with the Command Line Tools, so it is
  # available on exactly the machines that end up on this code path.
  local iconset="$ROOT_DIR/Resources/AppIcon.iconset"
  local icns="$ROOT_DIR/.build/AppIcon.icns"
  if [[ -d "$iconset" ]] && command -v iconutil >/dev/null 2>&1; then
    /bin/mkdir -p "$(dirname "$icns")"
    if iconutil --convert icns "$iconset" --output "$icns"; then
      /bin/mkdir -p "$APP_BUNDLE/Contents/Resources"
      /bin/cp "$icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    else
      echo "warning: iconutil failed; app will use the generic icon" >&2
    fi
  else
    echo "warning: no AppIcon.iconset or iconutil; app will use the generic icon" >&2
  fi

  /usr/bin/plutil -create xml1 "$APP_BUNDLE/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleExecutable -string "$EXECUTABLE_NAME" "$APP_BUNDLE/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$BUNDLE_ID" "$APP_BUNDLE/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleName -string "$DISPLAY_NAME" "$APP_BUNDLE/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleDisplayName -string "$DISPLAY_NAME" "$APP_BUNDLE/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundlePackageType -string APPL "$APP_BUNDLE/Contents/Info.plist"
  /usr/bin/plutil -insert LSMinimumSystemVersion -string "$MIN_SYSTEM_VERSION" "$APP_BUNDLE/Contents/Info.plist"
  /usr/bin/plutil -insert NSPrincipalClass -string NSApplication "$APP_BUNDLE/Contents/Info.plist"
  /usr/bin/plutil -insert NSHighResolutionCapable -bool true "$APP_BUNDLE/Contents/Info.plist"
  if [[ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]]; then
    /usr/bin/plutil -insert CFBundleIconFile -string AppIcon "$APP_BUNDLE/Contents/Info.plist"
  fi
  /usr/bin/plutil -insert NSLocalNetworkUsageDescription -string "Videohub On-Set connects to Blackmagic Design Videohub routers on your local network." "$APP_BUNDLE/Contents/Info.plist"

  if command -v codesign >/dev/null 2>&1; then
    codesign --force --sign - \
      --entitlements "$ROOT_DIR/VideohubOnSet/VideohubOnSet.entitlements" \
      "$APP_BUNDLE"
  fi

  # LaunchServices caches icons per bundle path, so a rebuild in place can keep
  # showing the previous icon. Re-register and bump the mtime to invalidate it.
  /usr/bin/touch "$APP_BUNDLE"
  local lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  [[ -x "$lsregister" ]] && "$lsregister" -f "$APP_BUNDLE" >/dev/null 2>&1 || true
}

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_process() {
  local attempts=50
  while (( attempts > 0 )); do
    if pgrep -x "$EXECUTABLE_NAME" >/dev/null; then
      echo "$DISPLAY_NAME is running."
      return 0
    fi
    sleep 0.1
    ((attempts -= 1))
  done

  echo "error: $DISPLAY_NAME did not remain running after launch" >&2
  return 1
}

stop_previous_instance

if has_usable_xcode; then
  build_with_xcode
else
  stage_swiftpm_bundle
fi

case "$MODE" in
  run|--run)
    open_app
    ;;
  --debug|debug)
    exec lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    exec /usr/bin/log stream --info --style compact --predicate "process == \"$EXECUTABLE_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    verify_process
    ;;
esac
