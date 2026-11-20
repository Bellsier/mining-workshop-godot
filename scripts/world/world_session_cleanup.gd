extends Node
## Lives under the root while a world is current. When the game quits, it drops the shared world before the
## engine shuts down (an Object left in Engine meta would be freed after the object database is gone).

func _exit_tree() -> void:
	if Engine.has_meta("mining_world_state"):
		Engine.remove_meta("mining_world_state")
