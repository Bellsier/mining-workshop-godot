extends Area2D
## The door in the middle of the tunnel passage. The stage-1 tunnel scene stands for the inside of the
## passage, so walking in westward continues at its east end, walking in eastward at its west end.

@export_file("*.tscn") var tunnel_scene := "res://scenes/tunnel.tscn"
@export var spawn_heading_west := "FromOutside"
@export var spawn_heading_east := "FromBeyond"

func _ready() -> void:
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node) -> void:
	if not body is CharacterBody2D:
		return
	var heading_west: bool = (body as CharacterBody2D).velocity.x < 0.0
	get_node("/root/Game").go(tunnel_scene, spawn_heading_west if heading_west else spawn_heading_east)
