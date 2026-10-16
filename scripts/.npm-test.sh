#!/usr/bin/env bash
# scripts/.npm-test.sh — single command registered as the npm "test" hook.
# It runs the Flutter VM suite and the node/PGlite suite, then prints a summary.
# Exit policy: either suite failing is a failure (the previous `set -e` version
# exited on the first `flutter test` failure, so the summary never ran and a red
# build could be read as green).
set -uo pipefail
cd "$(dirname "$0")/.."

test_exit=0
node_exit=0

echo "=========== FLUTTER TEST ==========="
flutter test --reporter expanded || test_exit=$?

echo
echo "=========== NODE (PGlite + unit) ==========="
node --test \
  scripts/sql.test.js \
  scripts/env.test.js \
  scripts/font.test.js \
  scripts/import.test.js \
  scripts/verify.test.js \
  scripts/reset.test.js || node_exit=$?

echo
echo "======= SUMMARY ======="
echo "flutter test:  exit ${test_exit}"
echo "node --test:   exit ${node_exit}"
if [ "${test_exit}" -ne 0 ] || [ "${node_exit}" -ne 0 ]; then
  echo "OVERALL:        FAIL"
  exit 1
fi
echo "OVERALL:        OK"
