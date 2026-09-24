package livepatch

// The API when livepatching is off: LIVEPATCH is false, or the target is not Windows x64.
when !(LIVEPATCH && ODIN_OS == .Windows && ODIN_ARCH == .amd64) {

	Watcher :: struct {}

	patch       :: proc(build_script: string) -> Error { return nil }
	patch_start :: proc(build_script: string) -> Error { return nil }
	patch_poll  :: proc() -> (finished: bool, err: Error) { return }

	watch_start :: proc(source_root: string) -> (watcher: Watcher, err: Watch_Error) { return {}, nil }
	watch_poll  :: proc(watcher: ^Watcher, debounce := WATCH_DEBOUNCE) -> (changed: bool, err: Watch_Error) { return false, nil }
	watch_stop  :: proc(watcher: ^Watcher) {}

}
