# Spare

A clipboard history for macOS that stays out of the way. Press **⌘⇧V**, type a few letters of
something you copied earlier, press Return, and it is pasted where you were typing.

Text and images, pinned favourites, type filters. Swift and AppKit, no dependencies, under 1 MB of
code. Everything stays on your Mac.

## Install

Requires macOS 26 (Tahoe) or later, Apple silicon or Intel.

1. Download `Spare-<version>.dmg` from the releases page and open it.
2. Drag **Spare** into **Applications**, then open it from there.
3. The first time you paste from Spare, macOS asks for **Accessibility** access. Spare needs it
   to press ⌘V for you; without it, a chosen clip is copied and you paste it yourself.

Spare lives in the menu bar. To start it with your Mac, turn on **Launch at login** in Settings.

## Use

| Key | Does |
| --- | --- |
| ⌘⇧V | Open the palette (change it in Settings) |
| Type | Search: every word must match, in any order |
| ↑ ↓, Return | Choose, and paste it into the app you came from |
| ⌘1 … ⌘9 | Paste the first nine rows directly |
| ⌘P | Pin or unpin. Pinned clips stay at the top and are never trimmed |
| ⌘⌫ | Delete the selected clip; ⌘Z brings it back |
| ⌘C | Copy without pasting |
| ⌘F | Show only text, images, links or email addresses |
| Esc | Close |

Hold ⌘ for a moment and the palette shows these shortcuts. Searching "image", "link" or "pinned"
finds clips by kind as well as by content.

## Privacy

- History is stored only on this Mac, in `~/Library/Application Support/app.spare`. Spare makes
  no network connections.
- Copies that apps mark as concealed or transient are never recorded, including passwords from
  1Password, KeeWeb and other managers that follow the
  [nspasteboard.org](http://nspasteboard.org) convention.
- Clips older than a month are removed by default; Settings offers a week, three months or never.
  **Reset Database…** deletes everything.

## Uninstall

Quit Spare from its menu, drag it to the Trash, and delete
`~/Library/Application Support/app.spare` and `~/Library/Caches/app.spare`.

## Build from source

Needs Xcode 26 or later (for the Liquid Glass icon; the Command Line Tools alone build the app
with a generic icon).

```sh
Scripts/build-app.sh            # build/Debug/Spare Dev.app — its own bundle id, prefs and history
Scripts/build-app.sh Release    # build/Release/Spare.app, universal
Scripts/run-tests.sh            # every harness; SPARE_SKIP_E2E=1 skips the one that pastes
```

`xcodegen generate` makes an Xcode project from `project.yml` if you prefer working in Xcode.

## Release

```sh
SPARE_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" \
SPARE_NOTARY_PROFILE=spare-notary \
Scripts/build-dmg.sh
```

Builds, signs with the hardened runtime, notarizes and staples the app and the DMG, and writes
`dist/Spare-<version>.dmg` with its SHA-256. The notary profile is saved once with
`xcrun notarytool store-credentials spare-notary`. The version lives in `project.yml`.
Without the two variables the DMG is unsigned and opens only on the Mac that built it.

## License

[GNU AGPL v3](LICENSE).
