#!/usr/bin/env python3
"""Convert a decrypted iOS FTL IPA into a Mac Catalyst app for Apple Silicon.

Steps:
  1. Extract the IPA and check that the arm64 slice is decrypted.
  2. Thin the binary to arm64.
  3. Rewrite the platform to Mac Catalyst (AMFI rejects the iOS platform).
  4. Build glfix.dylib from glfix.c and link it into the binary.
  5. Re-sign everything ad hoc.

The IPA must already be decrypted; this script does not decrypt anything.

Usage:
  python3 ftl_to_mac.py FTL.ipa [-o out] [--force]
"""
import argparse
import hashlib
import plistlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

# Pinned insert-dylib release (https://github.com/hookforge/insert-dylib).
# Fill in from the release page:
#   URL:    right-click the macOS arm64 .tar.gz asset and copy the link
#   SHA256: shasum -a 256 <file>.tar.gz
INSERT_DYLIB_URL = "https://github.com/hookforge/insert-dylib/releases/download/v0.1.0/insert-dylib-macos-aarch64.tar.gz"
INSERT_DYLIB_SHA256 = "https://github.com/hookforge/insert-dylib/releases/download/v0.1.0/SHA256SUMS.txt"
TOOLS_DIR = Path(__file__).resolve().parent / "tools"

CATALYST_MINOS = "11.0"
CATALYST_SDK = "14.0"
DYLIB_NAME = "glfix.dylib"
INSTALL_NAME = f"@executable_path/Frameworks/{DYLIB_NAME}"

ENTITLEMENTS = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.get-task-allow</key>
    <true/>
