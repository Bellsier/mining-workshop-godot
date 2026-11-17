extends Area2D
## A walk-in door: when the player enters this area, go to target_scene and appear at target_spawn there.
## Move the node (and its CollisionShape2D) in the 2D editor to move the entrance.

@export_file("*.tscn") var target_scene := ""
@export var target_spawn := "Start"

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node) -> void:
	if body is CharacterBody2D and target_scene != "":
		get_node("/root/Game").go(target_scene, target_spawn)
