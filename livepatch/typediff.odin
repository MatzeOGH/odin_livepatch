#+build windows
package livepatch

// The old-versus-new type diff that feeds the patch hooks (hooks.odin).
//
// This cannot reuse reflect.are_types_identical: it compares a named type by the pointer
// identity of its base, and the two arrays hold different pointers for the same type, so
// every type would look changed. types_equal matches named types by name and compares
// layout by structure.
//
// Recursion stops at a pointer: a pointer is one word whatever it points at, so a change
// behind it does not change the holder's layout, and it breaks recursive-type cycles. The
// pointee is reported on its own. By-value nesting recurses fully.

import "base:runtime"
import "core:strings"

// The old side: the exe's current type-info array, before commit swaps the header.
exe_type_table :: proc() -> []^runtime.Type_Info {
	return runtime.type_table
}

// The new side: the new build's array, from the relocated slice header merge_symbols captured.
mapped_type_table :: proc(header: rawptr) -> []^runtime.Type_Info {
	return (^[]^runtime.Type_Info)(header)^
}

diff_types :: proc(old_tbl, new_tbl: []^runtime.Type_Info, allocator := context.temp_allocator) -> []Type_Change {
	old_by_name := make(map[string]^runtime.Type_Info, len(old_tbl), allocator)
	for ti in old_tbl {
		if ti == nil {
			continue
		}
		if named, ok := ti.variant.(runtime.Type_Info_Named); ok {
			old_by_name[qualified_name(named, allocator)] = ti
		}
	}

	changed := make([dynamic]Type_Change, 0, 0, allocator)
	for ti in new_tbl {
		if ti == nil {
			continue
		}
		named, ok := ti.variant.(runtime.Type_Info_Named)
		if !ok {
			continue
		}
		old := old_by_name[qualified_name(named, allocator)] or_continue
		if !types_equal(old, ti) {
			append(&changed, Type_Change{name = named.name, old = old, new = ti})
		}
	}
	return changed[:]
}

@(private = "file")
qualified_name :: proc(named: runtime.Type_Info_Named, allocator: runtime.Allocator) -> string {
	return strings.concatenate({named.pkg, "::", named.name}, allocator)
}

// A named pointee is compared by name only (enough at a pointer boundary, and breaks
// cycles). An unnamed pointee (^int) has no cycle, so it is compared in full.
@(private = "file")
elem_equal :: proc(a, b: ^runtime.Type_Info) -> bool {
	an, aok := named_of(a)
	bn, bok := named_of(b)
	if aok || bok {
		return aok && bok && an.name == bn.name && an.pkg == bn.pkg
	}
	return types_equal(a, b)
}

@(private = "file")
named_of :: proc(t: ^runtime.Type_Info) -> (runtime.Type_Info_Named, bool) {
	if t == nil {
		return {}, false
	}
	return t.variant.(runtime.Type_Info_Named)
}

