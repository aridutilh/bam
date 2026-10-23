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
BUILD_DIR=${ARK_BUILD_DIR:-${ORBIT_BUILD_DIR:-"$PROJECT_DIR/.build"}}
DELIVERABLE_APP="$PROJECT_DIR/Ark.app"
# Sign outside iCloud/File Provider folders, which may add FinderInfo during signing.
STAGING_DIR=$(mktemp -d /private/tmp/ark-native.XXXXXX)
trap 'rm -rf "$STAGING_DIR"' EXIT
APP="$STAGING_DIR/Ark.app"
SDK=$(xcrun --sdk macosx --show-sdk-path)
SWIFTC=$(xcrun --find swiftc)
mkdir -p "$BUILD_DIR/module-cache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Scope the installed CLT duplicate SwiftBridging module-map workaround to this build.
printf '// Empty legacy module map; current SwiftBridging is supplied by the toolchain.\n' > "$BUILD_DIR/empty.modulemap"
python3 -c 'import json,sys; from pathlib import Path; p=Path(sys.argv[1]); (p/"overlay.json").write_text(json.dumps({"version":0,"case-sensitive":"true","roots":[{"type":"file","name":"/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap","external-contents":str(p/"empty.modulemap")}]},indent=2))' "$BUILD_DIR"
ARCH=${ARK_ARCH:-$(uname -m)}
COMMON=(-swift-version 5 -sdk "$SDK" -target "$ARCH-apple-macosx14.0" -module-cache-path "$BUILD_DIR/module-cache" -vfsoverlay "$BUILD_DIR/overlay.json" -Xcc -ivfsoverlay -Xcc "$BUILD_DIR/overlay.json")
"$SWIFTC" "${COMMON[@]}" -O -parse-as-library -framework AppKit -framework WebKit -framework QuartzCore "$PROJECT_DIR"/Sources/*.swift -o "$APP/Contents/MacOS/ArkBrowser"
cp -X "$PROJECT_DIR/Info.plist" "$APP/Contents/Info.plist"
/usr/bin/ditto --norsrc --noextattr "$PROJECT_DIR/Resources/" "$APP/Contents/Resources/"
# Finder/iCloud may attach metadata to newly created .app folders in Documents.
# Remove only signing-incompatible metadata on this generated bundle.
/usr/bin/xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
/usr/bin/xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
/usr/bin/codesign --force --sign - --timestamp=none "$APP"
/usr/bin/codesign --verify --strict --verbose=2 "$APP"
# Package the verified staging bundle before File Provider can add metadata.
/usr/bin/ditto --norsrc --noextattr -c -k --keepParent "$APP" "$PROJECT_DIR/Ark-macOS.zip"
# Replace this generated bundle rather than merging into an old File Provider inode.
if [ -d "$DELIVERABLE_APP" ]; then mv "$DELIVERABLE_APP" "$STAGING_DIR/previous-Ark.app"; fi
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
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit -framework QuartzCore "$PROJECT_DIR/Sources/RecoveredMotion.swift" "$PROJECT_DIR/Tests/MotionTests.swift" -o "$BUILD_DIR/motion-tests"
"$BUILD_DIR/motion-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library "$PROJECT_DIR/Sources/SpaceSwipe.swift" "$PROJECT_DIR/Tests/SpaceSwipeTests.swift" -o "$BUILD_DIR/swipe-tests"
"$BUILD_DIR/swipe-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/TabSearchResults.swift" "$PROJECT_DIR/Tests/TabSearchTests.swift" -o "$BUILD_DIR/tab-search-tests"
"$BUILD_DIR/tab-search-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit -framework WebKit "$PROJECT_DIR/Sources/FindBarCoordinator.swift" "$PROJECT_DIR/Tests/FindTests.swift" -o "$BUILD_DIR/find-tests"
"$BUILD_DIR/find-tests"
"$SWIFTC" "${COMMON[@]}" -parse-as-library -framework AppKit "$PROJECT_DIR/Sources/BrowserState.swift" "$PROJECT_DIR/Sources/BrowserLibrary.swift" "$PROJECT_DIR/Tests/LibraryTests.swift" -o "$BUILD_DIR/library-tests"
"$BUILD_DIR/library-tests" "$BUILD_DIR/library-fixtures"
printf 'Built %s\n' "$DELIVERABLE_APP"
