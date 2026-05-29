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
#   3. Skid marks — sample pre-friction lateral velocity to toggle tire
#      particle emission.
#   4. Friction — split velocity into forward/lateral, slow forward by drag,
#      kill some lateral by grip, recombine.
#   5. Speed clamp — enforce max_speed.
#   6. Steering — set angular velocity, scaled by current speed.
# ============================================================================


@export_group("Engine")
## How quickly the car gains forward speed when accelerating. Pixels/sec².
@export var acceleration: float = 800.0
## Hard cap on total speed. Pixels/sec.
@export var max_speed: float = 400.0
## Braking force while rolling forward, as a fraction of acceleration.
## Lower = gentler, longer stops.
@export_range(0.0, 1.0, 0.05) var brake_factor: float = 0.2
## Acceleration when reversing, as a fraction of acceleration. Separate from
## brake_factor so reverse can be tuned independently of braking.
@export_range(0.0, 1.0, 0.05) var reverse_factor: float = 0.3

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
## Fraction of normal grip retained at max_speed. 1.0 = no drift effect.
## Lower values mean more oversteer/drift at high speed. 0.3 = pronounced.
## Multiplies with effective_grip, so slippery surfaces stay slipperier.
@export_range(0.0, 1.0, 0.05) var high_speed_grip_floor: float = 0.3


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

# --- Skid marks -------------------------------------------------------------
@export_group("Skid marks")
## Tire-slip cutoff, expressed as a fraction of the lateral velocity a
## max-speed max-steering turn would build per physics tick (ignoring grip).
## Independent of surface, so slippery surfaces still mark easily — they
## naturally exceed the baseline. 0.75 ≈ the old absolute value of 15.
@export_range(0.0, 1.0, 0.05) var skid_threshold_pct: float = 0.75
## Local offset of the left rear tire from the car's center. The right tire
## mirrors this on the Y axis. Negative X = behind center.
@export var rear_tire_offset: Vector2 = Vector2(-15, 8)

@onready var skid_particles_left: CPUParticles2D = $SkidParticlesLeft
@onready var skid_particles_right: CPUParticles2D = $SkidParticlesRight


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

## Per-frame grip actually used in lateral-friction math, after speed
## modulation. Exposed for the debug HUD; do not write to it externally.
var final_grip: float = 0.9

## Pending reset. _on_race_reset can fire any time; the actual move is
## deferred to the next _integrate_forces — the only place a RigidBody2D
## can be repositioned without fighting the solver.
var _reset_requested: bool = false
var _reset_to: Transform2D

## True while the post-reset countdown is running. Set on race_reset,
## cleared on race_started. While true, _integrate_forces freezes the car.
var _controls_locked: bool = false

## Blocks roll-into-reverse: set true while braking from forward motion, so
## holding the brake past a full stop just keeps the car still. Cleared when
## the brake is released, so a fresh brake press from a standstill reverses.
var _reverse_locked: bool = false

func _ready() -> void:
	EventBus.race_reset.connect(_on_race_reset)
	EventBus.race_started.connect(_on_race_started)
	# Start the smoothed grip on the baseline so the first physics tick
	# doesn't lerp from a stale default. effective_drag stays at 0 since
	# the asphalt baseline has no drag.
	effective_grip = grip


# ============================================================================
# Main physics tick — orchestrates the five steps above. Each helper does
# one thing; this function is just the order.
# ============================================================================
func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if _reset_requested:
		_reset_requested = false
		state.transform = _reset_to

	if _controls_locked:
		state.linear_velocity = Vector2.ZERO
		state.angular_velocity = 0.0
		return
		
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
	_update_skid_marks(state, right)
	_apply_friction(state, forward, right)
	_clamp_speed(state)
	_apply_steering(state, steer)

