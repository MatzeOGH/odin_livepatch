@echo off
rem No argument: builds app.exe. patch() runs it with an output directory to build the patch objects.
rem OPT is the -o: level (default: none). VERSION selects the version of the code (default: 1).
rem This test always builds with livepatch off. It also type-checks the API with LIVEPATCH=true
rem on targets that livepatch does not patch, where the API must compile to no-ops.
if not defined ODIN set ODIN=odin
if not defined OPT set OPT=none
if not defined VERSION set VERSION=1
set FLAGS=-debug -o:%OPT% -define:VERSION=%VERSION% -use-separate-modules -define:LIVEPATCH=false

if "%~1"=="" (
    for %%T in (linux_arm64 linux_riscv64 darwin_amd64 freebsd_amd64 windows_i386) do (
        echo type-check LIVEPATCH=true -target:%%T
        "%ODIN%" check "%~dp0." -target:%%T -define:LIVEPATCH=true || exit /b 1
    )
    "%ODIN%" build "%~dp0." %FLAGS% -out:"%~dp0app.exe"
) else (
    "%ODIN%" build "%~dp0." %FLAGS% -build-mode:obj -out:"%~1/"
)
