#!/usr/bin/env python3
"""Check source-string coverage and identical keys across supported locales."""
import glob
import json
import re
from pathlib import Path

languages = ("en", "bg", "fr", "el", "hu", "pt-BR", "es", "tr")
entry_pattern = re.compile(r'^\s*("(?:[^"\\]|\\.)*")\s*=\s*("(?:[^"\\]|\\.)*");\s*$', re.M)

def format_localization_key(value):
    """Map Swift interpolation syntax to the format key SwiftUI uses at runtime."""
    result = []
    index = 0
    while index < len(value):
        if value.startswith("\\(", index):
            start = index + 2
            depth = 1
            cursor = start
            quoted = escaped = False
            while cursor < len(value) and depth:
                char = value[cursor]
                if quoted:
                    if escaped:
                        escaped = False
                    elif char == "\\":
                        escaped = True
                    elif char == '"':
                        quoted = False
                elif char == '"':
                    quoted = True
                elif char == "(":
                    depth += 1
                elif char == ")":
                    depth -= 1
                cursor += 1
            if depth == 0:
                expression = value[start:cursor - 1].strip()
                if "format:" in expression:
                    result.append("%@")
                elif expression.startswith(("Int(", "UInt(")) or expression in {
                    "position", "days", "submittedCount", "entry.count", "queueStatus.active",
                    "season", "number", "status", "model.cooldownSeconds", "selectedCatalogSongs.count", "successful", "expected"
                }:
                    result.append("%lld")
                else:
                    result.append("%@")
                index = cursor
                continue
        result.append(value[index])
        index += 1
    return "".join(result)
key_sets = {}
for language in languages:
    path = Path(f"{language}.lproj/Localizable.strings")
    if not path.exists():
        raise SystemExit(f"Missing localization table: {language}")
    key_sets[language] = {json.loads(key) for key, _ in entry_pattern.findall(path.read_text())}
    values = {json.loads(key): json.loads(value) for key, value in entry_pattern.findall(path.read_text())}
    for key, value in values.items():
        key_specs = re.findall(r'%(?:@|lld)', key)
        value_specs = re.findall(r'%(?:@|lld)', value)
        if sorted(key_specs) != sorted(value_specs):
            raise SystemExit(f"{language}: placeholder mismatch for {key!r}: {key_specs} != {value_specs}")

reference = key_sets["en"]
errors = []
for language, keys in key_sets.items():
    if keys != reference:
        errors.append(f"{language}: missing={sorted(reference-keys)}, extra={sorted(keys-reference)}")

