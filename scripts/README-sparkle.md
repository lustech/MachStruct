# Sparkle Auto-Update Setup (P5-06)

MachStruct uses [Sparkle 2](https://sparkle-project.org) for automatic updates
delivered via a signed appcast hosted at `https://machstruct.lustech.se/appcast.xml`.

---

## One-time setup (do this before the first release)

### 1. Generate the EdDSA key pair

Sparkle ships a `generate_keys` command-line tool.  After Xcode resolves the
Sparkle package, it lives inside the DerivedData directory.  The easiest way
to run it is via the Sparkle distribution tarball or via a cloned repo:

```bash
# Clone Sparkle (or use the copy Xcode already resolved)
git clone https://github.com/sparkle-project/Sparkle.git /tmp/sparkle-tools
cd /tmp/sparkle-tools

# Build the tools
xcodebuild -project Sparkle.xcodeproj -target generate_keys -configuration Release

# Run — this generates an EdDSA key pair and stores the private key in your keychain
./build/Release/generate_keys
```

The tool prints something like:

```
Public key (SUPublicEDKey): abc123XYZ…
Private key stored in keychain item "ed25519" for account "Sparkle".
```

**Copy the public key** into `MachStruct/App/Info.plist`:
```xml
<key>SUPublicEDKey</key>
<string>abc123XYZ…</string>   <!-- replace SPARKLE_ED_PUBLIC_KEY_PLACEHOLDER -->
```

The private key lives in your macOS keychain — never committed to git.

---

### 2. Build the sign_update tool

```bash
xcodebuild -project /tmp/sparkle-tools/Sparkle.xcodeproj \
           -target sign_update \
           -configuration Release
```

Copy `sign_update` somewhere on your `PATH` (e.g. `~/.local/bin/`).

---

## Per-release workflow

After the GitHub Actions notarization pipeline (P5-05) creates a draft DMG release:

### 1. Download the notarized DMG

```bash
gh release download vX.Y.Z --pattern "MachStruct.dmg" --dir /tmp/
```

### 2. Sign the DMG

```bash
sign_update /tmp/MachStruct.dmg
# Prints: sparkle:edSignature="<base64-signature>"  length=<bytes>
```

### 3. Update appcast.xml

Edit `scripts/appcast.xml`:
- Prepend a new `<item>` block (copy the v1.0 template).
- Fill in `sparkle:edSignature`, `length`, `url`, `pubDate`, and version strings.
- Update `sparkle:releaseNotesLink` to point to the release notes page.

### 4. Upload appcast.xml

```bash
# scp, rsync, or your preferred deployment method:
rsync -avz scripts/appcast.xml user@machstruct.lustech.se:/var/www/machstruct/appcast.xml
```

### 5. Verify

From any Mac with MachStruct installed:
```bash
# Temporarily point the app at the live URL and choose Help > Check for Updates
# Or use curl to inspect the raw feed:
curl https://machstruct.lustech.se/appcast.xml
```

---

## How Sparkle checks for updates

- On launch, `SPUStandardUpdaterController` schedules a background check if it
  hasn't run within the last 24 hours.
- The user can also trigger a manual check via **MachStruct > Check for Updates…**
- Sparkle verifies the EdDSA signature against `SUPublicEDKey` in Info.plist
  before offering or downloading any update — tampered DMGs are rejected.

---

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| "No updates available" immediately after upload | Sparkle compares `sparkle:version` (CFBundleVersion integer) — must be > installed version |
| Signature verification failure | Wrong `sign_update` key, or DMG modified post-signing |
| App Transport Security blocks appcast | Check `NSAppTransportSecurity` → `NSExceptionDomains` in Info.plist |
| "Check for Updates" greyed out | Updater still initialising; or `SUPublicEDKey` is the placeholder string |
