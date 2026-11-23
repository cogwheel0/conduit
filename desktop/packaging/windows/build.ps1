<#
Builds Conduit Desktop's Windows installer (x64, per user, unsigned):

  desktop\packaging\windows\build.ps1 -Notices <THIRD_PARTY_NOTICES.md> [-Version 1.2.0] [-Out <folder>]
                                      [-UpdatePublicKey <key> [-UpdateFeedUrl <url>]]
                                      [-SkipRust] [-SkipDaemon]

1. The app: cargo build --release for x86_64-pc-windows-msvc, without the
   test harness (no `harness` feature), CONDUIT_VERSION set, and the C
   runtime linked in (+crt-static), so it needs no Visual C++
   Redistributable on the machine it is installed on. With
   -UpdatePublicKey, its updater too (CONDUIT_UPDATE_PUBLIC_ED_KEY and
   CONDUIT_UPDATE_FEED_URL), as the Mac's bundle.sh writes SUPublicEDKey.
2. conduitd: `dart build cli` in apps\daemon (conduitd.exe and its
   sqlite3.dll), with the Dart code generated first when it isn't.
3. The install folder, staged in <out>\stage: conduit-desktop.exe with
   WinSparkle.dll beside it (the updater; the pinned release, tools.env),
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
-UpdatePublicKey: the EdDSA public key (base64 of 32 bytes) the app's
WinSparkle trusts: WINDOWS_PUBLIC_ED_KEY for a release
(docs/RELEASING-DESKTOP.md). Without it the app has no updater, as a Mac
bundle without SPARKLE_PUBLIC_ED_KEY has none. -UpdateFeedUrl: the feed it
reads (default: winlinux_feed.py url windows, beside the Mac's appcast;
CI's rehearsal names a fixture served on this machine).
-Notices: the licences of what the Windows build includes, made on a Mac or
Linux with packaging/notices/notices.sh --target x86_64-pc-windows-msvc
--out <file> (it needs bash and cargo-about); checked before anything
builds.

Inno Setup: ISCC in the environment, else the release tools.env pins,
downloaded once into desktop\target\inno\<version>, checked against its
SHA-256 and installed there. WinSparkle: tools.env's release, downloaded
once into desktop\target\winsparkle\<version> and checked the same way.

Needs Rust (rustup with MSVC), Flutter/Dart with `flutter pub get` done at
the repository root, and Python 3.
#>
#Requires -Version 7.4
param(
  [string]$Notices,
  [string]$Version = '0.0.0',
  [string]$Out,
  [string]$UpdatePublicKey,
  [string]$UpdateFeedUrl,
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

# WinSparkle.dll: tools.env's release, downloaded once and checked.
function Get-WinSparkle {
  $tools = Read-Env (Join-Path $PSScriptRoot 'tools.env')
  $root = Join-Path $desktop "target\winsparkle\$($tools.WINSPARKLE_VERSION)"
  $dll = Join-Path $root 'WinSparkle.dll'
  if (Test-Path -LiteralPath $dll) { return $dll }
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $zip = Join-Path $root "WinSparkle-$($tools.WINSPARKLE_VERSION).zip"
  if (-not (Test-Path -LiteralPath $zip)) {
    Log "downloading WinSparkle $($tools.WINSPARKLE_VERSION)"
    Invoke-WebRequest -Uri $tools.WINSPARKLE_URL -OutFile "$zip.part" -MaximumRetryCount 3
    Move-Item -LiteralPath "$zip.part" -Destination $zip
  }
  $sum = (Get-FileHash -Algorithm SHA256 -LiteralPath $zip).Hash.ToLowerInvariant()
  if ($sum -ne $tools.WINSPARKLE_SHA256) {
    Move-Aside $zip
    throw "WinSparkle's release has SHA-256 $sum, not tools.env's $($tools.WINSPARKLE_SHA256)"
  }
  Log "WinSparkle $($tools.WINSPARKLE_VERSION) checksum verified"
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $archive = [IO.Compression.ZipFile]::OpenRead($zip)
  try {
    $entry = $archive.GetEntry("WinSparkle-$($tools.WINSPARKLE_VERSION)/x64/Release/WinSparkle.dll")
    if (-not $entry) { throw "the WinSparkle release has no x64/Release/WinSparkle.dll" }
    # Renamed into place once written: a half-written copy is never used.
    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, "$dll.part", $true)
  } finally { $archive.Dispose() }
  Move-Item -LiteralPath "$dll.part" -Destination $dll
  $dll
}

$fileVersion = & python $winlinux version $Version --windows
if (-not $Notices) {
  throw '-Notices <file>: make it with packaging/notices/notices.sh --target x86_64-pc-windows-msvc --out <file>'
}
$Notices = (Resolve-Path -LiteralPath $Notices).ProviderPath
& python $winlinux notices $Notices --os windows
if (-not $Out) { $Out = Join-Path $desktop "target\windows\Conduit-$Version" }
# The updater's key and feed, checked before anything builds.
$update = @{}
if ($UpdatePublicKey) {
  $bytes = @()
  try { $bytes = [Convert]::FromBase64String($UpdatePublicKey) } catch { }
  if ($bytes.Length -ne 32) {
    throw '-UpdatePublicKey is not an EdDSA public key (base64 of 32 bytes, as generate_keys -p prints it)'
  }
  # FromBase64String skips whitespace inside; the app's decoder doesn't.
  $UpdatePublicKey = [Convert]::ToBase64String($bytes)
  if (-not $UpdateFeedUrl) { $UpdateFeedUrl = & python (Join-Path $packaging 'winlinux_feed.py') url windows }
  if ($UpdateFeedUrl -notmatch '^https?://') { throw "-UpdateFeedUrl $UpdateFeedUrl is not an http(s) URL" }
  $update = @{ CONDUIT_UPDATE_PUBLIC_ED_KEY = $UpdatePublicKey; CONDUIT_UPDATE_FEED_URL = $UpdateFeedUrl }
} elseif ($UpdateFeedUrl) {
  throw '-UpdateFeedUrl needs -UpdatePublicKey: an updater without a key would run unsigned updates'
}
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
  Log "reusing $exe (its updater is the one it was built with)"
} else {
  if ($update.Count) {
    Log "the updater trusts $UpdatePublicKey and reads $UpdateFeedUrl"
  } else {
    Log 'no -UpdatePublicKey: no updater in this build'
  }
  Log "cargo build --release --target $target (version $Version, static C runtime)"
  Push-Location $desktop
  try {
    Invoke-WithEnv @{
      CONDUIT_VERSION = $Version
      CARGO_TARGET_X86_64_PC_WINDOWS_MSVC_RUSTFLAGS = '-C target-feature=+crt-static'
      # Unset without -UpdatePublicKey: a key is never taken from the
      # caller's environment.
      CONDUIT_UPDATE_PUBLIC_ED_KEY = $update.CONDUIT_UPDATE_PUBLIC_ED_KEY
      CONDUIT_UPDATE_FEED_URL = $update.CONDUIT_UPDATE_FEED_URL
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
Copy-Item -LiteralPath (Get-WinSparkle) -Destination $stage
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
