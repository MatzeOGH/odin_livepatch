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
diverge. Every flag in the script is required. A build without `-debug` makes `patch()`
do nothing.

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

`patch()` blocks while it rebuilds and applies the patch, so the window freezes for a
second or two. On a build error it prints the error and leaves the running program
unchanged.

## What you can and cannot change live

- **Live:** anything in `frame`, `draw_scene`, `seed_state`, or the `State` fields —
  values, colors, physics, layout, and any widget the base build already used.
- **Also live:** any raylib or microui procedure the base build already references. The
  `prime_widgets` proc pulls the full microui widget set into the exe for this reason, so
  a live edit can add any of them.
- **Needs a full rebuild:** a call to a procedure that the base build never compiled in.
  Its code is not in the host, and a patch object does not carry it. Rebuild the host once.
- **Also live, through the migration path:** a new field on `State`. New globals and new
  struct fields are zero at first and preserved from then on.

## Files

- `main.odin` — setup, frame loop, the F5 and watcher triggers, and the editable `frame`
  proc (edit this).
- `mu_raylib.odin` — the microui-to-raylib backend (atlas texture, input, command rendering).
- `build_livepatch.bat` — the build script for both the host and the patch objects.
- `image_v1.png`, `image_v2.png` — the two pictures for the live `#load` swap.

## Non-livepatch build

The demo runs the same without livepatch. `patch()` is then a no-op that returns an error
you can ignore:

```bat
odin build . -out:demo.exe
```
