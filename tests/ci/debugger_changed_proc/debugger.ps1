# Runs app.exe under cdb. A breakpoint on a source line of work, which the exe has and each patch
# changes, must stop in the body of the exe, then of v2, then of v3, and never in an old body.
# Run build.bat first. Without cdb, the test is skipped, except in CI ($env:CI), where it fails.

$cdb = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\x64\cdb.exe'
if (-not (Test-Path $cdb)) {
    if ($env:CI) { Write-Host "  FAIL  cdb not found: $cdb"; exit 1 }
    Write-Host "  skipped: cdb not found ($cdb)"
    exit 0
}

# The line of the breakpoint: it has the comment "the debugger breaks here"
$line = (Select-String -Path (Join-Path $PSScriptRoot 'main.odin') -Pattern 'the debugger breaks here').LineNumber

# The breakpoint prints a marker line, the stack and the locals, then continues
$bp_commands = '".echo STOP; k 3; dv; g"'
# cdb sets a breakpoint on a source line only with its module name. The exe (app) gets it at the
# start. The name of a patch module (lp_<pid>_g<n>) is not known before the patch. Thus, each time
# a module lp_* loads, cdb runs cdb_on_load.txt, which sets the breakpoint in each module lp_*
# (lm1m lists their names).
$on_load = @(
    ".foreach (PATCHMOD {lm1m m lp_*}) { bp ``PATCHMOD!main.odin:$line`` $bp_commands }"
    'g'
)
$on_load_file = Join-Path $PSScriptRoot 'cdb_on_load.txt'
Set-Content $on_load_file $on_load
# Forward slashes: in a quoted cdb string, a backslash starts an escape. The \a in D:\a\... is a bell.
$on_load_path = $on_load_file -replace '\\', '/'
$commands = @(
    '.lines -e'
    "bp ``app!main.odin:$line`` $bp_commands"
    "sxe -c `"`$`$<$on_load_path`" ld:lp_*"
    'g'
)
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
# A local or an argument: optimized code keeps a value in a register or removes it. Checked at
# -o:none only.
function expect_unoptimized($label, $pattern) {
    if ($env:OPT -and $env:OPT -ne 'none') { Write-Host "  SKIP  $label (-o:$env:OPT)"; return }
    expect $label $pattern
}
expect             'v1: stopped in the body of the exe'  'app!main::work\+0x[0-9a-f]+ \['
expect             'v2, v3: stopped in a patch module'   'lp_\w+!main::work\+0x[0-9a-f]+ \[' 2
expect_unoptimized 'v1: the body of v1'                  '\bbody_version = 0n1\b'
expect_unoptimized 'v2: the body of v2'                  '\bbody_version = 0n2\b'
expect_unoptimized 'v3: the body of v3'                  '\bbody_version = 0n3\b'
expect_unoptimized 'v3: its local scaled'                '\bscaled = 0n30\b'
expect             'the program finished'                'ALL OK'
# One stop for each version: a stop in an old body would be a fourth
$stops = ([regex]::Matches($text, '(?m)^STOP\s*$')).Count
if ($stops -ne 3) { Write-Host "  FAIL  the breakpoint stopped $stops times, not 3"; $failed = $true }
if ($failed) { exit 1 }
