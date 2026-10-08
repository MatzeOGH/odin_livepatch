# Runs each test in tests\ci, then builds it one time with LIVEPATCH=false. Windows: build.bat and app.exe.
# Linux: build.sh and app. A test that has no build script for this system is skipped.
# OPT is the -o: level (default: none, minimal and speed). ODIN is the compiler (default: odin on PATH).
# Linux: RELOC=static builds with -reloc-mode:static (default: a PIE).
# In GitHub Actions, it also writes a table of the results to the job summary.
# Usage: tests\ci\run.ps1 [test,...]   (default: each directory in tests\ci)
param([string[]]$Tests = (Get-ChildItem $PSScriptRoot -Directory).Name)

$script_name = if ($IsWindows) { 'build.bat' } else { 'build.sh' }
$app_name = if ($IsWindows) { 'app.exe' } else { 'app' }

# Deletes the output of an earlier run: objects from another system or a crashed run would go
# into the next patch
function clean($d) {
    foreach ($old in 'livepatch', 'livepatch_mod') { Remove-Item -Recurse -Force -ErrorAction Ignore (Join-Path $d $old) }
}

# Runs the build script of test directory $d
function build($d) {
    if ($IsWindows) { & "$d\build.bat" } else { & sh "$d/build.sh" }
}

$opts = if ($env:OPT) { @($env:OPT) } else { @('none', 'minimal', 'speed') }
# The level of the LIVEPATCH=false build. In CI, only the -o:none jobs do it.
$off_opt = if ($opts -contains 'none') { 'none' } else { $opts[0] }
$failed = @()
$rows = @()
Remove-Item Env:VERSION, Env:LIVEPATCH -ErrorAction Ignore # the exe must have version 1
foreach ($opt in $opts) {
    $env:OPT = $opt
    foreach ($t in $Tests) {
        $d = Join-Path $PSScriptRoot $t
        if (-not (Test-Path (Join-Path $d $script_name))) { continue }
        Write-Host "=== $t -o:$opt"
        $problems = @()
        clean $d
        build $d
        if ($LASTEXITCODE -ne 0) {
            $problems += 'build failed'
        } else {
            # Tee: the output goes to the log, and the failed checks to the summary
            & (Join-Path $d $app_name) | Tee-Object -Variable output | Out-Host
            if ($LASTEXITCODE -ne 0) {
                # Each failed check, with the version line (v1, v2, ...) above it
                $version = ''
                $checks = @(foreach ($line in $output) {
                    if ($line -match '^v\d+$') { $version = "${line}: " }
                    elseif ($line -match '\bFAIL\b') { $version + $line.Trim() }
                })
                $problems += if ($checks) { $checks } else { "exit code $LASTEXITCODE" }
            }
        }

        # The code must also build with livepatch off. The -o: level does not change that, so it
        # builds one time.
        if ($opt -eq $off_opt) {
            $env:LIVEPATCH = 'false'
            build $d
            if ($LASTEXITCODE -ne 0) { $problems += 'LIVEPATCH=false build failed' }
            Remove-Item Env:LIVEPATCH
        }

        if ($problems) { $failed += "$t -o:$opt" }
        $rows += [pscustomobject]@{ Test = $t; Opt = $opt; Problems = $problems }
    }
}
Remove-Item Env:OPT

if ($env:GITHUB_STEP_SUMMARY) {
    $bad = @($rows | Where-Object { $_.Problems })
    $summary = @("### Tests: $($rows.Count - $bad.Count) of $($rows.Count) passed", '', '| Test | -o | Result | Failed checks |', '| --- | --- | --- | --- |')
    foreach ($row in $rows) {
        $details = ($row.Problems | ForEach-Object { ($_ -replace '\s+', ' ') -replace '\|', '\|' }) -join '<br>'
        $summary += "| ``$($row.Test)`` | $($row.Opt) | $(if ($row.Problems) { '❌' } else { '✅' }) | $details |"
    }
    $summary | Add-Content $env:GITHUB_STEP_SUMMARY -Encoding utf8
}

if ($failed) { Write-Host "FAILED: $($failed -join ', ')"; exit 1 }
Write-Host 'All passed.'
