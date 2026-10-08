# CI tests

Each directory here is one test. GitHub Actions runs all of them (`.github/workflows/tests.yml`).

## Rules for a test

- A test checks one feature. The first comment in `main.odin` tells which.
- A test has only its own files: `build.bat` and `main.odin`, and more files or packages if the feature needs them. It does not use a shared script. Most tests have the same `build.bat`. A test that needs other build flags changes its own copy.
- `VERSION :: #config(VERSION, 1)` selects the version of the code. Use `when VERSION == N` for code that changes shape. The source files do not change during a test.
- The exe is version 1. The test then applies version 2 and version 3 as patches, or more. Two patches find errors in a patch that works only one time.
- Each test runs at `-o:none`, `-o:minimal` and `-o:speed`. Each test must also build with `LIVEPATCH=false`.
- The functional tests do not use the source watcher. The `watcher` test checks it on its own.

To add a test, copy a directory and change `main.odin`. The runner and the workflow find the new directory.

## The harness

The end of each `main.odin` is the same harness: `check`, `patch_to` and `main`. A test defines `LAST_VERSION`, `setup` and `checks(v)`. `main` calls `setup` one time, then `checks(1)`, and then patches to each version and calls `checks(v)` again.

`main` stays in its version 1 body through all patches, so it does no checks itself. At `-o:speed`, LLVM can put a result of version 1 code into `main` as a constant. `checks` is a new call after each patch, so it runs the new body. A loop that runs through the patches has the same problem: it must read a global or a `@thread_local`, so that LLVM cannot fold the result.

A test that must do more between the patches, for example to check a rejected patch, has its own `main`.

## Run the tests

All tests, at the three `-o:` levels:

```powershell
tests\ci\run.ps1
```

Some tests:

```powershell
tests\ci\run.ps1 change_proc,hooks
```

One `-o:` level:

```powershell
$env:OPT = 'speed'; tests\ci\run.ps1
```

One test by hand, at the `-o:` level in `OPT` (default: `none`):

```powershell
tests\ci\change_proc\build.bat
tests\ci\change_proc\app.exe
```

`ODIN` is the compiler (default: `odin` on the PATH). If you set `ODIN_ROOT`, it must point to the same Odin as the compiler. A different `ODIN_ROOT` crashes the compiler.

## Debugger tests

`tests\ci\run_debugger.ps1` runs each test that has a `debugger.ps1` under cdb, at the `-o:` level in `OPT` (default: `none`). `run.ps1` runs these tests too, but without a debugger. At each level, the stops, the modules, the call stack and the globals must be correct. Locals and arguments are checked at `-o:none` only: optimized code keeps them in registers or removes them, so cdb shows `<value unavailable>` or a stale value. `debugger.ps1` sets breakpoints before the program starts, on procedures that only one patch has. Each breakpoint must stop in the patch module of that version, and cdb must read the values there. The script then compares the cdb output with the expected values, as the gdb and lldb scripts of the Linux suites do.

| Test | What cdb must read |
| --- | --- |
| `debugger_breakpoints` | A stop in each of two patches, the locals of the patched caller, and the call stack back to `main` in the exe. |
| `debugger_values` | A struct local, a global before and after a patch changed it, the call stack, a conditional breakpoint in a loop, an array, and the arguments of a procedure that only the last patch adds, with a string. |

cdb is in the Debugging Tools for Windows, a feature of the Windows SDK. When cdb is not installed, `debugger.ps1` skips the test. In CI (`$env:CI`), a missing cdb is a failure. The log of each run is `cdb.log` in the test directory.

## CI

The workflow runs on `windows-2025`, with one job for each `-o:` level. Each job runs the tests, then the debugger tests as a separate step (`Debugger tests (cdb)`), also when the tests failed. The image of this runner has cdb. The workflow uses the latest release of Odin, not Odin master. The output of each step has the full cdb log.
