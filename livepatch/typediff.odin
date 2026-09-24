#+build windows amd64
package livepatch

import "base:runtime"
import "core:reflect"
import "core:strings"

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

qualified_name :: proc(named: runtime.Type_Info_Named, allocator: runtime.Allocator) -> string {
	return strings.concatenate({named.pkg, "::", named.name}, allocator)
}

// Only a named type can make a cycle, so an unnamed pointee is compared in full.
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

types_equal :: proc(a, b: ^runtime.Type_Info) -> bool {
	if a == b {
		return true
	}
	if a == nil || b == nil {
		return false
	}
	// A kind with no extra fields is equal after this check.
	if a.size != b.size || a.align != b.align || reflect.union_variant_typeid(a.variant) != reflect.union_variant_typeid(b.variant) {
		return false
	}

	#partial switch x in a.variant {
	case runtime.Type_Info_Named:
		y := b.variant.(runtime.Type_Info_Named) or_return
		if x.name != y.name || x.pkg != y.pkg {
			return false
		}
		return types_equal(x.base, y.base)

	case runtime.Type_Info_Integer:
		y := b.variant.(runtime.Type_Info_Integer) or_return
		return x.signed == y.signed && x.endianness == y.endianness

	case runtime.Type_Info_Float:
		y := b.variant.(runtime.Type_Info_Float) or_return
		return x.endianness == y.endianness

	case runtime.Type_Info_String:
		y := b.variant.(runtime.Type_Info_String) or_return
		return x.is_cstring == y.is_cstring && x.encoding == y.encoding

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

	return true
}
