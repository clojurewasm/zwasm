<#
.SYNOPSIS
    Provisions the Windows-native toolchain pinned by .github/versions.lock.

.DESCRIPTION
    Reads the pinned versions of Zig, wasm-tools, wasmtime, and WASI SDK
    from .github/versions.lock and installs each into a per-user
    directory under %LOCALAPPDATA%\zwasm-tools. Adds the relevant
    binaries to the user-scoped PATH and sets WASI_SDK_PATH.

    Idempotent: an existing version-stamped directory is left in place
    and the install step is skipped.

    Requires: Windows 10/11 with built-in tar.exe (used to extract
    .tar.gz archives), PowerShell 5.1 or PowerShell 7. Does not require
    administrator rights.

.PARAMETER Force
    Reinstall every tool even if the version-stamped directory already
    exists.

.PARAMETER OnlyTool
    Install just one tool. Accepts: zig, wasm-tools, wasmtime, wasi-sdk.

.EXAMPLE
    pwsh -NoLogo -File scripts\windows\install-tools.ps1

.EXAMPLE
    pwsh -NoLogo -File scripts\windows\install-tools.ps1 -OnlyTool zig -Force
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [ValidateSet('zig', 'wasm-tools', 'wasmtime', 'wasi-sdk', 'all')]
    [string]$OnlyTool = 'all'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# --- Locate repo root and load versions.lock ---

function Find-RepoRoot {
    $dir = $PSScriptRoot
    while ($dir -and -not (Test-Path (Join-Path $dir '.github\versions.lock'))) {
        $parent = Split-Path -Parent $dir
        if ($parent -eq $dir) { return $null }
        $dir = $parent
    }
    return $dir
}

$repoRoot = Find-RepoRoot
if (-not $repoRoot) {
    throw "install-tools.ps1: cannot locate .github/versions.lock relative to $PSScriptRoot"
}

function Read-VersionsLock {
    param([Parameter(Mandatory)][string]$Path)
    $map = @{}
    foreach ($rawLine in Get-Content -LiteralPath $Path) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $eq = $line.IndexOf('=')
        if ($eq -lt 1) { continue }
        $key = $line.Substring(0, $eq).Trim()
        $val = $line.Substring($eq + 1)
        # Defensive: strip a trailing inline comment in case the policy is
        # ever violated, matching the Python reader in ci.yml.
        $hashIdx = $val.IndexOf('#')
        if ($hashIdx -ge 0) { $val = $val.Substring(0, $hashIdx) }
        $map[$key] = $val.Trim().Trim('"')
    }
    return $map
}

$versions = Read-VersionsLock -Path (Join-Path $repoRoot '.github\versions.lock')
foreach ($k in 'ZIG_VERSION', 'WASM_TOOLS_VERSION', 'WASMTIME_VERSION', 'WASI_SDK_VERSION') {
    if (-not $versions.ContainsKey($k)) {
        throw "install-tools.ps1: $k missing from versions.lock"
    }
}

# --- Install layout ---

$installRoot = Join-Path $env:LOCALAPPDATA 'zwasm-tools'
$workDir     = Join-Path $env:LOCALAPPDATA 'zwasm-tools\.work'
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
New-Item -ItemType Directory -Force -Path $workDir     | Out-Null

# --- Helpers ---

function Download-File {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$Dest)
    Write-Host "  download: $Url"
    # Force TLS 1.2; Windows 10 ships with TLS 1.0 default in .NET 4.x.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $oldProgress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'   # 100x faster Invoke-WebRequest
    try {
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
    }
    finally {
        $ProgressPreference = $oldProgress
    }
}

function Extract-Zip {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$Dest)
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    Expand-Archive -LiteralPath $Archive -DestinationPath $Dest -Force
}

function Extract-TarGz {
    param([Parameter(Mandatory)][string]$Archive, [Parameter(Mandatory)][string]$Dest)
    if (Test-Path $Dest) { Remove-Item -Recurse -Force $Dest }
    New-Item -ItemType Directory -Force -Path $Dest | Out-Null
    # Built-in tar.exe (BSD tar) on Windows 10+.
    & tar.exe -xzf $Archive -C $Dest
    if ($LASTEXITCODE -ne 0) {
        throw "tar.exe extraction failed for $Archive (exit $LASTEXITCODE)"
    }
}

function Resolve-SingleSubdir {
    param([Parameter(Mandatory)][string]$ParentDir)
    # @(...) forces array context so a single match still has .Count.
    $children = @(Get-ChildItem -LiteralPath $ParentDir -Directory)
    if ($children.Count -eq 1) { return $children[0].FullName }
    return $ParentDir
}

