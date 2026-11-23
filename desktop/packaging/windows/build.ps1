<#
Builds Conduit Desktop's Windows installer (x64, per user, unsigned):

  desktop\packaging\windows\build.ps1 -Notices <THIRD_PARTY_NOTICES.md> [-Version 1.2.0] [-Out <folder>]
                                      [-SkipRust] [-SkipDaemon]

1. The app: cargo build --release for x86_64-pc-windows-msvc, without the
   test harness (no `harness` feature), CONDUIT_VERSION set, and the C
   runtime linked in (+crt-static), so it needs no Visual C++
   Redistributable on the machine it is installed on.
2. conduitd: `dart build cli` in apps\daemon (conduitd.exe and its
   sqlite3.dll), with the Dart code generated first when it isn't.
3. The install folder, staged in <out>\stage: conduit-desktop.exe,
   conduitd\ beside it (where paths::packaged_daemon_for looks), the model
   logo catalog conduitd reads, the icon and the third-party notices; then
   checked (winlinux.py layout: complete, no test harness, no runtime DLL
   Windows lacks).
4. Inno Setup compiles conduit.iss into
   <out>\Conduit-<version>-windows-x64-setup.exe.

-Version: X.Y.Z (default 0.0.0), checked as the Mac's scripts check it
(packaging/macos/lib.sh); the installer's file version is X.Y.Z.0.
-Out: default desktop\target\windows\Conduit-<version>. An earlier one is
moved aside, never deleted.
-SkipRust, -SkipDaemon: reuse what an earlier build left.
-Notices: the licences of what the Windows build includes, made on a Mac or
Linux with packaging/notices/notices.sh --target x86_64-pc-windows-msvc
--out <file> (it needs bash and cargo-about); checked before anything
builds.

Inno Setup: ISCC in the environment, else the release tools.env pins,
downloaded once into desktop\target\inno\<version>, checked against its
SHA-256 and installed there.

Needs Rust (rustup with MSVC), Flutter/Dart with `flutter pub get` done at
the repository root, and Python 3.
#>
#Requires -Version 7.4
param(
  [string]$Notices,
  [string]$Version = '0.0.0',
  [string]$Out,
  [switch]$SkipRust,
  [switch]$SkipDaemon
)
$ErrorActionPreference = 'Stop'
# A native command that fails stops the script.
$PSNativeCommandUseErrorActionPreference = $true

$packaging = Split-Path -Parent $PSScriptRoot
$desktop = Split-Path -Parent $packaging
$repo = Split-Path -Parent $desktop
$target = 'x86_64-pc-windows-msvc'
$winlinux = Join-Path $packaging 'winlinux.py'

function Log([string]$Message) { Write-Host "==> $Message" }

# Moves an existing path aside (<path>.old-<time>-<pid>): nothing here deletes.
function Move-Aside([string]$Path) {
  if (Test-Path -LiteralPath $Path) {
    $aside = "$(Split-Path -Leaf $Path).old-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))-$PID"
    Rename-Item -LiteralPath $Path -NewName $aside
    Log "moved the previous $(Split-Path -Leaf $Path) aside to $aside"
  }
}

# KEY=value lines (tools.env).
function Read-Env([string]$Path) {
  $values = @{}
  foreach ($line in Get-Content -LiteralPath $Path) {
    if ($line -match '^([A-Z0-9_]+)=(.*)$') { $values[$Matches[1]] = $Matches[2] }
  }
  $values
}

# Runs $Block with the environment variables in $Vars set, then puts them back.
function Invoke-WithEnv([hashtable]$Vars, [scriptblock]$Block) {
  $saved = @{}
  foreach ($name in $Vars.Keys) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
    [Environment]::SetEnvironmentVariable($name, $Vars[$name])
  }
  try { & $Block } finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
  }
}

# The Dart packages' generated code isn't committed: generated when the
# core's is missing (as packaging/macos/bundle.sh does).
function Invoke-DartCodegen {
  if (Get-ChildItem -LiteralPath (Join-Path $repo 'packages\conduit_core\lib') -Recurse -Filter '*.g.dart' |
      Select-Object -First 1) { return }
  Log 'generating Dart code (build_runner)'
  Push-Location $repo
  try { flutter pub get } finally { Pop-Location }
  foreach ($dir in Get-ChildItem -Directory -LiteralPath (Join-Path $repo 'packages'), (Join-Path $repo 'apps')) {
    $pubspec = Join-Path $dir.FullName 'pubspec.yaml'
    if ((Test-Path -LiteralPath $pubspec) -and (Select-String -LiteralPath $pubspec -Pattern '^  build_runner:' -Quiet)) {
      Log "build_runner in $($dir.Name)"
      Push-Location $dir.FullName
      try { dart run build_runner build } finally { Pop-Location }
    }
  }
}

