extends RigidBody2D

# ============================================================================
# Player car — hybrid physics top-down arcade racer.
#
# Approach: RigidBody2D handles collisions (walls, other cars). The script
# overrides velocity every physics tick inside _integrate_forces to produce
# car-like handling, which is the only safe place to write to
# state.linear_velocity / state.angular_velocity without fighting the solver.
#
# Order of operations each tick (see _integrate_forces):
#   1. Throttle — add forward thrust based on input.
#   2. Surface effects — smooth-lerp effective_grip / effective_drag toward
#      values implied by the surfaces we're currently overlapping.
#   3. Friction — split velocity into forward/lateral, slow forward by drag,
#      kill some lateral by grip, recombine.
#   4. Speed clamp — enforce max_speed.
#   5. Steering — set angular velocity, scaled by current speed.
# ============================================================================


# --- Engine -----------------------------------------------------------------
@export_group("Engine")
## How quickly the car gains forward speed when accelerating. Pixels/sec².
@export var acceleration: float = 800.0
## Hard cap on total speed. Pixels/sec.
@export var max_speed: float = 400.0


# --- Steering ---------------------------------------------------------------
@export_group("Steering")
## Maximum rotation rate, in radians/sec. ~3.0 ≈ a half-turn per second.
@export var steering_speed: float = 3.0
## Fraction of max_speed at which steering reaches full effectiveness.
## Below this the car turns less; at/above this it turns at full rate.
## Lower = snappier handling at low speed; higher = sluggish until fast.
@export_range(0.05, 1.0, 0.05) var steering_full_speed_factor: float = 0.5


# --- Handling ---------------------------------------------------------------
@export_group("Handling")
## Baseline lateral friction. 1.0 = on rails, 0.0 = pure ice.
## Surfaces under the car can lower this; the lowest value wins.
@export_range(0.0, 1.0, 0.05) var grip: float = 0.9


# --- Surface transition smoothing -------------------------------------------
# Higher values = snappier transitions; lower = laggier.
# Asymmetric pairs let "punishment" be quick and "recovery" be gradual.
@export_group("Surface transitions")
## How fast effective_grip drops toward a lower target (entering ice/oil).
@export var grip_loss_speed: float = 15.0
## How fast effective_grip rises back up (leaving ice).
@export var grip_recover_speed: float = 5.0
## How fast effective_drag rises toward a higher target (entering mud).
@export var drag_gain_speed: float = 15.0
## How fast effective_drag falls back to 0 (leaving mud).
@export var drag_release_speed: float = 5.0


# --- Runtime state ----------------------------------------------------------

## All Area2D surfaces currently overlapping the car. Populated by
## scripts/surface.gd via the _on_surface_entered / _on_surface_exited
## methods below (duck-typed call from the Surface's body_entered signal).
var current_surfaces: Array[Area2D] = []

## Smoothed grip value actually used in the physics math. Lerps each frame
## toward _get_target_grip(). Initialized in _ready to the asphalt baseline.
var effective_grip: float = 0.9

## Smoothed drag value used in the physics math. Lerps toward
## _get_target_drag(); defaults to 0 (no drag on asphalt).
var effective_drag: float = 0.0


func _ready() -> void:
	# Start the smoothed grip on the baseline so the first physics tick
	# doesn't lerp from a stale default. effective_drag stays at 0 since
	# the asphalt baseline has no drag.
	effective_grip = grip


# ============================================================================
# Main physics tick — orchestrates the five steps above. Each helper does
# one thing; this function is just the order.
# ============================================================================
func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	var throttle := Input.get_axis("brake", "gas")
	var steer := Input.get_axis("steer_left", "steer_right")

	# Local axes for this tick.
	# transform.x is the car's forward (we drew the polygon's nose along +X).
	# transform.y is perpendicular to forward — used to decompose velocity
	# into "going where I'm pointed" vs "sliding sideways".
	var forward := transform.x
	var right := transform.y

	_apply_throttle(state, throttle, forward)
	_update_surface_effects(state.step)
	_apply_friction(state, forward, right)
	_clamp_speed(state)
	_apply_steering(state, steer)


