# Temporary helper inventory null-location fix

GUI 1.10.3 and Token Lab 0.1.3 guard every temporary-helper
`InstallLocation.TrimEnd()` comparison. Windows can return a development package
with a null `InstallLocation`; the former helper scan threw before registering
the temporary package or requesting a token. A null-location package is now
excluded from shared-helper cleanup and still blocks registration if it owns
the target identity. Packages outside the shared helper folder are never
removed by this change.

`tests/Test-TemporaryNullInstallLocation.ps1` covers both behaviors with mock
packages. The bundled executables pass their verification checks. A local
full request reached the Xbox service and confirmed helper shutdown, removal,
and app-data preservation. Xbox then returned `0x8015DA87` for the tested
edition; this separate service rejection remains unresolved. No token was
issued in that request.
