#!/bin/bash
set -euo pipefail
PROJECT_DIR=$(cd -- "$(dirname -- "$0")" && pwd)
# The public app must be buildable entirely from redistributable resources.
if [ -d "$PROJECT_DIR/Resources/Recovered" ]; then
    echo 'Public builds must not bundle extracted third-party resources.' >&2
    exit 1
fi
VERSION=$(tr -d '\n' < "$PROJECT_DIR/VERSION")
BUNDLE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Info.plist")
if [ "$VERSION" != "$BUNDLE_VERSION" ]; then
    echo 'VERSION and Info.plist must agree before building.' >&2
    exit 1
fi
bash "$PROJECT_DIR/scripts/generate-icon.sh"
bash "$PROJECT_DIR/scripts/generate-icon.sh" BamPreviewIcon
BUILD_DIR=${BAM_BUILD_DIR:-${ARK_BUILD_DIR:-${ORBIT_BUILD_DIR:-"$PROJECT_DIR/.build"}}}
# A caller may keep build output outside File Provider while the source stays in Documents.
# This remains a build input; interactive tests install it as canonical Bam Preview.
DELIVERABLE_DIR=${BAM_BUILD_OUTPUT_DIR:-"$PROJECT_DIR"}
mkdir -p "$DELIVERABLE_DIR"
DELIVERABLE_APP="$DELIVERABLE_DIR/Bam.app"
# Sign outside iCloud/File Provider folders, which may add FinderInfo during signing.
STAGING_DIR=$(mktemp -d /private/tmp/bam-native.XXXXXX)
trap 'rm -rf "$STAGING_DIR"' EXIT
APP="$STAGING_DIR/Bam.app"
SDK=$(xcrun --sdk macosx --show-sdk-path)
SWIFTC=$(xcrun --find swiftc)
mkdir -p "$BUILD_DIR/module-cache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Scope the installed CLT duplicate SwiftBridging module-map workaround to this build.
printf '// Empty legacy module map; current SwiftBridging is supplied by the toolchain.\n' > "$BUILD_DIR/empty.modulemap"
python3 -c 'import json,sys; from pathlib import Path; p=Path(sys.argv[1]); (p/"overlay.json").write_text(json.dumps({"version":0,"case-sensitive":"true","roots":[{"type":"file","name":"/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap","external-contents":str(p/"empty.modulemap")}]},indent=2))' "$BUILD_DIR"
ARCH=${BAM_ARCH:-${ARK_ARCH:-${ORBIT_ARCH:-$(uname -m)}}}
COMMON=(-swift-version 5 -sdk "$SDK" -target "$ARCH-apple-macosx14.0" -module-cache-path "$BUILD_DIR/module-cache" -vfsoverlay "$BUILD_DIR/overlay.json" -Xcc -ivfsoverlay -Xcc "$BUILD_DIR/overlay.json")
"$SWIFTC" "${COMMON[@]}" -O -parse-as-library -framework AppKit -framework WebKit -framework QuartzCore -framework UserNotifications -framework Security "$PROJECT_DIR"/Sources/*.swift -o "$APP/Contents/MacOS/BamBrowser"
cp -X "$PROJECT_DIR/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/ditto --norsrc --noextattr "$PROJECT_DIR/Resources/" "$APP/Contents/Resources/"
cp -X "$PROJECT_DIR/LICENSE" "$APP/Contents/Resources/LICENSE"
# Exclude the previous generated icon from upgraded working copies.
rm -f "$APP/Contents/Resources/ArkIcon.icns"
# Finder/iCloud may attach metadata to newly created .app folders in Documents.
# Remove only signing-incompatible metadata on this generated bundle.
/usr/bin/xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
/usr/bin/codesign --force --sign - --timestamp=none "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$APP"
# Package the verified staging bundle before File Provider can add metadata.
/usr/bin/ditto --norsrc --noextattr -c -k --keepParent "$APP" "$PROJECT_DIR/Bam-macOS.zip"
# Replace this generated bundle rather than merging into an old File Provider inode.
if [ -d "$DELIVERABLE_APP" ]; then mv "$DELIVERABLE_APP" "$STAGING_DIR/previous-Bam"; fi
/usr/bin/ditto --norsrc --noextattr "$APP" "$DELIVERABLE_APP"
# File Provider can reattach FinderInfo asynchronously just after the copy.
VERIFIED=false
for ATTEMPT in 1 2 3; do
    sleep "$ATTEMPT"
    /usr/bin/xattr -dr com.apple.FinderInfo "$DELIVERABLE_APP" 2>/dev/null || true
    /usr/bin/xattr -dr com.apple.ResourceFork "$DELIVERABLE_APP" 2>/dev/null || true
    # Remove root FinderInfo last; the recursive walk gives File Provider time to reattach it.
    /usr/bin/xattr -d com.apple.FinderInfo "$DELIVERABLE_APP" 2>/dev/null || true
    if /usr/bin/codesign --verify --strict --verbose=2 "$DELIVERABLE_APP"; then
        VERIFIED=true
        break
    fi
    sleep 0.2
done
if [ "$VERIFIED" != true ]; then exit 1; fi
"$SWIFTC" "${COMMON[@]}" "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Tests/main.swift" -o "$BUILD_DIR/model-tests"
"$BUILD_DIR/model-tests" "$BUILD_DIR"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Tests/FolderTests.swift" -o "$BUILD_DIR/folder-tests"
"$BUILD_DIR/folder-tests" "$BUILD_DIR/folder-fixtures"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit -framework WebKit "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/ArcImport.swift" "$PROJECT_DIR/Sources/FaviconSVGRenderer.swift" "$PROJECT_DIR/Sources/WebsiteFaviconStore.swift" "$PROJECT_DIR/Sources/ArcIconImport.swift" "$PROJECT_DIR/Tests/ArcImportTests.swift" -o "$BUILD_DIR/arc-import-tests"
"$BUILD_DIR/arc-import-tests" "$BUILD_DIR/arc-import-fixtures"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit -framework WebKit "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/ArcImport.swift" "$PROJECT_DIR/Sources/FaviconSVGRenderer.swift" "$PROJECT_DIR/Sources/WebsiteFaviconStore.swift" "$PROJECT_DIR/Sources/ArcIconImport.swift" "$PROJECT_DIR/Tests/ArcIconImportTests.swift" -o "$BUILD_DIR/arc-icon-tests"
"$BUILD_DIR/arc-icon-tests" "$BUILD_DIR/arc-icon-fixtures" "$PROJECT_DIR/Tests/Fixtures/arc/StorableSidebar.json"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/ArcImport.swift" "$PROJECT_DIR/Sources/ArcImportSheet.swift" "$PROJECT_DIR/Tests/ArcImportSheetTests.swift" -o "$BUILD_DIR/arc-import-sheet-tests"
"$BUILD_DIR/arc-import-sheet-tests" "$BUILD_DIR/arc-import-fixtures" "$PROJECT_DIR/Tests/Fixtures/arc/StorableSidebar.json"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/PreviewProfile.swift" "$PROJECT_DIR/Tests/PreviewProfileTests.swift" -o "$BUILD_DIR/preview-profile-tests"
"$BUILD_DIR/preview-profile-tests"
python3 -B "$PROJECT_DIR/Tests/PreviewInstallerTests.py"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit "$PROJECT_DIR/Sources/PreviewProfile.swift" "$PROJECT_DIR/Sources/PreviewIcon.swift" "$PROJECT_DIR/Tests/PreviewIconTests.swift" -o "$BUILD_DIR/preview-icon-tests"
"$BUILD_DIR/preview-icon-tests" "$DELIVERABLE_APP"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/ProfileLock.swift" "$PROJECT_DIR/Tests/ProfileLockTests.swift" -o "$BUILD_DIR/profile-lock-tests"
"$BUILD_DIR/profile-lock-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/ProfileHandoffLedger.swift" "$PROJECT_DIR/Tests/ProfileHandoffLedgerTests.swift" -o "$BUILD_DIR/profile-handoff-ledger-tests"
"$BUILD_DIR/profile-handoff-ledger-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/VendorProbeIsolation.swift" "$PROJECT_DIR/Tests/VendorProbeIsolationTests.swift" -o "$BUILD_DIR/vendor-probe-isolation-tests"
"$BUILD_DIR/vendor-probe-isolation-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/ExtensionGestureProbeRules.swift" "$PROJECT_DIR/Tests/ExtensionGestureProbeRulesTests.swift" -o "$BUILD_DIR/extension-gesture-probe-rules-tests"
"$BUILD_DIR/extension-gesture-probe-rules-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/ExtensionPackagePreparation.swift" "$PROJECT_DIR/Tests/ExtensionPackagePreparationTests.swift" -o "$BUILD_DIR/extension-package-tests"
"$BUILD_DIR/extension-package-tests" "$BUILD_DIR/extension-package-fixtures"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework JavaScriptCore "$PROJECT_DIR/Sources/ExtensionPackagePreparation.swift" "$PROJECT_DIR/Sources/ExtensionServiceWorkerPreparation.swift" "$PROJECT_DIR/Sources/SafariExtensionImport.swift" "$PROJECT_DIR/Sources/ExtensionSelectPickerCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionIdleCallbackCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionContentScriptPreparation.swift" "$PROJECT_DIR/Tests/ExtensionContentScriptTests.swift" -o "$BUILD_DIR/extension-messaging-tests"
"$BUILD_DIR/extension-messaging-tests" "$BUILD_DIR/extension-messaging-fixtures"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework JavaScriptCore "$PROJECT_DIR/Sources/ExtensionSelectPickerCompatibility.swift" "$PROJECT_DIR/Tests/ExtensionSelectPickerCompatibilityTests.swift" -o "$BUILD_DIR/extension-select-picker-tests"
"$BUILD_DIR/extension-select-picker-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework Security "$PROJECT_DIR/Sources/ExtensionPackageArchive.swift" "$PROJECT_DIR/Tests/ExtensionPackageArchiveTests.swift" -o "$BUILD_DIR/extension-archive-tests"
"$BUILD_DIR/extension-archive-tests" "$BUILD_DIR/extension-archive-fixtures"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework Security "$PROJECT_DIR/Sources/ExtensionPackageArchive.swift" "$PROJECT_DIR/Sources/ExtensionCatalog.swift" "$PROJECT_DIR/Tests/ExtensionCatalogTests.swift" -o "$BUILD_DIR/extension-catalog-tests"
"$BUILD_DIR/extension-catalog-tests" "$BUILD_DIR/extension-catalog-fixtures"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework JavaScriptCore "$PROJECT_DIR/Sources/ExtensionWasmCompatibility.swift" "$PROJECT_DIR/Tests/ExtensionWasmCompatibilityTests.swift" -o "$BUILD_DIR/extension-wasm-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/ExtensionLanguageDetection.swift" "$PROJECT_DIR/Tests/ExtensionLanguageDetectionTests.swift" -o "$BUILD_DIR/extension-language-tests"
"$BUILD_DIR/extension-language-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/ExtensionSidePanel.swift" "$PROJECT_DIR/Tests/ExtensionSidePanelTests.swift" -o "$BUILD_DIR/extension-sidepanel-tests"
"$BUILD_DIR/extension-sidepanel-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/ExtensionStaticRuleAudit.swift" "$PROJECT_DIR/Tests/ExtensionStaticRuleAuditTests.swift" -o "$BUILD_DIR/extension-static-rule-audit-tests"
"$BUILD_DIR/extension-static-rule-audit-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/ExtensionWindowTargeting.swift" "$PROJECT_DIR/Tests/ExtensionWindowTargetingTests.swift" -o "$BUILD_DIR/extension-window-targeting-tests"
"$BUILD_DIR/extension-window-targeting-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/ExtensionBookmarkTree.swift" "$PROJECT_DIR/Tests/ExtensionBookmarkTreeTests.swift" -o "$BUILD_DIR/extension-bookmark-tree-tests"
"$BUILD_DIR/extension-bookmark-tree-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework JavaScriptCore "$PROJECT_DIR/Sources/ExtensionIdleCallbackCompatibility.swift" "$PROJECT_DIR/Tests/ExtensionIdleCallbackCompatibilityTests.swift" -o "$BUILD_DIR/extension-idle-tests"
"$BUILD_DIR/extension-idle-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/ExtensionOffscreen.swift" "$PROJECT_DIR/Tests/ExtensionOffscreenTests.swift" -o "$BUILD_DIR/extension-offscreen-tests"
"$BUILD_DIR/extension-offscreen-tests"
"$BUILD_DIR/extension-wasm-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework JavaScriptCore "$PROJECT_DIR/Sources/ExtensionPackagePreparation.swift" "$PROJECT_DIR/Sources/ExtensionServiceWorkerPreparation.swift" "$PROJECT_DIR/Tests/ExtensionServiceWorkerPreparationTests.swift" -o "$BUILD_DIR/extension-worker-preparation-tests"
"$BUILD_DIR/extension-worker-preparation-tests" "$BUILD_DIR/extension-worker-fixtures"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework Security "$PROJECT_DIR/Sources/SafariExtensionImport.swift" "$PROJECT_DIR/Tests/SafariExtensionImportTests.swift" -o "$BUILD_DIR/safari-extension-import-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework Security "$PROJECT_DIR/Sources/ExtensionNativeMessaging.swift" "$PROJECT_DIR/Tests/ExtensionNativeMessagingTests.swift" -o "$BUILD_DIR/extension-native-messaging-tests"
"$BUILD_DIR/extension-native-messaging-tests"
"$BUILD_DIR/safari-extension-import-tests"
"$SWIFTC" "${COMMON[@]}" -O -parse-as-library -framework AppKit -framework WebKit -framework UserNotifications -framework Security "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/PreviewProfile.swift" "$PROJECT_DIR/Sources/BamTheme.swift" "$PROJECT_DIR/Sources/BrowserExtensions.swift" "$PROJECT_DIR/Sources/ExtensionStaticRuleAudit.swift" "$PROJECT_DIR/Sources/ExtensionWindowTargeting.swift" "$PROJECT_DIR/Sources/ExtensionLanguageDetection.swift" "$PROJECT_DIR/Sources/ExtensionOffscreen.swift" "$PROJECT_DIR/Sources/BrowserExtensionNativeRuntime.swift" "$PROJECT_DIR/Sources/ExtensionNativeMessaging.swift" "$PROJECT_DIR/Sources/ExtensionCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionBookmarkTree.swift" "$PROJECT_DIR/Sources/ExtensionWasmCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionInstallation.swift" "$PROJECT_DIR/Sources/ExtensionCatalog.swift" "$PROJECT_DIR/Sources/ExtensionPackageArchive.swift" "$PROJECT_DIR/Sources/ExtensionManagement.swift" "$PROJECT_DIR/Sources/ExtensionLibraryPanel.swift" "$PROJECT_DIR/Sources/SafariUserAgent.swift" "$PROJECT_DIR/Sources/ExtensionPackagePreparation.swift" "$PROJECT_DIR/Sources/ExtensionServiceWorkerPreparation.swift" "$PROJECT_DIR/Sources/SafariExtensionImport.swift" "$PROJECT_DIR/Sources/ExtensionSelectPickerCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionIdleCallbackCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionContentScriptPreparation.swift" "$PROJECT_DIR/Tests/BrowserExtensionEnumerationTests.swift" -o "$BUILD_DIR/extension-enumeration-tests"
"$BUILD_DIR/extension-enumeration-tests"
"$SWIFTC" "${COMMON[@]}" -O -parse-as-library -framework AppKit -framework WebKit -framework UserNotifications -framework Security "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/PreviewProfile.swift" "$PROJECT_DIR/Sources/BamTheme.swift" "$PROJECT_DIR/Sources/BrowserExtensions.swift" "$PROJECT_DIR/Sources/ExtensionStaticRuleAudit.swift" "$PROJECT_DIR/Sources/ExtensionWindowTargeting.swift" "$PROJECT_DIR/Sources/ExtensionLanguageDetection.swift" "$PROJECT_DIR/Sources/ExtensionOffscreen.swift" "$PROJECT_DIR/Sources/BrowserExtensionNativeRuntime.swift" "$PROJECT_DIR/Sources/ExtensionNativeMessaging.swift" "$PROJECT_DIR/Sources/ExtensionCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionBookmarkTree.swift" "$PROJECT_DIR/Sources/ExtensionWasmCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionInstallation.swift" "$PROJECT_DIR/Sources/ExtensionCatalog.swift" "$PROJECT_DIR/Sources/ExtensionPackageArchive.swift" "$PROJECT_DIR/Sources/ExtensionManagement.swift" "$PROJECT_DIR/Sources/ExtensionLibraryPanel.swift" "$PROJECT_DIR/Sources/SafariUserAgent.swift" "$PROJECT_DIR/Sources/ExtensionPackagePreparation.swift" "$PROJECT_DIR/Sources/ExtensionServiceWorkerPreparation.swift" "$PROJECT_DIR/Sources/SafariExtensionImport.swift" "$PROJECT_DIR/Sources/ExtensionSelectPickerCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionIdleCallbackCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionContentScriptPreparation.swift" "$PROJECT_DIR/Tests/ExtensionManagementDisclosureTests.swift" -o "$BUILD_DIR/extension-management-disclosure-tests"
"$BUILD_DIR/extension-management-disclosure-tests"
"$SWIFTC" "${COMMON[@]}" -O -parse-as-library -framework JavaScriptCore -framework AppKit -framework WebKit -framework UserNotifications -framework Security "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/PreviewProfile.swift" "$PROJECT_DIR/Sources/BamTheme.swift" "$PROJECT_DIR/Sources/BrowserExtensions.swift" "$PROJECT_DIR/Sources/ExtensionStaticRuleAudit.swift" "$PROJECT_DIR/Sources/ExtensionWindowTargeting.swift" "$PROJECT_DIR/Sources/ExtensionLanguageDetection.swift" "$PROJECT_DIR/Sources/ExtensionOffscreen.swift" "$PROJECT_DIR/Sources/BrowserExtensionNativeRuntime.swift" "$PROJECT_DIR/Sources/ExtensionNativeMessaging.swift" "$PROJECT_DIR/Sources/ExtensionCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionBookmarkTree.swift" "$PROJECT_DIR/Sources/ExtensionWasmCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionInstallation.swift" "$PROJECT_DIR/Sources/ExtensionCatalog.swift" "$PROJECT_DIR/Sources/ExtensionPackageArchive.swift" "$PROJECT_DIR/Sources/ExtensionManagement.swift" "$PROJECT_DIR/Sources/ExtensionLibraryPanel.swift" "$PROJECT_DIR/Sources/SafariUserAgent.swift" "$PROJECT_DIR/Sources/ExtensionPackagePreparation.swift" "$PROJECT_DIR/Sources/ExtensionServiceWorkerPreparation.swift" "$PROJECT_DIR/Sources/SafariExtensionImport.swift" "$PROJECT_DIR/Sources/ExtensionSelectPickerCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionIdleCallbackCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionContentScriptPreparation.swift" "$PROJECT_DIR/Tests/ExtensionCompatibilityTests.swift" -o "$BUILD_DIR/extension-compatibility-tests"
"$BUILD_DIR/extension-compatibility-tests"
"$SWIFTC" "${COMMON[@]}" -O -parse-as-library -framework AppKit -framework WebKit -framework UserNotifications -framework Security "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/PreviewProfile.swift" "$PROJECT_DIR/Sources/BamTheme.swift" "$PROJECT_DIR/Sources/BrowserExtensions.swift" "$PROJECT_DIR/Sources/ExtensionStaticRuleAudit.swift" "$PROJECT_DIR/Sources/ExtensionWindowTargeting.swift" "$PROJECT_DIR/Sources/ExtensionLanguageDetection.swift" "$PROJECT_DIR/Sources/ExtensionOffscreen.swift" "$PROJECT_DIR/Sources/BrowserExtensionNativeRuntime.swift" "$PROJECT_DIR/Sources/ExtensionNativeMessaging.swift" "$PROJECT_DIR/Sources/ExtensionCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionBookmarkTree.swift" "$PROJECT_DIR/Sources/ExtensionWasmCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionInstallation.swift" "$PROJECT_DIR/Sources/ExtensionCatalog.swift" "$PROJECT_DIR/Sources/ExtensionPackageArchive.swift" "$PROJECT_DIR/Sources/ExtensionManagement.swift" "$PROJECT_DIR/Sources/ExtensionLibraryPanel.swift" "$PROJECT_DIR/Sources/SafariUserAgent.swift" "$PROJECT_DIR/Sources/ExtensionPackagePreparation.swift" "$PROJECT_DIR/Sources/ExtensionServiceWorkerPreparation.swift" "$PROJECT_DIR/Sources/SafariExtensionImport.swift" "$PROJECT_DIR/Sources/ExtensionSelectPickerCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionIdleCallbackCompatibility.swift" "$PROJECT_DIR/Sources/ExtensionContentScriptPreparation.swift" "$PROJECT_DIR/Tests/BrowserExtensionStartupTests.swift" -o "$BUILD_DIR/extension-startup-tests"
"$BUILD_DIR/extension-startup-tests"
"$SWIFTC" "${COMMON[@]}" -O -parse-as-library -framework AppKit -framework WebKit "$PROJECT_DIR/Sources/FaviconSVGRenderer.swift" "$PROJECT_DIR/Sources/WebsiteFaviconStore.swift" "$PROJECT_DIR/Tests/WebsiteFaviconStoreTests.swift" -o "$BUILD_DIR/favicon-store-tests"
"$BUILD_DIR/favicon-store-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit -framework QuartzCore "$PROJECT_DIR/Sources/RecoveredMotion.swift" "$PROJECT_DIR/Tests/MotionTests.swift" -o "$BUILD_DIR/motion-tests"
"$BUILD_DIR/motion-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit "$PROJECT_DIR/Sources/SidebarSymbol.swift" "$PROJECT_DIR/Tests/SymbolRenderingTests.swift" -o "$BUILD_DIR/symbol-tests"
"$BUILD_DIR/symbol-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/SpaceSwipe.swift" "$PROJECT_DIR/Tests/SpaceSwipeTests.swift" -o "$BUILD_DIR/swipe-tests"
"$BUILD_DIR/swipe-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/Shortcuts.swift" "$PROJECT_DIR/Sources/SiteSearch.swift" "$PROJECT_DIR/Sources/TabSearchResults.swift" "$PROJECT_DIR/Sources/PaletteCommands.swift" "$PROJECT_DIR/Tests/TabSearchTests.swift" -o "$BUILD_DIR/tab-search-tests"
"$BUILD_DIR/tab-search-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/OnboardingModel.swift" "$PROJECT_DIR/Tests/OnboardingTests.swift" -o "$BUILD_DIR/onboarding-tests"
"$BUILD_DIR/onboarding-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/Shortcuts.swift" "$PROJECT_DIR/Sources/SiteSearch.swift" "$PROJECT_DIR/Sources/TabSearchResults.swift" "$PROJECT_DIR/Sources/PaletteCommands.swift" "$PROJECT_DIR/Tests/SiteSearchTests.swift" -o "$BUILD_DIR/site-search-tests"
"$BUILD_DIR/site-search-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit -framework WebKit "$PROJECT_DIR/Sources/FindBarCoordinator.swift" "$PROJECT_DIR/Tests/FindTests.swift" -o "$BUILD_DIR/find-tests"
"$BUILD_DIR/find-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/BrowserLibrary.swift" "$PROJECT_DIR/Sources/LibraryWriter.swift" "$PROJECT_DIR/Tests/LibraryTests.swift" -o "$BUILD_DIR/library-tests"
"$BUILD_DIR/library-tests" "$BUILD_DIR/library-fixtures"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/BrowserLibrary.swift" "$PROJECT_DIR/Sources/LibraryWriter.swift" "$PROJECT_DIR/Tests/LibraryWriterTests.swift" -o "$BUILD_DIR/library-writer-tests"
"$BUILD_DIR/library-writer-tests" "$BUILD_DIR/library-writer-fixtures"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/SessionWriter.swift" "$PROJECT_DIR/Tests/SessionWriterTests.swift" -o "$BUILD_DIR/session-writer-tests"
"$BUILD_DIR/session-writer-tests" "$BUILD_DIR/session-writer-fixtures"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/SessionWriter.swift" "$PROJECT_DIR/Sources/QuitCoordinator.swift" "$PROJECT_DIR/Tests/QuitCoordinatorTests.swift" -o "$BUILD_DIR/quit-coordinator-tests"
"$BUILD_DIR/quit-coordinator-tests" "$BUILD_DIR/quit-coordinator-fixtures"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework WebKit -framework JavaScriptCore "$PROJECT_DIR/Sources/TabResourcePolicy.swift" "$PROJECT_DIR/Sources/TabActivityProbe.swift" "$PROJECT_DIR/Tests/TabResourcePolicyTests.swift" -o "$BUILD_DIR/tab-resource-tests"
"$BUILD_DIR/tab-resource-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit -framework QuartzCore "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/Shortcuts.swift" "$PROJECT_DIR/Sources/RecoveredMotion.swift" "$PROJECT_DIR/Sources/SidebarSymbol.swift" "$PROJECT_DIR/Sources/BrowserAppearance.swift" "$PROJECT_DIR/Sources/SidebarView.swift" "$PROJECT_DIR/Tests/SidebarPerformanceTests.swift" -o "$BUILD_DIR/sidebar-performance-tests"
"$BUILD_DIR/sidebar-performance-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit -framework QuartzCore "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/Shortcuts.swift" "$PROJECT_DIR/Sources/RecoveredMotion.swift" "$PROJECT_DIR/Sources/SidebarSymbol.swift" "$PROJECT_DIR/Sources/BrowserAppearance.swift" "$PROJECT_DIR/Sources/SidebarView.swift" "$PROJECT_DIR/Tests/AppearanceTests.swift" -o "$BUILD_DIR/appearance-tests"
"$BUILD_DIR/appearance-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit -framework WebKit "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/PreviewProfile.swift" "$PROJECT_DIR/Sources/WebsiteProfileStore.swift" "$PROJECT_DIR/Tests/WebsiteProfileStoreTests.swift" -o "$BUILD_DIR/website-store-tests"
"$BUILD_DIR/website-store-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework JavaScriptCore "$PROJECT_DIR/Sources/ExtensionIdentityProbeRules.swift" "$PROJECT_DIR/Tests/ExtensionIdentityProbeTests.swift" -o "$BUILD_DIR/extension-identity-probe-tests"
"$BUILD_DIR/extension-identity-probe-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/ExtensionBookmarkTree.swift" "$PROJECT_DIR/Sources/BookmarkSessionSnapshot.swift" "$PROJECT_DIR/Tests/BookmarkSessionSnapshotTests.swift" -o "$BUILD_DIR/bookmark-snapshot-tests"
"$BUILD_DIR/bookmark-snapshot-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/ExtensionBookmarkTree.swift" "$PROJECT_DIR/Sources/BookmarkSessionSnapshot.swift" "$PROJECT_DIR/Sources/BookmarkVendorSeed.swift" "$PROJECT_DIR/Tests/BookmarkVendorSeedTests.swift" -o "$BUILD_DIR/bookmark-seed-tests"
"$BUILD_DIR/bookmark-seed-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit -framework QuartzCore -framework CoreText "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/Shortcuts.swift" "$PROJECT_DIR/Sources/RecoveredMotion.swift" "$PROJECT_DIR/Sources/SidebarSymbol.swift" "$PROJECT_DIR/Sources/BrowserAppearance.swift" "$PROJECT_DIR/Sources/SidebarView.swift" "$PROJECT_DIR/Sources/BamTheme.swift" "$PROJECT_DIR/Sources/BamControls.swift" "$PROJECT_DIR/Sources/SiteSearch.swift" "$PROJECT_DIR/Sources/Settings.swift" "$PROJECT_DIR/Tests/SettingsAppearanceTests.swift" -o "$BUILD_DIR/settings-appearance-tests"
"$BUILD_DIR/settings-appearance-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit "$PROJECT_DIR/Sources/Shortcuts.swift" "$PROJECT_DIR/Tests/ShortcutTests.swift" -o "$BUILD_DIR/shortcut-tests"
"$BUILD_DIR/shortcut-tests"
printf 'Built %s\n' "$DELIVERABLE_APP"
