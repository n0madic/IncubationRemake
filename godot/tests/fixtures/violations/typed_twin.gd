extends RefCounted

## The same function, typed.  It exists so the gate distinguishes "the strict
## setting rejects this file" from "nothing in this directory loads at all".
func fixed() -> int:
	var x: int = 1
	return x
