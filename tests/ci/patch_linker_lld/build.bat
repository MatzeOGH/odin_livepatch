@echo off
rem No argument: builds app.exe. patch() runs it with an output directory to build the patch objects.
rem OPT is the -o: level (default: none). VERSION selects the version of the code (default: 1).
rem LIVEPATCH=false builds the exe with livepatch off (default: true).
if not defined ODIN set ODIN=odin
if not defined OPT set OPT=none
if not defined VERSION set VERSION=1
if not defined LIVEPATCH set LIVEPATCH=true
rem patch() sets LIVEPATCH_DEBUGGER=0 when no debugger is attached. Then the patch needs no debug info.
set DEBUG=-debug
if not "%~1"=="" if "%LIVEPATCH_DEBUGGER%"=="0" set DEBUG=
rem The exe links with lld. The default linker is radlink. The patch DLL always links with lld-link.
set FLAGS=%DEBUG% -o:%OPT% -define:VERSION=%VERSION% -use-separate-modules -define:LIVEPATCH=%LIVEPATCH% -linker:lld -define:LIVEPATCH_LINKER=lld
rem /MAP writes app.map: patch() reads the address of each symbol from it.
set LINK=/OPT:NOREF /OPT:NOICF /MAP:"%~dp0app.map"

if "%~1"=="" (
    "%ODIN%" build "%~dp0." %FLAGS% -extra-linker-flags:"%LINK%" -out:"%~dp0app.exe"
) else (
    "%ODIN%" build "%~dp0." %FLAGS% -extra-linker-flags:"%LINK%" -build-mode:obj -out:"%~1/"
)
