extends SceneTree

## Authors the Terrain Range map data.
##
## Reads the pristine Terrain3D v1.0.2-stable demo regions from the read-only
## third-party directory, applies the AeroSim flight-field overlay, and writes
## the result to the map data directory the scene loads. The third-party
## directory is never written to, which is what keeps its SHA-256 record in
## `assets/third_party/terrain3d/asset_notes.md` verifiable.
##
## The pass is idempotent: every write is an absolute value, so re-running it
## reproduces the same output bit-for-bit from the same upstream regions.
##
## Usage:
##   GODOT_BIN --headless --path . --script scripts/author_terrain3d_range.gd

const SourceDirectory := "res://assets/third_party/terrain3d_demo/demo/data"
const OutputDirectory := "res://assets/maps/terrain3d_range/data"
const RegionFiles: Array[String] = [
    "terrain3d_00_00.res",
    "terrain3d_00-01.res",
    "terrain3d_00-02.res",
]
const TerrainAssets = preload("res://assets/third_party/terrain3d_demo/demo/data/assets.tres")

## The natural mesa the flight field sits on. Measured from the upstream
## regions: a 79.70 m plateau in the middle of the valley with roughly 70 m of
## relief within 120 m in every direction.
const FieldHeight := 79.7
const MeadowMinX := 376
const MeadowMaxX := 600
const MeadowMinZ := -824
const MeadowMaxZ := -672
## Only ground already within this much of the mesa height becomes meadow, so
## the paint follows the natural plateau instead of squaring it off.
const MeadowHeightTolerance := 2.0

const PadNorth := Vector2(520, -790)
const PadSouth := Vector2(440, -700)
const PadRadius := 9.0
const PadFeather := 5.0

## Worn dirt track between the two pads.
const TaxiwayHalfWidth := 3.5
const TaxiwayFeather := 2.5

## Loose rock at the foot of the north ridge landmark.
const ScreeCenter := Vector2(520, -822)
const ScreeRadius := 7.0

## Texture asset ids, matching `assets.tres`: 0 Rock, 1 Grass, 2 SoilSand.
const TextureRock := 0
const TextureGrass := 1
const TextureSoilSand := 2


func _initialize() -> void:
    call_deferred("_run")


func _run() -> void:
    if not _stage_pristine_regions():
        quit(1)
        return

    var camera := Camera3D.new()
    camera.position = Vector3(PadNorth.x, FieldHeight + 120.0, PadNorth.y)
    camera.current = true
    root.add_child(camera)

    var terrain := Terrain3D.new()
    terrain.name = "Terrain3D"
    terrain.data_directory = OutputDirectory
    terrain.assets = TerrainAssets
    terrain.material = Terrain3DMaterial.new()
    root.add_child(terrain)
    await process_frame
    terrain.set_camera(camera)
    await process_frame

    var data := terrain.data
    if not data.has_region(Vector2i(0, -1)):
        push_error("Terrain Range authoring requires the upstream region (0, -1)")
        quit(1)
        return

    _paint_meadow(data)
    _paint_taxiway(data)
    _author_pad(data, PadNorth)
    _author_pad(data, PadSouth)
    _paint_scree(data)

    data.update_maps(Terrain3DRegion.TYPE_HEIGHT, true, false)
    data.update_maps(Terrain3DRegion.TYPE_CONTROL, true, false)
    data.save_directory(OutputDirectory)

    _report(data)

    terrain.queue_free()
    camera.queue_free()
    await process_frame
    quit(0)


## Copies the upstream regions into the output directory so the authoring pass
## always starts from pristine data rather than from its own previous output.
func _stage_pristine_regions() -> bool:
    if DirAccess.make_dir_recursive_absolute(OutputDirectory) != OK and not DirAccess.dir_exists_absolute(OutputDirectory):
        push_error("Terrain Range authoring could not create %s" % OutputDirectory)
        return false
    for file_name in RegionFiles:
        var source := "%s/%s" % [SourceDirectory, file_name]
        if not FileAccess.file_exists(source):
            push_error("Terrain Range authoring is missing upstream region %s" % source)
            return false
        var error := DirAccess.copy_absolute(source, "%s/%s" % [OutputDirectory, file_name])
        if error != OK:
            push_error("Terrain Range authoring could not stage %s (error %d)" % [file_name, error])
            return false
    return true


## Turns the naturally flat top of the mesa into an explicit grass meadow. The
## upstream control map is rock everywhere and leaves ground cover to the
## material's auto shader; the flight field needs the surface it is flown over
## to be authored rather than inferred.
func _paint_meadow(data: Terrain3DData) -> void:
    for x in range(MeadowMinX, MeadowMaxX + 1):
        for z in range(MeadowMinZ, MeadowMaxZ + 1):
            var position := Vector3(x, 0, z)
            var height := data.get_height(position)
            if not is_finite(height) or absf(height - FieldHeight) > MeadowHeightTolerance:
                continue
            _paint(data, position, TextureGrass, TextureGrass, 0.0)


