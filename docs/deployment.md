# Build and deploy a native bundle

Build on a machine representative of the target's OS, CPU architecture, Zsh
build and shared libraries. A target host does not need a compiler or `make`.
It needs Zsh and the compatible runtime libraries used by the module, including
libcurl >=8.16.0 with HTTP/HTTPS/WS/WSS enabled.

```zsh
make ZSH_SRC=/path/to/matching/configured/zsh
make test ZSH_SRC=/path/to/matching/configured/zsh
make test-package ZSH_SRC=/path/to/matching/configured/zsh
make package ZSH_SRC=/path/to/matching/configured/zsh
```

Use the same `ZSH_SRC` for every make invocation when using custom headers.
The default remains `.deps/zsh-5.9.2`. Changing the source-tree path or compiler/
linker settings invalidates existing module builds even if the new headers
have older timestamps. Preparation of other Zsh releases is manual; the
pinned preparation script still targets 5.9.2.

Packaging additionally requires Python 3. The archive and SHA-256 sidecar are
written under `build/packages/`. The archive contains the native module,
loader, completions, examples, documentation, a runtime check and `BUILD.json`.
The matching project source, tests, build scripts and license are included;
Zsh headers and toolchains must be supplied separately when rebuilding.
The manifest records module/configuration digests and the local Zsh, libcurl,
OS, architecture and libc details. Runtime shared libraries are not bundled.
Packaging checks the staged module locally; it does not run the full network
suite automatically. `test-package` checks a relocated extraction, a PATH
containing only Zsh, and local verified HTTPS/WSS transfers.

On the target, verify the sidecar and extract the archive into an application
directory. Then run the check in a fresh shell (replace BUILD with the actual
archive name):

```zsh
sha256sum -c BUILD.tar.gz.sha256
tar -xzf BUILD.tar.gz
zsh -df /path/to/BUILD/scripts/check-runtime.zsh
```

The check performs load/unload/reload, parameter access, session lifecycle and
an empty shared poll. It uses no network and needs no build tools or Python.
After it passes, load the module from the application:

```zsh
source /path/to/BUILD/zcurl.zsh
```

Keep different builds in separate directories. Switch the application's loader
path when deploying a new build, and restart the owning shell or explicitly
unload/reload after releasing its handles. Replacing the file does not replace
code already loaded in a shell.

## What compatibility checks establish

The module rejects a different Zsh version and a runtime libcurl below the
required floor or without the four required protocols. The dynamic loader
also checks shared-library availability and symbol resolution.

These checks and the manifest do not prove Zsh ABI compatibility. Distribution
patches, configuration choices, libc and architecture matter even when version
strings match. A successful no-network check does not establish TLS trust,
proxy routing or application behavior on the target. Validate those using the
application's smoke tests before depending on a new host/build combination.
Only the environment listed in `validation.md` has been validated here.
