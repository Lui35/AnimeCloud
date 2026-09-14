#!/usr/bin/env bash

set -euo pipefail

PROJECT_PATH="${PROJECT_PATH:-AnimeCloud.xcodeproj}"
SCHEME="${SCHEME:-AnimeCloud}"
CONFIGURATION="${CONFIGURATION:-Release}"
OUTPUT_DIR="${OUTPUT_DIR:-Build/Unsigned}"
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-Build/DerivedData-Unsigned}"
IPA_NAME="${IPA_NAME:-AnimeCloud-unsigned.ipa}"

mkdir -p "${OUTPUT_DIR}"
OUTPUT_FILE="$(cd "${OUTPUT_DIR}" && pwd)/${IPA_NAME}"
rm -f "${OUTPUT_FILE}"

XCODEBUILD_ARGUMENTS=(
  -project "${PROJECT_PATH}"
  -scheme "${SCHEME}"
  -configuration "${CONFIGURATION}"
  -sdk iphoneos
  -destination "generic/platform=iOS"
  -derivedDataPath "${DERIVED_DATA_PATH}"
  CODE_SIGNING_ALLOWED=NO
  CODE_SIGNING_REQUIRED=NO
  CODE_SIGN_IDENTITY=""
)

if [[ -n "${MARKETING_VERSION:-}" ]]; then
  XCODEBUILD_ARGUMENTS+=("MARKETING_VERSION=${MARKETING_VERSION}")
fi

if [[ -n "${BUILD_NUMBER:-}" ]]; then
  XCODEBUILD_ARGUMENTS+=("CURRENT_PROJECT_VERSION=${BUILD_NUMBER}")
fi

xcodebuild "${XCODEBUILD_ARGUMENTS[@]}" clean build

APP_PATH="${DERIVED_DATA_PATH}/Build/Products/${CONFIGURATION}-iphoneos/${SCHEME}.app"
if [[ ! -d "${APP_PATH}" ]]; then
  echo "Expected app bundle was not produced at ${APP_PATH}" >&2
  exit 1
fi

PACKAGE_DIR="$(mktemp -d)"
trap 'rm -rf "${PACKAGE_DIR}"' EXIT
mkdir -p "${PACKAGE_DIR}/Payload"
ditto "${APP_PATH}" "${PACKAGE_DIR}/Payload/${SCHEME}.app"

# LiveContainer signs the app when it is installed, so the release must not
# contain a stale signature or provisioning profile.
rm -rf "${PACKAGE_DIR}/Payload/${SCHEME}.app/_CodeSignature"
rm -f "${PACKAGE_DIR}/Payload/${SCHEME}.app/embedded.mobileprovision"

(
  cd "${PACKAGE_DIR}"
  zip -qry "${OUTPUT_FILE}" Payload
)

unzip -t "${OUTPUT_FILE}" >/dev/null
if ! unzip -Z1 "${OUTPUT_FILE}" | grep -Fxq "Payload/${SCHEME}.app/Info.plist"; then
  echo "IPA does not contain the expected Payload/${SCHEME}.app bundle" >&2
  exit 1
fi
if unzip -Z1 "${OUTPUT_FILE}" | grep -Eq '(^|/)\._|^__MACOSX/'; then
  echo "IPA unexpectedly contains macOS metadata files" >&2
  exit 1
fi
if unzip -l "${OUTPUT_FILE}" | grep -Eq 'Payload/[^/]+\.app/_CodeSignature|embedded\.mobileprovision'; then
  echo "IPA unexpectedly contains signing material" >&2
  exit 1
fi

echo "Created unsigned IPA: ${OUTPUT_FILE}"
