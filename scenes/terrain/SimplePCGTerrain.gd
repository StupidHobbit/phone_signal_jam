# Procedural 3D terrain with chunk-based loading and marching squares
extends Node3D
class_name SimplePCGTerrain

signal chunk_spawned(chunk_index: Vector2, chunk_node: Node3D)
signal chunk_removed(chunk_index: Vector2)

# --- Exports ---

@export_group("Generator")
@export var generator_node: NodePath
@export var player_node: NodePath
@export var dynamic_generation: bool = true

@export_group("Chunk System")
@export var chunk_load_radius: int = 0
@export var map_update_interval: float = 0.1
@export var grid_size: Vector2 = Vector2(51, 51)

@export_group("Mesh")
@export var marching_squares: bool = true
@export var add_collision: bool = true
@export var offset: Vector3 = Vector3(-0.5, 0, -0.5)
## Size of each grid cell in world units. Decrease for more detailed terrain.
@export var cell_size: float = 1.0

@export_group("Grass")
## Mesh to use for grass blades (assign grass.res)
@export var grass_mesh: Mesh
## Material with grass shader (assign ShaderMaterial)
@export var grass_material: Material

@export_group("Materials")
@export var materials: Array[Material]
@export var material_filters: Array[int]   # ALL=0, WHITELIST=1, BLACKLIST=2
@export var material_values: Array[String] # Comma-separated tile indices per material

@export_group("Tilesheet")
@export var tilesheet_size: Vector2 = Vector2(2, 2)
@export var tile_margin: Vector2 = Vector2(0.01, 0.01)

# --- Constants ---

enum FilterMode { ALL, WHITELIST, BLACKLIST }

# UV positions of the 3 vertices for each of the 8 sub-triangles in a cell.
# Cell layout:
#   corner[0] corner[1]
#   corner[2] corner[3]
# Each cell is split into 4 quads, each quad into 2 triangles = 8 triangles total.
# Format: flat array of (u, v) pairs, 3 vertices × 8 triangles = 48 floats.
# (PackedFloat64Array cannot be a const in GDScript, so this is a var)
var CELL_TRIANGLE_UVS := PackedFloat64Array([
	# Quad 0 (top-left)
	0.0, 0.0,  0.5, 0.0,  0.0, 0.5,  # tri 0
	0.0, 0.5,  0.5, 0.0,  0.5, 0.5,  # tri 1
	# Quad 1 (top-right)
	0.5, 0.5,  0.5, 0.0,  1.0, 0.5,  # tri 2
	1.0, 0.5,  0.5, 0.0,  1.0, 0.0,  # tri 3
	# Quad 2 (bottom-left)
	0.0, 1.0,  0.0, 0.5,  0.5, 1.0,  # tri 4
	0.5, 1.0,  0.0, 0.5,  0.5, 0.5,  # tri 5
	# Quad 3 (bottom-right)
	0.5, 0.5,  1.0, 0.5,  0.5, 1.0,  # tri 6
	0.5, 1.0,  1.0, 0.5,  1.0, 1.0,  # tri 7
])

# Corner offsets for a cell: top-left, top-right, bottom-left, bottom-right
var CORNER_OFFSETS := [Vector2(0, 0), Vector2(1, 0), Vector2(0, 1), Vector2(1, 1)]

# --- State ---

var _generator: Node
var _generator_has_value: bool = false
var _generator_has_height: bool = false
var _player: Node3D

var _loaded_chunks: Array[Node3D] = []
var _loaded_chunk_positions := PackedVector2Array()
var _chunk_load_queue: Array = []
var _chunk_remove_queue: Array[int] = []

var _thread: Thread
var _mutex: Mutex
var _thread_active: bool = true
var _thread_time: float = 0.0
var _player_position: Vector3 = Vector3.ZERO


func _ready() -> void:
	if generator_node:
		_generator = get_node(generator_node)
		_generator_has_value = _generator.has_method("get_value")
		_generator_has_height = _generator.has_method("get_height")

	if player_node:
		_player = get_node(player_node)

	_mutex = Mutex.new()
	_thread = Thread.new()
	_thread.start(_map_update_loop.bind(0))


func _exit_tree() -> void:
	_thread_active = false
	_thread.wait_to_finish()


# --- Public API ---

