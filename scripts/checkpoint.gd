extends Area2D

# ============================================================================
# Checkpoint — emits a `crossed` signal carrying itself when a body enters.
# The GameManager enumerates checkpoints (via the parent container) and
# subscribes to each one's `crossed` signal. Index is implicit: position in
# the parent's child list.
#
# Per-checkpoint script (rather than the GameManager handling body_entered
# directly) keeps each checkpoint self-contained — adding new ones is just
# instancing the scene.
# ============================================================================

signal crossed(checkpoint: Area2D)


func _ready() -> void:
	body_entered.connect(_on_body_entered)


func _on_body_entered(_body: Node2D) -> void:
	crossed.emit(self)
