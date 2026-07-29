#!/usr/bin/env bash
# Minimal end-to-end smoke test against a running API.
#   ./scripts/smoke.sh [base_url]
set -euo pipefail

BASE="${1:-http://localhost:8000}"
EMAIL="test-user+$(date +%s)@prima.it"
TMP_AVATAR="$(mktemp -t avatar.XXXXXX).png"

# A valid 1x1 PNG, generated without needing ImageMagick or Pillow.
printf '\x89PNG\r\n\x1a\n' > "${TMP_AVATAR}"
python3 - "${TMP_AVATAR}" <<'PY'
import base64, sys
png = base64.b64decode(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)
open(sys.argv[1], "wb").write(png)
PY

echo "==> Liveness"
curl -fsS "${BASE}/health/live" | python3 -m json.tool

echo "==> Readiness"
curl -fsS "${BASE}/health/ready" | python3 -m json.tool

echo "==> POST /user"
curl -fsS -X POST "${BASE}/user" \
  -F "name=Test User" \
  -F "email=${EMAIL}" \
  -F "avatar=@${TMP_AVATAR};type=image/png" | python3 -m json.tool

echo "==> POST /user again (expects 409)"
curl -sS -o /dev/stderr -w '    HTTP %{http_code}\n' -X POST "${BASE}/user" \
  -F "name=Test User" -F "email=${EMAIL}" \
  -F "avatar=@${TMP_AVATAR};type=image/png"

echo "==> GET /users"
curl -fsS "${BASE}/users" | python3 -m json.tool

rm -f "${TMP_AVATAR}"
echo "==> Smoke test finished"
