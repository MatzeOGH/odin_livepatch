# livepatch demo: raylib + microui

Bouncing balls with a microui panel. Edit the code, and the running window changes. The
balls keep their positions and velocities.

## Build and run

Odin must be on your `PATH`, or set `ODIN` to the full path of `odin` in the shell that
runs the demo.

```sh
cd examples
./build_livepatch.sh   # Windows: .\build_livepatch.bat
./demo                 # Windows: demo.exe
```

## Patch it

1. Edit the `frame` proc in `main.odin`. For example, change a slider range, add a widget,
   or change the bounce damping (`* 0.86`).
2. Save the file, or press **F5** in the window.

The change appears, and the **reloads** counter goes up. The build runs on a worker thread
(`patch_start()`), so the window keeps running. If the build fails, the window shows the
error in red, and the old code keeps running.

## Feature demos

Each `DEMO_n` constant at the top of `main.odin` turns on one feature. Set it to `true`
and save. Set it to `false` and save to go back.

| Demo | Feature | What you see |
| --- | --- | --- |
| 1 | Type layout change | `Ball` gets a `trail` field. `after_patch` copies the state into the new layout, and the balls get trails. |
| 2 | Stored procedure pointer | `ball_draw` points to `draw_ball`. The balls get an outline, because the pointer calls the newest body. |
| 3 | `@static` local | A frame counter starts at 0 and does not reset on later patches. |
| 4 | Global that a patch adds | A **Wind** slider. `wind` starts at 40 and keeps its value on later patches. |
| 5 | Procedure that a patch adds | `draw_grid` draws a grid behind the balls. |
| 6 | Build error | The error shows in red, and the old code keeps running. |

Change `#load("image_v1.png")` to `image_v2.png` and save to swap the picture in the
corner. The post-patch hook finds the new bytes, and `after_patch` loads the new texture.

## How the demo keeps its state

`State` is on the heap behind the global `state` pointer, so its layout can change. The
post-patch hook records the old and new type info. `after_patch` runs in the main loop
after the patch and copies each field by name. A new field starts at zero.

`main` never returns, so it keeps its old code. Put the per-frame logic in procedures that
`main` calls.

A patch cannot call a raylib or microui procedure that the first build did not use. Rebuild
the demo for this. `prime_widgets` puts all microui widgets in the first build.

## Debugging

Start the demo under a debugger, set a breakpoint in `frame`, then edit and save. The
breakpoint stops in the new code. On Linux with gdb, first run
`handle SIG62 nostop noprint pass`. See [Debugging](../README.md#debugging).

## Files

- `main.odin`: the main loop, the patch triggers, and the `frame` proc to edit.
- `mu_raylib.odin`: the microui backend for raylib.
- `build_livepatch.bat`, `build_livepatch.sh`: build the demo and the patch objects.
- `image_v1.png`, `image_v2.png`: the pictures for the `#load` swap.
