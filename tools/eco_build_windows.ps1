# ECO REMOTO - Windows build helper
# Run in PowerShell from the rustdesk repo root on Windows.

$ErrorActionPreference = "Stop"

function Require-Command($name) {
  if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
    throw "Required command not found: $name"
  }
}

function Assert-LastExitCode($commandDescription) {
  if ($LASTEXITCODE -ne 0) {
    throw "$commandDescription failed with exit code $LASTEXITCODE"
  }
}

function Test-LibClangBin($path) {
  if ([string]::IsNullOrWhiteSpace($path)) { return $false }
  return (Test-Path (Join-Path $path "libclang.dll")) -or (Test-Path (Join-Path $path "clang.dll"))
}

function Get-ClangMajorVersion($binPath) {
  $clangExe = Join-Path $binPath "clang.exe"
  if (-not (Test-Path $clangExe)) { return $null }
  try {
    $line = & $clangExe --version 2>$null | Select-Object -First 1
    if ($line -match "clang version\s+([0-9]+)\.") {
      return [int]$matches[1]
    }
  } catch {}
  return $null
}

function Resolve-LibClangPath {
  $envLibClangPath = $env:LIBCLANG_PATH
  if (-not [string]::IsNullOrWhiteSpace($envLibClangPath) -and -not (Test-LibClangBin $envLibClangPath)) {
    Write-Host "[ECO] Ignoring invalid Env:LIBCLANG_PATH='$env:LIBCLANG_PATH'" -ForegroundColor DarkYellow
    Remove-Item Env:LIBCLANG_PATH -ErrorAction SilentlyContinue
    $envLibClangPath = $null
  }

  $candidates = @()
  if (Test-LibClangBin $envLibClangPath) {
    $candidates += $envLibClangPath
  }
  $candidates += @(
    "$env:ProgramFiles\Microsoft Visual Studio\2022\BuildTools\VC\Tools\Llvm\x64\bin",
    "$env:ProgramFiles\Microsoft Visual Studio\2022\Community\VC\Tools\Llvm\x64\bin",
    "$env:ProgramFiles\Microsoft Visual Studio\2022\Professional\VC\Tools\Llvm\x64\bin",
    "$env:ProgramFiles\Microsoft Visual Studio\2022\Enterprise\VC\Tools\Llvm\x64\bin",
    "$env:ProgramFiles\LLVM\bin"
  )

  $valid = @()
  foreach ($candidate in $candidates) {
    if (Test-LibClangBin $candidate -and -not ($valid -contains $candidate)) {
      $valid += $candidate
    }
  }

  $whereResults = @()
  try { $whereResults += (& where.exe libclang.dll 2>$null) } catch {}
  try { $whereResults += (& where.exe clang.dll 2>$null) } catch {}
  foreach ($path in $whereResults) {
    $bin = Split-Path -Parent $path
    if (Test-LibClangBin $bin -and -not ($valid -contains $bin)) {
      $valid += $bin
    }
  }

  if ($valid.Count -eq 0) {
    throw "libclang.dll/clang.dll not found. Install LLVM (e.g. 'winget install LLVM.LLVM') and rerun."
  }

  $preferred = @()
  foreach ($candidate in $valid) {
    $major = Get-ClangMajorVersion $candidate
    if ($null -ne $major -and $major -ge 14 -and $major -le 18) {
      $preferred += $candidate
    }
  }

  if ($preferred.Count -gt 0) {
    if (Test-LibClangBin $envLibClangPath -and -not ($preferred -contains $envLibClangPath)) {
      $envMajor = Get-ClangMajorVersion $envLibClangPath
      Write-Host "[ECO] Ignoring Env:LIBCLANG_PATH ($envLibClangPath, clang $envMajor) and using bindgen-friendly clang: $($preferred[0])" -ForegroundColor Yellow
    }
    return $preferred[0]
  }

  return $valid[0]
}

