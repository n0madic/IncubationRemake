extends RefCounted

## **Deliberately invalid.**  This file must not compile.
##
## `var x = 1` has no static type, and `debug/gdscript/warnings/untyped_declaration`
## is set to 2 (error) in `project.godot`, so loading it fails.
## `tests/test_warnings_gate.gd` asserts that it does -- which is how the last
## bullet of docs/92 section 10.4 becomes a gate rather than a setting.
##
## Do not "fix" it.  Do not exclude this directory in `directory_rules`: the
## exclusion would make the violation legal and the gate would pass while
## proving nothing.
func broken():
	var x = 1
	return x
