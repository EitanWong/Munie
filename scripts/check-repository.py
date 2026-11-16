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


APPLE_PLATFORMS = {'ios', 'macos', 'tvos', 'watchos', 'visionos'}


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


def main():
    for name in ('README.md', 'README.zh-Hans.md', 'AGENTS.md', 'CONTRIBUTING.md',
                 'SECURITY.md', 'docs/project-status.md', 'references/manifest.json'):
        require((ROOT / name).is_file(), f'Missing maintained file: {name}')

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
