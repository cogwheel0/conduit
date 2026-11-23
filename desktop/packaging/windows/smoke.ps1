<#
Smoke-tests a Conduit installer the way a user meets it (CI's install
smoke; also a test VM):

  desktop\packaging\windows\smoke.ps1 -Installer <Conduit-<version>-windows-x64-setup.exe> [-Work <folder>]
                                      [-UpdateFeed <folder> [-UpdateFeedPort 8471]]

1. Installs it silently for this user, and checks the install folder
   (winlinux.py layout) and what it registered under HKCU: conduit://, Open
   With for the Mac's document types (never as their default app), the
   Start menu entry; nothing under HKLM.
2. The installed app refuses the test harness's flags (exit 64), and runs
   its --smoke pass on a profile of its own in -Work: exit code 0 and
   "SMOKE passed". No conduitd from the install folder runs afterwards.
   With -UpdateFeed, that folder is served on 127.0.0.1 port
   -UpdateFeedPort while the pass runs, and WinSparkle's check must find
   nothing newer: an installer built with that feed's URL and key
   (build.ps1 -UpdateFeedUrl, -UpdatePublicKey) and a folder holding
   appcast-windows.xml for no newer version (CI's rehearsal).
3. Installs again over the app while it runs, as WinSparkle runs an
   update (winlinux_feed.py installer-arguments: /SILENT ... /RELAUNCH=1):
   the installer closes the app and its conduitd (Restart Manager),
   replaces the files and starts the app again. It waits for the app's
   conduitd and for the new app through process start traces, which need
   an administrator (CI's runner user is one), then stops the new app.
4. Uninstalls silently: the install folder, the Start menu entry and every
   registration are gone, and the user's data folder is still there.

It installs into this user's %LOCALAPPDATA%\Programs\Conduit and
uninstalls it at the end: run it only where that is wanted. Every app run
uses a profile in -Work (default: a new folder in %TEMP%).
#>
#Requires -Version 7.4
param(
  [Parameter(Mandatory)][string]$Installer,
  [string]$Work,
  [string]$UpdateFeed,
  [int]$UpdateFeedPort = 8471
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$packaging = Split-Path -Parent $PSScriptRoot
$winlinux = Join-Path $packaging 'winlinux.py'
$feedTool = Join-Path $packaging 'winlinux_feed.py'
$Installer = (Resolve-Path -LiteralPath $Installer).ProviderPath
if (-not $Work) { $Work = Join-Path ([IO.Path]::GetTempPath()) "conduit-smoke-$PID" }
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$Work = (Resolve-Path -LiteralPath $Work).ProviderPath

function Log([string]$Message) { Write-Host "==> $Message" }

$guid = (Select-String -LiteralPath (Join-Path $PSScriptRoot 'conduit.iss') -Pattern '^#define AppGuid "([0-9A-F-]+)"').Matches[0].Groups[1].Value
$uninstallKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\{$guid}_is1"
$app = Join-Path $env:LOCALAPPDATA 'Programs\Conduit'
$exe = Join-Path $app 'conduit-desktop.exe'
$daemon = Join-Path $app 'conduitd\bin\conduitd.exe'
$command = "`"$exe`" `"%1`""
$shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) 'Conduit.lnk'
$classes = 'HKCU:\Software\Classes'
$extensions = @(& python $winlinux types windows)
# What the installer owns outright, and removes whole.
$ownedKeys = @("$classes\conduit", "$classes\Conduit.File", "$classes\Applications\conduit-desktop.exe", $uninstallKey)

# A registry value: $Name '' is the key's default value; $null when absent.
function Get-RegValue([string]$Key, [string]$Name = '') {
  $item = Get-Item -LiteralPath $Key -ErrorAction SilentlyContinue
  if ($item) { $item.GetValue($Name) } else { $null }
}

function Test-RegValue([string]$Key, [string]$Name) {
  $item = Get-Item -LiteralPath $Key -ErrorAction SilentlyContinue
  [bool]($item -and $item.GetValueNames() -contains $Name)
}

function Expect([bool]$Ok, [string]$What) {
  if (-not $Ok) { throw "smoke: $What" }
}

# Runs the installer or uninstaller silently and waits for it, its second
# phase included (Start-Process -Wait waits for descendants).
function Invoke-Setup([string]$Path, [string]$Log) {
  $run = Start-Process -FilePath $Path -Wait -PassThru -ArgumentList @(
    '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$Log`""
  )
  if ($run.ExitCode -ne 0) {
    Get-Content -LiteralPath $Log -Tail 60 -ErrorAction SilentlyContinue
    throw "smoke: $(Split-Path -Leaf $Path) exited with $($run.ExitCode)"
  }
}

# Processes running the executable at exactly $Path.
function Get-ProcessAt([string]$Path) {
  @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Path)) -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $Path })
}

