#!/usr/bin/env bash
#
# Build a macOS .app bundle + DMG for MySQL Genius Desktop.
#
# Prerequisites:
#   - rbenv with Ruby 3.4.8 (or adjust RUBY_VERSION below)
#   - Bundle dependencies installable
#
# Usage:
#   ./packaging/macos/build-dmg.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DESKTOP_GEM="$PROJECT_ROOT/gems/mysql_genius-desktop"
CORE_GEM="$PROJECT_ROOT/gems/mysql_genius-core"

# --- Configuration -----------------------------------------------------------
RUBY_VERSION="${MG_RUBY_VERSION:-3.4.8}"
APP_NAME="MySQL Genius"
APP_BUNDLE="MySQLGenius.app"
DMG_NAME="MySQL-Genius"
VERSION=$(RBENV_VERSION="$RUBY_VERSION" ruby -r "$DESKTOP_GEM/lib/mysql_genius/desktop/version" -e 'puts MysqlGenius::Desktop::VERSION')
BUILD_DIR="$PROJECT_ROOT/build/macos"
APP_DIR="$BUILD_DIR/$APP_BUNDLE"

echo "==> Building $APP_NAME v$VERSION (Ruby $RUBY_VERSION)"

# --- Clean previous build ----------------------------------------------------
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# --- Create .app bundle structure --------------------------------------------
echo "==> Creating .app bundle structure"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"
mkdir -p "$APP_DIR/Contents/Resources/app"

# --- Info.plist --------------------------------------------------------------
cat > "$APP_DIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>MySQL Genius</string>
    <key>CFBundleDisplayName</key>
    <string>MySQL Genius</string>
    <key>CFBundleIdentifier</key>
    <string>com.antarr.mysql-genius</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>mysql-genius</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

# --- Generate a simple app icon (blue database cylinder) ---------------------
echo "==> Generating app icon"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"

# Use Python to generate a simple icon if available, otherwise skip
if command -v python3 &>/dev/null; then
  python3 "$SCRIPT_DIR/generate-icon.py" "$ICONSET_DIR" 2>/dev/null || true
fi

# If iconset has files, convert to icns
if [ "$(ls -A "$ICONSET_DIR" 2>/dev/null)" ]; then
  iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null || true
fi

# --- Copy app source ---------------------------------------------------------
echo "==> Copying application source"
APP_RESOURCE="$APP_DIR/Contents/Resources/app"

# Copy the core gem
cp -R "$CORE_GEM/lib" "$APP_RESOURCE/core-lib"
cp "$CORE_GEM/mysql_genius-core.gemspec" "$APP_RESOURCE/"

# Copy the desktop gem
cp -R "$DESKTOP_GEM/lib" "$APP_RESOURCE/lib"
cp -R "$DESKTOP_GEM/exe" "$APP_RESOURCE/exe"
cp "$DESKTOP_GEM/mysql_genius-desktop.gemspec" "$APP_RESOURCE/"

# --- Bundle gems (standalone mode) -------------------------------------------
echo "==> Installing gem dependencies (standalone bundle)"

# Create a minimal Gemfile for the standalone bundle
cat > "$APP_RESOURCE/Gemfile" <<GEMFILE
source "https://rubygems.org"

gem "mysql_genius-core", path: "."
gem "mysql_genius-desktop", path: "."

# Direct dependencies (pinned from gemspecs)
gem "net-ssh", "~> 7.0"
gem "puma", "~> 6.0"
gem "sinatra", "~> 4.0"
gem "sqlite3", "~> 2.0"
gem "trilogy", "~> 2.9"
GEMFILE

# We need gemspec stubs that point to the right lib paths
cat > "$APP_RESOURCE/mysql_genius-core.gemspec" <<SPEC
Gem::Specification.new do |s|
  s.name    = "mysql_genius-core"
  s.version = "0.0.0"
  s.authors = ["Antarr Byrd"]
  s.summary = "core"
  s.files   = Dir["core-lib/**/*.{rb,erb}"]
  s.require_paths = ["core-lib"]
end
SPEC

cat > "$APP_RESOURCE/mysql_genius-desktop.gemspec" <<SPEC
Gem::Specification.new do |s|
  s.name    = "mysql_genius-desktop"
  s.version = "0.0.0"
  s.authors = ["Antarr Byrd"]
  s.summary = "desktop"
  s.files   = Dir["lib/**/*.{rb,erb}", "exe/*"]
  s.require_paths = ["lib"]
end
SPEC

