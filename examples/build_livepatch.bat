@echo off
rem Builds the demo. Run it once with no argument to build demo.exe.
rem patch() runs it with an output directory to build the patch objects.
rem Both modes use the same flags, so the exe and the patch always match.

rem The compiler. Set ODIN if odin is not on PATH. patch() runs this script with the
rem environment of the demo, so the same value applies to each patch.
if not defined ODIN set ODIN=odin

set PKG=%~dp0
set EXE=%~dp0demo.exe

rem patch() sets LIVEPATCH_DEBUGGER=0 when no debugger is attached. Then the patch needs no
rem debug info, and the build is faster.
set DEBUG=-debug
if "%LIVEPATCH_DEBUGGER%"=="0" set DEBUG=

rem Mandatory: -use-separate-modules and -define:LIVEPATCH=true.
rem Optional: the -o: level, LIVEPATCH_TIMINGS, and LIVEPATCH_TOAST.
set FLAGS=%DEBUG% -o:none -use-separate-modules -define:LIVEPATCH=true -define:LIVEPATCH_TIMINGS=true -define:LIVEPATCH_TOAST=true

rem Mandatory for the exe link. /MAP writes demo.map. patch() reads the address of each
rem symbol from it, @static locals and file-private globals included. The PDB does not
rem have them. The obj build does not link, so it ignores these flags.
set LINK=/OPT:NOREF /OPT:NOICF /MAP:%EXE:.exe=.map%

if "%~1"=="" (
    "%ODIN%" build "%PKG%" %FLAGS% -extra-linker-flags:"%LINK%" -out:"%EXE%"
) else (
    "%ODIN%" build "%PKG%" %FLAGS% -extra-linker-flags:"%LINK%" -build-mode:obj -out:"%~1/"
)
