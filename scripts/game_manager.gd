extends Node

# ============================================================================
# GameManager — game-wide state holder. No transform, no render, no physics.
# Currently tracks lap timing; will grow to own race state, win conditions,
# pause, etc. as the project develops.
#
# Communication pattern: other nodes push events here via signals (the
# StartFinishLine's body_entered → on_line_crossed). The HUD pulls state
# each frame via a reference to this node.
# ============================================================================


# --- Lap state --------------------------------------------------------------

## Number of completed laps. Starts at 0; bumps each start-line crossing.
var lap_count: int = 0

## Time accumulated since the last crossing (or game start, for the first
## lap). Reset to 0 on each crossing.
var current_lap_time: float = 0.0

## Total time since the beginning.
var total_time: float = 0.0

## Fastest lap time so far. -1.0 means no lap has been completed yet —
## format_time renders that as the "--:--.---" placeholder.
var best_lap_time: float = -1.0

## The start/finish line whose body_entered we listen to. Drag the
## StartFinishLine node into this slot in the Inspector.
@export var start_line: Area2D

## Container holding all Checkpoint instances. Order in the scene tree
## determines the order they must be crossed in for a valid lap.
@export var checkpoints_container: Node2D

## Marker for where the car spawns/resets to — placed behind the start line.
## Drag the spawn Marker2D into this slot in the Inspector.
@export var spawn_marker: Marker2D

# Built in _ready from checkpoints_container's children; never mutated after.
var _checkpoints: Array[Area2D] = []
# Index of the next checkpoint that must be crossed for the current lap to
# remain valid. Starts at 0, advances on each in-order crossing, resets to
# 0 after a valid start-line crossing.
var _next_required_checkpoint: int = 0

func _ready() -> void:
	EventBus.race_reset.connect(_reset)
	if start_line:
		start_line.body_entered.connect(on_line_crossed)
		
	if checkpoints_container:
		for child in checkpoints_container.get_children():
			if child.has_signal("crossed"):
				_checkpoints.append(child)
				child.crossed.connect(_on_checkpoint_crossed)
	EventBus.race_reset.emit(spawn_marker.global_transform)
	
func _process(delta: float) -> void:
	current_lap_time += delta
	total_time += delta

# ============================================================================
# Called by the start/finish line's body_entered signal. No direction
# validation in this version — any crossing counts as a lap. Checkpoint
# ordering arrives in sub-step 15b.
# ============================================================================
func on_line_crossed(_body: Node2D) -> void:
	# Reject the crossing if the car hasn't passed every checkpoint in order
	# since the previous valid lap (or since game start for the first lap).
	if _next_required_checkpoint != _checkpoints.size():
		return

	var finished_time := current_lap_time
	if best_lap_time < 0.0 or finished_time < best_lap_time:
		best_lap_time = finished_time
	lap_count += 1
	current_lap_time = 0.0
	_next_required_checkpoint = 0

# ============================================================================
# Called by each Checkpoint's `crossed` signal. Only advances the required
# index if the checkpoint matches what's next — out-of-order or repeated
# crossings are silently ignored, which is what gives us reverse-protection
# and skip-protection for free.
# ============================================================================
func _on_checkpoint_crossed(checkpoint: Area2D) -> void:
	var idx := _checkpoints.find(checkpoint)
	if idx == _next_required_checkpoint:
		_next_required_checkpoint += 1

func _reset(_spawn_transform: Transform2D) -> void:
	lap_count = 0
	current_lap_time = 0.0
	total_time = 0.0
	best_lap_time = -1.0
	_next_required_checkpoint = 0

# ============================================================================
# Input handling — _unhandled_input fires only when a UI element didn't
# consume the event, which is exactly what we want for a global debug
# toggle. is_action_pressed (on the event, not the polled version) fires
# once per key press.
# ============================================================================
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("reset"):
		EventBus.race_reset.emit(spawn_marker.global_transform)
		
# ============================================================================
# Format a duration (seconds) as "m:ss.mmm". Negative input → placeholder,
# so callers can pass best_lap_time directly without a null check.
# ============================================================================
static func format_time(seconds: float) -> String:
	if seconds < 0.0:
		return "--:--.---"
	var minutes := int(seconds) / 60
	var secs := int(seconds) % 60
	var ms := int((seconds - int(seconds)) * 1000)
	return "%d:%02d.%03d" % [minutes, secs, ms]
