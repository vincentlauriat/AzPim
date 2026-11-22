#!/usr/bin/env python3
"""Fails when a French string is missing or stale.

App: AzPim/Localizable.xcstrings (String Catalog). Every key to translate needs a translated French value (or French
plural variants), the same placeholders as the key, and no `stale` extraction state.
Core: Packages/AzPimCore/Sources/AzPimCore/Resources/{en,fr}.lproj (.strings / .stringsdict: SwiftPM 6.1 copies a
String Catalog without compiling it). Every `L10n.string("...")` of the core sources needs a French entry.

`--stringsdata DIR` (macOS job, after a Debug build with SWIFT_EMIT_LOC_STRINGS): also compares the app catalog with
the strings the compiler extracted, so a string added in code but not in the catalog, or a catalog key no longer in
code, fails too.
"""
import argparse
import json
import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP_CATALOG = ROOT / "AzPim/Localizable.xcstrings"
CORE = ROOT / "Packages/AzPimCore/Sources/AzPimCore"
CORE_RESOURCES = CORE / "Resources"
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|lf|f)")
errors = []


def placeholders(text):
    """Placeholder types in order of their position (`%2$@` counts as the second argument)."""
    found = PLACEHOLDER.findall(text)
    positional = [re.match(r"%(\d+)\$(.*)", p) for p in found]
    if all(positional) and found:
        return [f"%{m.group(2)}" for m in sorted(positional, key=lambda m: int(m.group(1)))]
    return [re.sub(r"%\d+\$", "%", p) for p in found]


def check_value(where, key, value):
    if not value:
        errors.append(f"{where}: empty French value for {key!r}")
    elif placeholders(value) != placeholders(key):
        errors.append(f"{where}: placeholders differ for {key!r}: {value!r}")


def check_app_catalog():
    catalog = json.loads(APP_CATALOG.read_text(encoding="utf-8"))
    if catalog.get("version") != "1.0":
        errors.append(f"{APP_CATALOG.name}: version {catalog.get('version')!r}, Xcode 16 expects '1.0'")
    for key, entry in catalog["strings"].items():
        if entry.get("extractionState") == "stale":
            errors.append(f"{APP_CATALOG.name}: stale key {key!r} (no longer in the code)")
        if entry.get("shouldTranslate") is False:
            continue
        french = entry.get("localizations", {}).get("fr")
        if french is None:
            errors.append(f"{APP_CATALOG.name}: no French for {key!r}")
            continue
        if "stringUnit" in french:
            unit = french["stringUnit"]
            if unit.get("state") != "translated":
                errors.append(f"{APP_CATALOG.name}: French of {key!r} is {unit.get('state')!r}")
            check_value(APP_CATALOG.name, key, unit.get("value"))
        else:
            plural = french.get("variations", {}).get("plural", {})
            for form in ("one", "other"):
                unit = plural.get(form, {}).get("stringUnit", {})
                if unit.get("state") != "translated":
                    errors.append(f"{APP_CATALOG.name}: French plural {form!r} of {key!r} missing")
                check_value(APP_CATALOG.name, key, unit.get("value"))
    return catalog


def read_strings(path):
    """Keys and values of a `"key" = "value";` .strings file."""
    text = path.read_text(encoding="utf-8")
    pairs = re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$', text, re.M)
    unescape = lambda s: s.replace('\\"', '"').replace("\\n", "\n").replace("\\\\", "\\")  # noqa: E731
    lines = [line for line in text.splitlines() if line.strip() and not line.startswith("/*")]
    if len(pairs) != len(lines):
        errors.append(f"{path}: {len(lines) - len(pairs)} unreadable line(s)")
    return {unescape(k): unescape(v) for k, v in pairs}


def core_source_keys():
    """Keys of `L10n.string(...)`, with each `\\(...)` interpolation as one placeholder."""
    keys = set()
    for source in CORE.rglob("*.swift"):
        text = source.read_text(encoding="utf-8")
        for match in re.finditer(r'L10n\.string\(\s*("""\n(.*?)\n\s*"""|"((?:[^"\\]|\\.)*)")', text, re.S):
            if match.group(2) is not None:
                body = "\n".join(line.strip() for line in match.group(2).splitlines())
                body = body.replace("\\\n", "")
            else:
                body = match.group(3)
            keys.add(normalize(body))
    return keys


def normalize(text):
    """One placeholder token for `\\(...)`, `%@`, `%lld`…, so source text and table keys compare."""
    out, depth, i = [], 0, 0
    while i < len(text):
        if text.startswith("\\(", i) and depth == 0:
            depth, i = 1, i + 2
            out.append("§")
            continue
        if depth:
            depth += {"(": 1, ")": -1}.get(text[i], 0)
            i += 1
            continue
        out.append(text[i])
        i += 1
    return PLACEHOLDER.sub("§", "".join(out))


def check_core():
    french = read_strings(CORE_RESOURCES / "fr.lproj/Localizable.strings")
    plurals = {}
    for language in ("en", "fr"):
        table = plistlib.loads((CORE_RESOURCES / f"{language}.lproj/Localizable.stringsdict").read_bytes())
        plurals[language] = table
        for key, entry in table.items():
            rule = entry.get("count", {})
            for form in ("one", "other"):
                if not rule.get(form):
                    errors.append(f"core {language}: plural {form!r} of {key!r} missing")
                elif language == "fr":
                    check_value("core fr", key, rule[form])
    if set(plurals["en"]) != set(plurals["fr"]):
        errors.append(f"core: English and French plural keys differ: {set(plurals['en']) ^ set(plurals['fr'])}")
    for key, value in french.items():
        check_value("core fr", key, value)
    table_keys = {normalize(k) for k in french} | {normalize(k) for k in plurals["fr"]}
    source_keys = core_source_keys()
    for key in sorted(source_keys - table_keys):
        errors.append(f"core: no French for {key!r}")
    for key in sorted(table_keys - source_keys):
        errors.append(f"core: French entry no longer in the code: {key!r}")


def check_extracted(catalog, directory):
    extracted = set()
    files = list(pathlib.Path(directory).rglob("*.stringsdata"))
    if not files:
        errors.append(f"no .stringsdata under {directory}")
    for path in files:
        data = json.loads(path.read_text(encoding="utf-8"))
        extracted |= {item["key"] for item in data.get("tables", {}).get("Localizable", [])}
    keys = set(catalog["strings"])
    for key in sorted(extracted - keys):
        errors.append(f"{APP_CATALOG.name}: {key!r} is in the code but not in the catalog")
    for key in sorted(keys - extracted):
        errors.append(f"{APP_CATALOG.name}: {key!r} is no longer in the code")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stringsdata", help="build folder holding the app's .stringsdata files")
    args = parser.parse_args()
    catalog = check_app_catalog()
    check_core()
    if args.stringsdata:
        check_extracted(catalog, args.stringsdata)
    if errors:
        print("\n".join(f"::error::{e}" for e in errors))
        sys.exit(1)
    print(f"Localizations OK: {len(catalog['strings'])} app strings, French complete")


main()