</dict>
</plist>
"""

REQUIRED_TOOLS = ["xcrun", "lipo", "otool", "vtool", "codesign", "ditto", "xattr", "curl"]


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


def ensure_insert_dylib():
    """Return the path to the pinned insert-dylib, downloading it on first use."""
    tool = TOOLS_DIR / "insert-dylib"
    if tool.exists():
        return tool
    if not INSERT_DYLIB_URL:
        die("INSERT_DYLIB_URL is not set in this script (or pass --insert-dylib)")

    step("Downloading insert-dylib")
    with tempfile.TemporaryDirectory() as tmp:
        archive = Path(tmp) / "insert-dylib.tar.gz"
        run(["curl", "-fsSL", "-o", archive, INSERT_DYLIB_URL])

        # Read only the one file we need; nothing else is extracted to disk.
        with tarfile.open(archive) as tar:
            member = next((m for m in tar.getmembers()
                           if m.isfile() and Path(m.name).name == "insert-dylib"), None)
            if member is None:
                die("insert-dylib not found inside the archive")
            TOOLS_DIR.mkdir(exist_ok=True)
            tool.write_bytes(tar.extractfile(member).read())

    tool.chmod(0o755)
    run(["codesign", "-f", "-s", "-", tool])  # harmless if it is already signed
    return tool


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("ipa", type=Path, help="decrypted iOS IPA")
    parser.add_argument("-o", "--output", type=Path, default=Path("out"),
                        help="output directory (default: ./out)")
    parser.add_argument("--glfix", type=Path,
                        default=Path(__file__).resolve().parent / "glfix.c",
                        help="path to glfix.c (default: next to this script)")
    parser.add_argument("--insert-dylib", type=Path,
                        help="use this insert-dylib binary instead of the pinned release")
    parser.add_argument("--force", action="store_true",
                        help="overwrite an existing app in the output directory")
    args = parser.parse_args()

    # Check everything up front so that nothing is half done on failure.
    if sys.platform != "darwin":
        die("this script only works on macOS")
    for tool in REQUIRED_TOOLS:
        if not shutil.which(tool):
            die(f"'{tool}' not found, try: xcode-select --install")
    if not args.ipa.is_file():
        die(f"IPA not found: {args.ipa}")
    if not args.glfix.is_file():
        die(f"glfix.c not found: {args.glfix}")

    insert_dylib = args.insert_dylib or ensure_insert_dylib()
    if not Path(insert_dylib).exists():
        die(f"insert-dylib not found: {insert_dylib}")

    args.output.mkdir(parents=True, exist_ok=True)

    # All work happens in a hidden staging directory inside the output directory.
    # The finished app is moved into place at the very end (a rename on the same
    # volume), so a failure never leaves a half-patched app behind.
    with tempfile.TemporaryDirectory(dir=args.output, prefix=".build-") as work:
        work = Path(work)

        # 1. Extract the IPA.
        step("Extracting IPA")
        run(["ditto", "-x", "-k", args.ipa, work / "extract"])
        apps = list((work / "extract" / "Payload").glob("*.app"))
        if len(apps) != 1:
            die(f"expected exactly one .app in Payload/, found {len(apps)}")
        app = apps[0]

        final = args.output / app.name
        if final.exists() and not args.force:
            die(f"{final} already exists (use --force to overwrite)")

        with open(app / "Info.plist", "rb") as f:
            info = plistlib.load(f)
        binary = app / info["CFBundleExecutable"]
        print(f"  app: {app.name}\n  binary: {binary.name}")

        # 2. Check the architecture and the encryption state of the arm64 slice.
        step("Checking binary")
        archs = run(["lipo", "-archs", binary]).split()
        if "arm64" not in archs:
            die(f"no arm64 slice found (archs: {' '.join(archs)})")
        load_commands = run(["otool", "-arch", "arm64", "-l", binary])
        match = re.search(r"LC_ENCRYPTION_INFO_64.*?cryptid\s+(\d+)", load_commands, re.S)
        if match and match.group(1) != "0":
            die("the arm64 slice is still encrypted (cryptid 1); a decrypted IPA is required")

        # 3. Thin to arm64 if the binary is universal.
        if len(archs) > 1:
            step("Thinning to arm64")
            thin = work / "thin"
            run(["lipo", "-thin", "arm64", binary, "-output", thin])
            shutil.move(str(thin), str(binary))

        # 4. Rewrite the platform to Mac Catalyst.
        step("Rewriting platform to Mac Catalyst")
        patched = work / "patched"
        run(["vtool", "-set-build-version", "maccatalyst", CATALYST_MINOS, CATALYST_SDK,
             "-replace", "-output", patched, binary])
        shutil.move(str(patched), str(binary))
        binary.chmod(0o755)

        # 5. Build glfix.dylib from source.
        step("Building glfix.dylib")
        sdk_path = run(["xcrun", "--sdk", "macosx", "--show-sdk-path"]).strip()
        frameworks = app / "Frameworks"
        frameworks.mkdir(exist_ok=True)
        dylib = frameworks / DYLIB_NAME
        run(["xcrun", "clang", "-target", "arm64-apple-ios14.0-macabi",
             "-isysroot", sdk_path, "-dynamiclib", args.glfix, "-o", dylib])

        # 6. Link the dylib into the binary. The old code signature is already
        # invalid after the platform change, so it is stripped here.
        step("Linking glfix.dylib into the binary")
        run([insert_dylib, "--inplace", "--strip-codesig", "--all-yes", INSTALL_NAME, binary])

        # 7. Sign ad hoc, dylib first. The entitlements file stays outside the bundle.
        step("Signing")
        entitlements = work / "ents.plist"
        entitlements.write_text(ENTITLEMENTS)
        run(["xattr", "-cr", app])
        run(["codesign", "-f", "-s", "-", dylib])
        run(["codesign", "-f", "-s", "-", "--entitlements", entitlements, app])

        # 8. Verify.
        step("Verifying")
        if DYLIB_NAME not in run(["otool", "-L", binary]):
            die("glfix.dylib is not listed in the binary's load commands")
        if "MACCATALYST" not in run(["vtool", "-show-build", binary]):
            die("binary platform is not MACCATALYST")
        if "MACCATALYST" not in run(["vtool", "-show-build", dylib]):
            die("glfix.dylib platform is not MACCATALYST")
        verify = subprocess.run(["codesign", "--verify", "--verbose=2", str(app)],
                                capture_output=True, text=True)
        if verify.returncode != 0:
            print("  warning: codesign --verify reported a problem:\n" + verify.stderr)

        # 9. Move the finished app into place.
        if final.exists():
            shutil.rmtree(final)
        app.rename(final)

    print(f"\nDone. Start the game with:\n  {final / binary.name}")


if __name__ == "__main__":
    main()
