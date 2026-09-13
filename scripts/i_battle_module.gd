class_name IBattleModule
extends Control
## Interface for a mini-game that resolves an assault on a boss tile.
##
## The game's main loop instantiates a module, hands it both sides' data through
## [method init_battle], and waits for [signal battle_completed]. The module owns
## the entire presentation of the fight; the main loop owns the consequences on
## the board (who keeps the tile, what happens next).
##
## Data contract, shared by both dictionaries:
## [codeblock]
## tile    : HexTile   the tile this side fights from (attacker) or for (defender)
## coords  : Vector2i  that tile's axial grid coordinates
## side    : int       the HexTile seat this side belongs to (HexTile.NEUTRAL for none)
## power   : int       troop value for this side; read it for your odds
## is_boss : bool      true when the tile is a FORTRESS_BOSS
## [/codeblock]

signal battle_completed(is_victory: bool)

# Fonction appelée par le jeu principal pour démarrer le combat
@warning_ignore("unused_parameter")
func init_battle(attacker_data: Dictionary, defender_data: Dictionary) -> void:
	pass

# Fonction à appeler quand le mini-jeu se termine
func finish_battle(win: bool) -> void:
	battle_completed.emit(win)
