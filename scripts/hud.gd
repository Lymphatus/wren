extends CanvasLayer

# ============================================================================
# HUD — always-visible speed readout plus a toggleable debug panel.
# Press the toggle_debug action (F3 by default) to show/hide telemetry.
# ============================================================================

## The player car. Drag the Car node into this slot in the Inspector.
@export var car: RigidBody2D

# Always-visible.
@onready var speed_label: Label = $SpeedLabel

# Debug panel + its individual lines. The panel toggles visibility on F3;
# the lines update every frame while the panel is visible.
@onready var debug_panel: Control = $DebugPanel
@onready var debug_speed: Label = $DebugPanel/Lines/Speed
@onready var debug_forward: Label = $DebugPanel/Lines/Forward
@onready var debug_lateral: Label = $DebugPanel/Lines/Lateral
@onready var debug_grip: Label = $DebugPanel/Lines/Grip
@onready var debug_drag: Label = $DebugPanel/Lines/Drag
@onready var debug_surfaces: Label = $DebugPanel/Lines/Surfaces


func _process(_delta: float) -> void:
	if not car:
		return

	# Always-visible: cosmetic km/h reading.
	var speed := car.linear_velocity.length()
	speed_label.text = "Speed: %.0f km/h" % (speed / 2.0)

	# Skip the rest if the debug panel is hidden — no point updating
	# labels nobody can see.
	if debug_panel.visible:
		_update_debug()


# ============================================================================
# Telemetry update — runs only when the debug panel is visible.
# Pulls live values straight off the car's exposed state.
# ============================================================================
func _update_debug() -> void:
	var v := car.linear_velocity
	# Dot-product the velocity with the car's local axes to split it into
	# the same forward/lateral components the physics math uses.
	var forward_speed := v.dot(car.transform.x)
	var lateral_speed := v.dot(car.transform.y)

	debug_speed.text     = "speed:    %6.1f" % v.length()
	debug_forward.text   = "forward:  %6.1f" % forward_speed
	debug_lateral.text   = "lateral:  %6.1f" % lateral_speed
	debug_grip.text      = "grip:      %5.2f" % car.effective_grip
	debug_drag.text      = "drag:      %5.2f" % car.effective_drag
	debug_surfaces.text  = "surfaces:    %d"  % car.current_surfaces.size()


# ============================================================================
# Input handling — _unhandled_input fires only when a UI element didn't
# consume the event, which is exactly what we want for a global debug
# toggle. is_action_pressed (on the event, not the polled version) fires
# once per key press.
# ============================================================================
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug"):
		debug_panel.visible = not debug_panel.visible
