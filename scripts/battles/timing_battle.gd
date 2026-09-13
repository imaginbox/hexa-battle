class_name TimingBattle
extends IBattleModule
## Reference boss fight: stop the sweeping marker inside the green zone.
##
## Three rounds, two hits to win. The zone widens with the attacker's troop
## advantage, so grinding the fortress down on the board visibly pays off here.
##
## This is a TEMPLATE. To build your own fight, keep [method init_battle] and
## call [method finish_battle] when it ends, then point MainLoop's
## current_battle_module_scene at your scene instead of this one.

const ROUNDS := 3
const HITS_TO_WIN := 2
## Left-right-left cycles per second.
const SWEEPS_PER_SECOND := 0.8
const ZONE_MIN_HALF_WIDTH := 0.08
const ZONE_MAX_HALF_WIDTH := 0.24
const MARKER_WIDTH := 6.0
## Freeze after each strike, before the marker moves again.
const STRIKE_PAUSE := 0.55
## Delay between the final strike and the verdict.
const ENDING_DELAY := 0.9

@onready var _info: Label = $Box/Info
@onready var _rounds: Label = $Box/Rounds
@onready var _result: Label = $Box/Result
@onready var _strike: Button = $Box/Strike
@onready var _bar: ColorRect = $Box/Bar
@onready var _zone: ColorRect = $Box/Bar/Zone
@onready var _marker: ColorRect = $Box/Bar/Marker

## Half-width of the target zone, as a fraction of the bar.
var _zone_half_width: float = ZONE_MIN_HALF_WIDTH
var _phase: float = 0.0
var _hits: int = 0
var _attempts: int = 0
var _strike_pause: float = 0.0
var _ending_left: float = 0.0
var _done: bool = false


func _ready() -> void:
	_strike.pressed.connect(_attempt)
	_strike.grab_focus()
	_bar.resized.connect(_update_zone)
	_update_zone()
	_update_marker()
	_update_rounds()


func init_battle(attacker_data: Dictionary, defender_data: Dictionary) -> void:
	var attackers: int = int(attacker_data.get("power", 1))
	var defenders: int = maxi(int(defender_data.get("power", 1)), 1)
	var ratio: float = float(attackers) / float(defenders)
	_zone_half_width = clampf(0.1 + 0.12 * (ratio - 1.0), ZONE_MIN_HALF_WIDTH, ZONE_MAX_HALF_WIDTH)
	_info.text = "Assault: %d troops  vs  %d defenders%s\nodds %.2f" % [
		attackers,
		defenders,
		"  [FORTRESS]" if bool(defender_data.get("is_boss", false)) else "",
		ratio,
	]
	_update_zone()
	_update_rounds()


func _process(delta: float) -> void:
	if _done:
		return
	if _ending_left > 0.0:
		_ending_left -= delta
		if _ending_left <= 0.0:
			_done = true
			finish_battle(_hits >= HITS_TO_WIN)
		return
	if _strike_pause > 0.0:
		_strike_pause -= delta
		return
	_phase += delta * SWEEPS_PER_SECOND
	_update_marker()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_accept"):
		_attempt()
		get_viewport().set_input_as_handled()


# --- the fight ----------------------------------------------------------------

func _attempt() -> void:
	if _done or _ending_left > 0.0 or _strike_pause > 0.0:
		return
	var hit: bool = absf(_marker_position() - 0.5) <= _zone_half_width
	if hit:
		_hits += 1
	_result.text = "HIT" if hit else "MISS"
	_attempts += 1
	_strike_pause = STRIKE_PAUSE
	_update_rounds()
	if _attempts >= ROUNDS:
		_ending_left = ENDING_DELAY
		_strike.disabled = true


# --- presentation -------------------------------------------------------------

## Where the marker sits along the bar: 0 = left edge, 1 = right edge.
func _marker_position() -> float:
	return absf(fmod(_phase, 2.0) - 1.0)


func _update_marker() -> void:
	# Centre the marker on the position, so it lines up with the zone maths.
	_marker.size = Vector2(MARKER_WIDTH, _bar.size.y)
	_marker.position = Vector2(_marker_position() * _bar.size.x - MARKER_WIDTH * 0.5, 0.0)


func _update_zone() -> void:
	_zone.size = Vector2(_zone_half_width * 2.0 * _bar.size.x, _bar.size.y)
	_zone.position = Vector2((0.5 - _zone_half_width) * _bar.size.x, 0.0)


func _update_rounds() -> void:
	_rounds.text = "Round %d of %d      hits %d / %d needed" % [
		mini(_attempts + 1, ROUNDS), ROUNDS, _hits, HITS_TO_WIN]
