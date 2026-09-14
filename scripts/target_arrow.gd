class_name TargetArrow
extends Node3D
## Aiming ribbon: a curved 3D band running from the selected tile to wherever
## you are pointing. The geometry is rebuilt from scratch every frame with an
## ImmediateMesh, which is exactly what that class is designed for.

## How many segments the curve is chopped into — more is smoother.
const SEGMENTS := 16
## Ribbon width at the origin; it tapers towards the tip.
const WIDTH := 0.22
## Arc height as a fraction of the distance, clamped between a floor and a ceiling.
const PEAK_RATIO := 0.25
const PEAK_MIN := 0.8
const PEAK_MAX := 3.0
## Lift above the tile face, so the ribbon is not buried inside the board.
const LIFT := 0.4
## Ribbon colour when the board is ready for the move being drawn, and when it is not.
## The board paces moves, so a drag that will not land yet has to say so — otherwise the
## release just does nothing and reads as a broken control.
const COLOR_READY := Color("38b6ff")
const COLOR_WAITING := Color("8b93a1")

var mesh_instance: MeshInstance3D = MeshInstance3D.new()
var immediate_mesh: ImmediateMesh = ImmediateMesh.new()
var arrow_material: StandardMaterial3D = StandardMaterial3D.new()

var is_active: bool = false
var start_point: Vector3 = Vector3.ZERO
var target_point: Vector3 = Vector3.ZERO


func _ready() -> void:
	add_child(mesh_instance)
	mesh_instance.mesh = immediate_mesh

	# Matériau style Clay / Plastique bleu vibrant
	arrow_material.albedo_color = COLOR_READY
	arrow_material.roughness = 0.4
	arrow_material.emission_enabled = true
	arrow_material.emission = COLOR_READY.darkened(0.45)
	arrow_material.emission_energy_multiplier = 0.5
	arrow_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_instance.material_override = arrow_material
	visible = false


## Tints the ribbon for whether the board would accept the move being aimed at. Called
## every frame while aiming, so it only ever touches the two colours.
func set_ready(ready: bool) -> void:
	var tint: Color = COLOR_READY if ready else COLOR_WAITING
	arrow_material.albedo_color = tint
	arrow_material.emission = tint.darkened(0.45)


func start_aiming(origin: Vector3) -> void:
	start_point = origin + Vector3(0, LIFT, 0)
	target_point = start_point
	is_active = true
	visible = true


func update_aim(current_target: Vector3) -> void:
	target_point = current_target + Vector3(0, LIFT, 0)
	_draw_curved_arrow()


func stop_aiming() -> void:
	is_active = false
	visible = false
	immediate_mesh.clear_surfaces()


func _draw_curved_arrow() -> void:
	immediate_mesh.clear_surfaces()
	immediate_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLE_STRIP)

	# Hauteur d'arc proportionnelle à la distance
	var distance: float = start_point.distance_to(target_point)
	var peak_height: float = clampf(distance * PEAK_RATIO, PEAK_MIN, PEAK_MAX)
	var mid_point: Vector3 = (start_point + target_point) / 2.0 + Vector3(0, peak_height, 0)

	var prev_pos: Vector3 = start_point

	for i in range(SEGMENTS + 1):
		var t: float = float(i) / float(SEGMENTS)
		# Interpolation quadratique de Bézier
		var p: Vector3 = (1.0 - t) * (1.0 - t) * start_point + 2.0 * (1.0 - t) * t * mid_point + t * t * target_point

		# Calcul de la direction tangentielle pour orienter la largeur du ruban
		var forward: Vector3 = (p - prev_pos).normalized() if i > 0 else (mid_point - start_point).normalized()
		var right: Vector3 = forward.cross(Vector3.UP).normalized()
		prev_pos = p

		# Effet d'amincissement vers l'extrémité (pointe)
		var current_width: float = WIDTH * (1.0 - (t * 0.4))

		var v1: Vector3 = p - right * (current_width * 0.5)
		var v2: Vector3 = p + right * (current_width * 0.5)

		# Without a normal the ribbon gets NdotL = 0 and shows nothing but its
		# emission, which reads as a dark smudge. The band lies flat, so UP is
		# the correct facing for it.
		immediate_mesh.surface_set_normal(Vector3.UP)
		immediate_mesh.surface_add_vertex(v1)
		immediate_mesh.surface_set_normal(Vector3.UP)
		immediate_mesh.surface_add_vertex(v2)

	immediate_mesh.surface_end()
