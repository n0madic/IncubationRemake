class_name GameBlobHooks
extends BlobHooks

## The [BlobHooks] a running mission uses: an arm's spawn request is **run**,
## not merely written down.
##
## [method BlobKinds._spawn] is the arms' own `aBlob_Create*` call, and the
## base class answers it by recording the request and returning success. That
## is what an oracle wants -- `tests/test_blob.gd` compares the request, and
## `tools/blob_runtime.py` records the same one, arm for arm -- and it is not
## what a game wants: the child effect never reached the pool, so a barrel
## that should throw debris threw nothing, and the *arrived* flag of docs/42
## section 4.6 had nothing to raise it.
##
## **Thirteen creator addresses are reachable from an arm and all thirteen
## are transcribed** (docs/97 section 49). Twelve of them arrived with this
## note: they were reached from nowhere else -- no weapon switch names them
## and no set piece calls them -- so nothing in the remake had ever needed
## them, and a request for one found no program and made nothing, which is
## exactly what the whole layer used to do. [member unhandled] counts a
## request that still finds none, so an address added to [BlobKinds] without
## a program is a number rather than a silence.
##
## They are not read off the disassembly and left there. `blob_gold.py`'s
## `zoom_bob_*` and `spawn_*` families poke a donor record to each kind whose
## arm calls one, write the second generator's seed, step one `aBlob_Update`
## and read the pool **wide enough to hold the child** -- and `spawn.*` then
## replays this class's own path, arm and creator together, against the
## records the engine left.
##
## The order is the engine's. A creator called from an arm draws from the one
## `aRandom2` stream at the moment of the call, so the seed is written back
## before the sweep goes on, and the record it makes goes into the first free
## slot -- which `aCheckInBlobObjects` `0x0041E3D0` visits later in the **same**
## sweep when the slot is above the one being ticked (`inc edi`,
## `cmp edi, 0x1C2`), and not at all when it is below. [method
## BlobPool.tick_all] walks by index for that reason.

## Where the children go, held **weakly**. The pool owns its hooks
## ([method BlobPool.set_hooks]), so a strong pointer back is a reference
## cycle, and Godot counts references rather than collecting them: the suite
## run then ends with `ObjectDB instances were leaked at exit` and
## `run_tests.sh` exits non-zero, which is how this one was found.
var _pool: WeakRef = null
## What a creator reads: this world set's models, the geometry tables and the
## gore level. Built once per mission -- none of it changes inside one.
var inputs: BlobPrograms.Inputs = null
## How many requests found a program, and how many records they made.
var executed: int = 0
var made: int = 0
## Creator address -> how many requests found no program. A number rather than
## a silence: "the layer made nothing" and "this creator is not written yet"
## look identical from the pool. Nothing in [BlobKinds] lands here since
## docs/97 section 49; an address added without a program would.
var unhandled: Dictionary[int, int] = {}
## Creator address -> how many requests carried **fewer values than the
## creator takes**. A different answer from [member unhandled] and a worse
## one: the program exists and the request cannot use it. Five of the seven
## `0x00423720` requests in [BlobKinds] were in this state until they were
## stepped inside the engine and fixed, which is how the counter earned its
## place; `blob_tables.py`'s `arm_spawn.arity` now expects none.
var short_call: Dictionary[int, int] = {}


static func over(target: BlobPool, with: BlobPrograms.Inputs) -> GameBlobHooks:
	var hooks: GameBlobHooks = GameBlobHooks.new()
	hooks._pool = weakref(target)
	hooks.inputs = with
	return hooks


## The pool the hooks were installed on, or null once nothing else holds it.
func pool() -> BlobPool:
	if _pool == null:
		return null
	# An assignment from `Variant` is checked at run time; `as` would be a
	# warning, and warnings are errors here.
	var held: BlobPool = _pool.get_ref()
	return held


## The creator's own name in [BlobPrograms], which files them by address.
static func program_of(creator: int) -> String:
	return "0x%08X" % creator


func spawn(creator: int, args: Array, source: Blob) -> bool:
	var target: BlobPool = pool()
	if target == null or inputs == null:
		return super(creator, args, source)
	var numbers: PackedInt32Array = PackedInt32Array()
	for value: Variant in args:
		numbers.append(DictRead.as_int(value))
	var child: BlobPrograms.Pool = BlobPrograms.Pool.create(inputs)
	var draws: BlobPrograms.Draws = BlobPrograms.Draws.create(
		rng.seed if rng.seed != 0.0 else 1.0)
	var name: String = program_of(creator)
	var needed: int = BlobPrograms.args_needed(name)
	if needed >= 0 and numbers.size() < needed:
		short_call[creator] = short_call.get(creator, 0) + 1
		return spawns_succeed
	if not BlobPrograms.run(name, child, draws, numbers, inputs):
		unhandled[creator] = unhandled.get(creator, 0) + 1
		return spawns_succeed
	# One stream, as `aRandom2` is: the arms after this one in the sweep
	# continue from where the creator left it.
	rng.randomize_seed(draws.rng.seed)
	# A creator that writes 0 over the *arrived* flag does so here too, and
	# not only when a set piece calls it. None of the thirteen an arm can
	# reach is one of the five that do (docs/42 section 4.6) -- the arm's own
	# para bomb `0x0042B150` is **not** the set piece's `0x0042B070` and
	# writes nothing -- so this arm of the branch is the mechanism being
	# complete rather than a case that runs.
	if child.clears_arrived:
		target.set_arrived(false)
	executed += 1
	var born: int = BlobPrograms.spawn_into(target, child.records)
	made += born
	# A pool with no free slot returns -1 in the original and the effect is
	# silently dropped (docs/28 section 7.1); a creator that refused every
	# record of its own -- a model this world set does not carry -- did not
	# fail to find a slot, so it answers true.
	return born > 0 or child.records.is_empty()
