#+build windows
package livepatch

// Exe symbol lookup through the running process's own PDB, via DbgHelp.
//
// The hot cost is a SymFromNameW miss: it scans the whole PDB before it fails, and a large
// program asks for thousands of names that never resolve. So exe_symbol resolves in three
// tiers, cheapest first:
//
//   1. exe_index one SymEnumSymbolsW pass, name -> {addr, size}. Carries every function
//      (the redirect targets) as an O(1) hit, and is where most lookups land.
//   2. names that can never be a resolvable exe symbol: a miss with no scan (see
//      worth_symfromname).
//   3. SymFromNameW, only for what is left: a qualified Odin name absent from the index.
//      Enumeration omits a qualified *global* link name, so this is what still finds the
//      globals and preserves their state across a patch.

import "base:runtime"
import "core:strings"
import win "core:sys/windows"

// SymFromNameW / SymEnumSymbolsW are not in core:sys/windows
foreign import dbghelp "system:dbghelp.lib"

Sym_Enum_Callback :: #type proc "system" (sym: ^win.SYMBOL_INFOW, size: win.ULONG, ctx: rawptr) -> win.BOOL

@(default_calling_convention = "system")
foreign dbghelp {
	SymFromNameW :: proc(hProcess: win.HANDLE, Name: win.wstring, Symbol: win.PSYMBOL_INFOW) -> win.BOOL ---
	SymEnumSymbolsW :: proc(hProcess: win.HANDLE, BaseOfDll: win.DWORD64, Mask: win.wstring, Callback: Sym_Enum_Callback, UserContext: rawptr) -> win.BOOL ---
}

@(private) sym_initialized: bool
@(private) exe_index: map[string]Exe_Symbol // one enumeration pass; process-stable
@(private) exe_index_built: bool
@(private) exe_cache: map[string]Exe_Symbol // memoizes the SymFromNameW tier

Exe_Symbol :: struct {
	addr:  rawptr,
	size:  int,
	found: bool,
}

// Initializes DbgHelp once. Returns false if no PDB loads for the exe (a build without
// `-debug`).
sym_init :: proc() -> bool {
	if sym_initialized {
		return true
	}
	if !win.SymInitialize(win.GetCurrentProcess(), nil, true) {
		return false
	}
	win.SymSetOptions(win.SYMOPT_DEFERRED_LOADS)
	sym_initialized = true
	return true
}

// Enumerates the running exe's symbols once into exe_index. A partial or failed
// enumeration leaves fewer entries; those names fall through to the later tiers.
@(private)
build_exe_index :: proc() {
	exe_index_built = true // set first, so a failed pass is not retried on every call
	// A big exe enumerates tens of thousands of symbols; size the map up front.
	exe_index = make(map[string]Exe_Symbol, 1 << 16)
	base := win.DWORD64(uintptr(win.GetModuleHandleW(nil)))
	SymEnumSymbolsW(win.GetCurrentProcess(), base, nil, exe_index_cb, &exe_index)
}

@(private)
exe_index_cb :: proc "system" (sym: ^win.SYMBOL_INFOW, size: win.ULONG, ctx: rawptr) -> win.BOOL {
	context = runtime.default_context()
	if sym == nil || sym.NameLen == 0 {
		return win.TRUE
	}
	// The utf8 copy is heap-allocated, so it is a stable map key for the process lifetime.
	name, err := win.wstring_to_utf8(win.wstring(&sym.Name[0]), int(sym.NameLen), context.allocator)
	if err != nil {
		return win.TRUE
	}
	idx := (^map[string]Exe_Symbol)(ctx)
	idx[name] = Exe_Symbol{rawptr(uintptr(sym.Address)), int(sym.Size), true}
	return win.TRUE
}

// Whether a name absent from the index is worth a SymFromNameW scan. Skip only names that
// can never be a resolvable exe symbol:
//   - a leading `.` or `@` is COFF section / metadata (`.data`, `@feat.00`)
//   - `$` marks a compiler-generated helper (`__$equal`, `__$hasher`, `__$map_*`)
//   - `::[` / `-.` mark a file-private or static-local name
// A plain C-runtime name like `memmove` carries none of these, so it still resolves.
// Skipping it would leave every object that calls it dirty, so an edit to that object would
// silently keep running the old body.
@(private)
worth_symfromname :: proc(name: string) -> bool {
	if len(name) == 0 || name[0] == '.' || name[0] == '@' {
		return false
	}
	return(
		!strings.contains(name, "$") &&
		!strings.contains(name, "::[") &&
		!strings.contains(name, "-.") \
	)
}

// Resolves a link name in the running exe's PDB (see the tier comment at the top).
exe_symbol :: proc(name: string) -> (addr: rawptr, size: int, ok: bool) {
	if !exe_index_built {
		build_exe_index()
	}
	if s, hit := exe_index[name]; hit {
		return s.addr, s.size, s.found
	}

	if exe_cache == nil {
		exe_cache = make(map[string]Exe_Symbol)
	}
	if s, hit := exe_cache[name]; hit {
		return s.addr, s.size, s.found
	}

	s: Exe_Symbol
	if worth_symfromname(name) {
		buf: [size_of(win.SYMBOL_INFOW) + 2048]u8
		si := (^win.SYMBOL_INFOW)(&buf[0])
		si.SizeOfStruct = size_of(win.SYMBOL_INFOW)
		si.MaxNameLen = 1024
		if SymFromNameW(win.GetCurrentProcess(), win.utf8_to_wstring(name), si) {
			s = Exe_Symbol{rawptr(uintptr(si.Address)), int(si.Size), true}
		}
	}

	// The caller's name usually points into object bytes freed at the end of the patch, so
	// the process-lifetime cache clones its keys.
	exe_cache[strings.clone(name)] = s
	return s.addr, s.size, s.found
}

sym_reset :: proc() {
	clear(&exe_cache)
	exe_index_built = false
}
