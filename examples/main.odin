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
// Build the host with build_livepatch.bat, then run demo.exe. See README.md.

import lp "../livepatch"

import "core:fmt"
import "core:os"
import "core:path/filepath"
import mu "vendor:microui"
import rl "vendor:raylib"

WIDTH   :: 900
HEIGHT  :: 600
N_BALLS :: 24

Ball :: struct {
	pos, vel: rl.Vector2,
	radius:   f32,
	color:    rl.Color,
}

// The whole app state. It hangs off a package global (`state`), so its bytes survive
// a patch. Add a field here, patch, and the new field is zero and kept from then on.
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
// corner swaps. The bytes come through a proc, not a global: #load embeds them at build
// time, and a patch redirects this proc to the new bytes. A #load global would not swap,
// because livepatch preserves globals
image_bytes :: proc() -> []u8 { return #load("image_v1.png") }
img_tex: rl.Texture2D
img_src: rawptr

main :: proc() {
	rl.InitWindow(WIDTH, HEIGHT, "Odin livepatch demo -- edit frame(), press F5 or save")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	mu.init(&ctx)
	ctx.text_width  = mu.default_atlas_text_width
	ctx.text_height = mu.default_atlas_text_height

	atlas := atlas_texture()
	defer rl.UnloadTexture(atlas)

	img_tex = load_image_texture(image_bytes())
	img_src = raw_data(image_bytes())
	defer rl.UnloadTexture(img_tex)

	state = new(State)
	seed_state(state)

	// Watch this program's own source directory for saved .odin files. watch_poll only
	// reports a settled change, and the patch runs here in the main loop, not on a
	// background thread. A relative root is resolved against the exe.
	watcher, werr := lp.watch_start(filepath.dir(os.args[0]))
	if werr != nil {
		fmt.eprintln("watch:", werr)
	}
	defer lp.watch_stop(&watcher)

	for !rl.WindowShouldClose() {
		do_patch := rl.IsKeyPressed(.F5)
		if changed, poll_err := lp.watch_poll(&watcher); poll_err != nil {
			fmt.eprintln("watch:", poll_err)
		} else if changed {
			do_patch = true
		}

		// patch() blocks while it rebuilds and applies the patch (a second or two), so
		// the window freezes until it returns. The demo is single-threaded, so no worker
		// holds a lock a hook needs. On a build error the old code keeps running.
		if do_patch {
			if err := lp.patch("build_livepatch.bat"); err != nil {
				fmt.eprintln("livepatch:", err)
			}
		}

		// If a patch redirected image_bytes() to new bytes, free the old texture and
		// rebuild from the new ones.
		if bytes := image_bytes(); raw_data(bytes) != img_src {
			rl.UnloadTexture(img_tex)
			img_tex = load_image_texture(bytes)
			img_src = raw_data(bytes)
		}

		mu_handle_input(&ctx)
		frame(state, &ctx)

		rl.BeginDrawing()
		rl.ClearBackground(state.bg)
		draw_scene(state)
		mu_render(&ctx, atlas)
		rl.EndDrawing()
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

	if !s.paused {
		for &b in s.balls {
			b.vel.y += s.gravity * dt
			b.pos   += b.vel * dt * s.speed

			if b.pos.x - b.radius < 0      { b.pos.x = b.radius;          b.vel.x = +abs(b.vel.x) }
			if b.pos.x + b.radius > WIDTH  { b.pos.x = WIDTH - b.radius;  b.vel.x = -abs(b.vel.x) }
			if b.pos.y + b.radius > HEIGHT { b.pos.y = HEIGHT - b.radius; b.vel.y = -abs(b.vel.y) * 0.86 }
			if b.pos.y - b.radius < 0      { b.pos.y = b.radius;          b.vel.y = +abs(b.vel.y) }
		}
	}

	mu.begin(ctx)
	if mu.window(ctx, "Controls", {20, 20, 250, 240}) {
		mu.layout_row(ctx, {-1}, 0)
		mu.label(ctx, "Edit frame(), press F5 or save")

		mu.layout_row(ctx, {70, -1}, 0)
		mu.label(ctx, "Gravity")
		mu.slider(ctx, &s.gravity, 0, 1200)
		mu.label(ctx, "Speed")
		mu.slider(ctx, &s.speed, 0, 3)

		mu.layout_row(ctx, {-1}, 0)
		mu.checkbox(ctx, "Paused", &s.paused)
		if .SUBMIT in mu.button(ctx, "Reset positions") {
			seed_state(s)
		}
	}
	mu.end(ctx)
}

draw_scene :: proc(s: ^State) {
	for b in s.balls {
		rl.DrawCircleV(b.pos, b.radius, b.color)
	}

	if img_tex.id != 0 {
		src := rl.Rectangle{0, 0, f32(img_tex.width), f32(img_tex.height)}
		dst := rl.Rectangle{WIDTH - 180, 30, 150, 150}
		rl.DrawTexturePro(img_tex, src, dst, {0, 0}, 0, rl.WHITE)
	}

	rl.DrawText("edit frame(), press F5 or save to livepatch", 20, HEIGHT - 30, 20, {180, 190, 210, 255})
	rl.DrawText(rl.TextFormat("reloads: %d", i32(s.reloads)), WIDTH - 150, HEIGHT - 30, 20, {180, 190, 210, 255})
}

load_image_texture :: proc(png_bytes: []u8) -> rl.Texture2D {
	img := rl.LoadImageFromMemory(".png", raw_data(png_bytes), i32(len(png_bytes)))
	defer rl.UnloadImage(img)
	return rl.LoadTextureFromImage(img)
}

// A post-patch hook. livepatch finds it by the link section (no registration call) and
// runs it right after each patch is applied, while other threads are paused
@(link_section = "lp_post", export)
_on_patched := proc(changed: []lp.Type_Change) {
	state.reloads += 1
}
