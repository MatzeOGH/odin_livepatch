#+build windows
package livepatch

// Imports for the timing report only. @(require) keeps them live when LIVEPATCH is off.
@(require) import "core:fmt"
@(require) import "core:time"

// Public entry point: patch(build_script) rebuilds the program to objects and retargets
// the running procedures with no restart.
//
// LIVEPATCH gates only the body of patch(). Everything else is dropped as dead code when
// LIVEPATCH is off, so patch() can stay in the source permanently at no cost.

// Enable with `-define:LIVEPATCH=true` in the livepatch build script.
LIVEPATCH :: #config(LIVEPATCH, false)

// Print the per-phase timing report to stderr after each patch. Enable with
// `-define:LIVEPATCH_TIMINGS=true`. The timers always run; this gates only the print.
LIVEPATCH_TIMINGS :: #config(LIVEPATCH_TIMINGS, false)

// The result of patch(). A nil union means the patch was applied.
Error :: union {
	Build_Failed,      // the build script failed, or the output directory could not be prepared
	No_Pdb,            // no PDB for the exe -- built without -debug
	No_Objects_Mapped, // the build produced nothing that could be mapped
	Too_Few_Objects,   // one object only -- -use-separate-modules is missing
	Commit_Failed,     // a thread was inside a redirect site; nothing was written
}

Build_Failed      :: struct {exit_code: int, output: string}
No_Pdb            :: struct {}
No_Objects_Mapped :: struct {}
Too_Few_Objects   :: struct {count: int}
Commit_Failed     :: struct {}

when LIVEPATCH {

	// A near-exe block as a half-open address range, for pruning a dirty object's redirects.
	@(private = "file")
	Block_Range :: struct {
		lo, hi: uintptr,
	}

	patch :: proc(build_script: string) -> Error {
		// A PDB is required to resolve exe procedures and globals by link name.
		if !sym_init() {
			return No_Pdb{}
		}

		outdir := build_output_dir() or_return

		t0 := time.tick_now()
		run_build(build_script, outdir) or_return
		d_build := time.tick_since(t0)

		// Objects stay mapped for the life of the process (old generations must stay live).
		t0 = time.tick_now()
		objects, ok := map_all(outdir)
		if !ok || len(objects) == 0 {
			return No_Objects_Mapped{}
		}
		if len(objects) < 2 {
			return Too_Few_Objects{len(objects)}
		}
		d_map := time.tick_since(t0)

		t0 = time.tick_now()
		merged := merge_symbols(objects)
		d_merge := time.tick_since(t0)

		// Bind and relocate every object against the merged table. An object whose
		// relocations do not all resolve is "dirty": it holds a reference the compiler
		// cannot bind, so redirecting a procedure in it would run broken code.
		d_resolve, d_relocate: time.Duration
		dirty := make([dynamic]Block_Range, 0, len(objects), context.temp_allocator)
		for i in 0 ..< len(objects) {
			o := &objects[i]
			t0 = time.tick_now()
			resolved, _ := resolve_symbols(o, &merged)
			d_resolve += time.tick_since(t0)
			t0 = time.tick_now()
			stats := relocate_object(o, resolved)
			d_relocate += time.tick_since(t0)
			if stats.unresolved + stats.unsupported > 0 {
				append(&dirty, Block_Range{uintptr(o.block), uintptr(o.block) + uintptr(o.total)})
			}
		}
		prune_dirty(&merged, dirty[:])

		// Seed each first-seen global / @static from its now-relocated object copy.
		seed_new_globals(&merged)

		// Diff the exe's current type-info array (before commit swaps it) against the new
		// build's relocated array, so the hooks learn which types changed layout.
		t0 = time.tick_now()
		changed: []Type_Change
		if merged.type_table_new != nil {
			changed = diff_types(exe_type_table(), mapped_type_table(merged.type_table_new))
		}
		d_diff := time.tick_since(t0)

		// The halt-world write step. Pre hooks see old code, publication happens, then post
		// hooks see new code. Returns false without writing if a suspended thread is inside
		// a redirect site.
		t0 = time.tick_now()
		if !commit(&merged, find_hooks_in_exe("lp_pre"), find_hooks_in_exe("lp_post"), changed) {
			return Commit_Failed{}
		}
		d_commit := time.tick_since(t0)

		report_timings(objects, &merged, d_build, d_map, d_merge, d_resolve, d_relocate, d_diff, d_commit)
		return nil
	}

	// Prints one line per phase to stderr. Compiles away unless LIVEPATCH_TIMINGS is set.
	@(private = "file")
	report_timings :: proc(objects: []Loaded_Object, merged: ^Merged, d_build, d_map, d_merge, d_resolve, d_relocate, d_diff, d_commit: time.Duration) {
		when LIVEPATCH_TIMINGS {
			total_syms := 0
			for &o in objects {
				total_syms += o.view.n_syms
			}
			ms :: proc(d: time.Duration) -> f64 {
				return time.duration_milliseconds(d)
			}
			fmt.eprintf(
				"[livepatch] objects=%d symbols=%d redirects=%d slots=%d\n" +
				"[livepatch]   build    %8.1f ms  (compile)\n" +
				"[livepatch]   map      %8.1f ms\n" +
				"[livepatch]   merge    %8.1f ms\n" +
				"[livepatch]   resolve  %8.1f ms\n" +
				"[livepatch]   relocate %8.1f ms\n" +
				"[livepatch]   diff     %8.1f ms\n" +
				"[livepatch]   commit   %8.1f ms\n",
				len(objects), total_syms, len(merged.redirects), len(merged.slot_targets),
				ms(d_build), ms(d_map), ms(d_merge), ms(d_resolve), ms(d_relocate), ms(d_diff), ms(d_commit),
			)
		}
	}

	// Drops a redirect whose new body lives in a dirty object. Its exe entry keeps the old
	// body, still reachable through the stable exe address.
	//
	// Slots are left alone: a slot has no old body to fall back to, so dropping its target
	// would leave the stub jumping to null. A dirty object is usually dirty over one
	// sibling, not every slot body, so keeping the slot runs the relocated body (the best
	// available). Only a per-procedure dirty set could prune the offending body alone.
	@(private = "file")
	prune_dirty :: proc(merged: ^Merged, dirty: []Block_Range) {
		if len(dirty) == 0 {
			return
		}

		kept_redirects := make([dynamic]Redirect, 0, len(merged.redirects), context.temp_allocator)
		for r in merged.redirects {
			if !addr_in_ranges(uintptr(r.body), dirty) {
				append(&kept_redirects, r)
			}
		}
		merged.redirects = kept_redirects
	}

	@(private = "file")
	addr_in_ranges :: proc(a: uintptr, ranges: []Block_Range) -> bool {
		for r in ranges {
			if a >= r.lo && a < r.hi {
				return true
			}
		}
		return false
	}

} else {

	// LIVEPATCH off: patch() is a no-op.
	patch :: proc(build_script: string) -> Error {
		return nil
	}

}
