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
   the installer closes the app and its conduitd (Restart Manager, over
   the processes running from the install folder only), replaces the files
   and starts the app again. It waits for the app's
   conduitd, and for the new app and its conduitd, through process start
   traces, which need an administrator (CI's runner user is one).
4. Uninstalls silently while that app and its conduitd run: the uninstall
   closes both (as the installer does), then the install
   folder, the Start menu entry and every registration are gone, and the
   user's data folder is still there.

It installs into this user's %LOCALAPPDATA%\Programs\Conduit and
uninstalls it at the end: run it only where that is wanted. Every app run
uses a profile in -Work (default: a new folder in %TEMP%).

Every wait has a limit. Past one, it prints (and saves in -Work\stuck.txt)
the log's tail, the processes running from the install folder and what
Restart Manager says has its files open, then fails.
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

# The processes Restart Manager says have the .exe and .dll files under
# $Dir open, one line each (pid, kind, image).
function Get-FileHolders([string]$Dir) {
  if (-not ('SmokeRm' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class SmokeRm {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct Info { public int Pid; public uint StartLow; public uint StartHigh;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string App;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string Service;
    public int Type; public uint Status; public uint Session; public int Restartable; }
  [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmStartSession(out uint h, int f, StringBuilder key);
  [DllImport("rstrtmgr.dll")] static extern int RmEndSession(uint h);
  [DllImport("rstrtmgr.dll", CharSet = CharSet.Unicode)] static extern int RmRegisterResources(uint h, uint n, string[] files, uint na, IntPtr a, uint ns, IntPtr s);
  [DllImport("rstrtmgr.dll")] static extern int RmGetList(uint h, out uint needed, ref uint n, [In, Out] Info[] info, ref uint reasons);
  public static List<string> List(string[] files) {
    var lines = new List<string>(); uint h, needed = 0, n = 0, reasons = 0;
    if (RmStartSession(out h, 0, new StringBuilder(64)) != 0) { lines.Add("(no Restart Manager session)"); return lines; }
    try {
      int r = RmRegisterResources(h, (uint)files.Length, files, 0, IntPtr.Zero, 0, IntPtr.Zero);
      Info[] infos = null;
      if (r == 0) r = RmGetList(h, out needed, ref n, null, ref reasons);
      if (r == 234) { infos = new Info[needed]; n = needed; r = RmGetList(h, out needed, ref n, infos, ref reasons); }
      if (r != 0) { lines.Add("(RmGetList " + r + ")"); return lines; }
      for (int i = 0; i < n; i++) lines.Add(string.Format("pid {0}: {1}{2} (Restart Manager type {3})", infos[i].Pid, infos[i].App,
        infos[i].Service.Length > 0 ? ", service " + infos[i].Service : "", infos[i].Type));
    } finally { RmEndSession(h); }
    return lines;
  }
}
'@
  }
  $files = @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Include '*.exe', '*.dll' -ErrorAction SilentlyContinue | ForEach-Object FullName)
  if ($files.Count -eq 0) { return '(no .exe or .dll files)' }
  [SmokeRm]::List([string[]]$files)
}

# What may hold a setup or the app up: the log's tail, the processes running
# from the install folder and what has its files open. Also in stuck.txt,
# which the failed job uploads with the rest of -Work.
function Show-Stuck([string]$Log) {
  & {
    if ($Log) { "--- the end of $Log"; Get-Content -LiteralPath $Log -Tail 60 -ErrorAction SilentlyContinue }
    "--- processes running from $app"
    Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -like "$app\*" } |
      ForEach-Object { "pid $($_.ProcessId) (parent $($_.ParentProcessId)): $($_.ExecutablePath)" }
    "--- what has the .exe and .dll files under $app open (Restart Manager)"
    try { Get-FileHolders $app } catch { "(couldn't ask: $($_.Exception.Message))" }
  } | Tee-Object -FilePath (Join-Path $Work 'stuck.txt') | ForEach-Object { Write-Host $_ }
}

# Starts $Path and waits for it and every process it starts, as
# Start-Process -Wait does, at most $Minutes; returns its exit code. The
# tree is the started process and, by parent pid, each process started from
# one of the tree since (a setup's second phase, the app's conduitd). Past
# the limit it shows what may hold it up ($Log among it), ends that tree,
# through the process objects it holds, and fails.
function Invoke-Bounded([string]$Path, [string[]]$Arguments, [int]$Minutes, [string]$Log) {
  $root = Start-Process -FilePath $Path -ArgumentList $Arguments -PassThru
  $null = $root.Handle
  $tree = @{ [int]$root.Id = $root }
  $deadline = [DateTime]::UtcNow.AddMinutes($Minutes)
  while ($true) {
    foreach ($process in @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, CreationDate)) {
      $id = [int]$process.ProcessId
      $parent = $tree[[int]$process.ParentProcessId]
      # Not one already held, and started by a member while it ran (its pid
      # may have gone to another program since).
      if ($tree.ContainsKey($id) -or -not $parent -or $process.CreationDate -lt $parent.StartTime -or
        ($parent.HasExited -and $process.CreationDate -gt $parent.ExitTime)) { continue }
      $child = Get-Process -Id $id -ErrorAction SilentlyContinue
      if ($child) { $null = $child.Handle; $tree[$id] = $child }
    }
    if (@($tree.Values | Where-Object { -not $_.HasExited }).Count -eq 0) { return $root.ExitCode }
    if ([DateTime]::UtcNow -ge $deadline) { break }
    Start-Sleep -Milliseconds 250
  }
  Show-Stuck $Log
  foreach ($process in $tree.Values) {
    if (-not $process.HasExited) { $process.Kill(); $null = $process.WaitForExit(10000) }
  }
  throw "smoke: $(Split-Path -Leaf $Path) $($Arguments -join ' ') didn't end within $Minutes minutes (it and the $($tree.Count - 1) processes it started are stopped)"
}

