# Runs each test in tests\ci, then builds it with LIVEPATCH=false.
# OPT is the -o: level (default: both none and speed). ODIN is the compiler (default: odin on PATH).
# Usage: tests\ci\run.ps1 [test,...]   (default: each directory in tests\ci)
param([string[]]$Tests = (Get-ChildItem $PSScriptRoot -Directory).Name)

$opts = if ($env:OPT) { @($env:OPT) } else { @('none', 'speed') }
$failed = @()
Remove-Item Env:VERSION, Env:LIVEPATCH -ErrorAction Ignore # the exe must have version 1
foreach ($opt in $opts) {
    $env:OPT = $opt
    foreach ($t in $Tests) {
        $d = Join-Path $PSScriptRoot $t
        Write-Host "=== $t -o:$opt"
        & "$d\build.bat"
        if ($LASTEXITCODE -eq 0) { & "$d\app.exe" }
        if ($LASTEXITCODE -ne 0) { $failed += "$t -o:$opt" }

        # The code must also build with livepatch off
        $env:LIVEPATCH = 'false'
        & "$d\build.bat"
        if ($LASTEXITCODE -ne 0) { $failed += "$t -o:$opt LIVEPATCH=false build" }
        Remove-Item Env:LIVEPATCH
    }
}
Remove-Item Env:OPT
if ($failed) { Write-Host "FAILED: $($failed -join ', ')"; exit 1 }
Write-Host 'All passed.'
