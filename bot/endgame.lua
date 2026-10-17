local Endgame = {}

local suit_prefixes = { "S", "H", "C", "D" }
local rank_suffixes = { "2", "3", "4", "5", "6", "7", "8", "9", "T", "J", "Q", "K", "A" }

local function is_active()
	return MP
		and MP.GHOST
		and MP.GHOST.is_active()
		and MP.GHOST.replay
		and MP.GHOST.replay._multibots == true
end

function Endgame.deck_front_keys()
	local keys = {}
	for _, suit in ipairs(suit_prefixes) do
		for _, rank in ipairs(rank_suffixes) do keys[#keys + 1] = suit .. "_" .. rank end
	end
	return keys
end

function Endgame.current_joker_keys(replay, ante)
	local simulation = replay and replay._multibots_state or {}
	local ante_states = simulation.ante_states or {}
	local state = ante_states[ante] or ante_states[tostring(ante)]
	local source = state and state.jokers or simulation.jokers or {}
	local keys = {}
	for _, key in ipairs(source) do keys[#keys + 1] = key end
	return keys
end

local function clear_cards(area)
	if not area then return end
	if area.cards then remove_all(area.cards) end
	area.cards = {}
	area.highlighted = {}
	area.config.card_count = 0
end

local function populate_jokers()
	local area = MP.end_game_jokers
	if not area then return end
	clear_cards(area)

	local ante = G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante or 1
	for _, key in ipairs(Endgame.current_joker_keys(MP.GHOST.replay, ante)) do
		local center = G.P_CENTERS[key]
		if center then
			local card = Card(area.T.x, area.T.y, G.CARD_W, G.CARD_H, nil, center, {
				bypass_discovery_center = true,
				bypass_discovery_ui = true,
				bypass_lock = true,
			})
			-- These are display copies. They must never run add/remove-from-deck
			-- effects when the Multiplayer UI toggles between both players.
			card.added_to_deck = false
			area:emplace(card)
		end
	end
end

local function populate_deck()
	local area = MP.nemesis_deck
	if not area or not MP.nemesis_cards then return end
	clear_cards(area)
	for key in pairs(MP.nemesis_cards) do MP.nemesis_cards[key] = nil end

	for index, front_key in ipairs(Endgame.deck_front_keys()) do
		local front = G.P_CARDS[front_key]
		if front then
			local card = Card(area.T.x, area.T.y, G.CARD_W, G.CARD_H, front, G.P_CENTERS.c_base, {
				playing_card = -index,
				viewed_back = true,
				bypass_discovery_center = true,
				bypass_discovery_ui = true,
			})
			area:emplace(card)
			MP.nemesis_cards[#MP.nemesis_cards + 1] = card
		end
	end
end

local function replace_text(node, text)
	if type(node) ~= "table" then return end
	if node.n == G.UIT.T and node.config then node.config.text = text end
	for _, child in ipairs(node.nodes or {}) do replace_text(child, text) end
end

local function replace_button(node, old_button, new_button, text)
	if type(node) ~= "table" then return end
	if node.config and node.config.button == old_button then
		node.config.button = new_button
		replace_text(node, text)
	end
	for _, child in ipairs(node.nodes or {}) do replace_button(child, old_button, new_button, text) end
end

local function prepare()
	-- Mark both payloads as present so Multiplayer invokes its loaders instead
	-- of sending requests to a lobby that intentionally does not exist.
	MP.end_game_jokers_received = true
	MP.nemesis_deck_received = true
	MP.end_game_jokers_payload = nil
	MP.nemesis_deck_string = nil
end

local function reset_bot_session()
	if MULTIBOTS and MULTIBOTS.peer and type(MULTIBOTS.peer.reset) == "function" then
		MULTIBOTS.peer.reset(true)
	end
end

function Endgame.install()
	local load_jokers_ref = G.FUNCS.load_end_game_jokers
	function G.FUNCS.load_end_game_jokers(...)
		if is_active() then return populate_jokers() end
		return load_jokers_ref(...)
	end

	local load_deck_ref = G.FUNCS.load_nemesis_deck
	function G.FUNCS.load_nemesis_deck(...)
		if is_active() then return populate_deck() end
		return load_deck_ref(...)
	end

	local request_stats_ref = MP.ACTIONS.request_nemesis_stats
	function MP.ACTIONS.request_nemesis_stats(...)
		if is_active() then return end
		return request_stats_ref(...)
	end

	local game_over_ref = create_UIBox_game_over
	function create_UIBox_game_over(...)
		if not is_active() then return game_over_ref(...) end
		prepare()
		local result = MP.UI.create_UIBox_mp_game_end(false)
		replace_button(result, "lobby_leave", "multibots_main_menu", localize("b_main_menu"))
		return result
	end

	local win_ref = create_UIBox_win
	function create_UIBox_win(...)
		if not is_active() then return win_ref(...) end
		prepare()
		local result = MP.UI.create_UIBox_mp_game_end(true)
		replace_button(result, "lobby_leave", "multibots_main_menu", localize("b_main_menu"))
		return result
	end

	function G.FUNCS.multibots_new_run(e)
		reset_bot_session()
		MP.GHOST.clear()
		MP.end_game_jokers_received = false
		MP.nemesis_deck_received = false
		G.FUNCS.setup_practice_mode(e)
	end

	function G.FUNCS.multibots_main_menu(e)
		reset_bot_session()
		MP.GHOST.clear()
		MP.end_game_jokers_received = false
		MP.nemesis_deck_received = false
		G.FUNCS.go_to_menu(e)
	end
end

return Endgame
