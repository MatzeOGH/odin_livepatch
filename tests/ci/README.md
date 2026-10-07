# CI tests

Each directory here is one test. GitHub Actions runs all of them (`.github/workflows/tests.yml`).

## Rules for a test

- A test checks one feature.
- A test has only its own files: `build.bat` and `main.odin`. It does not use a shared script.
- `VERSION :: #config(VERSION, 1)` selects the version of the code. Use `when VERSION == N` for code that changes shape.
- The exe is version 1. The test then applies version 2 and version 3 as patches, or more. Two patches find errors in a patch that works only one time.
- The runner builds each test at `-o:none` and at `-o:speed`.

To add a test, make a new directory. The runner and the workflow find it.

## Run the tests

All tests:

```powershell
tests\ci\run.ps1
```

One test:

```powershell
tests\ci\run.ps1 change_proc
```

One test by hand, at the `-o:` level in `OPT` (default: `none`):

```powershell
tests\ci\change_proc\build.bat
tests\ci\change_proc\app.exe
```

`ODIN` is the compiler (default: `odin` on the PATH). If you set `ODIN_ROOT`, it must point to the same Odin as the compiler. A different `ODIN_ROOT` crashes the compiler.

## CI

The workflow runs on `windows-2022`. It uses the latest release of Odin, not Odin master.
