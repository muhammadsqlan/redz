"""Normalize copied native-library identities and sign a fresh ReDZ app bundle."""
from pathlib import Path
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True)


bundle = Path(sys.argv[1]).resolve(strict=True)
identity = sys.argv[2]
if bundle.suffix != ".app" or bundle.name != "ReDZ.app":
    raise SystemExit("Expected a fresh ReDZ.app build.")

native = []
for path in bundle.rglob("*"):
    if path.is_symlink():
        if not path.resolve(strict=True).is_relative_to(bundle):
            raise SystemExit(f"External symlink: {path}")
        continue
    if not path.is_file():
        continue
    with path.open("rb") as stream:
        magic = stream.read(4)
    if magic in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xca\xfe\xba\xbe", b"\xbe\xba\xfe\xca"):
        native.append(path)

for path in native:
    identifiers = [line.strip() for line in run("/usr/bin/otool", "-D", str(path)).splitlines() if line.strip() and not line.rstrip().endswith(":")]
    if any(not identifier.startswith("@") for identifier in identifiers):
        subprocess.run(["/usr/bin/install_name_tool", "-id", "@rpath/" + path.name, str(path)], check=True)
    load_commands = run("/usr/bin/otool", "-l", str(path)).splitlines()
    for index, line in enumerate(load_commands):
        if line.strip() == "cmd LC_RPATH":
            rpath = load_commands[index + 2].strip().split(" (", 1)[0].removeprefix("path ")
            if rpath.startswith("/") and not rpath.startswith(("/usr/lib/", "/System/Library/")):
                subprocess.run(["/usr/bin/install_name_tool", "-rpath", rpath, "@loader_path", str(path)], check=True)
    for line in run("/usr/bin/otool", "-L", str(path)).splitlines():
        if not line.startswith("\t"):
            continue
        dependency = line.strip().split(" (", 1)[0]
        if dependency.startswith("/") and not dependency.startswith(("/usr/lib/", "/System/Library/")):
            raise SystemExit(f"Nonportable native dependency: {path}: {dependency}")

options = ["--force", "--sign", identity]
if identity != "-":
    options += ["--options", "runtime", "--timestamp"]
for path in sorted(native, key=lambda item: len(item.parts), reverse=True):
    subprocess.run(["/usr/bin/codesign", *options, str(path)], check=True)
subprocess.run(["/usr/bin/codesign", *options, str(bundle)], check=True)
subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
print(f"Signed {len(native)} native components and {bundle.name}.")
