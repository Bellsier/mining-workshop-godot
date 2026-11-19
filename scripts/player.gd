extends CharacterBody2D
## Four-direction walk. Keyboard (WASD / arrows) and the touch stick both feed the move_* input actions.

## web BALANCE.world.PLAYER_SPEED: 3 world units (64 px each) per second.
@export var speed := 192.0
var facing := "down"
@onready var sprite: AnimatedSprite2D = $Sprite

func _physics_process(_delta: float) -> void:
	var game := get_node("/root/Game")
	var dir := Vector2.ZERO if game.world_input_blocked() else Input.get_vector("move_left", "move_right", "move_up", "move_down")
	velocity = dir * speed
	move_and_slide()
	if dir.length() > 0.01:
		# Four directions: the larger axis decides which way the character faces.
		if absf(dir.x) > absf(dir.y):
			facing = "right" if dir.x > 0 else "left"
		else:
			facing = "down" if dir.y > 0 else "up"
		sprite.play("walk_" + facing)
	else:
		sprite.play("idle_" + facing)
	if get_tree().current_scene != null:
		game.report(get_tree().current_scene.name, global_position, facing)
