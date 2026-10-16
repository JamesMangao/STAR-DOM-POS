#!/usr/bin/env bash
# Build the POS APK. --dart-define values come from the SINGLE loader
# scripts/env.js, which reads only D:\STARDOM-POS\.env and emits only the
# four whitelisted keys (SUPABASE_URL, SUPABASE_ANON_KEY, OWNER_EMAIL,
# OWNER_PASSWORD). SERVICE_ROLE_KEY and DB_URL are never emitted — env.js
# exits non-zero if they would be.
#
# The values are secrets: this script never prints them and never echoes the
# flutter command line. Usage: scripts/build_apk.sh [debug|release]
set -euo pipefail
cd "$(dirname "$0")/.."

mode="${1:-debug}"
command -v node >/dev/null || { echo "node is required"; exit 1; }

defines=()
while IFS= read -r line; do
  [ -n "$line" ] && defines+=("$line")
done < <(node scripts/env.js --dart-defines)

if [ "${#defines[@]}" -gt 0 ]; then
  echo "injecting ${#defines[@]} whitelisted dart-define(s) (values not shown)."
else
  echo "no .env values for the whitelist: building without dart-defines (offline build)."
fi

flutter pub get >/dev/null
flutter build apk "--$mode" "${defines[@]}"

apk="build/app/outputs/flutter-apk/app-${mode}.apk"
if [ -f "$apk" ]; then
  echo "APK: $apk ($(stat -c '%s' "$apk") bytes)"
fi
