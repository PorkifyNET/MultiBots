local Endgame = dofile("bot/endgame.lua")

local fronts = Endgame.deck_front_keys()
assert(#fronts == 52, "bot result deck should contain 52 cards")
assert(fronts[1] == "S_2", "deck should start with the two of Spades")
assert(fronts[13] == "S_A", "Spade ranks should use Balatro front keys")
assert(fronts[52] == "D_A", "deck should end with the ace of Diamonds")

local replay = {
	_multibots_state = {
		jokers = { "j_joker", "j_abstract" },
		ante_states = {
			[2] = { jokers = { "j_jolly" } },
		},
	},
}

local current = Endgame.current_joker_keys(replay, 2)
assert(#current == 1 and current[1] == "j_jolly", "result screen should use the current ante's Jokers")
current[1] = "changed"
assert(replay._multibots_state.ante_states[2].jokers[1] == "j_jolly", "Joker snapshot should be copied")

local fallback = Endgame.current_joker_keys(replay, 9)
assert(#fallback == 2 and fallback[2] == "j_abstract", "missing ante should use the final simulated Jokers")

print("endgame_spec: ok")