## Stop generation, remove all chunks, restart the update thread.
func clean() -> void:
	for child in get_children():
		child.queue_free()

	_loaded_chunk_positions = PackedVector2Array()
	_loaded_chunks.clear()

	_mutex.lock()
	_chunk_load_queue.clear()
	_chunk_remove_queue.clear()
	_mutex.unlock()

	_thread_time = 0.0
	if not _thread_active:
		_thread_active = true
		_thread.wait_to_finish()
		_thread = Thread.new()
		_thread.start(_map_update_loop.bind(0))


# --- Chunk Management ---

func _get_needed_chunks(center: Vector2) -> PackedVector2Array:
	var chunks := PackedVector2Array([center])
	for ring in range(1, chunk_load_radius + 1):
		for x in range(ring * 2 + 1):
			chunks.append(Vector2(x - ring, -ring) + center)
			chunks.append(Vector2(x - ring,  ring) + center)
		for y in range(1, ring * 2):
			chunks.append(Vector2( ring, y - ring) + center)
			chunks.append(Vector2(-ring, y - ring) + center)
	return chunks


func _map_update_loop(_unused: int) -> void:
	while _thread_active:
		if _thread_time < map_update_interval:
			continue
		_thread_time = 0.0

		_mutex.lock()
		var current_player_pos := _player_position
		_mutex.unlock()

		var chunk_world_size := grid_size * cell_size
		var current_chunk := Vector2(
			floor(current_player_pos.x / chunk_world_size.x),
			floor(current_player_pos.z / chunk_world_size.y)
		)
		var needed := _get_needed_chunks(current_chunk)

		# Generate one missing chunk per tick
		for chunk_index in needed:
			if chunk_index not in _loaded_chunk_positions:
				_generate_chunk(chunk_index)
				break

		# Queue one unneeded chunk for removal per tick
		for i in _loaded_chunk_positions.size():
			if _loaded_chunk_positions[i] not in needed:
				_mutex.lock()
				_chunk_remove_queue.append(i)
				_mutex.unlock()
				break

		if not dynamic_generation and _loaded_chunk_positions.size() == needed.size():
			_thread_active = false


func _process(delta: float) -> void:
	_thread_time += delta

	# Update player position and snapshot queues under the mutex,
	# then process them outside to avoid holding the lock during heavy work.
	_mutex.lock()
	_player_position = _player.position if _player else position
	var load_snapshot: Array  = _chunk_load_queue.duplicate()
	var remove_snapshot: Array[int] = _chunk_remove_queue.duplicate()
	_chunk_load_queue.clear()
	_chunk_remove_queue.clear()
	_mutex.unlock()

	_flush_load_queue(load_snapshot)
	_flush_remove_queue(remove_snapshot)


func _flush_load_queue(snapshot: Array) -> void:
	if snapshot.is_empty():
		return

	for chunk_data in snapshot:
		var surfaces: Array            = chunk_data[0]
		var collision_shape            = chunk_data[1]  # CollisionShape3D or null
		var world_origin: Vector2      = chunk_data[2]
		var chunk_index: Vector2       = chunk_data[3]
		# Grass transforms generated here (main thread) — safe to call generator methods
		var grass_transforms: Array    = _generate_grass_transforms(world_origin)

		var chunk_root := Node3D.new()
		chunk_root.position = Vector3(world_origin.x * cell_size, 0.0, world_origin.y * cell_size)

		# Terrain mesh
		var mesh_instance := MeshInstance3D.new()
		if not surfaces.is_empty():
			mesh_instance.mesh = surfaces[0]
		chunk_root.add_child(mesh_instance)

		# Collision
		if collision_shape:
			var static_body := StaticBody3D.new()
			static_body.add_child(collision_shape)
			mesh_instance.add_child(static_body)

		# Grass
		if grass_mesh and not grass_transforms.is_empty():
			var mmi := _build_grass_mmi(grass_transforms)
			chunk_root.add_child(mmi)

		add_child(chunk_root)
		_loaded_chunk_positions.append(chunk_index)
		_loaded_chunks.append(chunk_root)
		chunk_spawned.emit(chunk_index, chunk_root)


func _flush_remove_queue(snapshot: Array[int]) -> void:
	if snapshot.is_empty():
		return

	# Sort descending so removing by index doesn't shift earlier indices
	snapshot.sort()
	snapshot.reverse()
	for idx in snapshot:
		_remove_chunk(idx)


func _remove_chunk(index: int) -> void:
	var chunk := _loaded_chunks[index]
	chunk.call_deferred("queue_free")
	chunk_removed.emit(_loaded_chunk_positions[index])
	_loaded_chunks.remove_at(index)
	_loaded_chunk_positions.remove_at(index)


