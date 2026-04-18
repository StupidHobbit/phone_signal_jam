extends Node3D

@onready var grass: MultiMeshInstance3D = $Grass

func _ready() -> void:
	GameManager.reset()
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
