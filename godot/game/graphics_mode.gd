class_name GraphicsMode
extends RefCounted

## The *Graphics* preset of the options screen and the named switches behind
## it -- docs/92 section 7.29.
##
## **One row, three answers, a flag per feature.** The options screen has room
## for no more rows, and a player chooses a look rather than six switches; so
## the user-facing value is a preset, exactly as section 7.1's `Faithful` is,
## and every consumer asks the named question rather than comparing preset
## numbers. Everything here is presentation: nothing enters a save or the
## canonical hash.
##
## | Preset | Sampling | Colour | Effect light, halos, MSAA |
## |---|---|---|---|
## | `ORIGINAL` | nearest texel | the engine's RGB565 | off |
## | `SMOOTH` | bilinear, clamped | the exact 24-bit decode | off |
## | `ENHANCED` | mipmapped, anisotropic | the exact 24-bit decode | on |

const ORIGINAL: int = 0
const SMOOTH: int = 1
const ENHANCED: int = 2
const DEFAULT: int = ORIGINAL

## How a bank texture is read -- [method MeshBuilder.set_sampling].
const SAMPLING_NEAREST: int = 0
const SAMPLING_LINEAR: int = 1
const SAMPLING_MIPMAPPED: int = 2


static func clamped(preset: int) -> int:
	return clampi(preset, ORIGINAL, ENHANCED)


static func sampling(preset: int) -> int:
	match clamped(preset):
		SMOOTH:
			return SAMPLING_LINEAR
		ENHANCED:
			return SAMPLING_MIPMAPPED
	return SAMPLING_NEAREST


## Whether the 24-bit decode is drawn as it is rather than quantised to the
## engine's 5-6-5 fields -- [method MeshBuilder.channel_tables].
static func exact_colour(preset: int) -> bool:
	return clamped(preset) >= SMOOTH


static func effect_lights(preset: int) -> bool:
	return clamped(preset) >= ENHANCED


static func halos(preset: int) -> bool:
	return clamped(preset) >= ENHANCED


static func msaa(preset: int) -> bool:
	return clamped(preset) >= ENHANCED