## Levels a launch pad to the mesa height and lays a rock hardstand over it.
##
## The hardstand is rock rather than soil on purpose: the particle shader culls
## ground cover over hand-painted rock, so painting the pad this way is what
## keeps grass from growing through the surface the drone launches from.
func _author_pad(data: Terrain3DData, center: Vector2) -> void:
    var outer := PadRadius + PadFeather
    for x in range(int(center.x - outer) - 1, int(center.x + outer) + 2):
        for z in range(int(center.y - outer) - 1, int(center.y + outer) + 2):
            var distance := Vector2(x, z).distance_to(center)
            if distance > outer:
                continue
            var position := Vector3(x, 0, z)
            if distance <= PadRadius:
                data.set_height(position, FieldHeight)
            else:
                var pull := 1.0 - (distance - PadRadius) / PadFeather
                var height := data.get_height(position)
                if is_finite(height):
                    data.set_height(position, lerpf(height, FieldHeight, pull * pull))
            var blend := 1.0 if distance <= PadRadius else clampf(1.0 - (distance - PadRadius) / PadFeather, 0.0, 1.0)
            _paint(data, position, TextureGrass, TextureRock, blend)


## A worn soil track joining the two pads, so the field reads as used ground
## rather than two hardstands dropped onto an untouched meadow.
func _paint_taxiway(data: Terrain3DData) -> void:
    var axis := PadSouth - PadNorth
    var length := axis.length()
    if length <= 0.0:
        return
    var direction := axis / length
    var outer := TaxiwayHalfWidth + TaxiwayFeather
    var min_x := int(minf(PadNorth.x, PadSouth.x) - outer) - 1
    var max_x := int(maxf(PadNorth.x, PadSouth.x) + outer) + 2
    var min_z := int(minf(PadNorth.y, PadSouth.y) - outer) - 1
    var max_z := int(maxf(PadNorth.y, PadSouth.y) + outer) + 2
    for x in range(min_x, max_x):
        for z in range(min_z, max_z):
            var offset := Vector2(x, z) - PadNorth
            var along := clampf(offset.dot(direction), 0.0, length)
            var distance := offset.distance_to(direction * along)
            if distance > outer:
                continue
            var blend := 1.0 if distance <= TaxiwayHalfWidth else clampf(1.0 - (distance - TaxiwayHalfWidth) / TaxiwayFeather, 0.0, 1.0)
            _paint(data, Vector3(x, 0, z), TextureGrass, TextureSoilSand, blend)


## Rock debris skirting the north ridge landmark, so the landmark reads as part
## of the terrain rather than a prop dropped onto grass.
func _paint_scree(data: Terrain3DData) -> void:
    for x in range(int(ScreeCenter.x - ScreeRadius) - 1, int(ScreeCenter.x + ScreeRadius) + 2):
        for z in range(int(ScreeCenter.y - ScreeRadius) - 1, int(ScreeCenter.y + ScreeRadius) + 2):
            var distance := Vector2(x, z).distance_to(ScreeCenter)
            if distance > ScreeRadius:
                continue
            var position := Vector3(x, 0, z)
            _paint(data, position, data.get_control_base_id(position), TextureRock, 1.0)


## Writes one authored surface pixel.
##
## Clearing the auto bit is what makes the paint take effect: the upstream
## regions leave auto shading on everywhere, and while it is on both the shader
## and `Terrain3DData.get_texture_id()` derive the surface from slope and ignore
## the painted ids. Authored ground has to opt out of that inference.
func _paint(data: Terrain3DData, position: Vector3, base_id: int, overlay_id: int, blend: float) -> void:
    data.set_control_auto(position, false)
    data.set_control_base_id(position, base_id)
    data.set_control_overlay_id(position, overlay_id)
    data.set_control_blend(position, blend)


## Prints the authored values the scene and the headless gate depend on, so a
## layout change is caught here rather than in a failing assertion.
func _report(data: Terrain3DData) -> void:
    print("regions=", data.get_region_locations())
    for probe in [
        ["PadNorth", Vector3(PadNorth.x, 0, PadNorth.y)],
        ["PadSouth", Vector3(PadSouth.x, 0, PadSouth.y)],
        ["Taxiway", Vector3(480, 0, -745)],
        ["Meadow", Vector3(540, 0, -760)],
        ["Scree", Vector3(ScreeCenter.x, 0, ScreeCenter.y)],
        ["NorthSlope", Vector3(408, 0, -792)],
    ]:
        var position: Vector3 = probe[1]
        print("%-11s %s height=%.3f texture=%s" % [probe[0], position, data.get_height(position), data.get_texture_id(position)])
