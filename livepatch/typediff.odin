#+build windows amd64, linux amd64
package livepatch

import "base:runtime"
import "core:reflect"
import "core:strings"

diff_types :: proc(old_table, new_table: []^runtime.Type_Info, allocator := context.temp_allocator) -> []Type_Change {
	old_by_name := make(map[string]^runtime.Type_Info, len(old_table), allocator)
	for old_type in old_table {
		if old_type == nil {
			continue
		}
		if named, ok := old_type.variant.(runtime.Type_Info_Named); ok {
			old_by_name[qualified_name(named, allocator)] = old_type
		}
	}

	changed := make([dynamic]Type_Change, 0, 0, allocator)
	for new_type in new_table {
		if new_type == nil {
			continue
		}
		named := new_type.variant.(runtime.Type_Info_Named) or_continue
		old_type := old_by_name[qualified_name(named, allocator)] or_continue
		if !types_equal(old_type, new_type) {
			append(&changed, Type_Change{name = named.name, old = old_type, new = new_type})
		}
	}
	return changed[:]
}

qualified_name :: proc(named: runtime.Type_Info_Named, allocator: runtime.Allocator) -> string {
	return strings.concatenate({named.pkg, "::", named.name}, allocator)
}

// Only a named type can make a cycle, so an unnamed pointee is compared in full.
elem_equal :: proc(left, right: ^runtime.Type_Info) -> bool {
	left_named, left_is_named := named_of(left)
	right_named, right_is_named := named_of(right)
	if left_is_named || right_is_named {
		return left_is_named && right_is_named && left_named.name == right_named.name && left_named.pkg == right_named.pkg
	}
	return types_equal(left, right)
}

@(private = "file")
named_of :: proc(type_info: ^runtime.Type_Info) -> (runtime.Type_Info_Named, bool) {
	if type_info == nil {
		return {}, false
	}
	return type_info.variant.(runtime.Type_Info_Named)
}

