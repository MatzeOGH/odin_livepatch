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
		pending := prepare(build_script) or_return
		return apply(&pending)
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
		build_time, bind_time, link_time, diff_time: time.Duration,
	}

	prepare :: proc(build_script: string) -> (pending: Pending, err: Error) {
		context.allocator = runtime.heap_allocator()
		init() or_return

		output_dir := build_output_dir() or_return

		phase_start := time.tick_now()
		build_start := time.now()
		run_build(build_script, output_dir) or_return
		pending.build_time = time.tick_since(phase_start)

		phase_start = time.tick_now()
		read_ok: bool
		pending.objects, read_ok = read_all(output_dir, build_start)
		if !read_ok || len(pending.objects) == 0 {
			return pending, No_Objects_Mapped{}
		}
		if len(pending.objects) < 2 {
			return pending, Too_Few_Objects{len(pending.objects)}
		}

		pending.merged = merge_symbols(pending.objects)
		resolve_externals(pending.objects, &pending.merged) or_return
		for &object in pending.objects {
			out, failed := retarget_object_references(&object, &pending.merged)
			if failed != "" {
				return pending, Unresolved_Symbol{error_text(failed), error_text(object.path)}
			}
			if os.write_entire_file(object.path, out) != nil {
				return pending, No_Objects_Mapped{}
			}
		}
		pending.bind_time = time.tick_since(phase_start)

		prepare_redirects(&pending.merged) or_return

		phase_start = time.tick_now()
		pending.module = link_and_load(output_dir, pending.objects, &pending.merged) or_return
		pending.link_time = time.tick_since(phase_start)

		for &redirect in pending.merged.redirects {
			redirect.body = rawptr(pending.module.symbols[canonical_data_name(redirect.name)] or_else 0)
			if redirect.body == nil {
				return pending, Unresolved_Symbol{error_text(redirect.name), error_text("patch DLL map")}
			}
		}
		for &slot_target in pending.merged.slot_targets {
			slot_target.body = rawptr(pending.module.symbols[canonical_data_name(slot_target.name)] or_else 0)
			if slot_target.body == nil {
				return pending, Unresolved_Symbol{error_text(slot_target.name), error_text("patch DLL map")}
			}
		}
		if pending.merged.has_type_table {
			pending.merged.type_table_new = rawptr(pending.module.symbols["runtime::type_table"] or_else 0)
		}

		// Before commit swaps runtime.type_table
		phase_start = time.tick_now()
		if pending.merged.type_table_new != nil {
			pending.changed = diff_types(runtime.type_table, (^[]^runtime.Type_Info)(pending.merged.type_table_new)^)
		}
		pending.diff_time = time.tick_since(phase_start)
		return pending, nil
	}

	apply :: proc(pending: ^Pending) -> Error {
		context.allocator = runtime.heap_allocator()
		phase_start := time.tick_now()
		if !commit(&pending.merged, find_hooks_in_exe("lp_pre"), find_hooks_in_exe("lp_post"), pending.changed) {
			return Commit_Failed{}
		}
		commit_time := time.tick_since(phase_start)

		for name in pending.merged.new_globals {
			key := canonical_data_name(name)
			if addr, found := pending.module.symbols[key]; found {
				global_register(key, rawptr(addr))
			}
		}

		report_timings(pending, commit_time)
		show_toast(pending.build_time + pending.bind_time + pending.link_time + pending.diff_time + commit_time)
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
		exe_path, path_err := os.get_executable_path(context.allocator)
		if path_err != nil {
			return No_Map{}
		}
		exe_file, _ = os.read_entire_file_from_path(exe_path, context.allocator)
		load_exe_symbols(exe_path)
		if len(exe_map) == 0 {
			return No_Map{}
		}
		mirror_init()
		return make_exe_writable()
	}

	report_timings :: proc(pending: ^Pending, commit_time: time.Duration) {
		when LIVEPATCH_TIMINGS {
			total_symbols := 0
			for &object in pending.objects {
				total_symbols += object_symbol_count(&object)
			}
			ms :: proc(duration: time.Duration) -> f64 {
				return time.duration_milliseconds(duration)
			}
			fmt.eprintf(
				"[livepatch] objects=%d symbols=%d redirects=%d slots=%d\n" +
				"[livepatch]   build    %.1f ms  (compile)\n" +
				"[livepatch]   bind     %.1f ms\n" +
				"[livepatch]   link     %.1f ms  (link + load)\n" +
				"[livepatch]   diff     %.1f ms\n" +
				"[livepatch]   commit   %.1f ms\n",
				len(pending.objects), total_symbols, len(pending.merged.redirects), len(pending.merged.slot_targets),
				ms(pending.build_time), ms(pending.bind_time), ms(pending.link_time), ms(pending.diff_time), ms(commit_time),
			)
			if unpaused := unpaused_threads(); unpaused > 0 {
				fmt.eprintf("[livepatch]   %d thread(s) kept running: they block LIVEPATCH_SIGNAL\n", unpaused)
			}
		}
	}

}
