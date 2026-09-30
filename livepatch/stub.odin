package livepatch

when !(LIVEPATCH && SUPPORTED_TARGET) {

	Watcher :: struct {}

	patch       :: proc(build_script: string) -> Error { return nil }
	patch_start :: proc(build_script: string) -> Error { return nil }
	patch_poll  :: proc() -> (finished: bool, err: Error) { return }

	watch_start :: proc(source_root: string) -> (watcher: Watcher, err: Watch_Error) { return {}, nil }
	watch_poll  :: proc(watcher: ^Watcher, debounce := WATCH_DEBOUNCE) -> (changed: bool, err: Watch_Error) { return false, nil }
	watch_stop  :: proc(watcher: ^Watcher) {}

}
