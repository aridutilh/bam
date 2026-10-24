# Bam development

- Implement each feature as a coherent interaction, including departure, return, cancellation, focus, persistence, and accessibility where applicable.
- Split independent features between agents with explicit file ownership. Have another agent review behavior before calling a feature complete. Coordinate native UI tests so they do not compete for focus.
- After finishing and verifying each feature or fix, make a focused Git commit. Record the meaningful verification and remaining limitations; do not mark inventory items complete solely because they compile.
- Keep README.md, FEATURE-INVENTORY.md, VALIDATION.md and CHANGELOG.md accurate. Do not imply full Arc or Yab parity.
- Use semantic versions: patch for fixes, minor for features, major for breaking compatibility. Keep VERSION and Info.plist aligned. Tag tested release commits as vX.Y.Z and attach the corresponding app ZIP and SHA256SUMS to GitHub Releases. Do not overwrite published tags or assets.
- Commit original source and resources only. Do not add extracted proprietary artwork, animation files, decompiled implementations, browser profiles, private research, secrets, or generated app bundles to Git.
- Preserve legacy bundle identifier `com.ari.orbitprototype`, profile directory `OrbitPrototype`, and diagnostic cache directory `Ark` until an explicit, tested migration exists. Renaming visible branding must not discard user tabs or website data.
- Prefer targeted behavior tests to implementation-mirroring tests. Run bash build.sh and bash scripts/test-runtime.sh for integrated release checks on macOS.
