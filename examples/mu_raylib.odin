package livepatch_demo

// microui <-> raylib backend. Boring glue: build the font/icon atlas as a texture,
// feed raylib input into microui, and draw microui's command list with raylib.
// You rarely edit this file — the demo you edit lives in main.odin's `frame`.

import mu "vendor:microui"
import rl "vendor:raylib"

// Build a raylib texture from microui's built-in 128x128 alpha atlas (font + icons).
// Expand the single alpha byte to white RGBA so it tints cleanly.
atlas_texture :: proc() -> rl.Texture2D {
	W :: mu.DEFAULT_ATLAS_WIDTH
	H :: mu.DEFAULT_ATLAS_HEIGHT
	pixels: [W * H][4]u8
	for a, i in mu.default_atlas_alpha {
		pixels[i] = {255, 255, 255, a}
	}
	img := rl.Image {
		data    = &pixels[0],
		width   = W,
		height  = H,
		mipmaps = 1,
		format  = .UNCOMPRESSED_R8G8B8A8,
	}
	return rl.LoadTextureFromImage(img) // copies to VRAM; `pixels` can go out of scope after
}

// Map this frame's raylib input into microui. Call once per frame before `frame`.
mu_handle_input :: proc(ctx: ^mu.Context) {
	m := rl.GetMousePosition()
	mx, my := i32(m.x), i32(m.y)
	mu.input_mouse_move(ctx, mx, my)
	mu.input_scroll(ctx, 0, i32(rl.GetMouseWheelMove() * -30))

	if rl.IsMouseButtonPressed(.LEFT)   { mu.input_mouse_down(ctx, mx, my, .LEFT) }
	if rl.IsMouseButtonReleased(.LEFT)  { mu.input_mouse_up(ctx, mx, my, .LEFT) }
	if rl.IsMouseButtonPressed(.RIGHT)  { mu.input_mouse_down(ctx, mx, my, .RIGHT) }
	if rl.IsMouseButtonReleased(.RIGHT) { mu.input_mouse_up(ctx, mx, my, .RIGHT) }

	for {
		ch := rl.GetCharPressed()
		if ch == 0 { break }
		bytes, n := utf8_encode(ch)
		mu.input_text(ctx, string(bytes[:n]))
	}
	if rl.IsKeyPressed(.BACKSPACE) { mu.input_key_down(ctx, .BACKSPACE) }
	if rl.IsKeyPressed(.ENTER)     { mu.input_key_down(ctx, .RETURN) }
}

// Draw microui's command list. Call inside BeginDrawing/EndDrawing, after `frame`.
mu_render :: proc(ctx: ^mu.Context, atlas: rl.Texture2D) {
	cmd: ^mu.Command
	for variant in mu.next_command_iterator(ctx, &cmd) {
		switch c in variant {
		case ^mu.Command_Rect:
			rl.DrawRectangleRec(to_rect(c.rect), to_color(c.color))
		case ^mu.Command_Text:
			pos := c.pos
			for ch in c.str {
				r := min(int(ch), 127)
				src := mu.default_atlas[mu.DEFAULT_ATLAS_FONT + r]
				rl.DrawTextureRec(atlas, to_rect(src), {f32(pos.x), f32(pos.y)}, to_color(c.color))
				pos.x += src.w
			}
		case ^mu.Command_Icon:
			src := mu.default_atlas[c.id]
			x := c.rect.x + (c.rect.w - src.w) / 2
			y := c.rect.y + (c.rect.h - src.h) / 2
			rl.DrawTextureRec(atlas, to_rect(src), {f32(x), f32(y)}, to_color(c.color))
		case ^mu.Command_Clip:
			rl.BeginScissorMode(c.rect.x, c.rect.y, c.rect.w, c.rect.h)
		case ^mu.Command_Jump:
			// handled inside next_command_iterator
		}
	}
	rl.EndScissorMode()
}

@(private="file")
to_rect :: proc(r: mu.Rect) -> rl.Rectangle {
	return {f32(r.x), f32(r.y), f32(r.w), f32(r.h)}
}
@(private="file")
to_color :: proc(c: mu.Color) -> rl.Color {
	return {c.r, c.g, c.b, c.a}
}

// Minimal UTF-8 encoder for GetCharPressed runes (avoids pulling in unicode/utf8 just for this).
@(private="file")
utf8_encode :: proc(r: rune) -> (buf: [4]u8, n: int) {
	c := u32(r)
	switch {
	case c < 0x80:
		buf[0] = u8(c); n = 1
	case c < 0x800:
		buf[0] = 0xC0 | u8(c >> 6);   buf[1] = 0x80 | u8(c & 0x3F); n = 2
	case c < 0x10000:
		buf[0] = 0xE0 | u8(c >> 12);  buf[1] = 0x80 | u8((c >> 6) & 0x3F); buf[2] = 0x80 | u8(c & 0x3F); n = 3
	case:
		buf[0] = 0xF0 | u8(c >> 18);  buf[1] = 0x80 | u8((c >> 12) & 0x3F); buf[2] = 0x80 | u8((c >> 6) & 0x3F); buf[3] = 0x80 | u8(c & 0x3F); n = 4
	}
	return
}
