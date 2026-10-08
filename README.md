# Odin Livepatch

Change the code of a running Odin program without a restart. Windows and Linux, x64 only.

> **Build Odin from master!**

This is a development tool. It is on only with `-define:LIVEPATCH=true`. Without it, every
call compiles to a no-op, so the calls can stay in shipping source.

> **Work in progress.** Expect crashes and breaking changes.

```odin
import "livepatch"

if err := livepatch.patch("build_livepatch.bat"); err != nil {
    log.error(err) // the old code keeps running, nothing changed
}
```

`patch()` runs your build script, links the objects into a patch module, loads it next to
the exe, and redirects each procedure to its new body. Callers run the new body on the
next call.

**livepatch halts the world.** While `patch()` writes the new code and runs the migration
hooks, all other threads in the process are paused. No thread runs a mix of old and new
code. The pause is short, a few milliseconds, but your code must allow it:

- Call `patch()` from a safe point, such as the top of the main loop.
- In a hook, do not allocate, log, or take a lock. A paused thread can hold that lock, and
  the hook then waits forever.

## Try it

```sh
cd examples
./build_livepatch.sh   # Windows: .\build_livepatch.bat
./demo                 # Windows: demo.exe
```

Edit `frame` in `examples/main.odin`, save, and press F5. See
[examples/README.md](examples/README.md).

## Setup

1. Copy `examples/build_livepatch.bat` or `examples/build_livepatch.sh` next to your project.
   Set the package and exe paths in it.
2. Build the exe with the script and no argument. `patch()` calls the same script with an
   output directory to build the patch objects.
3. Call `patch()` at a safe point in your main loop.

