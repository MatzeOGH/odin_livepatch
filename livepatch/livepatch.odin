#+build windows amd64, linux amd64
package livepatch

@(require) import "core:fmt"
@(require) import "core:mem/virtual"
@(require) import "core:os"
@(require) import "core:strings"
@(require) import "core:sync"
@(require) import "core:thread"
@(require) import "core:time"
@(require) import "base:runtime"

// Prints the time of each phase to stderr after each patch
LIVEPATCH_TIMINGS :: #config(LIVEPATCH_TIMINGS, false)

// Shows a toast after each patch.
LIVEPATCH_TOAST :: #config(LIVEPATCH_TOAST, false)

// The object directory, in the exe directory. The watcher ignores it.
PATCH_OUTPUT_DIRNAME :: "livepatch"


when LIVEPATCH {

	// Rebuilds and applies a patch. Blocking!
	patch :: proc(build_script: string) -> Error {
		if job.thread != nil {
			return Patch_In_Progress{}
		}
		arena: virtual.Arena
		if virtual.arena_init_growing(&arena) != nil {
			return Build_Failed{kind = .Out_Of_Memory}
		}
		defer virtual.arena_destroy(&arena)
		context.temp_allocator = virtual.arena_allocator(&arena)
		p := prepare(build_script) or_return
		return apply(&p)
	}

	// Builds a patch on a worker thread
	patch_start :: proc(build_script: string) -> Error {
		if job.thread != nil {
			return Patch_In_Progress{}
		}
		if virtual.arena_init_growing(&job.arena) != nil {
			return Build_Failed{kind = .Out_Of_Memory}
		}
		job.script = strings.clone(build_script)
		job.done = false
		job.thread = thread.create_and_start(worker)
		return nil
	}

	patch_poll :: proc() -> (finished: bool, err: Error) {
		if job.thread == nil || !sync.atomic_load_explicit(&job.done, .Acquire) {
			return
		}
		thread.destroy(job.thread) // the worker has returned, so this does not wait
		job.thread = nil
		delete(job.script)
		defer virtual.arena_destroy(&job.arena)
		if job.err != nil {
			return true, job.err
		}
		return true, apply(&job.pending)
	}

	job: struct {
		thread:  ^thread.Thread,
		arena:   virtual.Arena, // the worker's temp allocations, kept until the apply
		script:  string,
		pending: Pending,
		err:     Error,
		done:    bool, // pending and err are complete
	}

	worker :: proc() {
		context.temp_allocator = virtual.arena_allocator(&job.arena)
		job.pending, job.err = prepare(job.script)
		sync.atomic_store_explicit(&job.done, true, .Release)
	}

	Pending :: struct {
		objects: []Loaded_Object,
		merged:  Merged,
		module:  Patch_Module,
		changed: []Type_Change,
		d_build, d_bind, d_link, d_diff: time.Duration,
	}

	prepare :: proc(build_script: string) -> (p: Pending, err: Error) {
		context.allocator = runtime.heap_allocator()
		init() or_return

		outdir := build_output_dir() or_return

		t0 := time.tick_now()
		build_start := time.now()
		run_build(build_script, outdir) or_return
		p.d_build = time.tick_since(t0)

		t0 = time.tick_now()
		ok: bool
		p.objects, ok = read_all(outdir, build_start)
		if !ok || len(p.objects) == 0 {
			return p, No_Objects_Mapped{}
		}
		if len(p.objects) < 2 {
			return p, Too_Few_Objects{len(p.objects)}
		}

		p.merged = merge_symbols(p.objects)
		resolve_externals(p.objects, &p.merged) or_return
		for &o in p.objects {
			out, failed := rewrite_object(&o, &p.merged)
			if failed != "" {
				return p, Unresolved_Symbol{error_text(failed), error_text(o.path)}
			}
			if os.write_entire_file(o.path, out) != nil {
				return p, No_Objects_Mapped{}
			}
		}
		p.d_bind = time.tick_since(t0)

		prepare_redirects(&p.merged) or_return

		t0 = time.tick_now()
		p.module = link_and_load(outdir, p.objects, &p.merged) or_return
		p.d_link = time.tick_since(t0)

		for &r in p.merged.redirects {
			r.body = rawptr(p.module.symbols[canonical_data_name(r.name)] or_else 0)
			if r.body == nil {
				return p, Unresolved_Symbol{error_text(r.name), error_text("patch DLL map")}
			}
		}
		for &s in p.merged.slot_targets {
			s.body = rawptr(p.module.symbols[canonical_data_name(s.name)] or_else 0)
			if s.body == nil {
				return p, Unresolved_Symbol{error_text(s.name), error_text("patch DLL map")}
			}
		}
		if p.merged.has_type_table {
			p.merged.type_table_new = rawptr(p.module.symbols["runtime::type_table"] or_else 0)
		}

		// Before commit swaps runtime.type_table
		t0 = time.tick_now()
		if p.merged.type_table_new != nil {
			p.changed = diff_types(runtime.type_table, (^[]^runtime.Type_Info)(p.merged.type_table_new)^)
		}
		p.d_diff = time.tick_since(t0)
		return p, nil
	}

	apply :: proc(p: ^Pending) -> Error {
		context.allocator = runtime.heap_allocator()
		t0 := time.tick_now()
		if !commit(&p.merged, find_hooks_in_exe("lp_pre"), find_hooks_in_exe("lp_post"), p.changed) {
			return Commit_Failed{}
		}
		d_commit := time.tick_since(t0)

		for name in p.merged.new_globals {
			key := canonical_data_name(name)
			if addr, found := p.module.symbols[key]; found {
				global_register(key, rawptr(addr))
			}
		}

		report_timings(p, d_commit)
		show_toast(p.d_build + p.d_bind + p.d_link + p.d_diff + d_commit)
		return nil
	}

	initialized: bool
	init_error:  Error

	// Makes the exe code and the type_table header writable
	init :: proc() -> Error {
		if !initialized {
			initialized = true
			init_error = init_once()
		}
		return init_error
	}

	init_once :: proc() -> Error {
		exe, err := os.get_executable_path(context.allocator)
		if err != nil {
			return No_Map{}
		}
		load_exe_symbols(exe)
		if len(exe_map) == 0 {
			return No_Map{}
		}
		exe_file, _ = os.read_entire_file_from_path(exe, context.allocator)
		mirror_init()
		return make_exe_writable()
	}

	report_timings :: proc(p: ^Pending, d_commit: time.Duration) {
		when LIVEPATCH_TIMINGS {
			total_syms := 0
			for &o in p.objects {
				total_syms += object_symbol_count(&o)
			}
			ms :: proc(d: time.Duration) -> f64 {
				return time.duration_milliseconds(d)
			}
			fmt.eprintf(
				"[livepatch] objects=%d symbols=%d redirects=%d slots=%d\n" +
				"[livepatch]   build    %.1f ms  (compile)\n" +
				"[livepatch]   bind     %.1f ms\n" +
				"[livepatch]   link     %.1f ms  (link + load)\n" +
				"[livepatch]   diff     %.1f ms\n" +
				"[livepatch]   commit   %.1f ms\n",
				len(p.objects), total_syms, len(p.merged.redirects), len(p.merged.slot_targets),
				ms(p.d_build), ms(p.d_bind), ms(p.d_link), ms(p.d_diff), ms(d_commit),
			)
		}
	}

}
