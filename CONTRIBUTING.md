# Contributing to Bam

Bam is an early native macOS browser prototype. Start with the acceptance criteria in [FEATURE-INVENTORY.md](FEATURE-INVENTORY.md). Small, complete interactions are easier to review than broad visual changes.

The public repository is [aridutilh/bam](https://github.com/aridutilh/bam). Build output is `Bam.app` with executable `BamBrowser`. Keep legacy bundle/profile identifiers `com.ari.orbitprototype` and `OrbitPrototype` intact unless a migration is explicitly implemented and verified.

Build with `bash build.sh`; run the integrated app checks with `bash scripts/test-runtime.sh`. These tests open native windows and should run with a logged-in graphical macOS session. Runtime tests use temporary or in-memory sessions rather than your browser profile. Python 3 is required for the local fixture server. FFmpeg is optional and used only to regenerate the original video fixture.

Use a separate commit for each completed feature or fix. Explain the behavior, validation, and limitations in the commit or pull request. Preserve existing user state, keyboard focus, Reduce Motion behavior, and page ownership during window transfers.

A release updates VERSION, Info.plist, CHANGELOG.md and VALIDATION.md, runs the checks, tags the tested commit as `vX.Y.Z`, and publishes the generated app ZIP plus checksums. Versions follow semantic versioning. Releases are currently development builds with ad-hoc signatures, not Developer ID notarized applications.

Original code and resources are MIT licensed. Contributions must be redistributable under that license. Apple frameworks and system-provided symbols remain governed by Apple's terms. Do not contribute copied Arc assets, extracted animation frames, or decompiled proprietary implementation code.
