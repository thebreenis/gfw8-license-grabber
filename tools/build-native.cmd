@echo off
setlocal
set "REPOROOT=%~dp0.."
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
 echo Install Visual Studio C++ Build Tools and the Windows SDK first.
 exit /b 1
)
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSROOT=%%i"
if not defined VSROOT exit /b 1
call "%VSROOT%\VC\Auxiliary\Build\vcvars32.bat" >nul
if errorlevel 1 exit /b 1
if not exist "%REPOROOT%\build\native" mkdir "%REPOROOT%\build\native"
pushd "%REPOROOT%\build\native"
cl /nologo /std:c++20 /EHsc /MT /O2 "%REPOROOT%\src\native\PackagedPayloadAsync.cpp" /Fe:Probe.exe /link /APPCONTAINER /SUBSYSTEM:WINDOWS /ENTRY:wmainCRTStartup windowsapp.lib ole32.lib oleaut32.lib
set "BUILDRESULT=%ERRORLEVEL%"
popd
exit /b %BUILDRESULT%
