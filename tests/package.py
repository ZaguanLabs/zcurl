"""Exercise the extracted bundle without a compiler, make or Python in PATH."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from package import digest, package
from integration import fixture, run


if __name__ == '__main__':
    source = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / '.deps/zsh-5.9.2'
    with tempfile.TemporaryDirectory(prefix='zcurl-package-test-ø-') as directory:
        work = Path(directory)
        archive = package(source, work)
        assert archive.with_name(archive.name + '.sha256').read_text().split()[0] == digest(archive)
        with tarfile.open(archive) as bundle:
            # This is our own freshly generated archive. Older Python builds
            # do not expose extraction filters.
            options = {'filter': 'data'} if hasattr(tarfile, 'data_filter') else {}
            bundle.extractall(work / 'relocated package', **options)
        project, = (work / 'relocated package').iterdir()
        manifest = json.loads((project / 'BUILD.json').read_text())
        assert (project / 'LICENSE').read_bytes() == (ROOT / 'LICENSE').read_bytes()
        assert (project / 'src/polling.c').read_bytes() == (ROOT / 'src/polling.c').read_bytes()
        assert digest(project / 'build/zcurl.so') == manifest['module_sha256']
        minimal = work / 'bin'
        minimal.mkdir()
        (minimal / 'zsh').symlink_to(shutil.which('zsh'))
        child = subprocess.run([str(minimal / 'zsh'), '-df', str(project / 'scripts/check-runtime.zsh')],
                               env=dict(os.environ, PATH=str(minimal)), cwd='/',
                               capture_output=True, text=True, timeout=20)
        assert child.returncode == 0, (child.stdout, child.stderr)
        assert 'PASS: module load' in child.stdout
        with fixture(project / 'build') as (env, plain, tls, temp):
            print(run(env, '''
                source "$ZCURL_TEST_ROOT/zcurl.zsh"
                zcurl -c "$ZCURL_TEST_CA" "$ZCURL_TEST_HTTPS/bytes" || exit 1
                [[ $zcurl_http_status == 200 && $zcurl_bytes == 258 ]] || exit 2
                zcurl ws open packaged -c "$ZCURL_TEST_CA" -- "${ZCURL_TEST_HTTPS/https:/wss:}/ws" || exit 3
                zcurl ws send packaged --data verified || exit 4
                repeat 100; do
                    zcurl poll --timeout 100 || exit 5
                    [[ $zcurl_event == data ]] && break
                done
                [[ $zcurl_channel == ws && $zcurl_body == verified ]] || exit 6
                zcurl --reset
                zmodload -u zcurl
                print 'PASS: relocated bundle, checksum/provenance, no-build-tools load check, HTTPS and WSS'
            '''))
            assert not plain.ws_errors and not tls.ws_errors
