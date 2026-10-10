package livepatch

when !(LIVEPATCH && SUPPORTED_TARGET) {

	Watcher :: struct {}

	patch       :: proc(build_script: string) -> Error { return nil }
	patch_start :: proc(build_script: string) -> Error { return nil }
	patch_poll  :: proc() -> (finished: bool, err: Error) { return }

	watch_start :: proc(source_root: string, extensions: []string = nil) -> (watcher: Watcher, err: Watch_Error) { return {}, nil }
	watch_poll  :: proc(watcher: ^Watcher, debounce := WATCH_DEBOUNCE) -> (changed: bool, err: Watch_Error) { return false, nil }
	watch_stop  :: proc(watcher: ^Watcher) {}

} else when ODIN_OS == .Darwin {

	// ponytail: no source watcher on macOS yet. Port watch_darwin.odin (kqueue) from the PoC when it is needed.
	Watcher :: struct {}

	watch_start :: proc(source_root: string, extensions: []string = nil) -> (watcher: Watcher, err: Watch_Error) { return {}, nil }
	watch_poll  :: proc(watcher: ^Watcher, debounce := WATCH_DEBOUNCE) -> (changed: bool, err: Watch_Error) { return false, nil }
	watch_stop  :: proc(watcher: ^Watcher) {}

}
