# iOS-FTL-for-macOS

Converts the iOS build of **FTL: Faster Than Light** into an app that runs natively on Apple Silicon Macs, without PlayCover. Rendering, audio, Game Center sign-in, and mouse input (translated to touch by the system) all work.

> This project is not affiliated with Subset Games. The repository contains no game files. You need your own decrypted copy of the iOS app (see [Legal](#legal)).

## Why

FTL has no native Apple Silicon build for macOS. Running the iOS app through PlayCover fails with this game: it crashes right after startup in the OpenGL layer. This tool patches the iOS binary so that it starts as a Mac Catalyst app and fixes that crash.

## Status

Tested with the FTL 1.6.21 iOS IPA on macOS 27.2 (Apple Silicon), on a single machine.

Working:

- Graphics and sound
- Mouse input (macOS translates clicks into touch events)
- Game Center sign-in

Known limitations:

- The window can be resized freely. The game may stretch or letterbox accordingly.
- There is no keyboard mapping and no PlayTools-style input layer. Input is whatever Mac Catalyst gives you.
- The app runs without a sandbox container, so it has no `~/Library/Containers/<bundle-id>` folder. Where save data ends up has not been verified.
- Starting the app through Finder or `open` has not been tested. Run the binary directly as shown below.

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
| `--glfix PATH` | Use a different `glfix.c` (default: the one next to the script) |
| `--insert-dylib PATH` | Use this `insert-dylib` binary instead of downloading the pinned release |
| `--keep-tools` | Copy the downloaded `insert-dylib` to `./tools/` |

To work offline after the first run, keep the tool once and point the script at it:

```
python3 ftl_to_mac.py FTL.ipa --keep-tools
python3 ftl_to_mac.py FTL.ipa --insert-dylib tools/insert-dylib
```

## How it works

Three things stand between the iOS binary and a working Mac app.

1. **Platform.** The iOS binary declares the iOS platform (`LC_VERSION_MIN_IPHONEOS`). On macOS, AMFI rejects it at launch (`unsuitable CT policy 0 for this platform/device`). The script thins the binary to `arm64` and rewrites the platform to Mac Catalyst with `vtool`. The system then runs it against the Catalyst UIKit.

2. **OpenGL crash (`glfix.c`).** FTL looks up its OpenGL functions by name at runtime, and on macOS those lookups end up in the wrong OpenGL library. `glfix.dylib` redirects them to the Catalyst `OpenGLES` framework. Functions that OpenGLES does not provide return `NULL`, which the game handles. The dylib is built from source on every run, so no precompiled binary is stored in this repository. Details are in the technical background at the end.

3. **Linking and signing.** `insert-dylib` adds an `LC_LOAD_DYLIB` entry for `@executable_path/Frameworks/glfix.dylib`. The old signature is invalid after the platform change, so the script re-signs the dylib and the app ad hoc, with only the `get-task-allow` entitlement (see `ents.plist`).

Set `GLFIX_DEBUG=1` when starting the game to log GL functions that OpenGLES does not provide:

```
GLFIX_DEBUG=1 ./out/FTL.app/FTL
```

## Troubleshooting

- **`the arm64 slice is still encrypted`**: The IPA is still FairPlay-encrypted. The script does not decrypt anything and needs a decrypted app.
- **`no .app bundle found`**: The input must contain exactly one `.app`, either in `Payload/` (IPA) or at the top level.
- **`Killed: 9` when starting the game**: The signature was rejected. Check the reason with
  `log show --last 2m --predicate 'eventMessage CONTAINS "AMFI"'`
- **Crash in `libGL` right after startup**: `glfix.dylib` is not being applied. Check that `otool -L out/FTL.app/FTL | grep glfix` shows a match, and start with `GLFIX_DEBUG=1`. You should see an `OpenGLES handle` line.
- **A tool is missing (`vtool`, `lipo`, ...)**: Install the Command Line Tools with `xcode-select --install`.

## Showcase
Yes! The game has to be played with touch inputs since the mouse and keyboard inputs are not being feed to the internal handlers on touch builds. (I plan to patch this with a future update)
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

The game imports `dlsym` but no `gl*` symbols, so it resolves every GL function by name at runtime. On macOS, `glGetString` exists twice: in the desktop `libGL.dylib` and in `/System/iOSSupport/.../OpenGLES`. The lookup resolves to the desktop `libGL`, which expects a CGL context, so the first GL call crashes. `glfix.dylib` interposes `dlsym` and answers `gl*` lookups from the Catalyst `OpenGLES` framework instead.

Desktop-only functions that the game also asks for (the DSA family such as `glCreateTextures`, and the KHR debug functions) are not in OpenGLES. They return `NULL`, and the game copes with that. The names are logged when `GLFIX_DEBUG=1` is set.

</details>

## Credits

- [hookforge/insert-dylib](https://github.com/hookforge/insert-dylib), a Rust rewrite of the original `insert_dylib` by Tyilo. It is downloaded at runtime and not bundled here.

## License

GPL-3.0. See [LICENSE](LICENSE).