# --- Step 1: throttle -------------------------------------------------------
# Add (or subtract, when braking) velocity along the forward direction.
# Multiplied by state.step (dt) so acceleration stays in pixels/sec²
# regardless of physics tick rate.
func _apply_throttle(state: PhysicsDirectBodyState2D, throttle: float, forward: Vector2) -> void:
	var forward_speed := state.linear_velocity.dot(forward)
	var force := 0.0
	if throttle >= 0.0:
		_reverse_locked = false                               # brake released — reverse allowed again
		force = throttle * acceleration                       # gas
	elif forward_speed > 0.0:
		_reverse_locked = true                                # this brake press began while rolling forward
		force = throttle * acceleration * brake_factor        # braking (rolling forward)
	elif not _reverse_locked:
		force = throttle * acceleration * reverse_factor      # reversing (brake re-pressed at a stop)
	# else: stopped while still holding the brake → hold still, don't reverse
	state.linear_velocity += forward * force * state.step


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


# --- Step 3: friction ----------------------------------------------
# Project velocity onto the forward and right axes, manipulate each
# independently, recombine.
#
#   forward_vel: how fast we're going where we're pointed.
#   lateral_vel: how fast we're sliding sideways.
#
# Drag is a continuous-time rate (uses dt) applied to forward_vel.
#
# Grip starts from effective_grip (set by surfaces) and is reduced as speed
# approaches max_speed, via a quadratic curve toward high_speed_grip_floor.
# The result, final_grip, is the per-frame fraction of lateral motion killed.
func _apply_friction(state: PhysicsDirectBodyState2D, forward: Vector2, right: Vector2) -> void:
	var forward_vel := forward * state.linear_velocity.dot(forward)
	var lateral_vel := right * state.linear_velocity.dot(right)

	# Speed-dependent grip loss. Eased (quadratic) curve so low-mid speeds
	# stay planted; grip only really falls off as we approach max_speed.
	# Multiplies with effective_grip — slippery surfaces still feel slippery.
	var speed_factor := clampf(state.linear_velocity.length() / max_speed, 0.0, 1.0)
	var eased := speed_factor * speed_factor
	final_grip = lerpf(effective_grip, effective_grip * high_speed_grip_floor, eased)

	forward_vel *= (1.0 - effective_drag * state.step)
	state.linear_velocity = forward_vel + lateral_vel * (1.0 - final_grip)


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

# --- Step 6: skid marks -----------------------------------------------------
# Toggle particle emission based on lateral slip. Particles have
# local_coords = false, so they're anchored in world space where the tire was
# at emission time — they don't drag along with the car. Lifetime, fade, and
# count cap are all configured on the nodes themselves; no per-frame
# bookkeeping needed here.
#
# Measured BEFORE _apply_friction kills the lateral component, otherwise the
# post-friction value (~10% of the real slip on grip=0.9) never trips.
#
# Baseline is the max lateral velocity a max-speed max-steering turn would
# build at the *worst-case drift effect* on a perfect-grip surface. Dividing
# by high_speed_grip_floor (not by current grip) keeps the threshold
# absolute in px/s — slippery surfaces still naturally exceed it (which is
# what makes them skid easily), but the baseline grows to include the
# expansion drift causes on otherwise-grippy surfaces. maxf guards
# against divide-by-zero on extreme tuning.
func _update_skid_marks(state: PhysicsDirectBodyState2D, right: Vector2) -> void:
	var lateral_speed := absf(state.linear_velocity.dot(right))
	var max_lateral_baseline := max_speed * steering_speed * state.step / maxf(high_speed_grip_floor, 0.01)
	var skidding := lateral_speed >= skid_threshold_pct * max_lateral_baseline

	skid_particles_left.emitting = skidding
	skid_particles_right.emitting = skidding
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

func _on_race_reset(spawn_transform: Transform2D) -> void:
	_reset_to = spawn_transform
	_reset_requested = true
	_controls_locked = true

func _on_race_started() -> void:
	_controls_locked = false
	
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
