@echo off
rem Builds the demo host, and (with an output dir argument) the patch objects that
rem patch() maps in. patch() calls this script the second way. Every flag is required.
rem Run the first form once by hand to produce demo.exe next to this script.

rem ODIN is the compiler to call. It defaults to `odin` (on PATH). To build without odin
rem on PATH, set it first: `set ODIN=C:\path\to\odin.exe`. patch() runs this
rem script in the running exe's environment, so this covers the F5 rebuild too.
if not defined ODIN set ODIN=odin

set PKG=%~dp0
set EXE=%~dp0demo.exe
set FLAGS=-debug -o:none -use-separate-modules -define:LIVEPATCH=true -define:LIVEPATCH_TIMINGS=true -define:LIVEPATCH_TOAST=true
rem /MAP lists the @static and file-private globals the PDB drops, so patch() can preserve
rem their state. The obj build links nothing and ignores it.
set LINK=/OPT:NOREF /OPT:NOICF /MAP:%EXE:.exe=.map%

if "%~1"=="" (
    "%ODIN%" build "%PKG%" %FLAGS% -extra-linker-flags:"%LINK%" -out:"%EXE%"
) else (
    "%ODIN%" build "%PKG%" %FLAGS% -extra-linker-flags:"%LINK%" -build-mode:obj -out:"%~1/"
)
