# Code Signing & Distribution — MachStruct

## Overview

MachStruct supports two distribution channels:

| Channel | Certificate | Export options |
|---|---|---|
| Direct (Developer ID) | Developer ID Application | `ExportOptions-Direct.plist` |
| App Store | Apple Distribution | `ExportOptions-AppStore.plist` |

---

## Prerequisites

### 1. Apple Developer account
Enroll at <https://developer.apple.com/enroll/> if you haven't already.

### 2. Your Team ID
Find it at **developer.apple.com → Account → Membership**.
Replace every `XXXXXXXXXX` placeholder in both `ExportOptions-*.plist` files with your 10-character Team ID.

### 3. Certificates (install into your login keychain)

**For direct distribution (notarization):**
1. In Xcode → Preferences → Accounts → Manage Certificates, create a **Developer ID Application** certificate.
   Alternatively: `Keychain Access → Certificate Assistant → Request a Certificate from a CA`, then upload to the Developer portal.

**For App Store:**
1. Create an **Apple Distribution** certificate in the same way.

### 4. Provisioning profiles
- Direct distribution with Hardened Runtime does **not** require a provisioning profile for Developer ID.
- App Store requires a **Mac App Store** provisioning profile — create it at developer.apple.com → Profiles.

### 5. App-specific password (for notarization)
1. Go to <https://appleid.apple.com/account/manage> → App-Specific Passwords.
2. Generate a password labelled `MachStruct-notarytool`.
3. Store it in your keychain:
   ```
   xcrun notarytool store-credentials "MachStruct-notarytool" \
       --apple-id YOUR_APPLE_ID \
       --team-id XXXXXXXXXX \
       --password <app-specific-password>
   ```

---

## Building a signed archive

```bash
xcodebuild archive \
    -scheme MachStruct \
    -archivePath build/MachStruct.xcarchive \
    -configuration Release
```

## Exporting for direct distribution

```bash
xcodebuild -exportArchive \
    -archivePath build/MachStruct.xcarchive \
    -exportPath build/MachStruct-Direct \
    -exportOptionsPlist ExportOptions-Direct.plist
```

## Notarizing (P5-05)

```bash
xcrun notarytool submit build/MachStruct-Direct/MachStruct.app \
    --keychain-profile "MachStruct-notarytool" \
    --wait

xcrun stapler staple build/MachStruct-Direct/MachStruct.app
```

## Verifying the signature

```bash
codesign --verify --deep --strict build/MachStruct-Direct/MachStruct.app
spctl --assess --type exec build/MachStruct-Direct/MachStruct.app
```

---

## Building for the Mac App Store

### Prerequisites
- Apple Distribution certificate in your login keychain (Xcode → Settings → Accounts → Manage Certificates → Apple Distribution)
- Mac App Store provisioning profiles installed (download from developer.apple.com → Profiles; double-click to install)
- `ExportOptions-AppStore.plist` updated with your Team ID (replace `XXXXXXXXXX`)

### Archive (App Store — Sparkle excluded via APP_STORE_BUILD flag)

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

The `APP_STORE_BUILD` flag activates `#if !APP_STORE_BUILD` guards in `MachStructApp.swift`, excluding Sparkle from the binary. The App Store prohibits third-party auto-update mechanisms.

### Export

```bash
xcodebuild -exportArchive \
    -archivePath build/MachStruct-AppStore.xcarchive \
    -exportPath build/MachStruct-AppStore \
    -exportOptionsPlist ExportOptions-AppStore.plist
```

This produces `build/MachStruct-AppStore/MachStruct.pkg`.

### Upload and validate via Xcode Organizer (Xcode 15+)

`xcrun altool` was deprecated in Xcode 13 and removed in Xcode 15. Use Xcode Organizer instead:

1. Window → Organizer (⌥⌘O)
2. Select the `MachStruct-AppStore` archive in the left panel
3. Click **Distribute App** → **App Store Connect** → **Upload** → Next
4. Review options → **Upload**

Xcode validates and uploads in one step. The build appears in App Store Connect → TestFlight within ~15 minutes.

### Upload via Transporter CLI (CI / scripted)

Transporter.app (free, install from Mac App Store) provides a CLI for automated pipelines:

```bash
# Generate an App Store Connect API key at appstoreconnect.apple.com → Users and Access → Keys
# Download the .p8 key file and note the Key ID and Issuer ID.

/Applications/Transporter.app/Contents/MacOS/Transporter \
    -m upload \
    -f "build/MachStruct-AppStore/MachStruct.pkg" \
    -apiKey "YOUR_KEY_ID" \
    -apiIssuer "YOUR_ISSUER_ID"
```

Transporter validates then uploads. Exit code 0 = success.

---

## What NOT to commit

- `.p12` certificate exports
- Provisioning profiles (`*.mobileprovision`, `*.provisionprofile`)
- App-specific passwords or API keys
- Any file under `~/Library/Developer/Xcode/DerivedData`

These are all covered by `.gitignore`.

---

## Xcode project settings to verify

In `MachStruct.xcodeproj` Build Settings (MachStruct target):

| Setting | Value |
|---|---|
| `CODE_SIGN_STYLE` | Manual (or Automatic with your team) |
| `CODE_SIGN_IDENTITY` | `Developer ID Application` (direct) / `Apple Distribution` (store) |
| `DEVELOPMENT_TEAM` | Your 10-char Team ID |
| `CODE_SIGN_ENTITLEMENTS` | `MachStruct/App/MachStruct.entitlements` |
| `ENABLE_HARDENED_RUNTIME` | YES |

These can be set via `xcodebuild` flags or directly in the `.xcodeproj`.