# Runs the installer or uninstaller silently and waits for it, its second
# phase included, at most 5 minutes.
function Invoke-Setup([string]$Path, [string]$Log) {
  $code = Invoke-Bounded $Path @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$Log`"") 5 $Log
  if ($code -ne 0) {
    Get-Content -LiteralPath $Log -Tail 60 -ErrorAction SilentlyContinue
    throw "smoke: $(Split-Path -Leaf $Path) exited with $code"
  }
}

# The setup log's Restart Manager lines: whom it closed, whom it left alone.
function Show-RestartManager([string]$Log) {
  Select-String -LiteralPath $Log -Pattern 'Restart Manager' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "    $($_.Line -replace '^\S+ \S+\s+', '')" }
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
  $code = Invoke-Bounded $exe @($flag, 'x') 2
  Expect ($code -eq 64) "$flag x: exit $code, not 64 (a build without the test harness refuses it)"
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
  $code = Invoke-Bounded $exe @('--smoke', "`"$report`"") 5 (Join-Path $env:CONDUIT_LOGS 'conduit-desktop.log')
} finally {
  if ($server) { Stop-Process -Id $server.Id -ErrorAction SilentlyContinue }
}
$lines = @(Get-Content -LiteralPath $report -ErrorAction SilentlyContinue)
$lines | ForEach-Object { Write-Host $_ }
if ($code -ne 0 -or $lines[-1] -ne 'SMOKE passed' -or ($lines -match '^SMOKE FAILED')) {
  Get-ChildItem -LiteralPath $env:CONDUIT_LOGS -Filter '*.log' -ErrorAction SilentlyContinue |
    ForEach-Object { Write-Host "--- $($_.Name)"; Get-Content -LiteralPath $_.FullName -Tail 60 }
  throw "smoke: the app's smoke pass failed (exit $code)"
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
# which starts the app, which starts its conduitd. Every start of those
# kinds is traced, and the ones descending from the setup are the app and
# the conduitd to check and to uninstall under (only processes this smoke
# started, never ones found by their path).
Register-CimIndicationEvent -SourceIdentifier UpdateStarts `
  -Query "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'conduit-desktop.exe' OR ProcessName = 'conduitd.exe' OR ProcessName LIKE '%.tmp'"
$relaunched = $null
$relaunchedDaemon = $null
try {
  $log = Join-Path $Work 'reinstall.log'
  # Not -Wait: that waits for the setup's descendants, and the app it
  # starts again is one of them.
  $setup = Start-Process -FilePath $Installer -PassThru -ArgumentList ($updateArgs + "/LOG=`"$log`"")
  $null = $setup.Handle
  if (-not $setup.WaitForExit(5 * 60 * 1000)) {
    Show-Stuck $log
    throw "smoke: the update install (pid $($setup.Id)) didn't end within 5 minutes"
  }
  if ($setup.ExitCode -ne 0) {
    Get-Content -LiteralPath $log -Tail 60 -ErrorAction SilentlyContinue
    throw "smoke: the update install exited with $($setup.ExitCode)"
  }
  Expect ($running.HasExited) 'the app the update replaced still runs'
  Expect (@($oldDaemons | Where-Object { -not $_.HasExited }).Count -eq 0) 'its conduitd still runs after the update replaced it'
  $family = @{ [int]$setup.Id = $true }
  # Trace events may arrive out of order, so a start whose parent isn't
  # known yet waits here and is matched once that parent joins.
  $unmatched = [System.Collections.Generic.List[object]]::new()
  $deadline = [DateTime]::UtcNow.AddMinutes(2)
  while (-not $relaunchedDaemon -and [DateTime]::UtcNow -lt $deadline) {
    $null = Wait-Event -SourceIdentifier UpdateStarts -Timeout 5
    foreach ($queued in @(Get-Event -SourceIdentifier UpdateStarts -ErrorAction SilentlyContinue)) {
      $unmatched.Add($queued.SourceEventArgs.NewEvent)
      Remove-Event -EventIdentifier $queued.EventIdentifier
    }
    do {
      $joined = $false
      # ToArray, not @(): PowerShell 7.4's @() can throw on a List[object].
      foreach ($started in $unmatched.ToArray()) {
        if ($family.ContainsKey([int]$started.ParentProcessID)) {
          $family[[int]$started.ProcessID] = $true
          if ($started.ProcessName -eq 'conduit-desktop.exe') { $relaunched = [int]$started.ProcessID }
          if ($started.ProcessName -eq 'conduitd.exe' -and $relaunched -and [int]$started.ParentProcessID -eq $relaunched) {
            $relaunchedDaemon = [int]$started.ProcessID
          }
          $null = $unmatched.Remove($started)
          $joined = $true
        }
      }
    } while ($joined -and -not $relaunchedDaemon)
  }
} finally {
  Unregister-Event -SourceIdentifier UpdateStarts
}
Expect ([bool]$relaunched) "the update (pid $($setup.Id)) started no app in 2 minutes"
Expect ([bool]$relaunchedDaemon) "the app the update started (pid $relaunched) started no conduitd in 2 minutes"
$again = Get-Process -Id $relaunched -ErrorAction SilentlyContinue
Expect ([bool]$again) "the app the update started (pid $relaunched) has already ended"
$null = $again.Handle
Expect ($again.Path -eq $exe) "the update started $($again.Path) (pid $relaunched), not $exe"
$againDaemon = Get-Process -Id $relaunchedDaemon -ErrorAction SilentlyContinue
Expect ([bool]$againDaemon) "the started app's conduitd (pid $relaunchedDaemon) has already ended"
$null = $againDaemon.Handle
Expect ($againDaemon.Path -eq $daemon) "the started app ran $($againDaemon.Path) (pid $relaunchedDaemon), not $daemon"
Assert-Installed
Show-RestartManager $log
Expect ([bool](Select-String -LiteralPath $log -Pattern 'Restart Manager closed [1-9]\d* Conduit processes: status 0$' -Quiet)) `
  "the update's Restart Manager didn't close the app and its conduitd (see $log)"
Log "the installer closed the app and its conduitd, replaced the files and started the app again (pid $relaunched, its conduitd pid $relaunchedDaemon, from setup pid $($setup.Id))"

# 4. Uninstall while that app and its conduitd run.
$keep = Join-Path $env:LOCALAPPDATA 'Conduit\User Data\smoke-keep.txt'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $keep) | Out-Null
Set-Content -LiteralPath $keep -Value 'the uninstaller keeps the user data'
$uninstaller = (Get-RegValue $uninstallKey 'UninstallString').Trim('"')
$uninstallLog = Join-Path $Work 'uninstall.log'
Log "uninstalling ($uninstaller) while the app (pid $relaunched) and its conduitd (pid $relaunchedDaemon) run"
Invoke-Setup $uninstaller $uninstallLog
Show-RestartManager $uninstallLog
Expect ([bool](Select-String -LiteralPath $uninstallLog -Pattern 'Restart Manager closed [1-9]\d* Conduit processes: status 0$' -Quiet)) `
  "the uninstall's Restart Manager didn't close the app and its conduitd (see $uninstallLog)"
foreach ($p in $again, $againDaemon) { $p.WaitForExit(30000) | Out-Null }
Expect ($again.HasExited) "the uninstall left the app (pid $relaunched) running"
Expect ($againDaemon.HasExited) "the uninstall left its conduitd (pid $relaunchedDaemon) running"
Log 'the uninstall closed the app and its conduitd'
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
