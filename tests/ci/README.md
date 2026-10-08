# CI tests

Each directory here is one test. GitHub Actions runs all of them on Windows, Linux and macOS ARM (`.github/workflows/tests.yml`).

## Rules for a test

- A test checks one feature. The first comment in `main.odin` tells which.
- A test has only its own files: `main.odin`, `build.bat` (Windows) and `build.sh` (Linux), and more files or packages if the feature needs them. It does not use a shared script. Most tests have the same build scripts. A test that needs other build flags changes its own copy.
- A test for one system has only the build script of that system. The runner skips it on the other system. For example, `reject_global_grew` and `thread_blocks_signal` have only `build.sh`.
- `VERSION :: #config(VERSION, 1)` selects the version of the code. Use `when VERSION == N` for code that changes shape. The source files do not change during a test.
- The exe is version 1. The test then applies version 2 and version 3 as patches, or more. Two patches find errors in a patch that works only one time.
- Each test runs at `-o:none`, `-o:minimal` and `-o:speed`. On Linux, each test also runs as a PIE and with `-reloc-mode:static`. Each test must also build with `LIVEPATCH=false`. The runner does this build at one `-o:` level only (`-o:none`, or the first level of the run): the level does not change it.
- The functional tests do not use the source watcher. The `watcher` test checks it on its own.

To add a test, copy a directory and change `main.odin`. The runner and the workflow find the new directory.

## The harness

The end of each `main.odin` is the same harness: `check`, `patch_to`, `version_check` and `main`. A test defines `LAST_VERSION`, `setup` and `checks(v)`. `main` calls `setup` one time, then `checks(1)`, and then patches to each version and calls `checks(v)` again. After each `checks(v)`, `version_check(v)` checks that the running code is version `v`. A patch that does not apply then fails, and does not pass with the old code.

`main` stays in its version 1 body through all patches, so it does no checks itself. At `-o:speed`, LLVM can put a result of version 1 code into `main` as a constant. `checks` is a new call after each patch, so it runs the new body. A loop that runs through the patches has the same problem: it must read a global or a `@thread_local`, so that LLVM cannot fold the result.

At `-o:speed`, LLVM also removes a call to a procedure that does nothing. Thus `checks` must do something in each version, also in version 1. If the `checks` of version 1 is empty, `main` does not call it, and the `checks` of the later versions never run.

A test that must do more between the patches, for example to check a rejected patch, has its own `main`.

## Run the tests

The runners are PowerShell scripts, for Windows and Linux. On Linux, they need `pwsh` ([install PowerShell on Linux](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-linux)).

All tests, at the three `-o:` levels:

```powershell
tests/ci/run.ps1
```

Some tests:

```powershell
tests/ci/run.ps1 change_proc,hooks
```

One `-o:` level, or on Linux one relocation mode:

```powershell
$env:OPT = 'speed'; tests/ci/run.ps1
$env:RELOC = 'static'; tests/ci/run.ps1
```

One test by hand, at the `-o:` level in `OPT` (default: `none`). Windows:

```powershell
tests\ci\change_proc\build.bat
tests\ci\change_proc\app.exe
```

Linux:

```sh
sh tests/ci/change_proc/build.sh
tests/ci/change_proc/app
```

`ODIN` is the compiler (default: `odin` on the PATH). If you set `ODIN_ROOT`, it must point to the same Odin as the compiler. A different `ODIN_ROOT` crashes the compiler.

Before each test, the runner deletes the `livepatch/` and `livepatch_mod/` directories of the test. Objects from another system or from a crashed run would otherwise go into the next patch.

## Debugger tests

`tests/ci/run_debugger.ps1` runs the tests that have a debugger script, under that debugger, at the `-o:` level in `OPT` (default: `none`). `run.ps1` runs these tests too, but without a debugger.

| System | Debugger | Script |
| --- | --- | --- |
| Windows | cdb | `debugger.ps1` |
| Linux | gdb | `debugger_gdb.sh` |
| Linux | lldb | `debugger_lldb.sh` |

A script sets breakpoints before the program starts: on procedures that only one patch has, or on source lines, as a user does. Each breakpoint must stop in the code of the right version, and the debugger must read the values there. A script finds the line of a source-line breakpoint by the comment `// the debugger breaks here` in `main.odin`. The script then compares the debugger output with the expected values. At each level, the stops, `main` in the stack and the globals must be correct. Locals, arguments and the frames of patched callers are checked at `-o:none` only: optimized code keeps values in registers or removes them, and can inline a caller. A stop procedure writes a global: at `-o:speed`, LLVM removes a call to a procedure that does nothing.

| Test | What the debugger must read |
| --- | --- |
| `debugger_breakpoints` | A stop in each of two patches, the locals of the patched caller, and the call stack back to `main` in the exe. |
| `debugger_values` | A struct local, a global before and after a patch changed it, the call stack, a conditional breakpoint in a loop, an array, and the arguments of a procedure that only the last patch adds, with a string. |
| `debugger_line_only_in_patch` | A breakpoint on a source line that only the patches have code on: it must stop in v2 and again in v3. The exe has no code on that line or after it. |
| `debugger_changed_proc` | A breakpoint on a source line of a procedure that the exe has and that each patch changes: it must stop in the body of the exe, then of v2, then of v3, and never in an old body. |
| `debugger_stepping` | At a breakpoint on a call in `main`, which stays in the exe: a step into the called procedure must arrive in its newest body, through the jump from the old body into the patch. Then a step over a line, a local, and the return value when the procedure finishes. |
| `debugger_kept_values` | The values that the code uses: a `@static`, which keeps its value across patches, a global that a patch adds and the next patch keeps, a `@thread_local` and a global of the exe. A patch module also has its own copies of these variables, which the code does not use. |

When the debugger is not installed, the script skips the test. In CI (`CI` is set), a missing debugger is a failure. The log of each run is in the test directory: `cdb.log`, `gdb.log` or `lldb.log`.

cdb is in the Debugging Tools for Windows, a feature of the Windows SDK.

## CI

The workflow uses the latest release of Odin, not Odin master.

| Jobs | Runner | Matrix |
| --- | --- | --- |
| `Windows x64` | `windows-2025` (its image has cdb) | `-o:none`, `-o:minimal`, `-o:speed` |
| `Linux x64` | `ubuntu-latest`, with `lld`, `gdb` and `lldb` from apt | the three `-o:` levels, each as a PIE and with `-reloc-mode:static` |
| `macOS ARM` | `macos-15`, with `llvm@20` and `lld` from Homebrew | the three `-o:` levels |

Each job runs the tests. The `-o:none` jobs then run the debugger tests as a separate step, also when the tests failed. The output of each step has the full debugger log. Each job writes a table of the results to its summary.