# Install one tool. The closure receives the unpacked archive root
# and is expected to return the directory whose contents should
# become $stampedDir (i.e. flat layout: bin/zig.exe lives directly
# inside or one level deep — the closure normalises that).
function Install-Tool {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory)][string]$Url,
        [Parameter(Mandatory)][ValidateSet('zip', 'tar.gz')][string]$Format
    )
    $stampedDir = Join-Path $installRoot ("{0}-{1}" -f $Name, $Version)
    if ((Test-Path $stampedDir) -and -not $Force) {
        Write-Host "[skip] $Name $Version (exists at $stampedDir)"
        return $stampedDir
    }
    Write-Host "[install] $Name $Version"
    $archiveExt = if ($Format -eq 'zip') { 'zip' } else { 'tar.gz' }
    $archive = Join-Path $workDir ("{0}-{1}.{2}" -f $Name, $Version, $archiveExt)
    Download-File -Url $Url -Dest $archive
    $stagingDir = Join-Path $workDir ("{0}-{1}-staging" -f $Name, $Version)
    if ($Format -eq 'zip') {
        Extract-Zip -Archive $archive -Dest $stagingDir
    } else {
        Extract-TarGz -Archive $archive -Dest $stagingDir
    }
    $unpacked = Resolve-SingleSubdir -ParentDir $stagingDir
    if (Test-Path $stampedDir) { Remove-Item -Recurse -Force $stampedDir }
    Move-Item -LiteralPath $unpacked -Destination $stampedDir
    Remove-Item -Recurse -Force $stagingDir -ErrorAction SilentlyContinue
    Remove-Item -Force $archive -ErrorAction SilentlyContinue
    return $stampedDir
}

# --- Install plan ---

$paths = @{}

if ($OnlyTool -in @('all', 'zig')) {
    $url = "https://ziglang.org/download/$($versions.ZIG_VERSION)/zig-x86_64-windows-$($versions.ZIG_VERSION).zip"
    $dir = Install-Tool -Name 'zig' -Version $versions.ZIG_VERSION -Url $url -Format 'zip'
    $paths['zig'] = $dir
}

if ($OnlyTool -in @('all', 'wasm-tools')) {
    # bytecodealliance ships wasm-tools as .zip for Windows (unlike Linux/macOS
    # which use .tar.gz). Pinned by versions.lock WASM_TOOLS_VERSION.
    $url = "https://github.com/bytecodealliance/wasm-tools/releases/download/v$($versions.WASM_TOOLS_VERSION)/wasm-tools-$($versions.WASM_TOOLS_VERSION)-x86_64-windows.zip"
    $dir = Install-Tool -Name 'wasm-tools' -Version $versions.WASM_TOOLS_VERSION -Url $url -Format 'zip'
    $paths['wasm-tools'] = $dir
}

if ($OnlyTool -in @('all', 'wasmtime')) {
    $url = "https://github.com/bytecodealliance/wasmtime/releases/download/v$($versions.WASMTIME_VERSION)/wasmtime-v$($versions.WASMTIME_VERSION)-x86_64-windows.zip"
    $dir = Install-Tool -Name 'wasmtime' -Version $versions.WASMTIME_VERSION -Url $url -Format 'zip'
    $paths['wasmtime'] = $dir
}

if ($OnlyTool -in @('all', 'wasi-sdk')) {
    $url = "https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-$($versions.WASI_SDK_VERSION)/wasi-sdk-$($versions.WASI_SDK_VERSION).0-x86_64-windows.tar.gz"
    $dir = Install-Tool -Name 'wasi-sdk' -Version $versions.WASI_SDK_VERSION -Url $url -Format 'tar.gz'
    $paths['wasi-sdk'] = $dir
}

# --- PATH and env wiring (User scope) ---

function Update-UserPath {
    param([Parameter(Mandatory)][string[]]$Add)
    $current = [Environment]::GetEnvironmentVariable('Path', 'User')
    if (-not $current) { $current = '' }
    $entries = $current.Split(';') | Where-Object { $_ }
    $changed = $false
    foreach ($p in $Add) {
        if (-not $p) { continue }
        if ($entries -notcontains $p) {
            $entries += $p
            Write-Host "[path] +$p"
            $changed = $true
        }
    }
    if ($changed) {
        [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
    }
}

# Each release ZIP/tar.gz unpacks with its binaries directly inside
# the install dir — no `bin/` subdirectory on Windows for any of these
# tools today. Add the install dir itself.
$pathsToAdd = @()
if ($paths.ContainsKey('zig'))        { $pathsToAdd += $paths['zig'] }
if ($paths.ContainsKey('wasm-tools')) { $pathsToAdd += $paths['wasm-tools'] }
if ($paths.ContainsKey('wasmtime'))   { $pathsToAdd += $paths['wasmtime'] }
Update-UserPath -Add $pathsToAdd

if ($paths.ContainsKey('wasi-sdk')) {
    [Environment]::SetEnvironmentVariable('WASI_SDK_PATH', $paths['wasi-sdk'], 'User')
    Write-Host "[env] WASI_SDK_PATH=$($paths['wasi-sdk'])"
}

# Ensure Git for Windows bash is reachable so `bash scripts/gate-commit.sh`
# works in fresh shells. Skip silently if Git is in a non-default location.
$gitBin = 'C:\Program Files\Git\bin'
if (Test-Path (Join-Path $gitBin 'bash.exe')) {
    Update-UserPath -Add @($gitBin)
}

Write-Host ""
Write-Host "Done. Open a new shell to pick up PATH/WASI_SDK_PATH changes."
Write-Host "Verify: zig version; wasm-tools --version; wasmtime --version; bash --version"
