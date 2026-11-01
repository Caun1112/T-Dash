#!/usr/bin/env python3
"""Inspect the actual package, not just its staging tree."""
import pathlib
import plistlib
import subprocess
import sys
import tempfile

deb = pathlib.Path(sys.argv[1]).resolve()
def run(*args):
    return subprocess.check_output(args, text=True).strip()

assert run('dpkg-deb', '-f', str(deb), 'Architecture') == 'iphoneos-arm64'
assert run('dpkg-deb', '-f', str(deb), 'Package') == 'com.caun.tdash.amap'
assert 'mobilesubstrate' in run('dpkg-deb', '-f', str(deb), 'Depends')
with tempfile.TemporaryDirectory() as tmp:
    subprocess.run(['dpkg-deb', '-x', str(deb), tmp], check=True)
    root = pathlib.Path(tmp)
    for path in root.rglob('*'):
        if path.is_file():
            assert str(path.relative_to(root)).startswith('var/jb/'), path
    lib = root / 'var/jb/Library/MobileSubstrate/DynamicLibraries'
    assert plistlib.loads((lib / 'TDash.plist').read_bytes()) == {'Filter': {'Bundles': ['com.autonavi.amap']}}
    binary = lib / 'TDash.dylib'
    assert set(run('lipo', '-archs', str(binary)).split()) == {'arm64', 'arm64e'}
    deps = run('otool', '-L', str(binary))
    assert '/Users/' not in deps and '/opt/' not in deps
    assert '@rpath/TDash.dylib' in deps
    assert '_TDashStart' in run('nm', '-gU', str(binary))
    # New Apple linkers emit __TEXT,__init_offsets rather than __mod_init_func.
    # Ask dyld's own inspection tool to resolve actual initializer targets.
    initializers = run('xcrun', 'dyld_info', '-inits', str(binary))
    assert initializers.count('_TDashLoad') == 2, initializers
    subprocess.run(['xcrun', 'dyld_info', '-validate_only', str(binary)], check=True)
    subprocess.run(['codesign', '--verify', '--all-architectures', '--verbose', str(binary)], check=True)
print('PASS: rootless layout, AMap-only filter, arm64/arm64e, initializer, load paths and signature')
