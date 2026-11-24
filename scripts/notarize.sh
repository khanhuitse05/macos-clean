#!/usr/bin/env bash
set -euo pipefail

SUBMIT_ARTIFACT="${1:?Usage: notarize.sh <artifact.zip|artifact.dmg> <staple_target.app|artifact.dmg>}"
STAPLE_TARGET="${2:?Usage: notarize.sh <artifact.zip|artifact.dmg> <staple_target.app|artifact.dmg>}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/fastlane/.env"
if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

AUTH_ARGS=()
if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  AUTH_ARGS=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  AUTH_ARGS=(--apple-id "$APPLE_ID" --password "$APPLE_APP_SPECIFIC_PASSWORD" --team-id "${APPLE_TEAM_ID:-369462BHJ6}")
else
  PROFILE="${NOTARY_PROFILE:-macos-clean-notary}"
  AUTH_ARGS=(--keychain-profile "$PROFILE")
fi

echo "==> Submitting $(basename "$SUBMIT_ARTIFACT") to Apple Notary service..."
set +e
RESULT_JSON="$(xcrun notarytool submit "$SUBMIT_ARTIFACT" "${AUTH_ARGS[@]}" --wait --output-format json 2>&1)"
EXIT_CODE=$?
set -e

if [[ $EXIT_CODE -ne 0 ]]; then
  echo "$RESULT_JSON" >&2
  if [[ "$RESULT_JSON" == *"Keychain"* || "$RESULT_JSON" == *"credentials"* || "$RESULT_JSON" == *"profile"* ]]; then
    echo "" >&2
    echo "Notarization credentials not found. Run one-time setup:" >&2
    echo "  ./scripts/setup_notary.sh" >&2
  fi
  exit $EXIT_CODE
fi

STATUS_INFO="$(python3 -c '
import json, sys
data = json.loads(sys.argv[1])
print(data.get("id", ""))
print(data.get("status", ""))
' "$RESULT_JSON" 2>/dev/null || true)"

SUBMISSION_ID="$(echo "$STATUS_INFO" | sed -n '1p')"
STATUS="$(echo "$STATUS_INFO" | sed -n '2p')"

echo "==> Notary submission $SUBMISSION_ID status: ${STATUS:-unknown}"

if [[ "$STATUS" != "Accepted" ]]; then
  echo "Notarization failed! Fetching Apple notarization log..." >&2
  if [[ -n "$SUBMISSION_ID" ]]; then
    xcrun notarytool log "$SUBMISSION_ID" "${AUTH_ARGS[@]}" >&2 || true
  else
    echo "$RESULT_JSON" >&2
  fi
  exit 1
fi

echo "==> Stapling notarization ticket to $(basename "$STAPLE_TARGET")..."
xcrun stapler staple "$STAPLE_TARGET"
xcrun stapler validate "$STAPLE_TARGET"
