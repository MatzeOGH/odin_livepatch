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
- Keep new globals, `@static`, and file-private globals across later patches. Each takes its
  initial value on the patch that adds it, then persists like a base global.
- Keep procedure pointers (`&proc`) valid. A stored pointer reaches the newest body.
- Change a type's layout when a migration hook moves the live instances (see
  [Migrating state across a type change](#migrating-state-across-a-type-change)).
- Migration hooks (`lp_pre` and `lp_post`) that receive the set of changed types.
- Watch `.odin` source files and report a settled change for the application to apply.
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
- Debugging patched procedures. A debugger cannot break in or step through a patched body.
- Freeing old code. Old generations stay mapped, so restart after many patches.
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

`patch()` rebuilds your package to objects, maps them next to the running exe, and
redirects every procedure to its new body. It blocks until the build finishes, the
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
set FLAGS=-debug -o:none -use-separate-modules -define:LIVEPATCH=true -extra-linker-flags:"/OPT:NOREF /OPT:NOICF"

if "%~1"=="" (
    odin build "%PKG%" %FLAGS% -out:"%EXE%"
) else (
    odin build "%PKG%" %FLAGS% -build-mode:obj -out:"%~1/"
)
```

Every flag is mandatory. The same script builds the exe and the patch, so they can never
diverge. **Always build through this script** — a build without `-debug` makes `patch()`
silently do nothing and reset your globals.

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
        pause_workers_for_patch()
        if err := livepatch.patch("build_livepatch.bat"); err != nil {
            log.error(err) // old code keeps running
        }
        resume_workers_after_patch()
    }

    update()
    render()
}
```

The watcher does not build or patch from a background thread. It debounces editor
write bursts, then leaves the application to choose the thread-safe moment for
`patch()`. Saves and additions of `.odin` files trigger a patch. Removals and
renames away from the root also trigger one conservatively, because Windows
cannot tell whether a removed entry was a directory containing source files.
Relative source roots are resolved relative to the running exe, as are relative
build-script paths.

The watcher ignores the object output directory (`<exe dir>/livepatch`). `patch()`
empties and refills that directory on every patch. If the watched root is the exe
directory, that churn would otherwise look like a source change and start another
patch, so the watcher skips it.

The script path is resolved relative to the exe. A procedure that never returns (the loop
above) keeps running its old body; keep per-frame logic in procedures called each frame so
they pick up new code.

`patch()` suspends other process threads before it invokes pre hooks. It keeps them
paused while it publishes procedure entries, slots, and the type table, and invokes post
hooks before resuming them. This prevents workers from entering new code before post
migration completes. A suspended thread may hold an allocator, I/O, or application lock,
so hooks must not allocate, block, or acquire locks that another thread could hold.

`patch()` returns `nil` on success, or a `livepatch.Error`
(`Build_Failed`, `No_Pdb`, `No_Objects_Mapped`, `Too_Few_Objects`, `Commit_Failed`).
Without `-define:LIVEPATCH=true` it compiles to `return nil`, so the call can stay in your
shipping source permanently.

## Build defines

Two `-define` flags control livepatch. Set them in the build script.

| Define | Default | Effect |
| --- | --- | --- |
| `LIVEPATCH` | `false` | Compiles the body of `patch()`, `watch_start()`, and `watch_poll()`. When it is off, those calls compile to no-ops (`patch()` returns `nil`), so the calls stay in shipping source at no cost. A build without it (or without `-debug`) makes `patch()` do nothing. |
| `LIVEPATCH_TIMINGS` | `false` | Prints a per-phase timing report to stderr after each patch. The timers always run, so this flag gates only the print. Set it with `-define:LIVEPATCH_TIMINGS=true`. |

The timing report shows one line per phase, plus the object, symbol, redirect, and slot counts:

```
[livepatch] objects=42 symbols=18734 redirects=311 slots=57
[livepatch]   build     1240.0 ms  (compile)
[livepatch]   map          3.1 ms
[livepatch]   merge        8.4 ms
[livepatch]   resolve      5.2 ms
[livepatch]   relocate     6.7 ms
[livepatch]   diff         1.9 ms
[livepatch]   commit       2.0 ms
```

`build` is the compile step (the build script). The other phases are the in-process
map, merge, relocate, type diff, and halt-world commit.

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
name.

### Non-Windows builds

The package compiles on every target. On anything other than Windows, `patch()` and the
watcher are no-op stubs (`patch()` returns `nil`, `watch_poll()` reports no change). So you
can call them unconditionally and keep the package imported in a cross-platform project
without any build tags of your own. Live patching only happens on Windows/x64.

## What survives a patch, what does not

Preserved:

- Package-level globals keep their value across patches.
- **New globals, `@static`, and file-private globals** persist across later patches. The
  patch that adds one seeds it from its initializer, then a process-lifetime store keyed by
  a build-stable name carries the value forward. You no longer have to declare kept state as
  a package-level global before the first build.
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
- New `@thread_local` variables are rejected. A debugger cannot break in or step through a
  patched procedure. Old code is never freed — restart after many patches.

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
