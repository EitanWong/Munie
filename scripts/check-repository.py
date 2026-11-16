#!/usr/bin/env python3
"""Check repository contracts without downloading or executing reference code."""

import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import struct
from urllib.parse import unquote

ROOT = Path(__file__).resolve().parent.parent


def require(condition, message):
    if not condition:
        raise ValueError(message)


def main():
    for name in ('README.md', 'README.zh-Hans.md', 'AGENTS.md', 'CONTRIBUTING.md',
                 'SECURITY.md', 'docs/project-status.md', 'references/manifest.json'):
        require((ROOT / name).is_file(), f'Missing maintained file: {name}')

    catalog = json.loads((ROOT / 'apps/ios/Munie/Resources/Localizable.xcstrings').read_text())
    strings = catalog['strings']
    for key, item in strings.items():
        for language in ('en', 'zh-Hans'):
            unit = item['localizations'][language]['stringUnit']
            require(unit['state'] == 'translated' and bool(unit['value'].strip()),
                    f'Missing {language} translation: {key}')
    patterns = [
        r'\b(?:Text|Button|Label|ContentUnavailableView)\(\s*"([^"\\\n]+)"',
        r'String\(localized:\s*"([^"\\\n]+)"',
        r'\.(?:navigationTitle|accessibilityLabel|alert|confirmationDialog)\(\s*"([^"\\]+)"',
        r'prompt:\s*"([^"\\]+)"',
    ]
    for source in (ROOT / 'apps/ios/Munie').rglob('*.swift'):
        for pattern in patterns:
            for key in re.findall(pattern, source.read_text()):
                require(key in strings, f'Unlocalized string in {source.name}: {key}')

    for file in (ROOT / 'apps').rglob('*.xcprivacy'):
        plistlib.loads(file.read_bytes())
    for file in (ROOT / 'apps').rglob('Contents.json'):
        json.loads(file.read_text())
    icon = ROOT / 'apps/ios/Munie/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
    png = icon.read_bytes()
    require(png[:8] == b'\x89PNG\r\n\x1a\n', 'App icon must be PNG')
    width, height, depth, color_type = struct.unpack('>IIBB', png[16:26])
    require((width, height, depth, color_type) == (1024, 1024, 8, 2),
            'App icon must be a 1024px opaque RGB PNG')
    for file in (ROOT / 'scripts').glob('*.sh'):
        subprocess.run(['bash', '-n', str(file)], check=True)
        require(file.stat().st_mode & 0o111, f'Script is not executable: {file.name}')

    # Historical research retains original links; maintained guidance must be navigable.
    markdown = [*ROOT.glob('*.md'), *ROOT.glob('docs/*.md'),
                *ROOT.glob('docs/decisions/*.md'), *ROOT.glob('references/*.md')]
    for file in markdown:
        for link in re.findall(r'\[[^\]]*\]\(([^\s)]+)\)', file.read_text()):
            target = unquote(link.split('#')[0])
            if not target or re.match(r'[a-zA-Z]+:', target):
                continue
            require((file.parent / target).exists(), f'Broken link in {file.name}: {link}')
    subprocess.run([sys.executable, str(ROOT / 'scripts/sync-references.py'), '--list'], check=True)
    subprocess.run([sys.executable, '-B', '-m', 'unittest', 'discover', '-s',
                    str(ROOT / 'references/tests'), '-v'], check=True)
    subprocess.run([sys.executable, '-B', '-m', 'unittest', 'discover', '-s',
                    str(ROOT / 'scripts/tests'), '-v'], check=True)
    workflows = [str(path) for path in (ROOT / '.github/workflows').glob('*.yml')]
    subprocess.run(['ruby', '-ryaml', '-e',
                    'ARGV.each { |p| YAML.load_file(p) }; puts "Workflow YAML parsed"',
                    *workflows], check=True)
    subprocess.run(['git', 'diff', '--check'], cwd=ROOT, check=True)
    print(f'Repository checks passed; {len(strings)} UI strings cover en and zh-Hans.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
