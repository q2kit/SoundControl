---
name: build-run
description: Build SoundControl from the command line with xcodebuild, then (re)launch it to verify a change. Use after editing Swift sources.
---

# Build & run SoundControl

The user builds with Xcode (`SoundControl.xcodeproj`). Use these commands only for your own verification;
don't add build scripts to the repo.

## Build

```sh
xcodebuild -project SoundControl.xcodeproj -scheme SoundControl -configuration Debug \
  -derivedDataPath build/DerivedData build 2>&1 | grep -E "error:|warning:|BUILD (SUCCEEDED|FAILED)" | sort -u
```

Ignore the `appintentsmetadataprocessor` "Metadata extraction skipped" warning. Any other warning should be fixed.

## Relaunch

```sh
pkill -f "SoundControl.app/Contents/MacOS/SoundControl"; sleep 1
open build/DerivedData/Build/Products/Debug/SoundControl.app
```

Quit first: `open` on a bundle that is already running only re-activates the old process, it does
not start the new binary. The app also terminates any other running instance with the same bundle id
on launch (including the user's Xcode run), so two instances never tap the same apps side by side.

An app's tap (and anything depending on it) only exists while that app has an audio process and
non-default settings; check what is playing before concluding a feature doesn't work.

## Notes
- Sources live in `SoundControl/` (a file-system synchronized group): new `.swift` files are picked up
  automatically, no need to edit `project.pbxproj`.
- Language mode is Swift 5 (`SWIFT_VERSION = 5.0`); deployment target macOS 14.4.
- Nothing in the code hardcodes the bundle id: log subsystem, aggregate device UID prefix and the
  single-instance check all use `AppInfo.bundleID`. Read the current one from the project:
  `BID=$(grep -m1 PRODUCT_BUNDLE_IDENTIFIER SoundControl.xcodeproj/project.pbxproj | sed -E 's/.*= (.*);/\1/')`
- Logs: `/usr/bin/log show --last 5m --predicate "subsystem == \"$BID\"" --style compact`.
  Always use the full path: in zsh, plain `log` is a shell builtin and silently prints nothing.
- Saved settings: `defaults export "$BID" - | plutil -extract AppSettings raw -o - - | base64 -d`
- Core Audio experiments (test harnesses, players) go in the session scratchpad, never in the repo.

## Testing the mute guard (MuteMirrorGuard)
- Use the *current* default output device as "the system output"; it changes on its own (e.g. AirPods
  reconnecting). Never assume it's the built-in speakers.
- Changing the default device and a routed device at the same moment *is* the mirror pattern, so
  resetting both together between scenarios gets "corrected" by the guard. Reset them one at a time,
  >0.5 s apart, and record/restore the user's original mute states.
- Never pipe a scenario script through `head`: SIGPIPE kills it before it restores the mute states.

## Text and translations
- UI text is written in English in code and translated in `SoundControl/Localizable.xcstrings`
  (Vietnamese for now). Every new string needs its `vi` entry there.
- Only string *literals* passed to SwiftUI (`Text("…")`, `LocalizedStringKey` parameters) are
  translated. A `String` variable, or a ternary of literals, is shown as is: use `String(localized:)`
  or an explicit `LocalizedStringKey`. Device and app names must stay verbatim (`Text(verbatim:)`).
- Check both languages by launching with `-AppleLanguages '(vi)'` / `'(en)'`.

## App icon
The icon is drawn in code by `.claude/tools/make-icon.swift` (a small mixing desk with three faders).
After changing it, regenerate the asset catalog:
```sh
swift .claude/tools/make-icon.swift /tmp/icon.png
I=SoundControl/Assets.xcassets/AppIcon.appiconset
for pt in 16 32 128 256 512; do
  sips -z $pt $pt /tmp/icon.png --out $I/icon_${pt}x${pt}.png
  sips -z $((pt*2)) $((pt*2)) /tmp/icon.png --out $I/icon_${pt}x${pt}@2x.png
done
```

## Exporting a copy for /Applications
```sh
xcodebuild -project SoundControl.xcodeproj -scheme SoundControl -configuration Release \
  -archivePath build/SoundControl.xcarchive archive
cp -R build/SoundControl.xcarchive/Products/Applications/SoundControl.app build/
```
Signed with the project's settings ("Sign to Run Locally" or the user's team).

CI signs releases with a self-signed certificate ("SoundControl Self-Signed") from the repo secrets
`SIGNING_CERTIFICATE_P12` (base64 of the .p12) and `SIGNING_CERTIFICATE_PASSWORD`. The certificate and
its password are kept by the user outside the repo; never commit them. There is no Apple Developer
account, so no notarization: Gatekeeper asks once on first launch, but the fixed identity keeps the
audio permission across updates. Replacing the certificate makes every user grant permissions again.
