# AirLift Debug

English | [中文](README.zh-CN.md)

A fork of [AirliftSilence](https://github.com/YiHoooong/AirliftSilence-iOS) with a
**device debug console** bolted on: type a path, read the file, edit it, write it back,
import a file, export what you found — all through the same AirTraffic sandbox escape the
original app already used to silence the call-recording announcements.

The upstream app is unchanged in behaviour. The console is a second tab.

```
┌─ AirLift Debug ─────────────────────────── ● PAIRED ─┐
│  TARGET PATH                                      /var/mobile/… │
│  [Announcement] [Greetings] [Media] [Library] [Preferences]  │
│  ┌────────────┬────────────┬────────────┐                  │
│  │  Read      │  Write     │  Export    │                  │
│  ├────────────┼────────────┼────────────┤                  │
│  │  Import    │  Browse    │ Save Files │                  │
│  └────────────┴────────────┴────────────┘                  │
│  CONTENT      [Editor] [Imported] [Device]                  │
│  ┌───────────────────────────────────────────────┐        │
│  │ monospaced editor, hex dump for binary files  │        │
│  └───────────────────────────────────────────────┘        │
│  SELECT CONTENT   start [12]  end [48]   [All][Copy][Keep]  │
└────────────────────────────────────────────────────────────┘
```

## What the console does

| Action | What it does |
|---|---|
| **Read** | Reads the file at the path, off the device, through the exploit. The content lands in the editor; a binary file lands there as a hex dump. |
| **Write** | Writes the current payload to the path, through the exploit. Two flavours: the whole payload, or only the selected slice. |
| **Select content** | Picks a character range out of the editor: copy it, keep only it, or write only it to the device. |
| **Import** | Takes a file from the Files app and keeps its bytes. The file can be written to the device as-is, or loaded into the editor. |
| **Export** | Prepares the current payload as a real file, then hands it to the share sheet (AirDrop, Save to Files) or to the Files app directly. |
| **Browse** | Lists a directory over AFC. AFC is rooted at the device's Media volume, so `/var/mobile/Media` and everything under it is browsable; tap a folder to walk into it, tap a file to make it the target path. |

Every one of them goes through the AirTraffic/ATAirlock escape — see
[docs/debug-console.md](docs/debug-console.md) for how, and for what the escape can and
cannot reach.

### The payload source

The write and export actions take their bytes from one of three sources, picked in the
**Content** card:

- **Editor** — whatever is in the text editor right now.
- **Imported** — the file picked with **Import**.
- **Device** — the bytes of the file that **Read** last pulled off the device.

That split is what makes the console useful: read a file, change one line, write the
whole thing back; or import a replacement and push it without ever touching the
editor.

### Driving it from a Shortcut

The console answers its own URL scheme, so a Shortcut or any launcher can drive it:

```
airliftdebug://read?path=/var/mobile/Library/CallServices/Greetings/default
airliftdebug://browse?path=/var/mobile/Media
```

`read` pulls the file into the editor, `browse` lists the directory. Both switch the app
to the console tab. The upstream actions keep working on their own scheme:

```
airliftsilence://check
airliftsilence://silence
airliftsilence://restore
```

## What it touches

Nothing new. The console can read and write the paths you give it, on the phone it is
running on — that is the whole point of the escape, and the reason the upstream app
exists at all. The original announcement tooling is untouched:

```
/var/mobile/Library/CallServices/Greetings/default/StartDisclosureWithTone.m4a
/var/mobile/Library/CallServices/Greetings/default/StopDisclosure.caf
/var/mobile/Library/CallServices/Greetings/default/StartDisclosure.caf
```

**Use this on a device you own.** A debug console that writes outside the sandbox is a
research tool: it is powerful enough to brick a phone, and it is not something to point
at somebody else's.

## Requirements

- iOS 18.0 – 27.2 beta 2. **Apple patched the underlying `airlift` exploit in iOS 27.2
  beta 3** — do not update past beta 2 or this stops working.
- [LocalDevVPN](https://github.com/rooootdev/LocalDevVPN) running in loopback mode (the
  app dials `10.7.0.1` by default, then falls back through the other tunnel
  gateways). **Never point it at `127.0.0.1`** — on iOS that makes
  `remotepairingdeviced` reject the control channel and enter a drop state where every
  later connection fails, recoverable only by toggling Developer Mode off and on.
- A pairing record. Either import one (AirDrop / Files → the app's Documents, as
  `airlift_pairing.plist`), or use the built-in on-device pairing: **Start pairing** →
  note the PIN → Settings › Privacy & Security › Developer Mode › **Pair with AirLift
  Debug**.
- The official Apple Books app installed and opened at least once — `com.apple.atc`
  refuses the sync otherwise.

The pairing file keeps the upstream name `airlift_pairing.plist`, so a record exported
from the original app can be imported here as-is.

## Build

The Rust core has to be compiled for iOS, so the build needs macOS. If you don't have a
Mac, **let GitHub build it** — `.github/workflows/build-ios.yml` runs on a macOS runner
and uploads an unsigned IPA (macOS runners are free for public repositories):

1. Push this repository to GitHub.
2. Actions → *Build unsigned IPA* → Run workflow.
3. Download the `AirLiftDebug-unsigned-ipa` artifact.

On a Mac with Xcode:

```sh
brew install xcodegen
./build-ios.sh          # rust-core -> AirliftFFI.xcframework
./build-ipa.sh Release  # -> build/AirLiftDebug.ipa (unsigned)
```

The IPA is deliberately **unsigned** — sign it with whatever you normally use (AltStore,
SideStore, Sideloadly, TrollStore, …).

> [!IMPORTANT]
> `SilenceApp.swift` force-references `ALGetGrappaToken`. The Rust side looks that
> symbol up with `dlsym`, so without the hard reference the linker may drop it and every
> sync then fails with *"Grappa session could not be established"* on iOS 27.0.1+. Keep
> that line.

## Publishing your own fork

This checkout is already set up as a fork: the upstream is the `upstream` remote, and
your copy is the `AirLift-Debug` branch.

```sh
git remote -v                                   # upstream -> YiHoooong/AirliftSilence-iOS
git checkout -b my-debug-build                  # your branch
# create an empty repository on GitHub, then:
git remote add origin git@github.com:<you>/<your-repo>.git
git push -u origin my-debug-build
```

The GitHub workflow builds an unsigned IPA for every push to `main`/`master`, so the
fork is one push away from a device.

## Languages

English is the development language; Simplified Chinese ships as `zh-Hans`. Strings are
not in a String Catalog — the `.strings` files are hand-written and the keys are the
English strings exactly as they appear in the Swift sources:

```
ios-app/en.lproj/Localizable.strings        # English (development language)
ios-app/zh-Hans.lproj/Localizable.strings   # Simplified Chinese
ios-app/{en,zh-Hans}.lproj/InfoPlist.strings # the Local Network permission prompt
```

To add a language: copy `en.lproj` to `<language>.lproj`, translate the values (keep the
keys and their `%@` placeholders in the same order), add the language to
`CFBundleLocalizations` in `Info.plist`, and re-run `xcodegen generate`. `en.lproj` has
to stay in place: XcodeGen only creates localisation variant groups when it finds the
development-language folder.

Nothing may drift silently:

```sh
python3 tools/check-strings.py   # also runs in CI
```

## How the console reaches the filesystem

Short version: the exploit cannot *read* or *write* anything by itself, it can only
**move objects**. Everything else is built on top of that one primitive.

- **Write** — the app stages a StreamingZip archive in the device's Media volume
  containing a symlink to the target directory, then asks ATAirlock to "complete" the
  payload file. ATAirlock follows the symlink, so the payload lands *inside* the
  target directory under the file name.
- **Read** — the app asks ATAirlock to move the target file out to Media, reads it over
  AFC, and puts it straight back with the proven writer.

The full walkthrough, with the FFI surface this fork added, is in
[docs/debug-console.md](docs/debug-console.md).

## Known limits

- **iOS can undo the silencing, and it cannot be stopped.** The announcements are
  generated on the device by Siri TTS, and the daemon regenerates them when the
  configuration it expects changes. See the upstream README for the measurements.
- The periodic **"ding ding ding"** reminder during a long recording is
  `recurringDisclosureTwinkle.caf` inside `TelephonyUtilities.framework` on the sealed
  system volume. This exploit cannot replace a sealed-volume file.
- **A read is not free.** The file is moved out of its directory while it is read and
  written back afterwards. If the write-back fails, the console says so and keeps the
  bytes it already has — but the file is then sitting in Media, and the console does not
  hide that.
- **AFC browsing stops at the Media volume.** `/var/mobile/Media` and below are
  browsable; the rest of the filesystem is reachable one file at a time, by path.
- A single payload is capped at 8 MiB. The limit is the hex string in memory, not the
  device.

## Credits

- [airlift](https://github.com/0xjohnnydev/airlift) — Johnny Franks: the original PoC
  and the ATAirlock analysis
- [AirCard-iOS](https://github.com/Mak5er/AirCard-iOS) — Mak5er: the loopback tunnel,
  the Rust FFI core, the pairing host and the Grappa tokens this is built on
- [idevice](https://github.com/jkcoxson/idevice) — the RSD/AFC/streaming_zip_conduit
  plumbing
- [AirliftSilence-iOS](https://github.com/YiHoooong/AirliftSilence-iOS) — the upstream
  this fork starts from

MIT. See [LICENSE](LICENSE).
