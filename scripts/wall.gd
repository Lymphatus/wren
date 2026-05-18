@tool
extends StaticBody2D

@export var size: Vector2 = Vector2(20, 200) :
	set(value):
		size = value
		_apply_size()

func _ready() -> void:
	_apply_size()

func _apply_size() -> void:
	if not is_inside_tree():
		return
	var col := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if col:
		var new_shape := RectangleShape2D.new()
		new_shape.size = size
		col.shape = new_shape
	var rect := get_node_or_null("ColorRect") as ColorRect
	if rect:
		rect.size = size
		rect.position = -size / 2.0