(
  cd "$APP_RESOURCE"
  RBENV_VERSION="$RUBY_VERSION" bundle config set --local path vendor/bundle
  RBENV_VERSION="$RUBY_VERSION" bundle config set --local standalone true
  RBENV_VERSION="$RUBY_VERSION" bundle install --jobs 4 2>&1 | tail -5
)

# --- Create launcher script --------------------------------------------------
echo "==> Creating launcher script"
cat > "$APP_DIR/Contents/MacOS/mysql-genius" <<'LAUNCHER'
#!/usr/bin/env bash
#
# MySQL Genius macOS app launcher
#
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/../Resources/app" && pwd)"
LOG_DIR="$HOME/.config/mysql_genius/logs"
mkdir -p "$LOG_DIR"

# Find Ruby — prefer rbenv/asdf, fall back to system
find_ruby() {
  for candidate in \
    "$HOME/.rbenv/versions/3.4.8/bin/ruby" \
    "$HOME/.rbenv/versions/3.4.4/bin/ruby" \
    "$HOME/.rbenv/versions/3.3.0/bin/ruby" \
    "$HOME/.rbenv/versions/3.2.0/bin/ruby" \
    "$HOME/.rbenv/versions/3.1.4/bin/ruby" \
    "$HOME/.asdf/installs/ruby/3.4.8/bin/ruby" \
    "/opt/homebrew/opt/ruby/bin/ruby" \
    "/usr/local/opt/ruby/bin/ruby" \
    "$(command -v ruby 2>/dev/null || true)"; do
    if [ -x "$candidate" 2>/dev/null ]; then
      echo "$candidate"
      return
    fi
  done
  osascript -e 'display alert "MySQL Genius" message "Ruby 3.1+ is required but was not found.\n\nInstall via: brew install rbenv && rbenv install 3.4.8" as critical'
  exit 1
}

RUBY="$(find_ruby)"

# Verify Ruby version >= 3.1
RUBY_VER=$("$RUBY" -e 'puts RUBY_VERSION')
RUBY_MAJOR=$(echo "$RUBY_VER" | cut -d. -f1)
RUBY_MINOR=$(echo "$RUBY_VER" | cut -d. -f2)
if [ "$RUBY_MAJOR" -lt 3 ] || { [ "$RUBY_MAJOR" -eq 3 ] && [ "$RUBY_MINOR" -lt 1 ]; }; then
  osascript -e "display alert \"MySQL Genius\" message \"Ruby 3.1+ required, found $RUBY_VER.\n\nInstall via: rbenv install 3.4.8\" as critical"
  exit 1
fi

BUNDLER_DIR="$APP_DIR/vendor/bundle"
BUNDLE_SETUP="$APP_DIR/bundle/bundler/setup.rb"

# Pick a port (default 19306, find next available if taken)
PORT=19306
while lsof -i :"$PORT" &>/dev/null; do
  PORT=$((PORT + 1))
done

export BUNDLE_GEMFILE="$APP_DIR/Gemfile"
export BUNDLE_PATH="$BUNDLER_DIR"

# Start the sidecar in the background
"$RUBY" -r "$BUNDLE_SETUP" "$APP_DIR/exe/mysql-genius-sidecar" --port "$PORT" \
  >> "$LOG_DIR/sidecar.log" 2>&1 &
SIDECAR_PID=$!

# Wait for the server to be ready (up to 10 seconds)
for i in $(seq 1 40); do
  if curl -s "http://127.0.0.1:$PORT/" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

# Open the browser
open "http://127.0.0.1:$PORT"

# Wait for the sidecar process to exit
wait "$SIDECAR_PID" 2>/dev/null || true
LAUNCHER
chmod +x "$APP_DIR/Contents/MacOS/mysql-genius"

# --- Build DMG ---------------------------------------------------------------
echo "==> Creating DMG"
DMG_PATH="$BUILD_DIR/${DMG_NAME}-${VERSION}.dmg"
DMG_TEMP="$BUILD_DIR/dmg-staging"

mkdir -p "$DMG_TEMP"
cp -R "$APP_DIR" "$DMG_TEMP/$APP_NAME.app"

# Add a symlink to /Applications for drag-install
ln -s /Applications "$DMG_TEMP/Applications"

# Create the DMG
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_TEMP" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

# --- Done --------------------------------------------------------------------
DMG_SIZE=$(du -h "$DMG_PATH" | cut -f1)
echo ""
echo "==> Build complete!"
echo "    App:  $APP_DIR"
echo "    DMG:  $DMG_PATH ($DMG_SIZE)"
echo ""
echo "    To test the app directly:"
echo "      open \"$APP_DIR\""
echo ""
echo "    To mount the DMG:"
echo "      open \"$DMG_PATH\""