function Assert-Installed {
  & python $winlinux layout $app --os windows
  Expect ((Get-RegValue $uninstallKey 'InstallLocation') -eq "$app\") "Installed apps names $(Get-RegValue $uninstallKey 'InstallLocation'), not $app\"
}

# 1. Install.
Log "installing $(Split-Path -Leaf $Installer) for this user"
Invoke-Setup $Installer (Join-Path $Work 'install.log')
Assert-Installed
Log 'registrations (HKCU)'
Expect ((Get-RegValue "$classes\conduit") -eq 'URL:Conduit') 'conduit: is not a URL scheme'
Expect (Test-RegValue "$classes\conduit" 'URL Protocol') 'conduit: has no "URL Protocol" value'
foreach ($key in "$classes\conduit", "$classes\Conduit.File", "$classes\Applications\conduit-desktop.exe") {
  $opens = Get-RegValue "$key\shell\open\command"
  Expect ($opens -eq $command) "$key opens '$opens', not '$command'"
}
foreach ($ext in $extensions) {
  Expect (Test-RegValue "$classes\$ext\OpenWithProgids" 'Conduit.File') "$ext has no Open With entry"
  Expect (Test-RegValue "$classes\Applications\conduit-desktop.exe\SupportedTypes" $ext) "$ext is not among SupportedTypes"
  Expect ((Get-RegValue "$classes\$ext") -ne 'Conduit.File') "the installer made Conduit the default app for $ext"
}
Expect (-not (Test-Path -LiteralPath 'HKLM:\Software\Classes\Conduit.File')) 'Conduit.File is registered for the machine (HKLM)'
Expect (Test-Path -LiteralPath $shortcut) "no Start menu entry at $shortcut"
$target = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut).TargetPath
Expect ($target -eq $exe) "the Start menu entry opens $target, not $exe"
Log "$($extensions.Count) file types, conduit:// and the Start menu entry"

# 2. The installed app.
$env:CONDUITD_PATH = $null
$env:CONDUIT_FLAVOR = 'dev'
$env:CONDUIT_USER_DATA = Join-Path $Work 'harness-check\user-data'
$env:CONDUIT_LOGS = Join-Path $Work 'harness-check\logs'
foreach ($flag in '--e2e', '--capture', '--probe', '--fixture', '--chat-fixture') {
  $run = Start-Process -FilePath $exe -ArgumentList $flag, 'x' -Wait -PassThru
  Expect ($run.ExitCode -eq 64) "$flag x: exit $($run.ExitCode), not 64 (a build without the test harness refuses it)"
}
$env:CONDUIT_FLAVOR = $null
Log 'refuses --e2e, --capture, --probe, --fixture, --chat-fixture (exit 64)'

