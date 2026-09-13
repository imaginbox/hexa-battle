extends Node3D
## Development preview: builds the real board for a chosen table size, so the
## multiplayer layout can be eyeballed without gathering four clients at the relay.
##
## The board reads the table only from [GameState], and [Net] is what normally
## publishes it. Going through GameState directly means this can stand up any
## table, including sizes too small to be a legal room, with no network at all —
## which is also a decent proof that the board is fully decoupled from the relay.
##
## Run this scene and change [member seats] / [member my_seat] to check the
## corners, seat colours and board radius for 1 to 4 players.

## Seats at the previewed table. 1 gives the solo board.
@export_range(1, 4) var seats: int = 4
## Which seat this preview plays from — the one whose castle shows as yours.
@export_range(0, 3) var my_seat: int = 0

const BOARD_SCENE := "res://scenes/main.tscn"


func _ready() -> void:
	# A fresh run, so the previewed board matches one built after a level reset
	# rather than inheriting whatever the last session left in GameState.
	GameState.reset()
	# Every other card is filled with an AI, which is the common shape of a real
	# table: one human and a machine apiece for the empty seats.
	var occupied: Array[int] = []
	var ai: Array[int] = []
	for i in seats:
		occupied.append(i)
		if i != my_seat:
			ai.append(i)
	GameState.configure_table(occupied, ai, my_seat, seats > 1)
	add_child(load(BOARD_SCENE).instantiate())
