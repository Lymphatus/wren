extends Node

## Fired when the race should reset. Carries where the car should land,
## so listeners don't need to know about the spawn marker.
signal race_reset(spawn_transform: Transform2D)
## Fired when the countdown ends and the car is free to move.
signal race_started()
## Fired when the race ended
signal race_ended()
