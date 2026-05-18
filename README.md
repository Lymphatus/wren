# Wren

> Top-down 2D arcade racer in Godot 4.6, in the spirit of *Super Cars* / *Super Speed*. Built as a learning project — small steps, lots of comments.

*"Wren" is a codename. The project may pick up a final name later.*

## Handling — hybrid physics

The car is a `RigidBody2D` so collisions (walls, future opponents) are handled by the physics engine for free. The script overrides velocity each physics tick inside `_integrate_forces`, splitting it into forward and lateral components and manipulating each:

- Forward velocity is the engine you control.
- Lateral velocity is killed (fully or partially) each frame — that's the **grip** value.
- A separate **drag** value slows forward velocity on resistant surfaces.

Surfaces (`Area2D` zones) under the car can override grip and drag, with smoothed transitions: punishment is fast (entering ice → slip immediately), recovery is slow (leaving ice → tires retain some slip).

## Controls

| Action | Key |
|---|---|
| Accelerate | W / Up |
| Brake / Reverse | S / Down |
| Steer left | A / Left |
| Steer right | D / Right |
| Toggle debug overlay | F3 |

## Status

Work in progress. Done so far: handling, walls, surface zones with smoothed transitions, basic HUD. Up next: skid marks, lap detection, AI opponent.

## License

MIT — see [LICENSE](LICENSE).
