local Endgame = dofile("bot/endgame.lua")

local network_requests = 0
local vanilla_game_over_calls = 0
local vanilla_win_calls = 0
local bot_resets = 0
local practice_setups = 0

MULTIBOTS = {
	peer = { reset = function(leave_lobby)
		assert(leave_lobby == true, "result navigation must leave the completed lobby")
		bot_resets = bot_resets + 1
	end },
}

local function area(kind)
	return {
		T = { x = 0, y = 0 },
		config = { type = kind, card_count = 0 },
		cards = {},
		highlighted = {},
		emplace = function(self, card)
			self.cards[#self.cards + 1] = card
			card.area = self
		end,
	}
end

function remove_all(items)
	for index = #items, 1, -1 do table.remove(items, index) end
end

function Card(_, _, _, _, front, center, params)
	return {
		front = front,
		center = center,
		params = params,
		remove = function() end,
	}
end

function localize(key)
	return ({ b_start_new_run = "New Run", b_main_menu = "Main Menu" })[key] or key
end

G = {
	CARD_W = 1,
	CARD_H = 1,
	UIT = { T = "text" },
	GAME = { round_resets = { ante = 2 } },
	P_CENTERS = { c_base = { key = "c_base" }, j_jolly = { key = "j_jolly" } },
	P_CARDS = {},
	FUNCS = {
		load_end_game_jokers = function() error("online Joker loader should not run") end,
		load_nemesis_deck = function() error("online deck loader should not run") end,
		setup_practice_mode = function() practice_setups = practice_setups + 1 end,
		go_to_menu = function() end,
	},
}
for _, key in ipairs(Endgame.deck_front_keys()) do G.P_CARDS[key] = { key = key } end

MP = {
	GHOST = {
		replay = {
			_multibots = true,
			_multibots_state = { ante_states = { [2] = { jokers = { "j_jolly" } } } },
		},
		is_active = function() return true end,
		clear = function() end,
	},
	ACTIONS = {
		request_nemesis_stats = function() network_requests = network_requests + 1 end,
	},
	UI = {},
}

local function button(name, label)
	return {
		config = { button = name },
		nodes = { { n = G.UIT.T, config = { text = label } } },
	}
end

function MP.UI.create_UIBox_mp_game_end(has_won)
	MP.end_game_jokers = area("joker")
	G.FUNCS.load_end_game_jokers()
	MP.ACTIONS.request_nemesis_stats()
	MP.nemesis_deck = area("deck")
	MP.nemesis_cards = {}
	G.FUNCS.load_nemesis_deck()
	return {
		config = { has_won = has_won },
		nodes = {
			button("mp_return_to_lobby", "Return to Lobby"),
			button("lobby_leave", "Leave Lobby"),
		},
	}
end

function create_UIBox_game_over()
	vanilla_game_over_calls = vanilla_game_over_calls + 1
end

function create_UIBox_win()
	vanilla_win_calls = vanilla_win_calls + 1
end

Endgame.install()
local result = create_UIBox_game_over()

assert(result.config.has_won == false, "bot loss should use Multiplayer's loss screen")
assert(vanilla_game_over_calls == 0 and vanilla_win_calls == 0, "vanilla result UI should be bypassed")
assert(network_requests == 0, "bot result UI must not request network stats")
assert(#MP.end_game_jokers.cards == 1, "bot Joker area should be populated")
assert(#MP.nemesis_cards == 52, "bot deck viewer should be populated")
assert(result.nodes[1].config.button == "mp_return_to_lobby", "bot results must preserve Multiplayer's rematch path")
assert(result.nodes[1].nodes[1].config.text == "Return to Lobby", "return-to-lobby label should be preserved")
assert(result.nodes[2].config.button == "multibots_main_menu", "leave-lobby should become Main Menu")
assert(result.nodes[2].nodes[1].config.text == "Main Menu", "Main Menu label should be replaced")

G.FUNCS.multibots_main_menu()
assert(bot_resets == 1,
	"leaving bot matchmaking must still tear down the finished bot peer")

print("endgame_install_spec: ok")
