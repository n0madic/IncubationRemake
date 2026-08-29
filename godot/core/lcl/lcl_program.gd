class_name LclProgram
extends RefCounted

## One parsed `.lcl`, narrowed once out of the cache document.
##
## `missions/<name>/script.json` is JSON, so every number in it is a `float` and
## every container a `Variant`. The narrowing happens **here**, at the loading
## boundary, and the interpreter then reads typed values -- the same rule
## [DictRead] states for the rest of the cache, and for the same reason: an
## interpreter that narrowed on every instruction would do it 79 times per
## invocation of `_C_140` and once per mission here.

const SCHEMA: String = "incubation.script/1"

## docs/20 section 3.2 -- an argument's three kinds, plus the two the parser
## produces for a bare word.
const ARG_NUMBER: int = 0
const ARG_VAR: int = 1
const ARG_STRING: int = 2
const ARG_EMPTY: int = 3

var mission: String = ""
var header_line: int = 0
## One dictionary per instruction: `kind`, `name`, `line`, `op`, and the three
## parameter arrays of docs/20 section 3.2 already split out.
var instructions: Array[Dictionary] = []
## Label name to instruction index.
var labels: Dictionary = {}


static func from_document(document: Dictionary) -> LclProgram:
	var program: LclProgram = LclProgram.new()
	if DictRead.as_string(document.get("schema", "")) != SCHEMA:
		return program
	var source: Dictionary = DictRead.as_dict(document.get("source", {}))
	program.mission = DictRead.as_string(source.get("mission", ""))
	program.header_line = DictRead.as_int(document.get("header_line", 0))
	for entry: Variant in DictRead.as_array(document.get("instructions", [])):
		program.instructions.append(_instruction(DictRead.as_dict(entry)))
	var labels: Dictionary = DictRead.as_dict(document.get("labels", {}))
	for name: Variant in labels:
		program.labels[DictRead.as_string(name)] = DictRead.as_int(
			labels[name])
	return program


func is_empty() -> bool:
	return instructions.is_empty()


## docs/20 section 3.2 -- numbers, strings and variable references go into
## **separate** arrays in the order they appear, and the arrays are pre-filled
## with -1 and "". That is why calling a command with fewer arguments than its
## handler reads is well defined rather than undefined, and why
## `FallingSpores`'s string can sit between its sixth and seventh number.
static func _instruction(record: Dictionary) -> Dictionary:
	var numbers: PackedInt32Array = PackedInt32Array()
	var strings: PackedStringArray = PackedStringArray()
	var variables: PackedInt32Array = PackedInt32Array()
	for entry: Variant in DictRead.as_array(record.get("args", [])):
		var arg: Dictionary = DictRead.as_dict(entry)
		match DictRead.as_string(arg.get("kind", "")):
			"number":
				numbers.append(DictRead.as_int(arg.get("value", 0)))
			"var":
				variables.append(DictRead.as_int(arg.get("slot_index", -1)))
			"string", "name":
				strings.append(DictRead.as_string(arg.get("value", "")))
			_:
				# `empty` contributes to no array; the corpus has none.
				pass
	return {
		"kind": DictRead.as_string(record.get("kind", "")),
		"name": DictRead.as_string(record.get("name", "")),
		"line": DictRead.as_int(record.get("line", 0)),
		"op": DictRead.as_string(record.get("op", ">")),
		"num": numbers,
		"str": strings,
		"var": variables,
	}
