@echo off
rem Builds the demo host, and (with an output dir argument) the patch objects that
rem patch() maps in. patch() calls this script the second way. Every flag is required.
rem Run the first form once by hand to produce demo.exe next to this script.

rem ODIN is the compiler to call. It defaults to `odin` (on PATH). To build without odin
rem on PATH, set it first: `set ODIN=C:\path\to\odin.exe`. patch() reads the same variable
rem from the running exe's environment, so this covers the F5 rebuild too.
if not defined ODIN set ODIN=odin

set PKG=%~dp0
set EXE=%~dp0demo.exe
set FLAGS=-debug -o:none -use-separate-modules -define:LIVEPATCH=true -define:LIVEPATCH_TIMINGS=true -extra-linker-flags:"/OPT:NOREF /OPT:NOICF"

if "%~1"=="" (
    "%ODIN%" build "%PKG%" %FLAGS% -out:"%EXE%"
) else (
    "%ODIN%" build "%PKG%" %FLAGS% -build-mode:obj -out:"%~1/"
)