These flags are mandatory: `-use-separate-modules -define:LIVEPATCH=true`. Add `-debug` to
use a debugger. See [Debugging](#debugging). On
Windows, the exe link also needs `/OPT:NOREF /OPT:NOICF /MAP`. On Linux, do not strip the
exe. `patch()` reads its symbol table. See [Optimizations](#optimizations) and
[Linkers](#linkers).

`patch()` sets `LIVEPATCH_DEBUGGER=0` when no debugger is attached. The example scripts
then drop `-debug` from the patch build, which makes it faster. If your code uses
`when ODIN_DEBUG`, such a patch runs the other branch.

Import the package with a relative path, a collection
(`-collection:livepatch=path/to/livepatch`), or copy it into `core/`.

## API

| Procedure | Use |
| --- | --- |
| `patch(script)` | Build and apply a patch. Blocks for the build. |
| `patch_start(script)`, `patch_poll()` | Build on a worker thread. Call `patch_poll()` each frame. It applies the patch when the build is done. |
| `watch_start(root)`, `watch_poll(&w)`, `watch_stop(&w)` | Report a settled change to a `.odin` file below `root`. You call `patch()`. |
| `error_delete(err)` | Free the strings in an error. |

On an error, nothing changes. See [Errors and crashes](#errors-and-crashes).

On Linux, the pause uses signal 62. To use a different signal, set
`-define:LIVEPATCH_SIGNAL=<n>`. A thread that blocks this signal keeps running. A debugger
needs a setup for this signal. See [Linux debugger setup](#linux-debugger-setup).

| Define | Default | Effect |
| --- | --- | --- |
| `LIVEPATCH` | `false` | Turns the package on. |
| `LIVEPATCH_TIMINGS` | `false` | Prints the time of each phase to stderr. |
| `LIVEPATCH_TOAST` | `false` | Shows a notification after each patch. |
| `LIVEPATCH_LINKER` | `"default"` | The linker of the patch module, with the names of `-linker:`. See [Linkers](#linkers). |

## What a patch keeps

livepatch matches the code and data of a patch to the exe by their link names.

- Package globals, `@static` locals, and file-private globals keep their values.
- `@(rodata)` globals and `@(static, rodata)` locals always get the values of the patch. When a
  patch removes `@(rodata)`, the variable gets new storage with its initial value from the
  patch: the exe copy is read-only.
- A global that a patch adds gets its initial value once, then persists. The initial value
  must be a constant. If the startup code must compute it, such as `table := make_table()` or
  a `map` literal, `patch()` returns `Global_Needs_Init`.
- Procedure pointers (`&proc`) go to the newest body.
- A pointer to a proc literal or to a nested procedure goes to the newest body, and its
  `@static` and `@thread_local` locals keep their values. This is true when its parent
  procedure (or the file scope) has the same number of literals in that file, or of nested
  procedures with that name.
- A generic instance over a local type is the same procedure after a patch, when its scope
  has the same number of local types with that name.
- A `@(private)` declaration keeps its pointers and values when a patch moves it to another
  file, unless another file has a private or public declaration with that name.
- A running call finishes its old body. A procedure that never returns, such as `main`,
  keeps its old body.

## Limits

- If a patch adds or removes a proc literal in a procedure, the literals of that procedure in
  that file are not redirected. A stored pointer to one of them keeps the old body. Register
  these callbacks again after the patch. The same is true for nested procedures with the
  same name. If such a procedure has a `@thread_local` local, the patch fails.

  ```odin
  register :: proc() {
      on_open = proc() { open_file() }
      on_save = proc() { save_file() }
      on_quit = proc() { quit() } // new in the patch: 3 literals, before 2
  }
  ```

  After this patch, `on_open` and `on_save` keep their old bodies until `register` runs again.
- A patch cannot add a `@thread_local` variable.
- A patch cannot add a global whose initial value the startup code computes (`Global_Needs_Init`).
- Old code stays in memory. Restart after many patches.
- On other targets, the API compiles to no-ops.

## Errors and crashes

### Errors

When `patch()` returns an error, the running program does not change.

| Error | Cause |
| --- | --- |
| `Build_Failed` | The build script failed or did not start. `output` has the compiler output. |
| `No_Map` | Windows: the exe has no `.map` file (no `/MAP`). Linux: the exe is stripped. |
| `No_Objects_Mapped` | An object file could not be read or rewritten. |
| `Unresolved_Symbol` | The new code uses a symbol that `patch()` cannot bind, such as a new `@thread_local`. |
| `Global_Grew` | Linux: a global stored by value (or a `@static` local) is larger in the patch than its storage in the exe or in an earlier patch. New code would write past its end. `name`, `old_size` and `new_size` tell which. |
| `Global_Needs_Init` | The patch adds a global whose initial value the startup code computes, such as `n := count()` or a `map` literal. A patch does not run the startup code, so the global would stay zero. `name` is the global. |
| `Load_Failed` | The patch module could not be linked or loaded. `output` has the linker output. |
| `Breakpoint_In_Redirect` | Windows: two debugger breakpoints block the redirect. See [Debugging](#debugging). |
| `Commit_Failed` | The exe code could not be made writable. Linux: a hardened kernel or SELinux refuses `mprotect`. |
| `Patch_In_Progress` | A patch from `patch_start()` is not finished. |

The strings in an error are on the heap. Free them with `error_delete(err)`.

### Hangs and crashes

`patch()` cannot detect these problems. The program hangs, crashes, or uses incorrect data.

- **A hook allocates, logs, or takes a lock.** All other threads are paused. If a paused
  thread holds the allocator, I/O, or application lock, the hook waits forever. Allocate
  all memory for the migration before you call `patch()`.
- **A type layout changes in a global stored by value.** The global keeps its old storage. On
  Linux, `patch()` returns `Global_Grew` when the global is larger in the patch. On Windows, the
  object files have no symbol sizes, so new code writes past the end and corrupts the next
  global. When the size stays the same, new code reads the old bytes in the new layout. Put
  the state behind a pointer.
- **A type layout changes and no post hook migrates the heap data.** New code reads data in
  the old layout.
- **A type layout changes in a stack value.** A hook cannot migrate stack data. This
  includes the locals of `main` and of other procedures that never return.
- **A stored `typeid` or `any` refers to a changed type.** It resolves to the old type info.
- **A procedure signature changes and a stored pointer uses the old signature.** The call
  passes incorrect arguments. Store the pointer again after the patch.
- **A procedure signature changes and a procedure that never returns calls it.** `main` keeps
  its old body, so it calls the new body with the old arguments:

  ```odin
  main :: proc() {
      for !done {
          step(1) // compiled for `step :: proc(frames: int)`
      }
  }
  // The patch changes it to `step :: proc(dt: f64, scale: f64)`. main still passes one int.
  ```

  With `-o:speed`, LLVM can also put the result of a small procedure directly into `main`.
  For example, `limit :: proc() -> int { return 10 }` can become the constant 10 in `main`, and
  a patch to `limit` then has no effect there. Keep the loop in `main` short, and put the
  work in procedures that return.
- **Two proc literals or nested procedures change places.** livepatch matches them by their
  order in their procedure. When a patch changes the order and the count stays the same, a
  stored pointer goes to the other body:

  ```odin
  register :: proc() {
      on_open = proc() { open_file() } // first
      on_save = proc() { save_file() } // second
  }
  // The patch changes the order of the two lines. The pointer that the exe stored in
  // on_open now goes to the first literal of the patch: save_file.
  ```

  The same is true for two `@static` locals with one name in one procedure, and for two local
  types with one name. Register callbacks again after such a patch.
- **Linux: a thread blocks `LIVEPATCH_SIGNAL` and runs patched code.** `patch()` cannot
  pause this thread, so the thread can run code while `patch()` writes it.
- **A hook is new in the patch.** It does not run, so no migration occurs. Declare hooks in
  the first build.

## Migration hooks

Put a proc pointer in the `lp_pre` or `lp_post` section. The patcher finds it and gives it
the types whose layout changed.

```odin
@(link_section=livepatch.HOOK_PRE_SECTION, export)
_pre := proc(changed: []livepatch.Type_Change) {
    // old code: copy the old state to storage that you prepared before patch()
}
@(link_section=livepatch.HOOK_POST_SECTION, export)
_post := proc(changed: []livepatch.Type_Change) {
    // new code: rebuild the state. c.name, c.old, c.new for c in changed
}
```

`export` is mandatory. Declare the hooks in the first build. A hook that a patch adds does
not run.

## Optimizations

`-o:none`, `-o:minimal`, and `-o:speed` all work. The example scripts use `-o:none`. Use
`-o:speed` to patch a realtime program at full speed.

Inlined code is safe. Each patch rebuilds and redirects every procedure in the program, so
no caller keeps an old inlined copy.

Obey these two rules:

- Keep `-use-separate-modules`. It stops inlining across packages.
- Do not turn on link-time optimization (LTO). It merges the package objects.

Use the same `-o:` level for the exe and the patch. The script does this for you.

In an optimized build, the debugger can show some locals as optimized out.

## Linkers

**Windows exe** (Odin `-linker:` flag):

| Linker | Works |
| --- | --- |
| `default` (`radlink`) | Yes |
| `msvc` (MSVC `link.exe`) | Yes |
| `lld` | Yes |

Each linker needs `/OPT:NOREF /OPT:NOICF /MAP`. To use radlink, use `-linker:default`. Odin
rejects `-linker:radlink` on Windows ("not supported on this platform"), but the default is
radlink.

The example scripts select the linker of the exe and of the patch with one value, `LINKER`.
They give it to `-linker:` and to `-define:LIVEPATCH_LINKER`. Set `LINKER` in the script, or in
the environment before you build the exe.

**Windows patch DLL:** `patch()` always links it with `lld-link.exe` from the Odin install that
built the exe. `LIVEPATCH_LINKER` has no effect. MSVC is not necessary for the patch.

**Linux exe:** any linker that Odin uses works (GNU `ld`, `lld`, `mold`), as a PIE or with
`-reloc-mode:static`. A stripped exe or a fully static exe (`-static`) does not work.

**Linux patch module:** `patch()` links it with lld, mold, or GNU `ld`. `LIVEPATCH_LINKER=lld`
selects `ld.lld`, and `mold` selects `mold`. Another value is a name to find on `PATH`, such
as `ld.lld-18`, or a full path.

With `default`, `patch()` uses the first of `ld.lld`, `mold`, and `ld` that is on `PATH`.
`patch()` finds the linker on the first patch, and uses it for each later patch.

`patch()` runs the linker with `--version` to get its kind and its flags. GNU gold and other
linkers are not used. If no known linker is found, `patch()` fails with `Load_Failed`.

To add a linker, add its `--version` text and its flags to `LINKER_KINDS` in
`livepatch/platform_linux.odin`.

## Debugging

Breakpoints, stepping, locals, and call stacks work in the new code.

Debugging works when:

- The build script passes `-debug`, as the example scripts do. Without it, the exe and the
  patches have no debug info, and no breakpoint binds.
- A debugger is attached at the time of the patch. `patch()` writes debug info only then.
- The debugger is VS Code, Visual Studio, RAD Debugger, or WinDbg on Windows. Each patch is
  a DLL with a PDB, so no setup is necessary.
- The debugger is gdb or lldb on Linux, with the setup in
  [Linux debugger setup](#linux-debugger-setup).

Debugging does not work when:

- You attach the debugger after a patch. The patches made before have no debug info. Patch
  again.
- You set an lldb breakpoint by name, such as `main::helper`. lldb reads `::` as a C++ scope.
  Use a file and line, or `breakpoint set -r '^main::helper$'`.
- On Windows, you set breakpoints on the `proc` line and the first line of a small procedure
  before the first patch. `patch()` fails with `Breakpoint_In_Redirect`. Remove one of the
  breakpoints and patch again.

A breakpoint on the `proc` line, set before the first patch, also stops once in the old exe
copy on each call. The call then continues into the new code.

### Linux debugger setup

Linux cannot suspend a different thread. Thus `patch()` sends signal 62 (`LIVEPATCH_SIGNAL`)
to each other thread. The signal handler holds the thread until the patch is written.

A debugger gets each signal before the program. gdb stops at this signal by default. Then
each patch stops in the debugger once for each thread. Tell the debugger to give the signal
to the program and not to stop. Do not block the signal in the debugger. Without the
signal, the threads do not pause, and `patch()` fails with `Commit_Failed` after a long wait.

| Debugger | Signal | Breakpoints in a patch |
| --- | --- | --- |
| gdb | `handle SIG62 nostop noprint pass` | `set breakpoint pending on` |
| lldb | `process handle 62 --stop false --notify false --pass true` | `settings set plugin.jit-loader.gdb.enable on` |

lldb names the real-time signals `SIGRTMIN+<x>` and `SIGRTMAX-<x>`, and does not accept `SIG62`.
Thus give lldb the number. If you set `-define:LIVEPATCH_SIGNAL=<n>`, use `SIG<n>` for gdb and
`<n>` for lldb. Windows does not use a signal, so no setup is necessary there.

**VS Code**, with the CodeLLDB extension, in `.vscode/launch.json`:

```json
{
  "type": "lldb",
  "request": "launch",
  "name": "Debug demo (Linux)",
  "program": "${workspaceFolder}/examples/demo",
  "cwd": "${workspaceFolder}/examples",
  "initCommands": ["settings set plugin.jit-loader.gdb.enable on"],
  "preRunCommands": ["process handle 62 --stop false --notify false --pass true"]
}
```

**VS Code**, with the C/C++ extension and gdb:

```json
{
  "type": "cppdbg",
  "request": "launch",
  "name": "Debug demo (Linux, gdb)",
  "program": "${workspaceFolder}/examples/demo",
  "cwd": "${workspaceFolder}/examples",
  "MIMode": "gdb",
  "setupCommands": [
    { "text": "handle SIG62 nostop noprint pass" },
    { "text": "set breakpoint pending on" }
  ]
}
```

**Zed**, in `.zed/debug.json`. Zed uses CodeLLDB, so the commands are the same as for lldb:

```json
{
  "label": "Debug demo (Linux)",
  "adapter": "CodeLLDB",
  "request": "launch",
  "program": "$ZED_WORKTREE_ROOT/examples/demo",
  "cwd": "$ZED_WORKTREE_ROOT/examples",
  "initCommands": ["settings set plugin.jit-loader.gdb.enable on"],
  "preRunCommands": ["process handle 62 --stop false --notify false --pass true"]
}
```