# ISCC.exe: $env:ISCC, else the pinned Inno Setup (tools.env).
function Get-Iscc {
  if ($env:ISCC) { return $env:ISCC }
  $tools = Read-Env (Join-Path $PSScriptRoot 'tools.env')
  $root = Join-Path $desktop "target\inno\$($tools.INNO_VERSION)"
  $innoDir = Join-Path $root 'inno'
  $iscc = Join-Path $innoDir 'ISCC.exe'
  # Written once the install finished: a half-installed copy is never used.
  if (Test-Path -LiteralPath (Join-Path $innoDir '.complete')) { return $iscc }
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $installer = Join-Path $root "innosetup-$($tools.INNO_VERSION).exe"
  if (-not (Test-Path -LiteralPath $installer)) {
    Log "downloading Inno Setup $($tools.INNO_VERSION)"
    Invoke-WebRequest -Uri $tools.INNO_URL -OutFile "$installer.part" -MaximumRetryCount 3
    Move-Item -LiteralPath "$installer.part" -Destination $installer
  }
  $sum = (Get-FileHash -Algorithm SHA256 -LiteralPath $installer).Hash.ToLowerInvariant()
  if ($sum -ne $tools.INNO_SHA256) {
    Move-Aside $installer
    throw "Inno Setup's installer has SHA-256 $sum, not tools.env's $($tools.INNO_SHA256)"
  }
  Log "Inno Setup $($tools.INNO_VERSION) checksum verified; installing it into $innoDir"
  Move-Aside $innoDir
  # For this user, into this folder only: no Start menu entries.
  $run = Start-Process -FilePath $installer -Wait -PassThru -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/CURRENTUSER', '/NOICONS',
    "/DIR=`"$innoDir`"", "/LOG=`"$root\install.log`""
  )
  if ($run.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $iscc)) {
    Get-Content -LiteralPath "$root\install.log" -Tail 40 -ErrorAction SilentlyContinue
    throw "Inno Setup's installer failed (exit $($run.ExitCode))"
  }
  New-Item -ItemType File -Path (Join-Path $innoDir '.complete') | Out-Null
  $iscc
}

$fileVersion = & python $winlinux version $Version --windows
if (-not $Notices) {
  throw '-Notices <file>: make it with packaging/notices/notices.sh --target x86_64-pc-windows-msvc --out <file>'
}
$Notices = (Resolve-Path -LiteralPath $Notices).ProviderPath
& python $winlinux notices $Notices --os windows
if (-not $Out) { $Out = Join-Path $desktop "target\windows\Conduit-$Version" }
$Out = [IO.Path]::GetFullPath($Out)
# The build moves an earlier -Out aside, notices in it included.
$outPrefix = $Out.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
if ($Notices.StartsWith($outPrefix, [StringComparison]::OrdinalIgnoreCase)) {
  throw "-Notices $Notices is inside -Out $Out, which the build moves aside first: put the notices elsewhere"
}

# 1. The app.
$exe = Join-Path $desktop "target\$target\release\conduit-desktop.exe"
if ($SkipRust) {
  if (-not (Test-Path -LiteralPath $exe)) { throw "-SkipRust: no $exe" }
  Log "reusing $exe"
} else {
  Log "cargo build --release --target $target (version $Version, static C runtime)"
  Push-Location $desktop
  try {
    Invoke-WithEnv @{
      CONDUIT_VERSION = $Version
      CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS = '-C target-feature=+crt-static'
    } { cargo build --release --locked --target $target -p conduit-desktop }
  } finally { Pop-Location }
}

# 2. conduitd.
$daemonBundle = Join-Path $repo 'apps\daemon\build\cli\windows_x64\bundle'
if ($SkipDaemon) {
  Log "reusing $daemonBundle"
} else {
  Invoke-DartCodegen
  Log 'dart build cli (apps\daemon)'
  Push-Location (Join-Path $repo 'apps\daemon')
  try { dart build cli } finally { Pop-Location }
}
if (-not (Test-Path -LiteralPath (Join-Path $daemonBundle 'bin\conduitd.exe'))) {
  throw "no $daemonBundle\bin\conduitd.exe"
}

# 3. The install folder.
Move-Aside $Out
$stage = Join-Path $Out 'stage'
New-Item -ItemType Directory -Force -Path $stage | Out-Null
Log "staging the install folder in $stage"
Copy-Item -LiteralPath $exe -Destination $stage
Copy-Item -LiteralPath $daemonBundle -Destination (Join-Path $stage 'conduitd') -Recurse
# The models.dev logo catalog: conduitd looks for it beside its bin\.
$logos = Join-Path $stage 'conduitd\model_logos'
New-Item -ItemType Directory -Force -Path $logos | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'assets\model_logos\catalog.json') -Destination $logos
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'conduit.ico') -Destination $stage
Copy-Item -LiteralPath $Notices -Destination (Join-Path $stage 'THIRD_PARTY_NOTICES.md')
& python $winlinux layout $stage --os windows

# 4. The installer.
$iscc = Get-Iscc
Log "compiling conduit.iss with $iscc"
& $iscc /Q "/DAppVersion=$Version" "/DFileVersion=$fileVersion" "/DStageDir=$stage" "/DOutputDir=$Out" `
  (Join-Path $PSScriptRoot 'conduit.iss')
$setup = Join-Path $Out "Conduit-$Version-windows-x64-setup.exe"
if (-not (Test-Path -LiteralPath $setup)) { throw "ISCC left no $setup" }
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $setup).Hash.ToLowerInvariant()
Log "$setup ($([math]::Round((Get-Item -LiteralPath $setup).Length / 1MB, 1)) MB, SHA-256 $hash; unsigned)"
