package livepatch_demo

// Livepatch demo: bouncing balls with a microui panel. Edit frame() (or any proc,
// color, or physics value below), and the running program changes with no restart:
//
//   - Press F5 in the window, or
//   - just save a .odin file: the watcher rebuilds on the next frame.
//
// The balls keep their positions and velocities, because that state lives in a package
// global that livepatch preserves across a patch.
//
// Each DEMO_n constant below turns on one livepatch feature. To enable a feature while the
// demo runs, set its constant to true and save. See README.md for what each one shows.
//
// Build the host with build_livepatch.bat, then run demo.exe.

import lp "../livepatch"

import "base:runtime"
import "core:fmt"
import "core:hash"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import mu "vendor:microui"
import rl "vendor:raylib"

// Set one to true and save to enable that demo. Set it back to false to disable it.
DEMO_1 :: false // a layout change: Ball gets a trail, and after_patch migrates the balls
DEMO_2 :: false // a change through a stored proc pointer: the balls get an outline
DEMO_3 :: false // a @static local: a frame counter that does not reset on a patch
DEMO_4 :: false // a global that a patch adds: a wind slider
DEMO_5 :: false // a procedure that a patch adds: a background grid
DEMO_6 :: false // a build error: the error shows on screen, and the old code keeps running

WIDTH   :: 900
HEIGHT  :: 600
N_BALLS :: 24

Ball :: struct {
	pos, vel: rl.Vector2,
	radius:   f32,
	color:    rl.Color,
	// A struct cannot contain `when`. When DEMO_1 is false, the array has no elements, so
	// a change of DEMO_1 changes the layout.
	trail:    [8 when DEMO_1 else 0]rl.Vector2,
}

// The whole app state. It is on the heap behind the `state` pointer, so its layout can
// change. When it changes, after_patch copies each field into a block with the new layout.
State :: struct {
	balls:   [N_BALLS]Ball,
	bg:      rl.Color,
	gravity: f32,
	speed:   f32,
	paused:  bool,
	reloads: int,
}

state: ^State
ctx:   mu.Context

// A live asset. Change the file name to image_v2.png, patch, and the picture in the
// corner swaps. #load embeds the bytes at build time, so only new code sees new bytes.
// main never returns and keeps its old code, so the post-patch hook does the check.
image_bytes :: #load("image_v1.png")
img_tex:     rl.Texture2D
img_hash:    u32  // the hash of the loaded bytes. A global, so it survives a patch.
img_pending: []u8 // new bytes from the hook, loaded by after_patch

// The hook sets these when the layout of State changes. after_patch migrates the state.
state_old, state_new: ^runtime.Type_Info

// The first line of the last patch error, drawn on screen.
last_error: cstring

// A proc pointer, stored once in the base build. A patch redirects draw_ball, so this
// pointer calls the newest body of draw_ball.
ball_draw: proc(b: Ball) = draw_ball

// It gets 40 on the patch that adds it, and it keeps its value after that.
when DEMO_4 {
	wind: f32 = 40
}

main :: proc() {
	rl.InitWindow(WIDTH, HEIGHT, "Odin livepatch demo edit frame(), press F5 or save")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	mu.init(&ctx)
	ctx.text_width  = mu.default_atlas_text_width
	ctx.text_height = mu.default_atlas_text_height

	atlas := atlas_texture()
	defer rl.UnloadTexture(atlas)

	img_tex  = load_image_texture(image_bytes)
	img_hash = hash.crc32(image_bytes)
	defer rl.UnloadTexture(img_tex)

	state = new(State)
	seed_state(state)

	// Watch this program's own source directory for saved .odin files. watch_poll only
	// reports a settled change. The build then runs on a worker thread, and the patch is
	// applied here in the main loop. A relative root is resolved against the exe.
	watcher, werr := lp.watch_start(filepath.dir(os.args[0]))
	if werr != nil {
		fmt.eprintln("watch:", werr)
	}
	defer lp.watch_stop(&watcher)

	patch_again := false // a save arrived while a patch was building

	for !rl.WindowShouldClose() {
		do_patch := rl.IsKeyPressed(.F5)
		if changed, poll_err := lp.watch_poll(&watcher); poll_err != nil {
			fmt.eprintln("watch:", poll_err)
		} else if changed {
			do_patch = true
		}

		// patch_start builds on a worker thread, so the window keeps running. patch_poll
		// applies the patch here, at the top of the frame, when the build is done. A save
		// during a build starts one more build after it. On a build error the old code
		// keeps running. (lp.patch() does the same in one call, but the window freezes
		// for the whole build.)
		if do_patch {
			if _, busy := lp.patch_start("build_livepatch.bat").(lp.Patch_In_Progress); busy {
				patch_again = true
			}
		}
		if finished, err := lp.patch_poll(); finished {
			after_patch(err)
			if patch_again {
				patch_again = false
				lp.patch_start("build_livepatch.bat")
			}
		}

		mu_handle_input(&ctx)
		frame(state, &ctx)

		// main keeps its old code, so it must not read fields of State. After a layout
		// change, a field can be at a different offset. frame and draw_scene get new code.
		rl.BeginDrawing()
		draw_scene(state)
		mu_render(&ctx, atlas)
		rl.EndDrawing()
	}
}

