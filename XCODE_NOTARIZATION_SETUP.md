You need a **Developer ID–signed and notarized** build. This is distribution outside the Mac App Store; GitHub is only hosting the release artifact.

## 1. Connect Xcode to the developer account

After enrollment is active:

1. Open **Xcode → Settings → Accounts**.
2. Add the Apple ID enrolled in the Apple Developer Program.
3. Select the account and your developer team.
4. Click **Manage Certificates**.
5. Create or confirm you have:
   - **Apple Development** — local development.
   - **Developer ID Application** — signing an app distributed through GitHub.
   - **Developer ID Installer** — only necessary if you distribute a signed `.pkg`.

Do not use an **Apple Distribution** or **Mac App Distribution** certificate for the GitHub build. Those are for App Store distribution.

Back up the Developer ID certificate and private key as an encrypted `.p12`. Losing the private key prevents another machine from producing updates under that certificate.

## 2. Configure the Xcode app target

Open `FileFlip.xcodeproj`, select the **FileFlip** app target, and configure:

### Signing & Capabilities

- Enable **Automatically manage signing**.
- Select your developer team.
- Use a stable, unique bundle identifier. The project currently uses:

```text
app.fileconvert.FileConvert
```

You may keep that if you control the corresponding identity, but a reverse-domain identifier you control is preferable, such as:

```text
com.yourname.fileflip
```

Changing this after release changes the app’s identity, so settle it before publishing.

- Keep **Hardened Runtime** enabled. FileFlip already has this enabled.
- Add only the hardened-runtime entitlements the app actually needs. Avoid broad exceptions such as disabled library validation unless required.
- Confirm the Release build does not contain `com.apple.security.get-task-allow = true`.

### General

Set:

- **Version**: user-visible version, such as `1.0.0`.
- **Build**: monotonically increasing integer, such as `1`.
- **Minimum deployment**: currently macOS 14.0.

A macOS 14 deployment target means users on Ventura/macOS 13 and earlier cannot run the app.

## 3. Decide which Mac architectures to support

This project is currently **Apple-Silicon-only**:

- The Xcode project explicitly sets `ARCHS = arm64`.
- The bundled `ffmpeg` and `ffprobe` executables are also arm64-only.

Therefore, the current build can support:

```text
Apple Silicon Macs running macOS 14 or later
```

It will not work natively on Intel Macs. You have two reasonable options:

### Option A: Publish Apple Silicon only

Simplest initial release. Name the artifact clearly:

```text
FileFlip-1.0.0-macos-arm64.zip
```

Document “Apple Silicon, macOS 14 or later” in the GitHub Release.

### Option B: Produce a Universal 2 app

For both Intel and Apple Silicon:

1. Change Release architecture to **Standard Architectures** (`arm64` and `x86_64`).
2. Set **Build Active Architecture Only** to `No` for Release.
3. Replace the bundled `ffmpeg` and `ffprobe` with Universal 2 versions, or package architecture-specific tools and select the correct one at runtime.
4. Verify every included native library and executable contains both architectures.

Changing only the app’s architecture is insufficient: the current arm64 `ffmpeg` and `ffprobe` would still fail on Intel.

## 4. Check embedded executables

Apple’s notary service requires every executable inside the bundle to be properly signed.

This matters for FileFlip because it bundles:

```text
Sources/FileConvertApp/Resources/MediaTools/ffmpeg
Sources/FileConvertApp/Resources/MediaTools/ffprobe
```

After archiving, inspect the final `.app` and confirm these nested executables carry valid Developer ID signatures. If Xcode’s resource-copy process does not sign them automatically, add a Release archive step that signs the nested executables before Xcode signs the outer app. Sign from the inside out; do not modify anything inside the app after the outer signature is applied.

Avoid treating `codesign --deep` as the signing strategy. It is useful during verification, but explicit inside-out signing produces a more predictable bundle.

## 5. Create the release archive

In Xcode:

1. Select the FileFlip scheme.
2. Select **Any Mac** or the appropriate generic macOS destination—not “My Mac” as an active debug-only build.
3. Select **Product → Archive**.
4. Wait for Xcode Organizer to open.
5. Select the new archive.
6. Click **Validate App** if available and resolve any issues.

An Archive uses the Release configuration. Do not publish the `.app` taken from `DerivedData/.../Debug`.

## 6. Sign and notarize through Xcode

This is the easiest first-release workflow:

