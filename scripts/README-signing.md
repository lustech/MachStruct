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
