# Runs the debugger tests: each test in tests\ci that has a debugger script for this system runs
# under that debugger. Windows: debugger.ps1 (cdb) and debugger_raddbg.ps1 (RAD Debugger). Linux:
# debugger_gdb.sh and debugger_lldb.sh. macOS: debugger_lldb.sh. DEBUGGER selects one debugger, for
# example raddbg (default: all). OPT is the -o: level (default: none). ODIN is the compiler
# (default: odin on PATH).
# In GitHub Actions, it also writes a table of the results to the job summary.
# Usage: tests\ci\run_debugger.ps1 [test,...]   (default: each directory with a debugger script)
param([string[]]$Tests)

$scripts = if ($IsWindows) { @('debugger.ps1', 'debugger_raddbg.ps1') } elseif ($IsMacOS) { @('debugger_lldb.sh') } else { @('debugger_gdb.sh', 'debugger_lldb.sh') }
# The name of the debugger of a script
function debugger_of($script) {
    $name = $script -replace '^debugger_?', '' -replace '\.(ps1|sh)$', ''
    if ($name) { $name } else { 'cdb' }
}
if ($env:DEBUGGER) { $scripts = @($scripts | Where-Object { (debugger_of $_) -eq $env:DEBUGGER }) }
if (-not $Tests) {
    $Tests = (Get-ChildItem $PSScriptRoot -Directory | Where-Object { $d = $_.FullName; $scripts | Where-Object { Test-Path (Join-Path $d $_) } }).Name
}

$opt_before = $env:OPT
if (-not $env:OPT) { $env:OPT = 'none' }
$failed = @()
$rows = @()
Remove-Item Env:VERSION, Env:LIVEPATCH -ErrorAction Ignore # the exe must have version 1
foreach ($t in $Tests) {
    $d = Join-Path $PSScriptRoot $t
    # Deletes the output of an earlier run: objects from another system or a crashed run would
    # go into the next patch
    foreach ($old in 'livepatch', 'livepatch_mod') { Remove-Item -Recurse -Force -ErrorAction Ignore (Join-Path $d $old) }
    if ($IsWindows) { & "$d\build.bat" } else { & sh "$d/build.sh" }
    $built = $LASTEXITCODE -eq 0
    foreach ($script in $scripts) {
        $path = Join-Path $d $script
        if (-not (Test-Path $path)) { continue }
        $debugger = debugger_of $script
        Write-Host "=== $t -o:$env:OPT under $debugger"
        $problems = @()
        if (-not $built) {
            $problems += 'build failed'
        } else {
            # Tee: the output goes to the log, and the failed expectations to the summary. 6>&1:
            # debugger.ps1 writes with Write-Host.
            if ($script -like '*.ps1') { & $path 6>&1 | Tee-Object -Variable output | Out-Host }
            else { & sh $path | Tee-Object -Variable output | Out-Host }
            if ($LASTEXITCODE -ne 0) {
                # Write-Host lines arrive as information records: match their text
                $checks = @($output | ForEach-Object { "$(if ($_ -is [System.Management.Automation.InformationRecord]) { $_.MessageData } else { $_ })" } |
                    Where-Object { $_ -match '^\s*FAIL\b' } | ForEach-Object { $_.Trim() })
                $problems += if ($checks) { $checks } else { "exit code $LASTEXITCODE" }
            }
        }
        if ($problems) { $failed += "$t ($debugger)" }
        $rows += [pscustomobject]@{ Test = $t; Debugger = $debugger; Problems = $problems }
    }
}

if ($env:GITHUB_STEP_SUMMARY) {
    $bad = @($rows | Where-Object { $_.Problems })
    $summary = @('', "### Debugger tests (-o:$env:OPT): $($rows.Count - $bad.Count) of $($rows.Count) passed", '', '| Test | Debugger | Result | Failed expectations |', '| --- | --- | --- | --- |')
    foreach ($row in $rows) {
        $details = ($row.Problems | ForEach-Object { ($_ -replace '\s+', ' ') -replace '\|', '\|' }) -join '<br>'
        $summary += "| ``$($row.Test)`` | $($row.Debugger) | $(if ($row.Problems) { '❌' } else { '✅' }) | $details |"
    }
    $summary | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8
}

$env:OPT = $opt_before
if ($failed) { Write-Host "FAILED: $($failed -join ', ')"; exit 1 }
Write-Host 'All passed.'
