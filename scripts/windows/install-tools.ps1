<#
.SYNOPSIS
    Provisions the Windows-native toolchain pinned by .github/versions.lock.

.DESCRIPTION
    Reads the pinned versions of Zig, wasm-tools, wasmtime, WASI SDK,
    plus the realworld-test toolchains (Go, TinyGo, Rust via rustup)
    from .github/versions.lock and installs each into a per-user
    directory under %LOCALAPPDATA%\zwasm-tools. Adds the relevant
    binaries to the user-scoped PATH and sets WASI_SDK_PATH /
    CARGO_HOME / RUSTUP_HOME.

    Idempotent: an existing version-stamped directory is left in place
    and the install step is skipped.

    Requires: Windows 10/11 with built-in tar.exe (used to extract
    .tar.gz archives), PowerShell 5.1 or PowerShell 7. Does not require
    administrator rights.

.PARAMETER Force
    Reinstall every tool even if the version-stamped directory already
    exists.

.PARAMETER OnlyTool
    Install just one tool. Accepts: zig, wasm-tools, wasmtime, wasi-sdk,
    rust, go, tinygo (and 'all', the default).

.EXAMPLE
    pwsh -NoLogo -File scripts\windows\install-tools.ps1

.EXAMPLE
    pwsh -NoLogo -File scripts\windows\install-tools.ps1 -OnlyTool zig -Force
#>

