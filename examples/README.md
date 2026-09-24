# Livepatch demo — raylib + microui

A bouncing-ball scene with a microui control panel, wired for livepatch. Edit the code
and the running program changes with no restart. The balls keep their exact positions
and velocities. The state survives because it lives in a package global, and livepatch
preserves globals across a patch.

Two ways to trigger a patch:

- Press **F5** in the window, or
- just save a `.odin` file. A file watcher rebuilds on the next frame.

Windows / x64 only.

## Build and run

Odin must be on your `PATH`. Build the host once with the livepatch build script, then
run it:

```bat
cd examples
.\build_livepatch.bat
demo.exe
```

If Odin is not on your `PATH`, set `ODIN` to its full path first. The build script and the
in-app rebuild (F5 or a save) both read that variable, so set it in the same shell that
runs `demo.exe`:

```bat
set ODIN=C:\path\to\odin.exe
.\build_livepatch.bat
demo.exe
```

The first form of the script builds `demo.exe` and `demo.pdb`. The `patch()` call uses
the second form of the same script to rebuild the objects, so the two builds can never
diverge. Every flag in the script is required. A build without `/MAP` makes `patch()`
fail with `No_Map`.

## The demo

1. In the open window, drag the panel. Move the **Gravity** and **Speed** sliders. Toggle
   **Paused**. Press **Reset positions**.
2. Open `main.odin` and edit the `frame` proc. For example:
   - change a slider range, such as `mu.slider(ctx, &s.gravity, 0, 3000)`
   - add a widget, such as another `mu.checkbox` or `mu.button`
   - change the bounce damping (`* 0.86`) or the wall logic
   - in `seed_state`, change `s.bg` or the ball colors
   - change `#load("image_v1.png")` to `image_v2.png` to swap the picture in the corner
3. Save the file (or press **F5**). `demo.exe` rebuilds the patch and loads it. The change
   appears, and the balls keep moving from their old positions. The on-screen **reloads**
   counter goes up, because the post-patch hook increments it.

The demo builds the patch with `patch_start()` on a worker thread, so the window keeps
running during the build. `patch_poll()` applies the patch at the top of the next frame. On
a build error the demo shows the first line of the error in red and leaves the running
program unchanged.

## Feature demos

`main.odin` has code for more livepatch features behind the constants `DEMO_1` to
`DEMO_6` at the top of the file. To enable a feature while the demo runs, set its constant
to `true` and save. You can enable them in any order.

| Demo | Feature | What you see |
| --- | --- | --- |
| 1 | Type layout change with migration | Adds a `trail` field to `Ball`. The balls keep moving and get trails. The post-patch hook records the old and new `State` types, and `after_patch` copies each field by name into a block with the new layout. |
| 2 | A stored procedure pointer | `ball_draw` holds a pointer to `draw_ball` from the base build. After the patch, the balls get a white outline, because the pointer calls the newest body. |
| 3 | A `@static` local | A frame counter in the panel. It starts at 0 on the patch that adds it, then does not reset on later patches. |
| 4 | A global that a patch adds | A **Wind** slider. `wind` starts at 40 on the patch that adds it, then keeps the slider value on later patches. |
| 5 | A procedure that a patch adds | `draw_grid` draws a grid behind the balls. |
| 6 | A build error | The error shows in red at the bottom of the window, and the old code keeps running. Set it back to `false` and save to continue. |

To go back, set the constant to `false` and save. For demo 1, this is one more layout
change: `trail` becomes an array with no elements, and the migration drops the old trail
points.

The picture in the corner also shows a hook: change `#load("image_v1.png")` to
`image_v2.png` and save. The post-patch hook compares the hash of the new bytes with the
hash of the loaded bytes, and `after_patch` loads the new texture when they differ.

## Debugging

Start `demo.exe` under a debugger, for example RAD Debugger or VS Code with the
`cppvsdbg` debugger. Set a breakpoint in `frame`, edit `frame`, and save. After the patch,
the breakpoint hits in the new code in `livepatch_mod/lp_<pid>_g<N>.dll`, with locals and a
full call stack.

You can set and remove breakpoints before and after a patch. See the main README for the
one rare case that `patch()` refuses.

## What you can and cannot change live

- **Live:** anything in `frame`, `draw_scene`, `seed_state`, or the `State` fields —
  values, colors, physics, layout, and any widget the base build already used.
- **Also live:** any raylib or microui procedure the base build already references. The
  `prime_widgets` proc pulls the full microui widget set into the exe for this reason, so
  a live edit can add any of them.
- **Needs a full rebuild:** a call to a procedure that the base build never compiled in.
  Its code is not in the host, and a patch object does not carry it. Rebuild the host once.
- **Also live, through the migration path:** a new, removed, or reordered field on `State`
  or `Ball`. `after_patch` copies each field by name. A new field is zero at first and
  preserved from then on.

## Files

- `main.odin` — setup, frame loop, the F5 and watcher triggers, and the editable `frame`
  proc (edit this).
- `mu_raylib.odin` — the microui-to-raylib backend (atlas texture, input, command rendering).
- `build_livepatch.bat` — the build script for both the host and the patch objects.
- `image_v1.png`, `image_v2.png` — the two pictures for the live `#load` swap.

## Non-livepatch build

The demo runs the same without livepatch. `patch_start()` and `patch_poll()` are then
no-ops that return `nil`, and the watcher reports no change:

```bat
odin build . -out:demo.exe
```
