# livepatch for Odin and Windows x64

Change code in a running program and retarget it in place, no restart. A developer tool
for fast iteration, Windows/x64 only. Not a shipping feature.

> **Work in progress and largely untested.** Expect crashes, gaps, and breaking changes.
> Do not depend on it.

## Supported features

- Windows on x64.
- Change the body of any named procedure. Callers run the new body on the next call.
- Add new named procedures. Callers reach them through the patched call sites.
- Keep package-level globals across every patch. New code reads the value the old code left.
- Keep `@static` locals and file-private globals across every patch, first one included, when
  the exe is built with `/MAP`. `patch()` reads their live address from the map.
- Keep a global that a patch adds. It takes its initial value on the patch that adds it, then
  persists like a base global.
- Keep procedure pointers (`&proc`) valid. A stored pointer reaches the newest body.
- Change a type's layout when a migration hook moves the live instances (see
  [Migrating state across a type change](#migrating-state-across-a-type-change)).
- Migration hooks (`lp_pre` and `lp_post`) that receive the set of changed types.
- Watch `.odin` source files and report a settled change for the application to apply.
- Debug patched procedures in any Windows debugger (VS Code, Visual Studio, RAD Debugger,
  WinDbg). Breakpoints, stepping, locals, and call stacks work in the new code (see
  [Debugging patched code](#debugging-patched-code)).
- Stay in shipping source at no cost. Without `-define:LIVEPATCH=true`, `patch()` compiles
  to `return nil`.

## Unsupported features

- Any operating system other than Windows, and any CPU other than x64.
- A layout change to a value stored by value in a package global. Keep evolving state
  behind a pointer instead.
- A `typeid` or `any` captured before that type's layout changed. It no longer resolves
  to the right type.
- Anonymous procedures (proc literals). The patcher does not redirect them, so re-register
  stored callbacks after a patch.
- New `@thread_local` variables. A patch that adds one is rejected.
- Freeing old code. Old generations stay loaded, so restart after many patches.
- Migrating stack objects. Only heap state behind a stable pointer migrates.

The [What survives a patch, what does not](#what-survives-a-patch-what-does-not) section
covers the runtime detail behind these two lists.

One call does everything:

```odin
import "livepatch"

if err := livepatch.patch("build_livepatch.bat"); err != nil {
    log.error(err)   // old code keeps running; nothing was changed
}
```

`patch()` rebuilds your package to objects, links them into a DLL, loads the DLL next to the
running exe, and redirects every procedure to its new body. It blocks until the build finishes, the
pre/post hooks complete, and the switch is applied or rejected.

`livepatch` pauses other process threads while it runs hooks and publishes code.
Your application is still responsible for choosing an appropriate patch point and for
ensuring hooks do not need a lock held by another thread.

## Setup

### 1. Build script

Copy `build_livepatch.bat` next to your project and point it at your sources. It has two
modes: no argument builds the exe, an output directory rebuilds to objects (this is what
`patch()` calls).

```bat
@echo off
set PKG=%~dp0src
set EXE=%~dp0game.exe
set FLAGS=-debug -o:none -use-separate-modules -define:LIVEPATCH=true
set LINK=/OPT:NOREF /OPT:NOICF /MAP:%EXE:.exe=.map%

if "%~1"=="" (
    odin build "%PKG%" %FLAGS% -extra-linker-flags:"%LINK%" -out:"%EXE%"
) else (
    odin build "%PKG%" %FLAGS% -extra-linker-flags:"%LINK%" -build-mode:obj -out:"%~1/"
)
```

Every flag is mandatory. The same script builds the exe and the patch, so they can never
diverge. **Always build through this script.**

`/MAP` writes `<exe>.map` next to the exe. `patch()` finds every exe symbol in it:
procedures, globals, `@static` locals and file-private globals. Only the exe build needs
it. Without it, `patch()` fails with `No_Map`.

### 2. Call patch()

```odin
main :: proc() {
    for !should_quit {
        if key_pressed(.F5) {
            // Hooks run while other threads are paused. Choose a point where no
            // worker holds a lock or resource that a hook needs.
            _ = livepatch.patch("build_livepatch.bat")
            // Post hooks have finished and workers have resumed.
        }
        update()   // callees run new code from the next call
        render()
    }
}
```

### Watch source saves

`watch_start()` observes `.odin` files recursively below an explicit source root.
It only reports a settled change: call `watch_poll()` from the application's main
loop and apply the patch at the same safe point used for a manual patch.

```odin
watch, err := livepatch.watch_start("src")
if err != nil {
    log.error(err)
}
defer livepatch.watch_stop(&watch)

for !should_quit {
    if changed, err := livepatch.watch_poll(&watch); err != nil {
        log.error(err)
    } else if changed {
        if err := livepatch.patch("build_livepatch.bat"); err != nil {
            log.error(err) // old code keeps running
        }
    }

    update()
    render()
}
```

The watcher does not build or patch from a background thread. It debounces editor
write bursts, then leaves the application to choose the thread-safe moment for
`patch()`. Only a change to a `.odin` file (save, add, remove or rename) triggers
a patch. Other files and directories do not. If you move a directory of sources
into or out of the root, save a `.odin` file or call `patch()` to apply the change.
Relative source roots are resolved relative to the running exe, as are relative
build-script paths.

The script path is resolved relative to the exe. A procedure that never returns (the loop
above) keeps running its old body; keep per-frame logic in procedures called each frame so
they pick up new code.

`patch()` suspends other process threads before it invokes pre hooks. It keeps them
paused while it publishes procedure entries, slots, and the type table, and invokes post
hooks before resuming them. This prevents workers from entering new code before post
migration completes. A suspended thread may hold an allocator, I/O, or application lock,
so hooks must not allocate, block, or acquire locks that another thread could hold.

`patch()` returns `nil` on success, or a `livepatch.Error`
(`Build_Failed`, `No_Map`, `No_Objects_Mapped`, `Too_Few_Objects`, `Unresolved_Symbol`,
`Load_Failed`, `Breakpoint_In_Redirect`, `Commit_Failed`, `Patch_In_Progress`). On an error,
nothing changes.
`Unresolved_Symbol` names what the new code references but cannot bind, such as a new
`@thread_local`. `Build_Failed` and `Load_Failed` have a `kind` enum, an `os_error`, and an
`output` with the compiler or linker output.
The strings in an error are on the heap. Free them with `livepatch.error_delete(err)`.
`Breakpoint_In_Redirect` is described in [Debugging patched code](#debugging-patched-code).
Without `-define:LIVEPATCH=true` it compiles to `return nil`, so the call can stay in your
shipping source permanently.

### Build without stopping the app

`patch()` stops the calling thread for the whole build, about the compile time. To keep
the app running, use `patch_start()` and `patch_poll()` instead. `patch_start()` starts the
build, the link and the load on a worker thread and returns at once. Call `patch_poll()`
once per frame, at the same safe point as `patch()`. When the build is done,
`patch_poll()` applies the patch there (the commit and the hooks, about 1 ms) and returns
`finished = true` with the result.

```odin
patch_again := false
for !should_quit {
    if source_changed() {
        if _, busy := livepatch.patch_start("build_livepatch.bat").(livepatch.Patch_In_Progress); busy {
            patch_again = true // one patch builds at a time; build again after it
        }
    }
    if finished, err := livepatch.patch_poll(); finished {
        if err != nil {
            log.error(err) // old code keeps running
        }
        if patch_again {
            patch_again = false
            livepatch.patch_start("build_livepatch.bat")
        }
    }
    update()
    render()
}
```

Only one patch builds at a time. While it builds, `patch_start()` and `patch()` return
`Patch_In_Progress`. The time from a save to the new code is the same as with `patch()`.
The compiler uses all CPU cores, so the frame rate can drop during the build. To keep a
core free, add `-thread-count:N` to the build script.

## Build defines

Three `-define` flags control livepatch. Set them in the build script.

| Define | Default | Effect |
| --- | --- | --- |
| `LIVEPATCH` | `false` | Compiles the body of `patch()`, `patch_start()`, `patch_poll()`, and the watcher procedures. When it is off, those calls compile to no-ops (`patch()` returns `nil`, `watch_poll()` reports no change), so the calls stay in shipping source at no cost. |
| `LIVEPATCH_TIMINGS` | `false` | Prints a per-phase timing report to stderr after each patch. The timers always run, so this flag gates only the print. Set it with `-define:LIVEPATCH_TIMINGS=true`. |
| `LIVEPATCH_TOAST` | `false` | Shows a Windows toast after each patch with the total patch time. A livepatch icon stays in the tray until the process stops. Set it with `-define:LIVEPATCH_TOAST=true`. |

The timing report shows one line per phase, plus the object, symbol, redirect, and slot counts:

```
[livepatch] objects=44 symbols=2508 redirects=660 slots=34
[livepatch]   build     450.0 ms  (compile)
[livepatch]   bind       20.0 ms
[livepatch]   link      160.0 ms  (link + load)
[livepatch]   diff        0.6 ms
[livepatch]   commit     56.0 ms
```

`build` is the compile step (the build script). `bind` decides where each symbol binds and
rewrites the objects. `link` links the patch DLL and loads it. `diff` is the type diff, and
`commit` is the halt-world write step.

## Linkers

`patch()` reads every exe symbol from the exe's `.map` (see [Setup](#1-build-script)). The map must be in the MSVC format. Choose the linker with
Odin's `-linker:` flag.

| `-linker:` | `/MAP` | Works with `patch()` |
| --- | --- | --- |
| `default` (MSVC `link.exe`) | MSVC format | Yes |
| `lld` | MSVC format | Yes |
| `radlink` | Not supported | No: `patch()` fails with `No_Map` |

The default linker and `lld` both write the map format the parser reads. `radlink` does
not implement `/MAP`: a build that passes the flag to it fails with
`switch "MAP" is not implemented`. Link with `default` or `lld`.

The patch DLL is always linked with `lld-link.exe` from the Odin distribution
that built the exe (`ODIN_ROOT/bin/lld-link.exe`), whatever linker builds the exe. MSVC is
not necessary for the patch.

## Debugging patched code

Each patch is a real DLL with a PDB that the linker writes:
`<exe dir>/livepatch_mod/lp_<pid>_g<N>.dll` and `.pdb`. The DLL loads like any other DLL, so
a debugger loads its PDB and binds your breakpoints in it. This works in VS Code (the
`cppvsdbg` debugger), Visual Studio, RAD Debugger, and WinDbg, with no special setup. The
name is different for each patch, so a debugger never uses the PDB of an earlier patch.

A source breakpoint binds in every module that has the line. After a patch, the exe and
each earlier patch DLL also have it. Only the newest copy runs, so usually only that copy
hits. The exception is a breakpoint on the `proc` line itself, set before the first patch:
it also hits once in the exe copy on each call, and then the call continues into the new
code.

You can set and remove breakpoints at any time, before or after a patch. `patch()`
overwrites the first bytes of each old procedure in the exe with a jump, and a debugger
breakpoint can be on these bytes. The jump is made so that it works while the breakpoint
is set and also after the debugger removes it (redirect.odin explains how).

`Breakpoint_In_Redirect` remains only for rare cases: breakpoints on both the `proc` line and
the first line of a small procedure, both set before the first patch. Remove one of them
and patch again. Nothing changes when `patch()` returns this error.

The patch DLLs stay loaded until the process ends, and `patch()` deletes the old files on
the first patch of the next run. In VS Code, use forward slashes in a `launch.json`
`environment` value, for example `"ODIN": "C:/odin/odin.exe"`. The debugger removes
backslashes from these values.

## Try it

`examples/` is a runnable raylib + microui scene wired for livepatch. It shows the whole
loop: edit a proc, press F5, and the running window changes while the state stays. Odin
must be on your `PATH`.

```bat
cd examples
.\build_livepatch.bat
demo.exe
```

Then edit the `frame` proc in `main.odin`, save, and press F5 in the window. See
[`examples/README.md`](examples/README.md) for the details.

## Importing the package

This repository holds the package in `livepatch/`. The example imports it with a relative
path (`import lp "../livepatch"`). For your own project, use a relative import, add a
collection (`-collection:livepatch=path/to/livepatch`), or copy the package into your Odin
`core/` and import it as `core:livepatch`.

### Other targets

The package compiles on every target. On anything other than Windows x64 (Windows on ARM64
included), `patch()` and the watcher are no-op stubs (`patch()` returns `nil`, `watch_poll()` reports no change). So you
can call them unconditionally and keep the package imported in a cross-platform project
without any build tags of your own. Live patching only happens on Windows/x64.

## What survives a patch, what does not

Preserved:

- Package-level globals keep their value across patches.
- **`@static` locals and file-private globals** keep their value across every patch, the
  first one included. New code uses their exe storage, found in the map.
- **A global that a patch adds** takes its initial value on the patch that adds it, because
  the base exe has no copy to seed from, then persists like a base global.
- Procedure pointers (`&proc`) stay valid — they reach the newest body.
- In-flight frames finish their old body; the next call runs new code.

Reset or unsafe (the ones that bite):

- **Changing the layout of a value that lives in a package global is unsafe.** The global
  keeps its fixed address and old storage; new code writing new fields can run off the end
  and corrupt the next global. Keep evolving state behind a pointer and migrate it (below).
- A **`typeid` or `any`** captured before you change that type's layout no longer resolves
  to the right type after the patch. Don't store long-lived `any` of types you're editing.
- **Anonymous procedures** (proc literals) are not redirected; a stored pointer to one
  keeps calling old code. Re-register callbacks after `patch()`, or use named procs.
- Changing a procedure's **signature** invalidates pointers stored under the old signature;
  re-register them.
- New `@thread_local` variables are rejected. Old code is never freed — restart after many
  patches.

## Migrating state across a type change

Register a migration hook by putting a proc pointer in a named linker section. The patcher
finds it (no registration call) and passes the set of types whose layout changed.

```odin
@(link_section="lp_pre",  export) _pre  := proc(changed: []livepatch.Type_Change) {
    // runs before the switch, on the old code
}
@(link_section="lp_post", export) _post := proc(changed: []livepatch.Type_Change) {
    // runs after the switch, on the new code: rewrite live instances here
    for c in changed {
        // c.name, c.old and c.new are the old/new ^runtime.Type_Info
    }
}
```

`@(export)` is required or the pointer is dropped as unreferenced. Hooks added by a patch
(absent from the first build) do not fire; declare them before the base build.

Use hooks as a two-phase migration:

1. The pre hook runs old code after other process threads are paused and before
   publication. It serializes or detaches old-layout objects into application-owned
   intermediate storage prepared before calling `patch()`.
2. The post hook runs new code after publication while those threads remain paused. It
   restores from that storage and publishes the completed new state.
3. `patch()` resumes the paused threads only after all post hooks complete.

The cache belongs to the application, normally through a stable pointer global whose
layout does not change. Prepare any allocation-backed cache before calling `patch()`;
hooks cannot safely allocate it while other threads are paused. Do not put a by-value
instance of a changing type in the cache; use a stable snapshot format such as IDs,
primitives, strings with explicit ownership, or versioned serialized data. Stack objects
cannot be migrated. Existing global storage keeps its original address and layout;
changing its layout is unsupported, so migrate heap-owned state behind a stable pointer
instead.

For a multithreaded application, call `patch()` at a point where workers do not hold any
resource a hook needs. A single-threaded patch-in-the-main-loop application already has this
property without additional synchronization.
