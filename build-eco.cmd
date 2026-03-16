@echo off
setlocal

set "REPO_DIR=%~dp0"
if "%REPO_DIR:~-1%"=="\" set "REPO_DIR=%REPO_DIR:~0,-1%"

set "FLUTTER_SDK=%~1"
if "%FLUTTER_SDK%"=="" (
  if exist "%REPO_DIR%\..\flutter\bin\flutter.bat" (
    set "FLUTTER_SDK=%REPO_DIR%\..\flutter"
  )
)

if not "%FLUTTER_SDK%"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO_DIR%\tools\eco_compile_windows.ps1" -FlutterSdkPath "%FLUTTER_SDK%" -InstallCodegen
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO_DIR%\tools\eco_compile_windows.ps1" -InstallCodegen
)

set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" (
  echo.
  echo [ECO-COMPILER] Build failed with exit code %EXITCODE%.
)
exit /b %EXITCODE%

