extends Camera2D

# ============================================================================
# Follow camera — keeps its global position locked to a target Node2D every
# frame. Sibling-of-target architecture: the camera isn't parented to what it
# follows, just watches it. Gives us a clean hook to add smoothing,
# look-ahead, or screen shake later without coupling to the target's
# transform.
# ============================================================================

## Node the camera should follow. Drag the player Car into this slot in the
## Inspector after attaching the script.
@export var target: RigidBody2D


func _process(_delta: float) -> void:
	if target:
		global_position = target.global_position
