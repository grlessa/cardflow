[Português](README.md) · **English** · [Español](README.es.md)

# Cardflow

Copy your camera cards without the fear of losing a single take.

You plug in the card and the drive where you want to keep it. Cardflow copies everything, checks
file by file, and only tells you it's safe to format the card once it's sure every photo and every
video arrived intact. If you want, it copies to two places at once: a drive and a backup.

I built it for people who shoot church services, events, concerts or weddings and need to clear a
card safely, without dragging folders by hand and praying nothing gets corrupted along the way.

## What it does

- Copies to one drive and, if you want, to a backup at the same time.
- After copying, it verifies every file. If one doesn't match, it warns you in red so you don't
  format the card.
- When everything checks out, it gives you the green light. Then you can format with peace of mind.
- Organizes the folders however you set it up: by date, event, camera or media type.
- If you run it again on the same card, it skips what's already copied instead of duplicating.
- Copies cinema formats (RED, Blackmagic, Sony, ARRI) without touching the folder structure those
  cameras need.

## Install

1. Download Cardflow.dmg from the [Releases](../../releases) page.
2. Open the file and drag Cardflow into your Applications folder.
3. The first time you read a card, the Mac asks once whether the app can access the drives. Click
   Allow. It won't ask again for every card.

The app is signed and recognized by Apple, so it opens normally, without that "unidentified
developer" warning.

If the Mac still won't let it open (it happens in some cases), right-click Cardflow and choose
Open. That brings up the option to open it anyway, and it won't ask again.

## How to use

1. Connect the card and the drive where you want to save.
2. Pick the destination drive, and the backup drive if you're using one.
3. Click Start and wait.
4. When the green light shows up, you can format the card safely.

## Updates

When you open the app, it takes a look here on GitHub to see if a new version is out. If there is,
a small notice appears with a download button. Just grab the new DMG and install it over the old one.

## Privacy

Cardflow works offline. The only time it uses the internet is for that check for a new version, and
even then it only reads the version number. Your files never leave your computer, and there's no
sign-up or tracking of any kind.

## For those who want the technical details

A native macOS app built in Swift and SwiftUI. The engine (`OffloadKit`) is pure Swift with no
external dependencies; the app uses Sparkle only for the in-app update.

### How verification works

It's not a plain copy and paste. For each file, Cardflow computes an xxHash64 hash of the source and
of what was written to each destination, and only marks it as verified when the two match. Before
comparing, it forces an fsync to make sure the bytes left the cache and actually reached the disk. If
verification fails, the corrupted file is deleted and the interface holds back the green light. The
card never shows up as safe without that proof.

Other guarantees from the engine:

- It doesn't overwrite. Running it again skips what's already there (same hash) and separates files
  with the same name but different content instead of clobbering them.
- It preserves cinema. RED (.RDM/.RDC/.R3D), BRAW (.braw plus sidecar), P2 and XAVC are copied as
  they are, keeping the folder tree. Flattening would break the relink in the editor.
- It refuses a copy and a backup that are the same physical disk (checked via DiskArbitration),
  because that wouldn't be a real backup.
- Each card produces a manifest with a record of what was copied: source, destination and hash.

### How the project is organized

- `Sources/OffloadKit` is the engine, in pure Swift, with no interface: reading the card, copying,
  verification, names from templates, manifest and preset memory.
- `Sources/CardflowApp` is the SwiftUI interface.
- `Sources/cardflow` and `Sources/CardflowCLI` are the command-line version, which uses the same
  engine.

### Building from source

You need Swift 6 (Xcode 16 or the Command Line Tools).

```sh
swift build
swift run cardflow --help
bash scripts/make-app.sh
```

To build the signed version packaged in a DMG, see [`docs/notarizacao.md`](docs/notarizacao.md) and
the scripts in `scripts/`.

### Requirements

macOS 14 or newer.

## License

[MIT](LICENSE). Use, modify and distribute freely, just keep the copyright notice.
