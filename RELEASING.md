# Releasing Trainspace

Trainspace ships free, without the paid Apple Developer Program. Builds are signed with a
self-signed certificate and aren't notarized, so a browser download needs one approval in
System Settings › Privacy & Security › Open Anyway. The Terminal installer avoids that step.

## The signing certificate

- Name: `Grant Kovich Code Signing` (self-signed, code signing only, expires 2036-11-08).
- SHA-1: `8E62F96F8D16EC8A6476369E3EBB5AD3ED5DF0E2`.
- Lives in its own keychain, `~/Library/Keychains/wallpaper-signing.keychain-db`. That
  keychain's password is in the login keychain as the generic password
  "wallpaper-signing keychain".
- Backup: `~/.wallpaper-signing/signing.p12`. Its password is in the login keychain as
  "wallpaper-signing p12". **Keep a copy of both in a password manager.**

Every release must be signed with this same certificate. Its hash is part of the app's
designated requirement, which is what macOS ties the location permission and the Keychain items that hold API keys to. A new
certificate means every user grants location again.

To restore it on a new Mac:

```sh
KC=~/Library/Keychains/wallpaper-signing.keychain-db
security create-keychain -p "<new keychain password>" $KC
security set-keychain-settings $KC
security import signing.p12 -k $KC -P "<p12 password>" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "<new keychain password>" $KC
security add-generic-password -U -a "$USER" -s "wallpaper-signing keychain" -w "<new keychain password>"
```

## The update key (Sparkle)

Updates are checked with [Sparkle](https://sparkle-project.org) 2.10.1. Each release's
`appcast.xml` is signed with an EdDSA key; the app only installs updates signed by it
(`SUPublicEDKey` in Info.plist: `ktB2cD4yaph+S3ss6AewILYWAVy92TfJbejMkDA+kQ0=`).

- The private key is in the login keychain (Sparkle's default account), with a backup at
  `~/.wallpaper-signing/sparkle-eddsa-private-key`. **Keep a copy in a password manager.**
  Losing it means shipping a new key, which users only get by downloading the app again.
- Sparkle's tools (`generate_appcast`, `sign_update`, `generate_keys`) live in
  `~/.wallpaper-signing/sparkle-2.10.1/bin`, from the Sparkle-2.10.1.tar.xz release
  (SHA-256 `1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27`). On a new Mac,
  download that release, check the hash, and import the key with
  `generate_keys -f ~/.wallpaper-signing/sparkle-eddsa-private-key`.
- The app finds updates at `releases/latest/download/appcast.xml`, so publishing a release
  is all it takes. It asks people before checking automatically.

## Steps

1. Bump `VERSION` in the Makefile. The build number is the commit count, so commit first.
2. `make test`.
3. `make data`, so the bundled timetables are current, then commit.
4. Build and sign:

   ```sh
   KC=~/Library/Keychains/wallpaper-signing.keychain-db
   security unlock-keychain -p "$(security find-generic-password -s 'wallpaper-signing keychain' -w)" $KC
   make release SIGN_ID="Grant Kovich Code Signing" SIGN_KEYCHAIN=$KC
   ```

   This writes `build/Trainspace-<version>.zip`, `.dmg`, `SHA256SUMS`, `install.sh` and `appcast.xml`, and prints
   the designated requirement. It must read
   `identifier "com.grantkovich.trainspace" and certificate leaf = H"8e62f96f…"`.
5. `make publish` creates GitHub release `v<version>` on this commit with the zip, DMG,
   `SHA256SUMS` and `install.sh` (the repo must be public for anonymous downloads).
6. Update the download page on grantkovich.com/apps/trainspace/: version, date, checksums, the DMG link
   and the installer line, which always fetches the newest release:
   `curl -fsSL https://github.com/grantkovich/trainspace-desktop-dynamic-wallpaper/releases/latest/download/install.sh | sh`.

## Before the first public release

Run the release test matrix (Plane WALL project) on a clean macOS user account, including a
fresh Safari download of the DMG with the Open Anyway path, and an Intel Mac (or Rosetta).

## With a paid Developer ID later

`make release SIGN_ID="Developer ID Application: … (TEAMID)" NOTARY_PROFILE=trainspace` notarizes
and staples the DMG too. Switching certificates changes the designated requirement once, so
users grant location again after that update.