1. In **Window → Organizer → Archives**, select the FileFlip archive.
2. Click **Distribute App**.
3. Select **Developer ID**.
4. Select **Upload** to send it to Apple’s notary service.
5. Let Xcode manage signing.
6. Submit it and wait for notarization to report success.
7. After notarization completes, export the archive again.

Xcode downloads and staples Apple’s notarization ticket to the archived app. Exporting after completion gives you the stapled distributable build.

Notarization is not App Review. It is an automated malware and signing-integrity check.

## 7. Verify the exported app

Run these against the exported `FileFlip.app`:

```bash
codesign --verify --deep --strict --verbose=2 "FileFlip.app"
```

Inspect its signing identity and entitlements:

```bash
codesign --display --verbose=4 "FileFlip.app"
codesign --display --entitlements :- "FileFlip.app"
```

Verify the stapled ticket:

```bash
xcrun stapler validate "FileFlip.app"
```

Ask Gatekeeper to assess it:

```bash
spctl --assess --type execute --verbose=4 "FileFlip.app"
```

Expected Gatekeeper output should indicate acceptance and identify the source as notarized Developer ID software.

Also launch the exported Release app and exercise real conversions, especially ones invoking the bundled media tools.

## 8. Package it for GitHub

An `.app` is a directory bundle, not a single file. Do not upload it uncompressed and do not rely on GitHub’s automatically generated “Source code” ZIP files.

After the app has been stapled, create the distribution ZIP with `ditto`:

```bash
ditto -c -k --sequesterRsrc --keepParent \
  "FileFlip.app" \
  "FileFlip-1.0.0-macos-arm64.zip"
```

Optional checksum:

```bash
shasum -a 256 "FileFlip-1.0.0-macos-arm64.zip"
```

Attach that ZIP as a binary asset to a GitHub Release. Include:

- Version
- Supported macOS versions
- Supported architecture: Apple Silicon, Intel, or Universal
- SHA-256 checksum
- Installation instructions: unzip and move `FileFlip.app` into `/Applications`
- Any external dependencies or first-run permissions

Do not modify the `.app` after signing and notarization. Modifying even one bundled resource invalidates its signature.

## 9. Perform the real Gatekeeper test

Local `spctl` verification is necessary but not a complete simulation of a GitHub download. Before publishing broadly:

1. Upload the ZIP to a draft GitHub Release.
2. Download it through Safari or another browser, ideally on a second or clean Mac user account.
3. Unzip it.
4. Move it to `/Applications`.
5. Double-click it normally.
6. Confirm Gatekeeper shows the identified-developer dialog and permits launch without requiring “Open Anyway.”
7. Run representative conversions.

Downloading through a browser applies the quarantine metadata that triggers the actual end-user Gatekeeper path.

## Optional: command-line notarization

For automated releases, use `notarytool`; `altool` is obsolete and no longer accepted.

Store credentials in Keychain:

```bash
xcrun notarytool store-credentials "fileflip-notary" \
  --apple-id "YOUR_APPLE_ID" \
  --team-id "YOUR_TEAM_ID" \
  --password "YOUR_APP_SPECIFIC_PASSWORD"
```

Create a submission ZIP:

```bash
ditto -c -k --keepParent "FileFlip.app" "FileFlip-notarization.zip"
```

Submit it:

```bash
xcrun notarytool submit "FileFlip-notarization.zip" \
  --keychain-profile "fileflip-notary" \
  --wait
```

After an `Accepted` result:

```bash
xcrun stapler staple "FileFlip.app"
xcrun stapler validate "FileFlip.app"
```

Then create a **new ZIP from the stapled app** for GitHub. A ZIP can be submitted for notarization, but the ticket is stapled to the `.app`, not the ZIP.

## FileFlip-specific release blockers

Before the first public release, address or consciously accept these:

1. **No development team is configured yet** — select your enrolled team in Xcode.
2. **Apple Silicon only** — both the project and bundled media tools are arm64.
3. **macOS 14 minimum** — older macOS versions cannot launch it.
4. **Nested media executables need verified signatures** — notarization will reject unsigned or incorrectly signed executables.
5. **Version metadata should be finalized** — assign a public version and increasing build number.
6. **Bundle identifier should be permanent** — choose it before the first release.

Apple references:

- [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Customizing the notarization workflow with `notarytool`](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [Distributing a macOS app outside the Mac App Store](https://help.apple.com/xcode/mac/current/en.lproj/dev033e997ca.html)
- [Managing signing certificates in Xcode](https://help.apple.com/xcode/mac/current/en.lproj/dev154b28f09.html)