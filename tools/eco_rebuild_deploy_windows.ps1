# ECO REMOTO - Rebuild + Deploy local + Service fix (Windows)
# Run in PowerShell as Administrator.

[CmdletBinding()]
param(
  [string]$FlutterSdkPath = "D:\flutter",
  [switch]$InstallCodegen
)

$ErrorActionPreference = "Stop"

function Assert-LastExitCode([string]$desc) {
  if ($LASTEXITCODE -ne 0) {
    throw "$desc failed with exit code $LASTEXITCODE"
  }
}

function Ensure-Admin {
  $id = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($id)
  if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Run this script in PowerShell as Administrator."
  }
}

Ensure-Admin

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $repoRoot

$compileScript = Join-Path $PSScriptRoot "eco_compile_windows.ps1"
if (!(Test-Path $compileScript)) {
  throw "Script not found: $compileScript"
}

Write-Host "[ECO] Build step..." -ForegroundColor Cyan
$args = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", $compileScript,
  "-FlutterSdkPath", $FlutterSdkPath,
  "-SkipInstaller"
)
if ($InstallCodegen) {
  $args += "-InstallCodegen"
}
& powershell @args
Assert-LastExitCode "eco_compile_windows.ps1"

$src = Join-Path $repoRoot "flutter\build\windows\x64\runner\Release"
$dst = Join-Path $env:ProgramFiles "RustDesk"
$exe = Join-Path $dst "eco-remoto.exe"

if (!(Test-Path $src)) { throw "Release folder not found: $src" }
New-Item -ItemType Directory -Path $dst -Force | Out-Null

Write-Host "[ECO] Stopping old processes/services..." -ForegroundColor Cyan
Get-Process -Name "eco-remoto","eco-remote","rustdesk","RustDesk" -ErrorAction SilentlyContinue |
  Stop-Process -Force -ErrorAction SilentlyContinue

foreach($s in @("RustDesk","ECO REMOTO","ECO-REMOTO","EcoRemoto")) {
  Stop-Service $s -Force -ErrorAction SilentlyContinue
  sc.exe delete $s 2>$null | Out-Null
}

Start-Sleep -Seconds 1

Write-Host "[ECO] Copying build output..." -ForegroundColor Cyan
Copy-Item (Join-Path $src "*") $dst -Recurse -Force

if (!(Test-Path $exe) -and (Test-Path (Join-Path $dst "rustdesk.exe"))) {
  Rename-Item (Join-Path $dst "rustdesk.exe") "eco-remoto.exe" -Force
}
if (!(Test-Path $exe)) { throw "Executable not found after deploy: $exe" }

# Keep only branded executable to avoid confusion.
Remove-Item (Join-Path $dst "RustDesk.exe") -Force -ErrorAction SilentlyContinue

Write-Host "[ECO] Creating service EcoRemoto..." -ForegroundColor Cyan
New-Service `
  -Name "EcoRemoto" `
  -BinaryPathName "`"$exe`" --service" `
  -DisplayName "EcoRemoto Service" `
  -StartupType Automatic

Start-Service "EcoRemoto"

# Start tray first, then open main UI.
Start-Process -FilePath $exe -ArgumentList "--tray" -WorkingDirectory $dst | Out-Null
Start-Sleep -Seconds 2
Start-Process -FilePath $exe -WorkingDirectory $dst | Out-Null

Write-Host "[ECO] Validation:" -ForegroundColor Cyan
Get-CimInstance Win32_Service |
  Where-Object { $_.Name -in @("EcoRemoto","RustDesk","ECO REMOTO","ECO-REMOTO") } |
  Select-Object Name,State,PathName

Get-CimInstance Win32_Process |
  Where-Object { $_.Name -match "eco-remoto|rustdesk|RustDesk" } |
  Select-Object Name,ProcessId,CommandLine

Write-Host "[ECO] Done." -ForegroundColor Green