// Runs in the main loop after each patch. The other threads run again, so it can allocate
// and call raylib, which the hook must not do. main keeps its old code, but a patch
// redirects this proc, so its newest body runs.
after_patch :: proc(err: lp.Error) {
	defer lp.error_delete(err)
	delete(last_error)
	last_error = nil
	if err != nil {
		fmt.eprintln("livepatch:", err)
		msg := fmt.tprint(err)
		if b, ok := err.(lp.Build_Failed); ok && b.output != "" {
			msg = b.output
		}
		first, _, _ := strings.partition(strings.trim_space(msg), "\n")
		last_error = strings.clone_to_cstring(first)
		return
	}

	if state_new != nil {
		// Uses the size from the type info. size_of(State) in old code is the old size.
		fresh, _ := mem.alloc(state_new.size, state_new.align)
		copy_fields(fresh, state_new, state, state_old)
		free(state)
		state = (^State)(fresh)
		state_old, state_new = nil, nil
	}
	state.reloads += 1

	if img_pending != nil {
		rl.UnloadTexture(img_tex)
		img_tex = load_image_texture(img_pending)
		img_pending = nil
	}
}

// Copies each field of the old value into the field with the same name in the new value.
// A new field stays zero, and a removed field is lost.
copy_fields :: proc(dst: rawptr, dst_type: ^runtime.Type_Info, src: rawptr, src_type: ^runtime.Type_Info) {
	dt := runtime.type_info_base(dst_type)
	st := runtime.type_info_base(src_type)
	#partial switch d in dt.variant {
	case runtime.Type_Info_Struct:
		if s, ok := st.variant.(runtime.Type_Info_Struct); ok {
			for i in 0 ..< d.field_count {
				for j in 0 ..< s.field_count {
					if d.names[i] == s.names[j] {
						copy_fields(rawptr(uintptr(dst) + d.offsets[i]), d.types[i], rawptr(uintptr(src) + s.offsets[j]), s.types[j])
					}
				}
			}
			return
		}
	case runtime.Type_Info_Array:
		if s, ok := st.variant.(runtime.Type_Info_Array); ok {
			for i in 0 ..< min(d.count, s.count) {
				copy_fields(rawptr(uintptr(dst) + uintptr(i * d.elem_size)), d.elem, rawptr(uintptr(src) + uintptr(i * s.elem_size)), s.elem)
			}
			return
		}
	}
	if dt.size == st.size {
		mem.copy(dst, src, dt.size)
	}
}

seed_state :: proc(s: ^State) {
	s.bg      = {24, 26, 33, 255}
	s.gravity = 300
	s.speed   = 1
	palette := [?]rl.Color{
		{239, 83, 80, 255}, {66, 165, 245, 255}, {102, 187, 106, 255},
		{255, 202, 40, 255}, {171, 71, 188, 255}, {38, 198, 218, 255},
	}
	for &b, i in s.balls {
		b = {}
		b.radius = 10 + f32((i * 7) % 22)
		b.pos    = {f32(60 + (i * 53) % (WIDTH - 120)), f32(40 + (i * 31) % 200)}
		b.vel    = {f32(80 + (i * 17) % 160) * (i & 1 == 0 ? 1 : -1), 0}
		b.color  = palette[i % len(palette)]
	}
}

