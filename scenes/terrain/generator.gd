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

# Single tile index — grass
const TILE_GRASS := 0


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
