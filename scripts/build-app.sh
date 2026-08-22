#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="MirrorBridge"
APP_PATH="$PROJECT_ROOT/dist/$APP_NAME.app"

cd "$PROJECT_ROOT"

swift build -c release --product "$APP_NAME"
BIN_PATH="$(swift build -c release --show-bin-path)"

rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources/bin"

cp "$BIN_PATH/$APP_NAME" "$APP_PATH/Contents/MacOS/$APP_NAME"
cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"

if [[ -d "$PROJECT_ROOT/Tools/bin" ]]; then
	cp -R "$PROJECT_ROOT/Tools/bin/." "$APP_PATH/Contents/Resources/bin/"
fi

if [[ -n "${MIRRORBRIDGE_SIGNING_IDENTITY:-}" ]]; then
	if [[ -d "$APP_PATH/Contents/Resources/bin" ]]; then
		find "$APP_PATH/Contents/Resources/bin" -type f -perm -111 -exec \
			codesign --force --options runtime --sign "$MIRRORBRIDGE_SIGNING_IDENTITY" {} \;
	fi
	codesign --force --options runtime --sign "$MIRRORBRIDGE_SIGNING_IDENTITY" "$APP_PATH"
fi

echo "Created $APP_PATH"
