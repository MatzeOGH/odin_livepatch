# Runs each test in tests\ci that has a debugger.ps1 under cdb, at -o:none. Optimized code shows
# locals as optimized out. ODIN is the compiler (default: odin on PATH).
# Usage: tests\ci\run_debugger.ps1 [test,...]   (default: each directory with a debugger.ps1)
param([string[]]$Tests = (Get-ChildItem $PSScriptRoot -Directory | Where-Object { Test-Path "$($_.FullName)\debugger.ps1" }).Name)

$failed = @()
Remove-Item Env:VERSION, Env:LIVEPATCH -ErrorAction Ignore # the exe must have version 1
$env:OPT = 'none'
foreach ($t in $Tests) {
    $d = Join-Path $PSScriptRoot $t
    Write-Host "=== $t under cdb"
    & "$d\build.bat"
    if ($LASTEXITCODE -eq 0) { & "$d\debugger.ps1" }
    if ($LASTEXITCODE -ne 0) { $failed += $t }
}
Remove-Item Env:OPT
if ($failed) { Write-Host "FAILED: $($failed -join ', ')"; exit 1 }
Write-Host 'All passed.'
