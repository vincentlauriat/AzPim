#!/usr/bin/env python3
"""Check that appcast.xml and project.yml agree (run by CI, no dependencies).

- appcast.xml is well-formed XML with at least one item;
- the newest item (highest sparkle:version) is not ahead of project.yml:
  sparkle:version <= CURRENT_PROJECT_VERSION and
  sparkle:shortVersionString <= MARKETING_VERSION;
- build numbers in the appcast are unique (a build number is never reused);
- MSAL and Sparkle are pinned by `revision:` in project.yml.

Usage: Scripts/check-release-metadata.py [repo root]
"""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent)
errors = []


def version_tuple(text):
    if not re.fullmatch(r"\d+(\.\d+)*", text or ""):
        raise ValueError(f"not a dotted numeric version: {text!r}")
    return tuple(int(p) for p in text.split("."))


# project.yml: plain regex (PyYAML is not guaranteed on the runner).
try:
    project = (ROOT / "project.yml").read_text(encoding="utf-8")
except OSError as exc:
    sys.exit(f"✗ cannot read project.yml: {exc}")


def project_setting(key):
    m = re.search(rf'^\s*{key}:\s*"?([^"\s#]+)"?', project, re.MULTILINE)
    if not m:
        errors.append(f"project.yml: {key} not found")
        return None
    return m.group(1)


marketing = project_setting("MARKETING_VERSION")
build = project_setting("CURRENT_PROJECT_VERSION")

for package in ("MSAL", "Sparkle"):
    block = re.search(rf"^  {package}:\n((?:    .*\n)+)", project, re.MULTILINE)
    if not block:
        errors.append(f"project.yml: package {package} not found")
    elif not re.search(r"^    revision:\s*[0-9a-f]{40}\b", block.group(1), re.MULTILINE):
        errors.append(f"project.yml: package {package} is not pinned by a 40-char `revision:`")

# appcast.xml
try:
    channel = ET.parse(ROOT / "appcast.xml").getroot().find("channel")
except ET.ParseError as exc:
    sys.exit(f"✗ appcast.xml is not well-formed XML: {exc}")
except OSError as exc:
    sys.exit(f"✗ cannot read appcast.xml: {exc}")
items = channel.findall("item") if channel is not None else []
if not items:
    errors.append("appcast.xml: no <item>")

entries = []
for item in items:
    v = item.findtext(f"{SPARKLE_NS}version")
    s = item.findtext(f"{SPARKLE_NS}shortVersionString")
    try:
        entries.append((int(v), version_tuple(s), v, s))
    except (TypeError, ValueError):
        errors.append(f"appcast.xml: item has bad sparkle:version {v!r} / shortVersionString {s!r}")

builds = [e[0] for e in entries]
if len(builds) != len(set(builds)):
    errors.append(f"appcast.xml: duplicate sparkle:version in {builds}")

if entries and marketing and build:
    newest = max(entries)
    try:
        if newest[0] > int(build):
            errors.append(f"appcast newest sparkle:version {newest[2]} > CURRENT_PROJECT_VERSION {build}")
        if newest[1] > version_tuple(marketing):
            errors.append(f"appcast newest shortVersionString {newest[3]} > MARKETING_VERSION {marketing}")
    except ValueError as exc:
        errors.append(f"project.yml: {exc}")
    print(f"appcast newest: build {newest[2]} / {newest[3]}; project.yml: build {build} / {marketing}")

if errors:
    for e in errors:
        print(f"✗ {e}", file=sys.stderr)
    sys.exit(1)
print("✓ release metadata consistent")
