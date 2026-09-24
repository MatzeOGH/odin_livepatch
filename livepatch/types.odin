package livepatch

import "base:runtime"
import "core:os"
import "core:strings"
import "core:time"

// Must be true to enable livepatching
LIVEPATCH :: #config(LIVEPATCH, false)

Error :: union {
	Build_Failed,
	No_Map,                 // the exe was linked without /MAP
	No_Objects_Mapped,      // an object could not be read or rewritten
	Too_Few_Objects,        // -use-separate-modules is missing
	Unresolved_Symbol,
	Load_Failed,            // the patch DLL could not be linked or loaded
	Breakpoint_In_Redirect,
	Commit_Failed,          // no safe moment to write, or the exe code is not writable. Nothing was written.
	Patch_In_Progress,      // patch_poll has not finished the patch from patch_start
}

// Copies s to the heap, so error_delete can free it.
error_text :: proc(s: string) -> string {
	return strings.clone(s, runtime.heap_allocator())
}

// Frees the strings of an Error. It is safe to call on any Error, and on nil.
error_delete :: proc(err: Error) {
	h := runtime.heap_allocator()
	#partial switch e in err {
	case Build_Failed:           delete(e.output, h)
	case Load_Failed:            delete(e.output, h)
	case Unresolved_Symbol:      delete(e.name, h); delete(e.object, h)
	case Breakpoint_In_Redirect: delete(e.procedures, h)
	}
}

Build_Failed :: struct {
	kind:      Build_Error_Kind,
	exit_code: int,      // .Script_Failed
	os_error:  os.Error, // .Cannot_Create_Dir, .Cannot_Run_Script
	output:    string,   // .Script_Failed: the build output
}
Build_Error_Kind :: enum {
	Exe_Path_Unknown,
	Out_Of_Memory,
	Cannot_Create_Dir,
	Cannot_Run_Script,
	Script_Failed,
}

No_Map            :: struct {}
No_Objects_Mapped :: struct {}
Too_Few_Objects   :: struct {count: int}
Unresolved_Symbol :: struct {name: string, object: string}

Load_Failed :: struct {
	kind:     Load_Error_Kind,
	os_error: os.Error, // .Cannot_Write_File, .Cannot_Run_Linker, .Load_Library_Failed
	output:   string,   // .Link_Failed: the linker output
}
Load_Error_Kind :: enum {
	Exe_Path_Unknown,
	Cannot_Write_File,
	No_Near_Memory,       // no free address range near the exe for the DLL
	No_Stub_Memory,       // no free address range near the exe for the redirect stubs
	Cannot_Run_Linker,
	Link_Failed,
	Load_Library_Failed,
	Wrong_Load_Base,      // the DLL did not load at the address it was linked for
}

Breakpoint_In_Redirect :: struct {procedures: string}
Commit_Failed     :: struct {}
Patch_In_Progress :: struct {}

// A type whose layout changed in this patch. A post hook reads old-layout instances through
// `old` and writes new-layout instances through `new`.
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

Watch_Start_Failed :: struct {kind: Watch_Error_Kind, os_error: os.Error}
Watch_Failed       :: struct {kind: Watch_Error_Kind, os_error: os.Error}
Watch_Error_Kind :: enum {
	Empty_Path,
	Exe_Path_Unknown,
	Out_Of_Memory,
	Cannot_Open_Dir,
	Cannot_Create_Event,
	Cannot_Read_Changes,
	Cannot_Poll,
}

WATCH_DEBOUNCE :: 150 * time.Millisecond
