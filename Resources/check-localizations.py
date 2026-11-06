#!/usr/bin/env python3
"""Validate bundled UI keys and format arguments without changing system language."""
import collections
import json
from pathlib import Path
import re
import subprocess

root = Path(__file__).resolve().parent
languages = ['en', 'zh-Hans', 'zh-Hant', 'ja', 'de', 'fr', 'es']
tables = {}
for language in languages:
    for name in ['Localizable', 'ServicesMenu', 'InfoPlist']:
        path = root / (language + '.lproj') / (name + '.strings')
        result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(path)], check=True, text=True, capture_output=True)
        table = json.loads(result.stdout)
        assert all(isinstance(value, str) and value for value in table.values()), f'Empty value in {path}'
        tables[language, name] = table
for name in ['Localizable', 'ServicesMenu', 'InfoPlist']:
    expected = tables['en', name]
    for language in languages:
        table = tables[language, name]
        assert table.keys() == expected.keys(), f'Key mismatch: {language}/{name}'
        for key, value in table.items():
            formats = lambda text: collections.Counter(re.findall(r'%(?:\d+\$)?[@diufgs]', text))
            assert formats(value) == formats(expected[key]), f'Format mismatch: {language}/{key}'
used = set()
for path in (root.parent / 'Sources' / 'SevenZip').glob('*.swift'):
    used.update(re.findall(r'L10n\.(?:tr|format|message)\("([^"\n]+)"', path.read_text()))
missing = used - tables['en', 'Localizable'].keys()
assert not missing, f'Untranslated source keys: {missing}'
print(f'PASS: {len(languages)} languages, {len(tables["en", "Localizable"])} keys, source coverage and format arguments')
