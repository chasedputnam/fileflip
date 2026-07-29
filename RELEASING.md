# Releasing File Flip for macOS

**Doc of record. Last verified: 2026-07-28.**

## Recommendation

Build, sign, package, notarize, and verify the first releases locally. Upload the exact verified artifact to a draft GitHub Release, test the downloaded artifact, then publish it. GitHub hosts the finished application; it does not sign or notarize macOS software.

Automate this workflow only after the local procedure succeeds reliably. That exposes nested-code signing, entitlements, packaging, notarization, and release-gate failures before Apple credentials are placed in CI.

## Release flow

```mermaid
flowchart LR
    A[Release build] --> B[Developer ID signing]
    B --> C[Package DMG]
    C --> D[Apple notarization]
    D --> E[Staple ticket]
    E --> F[Gatekeeper verification]
    F --> G[GitHub draft release]
    G --> H[Publish release]
```

## Prerequisites

- Apple Developer Program membership.
- A `Developer ID Application` certificate installed in Keychain.
- Hardened Runtime and production entitlements configured for the app.
- A `notarytool` Keychain profile named `FILEFLIP_NOTARY`, or a deliberately chosen replacement used consistently below.
- GitHub CLI authentication if using the command-line publishing flow.

## 1. Build and sign the Release application

Do not distribute the ad-hoc-signed local development build produced with:

```sh
CODE_SIGN_IDENTITY=-
```

For the first release, use Xcode:

1. Select **Product → Archive**.
2. Open **Organizer** and select the archive.
3. Choose **Distribute App → Developer ID**.
4. Export the signed application.

All nested executables and frameworks must be signed correctly. Do not repair the final bundle with a blanket `codesign --deep`; build and packaging should sign nested code in the correct inside-out order.

Verify the exported app:

```sh
codesign --verify --deep --strict --verbose=2 \
  "/path/to/File Flip.app"

spctl --assess --type execute --verbose=4 \
  "/path/to/File Flip.app"
```

## 2. Package the application

Prefer a conventional DMG containing:

- `File Flip.app`
- A shortcut to `/Applications`

Use a stable public asset name such as `FileFlip.dmg` if the website should link directly to the latest download. A versioned filename such as `FileFlip-1.0.0.dmg` is suitable when the website links to the GitHub release page instead.

## 3. Notarize with Apple

Submit the distributable artifact and wait for a final result:

```sh
xcrun notarytool submit FileFlip.dmg \
  --keychain-profile FILEFLIP_NOTARY \
  --wait
```

Proceed only when Apple reports `status: Accepted`. On rejection, retrieve and inspect the log:

```sh
xcrun notarytool log <SUBMISSION_ID> \
  --keychain-profile FILEFLIP_NOTARY \
  notarization-log.json
```

## 4. Staple and validate

```sh
xcrun stapler staple FileFlip.dmg
xcrun stapler validate FileFlip.dmg

spctl --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  FileFlip.dmg
```

Mount the DMG and verify its contained application as well:

```sh
codesign --verify --deep --strict --verbose=2 \
  "/Volumes/File Flip/File Flip.app"

spctl --assess --type execute --verbose=4 \
  "/Volumes/File Flip/File Flip.app"
```

Do not modify or rebuild the artifact after these checks.

## 5. Run the repository release gate

The gate requires candidate-bound evidence from both packaged-media commands. Use absolute paths; do not rebuild or modify the application between these runs:

```sh
ROOT="$PWD"
APP="/absolute/path/to/FileFlip.app"
REPORT="/absolute/path/to/media-matrix.json"
SMOKE_LOG="/absolute/path/to/installation-smoke.log"
REVISION="<release revision>"

FILECONVERT_REVISION="$REVISION" swift run packaged-media-matrix \
  --app "$APP" \
  --fixtures "$ROOT/Tests/Fixtures/Media/manifest.json" \
  --report "$REPORT"

scripts/smoke-installed-media.sh \
  "$APP" \
  "$ROOT/Tests/Fixtures/Media/manifest.json" > "$SMOKE_LOG"

Copy `release/evidence.example.json` to the release evidence location. Record the exact argument arrays above, their artifacts, timestamps, revision, and passing statuses under `packagedMedia`. The matrix report must contain exactly 76 passing non-identity routes (56 audio and 20 video), zero failures, and zero skips. The gate recomputes the application-tree digest and packaged manifest hash, rechecks fixture and public-declaration drift, and rejects stale, duplicated, malformed, source-only, or differently generated evidence.

Then run the fail-closed release gate against that same candidate:

```sh
python3 scripts/release-readiness.py \
  --app "$APP" \
  --data-root "$HOME/Library/Application Support/app.fileconvert.FileConvert" \
  --evidence /absolute/path/to/release-evidence.json
```

`release/release-contract.json` is the source of truth for required commands, platforms, suites, thresholds, fixtures, architectures, entitlements, and external observations. A green local test run alone does not certify a distributable release.

## 6. Publish through GitHub Releases

For the first release, create a draft and upload the exact DMG that passed notarization and release-readiness checks:

```sh
shasum -a 256 FileFlip.dmg > FileFlip.dmg.sha256

gh release create v1.0.0 \
  FileFlip.dmg \
  FileFlip.dmg.sha256 \
  --title "File Flip 1.0.0" \
  --generate-notes \
  --draft
```

Inspect the draft and test the downloaded asset:

```sh
gh release view v1.0.0
```

Then publish it:

```sh
gh release edit v1.0.0 --draft=false
```

The website release-page URL is:

```text
https://github.com/chasedputnam/file-flip/releases/latest
```

With the stable asset name above, a direct-download URL is:

```text
https://github.com/chasedputnam/file-flip/releases/latest/download/FileFlip.dmg
```

A normal, non-prerelease published release becomes the target of `/releases/latest`. Until one exists, GitHub returns 404 for that URL.

## Later automation

After the manual procedure has been proven, a tag-triggered GitHub Actions workflow can:

1. Import an encrypted Developer ID certificate.
2. Build and archive the app.
3. Sign nested code and the app.
4. Create the DMG.
5. Authenticate to Apple with an App Store Connect API key.
6. Notarize and staple the DMG.
7. Run the release-readiness gate.
8. Create the GitHub Release and upload the verified DMG and checksum.

The existing Pages workflow only builds and deploys the website. It does not build, sign, notarize, or publish the Mac application.

## References

- [Apple: Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
- [GitHub: Managing releases in a repository](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository)
