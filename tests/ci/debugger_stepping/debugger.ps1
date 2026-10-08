# Runs app.exe under cdb. At a breakpoint on the call of target in main, cdb steps into target,
# runs to the line after body_version, reads it, and goes up out of target with its return value in
# rax. It steps in v1 only: see the known limit in main.odin. Run build.bat first. Without cdb, the
# test is skipped, except in CI ($env:CI), where it fails.

$cdb = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\x64\cdb.exe'
if (-not (Test-Path $cdb)) {
    if ($env:CI) { Write-Host "  FAIL  cdb not found: $cdb"; exit 1 }
    Write-Host "  skipped: cdb not found ($cdb)"
    exit 0
}

$main = Join-Path $PSScriptRoot 'main.odin'
# The lines of the call, of the proc line of target, and of the line after body_version: they
# have comments
$call = (Select-String -Path $main -Pattern 'the debugger breaks here').LineNumber
$into = (Select-String -Path $main -Pattern 'a step into target arrives here').LineNumber
$read = (Select-String -Path $main -Pattern 'cdb reads body_version here').LineNumber

# cdb reads the commands of this file in order, and the next command after a stop. l+t: t steps
# by source line. At the stop of v1: step into target (t), show the frame, run to the line after
# body_version with a one-shot breakpoint (Odin gives the proc line more than one line-table row,
# so the count of p steps is not fixed), read the locals, go up out of target (gu), and show its
# return value (rax). At the stops of v2 and v3: continue.
$v1 = @('.echo STOP', 't', 'k 1', "bp /1 ``app!main.odin:$read``", 'g', 'dv', 'gu', 'r rax', 'g')
$later = @('.echo STOP', 'g')
$commands = @('.lines -e', 'l+t', "bp ``app!main.odin:$call``", 'g') + $v1 + $later + $later
$commands_file = Join-Path $PSScriptRoot 'cdb_commands.txt'
$log = Join-Path $PSScriptRoot 'cdb.log'
Set-Content $commands_file $commands
# Only the local PDBs: the exe PDB, and the PDB of each patch module
$env:_NT_SYMBOL_PATH = "$PSScriptRoot;$PSScriptRoot\livepatch_mod"
# -G: no stop at the process exit. The q on stdin ends cdb after the program exits.
'q' | & $cdb -G -lines -cf $commands_file (Join-Path $PSScriptRoot 'app.exe') *> $log
$text = Get-Content $log -Raw
Write-Host $text

$failed = $false
# Passes when at least $count lines of the log match $pattern
function expect($label, $pattern, $count = 1) {
    $found = ([regex]::Matches($text, "(?m)$pattern")).Count
    if ($found -ge $count) { Write-Host "  OK    $label" } else { Write-Host "  FAIL  $label (found $found of $count)"; $script:failed = $true }
}
expect 'stopped at the call three times'            '^STOP\s*$' 3
expect 'v1: step: in target of the exe'             "app!main::target(\+0x[0-9a-f]+)? \[.*main\.odin @ $into\]"
expect 'v1: the body of v1'                         '\bbody_version = 0n1\b'
expect 'v1: gu returns 21'                          '^rax=0000000000000015\s*$'
Write-Host '  KNOWN v2, v3: step into the patch (no debugger steps through the redirect stub)'
expect 'v2: the code of v2 ran'                     'target\(10\) +22 \(want 22\) OK'
expect 'v3: the code of v3 ran'                     'target\(10\) +23 \(want 23\) OK'
expect 'the program finished'                       'ALL OK'
if ($failed) { exit 1 }
