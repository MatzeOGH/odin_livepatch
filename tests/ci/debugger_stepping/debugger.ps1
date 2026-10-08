# Runs app.exe under cdb. At a breakpoint on the call of target in main, cdb steps into target and
# must arrive in the body of the newest version, steps over a line, reads body_version, and goes
# up out of target with its return value in rax. Run build.bat first. Without cdb, the test is
# skipped, except in CI ($env:CI), where it fails.

$cdb = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\x64\cdb.exe'
if (-not (Test-Path $cdb)) {
    if ($env:CI) { Write-Host "  FAIL  cdb not found: $cdb"; exit 1 }
    Write-Host "  skipped: cdb not found ($cdb)"
    exit 0
}

$main = Join-Path $PSScriptRoot 'main.odin'
# The lines of the call and of the first line of target: they have comments
$call = (Select-String -Path $main -Pattern 'the debugger breaks here').LineNumber
$into = (Select-String -Path $main -Pattern 'the debugger steps into target to here').LineNumber

# cdb reads the commands of this file in order, and the next command after a stop. l+t: t and p
# step by source line. At each stop: step into target (t), show the frame, step over a line (p),
# read the locals, go up out of target (gu), and show its return value (rax).
$stop = @('.echo STOP', 't', 'k 1', 'p', 'dv', 'gu', 'r rax', 'g')
$commands = @('.lines -e', 'l+t', "bp ``app!main.odin:$call``", 'g') + $stop + $stop + $stop
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
expect 'v2, v3: step: in target of a patch module'  "lp_\w+!main::target(\+0x[0-9a-f]+)? \[.*main\.odin @ $into\]" 2
expect 'v1: the body of v1'                         '\bbody_version = 0n1\b'
expect 'v2: the body of v2'                         '\bbody_version = 0n2\b'
expect 'v3: the body of v3'                         '\bbody_version = 0n3\b'
expect 'v1: gu returns 21'                          '^rax=0000000000000015\s*$'
expect 'v2: gu returns 22'                          '^rax=0000000000000016\s*$'
expect 'v3: gu returns 23'                          '^rax=0000000000000017\s*$'
expect 'the program finished'                       'ALL OK'
if ($failed) { exit 1 }
