class_name TimeTrial
extends RefCounted

signal checkpoint_reached(index: int, total: int)
signal trial_finished(elapsed_seconds: float)

var checkpoint_positions: Array[Vector3] = []
var finish_position := Vector3.ZERO
var activation_radius := 2.5
var next_checkpoint_index := 0
var elapsed_seconds := 0.0
var active := false
var finished := false


func configure(positions: Array, finish: Vector3, radius: float = 2.5) -> void:
    checkpoint_positions.clear()
    for position in positions:
        if position is Vector3:
            checkpoint_positions.append(position)
    finish_position = finish
    activation_radius = maxf(radius, 0.1)
    reset()


func start(reset_trial: bool = true) -> void:
    if reset_trial:
        reset()
    active = true


func reset() -> void:
    next_checkpoint_index = 0
    elapsed_seconds = 0.0
    active = false
    finished = false


func advance(position: Vector3, delta_seconds: float) -> void:
    if not active or finished:
        return
    elapsed_seconds += maxf(delta_seconds, 0.0)
    if next_checkpoint_index < checkpoint_positions.size():
        if position.distance_to(checkpoint_positions[next_checkpoint_index]) > activation_radius:
            return
        next_checkpoint_index += 1
        checkpoint_reached.emit(next_checkpoint_index, checkpoint_positions.size())
    if next_checkpoint_index == checkpoint_positions.size() and position.distance_to(finish_position) <= activation_radius:
        finished = true
        active = false
        trial_finished.emit(elapsed_seconds)
