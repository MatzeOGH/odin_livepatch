#+build !windows
package livepatch

// Non-Windows stub. livepatch works on Windows/x64 only, but its public API is declared on
// every target so an application can call patch() and the watcher unconditionally, with no
// build tags of its own. On other targets these do nothing, so a normal cross-platform
// build is never broken. The Windows implementation lives in the #+build windows files.

import "base:runtime"
import "core:time"

Error :: union {
	Build_Failed,
	No_Pdb,
	No_Objects_Mapped,
	Too_Few_Objects,
	Commit_Failed,
}

Build_Failed      :: struct {exit_code: int, output: string}
No_Pdb            :: struct {}
No_Objects_Mapped :: struct {}
Too_Few_Objects   :: struct {count: int}
Commit_Failed     :: struct {}

Type_Change :: struct {
	name: string,
	old:  ^runtime.Type_Info,
	new:  ^runtime.Type_Info,
}

Patch_Hook :: proc(changed: []Type_Change)

Watch_Error :: union {
	Watch_Start_Failed,
	Watch_Failed,
}

Watch_Start_Failed :: struct {output: string}
Watch_Failed       :: struct {output: string}

Watcher :: struct {}

WATCH_DEBOUNCE :: 150 * time.Millisecond

patch :: proc(build_script: string) -> Error { return nil }

watch_start :: proc(source_root: string) -> (watcher: Watcher, err: Watch_Error) { return {}, nil }
watch_poll  :: proc(watcher: ^Watcher, debounce := WATCH_DEBOUNCE) -> (changed: bool, err: Watch_Error) { return false, nil }
watch_stop  :: proc(watcher: ^Watcher) {}
