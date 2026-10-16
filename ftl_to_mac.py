#!/usr/bin/env python3
"""Convert a decrypted iOS FTL app into a Mac Catalyst app for Apple Silicon.

Input can be any of:
  * a decrypted iOS IPA (a zip containing Payload/FTL.app)
  * an .app bundle (FTL.app) directly
  * an .app bundle zipped up (a zip containing FTL.app)

Steps:
  1. Obtain the .app and check that the arm64 slice is decrypted.
  2. Thin the binary to arm64.
  3. Rewrite the platform to Mac Catalyst (AMFI rejects the iOS platform).
  4. Build glfix.dylib from glfix.c and link it into the binary.
  5. Re-sign everything ad hoc.

The IPA/app must already be decrypted; this script does not decrypt anything.

Usage:
  python3 ftl_to_mac.py FTL.ipa [-o out]
  python3 ftl_to_mac.py FTL.app [-o out]
  python3 ftl_to_mac.py FTL.app.zip [-o out]
"""
import argparse
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

# Source from https://github.com/hookforge/insert-dylib.
INSERT_DYLIB_URL = "https://github.com/hookforge/insert-dylib/releases/download/v0.1.0/insert-dylib-macos-aarch64.tar.gz"
TOOLS_DIR = Path(__file__).resolve().parent / "tools"

CATALYST_MINOS = "11.0"
CATALYST_SDK = "14.0"
DYLIB_NAME = "glfix.dylib"
INSTALL_NAME = f"@executable_path/Frameworks/{DYLIB_NAME}"


def die(message):
    print(f"error: {message}", file=sys.stderr)
    sys.exit(1)


def step(text):
    print(f"\n==> {text}")


def run(cmd):
    """Run a command, echo it, and return stdout. Abort with details on failure."""
    cmd = [str(c) for c in cmd]
    print("  $ " + " ".join(cmd))
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        sys.stderr.write(proc.stdout + proc.stderr)
        die(f"command failed with exit code {proc.returncode}")
    return proc.stdout


def locate_app(root):
    """Find a single .app bundle under root.

    Handles both layouts we care about:
      * IPA:        root/Payload/Foo.app
      * zipped app: root/Foo.app
    """
    payload = root / "Payload"
    if payload.is_dir():
        apps = list(payload.glob("*.app"))
        if len(apps) == 1:
            return apps[0]
        if apps:
            die(f"multiple .app bundles found in {payload}: {[a.name for a in apps]}")
    apps = list(root.glob("*.app"))
    if len(apps) == 1:
        return apps[0]
    if apps:
        die(f"multiple .app bundles found in {root}: {[a.name for a in apps]}")
    die(f"no .app bundle found in {root}")


