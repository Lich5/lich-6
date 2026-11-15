# --password-stdin through real pipes from each shell, run in its own step
# so no console detaching from the console cases gets in the way.
$ErrorActionPreference = 'Continue'
$failures = @()
function Invoke-Pipe($name, $shellFile, $shellArgs, $expectHex, $mustSee, $required) {
  $env:EXPECT_HEX = $expectHex
  try { $out = & $shellFile @shellArgs 2>&1 | Out-String } catch { $out = "EXCEPTION: $_" }
  "===== PIPE: $name"
  $out
  $ok = $true
  foreach ($s in $mustSee) { if (-not $out.Contains($s)) { "MISSING: $s"; $ok = $false } }
  "RESULT[$name]: " + $(if ($ok) { 'PASS' } else { 'FAIL' })
  if (-not $ok -and $required) { $script:failures += $name }
}
$pipeProbe = 'bundle exec ruby probe\pipe_probe.rb'
$rawProbe = 'ruby probe\raw_stdin.rb'
$asciiHex = '2074797065642053454352455420'   # ' typed SECRET '
$utf8Hex = '2070c3a4737377c3b672642020'      # ' p(a-umlaut)ssw(o-umlaut)rd  '
$umlautPw = ' p' + [char]0xE4 + 'ssw' + [char]0xF6 + 'rd  '

Invoke-Pipe 'RAW Windows PowerShell 5.1 ASCII' 'powershell.exe' @('-NoProfile', '-Command', "' typed SECRET ' | $rawProbe") $asciiHex @('RAW ') $false
Invoke-Pipe 'Windows PowerShell 5.1 ASCII (BOM stripped)' 'powershell.exe' @('-NoProfile', '-Command', "' typed SECRET ' | $pipeProbe") $asciiHex @('exact=true') $true
Invoke-Pipe 'RAW Windows PowerShell 5.1 non-ASCII' 'powershell.exe' @('-NoProfile', '-Command', "'$umlautPw' | $rawProbe") $utf8Hex @('RAW ') $false
Invoke-Pipe 'Windows PowerShell 5.1 non-ASCII (documented loss)' 'powershell.exe' @('-NoProfile', '-Command', "'$umlautPw' | $pipeProbe") $utf8Hex @('PIPE got=') $false
$env:PASSWORD = $umlautPw
Invoke-Pipe 'RAW pwsh 7 help example' 'pwsh.exe' @('-NoProfile', '-Command', "`$env:PASSWORD | $rawProbe") $utf8Hex @('RAW ') $false
Invoke-Pipe 'pwsh 7 help example ($env:PASSWORD | ...)' 'pwsh.exe' @('-NoProfile', '-Command', "`$env:PASSWORD | $pipeProbe") $utf8Hex @('exact=true') $true
Remove-Item Env:PASSWORD
Invoke-Pipe 'cmd echo pipe (report only)' 'cmd.exe' @('/d', '/c', "echo  typed SECRET | $pipeProbe") $asciiHex @('PIPE got=') $false

if ($failures.Count -gt 0) { "FAILED: $($failures -join ', ')"; exit 1 }
'ALL REQUIRED PIPE CASES PASSED'
