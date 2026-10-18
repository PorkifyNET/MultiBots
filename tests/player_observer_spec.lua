local logged = {}
local active = true
local funcs = {
	play_cards_from_highlighted = function(event) return event.result end,
	discard_cards_from_highlighted = function(event) return event.result end,
}
G = {
	FUNCS = funcs,
	GAME = {
		round_resets = { ante = 3 }, blind_on_deck = "Big", chips = 1200, dollars = 8,
		current_round = { hands_left = 2, discards_left = 1 },
	},
	hand = {
		cards = { { encoded = "S-A-none-none-none" }, { encoded = "H-K-none-none-none" } },
		highlighted = { { encoded = "S-A-none-none-none" } },
	},
	jokers = { cards = { { config = { center = { key = "j_joker" } } } } },
}
MP = { UTILS = { card_to_string = function(card) return card.encoded end } }
get_poker_hand_info = function(cards)
	return #cards == 1 and "High Card" or "Pair"
end

local Observer = dofile("bot/player_observer.lua")
local logger = {
	path = "active",
	write = function(kind, values) logged[#logged + 1] = { kind = kind, values = values } end,
}
assert(Observer.install({
	Logger = logger,
	is_active = function() return active end,
}) == 2, "observer should wrap available player action callbacks")

local event = { result = "played" }
assert(funcs.play_cards_from_highlighted(event) == "played",
	"observer must preserve callback return values")
assert(#logged == 1 and logged[1].kind == "PLAYER_ACTION"
	and logged[1].values.action == "play"
	and logged[1].values.ante == 3
	and logged[1].values.selected == "S-A-none-none-none"
	and logged[1].values.poker_hand == "High Card",
	"play observation should capture selected cards and pre-action resources")

active = false
funcs.discard_cards_from_highlighted({ result = "discarded" })
assert(#logged == 1, "observer must not capture actions outside an active bot run")

active = true
assert(funcs.discard_cards_from_highlighted({ result = "discarded" }) == "discarded"
	and #logged == 2 and logged[2].values.action == "discard",
	"observer should preserve discard callbacks and label the action")

local second_log = {}
local installed = dofile("bot/player_observer.lua").install({
	Logger = logger,
	is_active = function() return true end,
	get_loggers = function()
		return { logger, {
			path = "second",
			write = function(kind, values) second_log[#second_log + 1] = { kind = kind, values = values } end,
		} }
	end,
})
assert(installed == 2, "observer should support independent per-bot loggers")
funcs.play_cards_from_highlighted(event)
assert(#second_log == 1 and second_log[1].values.action == "play",
	"one human action should reach each active bot match log")

print("player_observer_spec: ok")
