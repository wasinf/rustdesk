# ECO REMOTO - Windows compiler (one-command build pipeline)
# Run in PowerShell from the rustdesk repo root on Windows.
#
# What this script does:
# 1) (Optional) Ensure FRB codegen tool
# 2) Generate bridge files (Rust/Dart/C header)
# 3) Resolve Flutter dependencies (pub get)
# 4) Call eco_build_windows.ps1 (Rust + Flutter build)
# 5) Package full Release folder into a ZIP (includes required DLLs)

[CmdletBinding()]
param(
  [string]$FlutterSdkPath = "",
  [string]$RustToolchain = "1.75.0",
  [string]$FrbToolchain = "stable",
  [string]$FrbVersion = "1.80.1",
  [string]$BrandIconPath = "",
  [string]$OutputName = "eco-remote",
  [string]$ArtifactDir = ".\dist",
  [string]$InnoSetupCompiler = "",
  [switch]$InstallCodegen,
  [switch]$SkipCodegen,
  [switch]$SkipPubGet,
  [switch]$SkipPackage,
  [switch]$SkipInstaller,
  [switch]$RunInstaller,
  [switch]$CreateExeInstaller
)

$ErrorActionPreference = "Stop"

function Write-Step($message) {
  Write-Host "[ECO-COMPILER] $message" -ForegroundColor Cyan
}

function Assert-LastExitCode($commandDescription) {
  if ($LASTEXITCODE -ne 0) {
    throw "$commandDescription failed with exit code $LASTEXITCODE"
  }
}

function Require-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $name"
  }
}

function Prepend-PathIfMissing($value) {
  if ([string]::IsNullOrWhiteSpace($value)) { return }
  $parts = $env:Path -split ';'
  if (-not ($parts -contains $value)) {
    $env:Path = "$value;$env:Path"
  }
}

function Resolve-BrandIconPath($repoRoot, $explicitPath) {
  if (-not [string]::IsNullOrWhiteSpace($explicitPath)) {
    $resolved = Resolve-Path $explicitPath -ErrorAction SilentlyContinue
    if ($resolved) { return $resolved.Path }
    throw "Brand icon file not found: $explicitPath"
  }
  $candidates = @(
    (Join-Path $repoRoot "branding\icon.ico"),
    (Join-Path $repoRoot "res\icon.ico")
  )
  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) { return $candidate }
  }
  return $null
}

function Resolve-InnoSetupCompiler([string]$explicitPath) {
  if (-not [string]::IsNullOrWhiteSpace($explicitPath)) {
    if (Test-Path $explicitPath) { return (Resolve-Path $explicitPath).Path }
    throw "Inno Setup compiler not found at: $explicitPath"
  }
  $cmd = Get-Command iscc.exe -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  $candidates = @(
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
  )
  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) { return (Resolve-Path $candidate).Path }
  }
  return $null
}

