#!/usr/bin/env python3
"""Read and validate the single-source Maintenance04 version catalog."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
REGISTRY_PATH = ROOT / "VERSION"
VERSION_PATTERN = re.compile(r"\A[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?\Z")
STEM_PATTERN = re.compile(r"\AVoicePointer-[A-Za-z0-9.-]+\Z")
BUILD_PATTERN = re.compile(r"\A([0-9]{8})\.([1-9][0-9]*)\Z")


@dataclass(frozen=True)
class VersionEntry:
    version: str
    stem: str
    build: str


@dataclass(frozen=True)
class VersionCatalog:
    default: str
    entries: dict[str, VersionEntry]


def parse_registry(contents: str) -> VersionCatalog:
    default: str | None = None
    entries: dict[str, VersionEntry] = {}
    stems: set[str] = set()
    builds: set[str] = set()

    for line_number, raw_line in enumerate(contents.splitlines(), start=1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("default="):
            if default is not None:
                raise ValueError(f"duplicate default at line {line_number}")
            default = line.removeprefix("default=")
            if not VERSION_PATTERN.fullmatch(default):
                raise ValueError(f"invalid default at line {line_number}")
            continue

        fields = line.split("|")
        if len(fields) != 3:
            raise ValueError(f"invalid registry row at line {line_number}")
        version, stem, build = fields
        if not VERSION_PATTERN.fullmatch(version):
            raise ValueError(f"invalid version at line {line_number}")
        if not STEM_PATTERN.fullmatch(stem):
            raise ValueError(f"invalid candidate stem at line {line_number}")
        build_match = BUILD_PATTERN.fullmatch(build)
        if not build_match:
            raise ValueError(f"invalid build number at line {line_number}")
        try:
            datetime.strptime(build_match.group(1), "%Y%m%d")
        except ValueError as error:
            raise ValueError(f"invalid build date at line {line_number}") from error
        if version in entries:
            raise ValueError(f"duplicate version at line {line_number}")
        if stem in stems:
            raise ValueError(f"duplicate candidate stem at line {line_number}")
        if build in builds:
            raise ValueError(f"duplicate build number at line {line_number}")
        entries[version] = VersionEntry(version, stem, build)
        stems.add(stem)
        builds.add(build)

    if default is None or default not in entries:
        raise ValueError("default version is missing from the registry")
    if not entries:
        raise ValueError("version registry is empty")
    return VersionCatalog(default, entries)


def load_registry() -> VersionCatalog:
    try:
        contents = REGISTRY_PATH.read_text(encoding="utf-8")
    except OSError as error:
        raise ValueError("version registry cannot be read") from error
    return parse_registry(contents)


def get_version(version: str) -> VersionEntry:
    catalog = load_registry()
    try:
        return catalog.entries[version]
    except KeyError as error:
        raise ValueError("version is not registered") from error


def review_info(template: bytes, catalog: VersionCatalog) -> bytes:
    info = plistlib.loads(template)  # Public fixture host metadata only.
    entry = catalog.entries[catalog.default]
    info['CFBundleShortVersionString'] = entry.version + '-review'
    info['CFBundleVersion'] = entry.build
    return plistlib.dumps(info)


def _expect(condition: bool, label: str, failures: list[str]) -> None:
    if not condition:
        failures.append(label)


def self_test() -> list[str]:
    failures: list[str] = []
    catalog = load_registry()
    _expect(catalog.default == "0.5.105", "final candidate is default", failures)
    historical_versions = {f"0.5.{patch}" for patch in range(52) if patch != 27}
    _expect(historical_versions.issubset(catalog.entries.keys()),
            "historical published versions retained", failures)
    _expect("0.5.27" not in catalog.entries, "historical version gap preserved", failures)
    _expect("0.5.99" not in catalog.entries, "temporary demo version absent", failures)
    _expect(catalog.entries.get("0.5.0") == VersionEntry(
        "0.5.0", "VoicePointer-0.5.0-pr1-migrated", "20260928.2"
    ), "legacy candidate identity preserved", failures)
    _expect(catalog.entries.get("0.5.50") == VersionEntry(
        "0.5.50", "VoicePointer-0.5.50-candidate", "20261001.3"
    ), "installed version metadata preserved", failures)
    _expect(catalog.entries.get("0.5.51") == VersionEntry(
        "0.5.51", "VoicePointer-0.5.51-candidate", "20261001.4"
    ), "latest candidate metadata preserved", failures)
    _expect(catalog.entries.get("0.5.52") == VersionEntry(
        "0.5.52", "VoicePointer-0.5.52-candidate", "20261002.1"
    ), "previous final candidate metadata retained", failures)
    _expect(catalog.entries.get("0.5.53") == VersionEntry(
        "0.5.53", "VoicePointer-0.5.53-candidate", "20261002.2"
    ), "previous final candidate metadata retained", failures)
    _expect(catalog.entries.get("0.5.54") == VersionEntry(
        "0.5.54", "VoicePointer-0.5.54-candidate", "20261003.1"
    ), "hotfix candidate metadata registered", failures)
    _expect(catalog.entries.get("0.5.55") == VersionEntry(
        "0.5.55", "VoicePointer-0.5.55-candidate", "20261003.2"
    ), "online API configuration candidate metadata registered", failures)
    _expect(catalog.entries.get("0.5.56") == VersionEntry(
        "0.5.56", "VoicePointer-0.5.56-candidate", "20261003.3"
    ), "targetless dictation candidate metadata registered", failures)
    _expect(catalog.entries.get("0.5.57") == VersionEntry(
        "0.5.57", "VoicePointer-0.5.57-candidate", "20261003.4"
    ), "online health and remembered enhancement candidate registered", failures)
    _expect(catalog.entries.get("0.5.58") == VersionEntry(
        "0.5.58", "VoicePointer-0.5.58-candidate", "20261003.5"
    ), "microphone and gesture hotfix candidate registered", failures)
    _expect(catalog.entries.get("0.5.58.1") == VersionEntry(
        "0.5.58.1", "VoicePointer-0.5.58.1-candidate", "20261003.6"
    ), "capture recovery hotfix candidate registered", failures)
    _expect(catalog.entries.get("0.5.59") == VersionEntry(
        "0.5.59", "VoicePointer-0.5.59-candidate", "20261003.7"
    ), "cloud draft and readiness candidate registered", failures)
    _expect(catalog.entries.get("0.5.59.1") == VersionEntry(
        "0.5.59.1", "VoicePointer-0.5.59.1-candidate", "20261004.1"
    ), "temporary inline demotion hotfix candidate registered", failures)
    _expect(catalog.entries.get("0.5.60") == VersionEntry(
        "0.5.60", "VoicePointer-0.5.60-candidate", "20261004.2"
    ), "local memory and teacher learning candidate registered", failures)
    _expect(catalog.entries.get("0.5.60.1") == VersionEntry(
        "0.5.60.1", "VoicePointer-0.5.60.1-candidate", "20261004.3"
    ), "cloud enhancement consent hotfix candidate registered", failures)
    template = (ROOT / 'scripts/SettingsReviewHost-Info.plist').read_bytes()
    info = plistlib.loads(review_info(template, catalog))
    _expect(info['CFBundleShortVersionString'] == catalog.default + '-review'
            and info['CFBundleVersion'] == catalog.entries[catalog.default].build,
            "review fixture resolves the registry and stays explicitly review", failures)

    malformed = [
        ("duplicate version", "default=0.5.0\n0.5.0|VoicePointer-a|20261002.1\n0.5.0|VoicePointer-b|20261002.2\n"),
        ("duplicate stem", "default=0.5.0\n0.5.0|VoicePointer-a|20261002.1\n0.5.1|VoicePointer-a|20261002.2\n"),
        ("duplicate build", "default=0.5.0\n0.5.0|VoicePointer-a|20261002.1\n0.5.1|VoicePointer-b|20261002.1\n"),
        ("invalid build date", "default=0.5.0\n0.5.0|VoicePointer-a|20261340.1\n"),
        ("unsafe candidate stem", "default=0.5.0\n0.5.0|../VoicePointer-a|20261002.1\n"),
    ]
    for label, contents in malformed:
        try:
            parse_registry(contents)
        except ValueError:
            pass
        else:
            failures.append("registry rejects " + label)

    env = dict(os.environ)
    env["VOICEPOINTER_VERSION_REGISTRY_ISOLATED"] = "1"
    env["VOICEPOINTER_PACKAGE_ISOLATED"] = "1"
    consumers = [
        ("python packager", [sys.executable, str(ROOT / "scripts/package-maintenance04-candidate.py"), "0.5.51", "--dry-run"]),
        ("package shell", ["/bin/bash", str(ROOT / "scripts/package-maintenance04-candidate.sh"), "0.5.51", "--dry-run"]),
        ("sign shell", ["/bin/bash", str(ROOT / "scripts/sign-maintenance04-candidate.sh"), "0.5.51", "--dry-run"]),
    ]
    expected = "VERSION_DRY_RUN version=0.5.51 stem=VoicePointer-0.5.51-candidate build=20261001.4"
    for label, command in consumers:
        result = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True, check=False)
        _expect(result.returncode == 0 and result.stdout.strip() == expected,
                label + " resolves registry entry without build/sign", failures)

    try:
        get_version("0.5.99")
    except ValueError:
        pass
    else:
        failures.append("unregistered demo version is rejected")
    return failures


def main(arguments: list[str]) -> int:
    if len(arguments) == 3 and arguments[0] == '--review-plist':
        Path(arguments[2]).write_bytes(review_info(Path(arguments[1]).read_bytes(), load_registry()))
        return 0
    if arguments == ["--default"]:
        print(load_registry().default)
        return 0
    if len(arguments) == 2 and arguments[0] == "--lookup":
        entry = get_version(arguments[1])
        print(entry.stem + "|" + entry.build)
        return 0
    if arguments == ["--self-test"]:
        failures = self_test()
        if failures:
            for failure in failures:
                print("FAIL version registry: " + failure, file=sys.stderr)
            return 1
        print("VERSION_REGISTRY_SELFTEST_PASS")
        return 0
    print("usage: version_registry.py --default | --lookup VERSION | --self-test", file=sys.stderr)
    return 64


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except ValueError as error:
        print("VERSION_REGISTRY_ERROR " + str(error), file=sys.stderr)
        raise SystemExit(64)
