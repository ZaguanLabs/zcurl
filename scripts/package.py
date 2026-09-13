#!/usr/bin/env python3
"""Create a relocatable native bundle for hosts with a compatible runtime."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def package(zsh_source, output):
    zsh_source = zsh_source.resolve()
    settings = ROOT / 'build/.build-settings'
    settings_lines = settings.read_text().splitlines()
    if Path(settings_lines[0]).resolve() != zsh_source:
        raise ValueError('selected headers differ from the module build; rerun make with ZSH_SRC')
    if (ROOT / 'build/zcurl.so').stat().st_mtime_ns < settings.stat().st_mtime_ns:
        raise ValueError('module predates the selected build settings; rerun make')
    header = zsh_source / 'Src/version.h'
    match = re.search(r'^#define ZSH_VERSION "([^"]+)"', header.read_text(), re.M)
    if not match or not (zsh_source / 'config.h').is_file():
        raise ValueError('configured Zsh headers are required')
    output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='zcurl-package-', dir=output) as work:
        stage = Path(work) / 'stage'
        (stage / 'build').mkdir(parents=True)
        shutil.copy2(ROOT / 'build/zcurl.so', stage / 'build/zcurl.so')
        for name in ('zcurl.zsh', 'README.md', 'LICENSE', 'Makefile'):
            shutil.copy2(ROOT / name, stage / name)
        for name in ('docs', 'completions', 'examples', 'src', 'scripts', 'tests'):
            shutil.copytree(ROOT / name, stage / name,
                            ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        result = subprocess.run(['zsh', '-df', str(stage / 'scripts/check-runtime.zsh')],
                                capture_output=True, text=True, timeout=20)
        if result.returncode:
            raise ValueError(f'staged runtime check failed:\n{result.stdout}{result.stderr}')
        versions = re.search(r'^zcurl ([^;]+); built for Zsh ([^;]+); (.+)$', result.stdout, re.M)
        if not versions or versions[2] != match[1]:
            raise ValueError('loaded module does not match the selected Zsh headers')
        name = f'zcurl-{versions[1]}-{platform.system().lower()}-{platform.machine()}-zsh-{versions[2]}'
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', name):
            raise ValueError('unsupported package name')
        try:
            distribution = getattr(platform, 'freedesktop_os_release', lambda: {})()
        except OSError:
            distribution = {}
        manifest = {
            'schema': 1, 'zcurl_version': versions[1], 'zsh_version': versions[2],
            'runtime_libcurl': versions[3], 'system': platform.system(),
            'machine': platform.machine(), 'libc': list(platform.libc_ver()),
            'distribution': distribution,
            'module_sha256': digest(stage / 'build/zcurl.so'),
            'zsh_config_sha256': digest(zsh_source / 'config.h'),
            'build_settings_sha256': digest(settings),
            'build_options': dict(zip(('compiler', 'cppflags', 'cflags', 'curl_cflags',
                                       'ldflags', 'curl_libs'), settings_lines[1:7])),
            'compatibility': 'Build provenance only; matching version strings do not prove ABI compatibility.',
            'validation': 'Local no-network runtime check passed. Run it again on the target host.',
        }
        (stage / 'BUILD.json').write_text(json.dumps(manifest, indent=2) + '\n')
        archive = output / (name + '.tar.gz')
        temporary = Path(work) / 'bundle.tar.gz'
        with tarfile.open(temporary, 'w:gz') as bundle:
            bundle.add(stage, arcname=name)
        os.replace(temporary, archive)
        checksum = Path(work) / 'checksum'
        checksum.write_text(f'{digest(archive)}  {archive.name}\n')
        os.replace(checksum, archive.with_name(archive.name + '.sha256'))
        return archive


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zsh-source', type=Path, default=ROOT / '.deps/zsh-5.9.2')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/packages')
    args = parser.parse_args()
    try:
        print(package(args.zsh_source, args.output.resolve()))
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f'zcurl package: {error}\n')