function Apply-BrandIcon($repoRoot, $sourceIco) {
  if ([string]::IsNullOrWhiteSpace($sourceIco)) {
    Write-Host "[ECO-COMPILER] No brand icon found. Keeping current project icons." -ForegroundColor DarkYellow
    return
  }
  Write-Step "Applying brand icon from: $sourceIco"
  $targets = @(
    (Join-Path $repoRoot "res\icon.ico"),
    (Join-Path $repoRoot "res\tray-icon.ico"),
    (Join-Path $repoRoot "flutter\windows\runner\resources\app_icon.ico"),
    (Join-Path $repoRoot "flutter\assets\icon.ico")
  )
  foreach ($target in $targets) {
    $dir = Split-Path -Parent $target
    if (-not (Test-Path $dir)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Copy-Item $sourceIco $target -Force
  }

  # Keep Flutter in-app top-left logo aligned with brand as well.
  $iconPngCandidates = @(
    (Join-Path (Split-Path -Parent $sourceIco) "icon.png"),
    (Join-Path $repoRoot "res\icon.png"),
    (Join-Path $repoRoot "branding\icon.png")
  )
  $iconPng = $iconPngCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($iconPng) {
    Copy-Item $iconPng (Join-Path $repoRoot "flutter\assets\icon.png") -Force
  }

  $iconSvgCandidates = @(
    (Join-Path (Split-Path -Parent $sourceIco) "logo.svg"),
    (Join-Path $repoRoot "res\logo.svg"),
    (Join-Path $repoRoot "branding\logo.svg")
  )
  $iconSvg = $iconSvgCandidates | Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($iconSvg) {
    Copy-Item $iconSvg (Join-Path $repoRoot "flutter\assets\icon.svg") -Force
  }
}

function Add-ProtocolSupportFiles([string]$targetDir) {
  $launcherPath = Join-Path $targetDir "eco-protocol-launcher.cmd"
  $registerScriptPath = Join-Path $targetDir "eco_register_protocols.ps1"

  $launcherContent = @'
@echo off
setlocal EnableExtensions EnableDelayedExpansion
set "URI=%~1"
set "TMP=!URI:eco-remote://=!"
set "TMP=!TMP:eco-remoto://=!"
set "TMP=!TMP:ecoremoto://=!"
set "TMP=!TMP:rustdesk://=!"
for /f "tokens=1 delims=/?#" %%A in ("!TMP!") do set "ID=%%A"
set "ID=!ID: =!"
echo [%date% %time%] URI=%~1 ID=!ID!>>"%TEMP%\eco-protocol.log"

if defined ID (
  start "" "%~dp0eco-remoto.exe" --connect "!ID!"
) else (
  start "" "%~dp0eco-remoto.exe" "%~1"
)
'@
  Set-Content -Path $launcherPath -Value $launcherContent -Encoding ASCII

  $registerScriptContent = @'
param(
  [string]$InstallDir = $PSScriptRoot
)

$ErrorActionPreference = "Stop"

$launcher = Join-Path $InstallDir "eco-protocol-launcher.cmd"
if (!(Test-Path $launcher)) {
  throw "Launcher de protocolo nao encontrado: $launcher"
}

$command = "`"$launcher`" `"%1`""
$schemes = @("eco-remote", "eco-remoto", "ecoremoto", "rustdesk")

function Set-Protocol([Microsoft.Win32.RegistryKey]$hive, [string]$scheme, [string]$value) {
  $base = $hive.CreateSubKey("Software\Classes\$scheme")
  $base.SetValue("", "URL:ECO REMOTO Protocol", [Microsoft.Win32.RegistryValueKind]::String)
  $base.SetValue("URL Protocol", "", [Microsoft.Win32.RegistryValueKind]::String)
  $open = $hive.CreateSubKey("Software\Classes\$scheme\shell\open\command")
  $open.SetValue("", $value, [Microsoft.Win32.RegistryValueKind]::String)
}

foreach ($scheme in $schemes) {
  Remove-Item "Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\Shell\Associations\UrlAssociations\$scheme\UserChoice" -Recurse -Force -ErrorAction SilentlyContinue
}

foreach ($scheme in $schemes) {
  Set-Protocol ([Microsoft.Win32.Registry]::CurrentUser) $scheme $command
  try {
    Set-Protocol ([Microsoft.Win32.Registry]::LocalMachine) $scheme $command
  } catch {
    # LocalMachine may fail if installer context lacks permission; HKCU is sufficient fallback.
  }
}
'@
  Set-Content -Path $registerScriptPath -Value $registerScriptContent -Encoding UTF8
}

function New-EcoExeInstaller($releaseDir, $artifactPath, $outputName, $stamp, $repoRoot, $isccPath) {
  $stageRoot = Join-Path $artifactPath "$outputName-setup-stage-$stamp"
  $appStage = Join-Path $stageRoot "app"
  if (Test-Path $stageRoot) {
    Remove-Item $stageRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $appStage -Force | Out-Null
  Copy-Item (Join-Path $releaseDir "*") $appStage -Recurse -Force
  Add-ProtocolSupportFiles $appStage

  $setupIcon = Join-Path $repoRoot "branding\icon.ico"
  if (-not (Test-Path $setupIcon)) {
    $setupIcon = Join-Path $repoRoot "res\icon.ico"
  }
  if (-not (Test-Path $setupIcon)) {
    throw "Setup icon not found (branding\\icon.ico or res\\icon.ico)."
  }

  $outputBase = "$outputName-setup-win64-$stamp"
  $issPath = Join-Path $stageRoot "EcoRemotoSetup.iss"

  $iss = @'
#define MyAppName "ECO REMOTO"
#define MyAppVersion "1.4.6"
#define MyAppPublisher "ECO REMOTO"
#define MyAppExeName "eco-remoto.exe"

[Setup]
AppId={{9E41D0F1-7D13-45F7-9B8A-2E7A0E3C6D2F}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DefaultDirName={autopf64}\RustDesk
DisableDirPage=yes
DisableProgramGroupPage=yes
OutputDir=__OUTPUT_DIR__
OutputBaseFilename=__OUTPUT_BASE__
Compression=lzma
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
CloseApplications=yes
RestartApplications=no
SetupIconFile=__SETUP_ICON__

[Languages]
Name: "brazilianportuguese"; MessagesFile: "compiler:Languages\BrazilianPortuguese.isl"

[Files]
Source: "__APP_STAGE__\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[InstallDelete]
Type: files; Name: "{app}\RustDesk.exe"

[Run]
Filename: "{cmd}"; Parameters: "/C sc stop ""RustDesk"" >nul 2>nul & sc delete ""RustDesk"" >nul 2>nul & sc stop ""ECO REMOTO"" >nul 2>nul & sc delete ""ECO REMOTO"" >nul 2>nul & sc stop ""ECO-REMOTO"" >nul 2>nul & sc delete ""ECO-REMOTO"" >nul 2>nul"; Flags: runhidden waituntilterminated
Filename: "{cmd}"; Parameters: "/C ""{app}\eco-remoto.exe"" --uninstall-service"; Flags: runhidden waituntilterminated
Filename: "{cmd}"; Parameters: "/C ""{app}\eco-remoto.exe"" --install-service"; Flags: runhidden waituntilterminated
Filename: "{cmd}"; Parameters: "/C ""{app}\eco-remoto.exe"" --after-install"; Flags: runhidden waituntilterminated
Filename: "powershell.exe"; Parameters: "-NoProfile -ExecutionPolicy Bypass -File ""{app}\eco_register_protocols.ps1"" -InstallDir ""{app}"""; Flags: runhidden waituntilterminated
Filename: "{cmd}"; Parameters: "/C sc stop ""EcoRemoto"" >nul 2>nul & sc config ""EcoRemoto"" binPath= ""\""{app}\eco-remoto.exe\"" --service"" start= auto"; Flags: runhidden waituntilterminated
Filename: "{cmd}"; Parameters: "/C sc start ""EcoRemoto"""; Flags: runhidden waituntilterminated
Filename: "{app}\eco-remoto.exe"; Description: "Abrir ECO REMOTO"; Flags: nowait postinstall unchecked skipifsilent

[Icons]
Name: "{autodesktop}\ECO REMOTO"; Filename: "{app}\eco-remoto.exe"
Name: "{autoprograms}\ECO REMOTO"; Filename: "{app}\eco-remoto.exe"

[Code]
function ExecHidden(const CmdLine: string): Integer;
var
  ResultCode: Integer;
begin
  if Exec(ExpandConstant('{cmd}'), '/C ' + CmdLine, '', SW_HIDE, ewWaitUntilTerminated, ResultCode) then
    Result := ResultCode
  else
    Result := -1;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Log('Stopping EcoRemoto/RustDesk processes before file copy...');
  ExecHidden('sc stop "EcoRemoto" >nul 2>nul');
  ExecHidden('sc stop "RustDesk" >nul 2>nul');
  ExecHidden('sc stop "ECO REMOTO" >nul 2>nul');
  ExecHidden('sc stop "ECO-REMOTO" >nul 2>nul');
  ExecHidden('taskkill /F /IM eco-remoto.exe >nul 2>nul');
  ExecHidden('taskkill /F /IM rustdesk.exe >nul 2>nul');
  Sleep(800);
  Result := '';
end;
'@

  $iss = $iss.Replace("__OUTPUT_DIR__", $artifactPath.Replace("\", "\\"))
  $iss = $iss.Replace("__OUTPUT_BASE__", $outputBase)
  $iss = $iss.Replace("__SETUP_ICON__", $setupIcon.Replace("\", "\\"))
  $iss = $iss.Replace("__APP_STAGE__", $appStage.Replace("\", "\\"))

  Set-Content -Path $issPath -Value $iss -Encoding UTF8

  & $isccPath $issPath | Out-Host
  Assert-LastExitCode "ISCC compile installer"

  $exeInstaller = Join-Path $artifactPath "$outputBase.exe"
  if (-not (Test-Path $exeInstaller)) {
    throw "Inno Setup did not generate expected installer: $exeInstaller"
  }

  return @{
    ExeInstaller = $exeInstaller
    IssFile = $issPath
    StageRoot = $stageRoot
  }
}

function New-EcoInstallerPackage($releaseDir, $artifactPath, $outputName, $stamp) {
  $installerRoot = Join-Path $artifactPath "$outputName-installer-win64-$stamp"
  $appDir = Join-Path $installerRoot "app"
  if (Test-Path $installerRoot) {
    Remove-Item $installerRoot -Recurse -Force
  }
  New-Item -ItemType Directory -Path $appDir -Force | Out-Null

  Copy-Item (Join-Path $releaseDir "*") $appDir -Recurse -Force
  Add-ProtocolSupportFiles $appDir

  $installPs1 = @'
#requires -version 5.1
param()

$ErrorActionPreference = "Stop"

function Ensure-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($id)
  $isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process powershell -Verb RunAs -ArgumentList $args
    exit 0
  }
}

function Stop-RustDeskProcesses {
  Stop-Service "RustDesk" -Force -ErrorAction SilentlyContinue
  Stop-Service "ECO REMOTO" -Force -ErrorAction SilentlyContinue
  Stop-Service "ECO-REMOTO" -Force -ErrorAction SilentlyContinue
  Stop-Service "EcoRemoto" -Force -ErrorAction SilentlyContinue
  Get-Process -Name "RustDesk","rustdesk","eco-remoto","eco-remote" -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
}

function Resolve-AppExe([string]$installDir) {
  $candidates = @(
    (Join-Path $installDir "eco-remoto.exe"),
    (Join-Path $installDir "eco-remote.exe")
  )
  foreach ($candidate in $candidates) {
    if (Test-Path $candidate) { return $candidate }
  }
  throw "Executavel principal nao encontrado na pasta de instalacao: $installDir"
}

function Register-ProtocolAliases([string]$installDir) {
  $registerScript = Join-Path $installDir "eco_register_protocols.ps1"
  if (Test-Path $registerScript) {
    powershell -NoProfile -ExecutionPolicy Bypass -File $registerScript -InstallDir $installDir | Out-Null
    return
  }
  Write-Host "[ECO-INSTALLER] Aviso: script de registro de protocolo nao encontrado: $registerScript" -ForegroundColor Yellow
}

Ensure-Admin

$payloadDir = Join-Path $PSScriptRoot "app"
if (-not (Test-Path $payloadDir)) {
  throw "Pasta de payload nao encontrada: $payloadDir"
}

$installDir = Join-Path $env:ProgramFiles "RustDesk"
Write-Host "[ECO-INSTALLER] Instalando em: $installDir" -ForegroundColor Cyan

Stop-RustDeskProcesses

New-Item -ItemType Directory -Path $installDir -Force | Out-Null
Copy-Item (Join-Path $payloadDir "*") $installDir -Recurse -Force

$exe = Resolve-AppExe $installDir

# Reinstala o servico para garantir que ele use o build novo
try { sc.exe stop "RustDesk" | Out-Null } catch {}
try { sc.exe delete "RustDesk" | Out-Null } catch {}
try { sc.exe stop "ECO REMOTO" | Out-Null } catch {}
try { sc.exe delete "ECO REMOTO" | Out-Null } catch {}
try { sc.exe stop "ECO-REMOTO" | Out-Null } catch {}
try { sc.exe delete "ECO-REMOTO" | Out-Null } catch {}
try { & $exe --uninstall-service | Out-Null } catch {}
Start-Sleep -Milliseconds 500
& $exe --install-service | Out-Null
Start-Sleep -Milliseconds 500

# Ensure the installed service points to the latest executable name.
sc.exe config "EcoRemoto" binPath= "`"$exe`" --service" | Out-Null
sc.exe config "EcoRemoto" start= auto | Out-Null

# Keep only branded executable to avoid duplicate tray ownership checks by path.
$legacyExe = Join-Path $installDir "RustDesk.exe"
if (Test-Path $legacyExe) {
  Remove-Item $legacyExe -Force -ErrorAction SilentlyContinue
}

Start-Service "EcoRemoto" -ErrorAction SilentlyContinue
& $exe --after-install | Out-Null
Register-ProtocolAliases -installDir $installDir

# Aguarda o servico estabilizar para evitar corrida de inicializacao e icone duplicado no tray.
$serviceReady = $false
for ($i = 0; $i -lt 20; $i++) {
  $svc = Get-Service "EcoRemoto" -ErrorAction SilentlyContinue
  if ($svc -and $svc.Status -eq "Running") {
    $serviceReady = $true
    break
  }
  Start-Sleep -Milliseconds 500
}
if (-not $serviceReady) {
  Write-Host "[ECO-INSTALLER] Aviso: servico EcoRemoto ainda nao esta Running, iniciando UI mesmo assim." -ForegroundColor Yellow
}

# Sobe somente a UI; o tray deve ser gerenciado pelo fluxo do servico para evitar duplicidade.
Start-Process -FilePath $exe -WorkingDirectory $installDir | Out-Null

Write-Host "[ECO-INSTALLER] Instalacao concluida com sucesso." -ForegroundColor Green
Write-Host "[ECO-INSTALLER] Aplicativo iniciado." -ForegroundColor Green
Pause
'@
  Set-Content -Path (Join-Path $installerRoot "Install_ECO_Remoto.ps1") -Value $installPs1 -Encoding UTF8

  $installCmd = @'
@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install_ECO_Remoto.ps1"
set "EXITCODE=%ERRORLEVEL%"
if not "%EXITCODE%"=="0" (
  echo.
  echo [ECO-INSTALLER] Falha na instalacao. Codigo: %EXITCODE%
  pause
)
exit /b %EXITCODE%
'@
  Set-Content -Path (Join-Path $installerRoot "Install_ECO_Remoto.cmd") -Value $installCmd -Encoding ASCII

  $readme = @'
ECO REMOTO - Instalador Windows

Como usar:
1) Extraia este pacote em qualquer pasta.
2) Execute "Install_ECO_Remoto.cmd" (duplo clique).
3) Aceite a elevacao de privilegios (UAC).

O instalador:
- Remove servicos legados (RustDesk e ECO REMOTO)
- Copia os arquivos novos para C:\Program Files\RustDesk
- Reinstala e inicia o servico EcoRemoto
- Abre o aplicativo
'@
  Set-Content -Path (Join-Path $installerRoot "README-INSTALADOR.txt") -Value $readme -Encoding UTF8

  $installerZip = Join-Path $artifactPath "$outputName-installer-win64-$stamp.zip"
  if (Test-Path $installerZip) {
    Remove-Item $installerZip -Force
  }
  Compress-Archive -Path (Join-Path $installerRoot "*") -DestinationPath $installerZip -Force
  Assert-LastExitCode "Compress-Archive installer package"

  return @{
    InstallerRoot = $installerRoot
    InstallerZip = $installerZip
  }
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $repoRoot

if (-not [string]::IsNullOrWhiteSpace($FlutterSdkPath)) {
  $flutterBin = Join-Path $FlutterSdkPath "bin"
  if (-not (Test-Path $flutterBin)) {
    throw "Flutter SDK path is invalid: '$FlutterSdkPath' (missing '$flutterBin')."
  }
  Prepend-PathIfMissing $flutterBin
  Write-Step "Using Flutter SDK: $FlutterSdkPath"
}

Require-Command git
Require-Command rustup
Require-Command cargo
Require-Command flutter

Write-Step "Repo root: $repoRoot"

$brandIcon = Resolve-BrandIconPath $repoRoot $BrandIconPath
Apply-BrandIcon $repoRoot $brandIcon

Write-Step "Ensuring Rust toolchain $RustToolchain..."
& rustup toolchain install $RustToolchain | Out-Host
Assert-LastExitCode "rustup toolchain install $RustToolchain"
& rustup default $RustToolchain | Out-Host
Assert-LastExitCode "rustup default $RustToolchain"

Write-Step "Version check..."
& rustc --version | Out-Host
Assert-LastExitCode "rustc --version"
& cargo --version | Out-Host
Assert-LastExitCode "cargo --version"
& flutter --version | Out-Host
Assert-LastExitCode "flutter --version"

if (-not $SkipCodegen) {
  $frbExe = Join-Path $env:USERPROFILE ".cargo\bin\flutter_rust_bridge_codegen.exe"
  if ($InstallCodegen -or -not (Test-Path $frbExe)) {
    Write-Step "Installing flutter_rust_bridge_codegen v$FrbVersion with +$FrbToolchain..."
    & rustup toolchain install $FrbToolchain | Out-Host
    Assert-LastExitCode "rustup toolchain install $FrbToolchain"
    & cargo +$FrbToolchain install flutter_rust_bridge_codegen --version $FrbVersion --features uuid --locked --force | Out-Host
    Assert-LastExitCode "cargo +$FrbToolchain install flutter_rust_bridge_codegen"
  }

  if (-not (Test-Path $frbExe)) {
    throw "flutter_rust_bridge_codegen not found at '$frbExe'."
  }

  Write-Step "Generating FRB bridge files..."
  & $frbExe `
    --rust-input .\src\flutter_ffi.rs `
    --rust-output .\src\bridge_generated.rs `
    --dart-output .\flutter\lib\generated_bridge.dart `
    --c-output .\flutter\windows\runner\bridge_generated.h | Out-Host
  Assert-LastExitCode "flutter_rust_bridge_codegen"

  foreach ($file in @(
    ".\src\bridge_generated.rs",
    ".\flutter\lib\generated_bridge.dart",
    ".\flutter\windows\runner\bridge_generated.h"
  )) {
    if (-not (Test-Path $file)) {
      throw "Expected generated file not found: $file"
    }
  }
}

if (-not $SkipPubGet) {
  Write-Step "Running flutter pub get..."
  Push-Location ".\flutter"
  & flutter pub get | Out-Host
  Assert-LastExitCode "flutter pub get"
  Pop-Location
}

Write-Step "Running eco_build_windows.ps1..."
& (Join-Path $PSScriptRoot "eco_build_windows.ps1")
Assert-LastExitCode "eco_build_windows.ps1"

$releaseDir = Join-Path $repoRoot "flutter\build\windows\x64\runner\Release"
if (-not (Test-Path $releaseDir)) {
  throw "Release folder not found: $releaseDir"
}

if (-not $SkipPackage) {
  $artifactPath = Join-Path $repoRoot $ArtifactDir
  if (-not (Test-Path $artifactPath)) {
    New-Item -ItemType Directory -Path $artifactPath | Out-Null
  }
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $zipPath = Join-Path $artifactPath "$OutputName-win64-$stamp.zip"

  Write-Step "Packaging full Release folder (exe + dlls) to ZIP..."
  Compress-Archive -Path (Join-Path $releaseDir "*") -DestinationPath $zipPath -Force
  Assert-LastExitCode "Compress-Archive Release"

  $installerResult = $null
  if (-not $SkipInstaller) {
    Write-Step "Creating customer installer package..."
    $installerResult = New-EcoInstallerPackage $releaseDir $artifactPath $OutputName $stamp
  }

  $exeInstallerResult = $null
  if ($CreateExeInstaller) {
    $isccPath = Resolve-InnoSetupCompiler $InnoSetupCompiler
    if ([string]::IsNullOrWhiteSpace($isccPath)) {
      Write-Host "[ECO-COMPILER] Inno Setup (ISCC.exe) not found. Skipping .exe installer generation." -ForegroundColor Yellow
      Write-Host "[ECO-COMPILER] Install Inno Setup 6 and rerun with -CreateExeInstaller." -ForegroundColor Yellow
    } else {
      Write-Step "Creating .exe installer with Inno Setup..."
      $exeInstallerResult = New-EcoExeInstaller $releaseDir $artifactPath $OutputName $stamp $repoRoot $isccPath
    }
  }

  Write-Host "[ECO-COMPILER] Build ready:" -ForegroundColor Green
  Write-Host "  EXE: $(Join-Path $releaseDir 'eco-remoto.exe')" -ForegroundColor Green
  Write-Host "  ZIP: $zipPath" -ForegroundColor Green
  if ($installerResult -ne $null) {
    Write-Host "  INSTALLER ZIP: $($installerResult.InstallerZip)" -ForegroundColor Green
    Write-Host "  INSTALLER CMD: $(Join-Path $($installerResult.InstallerRoot) 'Install_ECO_Remoto.cmd')" -ForegroundColor Green
    if ($RunInstaller) {
      Write-Step "Launching installer..."
      & (Join-Path $installerResult.InstallerRoot "Install_ECO_Remoto.cmd")
      Assert-LastExitCode "Install_ECO_Remoto.cmd"
    }
  }
  if ($exeInstallerResult -ne $null) {
    Write-Host "  INSTALLER EXE: $($exeInstallerResult.ExeInstaller)" -ForegroundColor Green
  }
} else {
  Write-Host "[ECO-COMPILER] Build ready at: $releaseDir" -ForegroundColor Green
}