# --- Step 1: throttle -------------------------------------------------------
# Add (or subtract, when braking) velocity along the forward direction.
# Multiplied by state.step (dt) so acceleration stays in pixels/sec²
# regardless of physics tick rate.
func _apply_throttle(state: PhysicsDirectBodyState2D, throttle: float, forward: Vector2) -> void:
	state.linear_velocity += forward * throttle * acceleration * state.step


# --- Step 2: surface effects ------------------------------------------------
# Compute the target grip/drag from currently-overlapping surfaces, then lerp
# the stored effective_* values toward those targets. Asymmetric rates: the
# direction of change determines which speed we use, so we get "fast to slip,
# slow to recover" behavior (and the same for drag, in the gain/release pair).
func _update_surface_effects(dt: float) -> void:
	var target_grip := _get_target_grip()
	var target_drag := _get_target_drag()

	var grip_rate := grip_loss_speed if target_grip < effective_grip else grip_recover_speed
	var drag_rate := drag_gain_speed if target_drag > effective_drag else drag_release_speed

	effective_grip = lerpf(effective_grip, target_grip, grip_rate * dt)
	effective_drag = lerpf(effective_drag, target_drag, drag_rate * dt)


# --- Step 3: friction -------------------------------------------------------
# Project velocity onto the forward and right axes, manipulate each
# independently, recombine.
#
#   forward_vel: how fast we're going where we're pointed.
#   lateral_vel: how fast we're sliding sideways.
#
# Drag is a continuous-time rate (uses dt) applied to forward_vel.
# Grip is a per-frame fraction applied to lateral_vel — at 60 Hz this means
# "kill this fraction of sideways motion, 60 times per second".
func _apply_friction(state: PhysicsDirectBodyState2D, forward: Vector2, right: Vector2) -> void:
	var forward_vel := forward * state.linear_velocity.dot(forward)
	var lateral_vel := right * state.linear_velocity.dot(right)

	forward_vel *= (1.0 - effective_drag * state.step)
	state.linear_velocity = forward_vel + lateral_vel * (1.0 - effective_grip)


# --- Step 4: speed clamp ----------------------------------------------------
# Rescale velocity if it exceeds max_speed. Throttle/collisions/surfaces could
# individually push us above the cap; this is the final enforcer.
func _clamp_speed(state: PhysicsDirectBodyState2D) -> void:
	if state.linear_velocity.length() > max_speed:
		state.linear_velocity = state.linear_velocity.normalized() * max_speed


# --- Step 5: steering -------------------------------------------------------
# Angular velocity is set (not accumulated): each frame the rotation rate is
# input × max_rate × speed_factor. speed_factor ramps from 0 at standstill to
# 1.0 at steering_full_speed_factor × max_speed (and stays at 1.0 above), so
# the car can't pivot in place. maxf guard avoids div-by-zero if someone sets
# the factor to 0.
func _apply_steering(state: PhysicsDirectBodyState2D, steer: float) -> void:
	var full_steer_speed := maxf(max_speed * steering_full_speed_factor, 0.01)
	var speed_factor := clampf(state.linear_velocity.length() / full_steer_speed, 0.0, 1.0)
	state.angular_velocity = steer * steering_speed * speed_factor


# ============================================================================
# Surface tracking
#
# Each Surface (scripts/surface.gd) listens to its Area2D.body_entered /
# body_exited signals and calls these methods on whichever body entered, if
# it has them (duck typing — no shared base class needed). We just keep the
# list; aggregation happens lazily in _get_target_grip / _get_target_drag.
# ============================================================================
func _on_surface_entered(surface: Area2D) -> void:
	current_surfaces.append(surface)


func _on_surface_exited(surface: Area2D) -> void:
	current_surfaces.erase(surface)


# Lowest grip across all current surfaces, or the car's baseline if none.
# "Most slippery wins" — a sliver of ice under a tire skids you regardless
# of what else you're touching.
func _get_target_grip() -> float:
	var result := grip
	for surface in current_surfaces:
		result = minf(result, surface.grip)
	return result


# Highest drag across all current surfaces, or 0 if none.
# "Most resistant wins" — overlapping ice + mud means you skid AND slow.
func _get_target_drag() -> float:
	var result := 0.0
	for surface in current_surfaces:
		result = maxf(result, surface.drag)
	return result