// Edit this proc and press F5 (or just save). Try: change a slider range, add a widget,
// change the bounce damping (* 0.86) or the wall logic, or edit the colors in seed_state.
frame :: proc(s: ^State, ctx: ^mu.Context) {
	dt := rl.GetFrameTime()

	when DEMO_6 {
		s.gravity = "fast"
	}

	if !s.paused {
		for &b in s.balls {
			b.vel.y += s.gravity * dt
			when DEMO_4 {
				b.vel.x += wind * dt
			}
			b.pos   += b.vel * dt * s.speed

			if b.pos.x - b.radius < 0      { b.pos.x = b.radius;          b.vel.x = +abs(b.vel.x) }
			if b.pos.x + b.radius > WIDTH  { b.pos.x = WIDTH - b.radius;  b.vel.x = -abs(b.vel.x) }
			if b.pos.y + b.radius > HEIGHT { b.pos.y = HEIGHT - b.radius; b.vel.y = -abs(b.vel.y) * 0.86 }
			if b.pos.y - b.radius < 0      { b.pos.y = b.radius;          b.vel.y = +abs(b.vel.y) }

			when DEMO_1 {
				copy(b.trail[1:], b.trail[:len(b.trail) - 1])
				b.trail[0] = b.pos
			}
		}
	}

	mu.begin(ctx)
	if mu.window(ctx, "Controls", {20, 20, 250, 300}) {
		mu.layout_row(ctx, {-1}, 0)
		mu.label(ctx, "Edit frame(), press F5 or save")

		mu.layout_row(ctx, {70, -1}, 0)
		mu.label(ctx, "Gravity")
		mu.slider(ctx, &s.gravity, 0, 1200)
		mu.label(ctx, "Speed")
		mu.slider(ctx, &s.speed, 0, 3)
		when DEMO_4 {
			mu.label(ctx, "Wind")
			mu.slider(ctx, &wind, -400, 400)
		}

		mu.layout_row(ctx, {-1}, 0)
		mu.checkbox(ctx, "Paused", &s.paused)
		if .SUBMIT in mu.button(ctx, "Reset positions") {
			seed_state(s)
		}

		// It starts at 0 on the patch that adds it, then does not reset on later patches.
		when DEMO_3 {
			@static frames: int
			frames += 1
			mu.label(ctx, fmt.tprintf("frames: %d", frames))
		}
	}
	mu.end(ctx)
}

draw_scene :: proc(s: ^State) {
	rl.ClearBackground(s.bg)

	when DEMO_5 {
		draw_grid()
	}

	for b in s.balls {
		ball_draw(b)
	}

	if img_tex.id != 0 {
		src := rl.Rectangle{0, 0, f32(img_tex.width), f32(img_tex.height)}
		dst := rl.Rectangle{WIDTH - 180, 30, 150, 150}
		rl.DrawTexturePro(img_tex, src, dst, {0, 0}, 0, rl.WHITE)
	}

	if last_error != nil {
		rl.DrawText(last_error, 20, HEIGHT - 60, 20, {239, 83, 80, 255})
	}
	rl.DrawText("edit frame(), press F5 or save to livepatch", 20, HEIGHT - 30, 20, {180, 190, 210, 255})
	rl.DrawText(rl.TextFormat("reloads: %d", i32(s.reloads)), WIDTH - 150, HEIGHT - 30, 20, {180, 190, 210, 255})
}

// draw_scene calls this through the ball_draw pointer.
draw_ball :: proc(b: Ball) {
	when DEMO_1 {
		for p, i in b.trail {
			if i > 0 && p != {} {
				rl.DrawCircleV(p, b.radius * f32(len(b.trail) - i) / f32(len(b.trail)), rl.Fade(b.color, 0.15))
			}
		}
	}
	rl.DrawCircleV(b.pos, b.radius, b.color)
	when DEMO_2 {
		rl.DrawCircleLinesV(b.pos, b.radius + 3, rl.WHITE)
	}
}

when DEMO_5 {
	draw_grid :: proc() {
		for x := i32(0); x < WIDTH; x += 50 {
			rl.DrawLine(x, 0, x, HEIGHT, {255, 255, 255, 20})
		}
		for y := i32(0); y < HEIGHT; y += 50 {
			rl.DrawLine(0, y, WIDTH, y, {255, 255, 255, 20})
		}
	}
}

load_image_texture :: proc(png_bytes: []u8) -> rl.Texture2D {
	img := rl.LoadImageFromMemory(".png", raw_data(png_bytes), i32(len(png_bytes)))
	defer rl.UnloadImage(img)
	return rl.LoadTextureFromImage(img)
}

// A post-patch hook. livepatch finds it by the link section (no registration call) and
// runs it right after each patch is applied, while the other threads are paused. The hook
// runs the new code, so it sees the new image bytes and the new State type.
@(link_section = "lp_post", export)
_on_patched := proc(changed: []lp.Type_Change) {
	// `changed` lists only the types in the type table, and a type is in the table only
	// when the program uses its type info. This line puts State (and Ball) in the table.
	_ = type_info_of(State)

	if h := hash.crc32(image_bytes); h != img_hash {
		img_pending = image_bytes // the patch DLL stays loaded, so the bytes stay valid
		img_hash    = h
	}

	for c in changed {
		if c.name == "State" {
			state_old, state_new = c.old, c.new
		}
	}
}