// Whether two types have the same layout, matching named types by name (see the file comment).
types_equal :: proc(a, b: ^runtime.Type_Info) -> bool {
	if a == b {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	if a.size != b.size || a.align != b.align {
		return false
	}

	switch x in a.variant {
	case runtime.Type_Info_Named:
		y := b.variant.(runtime.Type_Info_Named) or_return
		if x.name != y.name || x.pkg != y.pkg {
			return false
		}
		return types_equal(x.base, y.base)

	case runtime.Type_Info_Integer:
		y := b.variant.(runtime.Type_Info_Integer) or_return
		return x.signed == y.signed && x.endianness == y.endianness

	case runtime.Type_Info_Rune:
		_ = b.variant.(runtime.Type_Info_Rune) or_return
		return true

	case runtime.Type_Info_Float:
		y := b.variant.(runtime.Type_Info_Float) or_return
		return x.endianness == y.endianness

	case runtime.Type_Info_Complex:
		_ = b.variant.(runtime.Type_Info_Complex) or_return
		return true

	case runtime.Type_Info_Quaternion:
		_ = b.variant.(runtime.Type_Info_Quaternion) or_return
		return true

	case runtime.Type_Info_String:
		y := b.variant.(runtime.Type_Info_String) or_return
		return x.is_cstring == y.is_cstring && x.encoding == y.encoding

	case runtime.Type_Info_Boolean:
		_ = b.variant.(runtime.Type_Info_Boolean) or_return
		return true

	case runtime.Type_Info_Any:
		_ = b.variant.(runtime.Type_Info_Any) or_return
		return true

	case runtime.Type_Info_Type_Id:
		_ = b.variant.(runtime.Type_Info_Type_Id) or_return
		return true

	// Pointer family: stop at the pointer.
	case runtime.Type_Info_Pointer:
		y := b.variant.(runtime.Type_Info_Pointer) or_return
		return elem_equal(x.elem, y.elem)

	case runtime.Type_Info_Multi_Pointer:
		y := b.variant.(runtime.Type_Info_Multi_Pointer) or_return
		return elem_equal(x.elem, y.elem)

	case runtime.Type_Info_Soa_Pointer:
		y := b.variant.(runtime.Type_Info_Soa_Pointer) or_return
		return elem_equal(x.elem, y.elem)

	case runtime.Type_Info_Dynamic_Array:
		y := b.variant.(runtime.Type_Info_Dynamic_Array) or_return
		return elem_equal(x.elem, y.elem)

	case runtime.Type_Info_Slice:
		y := b.variant.(runtime.Type_Info_Slice) or_return
		return elem_equal(x.elem, y.elem)

	case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		y := b.variant.(runtime.Type_Info_Fixed_Capacity_Dynamic_Array) or_return
		return x.capacity == y.capacity && elem_equal(x.elem, y.elem)

	case runtime.Type_Info_Map:
		y := b.variant.(runtime.Type_Info_Map) or_return
		return elem_equal(x.key, y.key) && elem_equal(x.value, y.value)

	case runtime.Type_Info_Procedure:
		y := b.variant.(runtime.Type_Info_Procedure) or_return
		return x.variadic == y.variadic && x.convention == y.convention

	// By-value composition: recurse fully.
	case runtime.Type_Info_Array:
		y := b.variant.(runtime.Type_Info_Array) or_return
		return x.count == y.count && types_equal(x.elem, y.elem)

	case runtime.Type_Info_Enumerated_Array:
		y := b.variant.(runtime.Type_Info_Enumerated_Array) or_return
		return x.count == y.count && types_equal(x.index, y.index) && types_equal(x.elem, y.elem)

	case runtime.Type_Info_Simd_Vector:
		y := b.variant.(runtime.Type_Info_Simd_Vector) or_return
		return x.count == y.count && types_equal(x.elem, y.elem)

	case runtime.Type_Info_Matrix:
		y := b.variant.(runtime.Type_Info_Matrix) or_return
		if x.row_count != y.row_count || x.column_count != y.column_count || x.layout != y.layout {
			return false
		}
		return types_equal(x.elem, y.elem)

	case runtime.Type_Info_Bit_Set:
		y := b.variant.(runtime.Type_Info_Bit_Set) or_return
		if x.lower != y.lower || x.upper != y.upper {
			return false
		}
		return types_equal(x.underlying, y.underlying) && types_equal(x.elem, y.elem)

	case runtime.Type_Info_Struct:
		y := b.variant.(runtime.Type_Info_Struct) or_return
		if x.field_count != y.field_count || x.flags != y.flags {
			return false
		}
		for i in 0 ..< x.field_count {
			if x.names[i] != y.names[i] || x.offsets[i] != y.offsets[i] {
				return false
			}
			if !types_equal(x.types[i], y.types[i]) {
				return false
			}
		}
		return true

	case runtime.Type_Info_Union:
		y := b.variant.(runtime.Type_Info_Union) or_return
		if len(x.variants) != len(y.variants) || x.tag_offset != y.tag_offset {
			return false
		}
		if x.no_nil != y.no_nil || x.shared_nil != y.shared_nil {
			return false
		}
		for _, i in x.variants {
			if !types_equal(x.variants[i], y.variants[i]) {
				return false
			}
		}
		return true

	case runtime.Type_Info_Enum:
		y := b.variant.(runtime.Type_Info_Enum) or_return
		if len(x.names) != len(y.names) {
			return false
		}
		for _, i in x.names {
			if x.names[i] != y.names[i] || x.values[i] != y.values[i] {
				return false
			}
		}
		return types_equal(x.base, y.base)

	case runtime.Type_Info_Bit_Field:
		y := b.variant.(runtime.Type_Info_Bit_Field) or_return
		if x.field_count != y.field_count {
			return false
		}
		for i in 0 ..< x.field_count {
			if x.names[i] != y.names[i] || x.bit_sizes[i] != y.bit_sizes[i] || x.bit_offsets[i] != y.bit_offsets[i] {
				return false
			}
			if !types_equal(x.types[i], y.types[i]) {
				return false
			}
		}
		return types_equal(x.backing_type, y.backing_type)

	case runtime.Type_Info_Parameters:
		y := b.variant.(runtime.Type_Info_Parameters) or_return
		return len(x.types) == len(y.types)
	}

	// Same size, align, and kind, with no extra fields to compare.
	return true
}
