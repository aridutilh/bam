# Distribution: what a drag-to-install DMG would take

Status (2026-10-25): **not pursued.** Ari decided to keep Bam local and open source for now and not to buy an Apple Developer Program membership until it makes sense. This note records what would be needed so the decision can be revisited without redoing the research.

## Where Bam stands

`build.sh` signs the app ad hoc (`codesign --force --sign - --timestamp=none`) and packages it as `Bam-macOS.zip` with `SHA256SUMS`. Gatekeeper refuses an ad-hoc-signed app downloaded from the web (“Apple could not verify…”), whether it arrives as a ZIP or a DMG, so the current release path is a prerelease for people willing to right-click → Open or use `xattr -d com.apple.quarantine`. The keychain on the build machine holds only an “Apple Development” certificate belonging to someone else; it cannot sign for distribution outside the App Store.

A DMG by itself is one `hdiutil` command. It only improves the first-run experience when the app inside is Developer ID signed and notarized. An unsigned DMG is worse than the current ZIP: users would hit the Gatekeeper block on the disk image and again on the app.

## Steps, in order

1. **Apple Developer Program** membership (US$99/year) in Ari’s name, then a **Developer ID Application** certificate installed in the build machine’s keychain. Store the notarization credential once: `xcrun notarytool store-credentials <profile>` with an app-specific password or an App Store Connect API key.
2. **Sign with Developer ID and the hardened runtime.** Replace the ad-hoc line in `build.sh`:
   ```
   codesign --force --deep --options runtime --timestamp \
     --entitlements Bam.entitlements \
     --sign "Developer ID Application: <name> (<team id>)" "$APP"
   ```
   Hardened runtime is mandatory for notarization. Bam needs entitlements for what it already does: `com.apple.security.cs.allow-jit` and `com.apple.security.cs.allow-unsigned-executable-memory` for WebKit’s JavaScript engine, and the audio-input, camera and location entitlements if pages may request those. The hardened runtime can break behavior that works ad hoc, so the full `scripts/test-runtime.sh` batch and the vendor extension probes must pass on a hardened build before release.
3. **Build the DMG** with an Applications symlink, which is what makes the drag target appear:
   ```
   rm -rf dmg-root && mkdir dmg-root
   ditto --norsrc --noextattr "$APP" dmg-root/Bam.app
   ln -s /Applications dmg-root/Applications
   hdiutil create -volname "Bam" -srcfolder dmg-root -ov -format UDZO "Bam-$VERSION.dmg"
   codesign --sign "Developer ID Application: <name> (<team id>)" --timestamp "Bam-$VERSION.dmg"
   ```
   A background image with an arrow is optional polish.
4. **Notarize and staple.** `xcrun notarytool submit "Bam-$VERSION.dmg" --keychain-profile <profile> --wait`, then `xcrun stapler staple "Bam-$VERSION.dmg"`. Stapling lets the first launch pass offline. Keep the submission log; rejections usually name a missing entitlement or an unsigned nested binary.
5. **Publish.** Attach the stapled DMG to the GitHub Release next to the ZIP and `SHA256SUMS` (add its hash), and point the bambrowser.com download button at the release asset URL. Do not overwrite published tags or assets.

## Things that do not change

- **Bundle identifier.** Developer ID signing does not require renaming `com.ari.orbitprototype`; AGENTS.md keeps it until a tested migration exists.
- **Updates.** A DMG install is a one-time copy. Each release still means a manual re-download until an updater (Sparkle is the usual choice) exists, and Sparkle also requires a signed, notarized app. The signing work above is a prerequisite for that too.
- **Open source.** None of this changes what is committed; certificates and credentials stay in the keychain, never in Git.

## Effort estimate

With a Developer ID in hand: a day for the `build.sh` changes, entitlements file, DMG step and notarization, plus one full native test batch on the hardened build. Without the membership, nothing here can ship.
