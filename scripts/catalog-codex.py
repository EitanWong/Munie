#!/usr/bin/env python3
"""Inventory exported Codex protocol methods offline; never launch Codex or a model."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

KINDS = ('ClientRequest', 'ServerRequest', 'ServerNotification', 'ClientNotification')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_json(path):
    def unique_keys(items):
        result = {}
        for key, value in items:
            require(key not in result, f'Duplicate JSON key in {path.name}: {key}')
            result[key] = value
        return result

    def invalid_constant(value):
        raise ValueError(f'Non-finite JSON value in {path.name}: {value}')

    require(path.is_file() and not path.is_symlink(), f'Missing or symlinked JSON file: {path}')
    return json.loads(path.read_text(encoding='utf-8'), object_pairs_hook=unique_keys,
                      parse_constant=invalid_constant)


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'),
                      allow_nan=False).encode('utf-8')


def validate_local_refs(document, name):
    """Resolve only in-document references; a missing/new external reference requires review."""
    def visit(value):
        if type(value) is dict:
            if '$ref' in value:
                reference = value['$ref']
                require(type(reference) is str and (reference == '#' or reference.startswith('#/')),
                        f'{name}: unsupported external schema reference')
                target = document
                for token in reference[2:].split('/') if reference != '#' else []:
                    token = token.replace('~1', '/').replace('~0', '~')
                    require(type(target) is dict and token in target,
                            f'{name}: unresolved schema reference {reference}')
                    target = target[token]
                require(type(target) is dict, f'{name}: reference must resolve to a schema object')
            for child in value.values():
                visit(child)
        elif type(value) is list:
            for child in value:
                visit(child)

    visit(document)


def methods(schema, kind):
    """Require the exported tagged union shape so a new shape cannot disappear silently."""
    require(type(schema) is dict and schema.get('title') == kind, f'Expected {kind} schema')
    variants = schema.get('oneOf')
    require(type(variants) is list and bool(variants), f'{kind}: missing nonempty oneOf')
    result = set()
    for variant in variants:
        require(type(variant) is dict and variant.get('type') == 'object',
                f'{kind}: unsupported union variant')
        properties = variant.get('properties')
        required = variant.get('required')
        require(type(properties) is dict and type(required) is list and
                all(type(key) is str for key in required) and len(set(required)) == len(required),
                f'{kind}: invalid properties/required')
        require('method' in required and 'method' in properties, f'{kind}: missing method tag')
        tag = properties['method']
        require(type(tag) is dict and tag.get('type') == 'string', f'{kind}: invalid method tag')
        values = tag.get('enum') if 'enum' in tag else [tag.get('const')]
        require(type(values) is list and len(values) == 1 and type(values[0]) is str and
                re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(?:/[A-Za-z][A-Za-z0-9_]*)*', values[0]),
                f'{kind}: method must have one literal name')
        require(not ('enum' in tag and 'const' in tag), f'{kind}: ambiguous method tag')
        method = values[0]
        require(method not in result, f'{kind}: duplicate method {method}')
        if kind.endswith('Request'):
            require('id' in properties and 'id' in required and 'params' in properties,
                    f'{kind}/{method}: requests require id and params')
        else:
            require('id' not in properties and 'id' not in required,
                    f'{kind}/{method}: notifications cannot require a response id')
        require(all(type(value) is dict for value in properties.values()),
                f'{kind}/{method}: properties must contain schema objects')
        require(set(required) <= properties.keys(), f'{kind}/{method}: undefined required property')
        result.add(method)
    return result


def read_bundle(directory):
    require(directory.is_dir() and not directory.is_symlink(), f'Missing schema directory: {directory}')
    files = sorted(directory.rglob('*.json'))
    require(bool(files), f'No JSON schema files: {directory}')
    schemas = {}
    digest = hashlib.sha256()
    for path in files:
        document = read_json(path)
        require(type(document) is dict, f'Schema must be an object: {path}')
        validate_local_refs(document, path.name)
        # Hash every exported schema, including responses/definitions, not just method names.
        digest.update(path.relative_to(directory).as_posix().encode() + b'\0')
        digest.update(canonical(document) + b'\0')
        if path.parent == directory and path.stem in KINDS:
            schemas[path.stem] = document
    require(set(schemas) == set(KINDS), 'Schema bundle must contain all four protocol unions')
    inventory = {kind: methods(schemas[kind], kind) for kind in KINDS}
    return inventory, {'sha256': digest.hexdigest(), 'jsonFiles': len(files)}


def category(kind, method):
    """Munie review groups, not upstream claims of availability or product feature completeness."""
    if kind == 'ServerRequest':
        if 'requestApproval' in method or method in ('applyPatchApproval', 'execCommandApproval'):
            return 'approvals'
        return {
            'item/tool/requestUserInput': 'user_input', 'item/tool/call': 'dynamic_tools',
            'mcpServer/elicitation/request': 'mcp',
            'account/chatgptAuthTokens/refresh': 'accounts_and_auth',
            'attestation/generate': 'attestation', 'currentTime/read': 'host_services',
        }.get(method, 'other_native')
    if method in ('initialize', 'initialized'):
        return 'protocol'
    if method.startswith('thread/realtime/'):
        return 'voice_realtime'
    if method.startswith('thread/backgroundTerminals/'):
        return 'process_and_commands'
    prefix = method.split('/')[0]
    return {
        'thread': 'threads', 'threadSection': 'projects_and_navigation', 'turn': 'turns',
        'review': 'review', 'item': 'items_and_streaming', 'serverRequest': 'server_request_lifecycle',
        'skills': 'skills_and_hooks', 'hooks': 'skills_and_hooks', 'hook': 'skills_and_hooks',
        'plugin': 'plugins_and_apps', 'marketplace': 'plugins_and_apps', 'app': 'plugins_and_apps',
        'account': 'accounts_and_auth', 'userVerification': 'accounts_and_auth',
        'model': 'models_and_features', 'modelProvider': 'models_and_features',
        'experimentalFeature': 'models_and_features', 'collaborationMode': 'models_and_features',
        'permissionProfile': 'permissions', 'mcpServer': 'mcp', 'mcpServerStatus': 'mcp',
        'fs': 'filesystem', 'command': 'process_and_commands', 'process': 'process_and_commands',
        'project': 'projects_and_navigation', 'config': 'configuration',
        'configRequirements': 'configuration', 'externalAgentConfig': 'configuration',
        'remoteControl': 'remote_control', 'environment': 'environment',
        'memory': 'memory', 'rollout': 'memory', 'fuzzyFileSearch': 'search',
        'server': 'diagnostics', 'feedback': 'diagnostics', 'mock': 'test_surface',
        'windows': 'platform_setup', 'windowsSandbox': 'platform_setup',
        'error': 'errors', 'warning': 'warnings', 'guardianWarning': 'warnings',
        'deprecationNotice': 'warnings', 'configWarning': 'warnings',
        'autoApprovalReview': 'approvals',
    }.get(prefix, 'other_native')


def build_catalog(schema_directory, default_directory, cli_version):
    require(type(cli_version) is str and
            re.fullmatch(r'codex-cli [0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?', cli_version),
            'Use the literal codex --version result, for example codex-cli 0.162.1')
    full, full_metadata = read_bundle(schema_directory)
    default, default_metadata = read_bundle(default_directory)
    grouped = {}
    for kind in KINDS:
        require(default[kind] <= full[kind], f'{kind}: default export is not a subset of full export')
        grouped[kind] = [
            {'method': method, 'category': category(kind, method),
             'presentInDefaultExport': method in default[kind], 'status': 'unimplemented'}
            for method in sorted(full[kind])
        ]
    return {
        'catalogVersion': 1, 'harness': 'codex', 'cliVersion': cli_version,
        'source': {
            'documentation': 'https://learn.chatgpt.com/docs/app-server',
            'schemaHashRecipe': 'SHA-256 of sorted relative path + NUL + canonical sorted-key JSON + NUL',
            'fullExportCommand': 'codex app-server generate-json-schema --experimental --out SCHEMA_DIR',
            'defaultExportCommand': 'codex app-server generate-json-schema --out DEFAULT_SCHEMA_DIR',
        },
        'schemaBundles': {'experimental': full_metadata, 'default': default_metadata},
        'counts': {kind: len(grouped[kind]) for kind in KINDS},
        'totalMethods': sum(len(group) for group in grouped.values()),
        'implementedMethods': 0,
        'notes': [
            'Generated method inventory only; no remote adapter or method behavior has been implemented.',
            'Default-export presence is not a stability, feature-flag, account or platform availability claim.',
            'Experimental methods and fields need explicit runtime negotiation and upstream eligibility.',
            'Method coverage alone does not prove field, response, event variant or Codex Desktop UI parity.',
            'Categories are Munie review groups; all original method names and protocol directions are retained.',
        ],
        'methods': grouped,
    }


def check_catalog(expected, actual):
    # Python considers True == 1 and False == 0; protocol JSON types remain distinct.
    if canonical(expected) == canonical(actual):
        return
    require(type(actual) is dict, 'Catalog must be an object')
    messages = []
    actual_groups = actual.get('methods', {})
    require(type(actual_groups) is dict, 'Catalog methods must be an object')
    for kind in KINDS:
        rows = actual_groups.get(kind, [])
        require(type(rows) is list and all(type(row) is dict and type(row.get('method')) is str
                                         for row in rows), f'Catalog {kind} has malformed rows')
        current = {row['method']: row for row in rows}
        require(len(current) == len(rows), f'Catalog {kind} has duplicate methods')
        generated = {row['method']: row for row in expected['methods'][kind]}
        for label, names in (('added', generated.keys() - current.keys()),
                             ('removed', current.keys() - generated.keys())):
            if names:
                messages.append(f'{kind} {label}: {", ".join(sorted(names))}')
        changed = sorted(name for name in generated.keys() & current.keys()
                         if generated[name] != current[name])
        if changed:
            messages.append(f'{kind} changed metadata/status: {", ".join(changed)}')
    if expected.get('schemaBundles') != actual.get('schemaBundles'):
        messages.append('Exported schema hash changed; review fields, responses and event variants too')
    if expected.get('cliVersion') != actual.get('cliVersion'):
        messages.append('CLI version changed')
    if not messages:
        messages.append('Catalog counts, provenance or contract metadata changed')
    raise ValueError('Catalog drift:\n' + '\n'.join(messages))


def validate_snapshot(snapshot):
    """Check stored inventory integrity only; no installed-protocol drift claim is possible here."""
    require(type(snapshot) is dict, 'Catalog must be an object')
    require(type(snapshot.get('catalogVersion')) is int and snapshot['catalogVersion'] == 1,
            'Unsupported catalog version')
    require(snapshot.get('harness') == 'codex', 'Catalog must identify the Codex harness')
    require(type(snapshot.get('cliVersion')) is str and
            re.fullmatch(r'codex-cli [0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?', snapshot['cliVersion']),
            'Catalog must identify the literal CLI version')
    bundles = snapshot.get('schemaBundles')
    require(type(bundles) is dict and set(bundles) == {'experimental', 'default'},
            'Catalog must record both schema export bundles')
    for name, metadata in bundles.items():
        require(type(metadata) is dict and type(metadata.get('sha256')) is str and
                re.fullmatch(r'[0-9a-f]{64}', metadata['sha256']), f'{name}: invalid schema SHA-256')
        require(type(metadata.get('jsonFiles')) is int and metadata['jsonFiles'] >= len(KINDS),
                f'{name}: invalid schema file count')
    source = snapshot.get('source')
    require(type(source) is dict and all(type(source.get(key)) is str and source[key].strip()
            for key in ('documentation', 'schemaHashRecipe', 'fullExportCommand', 'defaultExportCommand')),
            'Missing schema provenance')
    groups = snapshot.get('methods')
    counts = snapshot.get('counts')
    require(type(groups) is dict and set(groups) == set(KINDS), 'Catalog must retain all four roles')
    require(type(counts) is dict and set(counts) == set(KINDS), 'Catalog role counts are incomplete')
    total = 0
    for kind in KINDS:
        rows = groups[kind]
        require(type(rows) is list and bool(rows), f'{kind}: missing method rows')
        seen = set()
        for row in rows:
            require(type(row) is dict and
                    set(row) == {'method', 'category', 'presentInDefaultExport', 'status'},
                    f'{kind}: malformed method row')
            method = row['method']
            require(type(method) is str and
                    re.fullmatch(r'[A-Za-z][A-Za-z0-9_]*(?:/[A-Za-z][A-Za-z0-9_]*)*', method),
                    f'{kind}: invalid method name')
            require(method not in seen, f'{kind}: duplicate method {method}')
            seen.add(method)
            require(type(row['category']) is str and bool(row['category'].strip()) and
                    row['category'] == category(kind, method), f'{kind}/{method}: invalid category')
            require(type(row['presentInDefaultExport']) is bool,
                    f'{kind}/{method}: default-export presence must be boolean')
            require(row['status'] == 'unimplemented',
                    f'{kind}/{method}: foundation inventory cannot claim implementation')
        require(type(counts[kind]) is int and counts[kind] == len(rows), f'{kind}: count mismatch')
        total += len(rows)
    require(type(snapshot.get('totalMethods')) is int and snapshot['totalMethods'] == total,
            'Catalog total count mismatch')
    require(type(snapshot.get('implementedMethods')) is int and snapshot['implementedMethods'] == 0,
            'Foundation inventory must record zero implemented methods')
    notes = snapshot.get('notes')
    require(type(notes) is list and bool(notes) and
            all(type(note) is str and note.strip() for note in notes), 'Missing inventory limitations')
    return total


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--schema-dir', type=Path,
                        help='Existing --experimental JSON schema export (not executed by this script)')
    parser.add_argument('--default-schema-dir', type=Path,
                        help='Existing default JSON schema export for the same CLI version')
    parser.add_argument('--cli-version')
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--output', type=Path)
    action.add_argument('--check', type=Path)
    action.add_argument('--validate-catalog', type=Path, help='Validate snapshot structure only, offline')
    args = parser.parse_args()
    if args.validate_catalog:
        require(args.schema_dir is None and args.default_schema_dir is None and args.cli_version is None,
                '--validate-catalog does not take schema directories or a CLI version')
        total = validate_snapshot(read_json(args.validate_catalog))
        print(f'Codex catalog structure validated: total={total}; implemented=0; '
              'generated-schema drift not checked.')
        return
    require(args.schema_dir is not None and args.default_schema_dir is not None and
            args.cli_version is not None, '--output/--check require both schema directories and --cli-version')
    catalog = build_catalog(args.schema_dir, args.default_schema_dir, args.cli_version)
    validate_snapshot(catalog)
    if args.check:
        check_catalog(catalog, read_json(args.check))
    else:
        args.output.write_text(json.dumps(catalog, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    counts = ', '.join(f'{kind}={count}' for kind, count in catalog['counts'].items())
    print(f'Codex catalog {"verified" if args.check else "written"}: {counts}; '
          f'total={catalog["totalMethods"]}; implemented=0.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, OverflowError) as error:
        sys.exit(f'Codex catalog failed: {error}')
