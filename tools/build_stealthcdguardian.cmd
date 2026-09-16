@echo off
setlocal enabledelayedexpansion
set "ROOT=%~dp0.."
set "OUT=%ROOT%\build"
if not exist "%OUT%" mkdir "%OUT%"

set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "%VSWHERE%" (
  echo ERROR: vswhere.exe not found
  exit /b 1
)
for /f "usebackq tokens=*" %%I in (`"%VSWHERE%" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSROOT=%%I"
if not defined VSROOT (
  echo ERROR: Visual Studio C++ x86 toolchain not found
  exit /b 1
)
call "%VSROOT%\VC\Auxiliary\Build\vcvars32.bat" >nul
if errorlevel 1 exit /b 1

set "SRC=%ROOT%\src\StealthCDGuardian\WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.c"
set "OBJ=%OUT%\WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.obj"
set "DLL=%OUT%\WoWStealthCDGuardian_5875_v2_HARD5S_WATCHDOG.dll"

echo [BUILD] cl x86 deterministic object
cl /nologo /c /O2 /GS- /GR- /EHsc- /Zl /Brepro /Fo"%OBJ%" "%SRC%"
if errorlevel 1 exit /b 1

echo [BUILD] link x86 DLL
link /nologo /DLL /MACHINE:X86 /NODEFAULTLIB /ENTRY:DllMain@12 /Brepro /OUT:"%DLL%" "%OBJ%"
if errorlevel 1 exit /b 1

dumpbin /headers "%DLL%" | findstr /C:"14C machine (x86)" >nul
if errorlevel 1 (
  echo ERROR: output is not PE32 x86
  exit /b 1
)
certutil -hashfile "%DLL%" SHA256
exit /b 0
