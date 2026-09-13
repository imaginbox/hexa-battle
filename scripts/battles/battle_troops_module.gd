class_name BattleTroopsModule
extends IBattleModule
## Combat express : les deux armées s'égrènent en direct, puis le module annonce
## le vainqueur. Le camp qui part avec le plus de troupes l'emporte — les pertes
## sont symétriques (2 à 4 par camp et par tick), donc elles ne départagent que
## les affrontements serrés.

@onready var blue_label: Label = $PanelCard/VBox/HBoxClash/BlueArmyBox/BlueCount
@onready var red_label: Label = $PanelCard/VBox/HBoxClash/RedArmyBox/RedCount
@onready var status_label: Label = $PanelCard/VBox/StatusLabel
@onready var panel_card: Control = $PanelCard

## Perte infligée à chaque camp, par tick d'attrition.
const LOSS_MIN := 2
const LOSS_MAX := 4
## Intervalle entre deux ticks d'attrition, en secondes.
const TICK := 0.08
## Pause sur le verdict avant la sortie animée.
const VERDICT_HOLD := 1.2

var blue_troops: int = 0
var red_troops: int = 0
var clash_running: bool = false


func _ready() -> void:
	# Animation d'entrée élastique de la fenêtre (effet pop-up jouet)
	panel_card.pivot_offset = panel_card.size / 2.0
	panel_card.scale = Vector2.ZERO
	var tween := create_tween().set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(panel_card, "scale", Vector2.ONE, 0.4)


func init_battle(attacker_data: Dictionary, defender_data: Dictionary) -> void:
	blue_troops = int(attacker_data.get("power", 30))
	red_troops = int(defender_data.get("power", 50))
	_update_labels()
	start_clash_sequence()


func _update_labels() -> void:
	blue_label.text = str(maxi(blue_troops, 0))
	red_label.text = str(maxi(red_troops, 0))


func start_clash_sequence() -> void:
	status_label.text = "AFFRONTEMENT !"
	clash_running = true

	# Boucle d'attrition
	while blue_troops > 0 and red_troops > 0:
		await get_tree().create_timer(TICK).timeout

		blue_troops -= randi_range(LOSS_MIN, LOSS_MAX)
		red_troops -= randi_range(LOSS_MIN, LOSS_MAX)

		_update_labels()

		# Micro-secousse du panneau lors des impacts
		panel_card.position.x += randf_range(-4, 4)
		panel_card.position.y += randf_range(-4, 4)

	clash_running = false
	_resolve_outcome()


func _resolve_outcome() -> void:
	var won: bool = blue_troops > 0

	var tween := create_tween().set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
	if won:
		status_label.text = "VICTOIRE !"
		status_label.modulate = Color.GREEN
	else:
		status_label.text = "DÉFAITE..."
		status_label.modulate = Color.RED

	tween.tween_property(status_label, "scale", Vector2(1.3, 1.3), 0.3)
	await get_tree().create_timer(VERDICT_HOLD).timeout

	# Sortie animée et signal au jeu principal
	var exit_tween := create_tween()
	exit_tween.tween_property(panel_card, "scale", Vector2.ZERO, 0.25)
	await exit_tween.finished

	finish_battle(won)
