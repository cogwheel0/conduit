<#
Runs the dev app on Windows: the binary itself (no bundle), with the dev
daemon from `dart build cli` in apps/daemon and the dev paths
(`Conduit Dev`). macOS and Linux use crates/app/run.sh.

  crates\app\run.ps1                         # run the app
  crates\app\run.ps1 -BuildOnly              # build, print the binary
  crates\app\run.ps1 -RegisterScheme         # conduit:// links open this
                                             # build (per-user registry
                                             # keys); only on this command
  crates\app\run.ps1 -RegisterScheme -Force  # ... over another handler
  crates\app\run.ps1 -UnregisterScheme       # undo it
  crates\app\run.ps1 --hidden                # arguments for the app

A scripted run (--e2e, --capture) uses the profile CONDUIT_USER_DATA names,
never the app's own; without one it starts on a fresh profile in %TEMP%.
#>
# A plain script, not an advanced one: arguments it doesn't take (the
# app's `--hidden`, `--e2e`) stay in $args instead of being refused.
param(
  [switch]$BuildOnly,
  [switch]$RegisterScheme,
  [switch]$UnregisterScheme,
  [switch]$Force
)
$AppArgs = @($args)
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..\..')
$bin = Join-Path (Get-Location) 'target\debug\conduit-desktop.exe'
$key = 'HKCU:\Software\Classes\conduit'
$command = "`"$bin`" `"%1`""

# The conduit: handlers registered for this user and for the machine
# (HKCU's wins where both are set; an installer may write HKLM).
function Get-SchemeCommands {
  foreach ($root in @($key, 'HKLM:\Software\Classes\conduit')) {
    $item = Get-ItemProperty -Path "$root\shell\open\command" -ErrorAction SilentlyContinue
    if ($item) { [pscustomobject]@{ Key = $root; Command = $item.'(default)' } }
  }
}

function Get-SchemeCommand {
  $item = Get-ItemProperty -Path "$key\shell\open\command" -ErrorAction SilentlyContinue
  if ($item) { $item.'(default)' } else { $null }
}

if ($UnregisterScheme) {
  # Only this build's keys: a handler another build or an install wrote stays.
  if ((Get-SchemeCommand) -eq $command) {
    Remove-Item -Path $key -Recurse
    "conduit:// links no longer open $bin"
  } else {
    'conduit:// is not registered to this build; nothing changed'
  }
  exit 0
}

cargo build -p conduit-desktop --features harness
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

if ($BuildOnly) {
  $bin
  exit 0
}

if ($RegisterScheme) {
  # Any handler that isn't this checkout's, per user or for the machine.
  $other = @(Get-SchemeCommands | Where-Object { $_.Command -ne $command }) | Select-Object -First 1
  if ($other -and -not $Force) {
    Write-Error "conduit:// links open $($other.Command) ($($other.Key)); add -Force to point them at this build"
  }
  New-Item -Path "$key\shell\open\command" -Force | Out-Null
  New-Item -Path "$key\DefaultIcon" -Force | Out-Null
  Set-ItemProperty -Path $key -Name '(default)' -Value 'URL:Conduit Dev'
  Set-ItemProperty -Path $key -Name 'URL Protocol' -Value ''
  Set-ItemProperty -Path "$key\DefaultIcon" -Name '(default)' -Value "`"$bin`",0"
  Set-ItemProperty -Path "$key\shell\open\command" -Name '(default)' -Value $command
  "conduit:// links now open $bin"
  exit 0
}

New-Item -ItemType Directory -Force -Path 'target\app' | Out-Null
$log = 'target\app\last-run.log'
# An E2E pass reads aloud into a null sink, as on the Mac.
if ($AppArgs -contains '--e2e' -and -not $env:CONDUIT_SPEECH_OUTPUT) {
  $env:CONDUIT_SPEECH_OUTPUT = 'null'
}
# The app's stderr is its log, not a failure of this script.
$ErrorActionPreference = 'Continue'
& $bin @AppArgs 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $log
# The app's own exit code (a refused flag is 64, a panic is not 0).
$code = $LASTEXITCODE
if (Select-String -Path $log -Pattern 'SMOKE FAILED' -Quiet) { exit 1 }
if ($null -eq $code) { exit 1 }
exit $code
