#!/usr/bin/env python3
"""Check repository contracts without downloading or executing reference code."""

import hashlib
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


APPLE_PLATFORMS = {'ios', 'macos', 'tvos', 'watchos', 'visionos'}


def markdown_links(markdown):
    """Extract the repository's inline links, excluding fenced and inline code examples."""
    visible = []
    fence = None
    for line in markdown.splitlines(keepends=True):
        if fence:
            character, length = fence
            closing = r' {0,3}' + re.escape(character) + '{' + str(length) + r',}[ \t]*\r?\n?'
            if re.fullmatch(closing, line):
                fence = None
            # Retain a block boundary so code spans cannot bridge a removed fence.
            visible.append('\n')
            continue
        opening = re.match(r'^ {0,3}(`{3,}|~{3,})([^\r\n]*)', line)
        if opening and (opening[1][0] != '`' or '`' not in opening[2]):
            fence = (opening[1][0], len(opening[1]))
            visible.append('\n')
        else:
            visible.append(line)

    links = []
    for paragraph in re.split(r'\r?\n[ \t]*\r?\n', ''.join(visible)):
        runs = list(re.finditer(r'`+', paragraph))
        next_by_length = {}
        closing_runs = {}
        for index in range(len(runs) - 1, -1, -1):
            length = len(runs[index][0])
            if length in next_by_length:
                closing_runs[index] = next_by_length[length]
            next_by_length[length] = index
        masked = list(paragraph)
        index = 0
        while index < len(runs):
            start = runs[index].start()
            preceding = start
            while preceding > 0 and paragraph[preceding - 1] == '\\':
                preceding -= 1
            closing_index = closing_runs.get(index)
            if (start - preceding) % 2 or closing_index is None:
                index += 1
                continue
            # Only an equally long backtick run closes a code span; escapes inside are literal.
            end = runs[closing_index].end()
            masked[start:end] = ' ' * (end - start)
            index = closing_index + 1
        links.extend(re.findall(r'\[[^\]]*\]\(([^\s)]+)\)', ''.join(masked)))
    return links


def validate_documentation(root):
    """Keep topic-named documentation discoverable through the maintained index."""
    docs = (root / 'docs').resolve()
    documents = {path.resolve() for path in docs.rglob('*.md')}
    index = docs / 'README.md'
    require(index in documents, 'Missing documentation index: docs/README.md')
    for path in sorted(documents):
        require(not re.match(r'^\d+[-_]', path.name),
                f'Use a topic filename without a numeric prefix: {path.relative_to(docs)}')
    visited = set()
    pending = [index]
    while pending:
        path = pending.pop()
        if path in visited:
            continue
        visited.add(path)
        for link in markdown_links(path.read_text(encoding='utf-8')):
            target = unquote(link.split('#')[0])
            if not target or re.match(r'[a-zA-Z]+:', target):
                continue
            resolved = (path.parent / target).resolve()
            if resolved in documents and resolved not in visited:
                pending.append(resolved)
    orphans = documents - visited
    require(not orphans, 'Unindexed documentation: ' +
            ', '.join(str(path.relative_to(docs)) for path in sorted(orphans)))


def validate_swift_package(package_root, manifest):
    """Reject local packages that silently drop a shipping platform or conventional source roots."""
    platforms = {item['platformName'] for item in manifest.get('platforms', [])}
    require(APPLE_PLATFORMS <= platforms,
            f'{package_root.name} must declare every Apple platform: '
            f'{", ".join(sorted(APPLE_PLATFORMS - platforms))}')
    for target in manifest['targets']:
        # Local shipping packages use SwiftPM's standard Sources/Tests layout.
        # The root host-only presentation harness intentionally uses custom app paths.
        target_root = 'Tests' if target['type'] == 'test' else 'Sources'
        expected = f"{target_root}/{target['name']}"
        require(target.get('path') in (None, expected),
                f"{package_root.name}/{target['name']} must use {expected}")
        require((package_root / expected).is_dir(),
                f'Missing SwiftPM target source directory: {package_root.name}/{expected}')


def check_swift_packages(root):
    manifests = sorted((root / 'packages').glob('*/Package.swift'))
    require(bool(manifests), 'No reusable Swift package found under packages/')
    for manifest in manifests:
        result = subprocess.run(['swift', 'package', '--package-path', str(manifest.parent),
                                 'dump-package'], check=True, text=True, capture_output=True)
        validate_swift_package(manifest.parent, json.loads(result.stdout))


def validate_xcode_project(project):
    """Check the generated graph, rather than trusting labels in the source spec."""
    objects = project['objects']
    targets = {item['name']: item for item in objects.values()
               if item.get('isa') == 'PBXNativeTarget'}
    require({'Munie', 'MunieWatch'} <= targets.keys(),
            'Generated project must contain native Munie and MunieWatch app targets')
    expected_sdks = {'iphoneos', 'iphonesimulator', 'macosx', 'appletvos',
                     'appletvsimulator', 'xros', 'xrsimulator'}
    for name in ('Munie', 'MunieWatch'):
        target = targets[name]
        require(target['productType'] == 'com.apple.product-type.application',
                f'{name} must be a native application target')
        configurations = objects[target['buildConfigurationList']]['buildConfigurations']
        require(bool(configurations), f'Missing build configurations for {name}')
        for configuration in configurations:
            settings = objects[configuration]['buildSettings']
            if name == 'Munie':
                sdks = set(settings.get('SUPPORTED_PLATFORMS', '').split())
                require(expected_sdks <= sdks and not sdks & {'watchos', 'watchsimulator'},
                        'Munie must support native iOS, macOS, tvOS and visionOS SDKs; '
                        'watchOS belongs in its own target')
                devices = settings.get('TARGETED_DEVICE_FAMILY[sdk=iphone*]',
                                       settings.get('TARGETED_DEVICE_FAMILY', ''))
                require({'1', '2'} <= {item.strip() for item in devices.split(',')},
                        'Munie iOS device family must include both iPhone and iPad')
            else:
                require(settings.get('SDKROOT') == 'watchos',
                        'MunieWatch must use the native watchOS SDK')
    for dependency in targets['Munie'].get('dependencies', []):
        linked_target = objects[dependency].get('target')
        require(linked_target is None or objects[linked_target]['name'] != 'MunieWatch',
                'Do not embed the standalone Watch app into every Munie platform')


