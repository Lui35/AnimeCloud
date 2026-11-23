#!/bin/bash
set -euo pipefail

# SPM links Google's static SDK but does not copy its UI bundles into the app.
# Copy resources from the exact framework slice selected by Xcode for this build.
cast_framework="${BUILT_PRODUCTS_DIR}/GoogleCast.framework"
app_resources="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
test -d "${cast_framework}/GoogleCastUIResources.bundle"
for resource_bundle in "${cast_framework}"/*.bundle; do
    ditto "${resource_bundle}" "${app_resources}/$(basename "${resource_bundle}")"
done
# Keep the SDK privacy manifest with its own resource bundle.
cp "${cast_framework}/PrivacyInfo.xcprivacy" "${app_resources}/GoogleCastCoreResources.bundle/PrivacyInfo.xcprivacy"
