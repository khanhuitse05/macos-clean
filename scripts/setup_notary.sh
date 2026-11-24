#!/usr/bin/env bash
set -euo pipefail

PROFILE="${1:-macos-clean-notary}"
TEAM_ID="${APPLE_TEAM_ID:-369462BHJ6}"

echo "Setting up Apple Notarization keychain profile: $PROFILE (Team: $TEAM_ID)"
echo ""
echo "You need an App-Specific Password from https://account.apple.com"
echo "(Sign in -> Sign-In and Security -> App-Specific Passwords -> Generate)"
echo ""
read -r -p "Apple ID email: " APPLE_ID_INPUT

xcrun notarytool store-credentials "$PROFILE" \
  --apple-id "$APPLE_ID_INPUT" \
  --team-id "$TEAM_ID"

echo ""
echo "Saved keychain profile '$PROFILE'."
echo "You can now run: fastlane release"
