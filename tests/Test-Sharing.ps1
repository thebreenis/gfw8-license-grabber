param([string]$Relay='http://127.0.0.1:8799')
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$build=Join-Path $root 'build';$null=New-Item -ItemType Directory -Path $build -Force
$csc=Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$source=Join-Path $root 'src\sharing'
$common=@((Join-Path $source 'ShareCrypto.cs'),(Join-Path $source 'ShareClient.cs'))
$refs=@('/reference:System.Web.Extensions.dll','/reference:System.Security.dll')
$agent=Join-Path $build 'Agent-tests.exe';$harness=Join-Path $build 'SharingTests.exe'
& $csc /nologo /target:winexe /platform:x64 /define:SHARING_TESTS "/out:$agent" @refs /reference:System.Net.Http.dll /reference:System.Windows.Forms.dll /reference:System.Drawing.dll /reference:System.IO.Compression.dll @common (Join-Path $source 'Agent.cs') (Join-Path $source 'AgentOperations.cs') (Join-Path $source 'SharingActivity.cs') (Join-Path $source 'AgentBundle.cs')
if($LASTEXITCODE){throw 'Fixture agent compilation failed.'}
& $csc /nologo /target:exe /platform:x64 "/out:$harness" @refs @common (Join-Path $PSScriptRoot 'Test-Sharing.cs')
if($LASTEXITCODE){throw 'Sharing test compilation failed.'}
& $harness $agent (Join-Path $build ('sharing-suite-'+[guid]::NewGuid().ToString('N'))) $Relay
if($LASTEXITCODE){throw 'Sharing integration tests failed.'}
