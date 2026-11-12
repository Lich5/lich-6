# Disposable real-dialog experiment. Retire with the testbed after recording its result.
$ErrorActionPreference = 'Stop'
$root = (Get-Location).Path
$artifacts = Join-Path $root 'tmp/windows-webui'
New-Item -ItemType Directory -Force $artifacts | Out-Null
$ruby = (Get-Command ruby).Source
$rubyw = Join-Path (Split-Path $ruby) 'rubyw.exe'
if (-not (Test-Path $rubyw)) { throw 'The selected Ruby has no rubyw.exe' }
foreach ($name in @('RUBYOPT', 'RUBYLIB', 'BUNDLE_GEMFILE', 'BUNDLE_PATH', 'BUNDLER_SETUP', 'RUBYGEMS_GEMDEPS', 'GEM_HOME', 'GEM_PATH')) {
  Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}
$env:LICH_TESTBED_REPAIR_ARTIFACTS = $artifacts
$env:RUBYOPT = '-r' + (Join-Path $root '.github/scripts/testbed_gem_repair_observer.rb').Replace('\', '/')

# Click only a real Yes button owned by an observed experiment Ruby process.
# GetDlgItem/BM_CLICK: https://learn.microsoft.com/en-us/windows/win32/controls/bm-click
Add-Type @'
using System;
using System.Text;
using System.Runtime.InteropServices;
public static class TestbedConsent {
  delegate bool Visitor(IntPtr window, IntPtr data);
  [DllImport("user32.dll")] static extern bool EnumWindows(Visitor visit, IntPtr data);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int size);
  [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr dialog, int id);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
  [DllImport("user32.dll")] static extern bool PostMessage(IntPtr window, uint message, IntPtr w, IntPtr l);
  public static bool Approve(uint process) {
    bool clicked = false;
    EnumWindows((window, data) => {
      uint owner; GetWindowThreadProcessId(window, out owner);
      if (owner != process) return true;
      var title = new StringBuilder(256); GetWindowText(window, title, title.Capacity);
      if (title.ToString() != "Lich5: Ruby Gem Check") return true;
      var yes = GetDlgItem(window, 6);
      if (yes == IntPtr.Zero) return true;
      SetForegroundWindow(window);
      clicked = PostMessage(yes, 0x00F5, IntPtr.Zero, IntPtr.Zero);
      return !clicked;
    }, IntPtr.Zero);
    return clicked;
  }
}
'@

$clicked = [System.Collections.Generic.HashSet[int]]::new()
$experiment = Start-Process -FilePath $rubyw -ArgumentList 'lich.rbw' -WorkingDirectory $root -PassThru -RedirectStandardOutput "$artifacts/startup.stdout.log" -RedirectStandardError "$artifacts/startup.stderr.log"
$deadline = (Get-Date).AddMinutes(10)
try {
  while ((Get-Date) -lt $deadline) {
    foreach ($file in Get-ChildItem $artifacts -Filter 'process-*.txt') {
      $childId = [int]($file.BaseName -replace '^process-', '')
      if (-not $clicked.Contains($childId) -and [TestbedConsent]::Approve($childId)) {
        [void]$clicked.Add($childId)
        "Approved actual gem-repair Yes button for PID $childId" | Tee-Object -FilePath "$artifacts/consent.log" -Append
      }
    }
    if (Test-Path "$artifacts/ready.json") { break }
    Start-Sleep -Seconds 1
  }
  if (-not (Test-Path "$artifacts/ready.json")) { throw 'Production repair/restart did not reach an accepted runtime within ten minutes' }
  $ready = Get-Content "$artifacts/ready.json" -Raw | ConvertFrom-Json
  $initial = Get-Content "$artifacts/policy-$($experiment.Id).json" -Raw | ConvertFrom-Json
  $final = Get-Content "$artifacts/policy-$($ready.pid).json" -Raw | ConvertFrom-Json
  if ($clicked.Count -eq 0 -or @($initial.needed).Count -eq 0) { throw 'No actual repair consent was exercised' }
  if ($ready.pid -eq $experiment.Id -or @($final.needed).Count -ne 0) { throw 'Repair did not restart into a complete accepted gem set' }
  [ordered]@{ verdict='pass'; initial_pid=$experiment.Id; restarted_pid=$ready.pid; approved_pids=@($clicked); initially_needed=@($initial.needed); remaining_needed=@($final.needed); scope='production gem repair and restart; not full WebUI acceptance' } |
    ConvertTo-Json -Depth 6 | Set-Content "$artifacts/repair-result.json"
  'Production consent, gem installation, restart and accepted runtime activation passed.' | Tee-Object -FilePath $env:GITHUB_STEP_SUMMARY -Append
} finally {
  if (Test-Path 'temp/lich5-missing-gems.log') { Copy-Item 'temp/lich5-missing-gems.log' "$artifacts/recovery.log" }
  # Stop only Ruby processes recorded by this experiment's inherited observer.
  foreach ($file in Get-ChildItem $artifacts -Filter 'process-*.txt') {
    $childId = [int]($file.BaseName -replace '^process-', '')
    $child = Get-Process -Id $childId -ErrorAction SilentlyContinue
    if ($child -and $child.Path -in @($ruby, $rubyw)) { Stop-Process -Id $childId -Force -ErrorAction SilentlyContinue }
  }
}