[CmdletBinding()]
param(
    [switch]$Force,
    [ValidateSet('zig', 'wasm-tools', 'wasmtime', 'wasi-sdk', 'rust', 'go', 'tinygo', 'all')]
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
# Realworld toolchain pins (W52). Fail loudly if a requested install
# needs them but they're missing — keeps the script honest about its
# inputs.
$realworldKeys = @{ rust = 'RUST_VERSION'; go = 'GO_VERSION'; tinygo = 'TINYGO_VERSION' }
foreach ($pair in $realworldKeys.GetEnumerator()) {
    $tool = $pair.Key; $key = $pair.Value
    if ($OnlyTool -in @('all', $tool) -and -not $versions.ContainsKey($key)) {
        throw "install-tools.ps1: $key missing from versions.lock (needed for $tool install)"
    }
}

# --- Install layout ---

$installRoot = Join-Path $env:LOCALAPPDATA 'zwasm-tools'
$workDir     = Join-Path $env:LOCALAPPDATA 'zwasm-tools\.work'
New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
New-Item -ItemType Directory -Force -Path $workDir     | Out-Null

# --- Microsoft Visual C++ Redistributable (WASI SDK clang.exe needs it) ---

function Ensure-VCRedist {
    # WASI SDK 30 ships a clang.exe linked against MSVC's vcruntime140.dll /
    # msvcp140.dll. Stock Windows 11 only carries the .NET-flavoured
    # vcruntime140_clr0400.dll variants, so a fresh machine fails with
    # STATUS_DLL_NOT_FOUND (exit 0xC0000135) before any compilation runs.
    # The plain runtime ships in Microsoft's Visual C++ Redistributable.
    if (Test-Path 'C:\Windows\System32\vcruntime140.dll') {
        return
    }
    Write-Host "[install] Microsoft Visual C++ Redistributable (required by WASI SDK clang.exe)"
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw "vcruntime140.dll missing and winget unavailable. Install Microsoft.VCRedist.2015+.x64 manually."
    }
    & winget install --id Microsoft.VCRedist.2015+.x64 -e --silent `
        --accept-source-agreements --accept-package-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget install of Microsoft.VCRedist.2015+.x64 failed (exit $LASTEXITCODE). System-wide install needs admin; rerun in an elevated shell or install manually."
    }
}

if ($OnlyTool -in @('all', 'wasi-sdk')) {
    Ensure-VCRedist
}

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

# --- Realworld toolchains: Go, TinyGo, Rust (W52) ---
#
# Needed only for the realworld Go / TinyGo / Rust subset of
# `test/realworld/build_all.py`. The C / C++ subset works without any
# of these. CI runners ship rustup pre-installed, so the three are
# strictly local / self-hosted-runner concerns.

if ($OnlyTool -in @('all', 'go')) {
    # The official Go zip extracts into a single `go/` directory holding
    # `bin/go.exe`. Resolve-SingleSubdir flattens that so the stamped
    # install dir holds `bin/` directly.
    $url = "https://go.dev/dl/go$($versions.GO_VERSION).windows-amd64.zip"
    $dir = Install-Tool -Name 'go' -Version $versions.GO_VERSION -Url $url -Format 'zip'
    $paths['go'] = $dir
}

if ($OnlyTool -in @('all', 'tinygo')) {
    # tinygo .zip on Windows extracts into a single `tinygo/` directory
    # holding `bin/tinygo.exe`. Same flattening as Go above.
    # Note: tinygo wasm32-wasi support requires `go` reachable on PATH
    # at compile time (it shells out to `go` for stdlib pieces).
    $url = "https://github.com/tinygo-org/tinygo/releases/download/v$($versions.TINYGO_VERSION)/tinygo$($versions.TINYGO_VERSION).windows-amd64.zip"
    $dir = Install-Tool -Name 'tinygo' -Version $versions.TINYGO_VERSION -Url $url -Format 'zip'
    $paths['tinygo'] = $dir
}

# Rustup is special: it's a self-installer (rustup-init.exe), not an
# archive. Install into a stamped directory under $installRoot with
# its own CARGO_HOME / RUSTUP_HOME so the install is self-contained
# and does not touch %USERPROFILE%\.cargo or the user-default toolchain.
function Install-Rustup {
    param(
        [Parameter(Mandatory)][string]$Toolchain,
        [Parameter(Mandatory)][string]$InstallRoot
    )
    # Use a canonical stamp directory that mirrors the Install-Tool
    # convention, so re-running the script on the same RUST_VERSION
    # is idempotent (skips the rustup-init download + run).
    $stampedDir = Join-Path $InstallRoot ("rust-{0}" -f $Toolchain)
    $cargoHome  = Join-Path $stampedDir 'cargo'
    $rustupHome = Join-Path $stampedDir 'rustup'
    if ((Test-Path $stampedDir) -and -not $Force) {
        Write-Host "[skip] rust $Toolchain (exists at $stampedDir)"
        return $stampedDir
    }
    Write-Host "[install] rust $Toolchain (rustup-init)"
    $installer = Join-Path $workDir 'rustup-init.exe'
    Download-File -Url 'https://win.rustup.rs/x86_64' -Dest $installer
    # rustup-init flags:
    #   -y                          non-interactive
    #   --no-modify-path            we manage PATH ourselves below
    #   --default-toolchain $tc     pin (e.g. 'stable')
    #   --default-host x86_64-pc-windows-msvc — match the CI runner ABI
    if (Test-Path $stampedDir) { Remove-Item -Recurse -Force $stampedDir }
    New-Item -ItemType Directory -Force -Path $cargoHome  | Out-Null
    New-Item -ItemType Directory -Force -Path $rustupHome | Out-Null
    $env:CARGO_HOME = $cargoHome
    $env:RUSTUP_HOME = $rustupHome
    & $installer -y --no-modify-path `
        --default-toolchain $Toolchain `
        --default-host x86_64-pc-windows-msvc
    if ($LASTEXITCODE -ne 0) {
        throw "rustup-init failed (exit $LASTEXITCODE)"
    }
    # Add the wasm32-wasip1 target so realworld Rust modules build.
    & (Join-Path $cargoHome 'bin\rustup.exe') target add wasm32-wasip1
    if ($LASTEXITCODE -ne 0) {
        throw "rustup target add wasm32-wasip1 failed (exit $LASTEXITCODE)"
    }
    Remove-Item -Force $installer -ErrorAction SilentlyContinue
    return $stampedDir
}

if ($OnlyTool -in @('all', 'rust')) {
    $rustToolchain = $versions.RUST_VERSION  # e.g. 'stable'
    $rustRoot = Install-Rustup -Toolchain $rustToolchain -InstallRoot $installRoot
    $paths['rust'] = $rustRoot
}

# --- PATH and env wiring (User scope, plus GitHub Actions if present) ---
#
# In CI the runner exports `$GITHUB_PATH` and `$GITHUB_ENV` — appending
# entries to those files exposes the change to subsequent steps in
# the same job. Local Windows installs do not have those vars set;
# behaviour falls back to the original User-scope-only path.

$inGithubActions = ($env:GITHUB_PATH -and (Test-Path $env:GITHUB_PATH))

function Append-GithubPath {
    param([Parameter(Mandatory)][string]$Entry)
    if ($inGithubActions) {
        Add-Content -Path $env:GITHUB_PATH -Value $Entry -Encoding utf8
    }
}

function Append-GithubEnv {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )
    if ($inGithubActions -and (Test-Path $env:GITHUB_ENV)) {
        Add-Content -Path $env:GITHUB_ENV -Value "$Key=$Value" -Encoding utf8
    }
}

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
        # Always export to GITHUB_PATH so a re-run with cached User
        # PATH still propagates entries to the current GHA job.
        Append-GithubPath -Entry $p
    }
    if ($changed) {
        [Environment]::SetEnvironmentVariable('Path', ($entries -join ';'), 'User')
    }
}

# Tool layouts after Resolve-SingleSubdir:
#
#   zig / wasm-tools / wasmtime — binaries directly in the stamped dir
#                                 (no bin/ subdir on Windows).
#   go                          — bin/ subdir holding go.exe + gofmt.exe.
#   tinygo                      — bin/ subdir holding tinygo.exe.
#   rust                        — cargo/bin/ holding cargo.exe + rustup.exe.
$pathsToAdd = @()
if ($paths.ContainsKey('zig'))        { $pathsToAdd += $paths['zig'] }
if ($paths.ContainsKey('wasm-tools')) { $pathsToAdd += $paths['wasm-tools'] }
if ($paths.ContainsKey('wasmtime'))   { $pathsToAdd += $paths['wasmtime'] }
if ($paths.ContainsKey('go'))         { $pathsToAdd += (Join-Path $paths['go']     'bin') }
if ($paths.ContainsKey('tinygo'))     { $pathsToAdd += (Join-Path $paths['tinygo'] 'bin') }
if ($paths.ContainsKey('rust'))       { $pathsToAdd += (Join-Path (Join-Path $paths['rust'] 'cargo') 'bin') }
Update-UserPath -Add $pathsToAdd

if ($paths.ContainsKey('wasi-sdk')) {
    [Environment]::SetEnvironmentVariable('WASI_SDK_PATH', $paths['wasi-sdk'], 'User')
    Append-GithubEnv -Key 'WASI_SDK_PATH' -Value $paths['wasi-sdk']
    Write-Host "[env] WASI_SDK_PATH=$($paths['wasi-sdk'])"
}

# Rust install needs persistent CARGO_HOME / RUSTUP_HOME so future
# shells use the self-contained install (not %USERPROFILE%\.cargo).
if ($paths.ContainsKey('rust')) {
    $rustRoot   = $paths['rust']
    $cargoHome  = Join-Path $rustRoot 'cargo'
    $rustupHome = Join-Path $rustRoot 'rustup'
    [Environment]::SetEnvironmentVariable('CARGO_HOME',  $cargoHome,  'User')
    [Environment]::SetEnvironmentVariable('RUSTUP_HOME', $rustupHome, 'User')
    Append-GithubEnv -Key 'CARGO_HOME'  -Value $cargoHome
    Append-GithubEnv -Key 'RUSTUP_HOME' -Value $rustupHome
    Write-Host "[env] CARGO_HOME=$cargoHome"
    Write-Host "[env] RUSTUP_HOME=$rustupHome"
}

# Ensure Git for Windows bash is reachable so `bash scripts/gate-commit.sh`
# works in fresh shells. Skip silently if Git is in a non-default location.
$gitBin = 'C:\Program Files\Git\bin'
if (Test-Path (Join-Path $gitBin 'bash.exe')) {
    Update-UserPath -Add @($gitBin)
}

Write-Host ""
Write-Host "Done. Open a new shell to pick up PATH / WASI_SDK_PATH /"
Write-Host "       CARGO_HOME / RUSTUP_HOME changes."
Write-Host "Verify (core):     zig version; wasm-tools --version; wasmtime --version; bash --version"
if ($OnlyTool -in @('all', 'go', 'tinygo', 'rust')) {
    Write-Host "Verify (realworld): go version; tinygo version; cargo --version; rustup --version"
}
