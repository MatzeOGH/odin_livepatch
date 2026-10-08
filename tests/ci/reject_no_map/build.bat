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
set FLAGS=%DEBUG% -o:%OPT% -define:VERSION=%VERSION% -use-separate-modules -define:LIVEPATCH=%LIVEPATCH%
rem This test links the exe without /MAP: patch() must reject each patch
set LINK=/OPT:NOREF /OPT:NOICF
if exist "%~dp0app.map" del "%~dp0app.map"

if "%~1"=="" (
    "%ODIN%" build "%~dp0." %FLAGS% -extra-linker-flags:"%LINK%" -out:"%~dp0app.exe"
) else (
    "%ODIN%" build "%~dp0." %FLAGS% -extra-linker-flags:"%LINK%" -build-mode:obj -out:"%~1/"
)
