# iOS-FTL-for-macOS

Converts the iOS build of **FTL: Faster Than Light** into an app that runs natively on Apple Silicon Macs, without PlayCover. Rendering, audio, Game Center sign-in, the desktop game's keyboard shortcuts, and mouse input all work, in a window that keeps the game's shape.

> This project is not affiliated with Subset Games. The repository contains no game files. You need your own decrypted copy of the iOS app (see [Legal](#legal)).

For iPhone and iPad (fullscreen on iPhones, touch controls, Hyperspace), see the sister project [FTL-iOS-Patcher](https://github.com/The-Dumb-Dino/FTL-iOS-Patcher).

## Why

FTL has no native Apple Silicon build for macOS. Running the iOS app through PlayCover fails with this game: it crashes right after startup in the OpenGL layer. This tool patches the iOS binary so that it starts as a Mac Catalyst app and fixes that crash.

## Status

Tested with the FTL 1.6.21 iOS IPA on macOS 27.2 (Apple Silicon), on a single machine.

Working:

- Graphics and sound
- Game Center sign-in
- Keyboard: the desktop game's hotkeys (see [Controls](#controls)), including Shift + system key to remove power
- Mouse: left button as a finger, right button as Back, wheel zoom, middle-button pan
- Window: opens at 80% of the screen in the screen's shape, keeps that shape when resized, letterboxes in full screen, and the titlebar no longer covers the top of the game
- Mods: PNG images from mods load (the iPad build has no PNG reader of its own), and [Hyperspace](#hyperspace) runs

Known limitations:

- The input was tested with events posted inside the app (the same AppKit path a real mouse and keyboard take), not with a physical mouse; trackpad pinch-to-zoom has not been tested at all.
- The app runs without a sandbox container. With Game Center signed in, saves go to `~/Library/Application Support/players/<player id>/`.
- Starting the app with `open out/FTL.app` works; double-clicking it in Finder has not been tested.
- Big mods: images a mod puts over the iPad's own textures or atlases can still show the iPad's originals, and textures wider or taller than 16384 pixels (a few animation strips in Multiverse) don't show. FTL-iOS-Patcher fixes both for its builds.

</br>

## Requirements

- A Mac with Apple Silicon
- Xcode Command Line Tools (`xcode-select --install`). They provide `clang`, `lipo`, `vtool`, `codesign`, and Python 3. The full Xcode app is not needed.
- Internet access on the first run (the script downloads [insert-dylib](https://github.com/hookforge/insert-dylib) v0.1.0)
- A **decrypted** FTL iOS app, as an IPA, a `.app` bundle, or a zipped `.app`

## Usage

**Option 1:** Grab release

Download the latest ``iOS-FTL-on-macOS-x.x.x.zip`` from the [release](https://github.com/The-Dumb-Dino/iOS-FTL-for-macOS/releases) page and unpack it.

**Option 2:** Clone
```
git clone https://github.com/The-Dumb-Dino/iOS-FTL-for-macOS
cd iOS-FTL-for-macOS
```

Run the script, the input can be any of these:
```
python3 ftl_to_mac.py FTL.ipa
python3 ftl_to_mac.py FTL.app
python3 ftl_to_mac.py FTL.app.zip
```

Optional: Launch and verify your patched FTL
```
./out/FTL.app/FTL
```

The finished app is written to `out/` (change with `-o`). An existing app with the same name in the output directory is replaced. All intermediate work happens in a hidden `.build-*` folder inside the output directory, which is deleted at the end, so a failed run never leaves a half-patched app behind.
You can now move it to your applications folder if you want to.

</br>

### Options

| Option | Description |
| --- | --- |
| `-o`, `--output DIR` | Output directory (default: `./out`) |
| `--src DIR` | Build the dylib from the sources in this directory (default: next to the script) |
| `--insert-dylib PATH` | Use this `insert-dylib` binary instead of downloading the pinned release |
| `--keep-tools` | Copy the downloaded `insert-dylib` to `./tools/` |
| `--hyperspace PATH` | Also install this `Hyperspace.1.6.21.arm64.dylib` (see [Hyperspace](#hyperspace)) |

To work offline after the first run, keep the tool once and point the script at it:

```
python3 ftl_to_mac.py FTL.ipa --keep-tools
python3 ftl_to_mac.py FTL.ipa --insert-dylib tools/insert-dylib
```

## Mods and Hyperspace

Mods are applied with [ftlman](https://github.com/afishhh/ftlman), which patches the game's `ftl.dat` inside the app and keeps the original as `ftl.dat.vanilla`. Its command line works directly on the app:

```
ftlman patch -d out/FTL.app Hyperspace.ftl "Multiverse - Assets.zip" "Multiverse - Data.zip"
```

Applying with no mods puts the original back. ftlman changes a file inside the signed app; the app still starts (it is not quarantined), but `codesign --verify` reports it.

### Hyperspace

[Hyperspace](https://github.com/FTL-Hyperspace/FTL-Hyperspace), which Multiverse and other big mods need, changes the game's code as well as its data. The iPad game's Hyperspace is built from the `iOS-binary-ports` branch of [FTL-Hyperspace-Dino](https://github.com/The-Dumb-Dino/FTL-Hyperspace-Dino) with its `buildscripts/macos/` (see the README there). It is optional:

1. Build the app with `--hyperspace path/to/Hyperspace.1.6.21.arm64.dylib`, which copies it into `FTL.app/Frameworks/`.
2. Apply `Hyperspace.ftl` (from any [Hyperspace 1.23.2](https://github.com/FTL-Hyperspace/FTL-Hyperspace/releases/tag/v1.23.2) download) first, then the mods that use it. ftlman's own Hyperspace installer is for the PC game; don't use it.
3. Start the game. The terminal shows `[ftlmac] Hyperspace started`, and the top right corner shows `HS-1.23.2 aarch64 macOS ...`.

`ftlmac.dylib` starts Hyperspace only while the applied mods include it (`data/hyperspace.xml` in `ftl.dat`), so the same app plays vanilla and other mods untouched. `FTLMAC_HYPERSPACE=<path>` loads a Hyperspace dylib from elsewhere. If Hyperspace can't start, an alert says why and the game quits. Hyperspace's logs (`zhl.log`, `FTL_HS.log`) go to `~/Library/Application Support/FTL for iPad/`; its saves (`hs_prof.sav`, `hs_continue.sav`, ...) go next to the game's own, so they don't mix with the plain game's.

## Controls

| Input | Action |
| --- | --- |
| Left click / drag | A finger, as on the iPad |
| Right click | Escape: closes the open window, or opens the game menu (a right click for Hyperspace mods whose scripts ask for one) |
| Mouse wheel / trackpad pinch | Zoom in and out where the pointer is |
| Middle button drag / two-finger scroll | Move the zoomed-in view |
| Desktop FTL hotkeys | Space pause, `1`-`4` event choices, `A` `S` `D` `F` `W` `E` ... systems (Shift removes power), `1`-`8` weapons, `F1`-`F8` crew, `U` `C` `I` ship screens, `Z` / `X` open / close all doors, `J` jump, Esc menu |

Letters follow your keyboard layout, like they do in the desktop game. Cmd shortcuts (Cmd+Q, Cmd+H, ...) stay with macOS, and while the game's text field is open (renaming the ship) the keys go there.

## How it works

Four things stand between the iOS binary and a working Mac app.

1. **Platform.** The iOS binary declares the iOS platform (`LC_VERSION_MIN_IPHONEOS`). On macOS, AMFI rejects it at launch (`unsuitable CT policy 0 for this platform/device`). The script thins the binary to `arm64` and rewrites the platform to Mac Catalyst with `vtool`. The system then runs it against the Catalyst UIKit.

2. **OpenGL crash (`glfix.c`).** FTL looks up its OpenGL functions by name at runtime, and on macOS those lookups end up in the wrong OpenGL library. `glfix.c` redirects them to the Catalyst `OpenGLES` framework. Functions that OpenGLES does not provide return `NULL`, which the game handles. The dylib is built from source on every run, so no precompiled binary is stored in this repository. Details are in the technical background at the end.

3. **Mac behaviour (`hooks.c`, `ftlmac.m`).** The iPad build still contains the desktop game's keyboard handling, but its hotkey lookup always answers "no key", and its platform layer reports that there is no hardware keyboard, which makes the game ignore Shift. `hooks.c` patches both, lets the door hotkeys work outside door mode, and sends the game its own key events. These patches are for the 1.6.21 build only (checked by its `LC_UUID`); the addresses come from [ftl-linux](#credits). The game's code is mapped from the signed file and `mprotect` refuses to make it writable, so `hooks.c` uses `vm_protect` with `VM_PROT_COPY`, which gives the process a private copy of each patched page. `ftlmac.m` handles the window and reads the mouse and keyboard through an AppKit event monitor. `png.c` puts a PNG decoder ([stb_image](https://github.com/nothings/stb)) behind the game's stubbed-out one, and `hyperspace.c` starts Hyperspace when it's installed.

4. **Linking and signing.** All the sources are built into `ftlmac.dylib`. `insert-dylib` adds an `LC_LOAD_DYLIB` entry for `@executable_path/Frameworks/ftlmac.dylib`. The old signature is invalid after the platform change, so the script re-signs the dylib and the app ad hoc, with only the `get-task-allow` entitlement (see `ents.plist`).

Environment variables for debugging:

| Variable | Effect |
| --- | --- |
| `GLFIX_DEBUG=1` | Log GL functions that OpenGLES does not provide |
| `FTLMAC_DEBUG=1` | Log the keys sent to the game and its hotkey lookups |
| `FTLMAC_TEST=<fifo>` | Read test commands (clicks, keys, wheel, window size) from a FIFO; see `ftlmac.m` |

```
GLFIX_DEBUG=1 ./out/FTL.app/FTL
```

The game's own log messages are printed to stderr with an `[FTL]` prefix.

## Troubleshooting

- **`the arm64 slice is still encrypted`**: The IPA is still FairPlay-encrypted. The script does not decrypt anything and needs a decrypted app.
- **`no .app bundle found`**: The input must contain exactly one `.app`, either in `Payload/` (IPA) or at the top level.
- **`Killed: 9` when starting the game**: The signature was rejected. Check the reason with
  `log show --last 2m --predicate 'eventMessage CONTAINS "AMFI"'`
- **Crash in `libGL` right after startup**: `ftlmac.dylib` is not being applied. Check that `otool -L out/FTL.app/FTL | grep ftlmac` shows a match, and start with `GLFIX_DEBUG=1`. You should see an `OpenGLES handle` line.
- **Keyboard shortcuts do nothing**: Start the game from a terminal and look for an `[ftlmac]` line. It says whether the hooks were applied; they only work with FTL 1.6.21.
- **A tool is missing (`vtool`, `lipo`, ...)**: Install the Command Line Tools with `xcode-select --install`.

## Showcase
Yes!
<img width="413,5" height="298,5" alt="Bildschirmfoto 2026-10-16 um 20 45 16" src="https://github.com/user-attachments/assets/ded3858b-f5b6-4c66-89ff-37b48c9fd0e0" />
<img width="413,5" height="298,5" alt="Bildschirmfoto 2026-10-16 um 20 49 42" src="https://github.com/user-attachments/assets/57238bc1-ac70-4c69-bf06-9f46de199a8f" />
<img width="413,5" height="298,5" alt="Bildschirmfoto 2026-10-16 um 20 55 46" src="https://github.com/user-attachments/assets/23c1d8a8-607d-463b-a006-a1184b4e08ba" />
<img width="413,5" height="298,5" alt="Bildschirmfoto 2026-10-16 um 20 50 25" src="https://github.com/user-attachments/assets/596c256a-2a1d-445a-a323-1a86c61c23b2" />

## Legal

This repository contains only the patching tools. It does not include FTL, an IPA, or a patched app, and it does not help with obtaining or decrypting an IPA. You are responsible for owning a legitimate copy of the game and for how you obtain a decrypted copy of it. *FTL: Faster Than Light* is the property of Subset Games.
## Technical background

<details>
<summary>Why the game crashes without <code>glfix</code></summary>

The crash is the same with a PlayCover-patched binary and with the plain converted binary:

```
EXC_BAD_ACCESS (code=1, address=0x3b0)
libGL.dylib`glGetString + 12
    ldr x2, [x8, #0x3b0]
```

`x8` is read from a thread-local slot that holds the current CGL context, and it is `NULL`. The game does everything right on the EAGL side:

- `-[EAGLContext initWithAPI:]` is called with `3` (ES3) and returns a valid context.
- `+[EAGLContext setCurrentContext:]` is called with it and returns `YES`.
- `[EAGLContext currentContext]` is set, but `CGLGetCurrentContext()` returns `NULL`.

The game imports `dlsym` but no `gl*` symbols, so it resolves every GL function by name at runtime. On macOS, `glGetString` exists twice: in the desktop `libGL.dylib` and in `/System/iOSSupport/.../OpenGLES`. The lookup resolves to the desktop `libGL`, which expects a CGL context, so the first GL call crashes. `glfix.c` interposes `dlsym` and answers `gl*` lookups from the Catalyst `OpenGLES` framework instead.

Desktop-only functions that the game also asks for (the DSA family such as `glCreateTextures`, and the KHR debug functions) are not in OpenGLES. They return `NULL`, and the game copes with that. The names are logged when `GLFIX_DEBUG=1` is set.

</details>

## Credits

- ftl-linux, the Linux port of the same iPad build from [ftl-android](https://github.com/Sidd065/ftl-android) by Sidd065, for the game's addresses, the hotkey table and the PNG hook.
- [stb_image](https://github.com/nothings/stb) by Sean Barrett (`third_party/stb_image.h`, MIT or public domain), for PNG decoding.
- [hookforge/insert-dylib](https://github.com/hookforge/insert-dylib), a Rust rewrite of the original `insert_dylib` by Tyilo. It is downloaded at runtime and not bundled here.

## License

GPL-3.0. See [LICENSE](LICENSE).
