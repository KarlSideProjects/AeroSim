extends RefCounted

## Test-only support surface for the PX4 qualification harness.  The smoke
## scene deliberately has a visual ground plane only; this keeps the real
## qualification's initial support equivalent to a normal map spawn without
## changing the production scene or collision policy.

const NAME := "QualificationGroundSupport"
const SIZE_M := Vector3(24.0, 0.1, 24.0)
const CENTER_Y_M := -0.15
const DRONE_SPAWN_CENTER_Y_M := 0.0
const DRONE_RADIUS_M := 0.1
const FRICTION := 1.0
const BOUNCE := 0.0


static func install(parent: Node) -> StaticBody3D:
    var existing := parent.get_node_or_null(NAME)
    if existing is StaticBody3D:
        return existing
    var support := StaticBody3D.new()
    support.name = NAME
    support.position = Vector3(0.0, CENTER_Y_M, 0.0)
    support.collision_layer = 1
    support.collision_mask = 1
    var material := PhysicsMaterial.new()
    material.friction = FRICTION
    material.bounce = BOUNCE
    support.physics_material_override = material
    var collider := CollisionShape3D.new()
    collider.name = "CollisionShape3D"
    var shape := BoxShape3D.new()
    shape.size = SIZE_M
    collider.shape = shape
    support.add_child(collider)
    parent.add_child(support)
    return support
