#!/usr/bin/env python3
"""Release policy and bundle metadata regression checks for iSnip."""

import pathlib
import plistlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PLIST_PATH = ROOT / "macos" / "Info.plist"
CHANGELOG_PATH = ROOT / "CHANGELOG.md"
PUBLISH_SCRIPT = ROOT / "macos" / "scripts" / "publish-release.sh"


def fail(msg: str) -> None:
    print(f"FAIL: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    if not PLIST_PATH.is_file():
        fail(f"Missing {PLIST_PATH}")

    with PLIST_PATH.open("rb") as f:
        info = plistlib.load(f)

    version = info.get("CFBundleShortVersionString", "")
    build = info.get("CFBundleVersion", "")
    bundle_id = info.get("CFBundleIdentifier", "")
    bundle_name = info.get("CFBundleName", "")
    executable = info.get("CFBundleExecutable", "")
    update_repo = info.get("AirSnipUpdateRepository", "")

    if not re.fullmatch(r"\d+\.\d+\.\d+", str(version)):
        fail(f"Invalid CFBundleShortVersionString: {version!r}")
    if not re.fullmatch(r"[1-9]\d*", str(build)):
        fail(f"Invalid CFBundleVersion: {build!r}")
    if bundle_id != "io.zzusec.airsnip":
        fail(f"Unexpected CFBundleIdentifier: {bundle_id!r}")
    if bundle_name != "iSnip" or executable != "iSnip":
        fail(f"Expected iSnip bundle/executable name, got {bundle_name!r} / {executable!r}")
    if update_repo != "zzusec/isnip-releases":
        fail(f"Unexpected AirSnipUpdateRepository: {update_repo!r}")

    if not CHANGELOG_PATH.is_file():
        fail("Missing CHANGELOG.md")
    changelog = CHANGELOG_PATH.read_text(encoding="utf-8")
    expected_header = f"## macOS v{version}"
    if expected_header not in changelog:
        fail(f"CHANGELOG.md missing section header {expected_header!r}")

    if not PUBLISH_SCRIPT.is_file():
        fail("Missing publish-release.sh")
    script_text = PUBLISH_SCRIPT.read_text(encoding="utf-8")
    if "get('private') is not True" not in script_text:
        fail("publish-release.sh must enforce private source repository check")
    if '[ "$branch" != main ]' not in script_text:
        fail("publish-release.sh must forbid publishing directly from main")
    if "--force" in script_text or "push -f" in script_text:
        fail("publish-release.sh must never force-push")

    scripts_dir = ROOT / "macos" / "scripts"
    for sh_file in sorted(scripts_dir.glob("*.sh")):
        proc = subprocess.run(["/bin/sh", "-n", str(sh_file)], capture_output=True, text=True)
        if proc.returncode != 0:
            fail(f"Shell syntax error in {sh_file.name}: {proc.stderr.strip()}")
        sh_text = sh_file.read_text(encoding="utf-8")
        for lineno, line in enumerate(sh_text.splitlines(), 1):
            m = re.search(r"\$[A-Za-z_][A-Za-z0-9_]*[^\x00-\x7f]", line)
            if m:
                fail(
                    f"Unbraced shell variable adjacent to UTF-8 char in {sh_file.name}:{lineno} ({m.group(0)!r}); use ${{var}}"
                )

    print(f"release-policy: ok (iSnip v{version}, build {build})")


if __name__ == "__main__":
    main()
