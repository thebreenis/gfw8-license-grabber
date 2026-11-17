# Build inputs and release integrity

GUI 1.10.2 / CLI 1.6.2 introduce an explicit shipping allowlist and local release provenance. These changes address supply-chain and accidental-packaging risks. They do not establish why an antivirus product classified an earlier release, and do not guarantee a different malware verdict.

## Build prerequisites

Use Windows x64, Python 3.10+, .NET Framework 4.8 and a locally installed Microsoft Roslyn compiler. Visual Studio Build Tools with MSBuild supplies Roslyn; the builder discovers it with vswhere. Alternatively set `GFW8_CSC` to a local Microsoft-signed Roslyn `csc.exe`. The older compiler shipped inside .NET Framework is no longer used for release builds because it does not support deterministic compilation. Native rebuilds additionally require the Visual C++ tools and Windows SDK.

The builder downloads no compiler, package, or dependency. It validates the compiler signature, pins dependency hashes and validates Microsoft library signatures before compiling. Signature validation may use Windows trust services and can fail if the trust chain cannot be validated; there is no skip-verification switch.

## Shipping inputs

`tools/package-inputs.json` lists exact backend, UI and source-archive inputs. Additional files in the checkout or staging directories are never discovered as runtime inputs. Missing or linked allowlisted inputs fail the build. New runtime files and new source files require a reviewed manifest change. Backend EXE/DLL/certificate inputs must also appear in `tools/dependencies.json`; an unpinned addition fails validation.

`tools/dependencies.json` records hashes, origins and supporting references. The Microsoft legacy DLLs have verified publisher signatures, but the project does not claim a separately recovered public download URL for each historical file. The native helper's source hash is recorded. The archive reader and its matching source were independently compared with the official 7-Zip 26.06 release during the local audit. Valid signatures and hash pins are integrity evidence, not guarantees of supported software or freedom from vulnerabilities.

## Determinism and provenance

Roslyn runs with deterministic compilation, fixed language version, explicit Framework references, no implicit response-file configuration, and normalized source paths. ZIP members have fixed order, timestamps and metadata. The native rebuild uses a basename source argument and reproducible-build compiler/linker switches. Nothing edits PE headers after compilation.

`dist/BUILD-PROVENANCE.json` records every allowlisted source hash, pinned dependency, compiler version/hash, Framework reference hashes, normalized compile arguments, Python/zlib versions, payload hashes and executable hashes. Native rebuilds also record the selected MSVC/Windows SDK versions, compiler/linker versions/hashes and selected helper hash. Reproducibility is conditional on identical recorded source and toolchain/reference inputs; a compiler, SDK, dependency or compression-library change may alter output.

Run `python tests/Test-Packaging.py` and the documented offline application checks after building. A release verification should build in two different checkout locations and compare the executable and payload hashes. Tests never acquire a receipt or token.

## Freeze a local release

After the final build and checks, run:

```powershell
python tools/freeze_release.py --destination dist/releases
```

This creates a new `GUI<version>-CLI<version>` folder with the verified EXEs, an allowlisted source ZIP, portable file details, provenance and checksums. It rejects source or EXE changes since the build and refuses to overwrite an existing version folder. The script never publishes to GitHub. Keep the frozen folder as the canonical binary set; change the version before producing a different release.

Signing is separate and not performed by these scripts. If signatures are added, preserve the unsigned build provenance and record signed-file hashes as a separate final release step. Existing private user data and app runtime behavior are outside this build-only change.
