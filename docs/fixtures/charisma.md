# Charisma pose cases

`cases_pose.json`, written by

```bash
python3 tools/charisma_tables.py gog_incubation \
    --emit-pose-cases tests/fixtures/charisma/cases_pose.json
```

is the fixture `godot/tests/test_charisma.gd` replays. It is gitignored — it
is derived from Blue Byte data and is ~6.8 MB — so this file records what it
holds.

## The oracle is executable Python, and it says so

Every other case file under `tests/fixtures/` that pins a *runtime* rule was
captured from `Incubation.exe` itself. This one was not, and the reason is
structural rather than an omission: Charisma is **statically linked into
`Incubation.exe` and exports nothing**, so `tools/wine_visn/`'s route — load
the DLL out of process and call an export — is closed. `tools/dbgcall/` can
reach the code inside a live process, but `V100Part::Update` (`0x004a6807`)
takes a constructed part with a loaded descriptor and a bound movement, not
values, so standing one up is most of a loader.

So the boundary here is **rank 2, executable Python**
([`docs/92`](../92-remake-architecture.md) §5): `tools/inclib/pose.py`
is the reference and the GDScript sampler is diffed against it. What keeps that
honest is that `inclib/pose.py` is not a fresh transcription — it is the model
that draws `tools/out/skeletons/*.png`, whose four contact sheets are the
by-eye proof of `docs/40` §5.2 and §6, and it produced them byte-identically
before and after being lifted out of `tools/cho_export.py`.

## What the file holds

311 `(model, animation)` pairs — every pairing the four selectors of
[`docs/40`](../40-charisma-model-animation.md) §7.2 can actually
produce, so no clip is posed against a body it is never chosen with.

Per case:

| Key | Meaning |
| --- | --- |
| `model`, `animation` | the `.cho` and `.cha` stems |
| `bones` | every `SkeletonNode` name, in file order — the index basis for the two flat arrays |
| `key_classes` | the interpolators this pair exercises |
| `frames` | 5 evenly spaced times spanning the clip, **plus up to 4 targeted probes** (below); `joints` is the **world** translation of every bone, flattened |
| `local_time`, `locals` | the middle frame's full 16-float **local** matrix per bone |

### The targeted probes, and the mutation that demanded them

The first version of this fixture sampled 5 evenly spaced frames and nothing
else. The mutation battery then found that **disabling the 0.25-frame hold rule
in the GDScript sampler changed nothing the fixture could see** — a 0.25-frame
window inside a 60-frame clip is missed by five samples essentially always,
even though 5.2 % of the corpus' 896 443 segments are exactly that long.

So the emitter now also samples *inside* short segments: for each case, up to
four times taken at `u = 0.5` and `u = 0.75` of a `dt <= 0.25` segment — the
first is the inclusive boundary of the "which key is returned" test and picks
the earlier key, the second picks the later one. 194 of the 311 cases have at
least one. Both halves of the rule are now caught: dropping the threshold moves
a joint by 119 units, picking the wrong key by 2.7.

This is the failure mode the project's rules are about. The check looked broad
and was narrow, and only mutating the thing it claimed to test showed it.

### What `frames` catches

`frames` catches everything that moves a bone in space — a transposed or
`(w, x, y, z)` quaternion, slerp where the engine uses squad, a dropped hold
interval, the top-level bone's absolute-position branch, a broken parent
accumulation. `locals` exists because a rotation error on a **childless leaf**
moves no joint at all, and 5 frames of positions would pass it.

## Coverage the suite asserts, and why it is asserted

| Key class | Cases | Why it must be present |
| --- | --- | --- |
| `LinearRotationKey` | 302 | the common path |
| `LinearVectorKey` | 301 | the common path |
| `BezierRotationKey` | 103 | **squad**. `docs/40` §4.4: replacing it with slerp differs by up to 0.246 per component, and a fixture of only linear tracks cannot see that |
| `BezierVectorKey` | 6 | the cubic Bezier vector, six cases and no more — a fixture that dropped them would still look broad |

## The float tolerance, and the size of what it must catch

This is the project's first diff that is not exact integers: `slerp` and
`squad` go through libm transcendentals, so Python and GDScript cannot promise
bit equality. The suite compares at **1e-4 absolute** per element. That is two
to four orders of magnitude below every error it exists to catch, all of them
measured in `docs/40`:

* a transposed or `(w, x, y, z)` quaternion — gross, whole limbs;
* slerp instead of squad — up to **0.246** per component;
* dropping the 0.25/0.5 hold rule — changes **5.2 %** of all intervals;
* skipping `quat_to_matrix`'s squared-norm division — mis-scales the 1 169
  shipped keys that are more than 1 % off unit length, by up to 40 %;
* adding the bind translation on the top-level bone — offsets the whole figure
  (for `P0_000` the root moves from z ≈ 29 to z ≈ 129).

The tolerance is a decision with that list beside it, not slack.
