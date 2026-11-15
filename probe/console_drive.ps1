# Drives a real Windows console: starts a command in a new console, waits for
# a prompt on screen, types into the console input buffer, and reads the screen
# back. GitHub runners give jobs no interactive console, so this is the only
# way to see what a user typing at cmd or PowerShell would see.
$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class ConsoleDriver {
  const uint GENERIC_READ = 0x80000000, GENERIC_WRITE = 0x40000000;
  const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, OPEN_EXISTING = 3;

  [StructLayout(LayoutKind.Sequential)] public struct COORD { public short X; public short Y; }
  [StructLayout(LayoutKind.Sequential)] public struct SMALL_RECT { public short Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct CSBI {
    public COORD dwSize; public COORD dwCursorPosition; public ushort wAttributes;
    public SMALL_RECT srWindow; public COORD dwMaximumWindowSize;
  }
  [StructLayout(LayoutKind.Explicit, CharSet = CharSet.Unicode)]
  public struct INPUT_RECORD {
    [FieldOffset(0)] public ushort EventType;
    [FieldOffset(4)] public int bKeyDown;
    [FieldOffset(8)] public ushort wRepeatCount;
    [FieldOffset(10)] public ushort wVirtualKeyCode;
    [FieldOffset(12)] public ushort wVirtualScanCode;
    [FieldOffset(14)] public char UnicodeChar;
    [FieldOffset(16)] public uint dwControlKeyState;
  }

  [DllImport("kernel32.dll", SetLastError = true)] static extern bool FreeConsole();
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool AttachConsole(uint pid);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr sec, uint disp, uint flags, IntPtr tmpl);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr h);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern bool WriteConsoleInputW(IntPtr h, INPUT_RECORD[] recs, uint n, out uint written);
  [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetConsoleScreenBufferInfo(IntPtr h, out CSBI info);
  [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
  static extern bool ReadConsoleOutputCharacterW(IntPtr h, [Out] char[] buf, uint len, COORD at, out uint read);

  static IntPtr Open(string name) {
    return CreateFileW(name, GENERIC_READ | GENERIC_WRITE, FILE_SHARE_READ | FILE_SHARE_WRITE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
  }

  static string Screen() {
    IntPtr h = Open("CONOUT$");
    if (h == new IntPtr(-1)) return "<CONOUT$ failed " + Marshal.GetLastWin32Error() + ">";
    try {
      CSBI info;
      if (!GetConsoleScreenBufferInfo(h, out info)) return "<CSBI failed " + Marshal.GetLastWin32Error() + ">";
      int width = info.dwSize.X;
      var sb = new StringBuilder();
      var line = new char[width];
      for (short y = 0; y <= info.dwCursorPosition.Y; y++) {
        uint read; COORD at; at.X = 0; at.Y = y;
        ReadConsoleOutputCharacterW(h, line, (uint)width, at, out read);
        sb.Append(new string(line, 0, (int)read).TrimEnd()).Append('\n');
      }
      return sb.ToString();
    } finally { CloseHandle(h); }
  }

  static INPUT_RECORD Key(char c, bool down) {
    var r = new INPUT_RECORD();
    r.EventType = 1; r.bKeyDown = down ? 1 : 0; r.wRepeatCount = 1; r.UnicodeChar = c;
    if (c == '\r') r.wVirtualKeyCode = 0x0D;
    else if (c == '\x1A') { r.wVirtualKeyCode = 0x5A; r.dwControlKeyState = 0x0008; }
    else if (c == ' ') r.wVirtualKeyCode = 0x20;
    else if (char.IsLetterOrDigit(c)) r.wVirtualKeyCode = (ushort)char.ToUpperInvariant(c);
    return r;
  }

  static string Type(string text) {
    IntPtr h = Open("CONIN$");
    if (h == new IntPtr(-1)) return "CONIN$ failed " + Marshal.GetLastWin32Error();
    try {
      var recs = new INPUT_RECORD[text.Length * 2];
      for (int i = 0; i < text.Length; i++) { recs[2 * i] = Key(text[i], true); recs[2 * i + 1] = Key(text[i], false); }
      uint written;
      if (!WriteConsoleInputW(h, recs, (uint)recs.Length, out written)) return "WriteConsoleInput failed " + Marshal.GetLastWin32Error();
      return "typed " + written + " records";
    } finally { CloseHandle(h); }
  }

  public static string Run(string file, string args, string dir, string waitFor, string input, int timeoutMs) {
    return Run2(file, args, dir, null, null, waitFor, input, timeoutMs);
  }

  public static string Run2(string file, string args, string dir, string preWait, string preInput, string waitFor, string input, int timeoutMs) {
    var psi = new ProcessStartInfo(file, args);
    psi.UseShellExecute = true;           // a console program started this way gets a new console
    psi.WorkingDirectory = dir;
    var p = Process.Start(psi);
    FreeConsole();
    var deadline = DateTime.UtcNow.AddMilliseconds(timeoutMs);
    bool attached = false;
    while (!attached && DateTime.UtcNow < deadline) {
      attached = AttachConsole((uint)p.Id);
      if (!attached) Thread.Sleep(100);
    }
    if (!attached) return "ATTACH_FAILED=" + Marshal.GetLastWin32Error();
    string screen = "";
    string preTyped = "none";
    if (preWait != null) {
      while (DateTime.UtcNow < deadline) {
        screen = Screen();
        if (screen.Contains(preWait) || p.HasExited) break;
        Thread.Sleep(100);
      }
      if (screen.Contains(preWait)) preTyped = Type(preInput);
    }
    while (DateTime.UtcNow < deadline) {
      screen = Screen();
      if (screen.Contains(waitFor) || p.HasExited) break;
      Thread.Sleep(250);
    }
    bool sawPrompt = screen.Contains(waitFor);
    string typed = "not typed";
    if (sawPrompt) { Thread.Sleep(750); typed = Type(input); }
    int left = (int)(deadline - DateTime.UtcNow).TotalMilliseconds;
    p.WaitForExit(Math.Max(1000, left));
    Thread.Sleep(500);
    screen = Screen();
    string code = p.HasExited ? p.ExitCode.ToString() : "still-running";
    if (!p.HasExited) {
      // Kill the whole tree: the shell's ruby child would otherwise linger.
      try { Process.Start(new ProcessStartInfo("taskkill", "/T /F /PID " + p.Id) { UseShellExecute = false, CreateNoWindow = true }).WaitForExit(10000); } catch { }
    }
    FreeConsole();
    return "EXIT=" + code + "\nPRE_TYPED=" + preTyped + "\nSAW_PROMPT=" + sawPrompt + "\nTYPED=" + typed + "\n----- SCREEN -----\n" + screen + "----- END SCREEN -----";
  }
}
'@

$repo = (Get-Location).Path
$failures = @()

# Screen lines are read back with trailing spaces trimmed, so match prompts
# without their trailing space.
function Invoke-Case($name, $file, $cmdArgs, $waitFor, $typed, $mustSee, $mustNotSee, $required, $timeoutMs = 90000, $preWait = $null, $preInput = $null) {
  $stderrLog = Join-Path $repo 'probe\probe-stderr.log'
  Remove-Item $stderrLog -ErrorAction SilentlyContinue
  $out = [ConsoleDriver]::Run2($file, $cmdArgs, $repo, $preWait, $preInput, $waitFor, $typed, $timeoutMs)
  "===== CASE: $name ($file $cmdArgs)"
  $out
  if (Test-Path $stderrLog) { "probe-stderr.log: [" + (Get-Content -Raw $stderrLog) + "]" }
  $ok = $true
  foreach ($s in $mustSee) { if (-not $out.Contains($s)) { "MISSING: $s"; $ok = $false } }
  foreach ($s in $mustNotSee) { if ($out.Contains($s)) { "UNEXPECTED (echoed?): $s"; $ok = $false } }
  "RESULT[$name]: " + $(if ($ok) { 'PASS' } else { 'FAIL' })
  if (-not $ok -and $required) { $script:failures += $name }
}

$probe = 'bundle exec ruby probe\read_secret_probe.rb'
$typed = "  typed SECRET `r"
$expect = @('Password:', 'RESULT len=15 exact=true', 'PROBE-DONE')

Invoke-Case 'cmd prompt' 'cmd.exe' "/d /c $probe" 'Password:' $typed $expect @('typed SECRET') $true
Invoke-Case 'Windows PowerShell prompt' 'powershell.exe' "-NoProfile -Command $probe" 'Password:' $typed $expect @('typed SECRET') $true
Invoke-Case 'pwsh prompt' 'pwsh.exe' "-NoProfile -Command $probe" 'Password:' $typed $expect @('typed SECRET') $true
Invoke-Case 'cmd Ctrl+Z (end-of-input)' 'cmd.exe' "/d /c $probe" 'Password:' "$([char]0x1A)`r" @('Password:', 'PROBE-DONE') @() $false

# Type-ahead: typed after READY, before the prompt. io-console's iflush is a
# no-op on Windows, so the early line is read; what matters is that the
# console never displays it (echo happens only when a read takes the input).
$env:PROBE_DELAY = '4'
Invoke-Case 'cmd type-ahead never shown' 'cmd.exe' "/d /c $probe" 'Password:' $typed @('Password:', 'PROBE-DONE') @('EARLYTYPED') $true 90000 'READY' "EARLYTYPED`r"
Invoke-Case 'Windows PowerShell type-ahead never shown' 'powershell.exe' "-NoProfile -Command $probe" 'Password:' $typed @('Password:', 'PROBE-DONE') @('EARLYTYPED') $true 90000 'READY' "EARLYTYPED`r"
Remove-Item Env:PROBE_DELAY

# Full lich.rbw path, report-only: startup on a CI Ruby may stop earlier for
# unrelated gem-check reasons. The seeded account makes -aa stop at "already
# exists" before it would authenticate.
New-Item -ItemType Directory -Force (Join-Path $repo 'data') | Out-Null
Set-Content -Path (Join-Path $repo 'data\entry.yaml') -Value "encryption_mode: plaintext`naccounts:`n  ZZTEST:`n    password: x`n    characters: []"
Invoke-Case 'lich.rbw -aa via cmd' 'cmd.exe' '/d /c bundle exec ruby lich.rbw --no-gtk -aa zztest' 'Password:' "typed-LICH-secret`r" @('Password:', 'already exists') @('typed-LICH-secret') $false 150000
$missingLog = Join-Path $repo 'temp\lich5-missing-gems.log'
if (Test-Path $missingLog) { '----- lich5-missing-gems.log'; Get-Content $missingLog -Tail 40 }
$debugLog = Get-ChildItem (Join-Path $repo 'temp') -Filter 'debug-*.log' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -Last 1
if ($debugLog) { "----- newest debug log: $($debugLog.Name)"; Get-Content $debugLog.FullName -Tail 40 } else { '----- no temp/debug-*.log written' }
Get-ChildItem (Join-Path $repo 'temp') -ErrorAction SilentlyContinue | Select-Object Name, Length | Format-Table | Out-String

if ($failures.Count -gt 0) { "FAILED: $($failures -join ', ')"; exit 1 }
'ALL REQUIRED CASES PASSED'