def check_xcode_project(root):
    project = root / 'Munie.xcodeproj/project.pbxproj'
    require(project.is_file(), 'Missing generated Xcode project; run ./scripts/bootstrap.sh')
    result = subprocess.run(['plutil', '-convert', 'json', '-o', '-', str(project)],
                            check=True, text=True, capture_output=True)
    validate_xcode_project(json.loads(result.stdout))


def check_identity_research(root):
    """Verify the opt-in fixture lock and archived notices without resolving packages."""
    archive = root / 'references/licenses/device-identity'
    manifest = json.loads((archive / 'manifest.json').read_text())
    packages = manifest['packages']
    expected = {item['identity']: (item['repository'], item['revision']) for item in packages}
    for fixture in ('device-identity', 'device-identity-ios'):
        lock = json.loads((root / 'scripts/fixtures' / fixture / 'Package.resolved').read_text())
        pins = lock['pins']
        actual = {item['identity']: (item['location'], item['state']['revision']) for item in pins}
        require(len(expected) == len(packages) == len(actual) == len(pins) == 3 and expected == actual,
                'Identity fixture lock does not match its reviewed license source revisions: ' + fixture)
    files = manifest['files']
    require(len(files) == 8 and len({item['path'] for item in files}) == 8,
            'Identity fixture must preserve eight distinct core license/notice files')
    for item in files:
        name = item['path']
        require(Path(name).name == name and name.endswith('.txt'), 'Invalid license archive path')
        data = (archive / name).read_bytes()
        require(type(item['bytes']) is int and len(data) == item['bytes'] and
                hashlib.sha256(data).hexdigest() == item['sha256'],
                f'Identity license archive bytes changed: {name}')


def main():
    for name in ('README.md', 'README.zh-Hans.md', 'AGENTS.md', 'CONTRIBUTING.md',
                 'SECURITY.md', 'docs/project-status.md', 'references/manifest.json'):
        require((ROOT / name).is_file(), f'Missing maintained file: {name}')

    validate_documentation(ROOT)
    check_identity_research(ROOT)
    subprocess.run([sys.executable, str(ROOT / 'scripts/catalog-codex.py'),
                    '--validate-catalog', str(ROOT / 'references/codex-capabilities.json')], check=True)
    check_swift_packages(ROOT)
    check_xcode_project(ROOT)

    catalog = json.loads((ROOT / 'apps/Munie/Resources/Localizable.xcstrings').read_text())
    strings = catalog['strings']
    for key, item in strings.items():
        for language in ('en', 'zh-Hans'):
            unit = item['localizations'][language]['stringUnit']
            require(unit['state'] == 'translated' and bool(unit['value'].strip()),
                    f'Missing {language} translation: {key}')
    patterns = [
        r'\b(?:Text|TextField|SecureField|Button|Label|ContentUnavailableView)\(\s*"([^"\\\n]+)"',
        r'String\(localized:\s*"([^"\\\n]+)"',
        r'\.(?:navigationTitle|accessibilityLabel|alert|confirmationDialog)\(\s*"([^"\\]+)"',
        r'prompt:\s*"([^"\\]+)"',
    ]
    for source in (ROOT / 'apps').rglob('*.swift'):
        for pattern in patterns:
            for key in re.findall(pattern, source.read_text()):
                require(key in strings, f'Unlocalized string in {source.name}: {key}')

    for file in (ROOT / 'apps').rglob('*.xcprivacy'):
        plistlib.loads(file.read_bytes())
    for file in (ROOT / 'apps').rglob('Contents.json'):
        json.loads(file.read_text())
    icon = ROOT / 'apps/Munie/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png'
    png = icon.read_bytes()
    require(png[:8] == b'\x89PNG\r\n\x1a\n', 'App icon must be PNG')
    width, height, depth, color_type = struct.unpack('>IIBB', png[16:26])
    require((width, height, depth, color_type) == (1024, 1024, 8, 2),
            'App icon must be a 1024px opaque RGB PNG')
    for file in (ROOT / 'scripts').glob('*.sh'):
        subprocess.run(['bash', '-n', str(file)], check=True)
        require(file.stat().st_mode & 0o111, f'Script is not executable: {file.name}')

    # Historical research retains original links; maintained guidance must be navigable.
    markdown = [*ROOT.glob('*.md'),
                *(path for path in (ROOT / 'docs').rglob('*.md')
                  if 'research' not in path.relative_to(ROOT / 'docs').parts),
                *ROOT.glob('references/*.md')]
    for file in markdown:
        for link in markdown_links(file.read_text(encoding='utf-8')):
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
