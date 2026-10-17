local BotUI = {}

local function text_node(text, scale, colour)
	return {
		n = G.UIT.T,
		config = { text = tostring(text), scale = scale or 0.4, colour = colour or G.C.UI.TEXT_LIGHT, shadow = true },
	}
end

local function row(label, value, colour)
	return {
		n = G.UIT.R,
		config = { align = "cm", padding = 0.08, minw = 8 },
		nodes = {
			{ n = G.UIT.C, config = { align = "cl", minw = 3.5 }, nodes = { text_node(label, 0.4) } },
			{ n = G.UIT.C, config = { align = "cr", minw = 4.5 }, nodes = { text_node(value, 0.4, colour) } },
		},
	}
end

local function score_text(value)
	if MP.INSANE_INT and value then return MP.INSANE_INT.to_string(value) end
	return "0"
end

local function current_bot_state()
	local replay = MP.GHOST.replay or {}
	local simulation = replay._multibots_state or {}
	local ante = G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante or 1
	return simulation.ante_states and (simulation.ante_states[ante] or simulation.ante_states[#simulation.ante_states]) or {}
end

local function bot_highest_score()
	local replay = MP.GHOST.replay or {}
	local ante = G.GAME and G.GAME.round_resets and G.GAME.round_resets.ante or 1
	local snapshot = replay.ante_snapshots and replay.ante_snapshots[ante]
	local highest = 0
	for _, hand in ipairs((snapshot and snapshot.hands) or {}) do
		highest = math.max(highest, tonumber(hand.score) or 0)
	end
	return number_format(highest)
end

function BotUI.players()
	local replay = MP.GHOST.replay or {}
	local player_name = MP.LOBBY.username or "Player"
	local bot_name = replay.nemesis_name or "MultiBot"
	return {
		n = G.UIT.ROOT,
		config = { align = "cm", minw = 10, minh = 5.5, padding = 0.2, r = 0.1, colour = G.C.BLACK },
		nodes = {
			row(player_name, tostring(MP.GAME.lives or 0) .. " " .. localize("k_lives"), G.C.GREEN),
			row("Highest score", score_text(MP.GAME.highest_score), G.C.FILTER),
			{ n = G.UIT.B, config = { w = 0.1, h = 0.25 } },
			row(bot_name, tostring((MP.GAME.enemy and MP.GAME.enemy.lives) or 0) .. " " .. localize("k_lives"), G.C.RED),
			row("Current location", (MP.GAME.enemy and MP.GAME.enemy.location) or "Unknown", G.C.BLUE),
			row("Projected score", bot_highest_score(), G.C.FILTER),
		},
	}
end

function BotUI.settings()
	local replay = MP.GHOST.replay or {}
	local difficulty = replay._multibots_difficulty or "normal"
	local pace = replay._multibots_pace or "standard"
	local ruleset = (replay.ruleset or "ruleset_mp_blitz"):gsub("^ruleset_mp_", "")
	local bot_state = current_bot_state()
	return {
		n = G.UIT.ROOT,
		config = { align = "cm", minw = 10, minh = 5.5, padding = 0.2, r = 0.1, colour = G.C.BLACK },
			nodes = {
			row("Ruleset", ruleset),
			row("Gamemode", "Attrition"),
			row("Difficulty", difficulty:sub(1, 1):upper() .. difficulty:sub(2), G.C.PURPLE),
			row("Bot pace", pace:sub(1, 1):upper() .. pace:sub(2), G.C.BLUE),
			row("Player seed", replay.seed or "?"),
			row("Bot seed", replay._multibots_bot_seed or replay.seed or "?"),
			row("The Order", replay._multibots_state and replay._multibots_state.the_order and "On" or "Off"),
			row("Bot money", "$" .. tostring(bot_state.money or 0), G.C.MONEY),
			row("Bot Jokers", tostring(#(bot_state.jokers or {})) .. "/5", G.C.ORANGE),
		},
	}
end

function BotUI.definition()
	return create_UIBox_generic_options({
		contents = {
			create_tabs({
				tabs = {
					{ label = localize("b_players"), chosen = true, tab_definition_function = BotUI.players },
					{ label = localize("b_lobby_info"), tab_definition_function = BotUI.settings },
				},
				tab_h = 8,
				snap_to_nav = true,
			}),
		},
	})
end

local function find_node_by_id(node, id)
	if type(node) ~= "table" then return nil end
	if node.config and node.config.id == id then return node end
	for _, child in ipairs(node.nodes or {}) do
		local found = find_node_by_id(child, id)
		if found then return found end
	end
	return nil
end

local function hud_info_button()
	local label = localize("ml_lobby_info")
	if type(label) ~= "table" then label = { tostring(label), "" } end
	return {
		n = G.UIT.R,
		config = {
			id = "multibots_info_button",
			align = "cm",
			minh = 1.2,
			minw = 1.5,
			padding = 0.05,
			r = 0.1,
			hover = true,
			colour = G.C.BLUE,
			button = "multibots_info",
			shadow = true,
		},
		nodes = {
			{
				n = G.UIT.R,
				config = { align = "cm", padding = 0, maxw = 1.4 },
				nodes = { text_node(label[1], 0.48) },
			},
			{
				n = G.UIT.R,
				config = { align = "cm", padding = 0, maxw = 1.4 },
				nodes = { text_node(label[2], 0.4) },
			},
		},
	}
end

local function make_bot_hud_match_multiplayer(definition)
	if not MULTIBOTS.is_active() then return definition end
	local button_area = find_node_by_id(definition, "button_area")
	if not button_area then return definition end
	local buttons = {}
	for _, node in ipairs(button_area.nodes or {}) do
		local id = node and node.config and node.config.id
		if id ~= "practice_collection_button" and id ~= "multibots_info_button" then buttons[#buttons + 1] = node end
	end
	buttons[#buttons + 1] = hud_info_button()
	button_area.nodes = buttons
	return definition
end

function BotUI.install()
	G.FUNCS.multibots_info = function(e)
		G.SETTINGS.paused = true
		G.FUNCS.overlay_menu({ definition = BotUI.definition() })
	end

	-- Multiplayer's practice mode adds a Collection button. A bot match should
	-- look like a real lobby instead, so edit the completed HUD definition:
	-- retain Run Info and Options, remove Collection, and add Lobby Info.
	local create_hud_ref = create_UIBox_HUD
	function create_UIBox_HUD(...)
		return make_bot_hud_match_multiplayer(create_hud_ref(...))
	end
end

return BotUI
