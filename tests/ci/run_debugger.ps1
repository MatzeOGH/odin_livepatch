# Runs each test in tests\ci that has a debugger.ps1 under cdb. OPT is the -o: level (default:
# none). ODIN is the compiler (default: odin on PATH).
# Usage: tests\ci\run_debugger.ps1 [test,...]   (default: each directory with a debugger.ps1)
param([string[]]$Tests = (Get-ChildItem $PSScriptRoot -Directory | Where-Object { Test-Path "$($_.FullName)\debugger.ps1" }).Name)

$opt_before = $env:OPT
if (-not $env:OPT) { $env:OPT = 'none' }
$failed = @()
Remove-Item Env:VERSION, Env:LIVEPATCH -ErrorAction Ignore # the exe must have version 1
foreach ($t in $Tests) {
    $d = Join-Path $PSScriptRoot $t
    Write-Host "=== $t -o:$env:OPT under cdb"
    & "$d\build.bat"
    if ($LASTEXITCODE -eq 0) { & "$d\debugger.ps1" }
    if ($LASTEXITCODE -ne 0) { $failed += $t }
}
$env:OPT = $opt_before
if ($failed) { Write-Host "FAILED: $($failed -join ', ')"; exit 1 }
Write-Host 'All passed.'