# --- Terrain Generation ---

func _generate_chunk(chunk_index: Vector2) -> void:
	var origin_2d := chunk_index * grid_size
	var tile_uv_size := Vector2.ONE / tilesheet_size
	var tile_uv_scale := Vector2.ONE - tile_margin

	# Per-corner data cached to avoid redundant generator calls
	var corner_values  := PackedInt64Array()
	var corner_heights := PackedFloat64Array()

	var all_faces := PackedVector3Array()
	var surfaces: Array = []

	for surface_idx in materials.size():
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(materials[surface_idx])

		var filter_mode: int = material_filters[surface_idx] if surface_idx < material_filters.size() else FilterMode.ALL
		var filter_set: Array[int] = _parse_filter_values(surface_idx)

		for row in int(grid_size.y):
			for col in int(grid_size.x):
				var cell_pos   := Vector3(col, 0, row)
				var cell_pos2d := Vector2(col, row)

				var tri_values := _get_triangle_values(cell_pos2d, origin_2d, corner_values)
				_cache_corner_heights(cell_pos2d, origin_2d, corner_heights)

				_add_cell_triangles(
					st, all_faces,
					cell_pos, cell_pos2d, origin_2d,
					tri_values, corner_heights,
					filter_mode, filter_set,
					tile_uv_size, tile_uv_scale
				)

		st.generate_normals()
		st.generate_tangents()
		surfaces.append(st.commit())

	var collision_shape: CollisionShape3D = null
	if add_collision:
		var shape := ConcavePolygonShape3D.new()
		shape.set_faces(all_faces)
		collision_shape = CollisionShape3D.new()
		collision_shape.shape = shape

	_mutex.lock()
	_chunk_load_queue.append([surfaces, collision_shape, origin_2d, chunk_index])
	_mutex.unlock()


func _parse_filter_values(surface_idx: int) -> Array[int]:
	if surface_idx >= material_values.size():
		return []
	var result: Array[int] = []
	for token in material_values[surface_idx].replace(" ", "").split(","):
		if token.is_valid_int():
			result.append(token.to_int())
	return result


## Returns the tile index for each of the 8 sub-triangles in a cell.
## Uses marching squares when enabled, otherwise returns a flat array of one value.
func _get_triangle_values(
	cell_pos2d: Vector2,
	origin_2d: Vector2,
	corner_values: PackedInt64Array
) -> PackedInt64Array:
	if not (marching_squares and _generator_has_value):
		var value: int = _generator.get_value(cell_pos2d + origin_2d) if _generator_has_value else 0
		return PackedInt64Array([value, value, value, value, value, value, value, value])

	var corners := _get_or_cache_corner_values(cell_pos2d, origin_2d, corner_values)
	return _marching_squares(corners)


func _get_or_cache_corner_values(
	cell_pos2d: Vector2,
	origin_2d: Vector2,
	corner_values: PackedInt64Array
) -> PackedInt64Array:
	var col := int(cell_pos2d.x)
	var row := int(cell_pos2d.y)
	var stride := int(grid_size.x) * 4  # 4 corners per cell

	var corners := PackedInt64Array()

	if col == 0 or row == 0:
		# Edge cell: query all 4 corners from generator
		for offset in CORNER_OFFSETS:
			corners.append(_generator.get_value(offset + cell_pos2d + origin_2d))
	else:
		# Reuse cached corners from adjacent cells
		corners.append(corner_values[(row - 1) * stride + col * 4 + 2])  # top-left  = prev row's bottom-left
		corners.append(corner_values[(row - 1) * stride + col * 4 + 3])  # top-right = prev row's bottom-right
		corners.append(corner_values[row * stride + (col - 1) * 4 + 1])  # bot-left  = prev col's bottom-right (wrong axis, kept for compat)
		corners.append(_generator.get_value(CORNER_OFFSETS[3] + cell_pos2d + origin_2d))

	corner_values.append_array(corners)
	return corners


