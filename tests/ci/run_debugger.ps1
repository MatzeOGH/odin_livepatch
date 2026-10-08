# Runs each test in tests\ci that has a debugger.ps1 under cdb. OPT is the -o: level (default:
# none). ODIN is the compiler (default: odin on PATH).
# In GitHub Actions, it also writes a table of the results to the job summary.
# Usage: tests\ci\run_debugger.ps1 [test,...]   (default: each directory with a debugger.ps1)
param([string[]]$Tests = (Get-ChildItem $PSScriptRoot -Directory | Where-Object { Test-Path "$($_.FullName)\debugger.ps1" }).Name)

$opt_before = $env:OPT
if (-not $env:OPT) { $env:OPT = 'none' }
$failed = @()
$rows = @()
Remove-Item Env:VERSION, Env:LIVEPATCH -ErrorAction Ignore # the exe must have version 1
foreach ($t in $Tests) {
    $d = Join-Path $PSScriptRoot $t
    Write-Host "=== $t -o:$env:OPT under cdb"
    $problems = @()
    & "$d\build.bat"
    if ($LASTEXITCODE -ne 0) {
        $problems += 'build failed'
    } else {
        # Tee: the output goes to the log, and the failed expectations to the summary. 6>&1: the
        # script writes with Write-Host.
        & "$d\debugger.ps1" 6>&1 | Tee-Object -Variable output | Out-Host
        if ($LASTEXITCODE -ne 0) {
            # Write-Host lines arrive as information records: match their text
            $checks = @($output | ForEach-Object { "$(if ($_ -is [System.Management.Automation.InformationRecord]) { $_.MessageData } else { $_ })" } |
                Where-Object { $_ -match '^\s*FAIL\b' } | ForEach-Object { $_.Trim() })
            $problems += if ($checks) { $checks } else { "exit code $LASTEXITCODE" }
        }
    }
    if ($problems) { $failed += $t }
    $rows += [pscustomobject]@{ Test = $t; Problems = $problems }
}

if ($env:GITHUB_STEP_SUMMARY) {
    $bad = @($rows | Where-Object { $_.Problems })
    $summary = @('', "### Debugger tests (cdb, -o:$env:OPT): $($rows.Count - $bad.Count) of $($rows.Count) passed", '', '| Test | Result | Failed expectations |', '| --- | --- | --- |')
    foreach ($row in $rows) {
        $details = ($row.Problems | ForEach-Object { ($_ -replace '\s+', ' ') -replace '\|', '\|' }) -join '<br>'
        $summary += "| ``$($row.Test)`` | $(if ($row.Problems) { '❌' } else { '✅' }) | $details |"
    }
    $summary | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8
}

$env:OPT = $opt_before
if ($failed) { Write-Host "FAILED: $($failed -join ', ')"; exit 1 }
Write-Host 'All passed.'
