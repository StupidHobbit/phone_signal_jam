extends Node

## Terrain generator: rolling grassy hills, single tile.
## Assign a FastNoiseLite resource to each noise export in the Inspector.

# --- Noise ---

## Large-scale hills shape (low frequency, high amplitude)
@export var hills_noise: FastNoiseLite
## Small bumps and surface variation (high frequency, low amplitude)
@export var detail_noise: FastNoiseLite

# --- Height settings ---

@export_group("Height")
## Overall height multiplier (world units)
@export var height_scale: float = 6.0
## How much the detail layer contributes relative to hills (0–1)
@export var detail_strength: float = 0.15

# --- Grass settings ---

@export_group("Grass")
## Enable grass spawning
@export var grass_enabled: bool = true
## Grass blade candidates per square world unit.
## SimplePCGTerrain multiplies this by chunk area to get total candidates.
## Not all candidates spawn — get_grass() filters by height/tile/curve.
## Example: 0.5 = ~1 blade per 2 m²,  2.0 = ~2 blades per m²
@export var grass_density_per_unit: float = 0.5
## Random Y-axis rotation range in degrees
@export var grass_rotation_spread: float = 360.0
## Random scale variation (0 = uniform, 0.3 = ±30%)
@export var grass_scale_variation: float = 0.3
## Minimum terrain height (world units) at which grass spawns
@export var grass_min_height: float = -100.0
## Maximum terrain height (world units) at which grass spawns
@export var grass_max_height: float = 100.0
## Spawn probability mapped over normalised height (left=min, right=max).
## Flat line at 1.0 = uniform density everywhere within height range.
@export var grass_density_curve: Curve

const TILE_GRASS := 0
const TILE_GRASS_TO_ROCK := 1
const TILE_ROCK := 2
const TILE_DIRT := 3
const TILE_DIRT_TO_GRASS := 4
const TILE_PATH := 5
const TILE_PATH_TO_GRASS := 6
const TILE_PATH_TO_DIRT := 7


func _ready() -> void:
	randomize_terrain()


## Re-seed all noise layers with a new random seed.
func randomize_terrain() -> void:
	var base_seed := randi()
	if hills_noise:  hills_noise.seed  = base_seed
	if detail_noise: detail_noise.seed = base_seed + 1


## Always returns grass tile.
func get_value(_pos: Vector2) -> int:
	return TILE_GRASS


## Returns terrain height at the given 2D world position.
## Combines large hills with fine surface detail.
func get_height(pos: Vector2) -> float:
	var h: float = hills_noise.get_noise_2dv(pos) if hills_noise else 0.0
	h *= height_scale
	if detail_noise:
		h += detail_noise.get_noise_2dv(pos) * detail_strength

	return h


## Returns grass spawn parameters for a given position.
## Called by SimplePCGTerrain for each candidate grass blade.
##
## Parameters:
##   pos    — grid-space 2D position
##   tile   — tile index at this position (from get_value)
##   height — world-space height at this position (from get_height * cell_size)
##
## Returns grass spawn parameters for a given position.
##
## Parameters:
##   pos        — grid-space 2D position
##   tile       — tile index at this position (from get_value)
##   height     — world-space height (from get_height * cell_size)
##   rand_value — caller-supplied random float in [0, 1] for density curve check
##                (avoids calling randf() from a background thread)
##
## Returns a Dictionary:
##   { "spawn":    bool  — whether to place a blade here
##     "scale":    float — base scale multiplier (1.0 = normal)
##     "rotation": float — Y rotation in radians, or -1 to use random }
func get_grass(pos: Vector2, tile: int, height: float, rand_value: float = 0.0) -> Dictionary:
	var result := {"spawn": false, "scale": 1.0, "rotation": -1.0}

	if not grass_enabled:
		return result

	# Height filter
	if height < grass_min_height or height > grass_max_height:
		return result

	# Normalised height in [0, 1] — reused for curve and scale
	var height_range: float = grass_max_height - grass_min_height
	var height_t: float = clampf(
		(height - grass_min_height) / max(height_range, 0.0001), 0.0, 1.0
	)

	# Optional density curve: maps normalised height to spawn probability.
	# Uses caller-supplied rand_value to stay thread-safe.
	if grass_density_curve:
		if rand_value > grass_density_curve.sample(height_t):
			return result

	result["spawn"] = true

	# Slightly smaller blades at higher elevations
	result["scale"] = lerpf(1.2, 0.7, height_t)

	return result


# --- Input: press Enter to regenerate ---

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey \
	and event.keycode == KEY_ENTER \
	and event.pressed \
	and not event.echo:
		randomize_terrain()
		var terrain := get_node_or_null("../SimplePCGTerrain") as SimplePCGTerrain
		if terrain:
			terrain.clean()