types_equal :: proc(left, right: ^runtime.Type_Info) -> bool {
	if left == right {
		return true
	}
	if left == nil || right == nil {
		return false
	}
	// A kind with no extra fields is equal after this check.
	if left.size != right.size || left.align != right.align || reflect.union_variant_typeid(left.variant) != reflect.union_variant_typeid(right.variant) {
		return false
	}

	#partial switch left_variant in left.variant {
	case runtime.Type_Info_Named:
		right_variant := right.variant.(runtime.Type_Info_Named) or_return
		if left_variant.name != right_variant.name || left_variant.pkg != right_variant.pkg {
			return false
		}
		return types_equal(left_variant.base, right_variant.base)

	case runtime.Type_Info_Integer:
		right_variant := right.variant.(runtime.Type_Info_Integer) or_return
		return left_variant.signed == right_variant.signed && left_variant.endianness == right_variant.endianness

	case runtime.Type_Info_Float:
		right_variant := right.variant.(runtime.Type_Info_Float) or_return
		return left_variant.endianness == right_variant.endianness

	case runtime.Type_Info_String:
		right_variant := right.variant.(runtime.Type_Info_String) or_return
		return left_variant.is_cstring == right_variant.is_cstring && left_variant.encoding == right_variant.encoding

	case runtime.Type_Info_Pointer:
		right_variant := right.variant.(runtime.Type_Info_Pointer) or_return
		return elem_equal(left_variant.elem, right_variant.elem)

	case runtime.Type_Info_Multi_Pointer:
		right_variant := right.variant.(runtime.Type_Info_Multi_Pointer) or_return
		return elem_equal(left_variant.elem, right_variant.elem)

	case runtime.Type_Info_Soa_Pointer:
		right_variant := right.variant.(runtime.Type_Info_Soa_Pointer) or_return
		return elem_equal(left_variant.elem, right_variant.elem)

	case runtime.Type_Info_Dynamic_Array:
		right_variant := right.variant.(runtime.Type_Info_Dynamic_Array) or_return
		return elem_equal(left_variant.elem, right_variant.elem)

	case runtime.Type_Info_Slice:
		right_variant := right.variant.(runtime.Type_Info_Slice) or_return
		return elem_equal(left_variant.elem, right_variant.elem)

	case runtime.Type_Info_Fixed_Capacity_Dynamic_Array:
		right_variant := right.variant.(runtime.Type_Info_Fixed_Capacity_Dynamic_Array) or_return
		return left_variant.capacity == right_variant.capacity && elem_equal(left_variant.elem, right_variant.elem)

	case runtime.Type_Info_Map:
		right_variant := right.variant.(runtime.Type_Info_Map) or_return
		return elem_equal(left_variant.key, right_variant.key) && elem_equal(left_variant.value, right_variant.value)

	case runtime.Type_Info_Procedure:
		right_variant := right.variant.(runtime.Type_Info_Procedure) or_return
		return left_variant.variadic == right_variant.variadic && left_variant.convention == right_variant.convention

	case runtime.Type_Info_Array:
		right_variant := right.variant.(runtime.Type_Info_Array) or_return
		return left_variant.count == right_variant.count && types_equal(left_variant.elem, right_variant.elem)

	case runtime.Type_Info_Enumerated_Array:
		right_variant := right.variant.(runtime.Type_Info_Enumerated_Array) or_return
		return left_variant.count == right_variant.count && types_equal(left_variant.index, right_variant.index) && types_equal(left_variant.elem, right_variant.elem)

	case runtime.Type_Info_Simd_Vector:
		right_variant := right.variant.(runtime.Type_Info_Simd_Vector) or_return
		return left_variant.count == right_variant.count && types_equal(left_variant.elem, right_variant.elem)

	case runtime.Type_Info_Matrix:
		right_variant := right.variant.(runtime.Type_Info_Matrix) or_return
		if left_variant.row_count != right_variant.row_count || left_variant.column_count != right_variant.column_count || left_variant.layout != right_variant.layout {
			return false
		}
		return types_equal(left_variant.elem, right_variant.elem)

	case runtime.Type_Info_Bit_Set:
		right_variant := right.variant.(runtime.Type_Info_Bit_Set) or_return
		if left_variant.lower != right_variant.lower || left_variant.upper != right_variant.upper {
			return false
		}
		return types_equal(left_variant.underlying, right_variant.underlying) && types_equal(left_variant.elem, right_variant.elem)

	case runtime.Type_Info_Struct:
		right_variant := right.variant.(runtime.Type_Info_Struct) or_return
		if left_variant.field_count != right_variant.field_count || left_variant.flags != right_variant.flags {
			return false
		}
		for i in 0 ..< left_variant.field_count {
			if left_variant.names[i] != right_variant.names[i] || left_variant.offsets[i] != right_variant.offsets[i] {
				return false
			}
			if !types_equal(left_variant.types[i], right_variant.types[i]) {
				return false
			}
		}
		return true

	case runtime.Type_Info_Union:
		right_variant := right.variant.(runtime.Type_Info_Union) or_return
		if len(left_variant.variants) != len(right_variant.variants) || left_variant.tag_offset != right_variant.tag_offset {
			return false
		}
		if left_variant.no_nil != right_variant.no_nil || left_variant.shared_nil != right_variant.shared_nil {
			return false
		}
		for _, i in left_variant.variants {
			if !types_equal(left_variant.variants[i], right_variant.variants[i]) {
				return false
			}
		}
		return true

	case runtime.Type_Info_Enum:
		right_variant := right.variant.(runtime.Type_Info_Enum) or_return
		if len(left_variant.names) != len(right_variant.names) {
			return false
		}
		for _, i in left_variant.names {
			if left_variant.names[i] != right_variant.names[i] || left_variant.values[i] != right_variant.values[i] {
				return false
			}
		}
		return types_equal(left_variant.base, right_variant.base)

	case runtime.Type_Info_Bit_Field:
		right_variant := right.variant.(runtime.Type_Info_Bit_Field) or_return
		if left_variant.field_count != right_variant.field_count {
			return false
		}
		for i in 0 ..< left_variant.field_count {
			if left_variant.names[i] != right_variant.names[i] || left_variant.bit_sizes[i] != right_variant.bit_sizes[i] || left_variant.bit_offsets[i] != right_variant.bit_offsets[i] {
				return false
			}
			if !types_equal(left_variant.types[i], right_variant.types[i]) {
				return false
			}
		}
		return types_equal(left_variant.backing_type, right_variant.backing_type)

	case runtime.Type_Info_Parameters:
		right_variant := right.variant.(runtime.Type_Info_Parameters) or_return
		return len(left_variant.types) == len(right_variant.types)
	}

	return true
}