def fetch_insert_dylib(work):
    """Download and extract the pinned insert-dylib release into work/tools.

    The tool lives inside the per-run work directory, so it is removed
    automatically when the run finishes. Pass --keep-tools to instead copy
    it into ./tools/ next to this script before cleanup.
    """
    step("Downloading insert-dylib")
    tools = work / "tools"
    tools.mkdir()
    tarball = tools / "insert-dylib.tar.gz"
    run(["curl", "-fL", "--retry", "3", "-o", tarball, INSERT_DYLIB_URL])
    with tarfile.open(tarball) as tf:
        try:
            tf.extractall(tools, filter="data")
        except TypeError:
            # Python < 3.12 doesn't support the filter argument.
            tf.extractall(tools)
    tarball.unlink()
    for candidate in sorted(tools.rglob("insert-dylib")):
        if candidate.is_file():
            candidate.chmod(0o755)
            return candidate
    die("insert-dylib binary not found inside the downloaded archive")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("input", type=Path, help="decrypted IPA, .app bundle, or zipped .app")
    parser.add_argument("-o", "--output", type=Path, default=Path("out"), help="output directory (default: ./out)")
    parser.add_argument("--glfix", type=Path, default=Path(__file__).resolve().parent / "glfix.c", help="path to glfix.c (default: next to this script)")
    parser.add_argument("--insert-dylib", type=Path, help="use this insert-dylib binary instead of downloading the pinned release")
    parser.add_argument("--keep-tools", action="store_true", help="copy downloaded tools into ./tools/ instead of letting them be deleted with the work directory")
    args = parser.parse_args()

    args.output.mkdir(parents=True, exist_ok=True)

    # All work happens in a hidden staging directory inside the output directory.
    # The finished app is moved into place at the very end (a rename on the same volume)
    # Prevents a failure leaving a half-patched app behind.
    with tempfile.TemporaryDirectory(dir=args.output, prefix=".build-") as work:
        work = Path(work)

        insert_dylib = args.insert_dylib if args.insert_dylib is not None else fetch_insert_dylib(work)
        entitlements = Path(__file__).resolve().parent / "ents.plist"

        # Obtain a copy of the FTL.app. A .app will be copied directly otherwise from inside the zip or ipa.
        step("Preparing app")
        if args.input.is_dir():
            # A directory is either the .app itself, or a directory containing one.
            src = args.input if args.input.suffix == ".app" else locate_app(args.input)
            app = work / src.name
            run(["ditto", src, app])
        else:
            extract = work / "extract"
            run(["ditto", "-x", "-k", args.input, extract])
            app = locate_app(extract)
        print(f"  app: {app.name}")

        final = args.output / app.name

        with open(app / "Info.plist", "rb") as f:
            info = plistlib.load(f)
        binary = app / info["CFBundleExecutable"]
        print(f"  binary: {binary.name}")

        # Refuse to proceed if the arm64 slice is still encrypted.
        step("Checking encryption")
        load_commands = run(["otool", "-arch", "arm64", "-l", binary])
        match = re.search(r"LC_ENCRYPTION_INFO_64.*?cryptid\s+(\d+)", load_commands, re.S)
        if match and match.group(1) != "0":
            die("the arm64 slice is still encrypted (cryptid 1); a decrypted app is required")

        # Remove the armv7 binary (It wont be needed anyways).
        archs = run(["lipo", "-archs", binary]).split()
        if len(archs) > 1:
            step("Thinning to arm64")
            thin = work / "thin"
            run(["lipo", "-thin", "arm64", binary, "-output", thin])
            shutil.move(str(thin), str(binary))

        # Change the platform to Mac Catalyst.
        step("Rewriting platform to Mac Catalyst")
        patched = work / "patched"
        run(["vtool", "-set-build-version", "maccatalyst", CATALYST_MINOS, CATALYST_SDK, "-replace", "-output", patched, binary])
        shutil.move(str(patched), str(binary))
        binary.chmod(0o755)

        # Build glfix.dylib from source do I don't have tp store a precompiled binary anywhere.
        step("Building glfix.dylib")
        sdk_path = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        frameworks = app / "Frameworks"
        frameworks.mkdir(exist_ok=True)
        dylib = frameworks / DYLIB_NAME
        run(["xcrun", "clang", "-target", "arm64-apple-ios14.0-macabi", "-isysroot", sdk_path, "-dynamiclib", args.glfix, "-o", dylib])

        # Link the dylib into the binary. The old code signature is already invalid after the platform change, so it is stripped here.
        step("Linking glfix.dylib into the binary")
        run([insert_dylib, "--inplace", "--strip-codesig", "--all-yes", INSTALL_NAME, binary])

        # Sign ad hoc, dylib first.
        step("Signing")
        run(["xattr", "-cr", app])
        run(["codesign", "-f", "-s", "-", dylib])
        run(["codesign", "-f", "-s", "-", "--entitlements", entitlements, app])

        # Move the finished app into place.
        if final.exists():
            shutil.rmtree(final)
        app.rename(final)

        # Keep the downloaded tool around if the user asked for it. This has to happen before the TemporaryDirectory context exits.
        if args.keep_tools and args.insert_dylib is None:
            TOOLS_DIR.mkdir(parents=True, exist_ok=True)
            kept = TOOLS_DIR / insert_dylib.name
            shutil.copy2(insert_dylib, kept)
            print(f"\nKept insert-dylib at {kept}")

    print(f"\nDone. Start the game with:\n  {final / binary.name}")


if __name__ == "__main__":
    main()
