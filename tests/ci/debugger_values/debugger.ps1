# Runs app.exe under cdb: three patches, a stop in each, and the values that cdb must read there.
# Each breakpoint is set before the program starts, on a procedure that only one patch has. Run
# build.bat first. Without cdb, the test is skipped, except in CI ($env:CI), where it fails.

$cdb = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\x64\cdb.exe'
if (-not (Test-Path $cdb)) {
    if ($env:CI) { Write-Host "  FAIL  cdb not found: $cdb"; exit 1 }
    Write-Host "  skipped: cdb not found ($cdb)"
    exit 0
}

# Each breakpoint prints what it reads, then continues. Frame 1 is the patched caller.
# loop_v3 stops only when its argument i (in rcx) is 5. A marker line (STOP ...) starts each stop.
# cdb cannot bind the loop variable i of scene_v3 (the debug info of Odin has no such local
# there), so the test reads i as the argument in rcx. dv prints the locals that cdb sees.
# The debug info of Odin gives the string argument label the type string& (as clang does for a
# struct that is passed by reference). Thus the test reads the fields len and data through it.
# cdb resolves a breakpoint on a symbol only with its module name, and the name of a patch
# module (lp_<pid>_g<n>) is not known before the patch. Thus, each time a module lp_* loads,
# cdb runs cdb_on_load.txt, which sets the breakpoints with bm in all modules lp_*.
# Optimized code removes the locals of v4. Then da fails, and an error stops the rest of the
# command list, also its g. Thus the v4 stop reads the locals at -o:none only.
$v4_reads = if ($env:OPT -and $env:OPT -ne 'none') { '' } else { '.frame 1; dx n; dx label.len; da @@c++(label.data) L4; dx doubled; ' }
$on_load = @(
    'bm lp_*!main::stop_v2 ".echo STOP v2; k 6; .frame 1; dx p; dx total; dq app!main::counter L1; g"'
    'bm lp_*!main::loop_v3 "j (@rcx == 5) ''.echo STOP v3 loop; r rcx; .frame 1; dv; dx sum; g'' ; ''g''"'
    'bm lp_*!main::stop_v3 ".echo STOP v3 end; .frame 1; dx -r1 values; dx total; dq app!main::counter L1; g"'
    "bm lp_*!main::stop_v4 `".echo STOP v4; k 3; ${v4_reads}g`""
    'g'
)
$on_load_file = Join-Path $PSScriptRoot 'cdb_on_load.txt'
Set-Content $on_load_file $on_load
# Forward slashes: in a quoted cdb string, a backslash starts an escape. The \a in D:\a\... is a bell.
$on_load_path = $on_load_file -replace '\\', '/'
$commands = @(
    '.lines -e'
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
# A local, an argument, or the frame of a patched caller: optimized code (-o:minimal, -o:speed)
# keeps a value in a register or removes it, and can inline a caller. Then cdb shows
# <value unavailable>, a stale value, or no frame. Checked at -o:none only.
function expect_unoptimized($label, $pattern) {
    if ($env:OPT -and $env:OPT -ne 'none') { Write-Host "  SKIP  $label (-o:$env:OPT)"; return }
    expect $label $pattern
}
Write-Host 'v2: a struct, a global, the call stack'
expect 'stopped in the patch module'        'lp_\w+!main::stop_v2 \['
expect_unoptimized 'struct local p.x'                   '\bx\s*:\s*3\b'
expect_unoptimized 'struct local p.y'                   '\by\s*:\s*6\b'
expect_unoptimized 'local total'                        'total\s*:\s*9\b'
expect 'global counter, before the update'  '\s00000000`00000005\s*$'
expect_unoptimized 'scene_v2 in the patch module'       'lp_\w+!main::scene_v2'
expect_unoptimized 'drive in the stack'                 '!main::drive'
expect 'main of the exe in the stack'       'app!main::main'
Write-Host 'v3: a conditional breakpoint in a loop, an array, the global as v2 left it'
expect 'stopped once in the loop'           '^STOP v3 loop\s*$' 1
expect 'loop variable i, as the argument'   '^rcx=0000000000000005\s*$'
expect_unoptimized 'sum so far'                         '\bsum\s*:\s*15\b'
expect 'stopped after the loop'             '^STOP v3 end\s*$'
expect_unoptimized 'array values[0]'                    '\[0\]\s*:\s*66\b'
expect_unoptimized 'array values[1]'                    '\[1\]\s*:\s*1\b'
expect_unoptimized 'array values[2]'                    '\[2\]\s*:\s*14\b'
expect_unoptimized 'local total'                        'total\s*:\s*67\b'
expect 'global counter, as v2 left it'      '\s00000000`0000000e\s*$'
Write-Host 'v4: a procedure that only this patch has, with a string argument'
expect 'stopped in the patch module'        'lp_\w+!main::stop_v4 \['
expect_unoptimized 'added_helper in the stack'          'lp_\w+!main::added_helper'
expect_unoptimized 'argument n'                         '\bn\s*:\s*3\b'
expect_unoptimized 'string argument label: length'      'label\.len\s+:\s+4\b'
expect_unoptimized 'string argument label: text'        '"four"'
expect_unoptimized 'local doubled'                      'doubled\s*:\s*12\b'
expect 'the program finished'               'ALL OK'
$loops = ([regex]::Matches($text, '(?m)^STOP v3 loop\s*$')).Count
if ($loops -ne 1) { Write-Host "  FAIL  the loop breakpoint stopped $loops times, not 1"; $failed = $true }
if ($failed) { exit 1 }
