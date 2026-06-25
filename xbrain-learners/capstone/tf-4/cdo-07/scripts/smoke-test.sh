#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${BASE_URL:-}" ]]; then
  echo "::notice title=Smoke test skipped::BASE_URL is empty. Set STAGING_BASE_URL or PROD_BASE_URL repository variable to enable smoke tests."
  exit 0
fi

base_url="${BASE_URL%/}"

curl --fail --silent --show-error --max-time 10 "${base_url}/health" >/dev/null

echo "Smoke test passed for ${base_url}/health"
