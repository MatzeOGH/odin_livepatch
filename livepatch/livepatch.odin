#+build windows
package livepatch

@(require) import "core:fmt"
@(require) import "core:path/filepath"
@(require) import "core:strings"
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
	No_Objects_Mapped, // an object could not be read or mapped near the exe
	Too_Few_Objects,   // one object only -- -use-separate-modules is missing
	Unresolved_Symbol, // new code references something that cannot be bound
	Commit_Failed,     // no safe moment to write; nothing was written
}

Build_Failed      :: struct {exit_code: int, output: string}
No_Pdb            :: struct {}
No_Objects_Mapped :: struct {}
Too_Few_Objects   :: struct {count: int}
Unresolved_Symbol :: struct {name: string, object: string}
Commit_Failed     :: struct {}

when LIVEPATCH {

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

		d_resolve, d_relocate: time.Duration
		failed: Unresolved_Symbol
		for i in 0 ..< len(objects) {
			o := &objects[i]
			t0 = time.tick_now()
			resolved, _ := resolve_symbols(o, &merged)
			d_resolve += time.tick_since(t0)
			t0 = time.tick_now()
			stats := relocate_object(o, resolved)
			d_relocate += time.tick_since(t0)
			if failed.name == "" && stats.first_failed != "" {
				failed = {strings.clone(stats.first_failed), strings.clone(filepath.base(o.path))}
			}
		}
		if failed.name != "" {
			global_forget(&merged)
			return failed
		}

		// No live code reaches a new store yet.
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
			global_forget(&merged)
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

} else {

	// LIVEPATCH off: patch() is a no-op.
	patch :: proc(build_script: string) -> Error {
		return nil
	}

}
