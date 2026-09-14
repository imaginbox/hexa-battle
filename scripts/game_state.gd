class_name GameState
extends RefCounted
## Session-wide run state: the gold the player has banked and how far a march can
## reach.
##
## Static rather than an autoload: any script can read or write it with no node
## reference to thread around, and it survives a board rebuild (which is what the
## stage loop does every level). Reset it with [method reset] to start over.

## Cost of the first reach upgrade, and how much each further one adds.
const REACH_COST_BASE := 40
const REACH_COST_STEP := 30
## Reach levels. Level 1 is the units' own range (1 / 2 / 3 hexes by class);
## every level after that adds one hex to every class on both sides.
const BASE_REACH := 1
const MAX_REACH := 4

## Gold banked by the player. Mines add to it, upgrades spend it.
static var player_gold: int = 0
## Totals produced over the run, shown in the between-levels recap. Spending does
## not reduce them — they say how much the war effort actually generated.
static var gold_earned: int = 0
static var troops_raised: int = 0
## Current reach level. See [method reach_bonus].
static var unlocked_reach_distance: int = BASE_REACH
## When true, the player's tiles fire on their own instead of waiting for a drag.
static var auto_attack: bool = false
## How many duels the AI has lost. Every level it gains reacts faster and comes
## back with more troops; see [method raise_ai_level].
static var ai_level: int = 1


## Which seats are at the table, and which one this peer commands.
##
## Mirrored here from [Net] rather than read from it, on purpose: the board
## scripts ([HexTile], [GameGrid], [AIController]) carry a `class_name`, and a
## script with a `class_name` can be compiled as a dependency of another script
## before the autoload singletons are registered — at which point the `Net`
## identifier does not resolve and the whole file fails to compile. Plain static
## data has no such ordering hazard, so [Net] publishes the table here and the
## board reads it here.
##
## A list of seat indices rather than a plain count, because a table can have holes:
## a card the host never filled can sit between two that are in play, and the board
## must not invent a castle for it.
static var occupied_seats: Array[int] = [0, 1]
## Which of those seats are run by the AI rather than by a person.
static var ai_seats: Array[int] = [1]
static var local_seat: int = 0
static var in_room: bool = false
## Board radius this table's head count calls for.
static var table_radius: int = 3

## Seat colours, shared by the lobby swatches and the board itself so a seat looks
## the same in both places.
const SEAT_COLORS: Array[Color] = [
	Color("2e86de"), Color("ee5253"), Color("4ecb71"), Color("f5a623"),
]
## Board radius by head count: more players need more ground to spread into.
const RADIUS_BY_PLAYERS := {2: 3, 3: 4, 4: 5}


static func seat_color(seat: int) -> Color:
	return SEAT_COLORS[seat % SEAT_COLORS.size()]


static func radius_for_players(count: int) -> int:
	return int(RADIUS_BY_PLAYERS.get(count, RADIUS_BY_PLAYERS[2]))


static func seat_count() -> int:
	return occupied_seats.size()


static func is_ai_seat(seat: int) -> bool:
	return ai_seats.has(seat)


## Records the table. Called by [Net] whenever it changes, including once at startup
## for the offline case.
##
## `match_mode` is passed rather than inferred from the table, because the same table
## means different things in the two modes: solo is one human against the AI at seat
## 1 — which is exactly what a VS match looks like when the host has filled the other
## cards with AI — yet only solo runs the staged difficulty ladder. The board cannot
## tell which it is from the seats alone, so the mode is stated.
static func configure_table(occupied: Array[int], ai: Array[int], my_seat: int,
		match_mode: bool) -> void:
	occupied_seats = occupied.duplicate()
	ai_seats = ai.duplicate()
	local_seat = my_seat
	in_room = match_mode
	table_radius = radius_for_players(occupied.size())


## Peer id that owns the table, and whether that is this peer.
##
## Published with the rest of the table, and for exactly the same reason it lives here:
## the board carries a `class_name`, so it can be compiled as a dependency of another
## script before the autoload singletons are registered — at which point a `Net`
## reference does not resolve and takes the whole file down with it. Static data has no
## such ordering hazard.
static var table_owner_id: int = 0
static var is_authority: bool = false
## Peer id -> seat index, so an action arriving off the wire can be traced to whoever
## sent it rather than trusted.
static var peer_seats: Dictionary = {}


## The seat a peer holds, or -1 when it holds none.
static func seat_of_peer(peer_id: int) -> int:
	return int(peer_seats.get(peer_id, -1))


static func add_gold(amount: int) -> void:
	if amount <= 0:
		return
	player_gold += amount
	gold_earned += amount


## Tallies the troops the board produced, for the between-levels recap.
static func add_troops_raised(amount: int) -> void:
	if amount > 0:
		troops_raised += amount


## Spends gold if there is enough of it. Returns whether the purchase went through.
static func spend_gold(amount: int) -> bool:
	if amount > player_gold:
		return false
	player_gold -= amount
	return true


## What the next +1 hex of reach costs.
static func reach_cost() -> int:
	return REACH_COST_BASE + REACH_COST_STEP * (unlocked_reach_distance - 1)


static func at_max_reach() -> bool:
	return unlocked_reach_distance >= MAX_REACH


## Extra hexes every class gets on top of its own range.
static func reach_bonus() -> int:
	return unlocked_reach_distance - BASE_REACH


## Buys one more hex of reach. Returns false when it is unaffordable or already
## at the cap.
static func upgrade_reach() -> bool:
	if at_max_reach():
		return false
	if not spend_gold(reach_cost()):
		return false
	unlocked_reach_distance += 1
	return true


static func reset() -> void:
	player_gold = 0
	gold_earned = 0
	troops_raised = 0
	unlocked_reach_distance = BASE_REACH
	auto_attack = false
	ai_level = 1


## Called after the player takes a castle: the AI comes back sharper.
static func raise_ai_level() -> void:
	ai_level += 1