function Ensure-BindgenFriendlyLibClang($binPath) {
  $major = Get-ClangMajorVersion $binPath
  if ($null -eq $major) {
    Write-Host "[ECO] Could not detect clang major version from $binPath. Proceeding..." -ForegroundColor DarkYellow
    return
  }
  if ($major -gt 18) {
    if ($env:ECO_ALLOW_UNSUPPORTED_CLANG -eq "1") {
      Write-Host "[ECO] WARNING: Detected clang $major. Continuing because ECO_ALLOW_UNSUPPORTED_CLANG=1." -ForegroundColor Yellow
      Write-Host "[ECO] bindgen may generate opaque structs (_address) and break build on scrap." -ForegroundColor Yellow
      return
    }
    throw "Detected clang $major at '$binPath'. Install/use LLVM 16-18 (or VS LLVM) to avoid bindgen opaque structs. If you want to force anyway, set ECO_ALLOW_UNSUPPORTED_CLANG=1."
  }
}

Write-Host "[ECO] Starting build..." -ForegroundColor Cyan

# Basic checks
Require-Command git
Require-Command flutter
Require-Command cargo

# Ensure submodules
Write-Host "[ECO] Updating submodules..." -ForegroundColor Cyan
& git submodule update --init --recursive
Assert-LastExitCode "git submodule update --init --recursive"

# Recommended toolchain versions (match CI)
$rustToolchain = "1.75.0"
Write-Host "[ECO] Ensuring Rust toolchain $rustToolchain..." -ForegroundColor Cyan
& rustup toolchain install $rustToolchain | Out-Host
Assert-LastExitCode "rustup toolchain install $rustToolchain"
& rustup default $rustToolchain | Out-Host
Assert-LastExitCode "rustup default $rustToolchain"

Write-Host "[ECO] Flutter version (expected 3.24.5):" -ForegroundColor Cyan
& flutter --version | Out-Host
Assert-LastExitCode "flutter --version"

# Avoid stale bindgen flags from previous troubleshooting sessions.
foreach ($name in @("SCRAP_FORCE_BINDGEN", "BINDGEN_EXTRA_CLANG_ARGS")) {
  if (Test-Path "Env:$name") {
    Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    Write-Host "[ECO] Cleared Env:$name" -ForegroundColor DarkYellow
  }
}

$env:LIBCLANG_PATH = Resolve-LibClangPath
if (-not ($env:Path -split ';' | Where-Object { $_ -eq $env:LIBCLANG_PATH })) {
  $env:Path = "$env:LIBCLANG_PATH;$env:Path"
}
Write-Host "[ECO] LIBCLANG_PATH=$env:LIBCLANG_PATH" -ForegroundColor Cyan
if (Test-Path (Join-Path $env:LIBCLANG_PATH "clang.exe")) {
  & (Join-Path $env:LIBCLANG_PATH "clang.exe") --version | Select-Object -First 1 | Out-Host
}
Ensure-BindgenFriendlyLibClang $env:LIBCLANG_PATH

# Build
Write-Host "[ECO] Building Rust core + Flutter UI..." -ForegroundColor Cyan
# Force regen of bindgen outputs for scrap (vpx/aom/yuv) to avoid stale opaque structs.
& cargo clean -p scrap | Out-Host
Assert-LastExitCode "cargo clean -p scrap"
# Uses build.py for Windows Flutter flow. Requires python in PATH (py or python).
if (Get-Command py -ErrorAction SilentlyContinue) {
  & py -3 build.py --flutter --skip-portable-pack
  Assert-LastExitCode "py -3 build.py --flutter --skip-portable-pack"
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
  & python build.py --flutter --skip-portable-pack
  Assert-LastExitCode "python build.py --flutter --skip-portable-pack"
} else {
  throw "Python not found. Install Python 3 and try again."
}

# Output
$releaseDir = Join-Path $PSScriptRoot "..\flutter\build\windows\x64\runner\Release"
$generatedExe = Join-Path $releaseDir "rustdesk.exe"
$targetExe = Join-Path $releaseDir "eco-remoto.exe"
$legacyAlias = Join-Path $releaseDir "eco-remote.exe"

if (Test-Path $generatedExe) {
  # Keep only the branded executable in Release output.
  if (Test-Path $targetExe) {
    Remove-Item $targetExe -Force
  }
  Move-Item $generatedExe $targetExe -Force
} elseif (-not (Test-Path $targetExe)) {
  throw "Build completed but no executable was found at '$generatedExe' or '$targetExe'"
}

# Cleanup older alias to avoid delivery confusion.
if (Test-Path $legacyAlias) {
  Remove-Item $legacyAlias -Force
}

Write-Host "[ECO] Build OK: $targetExe" -ForegroundColor Green
