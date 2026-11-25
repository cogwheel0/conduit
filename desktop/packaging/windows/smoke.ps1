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
# What the smoke started: its jobs (Start-InJob) and the app the update
# starts again, which Setup starts outside the setup's job, with its
# conduitd (each held by pid and handle). On a failure they end before the
# script does: the failure upload can't zip logs the app still holds open.
$script:toStop = [System.Collections.Generic.List[object]]::new()
trap {
  foreach ($held in $script:toStop) {
    try {
      if ($held.PSObject.Methods['Terminate']) { $held.Terminate() }
      elseif (-not $held.HasExited) { $held.Kill(); $null = $held.WaitForExit(10000) }
    } catch { }
  }
  break
}

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

# Starts $Path in a job object of its own, suspended until it is in the job,
# as Start-Process -Wait does: what it starts is in the job too, so the job
# is waited for and ended as one. The exception is the app an update's
# Setup starts again, which runs outside the setup's job. WaitForAll waits
# for the whole job, WaitForExit for the started process alone, and
# Terminate ends the job.
function Start-InJob([string]$Path, [string[]]$Arguments) {
  if (-not ('SmokeJob' -as [type])) {
    Add-Type -TypeDefinition @'
using System; using System.ComponentModel; using System.Runtime.InteropServices; using System.Text; using System.Threading;
public sealed class SmokeJob {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  struct StartupInfo { public int cb; public string reserved, desktop, title;
    public int x, y, xSize, ySize, xChars, yChars, fill, flags; public short show, reserved2;
    public IntPtr reserved3, stdIn, stdOut, stdErr; }
  [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr process, thread; public int pid, tid; }
  [StructLayout(LayoutKind.Sequential)] struct Accounting { public long user, kernel, periodUser, periodKernel; public uint faults, total, active, terminated; }
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern IntPtr CreateJobObject(IntPtr attributes, string name);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool CreateProcess(string app, StringBuilder cmd,
    IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string dir, ref StartupInfo si, out ProcessInfo pi);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(IntPtr job, int cls, out Accounting info, int size, IntPtr ret);
  [DllImport("kernel32.dll")] static extern bool TerminateJobObject(IntPtr job, uint code);
  [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr process, uint code);
  [DllImport("kernel32.dll")] static extern uint ResumeThread(IntPtr thread);
  [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint ms);
  [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
  readonly IntPtr job, process;
  public readonly int Id;
  public SmokeJob(string commandLine, string directory) {
    job = CreateJobObject(IntPtr.Zero, null);
    if (job == IntPtr.Zero) throw new Win32Exception();
    var si = new StartupInfo(); si.cb = Marshal.SizeOf(typeof(StartupInfo));
    ProcessInfo pi;
    // CREATE_SUSPENDED | CREATE_NEW_CONSOLE, as Start-Process.
    if (!CreateProcess(null, new StringBuilder(commandLine), IntPtr.Zero, IntPtr.Zero, false, 0x14, IntPtr.Zero, directory, ref si, out pi))
      throw new Win32Exception();
    if (!AssignProcessToJobObject(job, pi.process)) {
      var error = new Win32Exception();
      TerminateProcess(pi.process, 1);
      throw error;
    }
    ResumeThread(pi.thread);
    CloseHandle(pi.thread);
    process = pi.process;
    Id = pi.pid;
  }
  public int Active { get {
    Accounting a;
    if (!QueryInformationJobObject(job, 1, out a, Marshal.SizeOf(typeof(Accounting)), IntPtr.Zero)) throw new Win32Exception();
    return (int)a.active;
  } }
  public bool WaitForAll(int ms) {
    var end = DateTime.UtcNow.AddMilliseconds(ms);
    while (Active > 0) { if (DateTime.UtcNow >= end) return false; Thread.Sleep(250); }
    return true;
  }
  public bool WaitForExit(int ms) { return WaitForSingleObject(process, (uint)ms) == 0; }
  public int ExitCode { get { uint code; GetExitCodeProcess(process, out code); return (int)code; } }
  public void Terminate() { TerminateJobObject(job, 1); WaitForAll(10000); }
}
'@
  }
  $job = [SmokeJob]::new("`"$Path`" $($Arguments -join ' ')", (Get-Location).ProviderPath)
  if ($null -ne $script:toStop) { $script:toStop.Add($job) }
  $job
}

# Starts $Path and waits for it and every process it starts (its job), at
# most $Minutes; returns its exit code. Past the limit it shows what may
# hold it up ($Log among it), ends the whole job, and fails.
function Invoke-Bounded([string]$Path, [string[]]$Arguments, [int]$Minutes, [string]$Log) {
  $job = Start-InJob $Path $Arguments
  if (-not $job.WaitForAll($Minutes * 60 * 1000)) {
    Show-Stuck $Log
    $job.Terminate()
    throw "smoke: $(Split-Path -Leaf $Path) $($Arguments -join ' ') didn't end within $Minutes minutes; it and every process it started are ended"
  }
  $job.ExitCode
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

# The executable a process this smoke holds runs, once it reads: Path is its
# main module's file, which a process only just started may not report yet.
# Tried for up to 5 s; nothing (and the check after it fails) if it never reads.
function Get-StartedPath([System.Diagnostics.Process]$Process) {
  foreach ($try in 1..50) {
    $Process.Refresh()
    $path = $Process.Path
    if ($path) { return $path }
    Start-Sleep -Milliseconds 100
  }
  return $null
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
# The app's conduitd starting is the event to wait for: the start trace of
# a conduitd whose parent is the app this smoke started (process start
# traces need an administrator, which CI's runner is).
Register-CimIndicationEvent -SourceIdentifier ConduitdStarted `
  -Query "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName = 'conduitd.exe'"
try {
  $running = Get-Process -Id (Start-InJob $exe @()).Id
  $null = $running.Handle
  $daemonId = $null
  $deadline = [DateTime]::UtcNow.AddMinutes(2)
  while (-not $daemonId -and [DateTime]::UtcNow -lt $deadline) {
    $queued = Wait-Event -SourceIdentifier ConduitdStarted -Timeout 5
    if ($queued) {
      Remove-Event -EventIdentifier $queued.EventIdentifier
      if ([int]$queued.SourceEventArgs.NewEvent.ParentProcessID -eq $running.Id) {
        $daemonId = [int]$queued.SourceEventArgs.NewEvent.ProcessID
      }
    }
  }
  Expect ([bool]$daemonId) "the app (pid $($running.Id)) started no conduitd in 2 minutes"
} finally {
  Unregister-Event -SourceIdentifier ConduitdStarted
}
$runningDaemon = Get-Process -Id $daemonId -ErrorAction SilentlyContinue
Expect ([bool]$runningDaemon) "the running app's conduitd (pid $daemonId) has already ended"
$null = $runningDaemon.Handle
$daemonPath = Get-StartedPath $runningDaemon
Expect ($daemonPath -eq $daemon) "the running app's conduitd (pid $daemonId) is $daemonPath, not $daemon"
$updateArgs = @((& python $feedTool installer-arguments) -split ' ')
Log "installing again over the running app (pid $($running.Id)) and its conduitd (pid $daemonId), as WinSparkle runs an update ($($updateArgs -join ' '))"
$oldDaemons = @($runningDaemon)
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
  # The setup alone is waited for: the app it starts again runs on. Past
  # the limit its job ends: the setup and what it started there.
  $setup = Start-InJob $Installer ($updateArgs + "/LOG=`"$log`"")
  if (-not $setup.WaitForExit(5 * 60 * 1000)) {
    Show-Stuck $log
    $setup.Terminate()
    throw "smoke: the update install (pid $($setup.Id)) didn't end within 5 minutes; it and the processes in its job are ended"
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
# Held for the cleanup first, so a check that fails below still ends it.
$again = Get-Process -Id $relaunched -ErrorAction SilentlyContinue
Expect ([bool]$again) "the app the update started (pid $relaunched) has already ended"
$null = $again.Handle
$script:toStop.Add($again)
Expect ([bool]$relaunchedDaemon) "the app the update started (pid $relaunched) started no conduitd in 2 minutes"
$againPath = Get-StartedPath $again
Expect ($againPath -eq $exe) "the update started $againPath (pid $relaunched), not $exe"
$againDaemon = Get-Process -Id $relaunchedDaemon -ErrorAction SilentlyContinue
Expect ([bool]$againDaemon) "the started app's conduitd (pid $relaunchedDaemon) has already ended"
$null = $againDaemon.Handle
$script:toStop.Add($againDaemon)
$againDaemonPath = Get-StartedPath $againDaemon
Expect ($againDaemonPath -eq $daemon) "the started app ran $againDaemonPath (pid $relaunchedDaemon), not $daemon"
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
