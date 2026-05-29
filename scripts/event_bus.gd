extends Node

## Fired when the race should reset. Carries where the car should land,
## so listeners don't need to know about the spawn marker.
signal race_reset(spawn_transform: Transform2D)