$env:CONDUIT_USER_DATA = Join-Path $Work 'smoke\user-data'
$env:CONDUIT_LOGS = Join-Path $Work 'smoke\logs'
$report = Join-Path $Work 'smoke\report.txt'
if ($UpdateFeed) {
  $UpdateFeed = (Resolve-Path -LiteralPath $UpdateFeed).ProviderPath
  Expect (Test-Path -LiteralPath (Join-Path $UpdateFeed 'appcast-windows.xml')) "no appcast-windows.xml in $UpdateFeed"
}
$server = $null
# The feed server, when there is one, is stopped however this step ends.
try {
  if ($UpdateFeed) {
    $server = Start-Process -FilePath python -PassThru -NoNewWindow -ArgumentList @(
      '-m', 'http.server', $UpdateFeedPort, '--bind', '127.0.0.1', '--directory', "`"$UpdateFeed`""
    ) -RedirectStandardOutput (Join-Path $Work 'feed-server.out') -RedirectStandardError (Join-Path $Work 'feed-server.log')
    # The pass checks once it has connected; the server answers well before.
    $feedUrl = "http://127.0.0.1:$UpdateFeedPort/appcast-windows.xml"
    $served = $false
    foreach ($try in 1..50) {
      try { Invoke-WebRequest -Uri $feedUrl -UseBasicParsing | Out-Null; $served = $true; break } catch { Start-Sleep -Milliseconds 200 }
    }
    Expect $served "the update feed in $UpdateFeed isn't served at $feedUrl"
    Log "serving $UpdateFeed at $feedUrl for WinSparkle's check"
  }
  Log "the app's --smoke pass (profile in $Work\smoke)"
  $run = Start-Process -FilePath $exe -ArgumentList '--smoke', "`"$report`"" -Wait -PassThru
} finally {
  if ($server) { Stop-Process -Id $server.Id -ErrorAction SilentlyContinue }
}
$lines = @(Get-Content -LiteralPath $report -ErrorAction SilentlyContinue)
$lines | ForEach-Object { Write-Host $_ }
if ($run.ExitCode -ne 0 -or $lines[-1] -ne 'SMOKE passed' -or ($lines -match '^SMOKE FAILED')) {
  Get-ChildItem -LiteralPath $env:CONDUIT_LOGS -Filter '*.log' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "--- $($_.Name)"; Get-Content -LiteralPath $_.FullName -Tail 60 }
  throw "smoke: the app's smoke pass failed (exit $($run.ExitCode))"
}
# Only a packaged release build, with conduitd beside it, runs in the
# production flavour.
Expect ([bool](Select-String -LiteralPath (Join-Path $env:CONDUIT_LOGS 'conduit-desktop.log') `
    -Pattern 'Conduit Desktop .* \(Production\), userData ' -Quiet)) `
  "the installed app didn't run in the production flavour (it found no packaged conduitd)"
Expect ((Get-ProcessAt $daemon).Count -eq 0) "a conduitd from $app still runs after the app quit"
Log 'smoke passed; no conduitd left'
if ($UpdateFeed) {
  Expect ($lines -contains 'SMOKE update check: up to date') `
    "WinSparkle didn't read the served feed and find nothing newer (see the report)"
  Log 'WinSparkle loaded and read the feed: nothing newer'
}

# 3. Install again over the running app.
$env:CONDUIT_USER_DATA = Join-Path $Work 'running\user-data'
$env:CONDUIT_LOGS = Join-Path $Work 'running\logs'
# The app's conduitd starting is the event to wait for (process start
# traces need an administrator, which CI's runner is).
Register-CimIndicationEvent -SourceIdentifier ConduitdStarted `
  -Query "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'conduitd.exe'"
try {
  $running = Start-Process -FilePath $exe -PassThru
  $started = Wait-Event -SourceIdentifier ConduitdStarted -Timeout 120
  Expect ([bool]$started) "the app (pid $($running.Id)) started no conduitd in 2 minutes"
} finally {
  Unregister-Event -SourceIdentifier ConduitdStarted
}
Expect ((Get-ProcessAt $daemon).Count -eq 1) 'the running app has no conduitd from the install folder'
$updateArgs = @((& python $feedTool installer-arguments) -split ' ')
Log "installing again over the running app (pid $($running.Id)) and its conduitd, as WinSparkle runs an update ($($updateArgs -join ' '))"
$oldDaemons = @(Get-ProcessAt $daemon)
# A process object reads its exit only through a handle opened while it ran.
foreach ($p in @($running) + $oldDaemons) { $null = $p.Handle }
# The app the update starts again is the setup's: setup.exe starts its .tmp,
# which starts the app. Every start of either kind is traced, and the one
# whose parent is the setup or its .tmp is the app to check and to stop
# (only a process this smoke started, never one found by its path).
Register-CimIndicationEvent -SourceIdentifier UpdateStarts `
  -Query "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'conduit-desktop.exe' OR ProcessName LIKE '%.tmp'"
$relaunched = $null
try {
  $log = Join-Path $Work 'reinstall.log'
  # Not -Wait: that waits for the setup's descendants, and the app it
  # starts again is one of them.
  $setup = Start-Process -FilePath $Installer -PassThru -ArgumentList ($updateArgs + "/LOG=`"$log`"")
  $null = $setup.Handle
  $setup.WaitForExit()
  if ($setup.ExitCode -ne 0) {
    Get-Content -LiteralPath $log -Tail 60 -ErrorAction SilentlyContinue
    throw "smoke: the update install exited with $($setup.ExitCode)"
  }
  Expect ($running.HasExited) 'the app the update replaced still runs'
  Expect (@($oldDaemons | Where-Object { -not $_.HasExited }).Count -eq 0) 'its conduitd still runs after the update replaced it'
  $family = @{ [int]$setup.Id = $true }
  $deadline = [DateTime]::UtcNow.AddMinutes(2)
  while (-not $relaunched -and [DateTime]::UtcNow -lt $deadline) {
    $null = Wait-Event -SourceIdentifier UpdateStarts -Timeout 5
    foreach ($queued in @(Get-Event -SourceIdentifier UpdateStarts -ErrorAction SilentlyContinue)) {
      $started = $queued.SourceEventArgs.NewEvent
      if ($family.ContainsKey([int]$started.ParentProcessID)) {
        $family[[int]$started.ProcessID] = $true
        if ($started.ProcessName -eq 'conduit-desktop.exe') { $relaunched = [int]$started.ProcessID }
      }
      Remove-Event -EventIdentifier $queued.EventIdentifier
    }
  }
} finally {
  Unregister-Event -SourceIdentifier UpdateStarts
}
Expect ([bool]$relaunched) "the update (pid $($setup.Id)) started no app in 2 minutes"
$again = Get-Process -Id $relaunched -ErrorAction SilentlyContinue
Expect ([bool]$again) "the app the update started (pid $relaunched) has already ended"
$null = $again.Handle
Expect ($again.Path -eq $exe) "the update started $($again.Path) (pid $relaunched), not $exe"
Assert-Installed
Log "the installer closed the app and its conduitd, replaced the files and started the app again (pid $relaunched, from setup pid $($setup.Id))"
Stop-Process -Id $relaunched
$again.WaitForExit()
# Its job object ends its conduitd with it.
$left = @(Get-ProcessAt $daemon)
$left | ForEach-Object { $null = $_.Handle; $_.WaitForExit(30000) | Out-Null }
Expect (@($left | Where-Object { -not $_.HasExited }).Count -eq 0) 'the started app left a conduitd running'

# 4. Uninstall.
$keep = Join-Path $env:LOCALAPPDATA 'Conduit\User Data\smoke-keep.txt'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $keep) | Out-Null
Set-Content -LiteralPath $keep -Value 'the uninstaller keeps the user data'
$uninstaller = (Get-RegValue $uninstallKey 'UninstallString').Trim('"')
Log "uninstalling ($uninstaller)"
Invoke-Setup $uninstaller (Join-Path $Work 'uninstall.log')
& python $winlinux gone $app $shortcut
foreach ($key in $ownedKeys) {
  Expect (-not (Test-Path -LiteralPath $key)) "$key is still there"
}
foreach ($ext in $extensions) {
  Expect (-not (Test-RegValue "$classes\$ext\OpenWithProgids" 'Conduit.File')) "$ext still lists Conduit.File"
}
Expect (Test-Path -LiteralPath $keep) "the uninstall removed the user's data ($keep)"
Log 'uninstalled: no files or registrations left; the user data stays'
Log 'smoke passed'