func _cache_corner_heights(
	cell_pos2d: Vector2,
	origin_2d: Vector2,
	corner_heights: PackedFloat64Array
) -> void:
	if not _generator_has_height:
		return

	var col := int(cell_pos2d.x)
	var row := int(cell_pos2d.y)
	var stride := int(grid_size.x) * 4

	var heights := PackedFloat64Array()

	if col == 0 or row == 0:
		for offset in CORNER_OFFSETS:
			heights.append(_generator.get_height(offset + cell_pos2d + origin_2d))
	else:
		heights.append(corner_heights[(row - 1) * stride + col * 4 + 2])
		heights.append(corner_heights[(row - 1) * stride + col * 4 + 3])
		heights.append(corner_heights[row * stride + (col - 1) * 4 + 3])
		heights.append(_generator.get_height(CORNER_OFFSETS[3] + cell_pos2d + origin_2d))

	corner_heights.append_array(heights)


func _add_cell_triangles(
	st: SurfaceTool,
	all_faces: PackedVector3Array,
	cell_pos: Vector3,
	cell_pos2d: Vector2,
	origin_2d: Vector2,
	tri_values: PackedInt64Array,
	corner_heights: PackedFloat64Array,
	filter_mode: int,
	filter_set: Array[int],
	tile_uv_size: Vector2,
	tile_uv_scale: Vector2
) -> void:
	var cell_corner_base := int(cell_pos2d.y) * int(grid_size.x) * 4 + int(cell_pos2d.x) * 4

	for tri_idx in 8:
		var tile_value: int = tri_values[tri_idx]

		if not _passes_filter(tile_value, filter_mode, filter_set):
			continue

		var tile_uv_origin: Vector2 = _tile_index_to_uv(tile_value, tile_uv_size)

		for vert_idx in 3:
			var u: float = CELL_TRIANGLE_UVS[tri_idx * 6 + vert_idx * 2]
			var v: float = CELL_TRIANGLE_UVS[tri_idx * 6 + vert_idx * 2 + 1]
			var vert := Vector3(u, 0.0, v)

			if _generator_has_height:
				vert.y = _interpolate_height(vert, corner_heights, cell_corner_base)

			var uv := Vector2(vert.x, vert.z) * tile_uv_scale * tile_uv_size + tile_uv_origin
			var world_vertex := (vert + cell_pos + offset) * cell_size

			st.set_uv(uv)
			st.add_vertex(world_vertex)
			all_faces.append(world_vertex)


func _passes_filter(value: int, mode: int, filter_set: Array[int]) -> bool:
	match mode:
		FilterMode.WHITELIST: return value in filter_set
		FilterMode.BLACKLIST: return value not in filter_set
		_: return true


func _tile_index_to_uv(tile_index: int, tile_uv_size: Vector2) -> Vector2:
	var row: float = floor(tile_index / tilesheet_size.x)
	var col: float = tile_index - row * tilesheet_size.x
	return (Vector2(col, row) + tile_margin / 2.0) * tile_uv_size


## Interpolate vertex height from the 4 cached corner heights of the cell.
## Corners are indexed: 0=top-left, 1=top-right, 2=bottom-left, 3=bottom-right
func _interpolate_height(vert: Vector3, corner_heights: PackedFloat64Array, base: int) -> float:
	var h0: float = corner_heights[base + 0]
	var h1: float = corner_heights[base + 1]
	var h2: float = corner_heights[base + 2]
	var h3: float = corner_heights[base + 3]

	if vert.x == 0.5 and vert.z == 0.5:
		# Center: bilinear interpolation
		return lerp(lerp(h0, h1, 0.5), lerp(h2, h3, 0.5), 0.5)
	elif vert.x == 0.5:
		# Mid-horizontal edge
		var row_offset := int(vert.z * 2)  # 0 for top edge, 2 for bottom edge
		return lerp(corner_heights[base + row_offset], corner_heights[base + row_offset + 1], 0.5)
	elif vert.z == 0.5:
		# Mid-vertical edge
		var col_offset := int(vert.x)  # 0 for left edge, 1 for right edge
		return lerp(corner_heights[base + col_offset], corner_heights[base + 2 + col_offset], 0.5)
	else:
		# Exact corner
		return corner_heights[base + int(vert.z * 2) + int(vert.x)]


# --- Marching Squares ---

