#!/usr/bin/env bats

# Test release-manifest.json structure and consistency

setup() {
    export ROOT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
    export MANIFEST="${ROOT_DIR}/templates/release-manifest.json"
    export VERSIONS="${ROOT_DIR}/templates/versions.env"
}

@test "release-manifest.json is valid JSON" {
    run python3 -m json.tool "$MANIFEST"
    [ "$status" -eq 0 ]
}

@test "manifest has required top-level keys" {
    run python3 -c "
import json, sys
m = json.load(open('$MANIFEST'))
required = {'version', 'release_date', 'min_installer_version', 'images', 'compatibility', 'changelog_url'}
missing = required - set(m.keys())
if missing:
    print(f'Missing: {missing}')
    sys.exit(1)
"
    [ "$status" -eq 0 ]
}

@test "manifest has at least 23 images" {
    run python3 -c "
import json, sys
m = json.load(open('$MANIFEST'))
count = len(m.get('images', {}))
if count < 23:
    print(f'Only {count} images, expected >= 23')
    sys.exit(1)
print(f'{count} images')
"
    [ "$status" -eq 0 ]
}

@test "manifest includes node-exporter and alertmanager" {
    run python3 -c "
import json, sys
m = json.load(open('$MANIFEST'))
images = m.get('images', {})
missing = []
for svc in ['node-exporter', 'alertmanager']:
    if svc not in images:
        missing.append(svc)
if missing:
    print(f'Missing: {missing}')
    sys.exit(1)
"
    [ "$status" -eq 0 ]
}

@test "all image entries have required fields" {
    run python3 -c "
import json, sys
m = json.load(open('$MANIFEST'))
required_fields = {'registry', 'image', 'tag', 'digest', 'platforms'}
errors = []
for svc, info in m.get('images', {}).items():
    missing = required_fields - set(info.keys())
    if missing:
        errors.append(f'{svc}: missing {missing}')
if errors:
    print('\n'.join(errors))
    sys.exit(1)
"
    [ "$status" -eq 0 ]
}

@test "changelog_url does not contain placeholder" {
    run python3 -c "
import json, sys
m = json.load(open('$MANIFEST'))
url = m.get('changelog_url', '')
if 'your-org' in url:
    print(f'Placeholder in changelog_url: {url}')
    sys.exit(1)
"
    [ "$status" -eq 0 ]
}

@test "cadvisor version matches versions.env" {
    # Regression test for v0.49.1 vs v0.52.1 mismatch
    manifest_tag=$(python3 -c "import json; print(json.load(open('$MANIFEST'))['images']['cadvisor']['tag'])")
    versions_tag=$(grep '^CADVISOR_VERSION=' "$VERSIONS" | cut -d= -f2)
    [ "$manifest_tag" = "$versions_tag" ]
}

@test "check-manifest-versions.py runs without error (structural check)" {
    run python3 -c "
import importlib.util, sys
spec = importlib.util.spec_from_file_location('check', '${ROOT_DIR}/scripts/check-manifest-versions.py')
mod = importlib.util.module_from_spec(spec)
# Just verify the script is valid Python, don't run main() (digests may be empty)
spec.loader.exec_module(mod)
# Verify key functions exist
assert hasattr(mod, 'parse_versions_env'), 'Missing parse_versions_env'
assert hasattr(mod, 'main'), 'Missing main'
"
    [ "$status" -eq 0 ]
}
