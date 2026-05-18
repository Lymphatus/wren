@tool
extends Area2D

@export var size: Vector2 = Vector2(200, 200) :
	set(value):
		size = value
		_apply_size()

@export var color: Color = Color(0.4, 0.5, 0.9, 0.5) :
	set(value):
		color = value
		_apply_color()

@export_range(0.0, 1.0, 0.05) var grip: float = 0.3
@export_range(0.0, 10.0, 0.1) var drag: float = 0.0

func _ready() -> void:
	_apply_size()
	_apply_color()
	if Engine.is_editor_hint():
		return
	body_entered.connect(_on_body_entered)
	body_exited.connect(_on_body_exited)

func _on_body_entered(body: Node) -> void:
	if body.has_method("_on_surface_entered"):
		body._on_surface_entered(self)

func _on_body_exited(body: Node) -> void:
	if body.has_method("_on_surface_exited"):
		body._on_surface_exited(self)

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

func _apply_color() -> void:
	if not is_inside_tree():
		return
	var rect := get_node_or_null("ColorRect") as ColorRect
	if rect:
		rect.color = color
