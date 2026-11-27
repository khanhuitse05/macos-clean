#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

VERSION=""
BUILD_NUMBER=""
SKIP_TESTS="false"
SKIP_NOTARIZE="false"
BUILD_ONLY="false"
SKIP_PUSH="false"
SKIP_GITHUB_RELEASE="false"
SKIP_HOMEBREW="false"
DRAFT="false"
PRERELEASE="false"

usage() {
  cat <<EOF
Usage: ./scripts/release.sh [options]

Options:
  --version <x.y.z>       Set MARKETING_VERSION in project.yml before building
  --build-number <n>      Set CURRENT_PROJECT_VERSION in project.yml
  --skip-tests            Skip MacosCleanCore unit tests
  --skip-notarize         Build & sign DMG locally without Apple notarization
  --build-only            Build, sign, and package DMG locally without publishing or creating a GitHub Release
  --skip-push             Commit web/version updates locally without pushing to origin/main
  --skip-github-release   Skip creating/updating GitHub Release on macos-clean
  --skip-homebrew         Skip bumping the cask in khanhuitse05/homebrew-tap
  --draft                 Create GitHub Release as a draft
  --prerelease            Mark GitHub Release as a prerelease
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION="$2"
      shift 2
      ;;
    --build-number)
      BUILD_NUMBER="$2"
      shift 2
      ;;
    --skip-tests)
      SKIP_TESTS="true"
      shift
      ;;
    --skip-notarize)
      SKIP_NOTARIZE="true"
      shift
      ;;
    --build-only)
      BUILD_ONLY="true"
      shift
      ;;
    --skip-push)
      SKIP_PUSH="true"
      shift
      ;;
    --skip-github-release)
      SKIP_GITHUB_RELEASE="true"
      shift
      ;;
    --skip-homebrew)
      SKIP_HOMEBREW="true"
      shift
      ;;
    --draft)
      DRAFT="true"
      shift
      ;;
    --prerelease)
      PRERELEASE="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

FASTLANE_ARGS=()
[[ -n "$VERSION" ]] && FASTLANE_ARGS+=("version:$VERSION")
[[ -n "$BUILD_NUMBER" ]] && FASTLANE_ARGS+=("build_number:$BUILD_NUMBER")
[[ "$SKIP_TESTS" == "true" ]] && FASTLANE_ARGS+=("skip_tests:true")
[[ "$SKIP_NOTARIZE" == "true" ]] && FASTLANE_ARGS+=("notarize:false")
[[ "$SKIP_PUSH" == "true" ]] && FASTLANE_ARGS+=("skip_push:true")
[[ "$SKIP_GITHUB_RELEASE" == "true" ]] && FASTLANE_ARGS+=("skip_github_release:true")
[[ "$SKIP_HOMEBREW" == "true" ]] && FASTLANE_ARGS+=("skip_homebrew:true")
[[ "$DRAFT" == "true" ]] && FASTLANE_ARGS+=("draft:true")
[[ "$PRERELEASE" == "true" ]] && FASTLANE_ARGS+=("prerelease:true")

if [[ "$BUILD_ONLY" == "true" ]]; then
  fastlane build "${FASTLANE_ARGS[@]}"
  fastlane package_dmg "${FASTLANE_ARGS[@]}"
else
  fastlane release "${FASTLANE_ARGS[@]}"
fi
