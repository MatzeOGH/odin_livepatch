# Runs app.exe under cdb. A breakpoint on stop_v2 and on stop_v3, set before the program starts,
# must stop in the patch module of each version, with the locals of the patched caller. Run
# build.bat first. Without cdb, the test is skipped, except in CI ($env:CI), where it fails.

$cdb = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\x64\cdb.exe'
if (-not (Test-Path $cdb)) {
    if ($env:CI) { Write-Host "  FAIL  cdb not found: $cdb"; exit 1 }
    Write-Host "  skipped: cdb not found ($cdb)"
    exit 0
}

# Each breakpoint prints the stack and the locals of its caller (frame 1), then continues
# cdb resolves a breakpoint on a symbol only with its module name, and the name of a patch
# module (lp_<pid>_g<n>) is not known before the patch. Thus, each time a module lp_* loads,
# cdb runs cdb_on_load.txt, which sets the breakpoints with bm in all modules lp_*.
$on_load = @(
    'bm lp_*!main::stop_v2 ".echo STOP v2; k 5; .frame 1; dv; g"'
    'bm lp_*!main::stop_v3 ".echo STOP v3; k 5; .frame 1; dv; g"'
    'g'
)
$on_load_file = Join-Path $PSScriptRoot 'cdb_on_load.txt'
Set-Content $on_load_file $on_load
$commands = @(
    '.lines -e'
    "sxe -c `"`$`$<$on_load_file`" ld:lp_*"
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
expect 'v2: stopped in the patch'           '^STOP v2\s*$'
expect 'v2: in the patch module'            'lp_\w+!main::stop_v2'
expect 'v2: caller body_v2 in the patch'    'lp_\w+!main::body_v2'
expect 'v2: local n'                        '\bn = 0n20'
expect 'v2: local doubled'                  '\bdoubled = 0n40'
expect 'v3: stopped in the second patch'    '^STOP v3\s*$'
expect 'v3: in the patch module'            'lp_\w+!main::stop_v3'
expect 'v3: local tripled'                  '\btripled = 0n60'
expect 'called from main in the exe'        'app!main::main' 2
expect 'the program finished'               'ALL OK'
if ($failed) { exit 1 }
