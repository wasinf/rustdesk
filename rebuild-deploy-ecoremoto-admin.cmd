@echo off
setlocal

net session >nul 2>&1
if not "%errorlevel%"=="0" (
  echo [ECO] Solicitando permissao de Administrador...
  powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

set "REPO_DIR=%~dp0"
if "%REPO_DIR:~-1%"=="\" set "REPO_DIR=%REPO_DIR:~0,-1%"

set "FLUTTER_SDK=%~1"
if "%FLUTTER_SDK%"=="" (
  if exist "D:\flutter\bin\flutter.bat" (
    set "FLUTTER_SDK=D:\flutter"
  )
)
if "%FLUTTER_SDK%"=="" (
  if exist "%REPO_DIR%\..\flutter\bin\flutter.bat" (
    set "FLUTTER_SDK=%REPO_DIR%\..\flutter"
  )
)

echo [ECO] Repo: %REPO_DIR%
echo [ECO] Flutter SDK: %FLUTTER_SDK%

if "%FLUTTER_SDK%"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO_DIR%\tools\eco_rebuild_deploy_windows.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%REPO_DIR%\tools\eco_rebuild_deploy_windows.ps1" -FlutterSdkPath "%FLUTTER_SDK%"
)

set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" (
  echo.
  echo [ECO] Falha no processo. Codigo: %EXITCODE%
  pause
)
exit /b %EXITCODE%

