#!/usr/bin/env bash
# Build the POS APK, injecting --dart-define values from .env.
#
# The values are secrets: this script NEVER prints them and never echoes the
# flutter command line. Usage:
#     scripts/build_apk.sh            # debug
#     scripts/build_apk.sh release
#
# If .env is missing, the build still runs (Env.isConfigured stays false and
# the app simply works offline with sync disabled).
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-debug}"
defines=()

if [ -f .env ]; then
  while IFS='=' read -r key value || [ -n "$key" ]; do
    key="$(printf '%s' "$key" | tr -d '\r' | xargs)"
    case "$key" in ''|'#'*) continue ;; esac
    value="$(printf '%s' "$value" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    defines+=(--dart-define="$key=$value")
  done < .env
  echo ".env found: injecting ${#defines[@]} dart-define(s) (values not shown)."
else
  echo "No .env found: building without dart-defines (offline build)."
fi

flutter pub get >/dev/null
flutter build apk "--$mode" "${defines[@]}"

apk="build/app/outputs/flutter-apk/app-${mode}.apk"
if [ -f "$apk" ]; then
  echo "APK: $apk ($(stat -c '%s' "$apk") bytes)"
fi
