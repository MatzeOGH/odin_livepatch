# Runs app.exe under cdb. At a stop in bump in each version, cdb must read the values that the code
# uses: the @static calls, the global that v2 adds, a @thread_local and a global of the exe. Run
# build.bat first. Without cdb, the test is skipped, except in CI ($env:CI), where it fails.

$cdb = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\x64\cdb.exe'
if (-not (Test-Path $cdb)) {
    if ($env:CI) { Write-Host "  FAIL  cdb not found: $cdb"; exit 1 }
    Write-Host "  skipped: cdb not found ($cdb)"
    exit 0
}

# At each stop: select bump (frame 1), read the @static calls and the globals, continue. A failed
# dx does not stop the commands (added_global is not in v1).
$read = '".echo STOP; k 2; .frame 1; dx calls; dx total; dx tl_value; dx added_global; g"'
# The exe gets the breakpoint at the start. cdb resolves a breakpoint on a symbol only with its
# module name, and the name of a patch module (lp_<pid>_g<n>) is not known before the patch. Thus,
# each time a module lp_* loads, cdb runs cdb_on_load.txt, which sets it in all modules lp_*.
$on_load = @("bm lp_*!main::stop_here $read", 'g')
$on_load_file = Join-Path $PSScriptRoot 'cdb_on_load.txt'
Set-Content $on_load_file $on_load
# Forward slashes: in a quoted cdb string, a backslash starts an escape. The \a in D:\a\... is a bell.
$on_load_path = $on_load_file -replace '\\', '/'
$commands = @(
    '.lines -e'
    "bm app!main::stop_here $read"
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
expect 'stopped three times'                '^STOP\s*$' 3
expect 'v1: in bump of the exe'             'app!main::bump\+0x[0-9a-f]+ \['
expect 'v2, v3: in bump of a patch module'  'lp_\w+!main::bump\+0x[0-9a-f]+ \[' 2
expect 'v3: @static calls is 3'             '^calls\s*:\s*3\b'
expect 'v1: global total'                   'total\s*:\s*101\b'
expect 'v3: global total'                   'total\s*:\s*106\b'
expect 'v1: @thread_local tl_value'         'tl_value\s*:\s*8\b'
expect 'v3: @thread_local tl_value'         'tl_value\s*:\s*13\b'
expect 'v2: global that v2 adds'            'added_global\s*:\s*1002\b'
expect 'v3: the same global, kept'          'added_global\s*:\s*1005\b'
expect 'the program finished'               'ALL OK'
if ($failed) { exit 1 }
