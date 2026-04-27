# MachStruct Release Runbook

Two distribution channels: **Notarized DMG** (direct/Sparkle) and **Mac App Store**.
Run both for each public release, or DMG-only for hotfixes.

---

## Before you start

Make sure:
- All planned commits are on `main` and pushed
- `swift test` passes locally
- The app opens and runs correctly in Xcode

---

## Step 1: Bump version numbers

Edit **all three** Info.plist files:

| File | Keys to update |
|---|---|
| `MachStruct/App/Info.plist` | `CFBundleShortVersionString`, `CFBundleVersion` |
| `MachStructQuickLook/Info.plist` | `CFBundleShortVersionString`, `CFBundleVersion` |
| `MachStructSpotlight/Info.plist` | `CFBundleShortVersionString`, `CFBundleVersion` |

**Versioning rules:**
- `CFBundleShortVersionString` — human-readable version, e.g. `1.1` or `1.1.2`
- `CFBundleVersion` — monotonically increasing integer, e.g. `2` (App Store requires this to be unique per submission, never reuse)

Example for v1.1:
```xml
<key>CFBundleShortVersionString</key>
<string>1.1</string>
<key>CFBundleVersion</key>
<integer>2</integer>
```

Commit:
```bash
git add MachStruct/App/Info.plist MachStructQuickLook/Info.plist MachStructSpotlight/Info.plist
git commit -m "chore: bump version to 1.1 (build 2)"
```

---

## Step 2: Push a tag → CI builds the DMG

```bash
git tag v1.1
git push origin main --tags
```

This triggers `.github/workflows/release.yml`, which:
1. Archives the app with your Developer ID Application certificate
2. Notarizes and staples with Apple
3. Wraps in a `.dmg`
4. Creates a **draft** GitHub Release at github.com/lustech/MachStruct/releases

Watch progress at: **GitHub → Actions tab**

Duration: ~5–10 minutes.

---

## Step 3: Sign the DMG for Sparkle

Once CI finishes, download the DMG and sign it so Sparkle can verify it:

```bash
# Download the DMG from the draft release
gh release download v1.1 --pattern "MachStruct.dmg" --dir /tmp/

# Sign it (requires the EdDSA private key in your keychain — set up once per machine via README-sparkle.md)
sign_update /tmp/MachStruct.dmg
```

This prints something like:
```
sparkle:edSignature="abc123..."  length=12345678
```

Copy both values — you need them in the next step.

---

## Step 4: Update appcast.xml

Open `scripts/appcast.xml` and **prepend** a new `<item>` block inside `<channel>`, above the previous release:

```xml
<!-- ── v1.1 ─────────────────────────────────────────────────── -->
<item>
  <title>MachStruct 1.1</title>
  <sparkle:releaseNotesLink>
    https://machstruct.lustech.se/release-notes/1.1.html
  </sparkle:releaseNotesLink>
  <pubDate>Wed, 23 Apr 2026 12:00:00 +0000</pubDate>
  <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
  <sparkle:version>2</sparkle:version>
  <sparkle:shortVersionString>1.1</sparkle:shortVersionString>
  <enclosure
    url="https://github.com/lustech/MachStruct/releases/download/v1.1/MachStruct.dmg"
    sparkle:edSignature="PASTE_SIGNATURE_HERE"
    length="PASTE_LENGTH_HERE"
    type="application/octet-stream"/>
</item>
```

Fill in:
- `sparkle:edSignature` and `length` from Step 3
- `pubDate` — today's date in RFC 2822 format (e.g. `Wed, 23 Apr 2026 12:00:00 +0000`)
- `sparkle:version` — the `CFBundleVersion` integer from Step 1
- `url` — the GitHub Releases download URL (copy the direct link from the draft release page)

Deploy to your server:
```bash
rsync -avz scripts/appcast.xml user@machstruct.lustech.se:/var/www/machstruct/appcast.xml
```

Commit the updated appcast:
```bash
git add scripts/appcast.xml
git commit -m "chore: update appcast for v1.1"
git push
```

---

## Step 5: Publish the GitHub Release

Go to **github.com → Releases → find the draft** created by CI.

- Add release notes (or let GitHub auto-generate from commits)
- Click **Publish release**

Existing users with MachStruct installed will be offered the update automatically on next launch (or via MachStruct → Check for Updates…).

---

## Step 6: App Store submission (every release, or when ready)

The App Store requires a separate archive built *without* Sparkle.

### Archive

```bash
xcodebuild archive \
    -project MachStruct.xcodeproj \
    -scheme MachStruct \
    -archivePath build/MachStruct-AppStore.xcarchive \
    -configuration Release \
    OTHER_SWIFT_FLAGS="$(inherited) -DAPP_STORE_BUILD" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Apple Distribution" \
    DEVELOPMENT_TEAM="XXXXXXXXXX" \
    PROVISIONING_PROFILE_SPECIFIER="MachStruct AppStore"
```

Replace `XXXXXXXXXX` with your Team ID.

### Export

```bash
xcodebuild -exportArchive \
    -archivePath build/MachStruct-AppStore.xcarchive \
    -exportPath build/MachStruct-AppStore \
    -exportOptionsPlist ExportOptions-AppStore.plist
```

### Upload

**Xcode Organizer (recommended):**
Window → Organizer → select archive → Distribute App → App Store Connect → Upload

**Or Transporter CLI:**
```bash
/Applications/Transporter.app/Contents/MacOS/Transporter \
    -m upload \
    -f "build/MachStruct-AppStore/MachStruct.pkg" \
    -apiKey "YOUR_KEY_ID" \
    -apiIssuer "YOUR_ISSUER_ID"
```

### Submit for review

Go to **appstoreconnect.apple.com** → your app → select the uploaded build → Submit for Review.

---

## Quick reference

| Task | Command / Location |
|---|---|
| Run tests | `swift test` |
| Trigger DMG build | `git tag vX.Y && git push origin --tags` |
| Watch CI | GitHub → Actions |
| Download DMG | `gh release download vX.Y --pattern "*.dmg" --dir /tmp/` |
| Sign for Sparkle | `sign_update /tmp/MachStruct.dmg` |
| Deploy appcast | `rsync -avz scripts/appcast.xml user@machstruct.lustech.se:/var/www/machstruct/appcast.xml` |
| Publish release | GitHub → Releases → draft → Publish |
| App Store archive | see Step 6 |
| App Store upload | Xcode Organizer or Transporter CLI |
