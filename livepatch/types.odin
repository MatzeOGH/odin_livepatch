package livepatch

import "base:runtime"
import "core:strings"
import "core:time"

// Must be true to enable livepatching
LIVEPATCH :: #config(LIVEPATCH, false)

// The targets that livepatch patches. On any other, the API is a no-op stub.
SUPPORTED_TARGET :: (ODIN_OS == .Windows || ODIN_OS == .Linux) && ODIN_ARCH == .amd64

// The sections of the migration hooks, for `@(link_section=...)`
HOOK_PRE_SECTION  :: "__DATA,lp_pre" when ODIN_OS == .Darwin else "lp_pre"
HOOK_POST_SECTION :: "__DATA,lp_post" when ODIN_OS == .Darwin else "lp_post"

Error :: union {
	Build_Failed,
	No_Map,                 // the exe was linked without /MAP
	No_Objects_Mapped,      // an object could not be read or rewritten
	Unresolved_Symbol,
	Global_Needs_Init,      // a global that the patch adds gets its value from code at startup
	Global_Grew,            // a global stored by value is larger in the patch than its storage (Linux)
	Load_Failed,            // the patch DLL could not be linked or loaded
	Breakpoint_In_Redirect,
	Commit_Failed,          // no safe moment to write, or the exe code is not writable. Nothing was written.
	Patch_In_Progress,      // patch_poll has not finished the patch from patch_start
}

// Copies text to the heap, so error_delete can free it.
error_text :: proc(text: string) -> string {
	return strings.clone(text, runtime.heap_allocator())
}

// Frees the strings of an Error. It is safe to call on any Error, and on nil.
error_delete :: proc(err: Error) {
	heap := runtime.heap_allocator()
	#partial switch variant in err {
	case Build_Failed:           delete(variant.output, heap)
	case Load_Failed:            delete(variant.output, heap)
	case Unresolved_Symbol:      delete(variant.name, heap); delete(variant.object, heap)
	case Global_Needs_Init:      delete(variant.name, heap)
	case Global_Grew:            delete(variant.name, heap)
	case Breakpoint_In_Redirect: delete(variant.procedures, heap)
	}
}

Build_Failed :: struct {
	kind:      Build_Error_Kind,
	exit_code: int,      // .Script_Failed
	os_error:  Os_Error, // .Cannot_Create_Dir, .Cannot_Run_Script
	output:    string,   // .Script_Failed: the build output
}
Build_Error_Kind :: enum {
	Exe_Path_Unknown,
	Out_Of_Memory,
	Cannot_Create_Dir,
	Cannot_Run_Script,
	Script_Failed,
	No_Separate_Modules, // the build made one object: the script must use -use-separate-modules
}

No_Map            :: struct {}
No_Objects_Mapped :: struct {}
Unresolved_Symbol :: struct {name: string, object: string}
Global_Needs_Init :: struct {name: string}
Global_Grew       :: struct {name: string, old_size, new_size: int}

Load_Failed :: struct {
	kind:     Load_Error_Kind,
	os_error: Os_Error, // .Cannot_Write_File, .Cannot_Run_Linker, .Load_Library_Failed, and why the memory was refused for .No_Near_Memory, .No_Stub_Memory
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
Commit_Failed     :: struct {
	os_error: Os_Error, // set when the exe code could not be made writable
}
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

Watch_Start_Failed :: struct {kind: Watch_Error_Kind, os_error: Os_Error}
Watch_Failed       :: struct {kind: Watch_Error_Kind, os_error: Os_Error}
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
