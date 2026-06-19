# Release: Build & Upload to TestFlight / App Store Connect

The iOS app (`WatchAI`) embeds the watchOS app (`WatchAIWatch Watch App`) and is
archived + uploaded from the command line. Run `scripts/release.sh` — it encodes
every workaround below.

## Prerequisites (one-time)

1. **Xcode** with command-line tools selected (`xcode-select -p` → an `Xcode.app`).
2. **watchOS platform installed.** Archiving the embedded watch app fails with
   *"watchOS X must be installed in order to archive the scheme"* — even when
   `xcodebuild -showsdks` lists it — after Xcode updates. Install it:
   ```
   xcodebuild -downloadPlatform watchOS
   ```
   (~4 GB; one-time per Xcode major update.)
3. **App Store Connect API key** at `fastlane/api_key.json` (gitignored). It holds
   `key_id`, `issuer_id`, and the private `key`. `scripts/release.sh` auto-extracts
   the private key to `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8` for
   `xcodebuild` auth. Never commit the `.p8` or `api_key.json`.

## Each release

1. **Bump versions** in `WatchAI.xcodeproj/project.pbxproj` (all 4 occurrences each):
   - `CURRENT_PROJECT_VERSION` (build number) — **always** increment.
   - `MARKETING_VERSION` (CFBundleShortVersionString) — increment when the current
     version's train is already approved/released (see Gotcha 3). Use **patch**
     bumps (e.g. `1.1.1` → `1.1.2`); ask before bumping. Keep build numbers
     monotonic.
2. **Build + upload:**
   ```
   ./scripts/release.sh
   ```
   This archives, re-signs with the Apple Distribution cert via the API key, builds
   the IPA, and uploads (`ExportOptions.plist` has `destination=upload`).
3. The build then **processes** on Apple's side and appears in TestFlight /
   App Store Connect a few minutes later.

## Gotchas (all handled by `scripts/release.sh`)

1. **watchOS platform** — see Prerequisites #2.
2. **Homebrew `rsync` shadowing** — Homebrew's `rsync` 3.4.x on `PATH` breaks
   `xcodebuild -exportArchive` at the IPA step with
   *"rsync: syntax or usage error … Copy failed"*. The script puts `/usr/bin`
   ahead on `PATH` so Xcode uses the system `rsync` (openrsync).
3. **Closed version train** — once a `MARKETING_VERSION` is approved, App Store
   Connect closes its train and rejects further uploads with
   *`90186 Invalid Pre-Release Train … is closed`* / *`90062`*. Incrementing only
   the build number does **not** help — you must raise `MARKETING_VERSION`.
4. **fastlane `build_app`** does not accept `api_key_path`; auth is passed to
   `xcodebuild` as `-authenticationKey*` flags instead (the script handles this).
