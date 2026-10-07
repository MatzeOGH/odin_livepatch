# Runs each test in tests\ci at -o:none and -o:speed. ODIN is the compiler (default: odin on PATH).
# Usage: tests\ci\run.ps1 [test...]   (default: each directory in tests\ci)
param([string[]]$Tests = (Get-ChildItem $PSScriptRoot -Directory).Name)

$failed = @()
Remove-Item Env:VERSION -ErrorAction Ignore # the exe must have version 1
foreach ($opt in 'none', 'speed') {
    $env:OPT = $opt
    foreach ($t in $Tests) {
        $d = Join-Path $PSScriptRoot $t
        Write-Host "=== $t -o:$opt"
        & "$d\build.bat"
        if ($LASTEXITCODE -eq 0) { & "$d\app.exe" }
        if ($LASTEXITCODE -ne 0) { $failed += "$t -o:$opt" }
    }
}
if ($failed) { Write-Host "FAILED: $($failed -join ', ')"; exit 1 }
Write-Host 'All passed.'