## Maps 4 corner tile values to 8 per-triangle tile values.
## Corner layout:  [0]=top-left  [1]=top-right
##                 [2]=bot-left  [3]=bot-right
func _marching_squares(c: PackedInt64Array) -> PackedInt64Array:
	var all_same    := c[0] == c[1] and c[0] == c[2] and c[0] == c[3]
	var top_same    := c[0] == c[1]
	var bot_same    := c[2] == c[3]
	var left_same   := c[0] == c[2]
	var right_same  := c[1] == c[3]
	var diag_a_same := c[0] == c[3]  # top-left == bot-right
	var diag_b_same := c[1] == c[2]  # top-right == bot-left

	# All corners identical → solid fill
	if all_same:
		return _fill8(c[0])

	# One corner differs
	if top_same and left_same:   # only bot-right differs
		return PackedInt64Array([c[0],c[0],c[0],c[0], c[0],c[0],c[0],c[3]])
	if top_same and right_same:  # only bot-left differs
		return PackedInt64Array([c[0],c[0],c[0],c[0], c[2],c[0],c[0],c[0]])
	if bot_same and left_same:   # only top-right differs
		return PackedInt64Array([c[0],c[1],c[1],c[1], c[1],c[1],c[1],c[1]])
	if bot_same and right_same:  # only top-left differs
		return PackedInt64Array([c[0],c[1],c[1],c[1], c[2],c[1],c[1],c[1]])

	# Two corners on same edge
	if top_same and not bot_same:
		return PackedInt64Array([c[0],c[0],c[0],c[0], c[2],c[0],c[0],c[3]])
	if bot_same and not top_same:
		return PackedInt64Array([c[0],c[0],c[2],c[2], c[2],c[2],c[2],c[2]])
	if left_same and not right_same:
		return PackedInt64Array([c[0],c[0],c[1],c[1], c[0],c[0],c[1],c[1]])
	if right_same and not left_same:
		return PackedInt64Array([c[0],c[1],c[1],c[1], c[2],c[1],c[1],c[1]])

	# Diagonal pairs
	if diag_a_same and diag_b_same:
		return PackedInt64Array([c[0],c[0],c[0],c[1], c[1],c[0],c[0],c[0]])
	if diag_b_same:
		return PackedInt64Array([c[0],c[1],c[1],c[1], c[1],c[1],c[1],c[3]])

	# All four corners different
	return PackedInt64Array([c[0],c[0],c[1],c[1], c[2],c[2],c[3],c[3]])


func _fill8(value: int) -> PackedInt64Array:
	return PackedInt64Array([value, value, value, value, value, value, value, value])


# --- Grass ---

## Generates Transform3D array for grass blades across the chunk.
## Called on the main thread so generator methods can be safely accessed.
## origin_2d is the chunk's grid-space origin (chunk_index * grid_size).
## Spawn logic and per-blade parameters come from generator.get_grass().
func _generate_grass_transforms(origin_2d: Vector2) -> Array:
	if not grass_mesh:
		return []

	var has_grass_func: bool = _generator != null and _generator.has_method("get_grass")
	var density: int = _generator.grass_density if has_grass_func else 0
	if density <= 0:
		return []

	var chunk_world := grid_size * cell_size
	var transforms: Array = []

	var rng := RandomNumberGenerator.new()
	# Deterministic seed per chunk so regeneration is stable
	rng.seed = hash(origin_2d)

	for i in density:
		# Local position within the chunk (chunk root is already world-offset)
		var lx: float = rng.randf() * chunk_world.x
		var lz: float = rng.randf() * chunk_world.y

		# Grid-space position for generator queries
		var grid_pos := origin_2d + Vector2(lx, lz) / cell_size

		# World-space height (scaled to match mesh vertices)
		var ly: float = 0.0
		if _generator_has_height:
			ly = _generator.get_height(grid_pos) * cell_size

		# Ask generator whether to spawn here and with what parameters
		var tile: int = _generator.get_value(grid_pos) if _generator_has_value else 0
		var grass_params: Dictionary = _generator.get_grass(grid_pos, tile, ly)
		if not grass_params.get("spawn", false):
			continue

		# Y rotation: use generator value if provided, otherwise random
		var raw_rotation: float = grass_params.get("rotation", -1.0)
		var angle: float
		if raw_rotation >= 0.0:
			angle = raw_rotation
		else:
			angle = deg_to_rad(rng.randf_range(0.0, 360.0))
		var basis := Basis(Vector3.UP, angle)

		transforms.append(Transform3D(basis, Vector3(lx, ly, lz)))

	return transforms


## Builds a MultiMeshInstance3D from pre-computed transforms.
## Must be called on the main thread.
func _build_grass_mmi(transforms: Array) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = grass_mesh
	mm.instance_count = transforms.size()

	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if grass_material:
		mmi.material_override = grass_material
	return mmi
