# CI tests

Each directory here is one test. GitHub Actions runs all of them (`.github/workflows/tests.yml`).

## Rules for a test

- A test checks one feature. The first comment in `main.odin` tells which.
- A test has only its own files: `build.bat` and `main.odin` (and more `.odin` files if the feature needs them). It does not use a shared script.
- `VERSION :: #config(VERSION, 1)` selects the version of the code. Use `when VERSION == N` for code that changes shape. The source files do not change during a test.
- The exe is version 1. The test then applies version 2 and version 3 as patches, or more. Two patches find errors in a patch that works only one time.
- Each test runs at `-o:none` and at `-o:speed`. Each test must also build with `LIVEPATCH=false`.
- The functional tests do not use the source watcher. The `watcher` test checks it on its own.

To add a test, copy a directory and change `main.odin`. The runner and the workflow find the new directory.

## The harness

The end of each `main.odin` is the same harness: `check`, `patch_to` and `main`. A test defines `LAST_VERSION`, `setup` and `checks(v)`. `main` calls `setup` one time, then `checks(1)`, and then patches to each version and calls `checks(v)` again.

`main` stays in its version 1 body through all patches, so it does no checks itself. At `-o:speed`, LLVM can put a result of version 1 code into `main` as a constant. `checks` is a new call after each patch, so it runs the new body. A loop that runs through the patches has the same problem: it must read a global or a `@thread_local`, so that LLVM cannot fold the result.

A test that must do more between the patches, for example to check a rejected patch, has its own `main`.

## Run the tests

All tests, at both `-o:` levels:

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

## CI

The workflow runs on `windows-2022`, with one job for each `-o:` level. It uses the latest release of Odin, not Odin master.