patterns = (
    r'(?:Text|Button|Label|Section|Picker|LabeledContent|ProgressView|ContentUnavailableView)\(\s*"((?:[^"\\]|\\.)*)"',
    r'Link\(\s*"((?:[^"\\]|\\.)*)"',
    r'(?:navigationTitle|accessibilityLabel|accessibilityValue|accessibilityHint)\(\s*"((?:[^"\\]|\\.)*)"',
    r'String\(localized:\s*"((?:[^"\\]|\\.)*)"',
    r'(?:alert|confirmationDialog)\(\s*"((?:[^"\\]|\\.)*)"',
    r'prompt:\s*"((?:[^"\\]|\\.)*)"',
    r'(?:browsePage|shelf)\((?:title:\s*)?"((?:[^"\\]|\\.)*)"',
    r'(?:sectionHeader|sectionHeading|emptyMessage|heroCard|openProviderButton)\(\s*(?:title:\s*)?"((?:[^"\\]|\\.)*)"',
    r'openProviderButton\([^\n]*?label:\s*"((?:[^"\\]|\\.)*)"',
    r'\b(?:detail|subtitle):\s*"((?:[^"\\]|\\.)*)"',
    r'DowntifyUnavailableView\(title:\s*"((?:[^"\\]|\\.)*)"',
    r'collectionStatus\([\s\S]{0,250}?title:\s*"((?:[^"\\]|\\.)*)"',
    r'TrashAlert\(title:\s*"((?:[^"\\]|\\.)*)"',
    r'mutate\(failure:\s*"((?:[^"\\]|\\.)*)"',
    r'(?:cachedError|storageFailure)\("((?:[^"\\]|\\.)*)"',
    r'requestMessage\s*=\s*"((?:[^"\\]|\\.)*)"',
    r'errorMessage\s*=\s*"((?:[^"\\]|\\.)*)"',
    r'(?:queueError|localError|signOutError)\s*=\s*"((?:[^"\\]|\\.)*)"',
    r'(?:status|state)\s*=\s*\.failed\("((?:[^"\\]|\\.)*)"',
    r'state\s*=\s*\.(?:cachedError|storageFailure)\("((?:[^"\\]|\\.)*)"',
    r'downloadMessage\s*=[^\n]*?"((?:[^"\\]|\\.)*)"',
    r'case\s+\.\w+:\s*"((?:[^"\\]|\\.)*)"',
    r'case\s+\.\w+\s*\([^)]*\)\s*:\s*"((?:[^"\\]|\\.)*)"',
    r'case\s+(?:\.\w+(?:,\s*)?)+:\s*"((?:[^"\\]|\\.)*)"',
)
non_localized_case_values = {"music.mic", "opticaldisc", "music.note.list", "heart.fill"}
source_keys = set()
for source in glob.glob("Downtify/**/*.swift", recursive=True):
    content = Path(source).read_text()
    for pattern in patterns:
        for key in re.findall(pattern, content):
            # Skip regex fragments that terminate inside a nested Swift interpolation.
            if "queueStatus.paused ?" in key or "metadata.title ??" in key or "code ?? " in key:
                continue
            if key.startswith("Similar to \\("):
                continue
            # Punctuation used to join localized Text fragments is not a standalone phrase.
            if not any(char.isalnum() for char in key):
                continue
            if key in non_localized_case_values:
                continue
            source_keys.add(format_localization_key(key.replace('\\"', '"').replace('\\n', '\n')))
    if source.endswith("/Presentation/DownloadsView.swift"):
        for key in re.findall(r'return\s+"((?:[^"\\]|\\.)*)"', content):
            if "code ?? " in key:
                continue
            source_keys.add(format_localization_key(key.replace('\\"', '"').replace('\\n', '\n')))
    if source.endswith("/Presentation/LibraryHomeView.swift"):
        for line in content.splitlines():
            if "downloadMessage =" in line:
                for key in re.findall(r'"((?:[^"\\]|\\.)*)"', line):
                    source_keys.add(format_localization_key(key.replace('\\"', '"').replace('\\n', '\n')))
    if source.endswith("/Presentation/CatalogDiscoverView.swift"):
        for key in re.findall(r'(?:case|,)\s*\w+\s*=\s*"([^"]+)"', content):
            source_keys.add(key)
        for key in re.findall(r'sectionHeading\("(Similar to [^\n]+)", count:', content):
            source_keys.add(format_localization_key(key))
    if source.endswith(("/Presentation/CatalogSearchView.swift", "/Presentation/CatalogDiscoverView.swift")):
        for key in re.findall(r'TextField\(\s*"((?:[^"\\]|\\.)*)"', content):
            source_keys.add(format_localization_key(key))
source_keys.update({"System", "Light", "Dark", "OLED black"})
source_keys.update({"Could not reach the server."})
source_keys.update({"Queue %@ · %lld active", "Working on %@"})
source_keys.update({
    "The server could not complete this request (%@). Nothing was changed.",
    "The server could not confirm this request (%@). Nothing was moved.",
    "This episode belongs to a different server", "This track belongs to a different server",
    "Could not play this episode", "Could not play this track",
})
if source_keys - reference:
    errors.append(f"source keys: missing={sorted(source_keys-reference)}")
if reference - source_keys:
    errors.append(f"source keys: extra={sorted(reference-source_keys)}")
if errors:
    raise SystemExit("Localization coverage mismatch:\n" + "\n".join(errors))
print(f"Localization key parity passed: {len(reference)} source keys across {len(languages)} locales")
