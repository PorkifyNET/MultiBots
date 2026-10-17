local json = require("json")

local Peer = {
	dependencies = nil,
	pending = nil,
	replay = nil,
	run = nil,
	transport = nil,
	local_server = nil,
	thread = nil,
	incoming = nil,
	outgoing = nil,
	running = false,
	in_game = false,
	pvp = false,
	joined_sent = false,
	ready_sent = false,
	rematch_ready_sent = false,
	terminal_logged = false,
	ante = nil,
	phase = 1,
	elapsed = 0,
	bot_hand_index = 0,
	bot_hands = 4,
	player_hands = 4,
	pvp_session = nil,
	playing_hand = false,
	player_lives_by_id = {},
	pvp_scores_by_id = {},
	last_pvp_scores_by_id = {},
	human_players_seen = false,
	fallback_pending = false,
	previous_host_id = nil,
	host_recovery_attempted = false,
	spectator_outbox = {},
	spectator_waiting_step = nil,
}

local function shallow_copy(message)
	local result = {}
	for key, value in pairs(message or {}) do result[key] = value end
	return result
end

local function protocol_v2()
	return MP and MP.PROTOCOL and tonumber(MP.PROTOCOL.VERSION) == 2
end

local function lobby_client()
	return MP and MP.LOBBY and (MP.LOBBY.client or MP.LOBBY) or {}
end

local function packet(family, schema_action, action, payload)
	if MP.PROTOCOL and MP.PROTOCOL.build_v2_packet_for_schema then
		return MP.PROTOCOL.build_v2_packet_for_schema(family, schema_action, action, payload)
	end
	return { version = 2, family = family, action = action, payload = payload or {} }
end

local function v2_message(message)
	local action = message.action
	if action == "username" then
		return packet("system", "hello", "identity", {
			username = message.username, blindCol = message.blindCol,
			modHash = message.modHash,
		})
	elseif action == "version" then
		return packet("system", "hello", "hello", { version = message.version })
	elseif action == "joinLobby" then
		return packet("lobby", "intent", "join", { code = message.code })
	elseif action == "readyLobby" then
		return packet("lobby", "intent", "ready")
	elseif action == "readyBlind" then
		return packet("match", "intent", "readyBlind", {
			blindRow = message.blindRow or "Boss", blindKind = message.blindKind or "pvp",
			handsLeft = message.handsLeft or Peer.bot_hands,
		})
	elseif action == "soldJoker" or action == "asteroid" or action == "letsGoGamblingNemesis" then
		return packet("feature", "event", action)
	elseif action == "receiveEndGameJokers" then
		return packet("endgame", "state", action, {
			keys = message.keys, sourcePlayerId = Peer.player_id,
			requesterPlayerId = Peer.endgame_requester,
		})
	elseif action == "receiveNemesisDeck" then
		return packet("endgame", "state", action, {
			cards = message.cards, sourcePlayerId = Peer.player_id,
			requesterPlayerId = Peer.endgame_requester,
		})
	elseif action == "nemesisEndGameStats" then
		return nil
	elseif action == "spectatorProvideSnapshot" then
		return packet("feature", "event", action, {
			spectatorPlayerId = message.spectatorPlayerId,
			targetPlayerId = Peer.player_id,
			snapshotData = message.snapshotData,
		})
	elseif action == "spectatorActionStream" then
		return packet("feature", "event", action, {
			actionData = message.actionData,
			stepIndex = message.stepIndex,
		})
	elseif action == "makePlayerHost" then
		return packet("lobby", "intent", "makeHost", { playerId = message.playerId })
	elseif action == "kickPlayer" then
		return packet("lobby", "intent", "kick", { playerId = message.playerId })
	elseif action == "lobbyInfo" then
		return nil
	end
	local payload = {}
	for key, value in pairs(message) do if key ~= "action" then payload[key] = value end end
	return packet("match", "intent", action, payload)
end

local function legacy_message(message)
	if not protocol_v2() or type(message) ~= "table" or not message.family then return message end
	local payload = shallow_copy(message.payload)
	local action = message.action
	if message.family == "system" and action == "connected" then action = "connected"
	elseif message.family == "system" and action == "requestVersion" then action = "version"
	elseif message.family == "system" and action == "error" then action = "multibotsTransportError"
	elseif message.family == "lobby" and action == "joined" then
		action = "joinedLobby"
		Peer.player_id = payload.playerId
		Peer.pending.options = shallow_copy(payload.options)
		for _, player in ipairs(payload.players or {}) do
			if player.id == Peer.player_id then Peer.nemesis_id = player.nemesisPlayerId end
		end
	elseif message.family == "lobby" and action == "options" then
		action = "lobbyOptions"
		payload = shallow_copy(payload.options or payload)
	elseif message.family == "lobby" and action == "snapshot" then
		for _, player in ipairs(payload.players or {}) do
			if player.id == Peer.player_id then Peer.nemesis_id = player.nemesisPlayerId end
		end
		action = Peer.terminal_logged and payload.isInGame == false and "stopGame" or "lobbyInfo"
	elseif message.family == "lobby" and action == "playerLeft" then
		action = "lobbyPlayerLeft"
	elseif message.family == "lobby" and action == "kicked" then
		action = "multibotsKicked"
	elseif message.family == "match" and action == "endPvp" then action = "endPvP"
	elseif message.family == "endgame" and action == "win" then action = "winGame"
	elseif message.family == "endgame" and action == "lose" then action = "loseGame"
	elseif message.family == "endgame" and action == "alone" then action = "aloneGame"
	elseif message.family == "endgame" and action == "getEndGameJokers" then
		action = "getEndGameJokers"; Peer.endgame_requester = payload.requesterPlayerId
	elseif message.family == "endgame" and action == "getNemesisDeck" then
		action = "getNemesisDeck"; Peer.endgame_requester = payload.requesterPlayerId
	end
	payload.action = action
	return payload
end

local function random_string_safe(length)
	if type(random_string) == "function" then return random_string(length) end
	local out = {}
	for index = 1, length do out[index] = string.char(math.random(65, 90)) end
	return table.concat(out)
end

local function copy_message(message)
	return shallow_copy(message)
end

local function strategy_debug_enabled()
	return SMODS and SMODS.Mods and SMODS.Mods.MultiBots and SMODS.Mods.MultiBots.config
		and SMODS.Mods.MultiBots.config.logging
		and SMODS.Mods.MultiBots.config.logging.technical_debug == true
end

local function bot_name()
	local difficulty = Peer.pending and Peer.pending.difficulty or "normal"
	local definition = Peer.dependencies.Generator.difficulties[difficulty]
	local visible = Peer.pending and Peer.pending.name
		or "MultiBot (" .. (definition and definition.name or "Normal") .. ")"
	if protocol_v2() then return visible end
	return visible .. "~" .. tostring((Peer.pending and Peer.pending.bot_blind_col) or 2)
end

local function human_name()
	local client = lobby_client()
	return tostring(client.username or "Player") .. "~" .. tostring(client.blind_col or 1)
end

local function configured_endpoint()
	local multiplayer = protocol_v2() and SMODS.Mods["MultiplayerExperimental"]
		or SMODS.Mods["Multiplayer"] or SMODS.Mods["MultiplayerExperimental"]
	local environment = MP.ENV or {}
	local config = multiplayer and multiplayer.config or {}
	return environment.server_url or config.server_url,
		tonumber(environment.server_port) or tonumber(config.server_port) or 8788
end

function Peer.send(message)
	if Peer.transport == "local" then
		return Peer.local_server:receive("guest", copy_message(message))
	end
	if protocol_v2() then message = v2_message(message) end
	if message and Peer.outgoing then Peer.outgoing:push(json.encode(message)) end
end

local function send_identity()
	Peer.send({
		action = "username", username = bot_name(),
		blindCol = (Peer.pending and Peer.pending.bot_blind_col) or 2,
		modHash = MP.MOD_STRING,
	})
	Peer.send({ action = "version", version = MULTIPLAYER_VERSION or MP.version or "" })
end

local function start_remote(code)
	local source_chunk = assert(SMODS.load_file("bot/socket_thread.lua", "MultiBots"))
	local source = source_chunk()
	local nonce = tostring(love.timer.getTime()):gsub("%D", "")
	local incoming_name = "multibotsBotToUi" .. nonce
	local outgoing_name = "multibotsUiToBot" .. nonce
	Peer.incoming = love.thread.getChannel(incoming_name)
	Peer.outgoing = love.thread.getChannel(outgoing_name)
	Peer.incoming:clear()
	Peer.outgoing:clear()
	Peer.thread = love.thread.newThread(source)
	local host, port = configured_endpoint()
	Peer.transport = "remote"
	Peer.running = true
	Peer.thread:start(host, port, incoming_name, outgoing_name)
	Peer.pending.code = code
end

local function inject_human(message)
	love.thread.getChannel("networkToUi"):push(json.encode(message))
end

local function start_local()
	local LocalServer = Peer.dependencies.LocalServer
	Peer.transport = "local"
	Peer.running = true
	Peer.local_server = LocalServer.new(inject_human, function(message) Peer.handle(message) end,
		function() return "BOT" .. random_string_safe(2) end, function() return random_string_safe(8) end)
	Peer.local_server:receive("guest", { action = "username", username = bot_name(), modHash = MP.MOD_STRING })
	Peer.local_server:receive("guest", { action = "version", version = MULTIPLAYER_VERSION })
	inject_human({ action = "connected" })
	inject_human({ action = "version" })
end

local function current_jokers()
	if Peer.run then return Peer.run.jokers or {} end
	local state = Peer.replay and Peer.replay._multibots_state or {}
	local ante_state = state.ante_states and (state.ante_states[Peer.ante] or state.ante_states[tostring(Peer.ante)])
	return ante_state and ante_state.jokers or state.jokers or {}
end

local function current_joker_editions()
	if Peer.run then return Peer.run.joker_editions or {} end
	local state = Peer.replay and Peer.replay._multibots_state or {}
	local ante_state = state.ante_states and (state.ante_states[Peer.ante] or state.ante_states[tostring(Peer.ante)])
	return ante_state and ante_state.joker_editions or state.joker_editions or {}
end

local function current_deck()
	if Peer.run then return Peer.run.deck or {} end
	local state = Peer.replay and Peer.replay._multibots_state or {}
	local ante_state = state.ante_states and (state.ante_states[Peer.ante] or state.ante_states[tostring(Peer.ante)])
	return ante_state and ante_state.deck or state.deck or {}
end

local spectator_rank_names = {
	[11] = "Jack", [12] = "Queen", [13] = "King", [14] = "Ace",
}

local function spectator_card(card, sort_id)
	if not card then return nil end
	local rank = tonumber(card.rank) or 2
	return {
		suit = card.suit or "Spades",
		value = spectator_rank_names[rank] or tostring(rank),
		id = rank,
		nominal = rank == 14 and 11 or math.min(rank, 10),
		center_key = card.enhancement and card.enhancement ~= "none" and card.enhancement or nil,
		edition = card.edition and card.edition ~= "none" and card.edition or nil,
		seal = card.seal and card.seal ~= "none" and card.seal or nil,
		mp_card_id = tostring(card.id or sort_id),
		sort_id = sort_id,
	}
end

local function spectator_cards(cards)
	local result = {}
	for index, card in ipairs(cards or {}) do result[#result + 1] = spectator_card(card, index) end
	return result
end

local function current_phase_result(phase)
	if Peer.pvp_session then return Peer.pvp_session, Peer.pvp_result end
	if not phase then return nil, nil end
	if phase.blind == "Small" then return nil, Peer.small_result end
	if phase.blind == "Big" then return nil, Peer.big_result end
	if phase.blind == "Boss" then return nil, Peer.boss_result end
	return nil, nil
end

local function spectator_jokers(keys, editions)
	local jokers = {}
	for index, key in ipairs(keys or {}) do
		jokers[#jokers + 1] = {
			key = key,
			edition = (editions and editions[key])
				or (Peer.run and Peer.run.joker_editions and Peer.run.joker_editions[key]),
			sort_id = index,
		}
	end
	return jokers
end


-- Blind size at the lobby's Stake (Green/Purple scale it).
local function blind_base(ante)
	local Simulator = Peer.dependencies.Simulator
	local scaling = Simulator.blind_scaling and Simulator.blind_scaling(Peer.run and Peer.run.stake)
	return Simulator.base_score(ante, scaling)
end
local function spectator_board_state(overrides)
	overrides = overrides or {}
	local run = Peer.run
	if not run then return nil end
	local phase = Peer.timeline and Peer.timeline[Peer.phase]
	local session, result = current_phase_result(phase)
	local pvp = Peer.pvp_session ~= nil or Peer.pvp == true
	local blind_name = pvp and "Boss" or (phase and phase.blind) or "Small"
	local blind_key = pvp and "bl_mp_nemesis" or (blind_name == "Big" and "bl_big" or "bl_small")
	local target = pvp and tonumber(Peer.player_score) or blind_base(Peer.ante or 1)
	if blind_name == "Big" then target = target * 1.5
	elseif blind_name == "Boss" and not pvp then target = target * 2 end

	local jokers = spectator_jokers(run.jokers)
	local consumeables = {}
	for index, consumable in ipairs(run.consumables or {}) do
		consumeables[#consumeables + 1] = {
			key = consumable.key or consumable, edition = consumable.edition, sort_id = index,
		}
	end
	local hands = {}
	for name, level in pairs(run.levels or {}) do hands[name] = { level = tonumber(level) or 1 } end

	local phase_type = phase and phase.type
	local snapshot_state = G and G.STATES and (
		phase_type == "loc_shop" and G.STATES.SHOP
		or phase_type == "loc_ready" and G.STATES.BLIND_SELECT
		or G.STATES.SELECTING_HAND
	)
	local shop_cards = {}
	local shop_area_counts = {}
	for _, key in ipairs(Peer.spectator_shop_cards or {}) do
		local area = tostring(key):match("^p_") and "shop_booster"
			or (tostring(key):match("^v_") and "shop_vouchers" or "shop_jokers")
		shop_area_counts[area] = (shop_area_counts[area] or 0) + 1
		shop_cards[#shop_cards + 1] = {
			area = area, index = shop_area_counts[area], key = key, sort_id = #shop_cards + 1,
		}
	end
	local board = {
		step = Peer.spectator_step or 0,
		state = snapshot_state,
		dollars = tonumber(run.money) or 0,
		chips = tonumber(session and session.cumulative or result and result.score) or 0,
		ante = tonumber(Peer.ante or run.ante) or 1,
		blind_ante = tonumber(Peer.ante or run.ante) or 1,
		round = tonumber(run.round) or 1,
		hands = hands,
		base_hands = tonumber(run.hands_per_round) or 4,
		base_discards = tonumber(run.discards_per_round) or 3,
		hands_left = tonumber(session and session.hands_left or result and result.hands_left) or 0,
		hands_played = tonumber(run.hands_played) or 0,
		discards_left = tonumber(session and session.discards_left or result and result.discards_left)
			or tonumber(run.discards_per_round) or 3,
		jokers = jokers,
		consumeables = consumeables,
		consumeable_slots = tonumber(run.consumable_limit) or 2,
		joker_slots = tonumber(run.joker_limit) or 5,
		hand_size = #(run.hand or {}),
		hand = spectator_cards(run.hand),
		deck = spectator_cards(run.draw_pile or run.deck),
		discard = spectator_cards(run.used_cards),
		shop_cards = shop_cards,
		deck_size = #(run.deck or {}),
		blind_on_deck = blind_name,
		blind = {
			key = blind_key, name = blind_key, chips = target,
			chip_text = tostring(math.floor(target)), boss = blind_name == "Boss",
		},
		location = "loc_playing",
		pvp_enemy = pvp and {
			score_text = tostring(Peer.player_score or 0), hands = tonumber(Peer.player_hands) or 0,
			username = "Opponent",
		} or nil,
	}
	for key, value in pairs(overrides) do board[key] = value end
	return board
end

local function send_spectator_snapshot(spectator_player_id, overrides, shared_step)
	if not (protocol_v2() and spectator_player_id and Peer.run) then return false end
	local built, board_state = pcall(spectator_board_state, overrides)
	if not built or not board_state then return false end
	-- A one-recipient catch-up snapshot describes the latest published step; it
	-- must not consume a new global sequence number or other watchers see a gap.
	board_state.step = shared_step or (Peer.spectator_step or 0)
	local ok, snapshot_data = pcall(json.encode, board_state)
	if not ok or not snapshot_data then return false end
	Peer.send({
		action = "spectatorProvideSnapshot",
		spectatorPlayerId = spectator_player_id,
		snapshotData = snapshot_data,
	})
	return true
end

local function has_spectator_watchers()
	return next(Peer.spectator_watchers or {}) ~= nil
end

local function queue_spectator_snapshot(overrides)
	if not (protocol_v2() and has_spectator_watchers() and Peer.run) then return false end
	local step = (Peer.spectator_step or 0) + 1
	local built, board_state = pcall(spectator_board_state, overrides)
	if not built or not board_state then return false end
	board_state.step = step
	local ok, snapshot_data = pcall(json.encode, board_state)
	if not ok or not snapshot_data then return false end
	Peer.spectator_step = step
	Peer.spectator_outbox = Peer.spectator_outbox or {}
	Peer.spectator_outbox[#Peer.spectator_outbox + 1] = {
		kind = "snapshot", step = step, snapshot_data = snapshot_data,
	}
	return true
end

local function broadcast_spectator_snapshot(overrides)
	if not next(Peer.spectator_watchers or {}) then return end
	queue_spectator_snapshot(overrides)
end

local function send_spectator_action(action_type, data)
	if not (protocol_v2() and has_spectator_watchers()) then return false end
	local step = (Peer.spectator_step or 0) + 1
	local action_entry = { step = step, type = action_type, data = data or {} }
	local ok, action_data = pcall(json.encode, action_entry)
	if not ok then return false end
	Peer.spectator_step = step
	Peer.spectator_outbox = Peer.spectator_outbox or {}
	Peer.spectator_outbox[#Peer.spectator_outbox + 1] = {
		kind = "action", step = step, action_data = action_data,
	}
	return true
end

local function logged_card(card_text, sort_id)
	local fields = {}
	for field in tostring(card_text or ""):gmatch("[^:]+") do fields[#fields + 1] = field end
	local rank = tonumber(fields[3]) or tonumber(tostring(fields[1] or ""):match("%d+")) or 2
	return spectator_card({
		id = fields[1], suit = fields[2], rank = rank,
		enhancement = fields[4] ~= "none" and fields[4] or nil,
		edition = fields[5] ~= "none" and fields[5] or nil,
		seal = fields[6] ~= "none" and fields[6] or nil,
	}, sort_id)
end

local function logged_cards(card_list)
	local cards = {}
	for card_text in tostring(card_list or ""):gmatch("[^,]+") do
		cards[#cards + 1] = logged_card(card_text, #cards + 1)
	end
	return cards
end

local function snapshot_field(snapshot, name)
	for field in tostring(snapshot or ""):gmatch("[^|]+") do
		local key, value = field:match("^([^:]+):(.*)$")
		if key == name then return value end
	end
	return nil
end

local function split_csv(value)
	local values = {}
	for item in tostring(value or ""):gmatch("[^,]+") do
		if item ~= "" and item ~= "none" then values[#values + 1] = item end
	end
	return values
end

local function snapshot_map(value)
	local values = {}
	for item in tostring(value or ""):gmatch("[^,]+") do
		local key, entry = item:match("^([^:]+):(.*)$")
		if key and entry then values[key] = entry end
	end
	return values
end

local function selected_card_indices(hand_text, selected_text)
	local wanted = {}
	for card_text in tostring(selected_text or ""):gmatch("[^,]+") do
		wanted[card_text] = (wanted[card_text] or 0) + 1
	end
	local indices = {}
	local index = 0
	for card_text in tostring(hand_text or ""):gmatch("[^,]+") do
		index = index + 1
		if (wanted[card_text] or 0) > 0 then
			indices[#indices + 1] = index
			wanted[card_text] = wanted[card_text] - 1
		end
	end
	return indices
end

local function stream_hand_decision(decision)
	if not has_spectator_watchers() then return false end
	local action_type = decision.type == "discard" and "DISCARD"
		or (decision.type == "play" and "PLAY_HAND") or nil
	if not action_type then return false end
	local indices = selected_card_indices(decision.hand_contents, decision.selected)
	if #indices == 0 then return false end
	local snapshot = decision.snapshot
	local joker_keys = split_csv(snapshot_field(snapshot, "jokers"))
	local joker_editions = snapshot_map(snapshot_field(snapshot, "joker_editions"))
	local levels = {}
	for hand, level in pairs(snapshot_map(snapshot_field(snapshot, "levels"))) do
		levels[hand] = { level = tonumber(level) or 1 }
	end
	local overrides = {
		state = G and G.STATES and G.STATES.SELECTING_HAND,
		hand = logged_cards(decision.hand_contents),
		discard = logged_cards(snapshot_field(snapshot, "used")),
		chips = tonumber(decision.current_score) or 0,
		hands_left = tonumber(decision.hands_remaining),
		discards_left = tonumber(decision.discards_remaining),
		dollars = tonumber(decision.money),
		jokers = spectator_jokers(joker_keys, joker_editions),
		hands = levels,
		shop_cards = {},
	}
	local draw = snapshot_field(snapshot, "draw")
	if draw then overrides.deck = logged_cards(draw) end
	local consumables = split_csv(snapshot_field(snapshot, "consumables"))
	overrides.consumeables = {}
	for index, key in ipairs(consumables) do
		overrides.consumeables[index] = { key = key, sort_id = index }
	end
	broadcast_spectator_snapshot(overrides)
	return send_spectator_action(action_type, { cards = indices })
end

local function pack_pick_index(decision, key)
	local standard_index = tostring(key):match("^ordered_standard_(%d+)$")
	if standard_index then return tonumber(standard_index) end
	for index, revealed in ipairs(split_csv(decision.revealed)) do
		if revealed == key then return index end
	end
	return 1
end

local function shop_area_and_index(key)
	local wanted_area = tostring(key):match("^p_") and "shop_booster"
		or (tostring(key):match("^v_") and "shop_vouchers" or "shop_jokers")
	local area_index = 0
	for _, offered_key in ipairs(Peer.spectator_shop_cards or {}) do
		local area = tostring(offered_key):match("^p_") and "shop_booster"
			or (tostring(offered_key):match("^v_") and "shop_vouchers" or "shop_jokers")
		if area == wanted_area then area_index = area_index + 1 end
		if offered_key == key then return wanted_area, area_index end
	end
	return wanted_area, 1
end

local function stream_shop_decision(decision)
	if not has_spectator_watchers() then return false end
	if decision.type == "reroll_shop" then return send_spectator_action("REROLL_SHOP", {}) end
	if decision.type == "skip_blind" then
		return send_spectator_action("SKIP_BLIND", { blind_row = decision.blind })
	end
	local key = decision.key or decision.value
	if not key then return false end
	local area, index = shop_area_and_index(key)
	if decision.type == "buy_pack" then
		send_spectator_action("BUY_BOOSTER", { index = index, card_key = key })
		local picked = split_csv(decision.picked)
		if #picked == 0 then
			send_spectator_action("SKIP_PACK", {})
		else
			for _, picked_key in ipairs(picked) do
				send_spectator_action("SELECT_PACK_CARD", {
					index = pack_pick_index(decision, picked_key), card_key = picked_key,
				})
			end
		end
		return true
	elseif decision.type == "buy_joker" or decision.type == "buy_voucher" then
		return send_spectator_action("BUY_CARD", { area = area, index = index, card_key = key })
	end
	return false
end

local function stream_decision_once(decision, index)
	if index <= (Peer.last_spectator_streamed_decision or 0) then return end
	stream_hand_decision(decision)
	stream_shop_decision(decision)
	Peer.last_spectator_streamed_decision = index
end

local function joker_payload()
	if not CardArea or not G.P_CENTERS or not MP.UTILS.str_pack_and_encode then return "" end
	local jokers, joker_editions = current_jokers(), current_joker_editions()
	local capacity = math.max(5, #jokers)
	local area = CardArea(0, 0, capacity * G.CARD_W, G.CARD_H, {
		card_limit = capacity, type = "joker", highlight_limit = 1, fixed_limit = true,
	})
	for _, key in ipairs(jokers) do
		if G.P_CENTERS[key] then
			local card = Card(0, 0, G.CARD_W, G.CARD_H, nil, G.P_CENTERS[key], {
				bypass_discovery_center = true, bypass_discovery_ui = true, bypass_lock = true,
			})
			local edition = joker_editions[key]
			if edition and card.set_edition then card:set_edition({ [edition] = true }, true, true) end
			card.added_to_deck = false
			area:emplace(card)
		end
	end
	local payload = MP.UTILS.str_pack_and_encode(area:save())
	area:remove()
	return payload
end

local function deck_string()
	local cards = {}
	local suits = { Spades = "S", Hearts = "H", Clubs = "C", Diamonds = "D" }
	local ranks = { [10] = "T", [11] = "J", [12] = "Q", [13] = "K", [14] = "A" }
	for _, card in ipairs(current_deck()) do
		local suit = suits[card.suit]
		local rank = ranks[card.rank] or tostring(card.rank)
		if suit then
			cards[#cards + 1] = table.concat({
				suit,
				rank,
				card.enhancement or "none",
				card.edition or "none",
				card.seal or "none",
			}, "-")
		end
	end
	return ";" .. table.concat(cards, ";")
end

local function joined_or_none(values, separator)
	return #values > 0 and table.concat(values, separator) or "none"
end

local function detail_value(value)
	if type(value) == "number" or type(value) == "string" or type(value) == "boolean" then
		return tostring(value)
	end
end

local function bot_joker_details()
	local details, editions = {}, current_joker_editions()
	for _, key in ipairs(current_jokers()) do
		local effect = Peer.run and Peer.run.joker_effects and Peer.run.joker_effects[key] or {}
		local parts = { key, "edition=" .. tostring(editions[key] or "none") }
		if effect.kind then parts[#parts + 1] = "effect=" .. tostring(effect.kind) end
		local scaling = Peer.run and Peer.run.joker_state and detail_value(Peer.run.joker_state[key])
		if scaling then parts[#parts + 1] = "scaling=" .. scaling end
		local target = Peer.run and Peer.run.joker_targets and detail_value(Peer.run.joker_targets[key])
		if target then
			parts[#parts + 1] = "target=" .. target
		elseif effect.rank then
			parts[#parts + 1] = "target_rank=" .. tostring(effect.rank)
		elseif effect.suit then
			parts[#parts + 1] = "target_suit=" .. tostring(effect.suit)
		elseif effect.hand then
			parts[#parts + 1] = "target_hand=" .. tostring(effect.hand)
		end
		details[#details + 1] = table.concat(parts, " ")
	end
	return joined_or_none(details, ",")
end

local function player_joker_detail(card, encoded)
	local key = card and card.config and card.config.center and card.config.center.key
	local parts = { tostring(key or encoded or "unknown") }
	if encoded and encoded ~= key then parts[#parts + 1] = "encoded=" .. tostring(encoded) end
	local center = card and card.config and card.config.center
	local config = center and center.config or {}
	local ability = card and card.ability or {}
	local extra = detail_value(ability.extra) or detail_value(config.extra)
	if extra then parts[#parts + 1] = "scaling=" .. extra end
	if config.rank then parts[#parts + 1] = "target_rank=" .. tostring(config.rank) end
	if config.suit then parts[#parts + 1] = "target_suit=" .. tostring(config.suit) end
	if config.hand_type then parts[#parts + 1] = "target_hand=" .. tostring(config.hand_type) end
	return table.concat(parts, " ")
end

local function final_bot_snapshot()
	local jokers, editions = {}, current_joker_editions()
	for _, key in ipairs(current_jokers()) do
		local edition = editions[key]
		jokers[#jokers + 1] = key .. (edition and ("@" .. edition) or "")
	end
	return {
		jokers = joined_or_none(jokers, ","),
		joker_details = bot_joker_details(),
		consumables = joined_or_none((function()
			local keys = {}
			for _, consumable in ipairs(Peer.run and Peer.run.consumables or {}) do
				keys[#keys + 1] = consumable.key
			end
			return keys
		end)(), ","),
		deck_count = #current_deck(),
		deck = deck_string():gsub("^;", ""),
	}
end

local function final_player_snapshot()
	local jokers, joker_details, deck = {}, {}, {}
	for _, card in ipairs(G.jokers and G.jokers.cards or {}) do
		local value
		if MP.UTILS and type(MP.UTILS.joker_to_string) == "function" then
			local ok, encoded = pcall(MP.UTILS.joker_to_string, card)
			if ok then value = encoded end
		end
		if not value or value == "" then
			value = card and card.config and card.config.center and card.config.center.key
		end
		if value and value ~= "" then
			jokers[#jokers + 1] = value
			joker_details[#joker_details + 1] = player_joker_detail(card, value)
		end
	end
	for _, card in ipairs(G.playing_cards or {}) do
		local value
		if MP.UTILS and type(MP.UTILS.card_to_string) == "function" then
			local ok, encoded = pcall(MP.UTILS.card_to_string, card)
			if ok then value = encoded end
		end
		-- Multiplayer serializes an unenhanced card as c_base while the headless
		-- deck uses none. Normalize only the enhancement field for easy diffing.
		if value then value = value:gsub("%-c_base%-", "-none-") end
		if value and value ~= "" then deck[#deck + 1] = value end
	end
	return {
		jokers = joined_or_none(jokers, ","),
		joker_details = joined_or_none(joker_details, ","),
		deck_count = #deck,
		deck = joined_or_none(deck, ";"),
	}
end

local function build_replay(message)
	local options = Peer.local_server and Peer.local_server.options
		or (protocol_v2() and Peer.pending and Peer.pending.options)
		or MP.LOBBY.config
	options = options or {}
	local seed = message.seed or random_string_safe(8)
	local bot_seed = options.different_seeds and random_string_safe(8) or seed
	if protocol_v2() then
		-- Each headless peer needs its own deterministic run. Reusing the lobby
		-- seed made equal-difficulty bots make identical decisions and tie forever.
		bot_seed = tostring(bot_seed) .. ":" .. tostring(Peer.player_id or Peer.pending.name)
	end
	local order_seed = options.different_seeds and bot_seed or seed
	if options.the_order ~= false and bot_seed:sub(1, 1) ~= "*" then bot_seed = "*" .. bot_seed end
	if options.the_order ~= false and tostring(order_seed):sub(1, 1) ~= "*" then
		order_seed = "*" .. tostring(order_seed)
	end
	local banned = G.GAME and G.GAME.banned_keys or {}
	local catalog = Peer.dependencies.Content.build(G.P_CENTER_POOLS or {}, G.P_CENTERS or {}, banned)
	local content_summary = Peer.dependencies.Content.summary(catalog)
	sendInfoMessage(string.format(
		"HEADLESS_CONTENT jokers=%d planets=%d deck_tools=%d packs=%d unsupported=%d%s",
		content_summary.jokers,
		content_summary.planets,
		content_summary.deck_tools,
		content_summary.packs,
		content_summary.skipped,
		#content_summary.examples > 0 and " examples=" .. table.concat(content_summary.examples, ",") or ""
	), "MULTIBOTS")
	Peer.run = Peer.dependencies.Simulator.new({
		difficulty = Peer.pending.difficulty,
		decision_temperature = Peer.pending.decision_temperature,
		weights = Peer.pending.strategy_weights,
		seed = bot_seed,
		deck = options.back or "Red Deck",
		the_order = options.the_order ~= false,
		banned_jokers = banned,
		content_catalog = catalog,
		-- The bot owns a complete Order state: top-level shops and unopened
		-- Booster contents are generated from its queues, never the host's UI.
		strict_order_content = options.the_order ~= false,
		no_gold_on_round_loss = options.no_gold_on_round_loss == true,
		gold_on_life_loss = options.gold_on_life_loss ~= false,
		death_on_round_loss = options.death_on_round_loss ~= false,
		stake = tonumber(message.stake) or (G.GAME and tonumber(G.GAME.stake)) or 1,
		ruleset = options.ruleset or (Peer.pending and Peer.pending.ruleset),
	}, Peer.dependencies.Expert.modules(Peer.dependencies))
	Peer.dependencies.Order.clear()
	-- A new game: the host's tag queue is read again at the bot's first Ante.
	Peer.blind_tag_seed, Peer.blind_tags_trusted = nil, nil
	if Peer.dependencies.Order.begin_run then
		local order_state = Peer.dependencies.Order.begin_run(Peer.run, order_seed)
		if not order_state then
			sendWarnMessage("Could not initialize the bot's private Order queues", "MULTIBOTS")
		end
	end
	if Peer.dependencies.Logger then
		local logging = SMODS.Mods.MultiBots and SMODS.Mods.MultiBots.config
			and SMODS.Mods.MultiBots.config.logging or {}
		Peer.dependencies.Logger.start({
			version = SMODS.Mods.MultiBots and SMODS.Mods.MultiBots.version,
			seed = seed, bot_seed = bot_seed, difficulty = Peer.pending.difficulty,
			decision_temperature = Peer.pending.decision_temperature,
			name = Peer.pending.name, ruleset = options.ruleset,
			weight_profile = Peer.pending.strategy_weight_profile or "defaults",
			order = options.the_order ~= false, stake = tonumber(message.stake) or options.stake or 1,
			jokers = content_summary.jokers, deck_tools = content_summary.deck_tools,
			unsupported = content_summary.skipped,
			high_regret_threshold = logging.high_regret_threshold or 25,
			score_variance_ratio = logging.score_variance_ratio or 4,
			reorder_threshold = logging.reorder_threshold or 3,
		})
	end
	Peer.pvp_start_ante = tonumber(options.pvp_start_round) or 2
	Peer.replay = {
		seed = seed,
		nemesis_name = Peer.pending.name,
		ante_snapshots = {},
		_multibots = true,
		_multibots_live = true,
		_multibots_difficulty = Peer.pending.difficulty,
		_multibots_decision_temperature = Peer.pending.decision_temperature,
		_multibots_name_mode = Peer.pending.name_mode,
		_multibots_pace = Peer.pending.pace,
		_multibots_behavior = Peer.pending.behavior,
		_multibots_state = Peer.dependencies.Simulator.export(Peer.run, {}),
	}
	Peer.in_game = true
	Peer.rematch_ready_sent = false
	Peer.terminal_logged = false
	Peer.ante = nil
	Peer.pvp = false
	Peer.bot_skips = 0
	Peer.skips_since_pvp = 0
	Peer.timer_enabled = options.timer ~= false
	Peer.last_spectator_streamed_decision = 0
	Peer.spectator_shop_cards = {}
end

local function sync_live_state()
	if not Peer.run or not Peer.replay then return end
	local previous = Peer.replay._multibots_state and Peer.replay._multibots_state.ante_states or {}
	Peer.replay._multibots_state = Peer.dependencies.Simulator.export(Peer.run, previous)
end

local function log_new_decisions(first_index)
	if not Peer.run then return end
	for index = first_index, #Peer.run.decisions do
		local decision = Peer.run.decisions[index]
		stream_decision_once(decision, index)
		if decision.type == "sell_joker" then Peer.send({ action = "soldJoker" }) end
		if decision.type == "fail_round" then Peer.send({ action = "failRound" }) end
		if decision.type == "use_consumable" and decision.key == "c_mp_asteroid" then
			Peer.send({ action = "asteroid" })
		end
		local details = decision.key or decision.hand or decision.blind or decision.count or ""
		if decision.type == "reorder_jokers" then
			details = tostring(decision.from or "") .. " -> " .. tostring(decision.to or "")
		end
		local current_plan = Peer.run.strategy_plan
		local primary = decision.plan_primary or (current_plan and current_plan.primary_hand)
		local secondary = decision.plan_secondary or (current_plan and current_plan.secondary_hand)
		local confidence = decision.plan_confidence or (current_plan and current_plan.confidence)
		local plan_text = decision.plan_exploring and "Exploring" or (primary and string.format("%s/%s(%.2f)",
			tostring(primary), tostring(secondary), tonumber(confidence) or 0) or "none")
		if strategy_debug_enabled() then sendDebugMessage(string.format(
			"LIVE_ACTION ante=%s round=%s action=%s value=%s picked=%s revealed=%s modeled=%s score=%s target=%s money=%s deck=%s jokers=%s utility=%s priority=%s reserve=%s source=%s scalers=%s plan=%s",
			tostring(decision.ante or Peer.ante),
			tostring(decision.round or ""),
			tostring(decision.type or "unknown"),
			tostring(details),
			tostring(decision.picked or ""),
			tostring(decision.revealed or ""),
			tostring(decision.modeled or ""),
			tostring(decision.score or ""),
			tostring(decision.target or ""),
			tostring(decision.money or Peer.run.money),
			tostring(decision.deck_size or #Peer.run.deck),
			tostring(decision.joker_count or #Peer.run.jokers),
			tostring(decision.utility or ""),
			tostring(decision.priority or ""),
			tostring(decision.reserve or ""),
			tostring(decision.source or ""),
			tostring(decision.scalers or "none"),
			plan_text
		), "MULTIBOTS") end
		if Peer.dependencies.Logger then
			local record_kind = decision.type == "shop_decision" and "SHOP_DECISION"
				or (decision.type == "fail_round" and "BLIND_FAILURE") or "DECISION"
			Peer.dependencies.Logger.write(record_kind, {
				decision_id = decision.decision_id,
				ante = decision.ante or Peer.ante, round = decision.round,
				action = decision.type, value = details, score = decision.score,
				cards = decision.cards, selected = decision.selected, effect = decision.effect,
				target = decision.target, current_score = decision.current_score,
				required_score = decision.required_score, pressure = decision.pressure,
				hands_remaining = decision.hands_remaining,
				hands_available = decision.hands_available,
				discards_remaining = decision.discards_remaining,
				discards_available = decision.discards_available,
				consumables_remaining = decision.consumables_remaining,
				consumables_available = decision.consumables_available,
				hand_contents = decision.hand_contents,
				money = decision.money or Peer.run.money,
				deck = decision.deck_size or #Peer.run.deck,
				jokers = decision.jokers or table.concat(Peer.run.jokers or {}, ","),
				consumables = decision.consumables,
				scalers = decision.scalers, plan = plan_text,
				plan_primary = decision.plan_primary, plan_secondary = decision.plan_secondary,
				plan_confidence = decision.plan_confidence,
				utility = decision.utility, priority = decision.priority,
				chosen_utility = decision.chosen_utility,
				best_utility = decision.best_utility, regret = decision.regret,
				candidates = decision.candidates, chosen = decision.chosen,
				reserve = decision.reserve, source = decision.source,
				reserve_reason = decision.reserve_reason,
				best_alternative = decision.best_alternative,
				replacement = decision.replacement,
				shop_id = decision.shop_id, offered = decision.offered,
				supported = decision.supported, evaluated = decision.evaluated,
				picked = decision.picked,
				revealed = decision.revealed, modeled = decision.modeled,
				from = decision.from, to = decision.to, blind = decision.blind,
				snapshot = decision.snapshot,
			})
		end
	end
end

local function visit_current_shop(next_round_is_pvp)
	if not Peer.run then return true end
	Peer.run.next_round_is_pvp = next_round_is_pvp == true
	if Peer.run.the_order then
		local keys, generation_error
		if Peer.dependencies.Order.generate_shop then
			keys, generation_error = Peer.dependencies.Order.generate_shop(Peer.run)
		else
			-- Compatibility with older/test Order adapters.
			keys = Peer.dependencies.Order.take()
			if not keys then return false end
		end
		if not keys then
			sendWarnMessage("ORDER_SHOP generation failed: " .. tostring(generation_error), "MULTIBOTS")
			if Peer.dependencies.Logger then
				local write_debug = Peer.dependencies.Logger.write_debug or Peer.dependencies.Logger.write
				write_debug("WARN", {
					ante = Peer.ante, kind = "order_shop_generation", error = generation_error,
				})
			end
			-- Never consume the human's visible shop as a recovery path. A failed
			-- private poll costs the bot this shop, but cannot desynchronise the run.
			return true
		end
		local function process(generated_keys, source)
			for index = (Peer.last_spectator_streamed_decision or 0) + 1, #Peer.run.decisions do
				stream_decision_once(Peer.run.decisions[index], index)
			end
			Peer.spectator_shop_cards = {}
			for _, key in ipairs(generated_keys or {}) do
				Peer.spectator_shop_cards[#Peer.spectator_shop_cards + 1] = key
			end
			local jokers_before = {}
			for _, key in ipairs(Peer.run.jokers or {}) do jokers_before[#jokers_before + 1] = key end
			local money_before = Peer.run.money
			broadcast_spectator_snapshot({
				state = G and G.STATES and G.STATES.SHOP,
				jokers = spectator_jokers(jokers_before), dollars = money_before,
				hand = {},
			})
			local first_shop_decision = #Peer.run.decisions + 1
			local report = Peer.dependencies.Simulator.visit_shop(Peer.run, generated_keys)
			for index = first_shop_decision, #Peer.run.decisions do
				stream_decision_once(Peer.run.decisions[index], index)
			end
			if strategy_debug_enabled() then sendDebugMessage(string.format(
				"ORDER_SHOP source=%s offered=%s supported=%s tag_rewards=%s purchases=%s money=%s reserve=%s",
				tostring(source or "visit"), table.concat(report.keys or {}, ","),
				table.concat(report.supported_keys or {}, ","),
				table.concat(report.tag_rewards or {}, ","),
				tostring(report.purchases or 0),
				tostring(report.money or Peer.run.money),
				tostring(report.reserve or 0)
			), "MULTIBOTS") end
			if Peer.dependencies.Logger then
				Peer.dependencies.Logger.write("SHOP_VISIT", {
					ante = Peer.ante, source = source or "visit",
					offered = table.concat(report.keys or {}, ","),
					supported = table.concat(report.supported_keys or {}, ","),
					tags = table.concat(report.tag_rewards or {}, ","),
					purchases = report.purchases or 0, money = report.money or Peer.run.money,
					reserve = report.reserve or 0,
				})
			end
			return report
		end
		-- The shop and its rerolls (the reroll_step hook decides; the Order's
		-- private queues give the reroll's cards).
		Peer.dependencies.Simulator.shop_phase(Peer.run, keys, {
			reroll_keys = Peer.dependencies.Order.generate_reroll,
			visit = process,
			on_reroll_failed = function(reroll_error)
				sendWarnMessage("ORDER_REROLL generation failed: " .. tostring(reroll_error), "MULTIBOTS")
			end,
		})
	else
		Peer.dependencies.Simulator.shop_phase(Peer.run)
	end
	return true
end

local function schedule_next_ante()
	local config = SMODS and SMODS.Mods and SMODS.Mods.MultiBots and SMODS.Mods.MultiBots.config
	local pace = config and config.pace
	Peer.next_ante_delay = math.max(0, tonumber(pace and pace.shop_seconds) or 18)
end

local function begin_shop_wait(next_round_is_pvp, advance_ante)
	if visit_current_shop(next_round_is_pvp) then
		if advance_ante then schedule_next_ante() end
		return true
	end
	Peer.waiting_order_shop = {
		elapsed = 0, ante = Peer.ante, first_decision = #Peer.run.decisions + 1,
		next_round_is_pvp = next_round_is_pvp == true,
		advance_ante = advance_ante == true,
	}
	return false
end

local function pvp_is_next_phase()
	if Peer.ante < (Peer.pvp_start_ante or 2) then return false end
	for index = (Peer.phase or 0) + 1, #(Peer.timeline or {}) do
		local phase = Peer.timeline[index]
		if phase.type == "loc_playing" then return false end
		if phase.type == "loc_ready" then return true end
	end
	return Peer.timeline and Peer.timeline[Peer.phase]
		and Peer.timeline[Peer.phase].type == "loc_ready" or false
end

local function enter_phase(phase, previous)
	if not Peer.run or not phase then return end
	local simulator = Peer.dependencies.Simulator
	local first_new_decision = #Peer.run.decisions + 1
	if phase.type == "loc_playing" then
		if previous and previous.type == "loc_shop" then
			send_spectator_action("TOGGLE_SHOP", {})
		end
		send_spectator_action("SELECT_BLIND", { blind_row = phase.blind })
		-- Multiplayer de-duplicates round losses until it receives newRound.
		-- Small, Big, and non-PvP Boss are separate rounds even when they share
		-- an Ante, so announce every Blind boundary rather than every Ante.
		Peer.send({ action = "newRound" })
	end
	if phase.type == "loc_playing" and phase.blind == "Small" then
		Peer.small_result = simulator.play_round(Peer.run, blind_base(Peer.ante), "Small")
	elseif phase.type == "loc_playing" and phase.blind == "Big" then
		Peer.big_result = simulator.play_round(Peer.run, blind_base(Peer.ante) * 1.5, "Big")
	elseif phase.type == "loc_playing" and phase.blind == "Boss" then
		Peer.boss_result = simulator.play_round(Peer.run, blind_base(Peer.ante) * 2, "Boss")
	elseif phase.type == "loc_shop" and previous and previous.blind == "Small" then
		send_spectator_action("CASH_OUT", {})
		simulator.award_blind(Peer.run, "Small", Peer.small_result)
		begin_shop_wait(pvp_is_next_phase())
	elseif phase.type == "loc_shop" and previous and previous.blind == "Big" then
		send_spectator_action("CASH_OUT", {})
		simulator.award_blind(Peer.run, "Big", Peer.big_result)
		begin_shop_wait(pvp_is_next_phase())
	elseif phase.type == "loc_shop" and previous and previous.blind == "Boss" then
		send_spectator_action("CASH_OUT", {})
		simulator.award_blind(Peer.run, "Boss", Peer.boss_result)
		begin_shop_wait(false, true)
	elseif phase.type == "loc_ready" then
		local state = simulator.snapshot(Peer.run)
		Peer.replay._multibots_state.ante_states[Peer.ante] = state
	end
	sync_live_state()
	log_new_decisions(first_new_decision)
end

local function play_next_hand()
	if not Peer.pvp_session then return false end
	Peer.pvp_session.pvp_target = tonumber(Peer.player_score) or 0
	Peer.pvp_session.pvp_player_hands = tonumber(Peer.player_hands)
	local first_new_decision = #Peer.run.decisions + 1
	local next_hand, result, finished = Peer.dependencies.Simulator.step_round(Peer.pvp_session)
	if not next_hand then
		if finished then Peer.pvp_result = result end
		return false
	end
	Peer.bot_hand_index = Peer.bot_hand_index + 1
	Peer.bot_hands = tonumber(next_hand.hands_left) or math.max(0, Peer.bot_hands - 1)
	if finished then Peer.pvp_result = result end
	if Peer.player_id then
		Peer.pvp_scores_by_id = Peer.pvp_scores_by_id or {}
		Peer.pvp_scores_by_id[tostring(Peer.player_id)] = next_hand.score or "0"
	end
	sync_live_state()
	log_new_decisions(first_new_decision)
	Peer.playing_hand = true
	Peer.send({ action = "playHand", score = tostring(next_hand.score or 0), handsLeft = Peer.bot_hands })
	Peer.playing_hand = false
	return true
end

local function play_until_matched(target_hands)
	local hands_target = tonumber(target_hands) or tonumber(Peer.player_hands) or 0
	while Peer.pvp and Peer.bot_hands > hands_target do
		if not play_next_hand() then break end
	end
end

local function is_bot_player(player_id)
	if not player_id then return false end
	for key, value in pairs((MP and MP.LOBBY and MP.LOBBY.multibots_bot_ids) or {}) do
		local id = type(key) == "number" and value or (value and key or nil)
		if id and tostring(id) == tostring(player_id) then return true end
	end
	return false
end

local function human_lobby_player_ids()
	local ids = {}
	local players = Peer.lobby_players or (MP and MP.LOBBY and MP.LOBBY.players)
	for _, player in ipairs(players or {}) do
		local player_id = player.id or player.player_id or player.playerId
		local is_spectator = player.is_spectator == true or player.isSpectator == true
			or player.role == "spectator"
		if player_id and not is_spectator and not is_bot_player(player_id) then
			ids[tostring(player_id)] = true
		end
	end
	if Peer.nemesis_id and not is_bot_player(Peer.nemesis_id) then
		local nemesis_is_spectator = false
		for _, player in ipairs(players or {}) do
			local player_id = player.id or player.player_id or player.playerId
			if player_id and tostring(player_id) == tostring(Peer.nemesis_id) then
				nemesis_is_spectator = player.is_spectator == true
					or player.isSpectator == true or player.role == "spectator"
				break
			end
		end
		if not nemesis_is_spectator then ids[tostring(Peer.nemesis_id)] = true end
	end
	return ids
end

local function human_player_can_gate_hands(player_id)
	if not player_id or is_bot_player(player_id) then return false end
	local lives = Peer.player_lives_by_id and Peer.player_lives_by_id[tostring(player_id)]
	if lives ~= nil and tonumber(lives) and tonumber(lives) <= 0 then return false end
	local players = Peer.lobby_players or (MP and MP.LOBBY and MP.LOBBY.players)
	for _, player in ipairs(players or {}) do
		local id = player.id or player.player_id or player.playerId
		if id and tostring(id) == tostring(player_id) then
			return not (player.is_spectator == true or player.isSpectator == true
				or player.role == "spectator")
		end
	end
	return true
end

local function initialize_human_hand_counts(starting_hands)
	local lobby = MP and MP.LOBBY
	if not lobby then return nil end
	local round = tostring(Peer.ante or "")
	if lobby.multibots_human_hands_round ~= round
		or type(lobby.multibots_human_hands) ~= "table" then
		lobby.multibots_human_hands = {}
		lobby.multibots_human_hands_round = round
		for player_id in pairs(human_lobby_player_ids()) do
			lobby.multibots_human_hands[player_id] = starting_hands
		end
	end
	return lobby.multibots_human_hands
end

local function update_human_hand_count(player_id, hands_left)
	if not player_id or is_bot_player(player_id) then return end
	local lobby = MP and MP.LOBBY
	if not lobby or type(lobby.multibots_human_hands) ~= "table" then return end
	local count = tonumber(hands_left)
	if count then lobby.multibots_human_hands[tostring(player_id)] = math.max(0, count) end
end

local function most_human_hands_remaining()
	local lobby = MP and MP.LOBBY
	local counts = lobby and lobby.multibots_human_hands
	if type(counts) ~= "table" then return nil end
	local maximum
	for player_id, hands_left in pairs(counts) do
		local count = tonumber(hands_left)
		if count and human_player_can_gate_hands(player_id) then
			maximum = math.max(maximum or count, count)
		end
	end
	return maximum
end

local function bot_player_ids()
	local ids = {}
	for key, value in pairs((MP and MP.LOBBY and MP.LOBBY.multibots_bot_ids) or {}) do
		local id = type(key) == "number" and value or (value and key or nil)
		if id then ids[tostring(id)] = true end
	end
	if Peer.player_id and is_bot_player(Peer.player_id) then
		ids[tostring(Peer.player_id)] = true
	end
	return ids
end

local function update_player_lives(player_id, lives)
	local count = tonumber(lives)
	if player_id and count then
		Peer.player_lives_by_id = Peer.player_lives_by_id or {}
		Peer.player_lives_by_id[tostring(player_id)] = count
	end
end

local function compare_player_ids(left, right)
	local left_number, right_number = tonumber(left), tonumber(right)
	if left_number and right_number and left_number ~= right_number then
		return left_number < right_number
	end
	return tostring(left) < tostring(right)
end

local function lowest_player_id(ids)
	local lowest
	for _, player_id in ipairs(ids) do
		if not lowest or compare_player_ids(player_id, lowest) then lowest = player_id end
	end
	return lowest
end

local function normalized_score(value)
	if type(value) == "number" then
		if value ~= value or value == math.huge or value == -math.huge then return nil end
		value = string.format("%.0f", math.max(0, value))
	end
	if type(value) ~= "string" then return nil end
	local score = value:match("^%s*(%d+)%s*$")
	if not score then return nil end
	score = score:gsub("^0+", "")
	return score ~= "" and score or "0"
end

local function compare_scores(left, right)
	if #left ~= #right then return #left < #right and -1 or 1 end
	if left == right then return 0 end
	return left < right and -1 or 1
end

local function humans_are_out()
	local players = Peer.lobby_players or (MP and MP.LOBBY and MP.LOBBY.players)
	local has_roster = type(players) == "table"
	local seen_players = {}
	for _, player in ipairs(has_roster and players or {}) do
		local player_id = player.id or player.player_id or player.playerId
		local is_spectator = player.is_spectator == true or player.isSpectator == true
			or player.role == "spectator"
		if player_id then seen_players[tostring(player_id)] = true end
		if player_id and not is_spectator and not is_bot_player(player_id) then
			local lives = Peer.player_lives_by_id and Peer.player_lives_by_id[tostring(player_id)]
			if lives == nil or tonumber(lives) > 0 then return false end
		end
	end
	if Peer.nemesis_id and not is_bot_player(Peer.nemesis_id)
		and not seen_players[tostring(Peer.nemesis_id)] then
		local lives = Peer.player_lives_by_id
			and Peer.player_lives_by_id[tostring(Peer.nemesis_id)]
		if lives == nil or tonumber(lives) > 0 then return false end
	end
	return true
end

local function bot_only_winner_id()
	local bots = bot_player_ids()
	if not next(bots) or not humans_are_out() then return nil end

	local players = Peer.lobby_players or (MP and MP.LOBBY and MP.LOBBY.players)
	local roster_ids
	if type(players) == "table" then
		roster_ids = {}
		for _, player in ipairs(players) do
			local player_id = player.id or player.player_id or player.playerId
			local is_spectator = player.is_spectator == true or player.isSpectator == true
				or player.role == "spectator"
			if player_id and not is_spectator then roster_ids[tostring(player_id)] = true end
		end
	end

	local candidates, unknown_lives = {}, false
	for player_id in pairs(bots) do
		if not roster_ids or roster_ids[player_id] then
			local lives = Peer.player_lives_by_id and Peer.player_lives_by_id[player_id]
			if lives == nil then
				candidates[#candidates + 1] = player_id
				unknown_lives = true
			elseif tonumber(lives) > 0 then
				candidates[#candidates + 1] = player_id
			end
		end
	end
	if #candidates == 0 then return nil end
	if unknown_lives then return lowest_player_id(candidates) end

	local most_lives, finalists = nil, {}
	for _, player_id in ipairs(candidates) do
		local lives = tonumber(Peer.player_lives_by_id[player_id])
		if most_lives == nil or lives > most_lives then
			most_lives, finalists = lives, { player_id }
		elseif lives == most_lives then
			finalists[#finalists + 1] = player_id
		end
	end
	if #finalists == 1 then return finalists[1] end

	local scores = Peer.last_pvp_scores_by_id or {}
	local highest_score, score_winners
	for _, player_id in ipairs(finalists) do
		local score = normalized_score(scores[player_id])
		if not score then return lowest_player_id(finalists) end
		if highest_score == nil or compare_scores(score, highest_score) > 0 then
			highest_score, score_winners = score, { player_id }
		elseif compare_scores(score, highest_score) == 0 then
			score_winners[#score_winners + 1] = player_id
		end
	end
	if #score_winners == 1 then return score_winners[1] end
	return lowest_player_id(finalists)
end

local function resolve_bot_only_match(require_human_participation)
	if not Peer.in_game or (require_human_participation and not Peer.human_players_seen) then
		return false
	end
	local winner_id = bot_only_winner_id()
	if not winner_id then return false end
	local outcome = Peer.player_id and tostring(winner_id) == tostring(Peer.player_id)
		and "winGame" or "loseGame"
	Peer.handle({ action = outcome })
	return true
end

local function resume_pvp_after_roster_update()
	if not Peer.pvp or Peer.playing_hand then return false end
	if resolve_bot_only_match(true) then return true end
	play_until_matched(most_human_hands_remaining() or 0)
	return false
end

local function record_pvp_result(bot_lost)
	if Peer.pvp_session and not Peer.pvp_result then
		Peer.pvp_result = Peer.dependencies.Simulator.finish_round(Peer.pvp_session)
	end
	Peer.last_pvp_scores_by_id = shallow_copy(Peer.pvp_scores_by_id)
	if Peer.player_id and Peer.pvp_result then
		Peer.last_pvp_scores_by_id[tostring(Peer.player_id)] = Peer.pvp_result.score
	end
	if not Peer.run or not Peer.pvp_result then return nil end
	Peer.pvp_result.life_lost = bot_lost == true
	if Peer.dependencies.Simulator.record_pvp_outcome then
		Peer.dependencies.Simulator.record_pvp_outcome(
			Peer.run, Peer.pvp_result.score, Peer.player_score
		)
	end
	if Peer.dependencies.Logger then
		Peer.dependencies.Logger.write("PVP", {
			ante = Peer.ante, bot_score = Peer.pvp_result.score,
			player_score = Peer.player_score, bot_lost = bot_lost == true,
			margin = (tonumber(Peer.pvp_result.score) or 0) - (tonumber(Peer.player_score) or 0),
		})
	end
	return Peer.pvp_result
end

local function remember_previous_host(message)
	if Peer.previous_host_id or type(message.players) ~= "table" then return end
	for _, player in ipairs(message.players) do
		local id = player.id or player.playerId
		if id and (player.isOwner == true or player.is_owner == true)
			and tostring(id) ~= tostring(Peer.player_id) then
			Peer.previous_host_id = tostring(id)
			return
		end
	end
end

local function recover_bot_host(message)
	remember_previous_host(message)
	if message.isHost ~= true then
		if message.isHost == false then Peer.host_recovery_attempted = false end
		return
	end
	if Peer.host_recovery_attempted then return end
	Peer.host_recovery_attempted = true

	local previous_host_id = Peer.previous_host_id
	local previous_host_present = false
	for _, player in ipairs(message.players or {}) do
		local id = player.id or player.playerId
		if previous_host_id and tostring(id) == previous_host_id then
			previous_host_present = true
			break
		end
	end
	local departed_id = message.playerId or message.player_id
	if previous_host_id and previous_host_id ~= tostring(departed_id or "")
		and (previous_host_present or type(message.players) ~= "table") then
		Peer.send({ action = "makePlayerHost", playerId = previous_host_id })
		return
	end

	local lobby = MP and MP.LOBBY
	local bot_ids = lobby and lobby.multibots_bot_ids or {}
	local kicked = {}
	for key, value in pairs(bot_ids) do
		local player_id = type(key) == "number" and value or (value and key or nil)
		if player_id then
			player_id = tostring(player_id)
			kicked[player_id] = true
			Peer.send({ action = "kickPlayer", playerId = player_id })
		end
	end
	if Peer.player_id and not kicked[tostring(Peer.player_id)] then
		Peer.send({ action = "kickPlayer", playerId = tostring(Peer.player_id) })
	end
end

function Peer.handle(message)
	message = legacy_message(message)
	local action = message and message.action
	if action == "multibotsTransportConnected" and protocol_v2() then
		return
	elseif action == "multibotsTransportConnected" or action == "connected" then
		send_identity()
		if Peer.pending and Peer.pending.code and not Peer.joined_sent then
			Peer.joined_sent = true
			Peer.send({ action = "joinLobby", code = Peer.pending.code })
		end
	elseif action == "version" then
		Peer.send({ action = "version", version = MULTIPLAYER_VERSION or MP.version or "" })
	elseif action == "joinedLobby" then
		Peer.lobby_players = message.players or Peer.lobby_players
		remember_previous_host(message)
		Peer.host_recovery_attempted = false
		recover_bot_host(message)
		if not protocol_v2() then Peer.send({ action = "lobbyInfo" }) end
		Peer.send({ action = "readyLobby" })
	elseif action == "lobbyInfo" or action == "lobbyPlayerLeft" then
		if type(message.players) == "table" then Peer.lobby_players = message.players end
		local departed_player_id = message.playerId or message.player_id
		if action == "lobbyPlayerLeft" and departed_player_id then
			if Peer.nemesis_id and tostring(Peer.nemesis_id) == tostring(departed_player_id) then
				Peer.nemesis_id = nil
			end
			if Peer.player_lives_by_id then
				Peer.player_lives_by_id[tostring(departed_player_id)] = nil
			end
			if Peer.last_pvp_scores_by_id then
				Peer.last_pvp_scores_by_id[tostring(departed_player_id)] = nil
			end
			if MP and MP.LOBBY and MP.LOBBY.multibots_human_hands then
				MP.LOBBY.multibots_human_hands[tostring(departed_player_id)] = nil
			end
			for index = #(Peer.lobby_players or {}), 1, -1 do
				local player = Peer.lobby_players[index]
				local player_id = player.id or player.player_id or player.playerId
				if player_id and tostring(player_id) == tostring(departed_player_id) then
					table.remove(Peer.lobby_players, index)
				end
			end
		end
		recover_bot_host(message)
		if action == "lobbyPlayerLeft" and resolve_bot_only_match(true) then return end
		if resume_pvp_after_roster_update() then return end
	elseif action == "lobbyOptions" then
		if Peer.pending then Peer.pending.options = copy_message(message) end
	elseif action == "startGame" then
		if MP and MP.LOBBY then
			MP.LOBBY.multibots_human_hands = nil
			MP.LOBBY.multibots_human_hands_round = nil
		end
		Peer.player_lives_by_id, Peer.pvp_scores_by_id, Peer.last_pvp_scores_by_id = {}, {}, {}
		Peer.human_players_seen = next(human_lobby_player_ids()) ~= nil
		local starting_lives = tonumber(message.startingLives or message.lives
			or (MP and MP.LOBBY and MP.LOBBY.config and MP.LOBBY.config.starting_lives))
		if starting_lives then
			local players = Peer.lobby_players or (MP and MP.LOBBY and MP.LOBBY.players) or {}
			for _, player in ipairs(players) do
				local player_id = player.id or player.player_id or player.playerId
				if player_id then update_player_lives(player_id, starting_lives) end
			end
			for player_id in pairs(bot_player_ids()) do update_player_lives(player_id, starting_lives) end
		end
		build_replay(message)
	elseif action == "spectatorRequestSnapshot" then
		local spectator_player_id = message.spectatorPlayerId
		if spectator_player_id and (not message.targetPlayerId or message.targetPlayerId == Peer.player_id) then
			Peer.spectator_watchers = Peer.spectator_watchers or {}
			Peer.spectator_watchers[tostring(spectator_player_id)] = true
			send_spectator_snapshot(tostring(spectator_player_id))
		end
	elseif action == "startBlind" and Peer.in_game then
		Peer.pvp = true
		Peer.skips_since_pvp = 0
		Peer.send({ action = "setLocation", location = "loc_playing-bl_mp_nemesis" })
		if Peer.run then
			Peer.pvp_session = Peer.dependencies.Simulator.begin_round(Peer.run, nil, "Boss", "PvP")
			Peer.pvp_result = nil
			Peer.replay.ante_snapshots[Peer.ante] = { hands = Peer.pvp_session.hands }
			sync_live_state()
		end
		Peer.bot_hand_index = 0
		Peer.bot_hands = Peer.pvp_session and Peer.pvp_session.starting_hands or 4
		Peer.player_hands, Peer.player_score = 4, 0
		Peer.pvp_scores_by_id = {}
		for player_id in pairs(bot_player_ids()) do Peer.pvp_scores_by_id[player_id] = "0" end
		local human_hands = initialize_human_hand_counts(Peer.bot_hands)
		Peer.send({ action = "newRound" })
		Peer.send({ action = "playHand", score = "0", handsLeft = Peer.bot_hands })
		if not human_hands or not next(human_hands) then
			if is_bot_player(Peer.nemesis_id) then
				play_next_hand()
			elseif Peer.nemesis_id and not human_player_can_gate_hands(Peer.nemesis_id) then
				play_until_matched(0)
			else
				play_until_matched()
			end
		end
	elseif action == "enemyInfo" then
		local player_id = message.playerId or Peer.nemesis_id
		update_human_hand_count(player_id, message.handsLeft)
		update_player_lives(player_id, message.lives)
		if Peer.pvp and player_id and message.score ~= nil then
			Peer.pvp_scores_by_id = Peer.pvp_scores_by_id or {}
			Peer.pvp_scores_by_id[tostring(player_id)] = message.score
		end
		if resolve_bot_only_match(true) then return end
		local is_nemesis_info = not message.playerId or not Peer.nemesis_id
			or tostring(message.playerId) == tostring(Peer.nemesis_id)
		if is_nemesis_info and Peer.run and message.skips ~= nil then
			Peer.run.opponent_skips = tonumber(message.skips) or Peer.run.opponent_skips or 0
		end
		local previous_hands, previous_score = Peer.player_hands, Peer.player_score
		if is_nemesis_info then
			Peer.player_hands = tonumber(message.handsLeft) or Peer.player_hands
			Peer.player_score = tonumber(message.score) or Peer.player_score
		end
		if Peer.pvp and not Peer.playing_hand then
			local most_human_hands = most_human_hands_remaining()
			if most_human_hands ~= nil then
				play_until_matched(most_human_hands)
			elseif is_nemesis_info and is_bot_player(Peer.nemesis_id)
				and (Peer.player_hands ~= previous_hands or Peer.player_score ~= previous_score) then
				play_next_hand()
			elseif is_nemesis_info then
				if Peer.nemesis_id and not human_player_can_gate_hands(Peer.nemesis_id) then
					play_until_matched(0)
				else
					play_until_matched()
				end
			end
		end
	elseif action == "playerInfo" then
		update_player_lives(Peer.player_id, message.lives)
	elseif action == "aloneGame" then
		if not resolve_bot_only_match(false) then Peer.handle({ action = "loseGame" }) end
		return
	elseif Peer.in_game and (action == "soldJoker"
		or (Peer.pvp and (action == "asteroid" or action == "letsGoGamblingNemesis"))) then
		local first_new_decision = Peer.run and (#Peer.run.decisions + 1) or 1
		if Peer.dependencies.Simulator.apply_pvp_effect
			and Peer.dependencies.Simulator.apply_pvp_effect(Peer.run, action) then
			sync_live_state()
			log_new_decisions(first_new_decision)
		end
	elseif action == "endPvP" and Peer.in_game then
		Peer.pvp = false
		if record_pvp_result(message.lost == true) then
			Peer.send({ action = "setLocation", location = "loc_shop-" })
			local first_new_decision = #Peer.run.decisions + 1
			Peer.dependencies.Simulator.award_blind(Peer.run, "Boss", Peer.pvp_result)
			local visited = begin_shop_wait(false, true)
			Peer.pvp_result = nil
			Peer.pvp_session = nil
			sync_live_state()
			if visited then log_new_decisions(first_new_decision) end
		end
	elseif action == "getEndGameJokers" then
		Peer.send({ action = "receiveEndGameJokers", keys = joker_payload() })
	elseif action == "getNemesisDeck" then
		Peer.send({ action = "receiveNemesisDeck", cards = deck_string() })
	elseif action == "endGameStatsRequested" then
		Peer.send({
			action = "nemesisEndGameStats",
			reroll_count = tostring(Peer.run and Peer.run.times_rerolled or 0),
			reroll_cost_total = tostring(Peer.run and Peer.run.reroll_cost_total or 0),
		})
	elseif action == "winGame" or action == "loseGame" or action == "stopGame" then
		if action ~= "stopGame" and (Peer.pvp_session or Peer.pvp_result) then
			record_pvp_result(action == "loseGame")
			Peer.pvp_result = nil
			Peer.pvp_session = nil
		end
		-- Keep the final run available for deck/Joker inspection, but stop the
		-- host-driven phase clock immediately. Otherwise a queued next Blind can
		-- still be simulated after the result screen has appeared.
		Peer.in_game = false
		Peer.pvp = false
		Peer.next_ante_delay = nil
		Peer.waiting_order_shop = nil
		Peer.timeline = nil
		Peer.ready_sent = true
		if Peer.dependencies.Logger and not Peer.terminal_logged then
			Peer.terminal_logged = true
			-- Keep full builds out of the per-action stream, but retain both final
			-- decks for post-match diagnosis. Multiplayer's compact card encoding
			-- preserves rank, suit, enhancement, edition, and seal.
			Peer.dependencies.Logger.write("FINAL_BOT", final_bot_snapshot())
			Peer.dependencies.Logger.write("FINAL_PLAYER", final_player_snapshot())
			Peer.dependencies.Logger.finish(action, {
				ante = Peer.ante, money = Peer.run and Peer.run.money,
				jokers = Peer.run and table.concat(Peer.run.jokers or {}, ",") or "",
				deck = Peer.run and #Peer.run.deck or 0,
			})
		end
		-- A win/loss message opens the results screen, but the lobby authority can
		-- still clear ready state when the host later returns. stopGame is the
		-- actual return-to-lobby boundary, so ready for the rematch only then.
		if action == "stopGame" and Peer.pending and Peer.running and not Peer.rematch_ready_sent then
			Peer.rematch_ready_sent = true
			Peer.send({ action = "readyLobby" })
		end
	elseif action == "keepAlive" then
		Peer.send({ action = "keepAliveAck" })
	elseif action == "multibotsTransportError" then
		sendWarnMessage("Bot connection failed: " .. tostring(message.message), "MULTIBOTS")
		if Peer.dependencies.Logger then
			local write_debug = Peer.dependencies.Logger.write_debug or Peer.dependencies.Logger.write
			write_debug("NETWORK_ERROR", { error = message.message, transport = Peer.transport })
		end
		Peer.running = false
		if protocol_v2() then
			Peer.reset(false)
		elseif Peer.transport == "remote" then
			Peer.fallback_pending = true
		end
	elseif action == "multibotsKicked" then
		Peer.reset(false)
	end
end

local function fallback_to_local()
	Peer.fallback_pending = false
	-- Leave the empty remote lobby before Client.send is switched to the
	-- embedded authority. The human connection itself remains untouched.
	if MP.LOBBY.code then MP.ACTIONS.leave_lobby() end
	if Peer.outgoing then Peer.outgoing:push("__MULTIBOTS_CLOSE__") end
	MP.LOBBY.code = nil
	Peer.thread, Peer.incoming, Peer.outgoing = nil, nil, nil
	Peer.transport, Peer.running, Peer.joined_sent = nil, false, false
	if Peer.pending and Peer.pending.ruleset then MP.LOBBY.config.ruleset = Peer.pending.ruleset end
	start_local()
	MP.ACTIONS.create_lobby(tostring(MP.LOBBY.config.gamemode or "gamemode_mp_attrition"):gsub("^gamemode_mp_", ""))
end

local function location_for_phase(phase)
	if not phase then return nil end
	local blind = phase.blind
	local blind_key = blind and G.GAME and G.GAME.round_resets and G.GAME.round_resets.blind_choices
		and G.GAME.round_resets.blind_choices[blind] or ""
	return phase.type .. "-" .. blind_key
end

-- The skip tags of the bot's own Ante. The host's blind
-- tags belong to the host's current Ante, and the bot keeps its own pace, so a
-- bot that reaches Ante N first used to see the host's Ante N-1 tags. The tags
-- of any Ante are replayed from the host's seed (Order.blind_tags); the replay
-- is trusted only after it matched the host's real tags on a shared Ante, and
-- any later mismatch goes back to the host's tags for the rest of the game.
local function blind_tags_for_ante(ante, live_tags)
	local Order = Peer.dependencies and Peer.dependencies.Order
	local resets = G and G.GAME and G.GAME.round_resets
	if not (Order and Order.blind_tags and resets) or Peer.blind_tags_trusted == false then return live_tags end
	local random = G.GAME.pseudorandom
	if not Peer.blind_tag_seed and random and random.seed then
		Peer.blind_tag_seed = { seed = random.seed, hashed_seed = random.hashed_seed }
	end
	local replayed = Peer.blind_tag_seed and Order.blind_tags(Peer.blind_tag_seed, ante)
	if not replayed then return live_tags end
	local live_ante = tonumber(resets.mp_real_ante or resets.ante)
	if live_tags and live_ante == tonumber(ante) then
		if replayed.Small == live_tags.Small and replayed.Big == live_tags.Big then
			Peer.blind_tags_trusted = true
		else
			Peer.blind_tags_trusted = false
			sendWarnMessage(string.format("BLIND_TAGS replay %s/%s differs from the host's %s/%s at Ante %s; "
				.. "using the host's tags", tostring(replayed.Small), tostring(replayed.Big),
				tostring(live_tags.Small), tostring(live_tags.Big), tostring(ante)), "MULTIBOTS")
		end
		return live_tags
	end
	if Peer.blind_tags_trusted then return replayed end
	return live_tags
end
Peer.blind_tags_for_ante = blind_tags_for_ante

local function begin_ante(ante)
	if Peer.ante ~= nil then
		send_spectator_action("TOGGLE_SHOP", {})
	end
	Peer.ante = ante
	Peer.phase, Peer.elapsed, Peer.ready_sent, Peer.timer_sent = 1, 0, false, false
	Peer.next_ante_delay = nil
	if Peer.run then Peer.dependencies.Simulator.set_ante(Peer.run, ante) end
	local first_new_decision = Peer.run and (#Peer.run.decisions + 1) or 1
	local behavior = Peer.pending and Peer.pending.behavior or {}
	local skip_mode = behavior.skip_mode
		or (behavior.skip_blinds == false and "disabled" or "reactive")
	local tags = G.GAME and G.GAME.round_resets and G.GAME.round_resets.blind_tags
	tags = blind_tags_for_ante(ante, tags)
	local skipped = Peer.run and Peer.dependencies.Simulator.plan_skips
		and Peer.dependencies.Simulator.plan_skips(Peer.run, skip_mode, tags) or {}
	local skipped_count = 0
	for _, blind in ipairs({ "Small", "Big" }) do
		if skipped[blind] then skipped_count = skipped_count + 1 end
	end
	Peer.skips_since_pvp = (Peer.skips_since_pvp or 0) + skipped_count
	local options = Peer.local_server and Peer.local_server.options or MP.LOBBY.config or {}
	local timer_base = tonumber(options.timer_base_seconds) or 150
	if MP.UTILS and type(MP.UTILS.timer_base) == "function" then
		local ok, value = pcall(MP.UTILS.timer_base)
		if ok and tonumber(value) then timer_base = tonumber(value) end
	end
	Peer.ante_timer_seconds = timer_base
		+ Peer.skips_since_pvp * (tonumber(options.timer_increment_seconds) or 0)
	Peer.timeline = Peer.dependencies.Status.build_timeline(Peer.replay, ante, Peer.pvp_start_ante, skipped)
	Peer.send({ action = "setAnte", ante = ante })
	for _, blind in ipairs({ "Small", "Big" }) do
		if skipped[blind] then
			Peer.bot_skips = (Peer.bot_skips or 0) + 1
			Peer.send({ action = "skip", skips = Peer.bot_skips })
		end
	end
	if Peer.run and first_new_decision <= #Peer.run.decisions then
		sync_live_state()
		log_new_decisions(first_new_decision)
	end
	local location = location_for_phase(Peer.timeline[1])
	if location then Peer.send({ action = "setLocation", location = location }) end
end

local function animations_pending(dt)
	-- PeerPool advances every bot in one frame; keep the settle clock shared.
	local animation_state = MP.MULTIBOTS_ANIMATION_STATE
	if type(animation_state) ~= "table" then
		animation_state = {
			queue_count = nil, queue_stable = 0,
			wait_elapsed = 0, quiet_elapsed = 0,
		}
		MP.MULTIBOTS_ANIMATION_STATE = animation_state
	end
	local event_count = 0
	local queues = G and G.E_MANAGER and G.E_MANAGER.queues
	if type(queues) == "table" then
		for _, queue in pairs(queues) do
			if type(queue) == "table" then event_count = event_count + #queue end
		end
	end
	local step = math.max(0, tonumber(dt) or 0)
	if love and love.timer and type(love.timer.getTime) == "function" then
		local now = love.timer.getTime()
		if animation_state.last_time then step = math.max(0, now - animation_state.last_time) else step = 0 end
		animation_state.last_time = now
	end
	local cards_to_draw = SMODS and tonumber(SMODS.cards_to_draw) or 0
	if event_count > 0 or cards_to_draw > 0 then
		animation_state.wait_elapsed = animation_state.wait_elapsed + step
		animation_state.quiet_elapsed = 0
		if event_count == animation_state.queue_count then
			animation_state.queue_stable = animation_state.queue_stable + step
		else
			animation_state.queue_count = event_count
			animation_state.queue_stable = 0
		end
		return not (event_count <= 2 and event_count > 0
			and animation_state.queue_stable >= 0.75)
			and animation_state.wait_elapsed < 3
	end
	if animation_state.wait_elapsed > 0 and animation_state.quiet_elapsed < 0.1 then
		animation_state.quiet_elapsed = animation_state.quiet_elapsed + step
		return animation_state.quiet_elapsed < 0.1
	end
	animation_state.queue_count = nil
	animation_state.queue_stable = 0
	animation_state.wait_elapsed = 0
	animation_state.quiet_elapsed = 0
	return false
end

local function spectator_playback_pending(step)
	local spectator = MP and MP.SPECTATOR
	if not (spectator and spectator.is_spectating
		and tostring(spectator.target_player_id) == tostring(Peer.player_id)) then
		return false
	end
	if (tonumber(spectator.current_step) or 0) < step then return true end
	for _, entry in ipairs(spectator.pending_replay_queue or {}) do
		if (tonumber(entry.step) or math.huge) <= step then return true end
	end
	return false
end

local function flush_spectator_outbox()
	local outbox = Peer.spectator_outbox
	if not outbox or #outbox == 0 then return end
	if not has_spectator_watchers() then
		Peer.spectator_outbox = {}
		Peer.spectator_waiting_step = nil
		return
	end
	if Peer.spectator_waiting_step and spectator_playback_pending(Peer.spectator_waiting_step) then
		return
	end
	Peer.spectator_waiting_step = nil
	local entry = table.remove(outbox, 1)
	if entry.kind == "snapshot" then
		for spectator_player_id in pairs(Peer.spectator_watchers or {}) do
			Peer.send({
				action = "spectatorProvideSnapshot",
				spectatorPlayerId = spectator_player_id,
				snapshotData = entry.snapshot_data,
			})
		end
	elseif entry.kind == "action" then
		Peer.send({
			action = "spectatorActionStream",
			actionData = entry.action_data,
			stepIndex = entry.step,
		})
	end
	Peer.spectator_waiting_step = entry.step
end

function Peer.update(dt)
	if protocol_v2() and animations_pending(dt) then return end
	if protocol_v2() then flush_spectator_outbox() end
	local incoming = Peer.incoming
	if Peer.transport == "remote" and incoming then
		local raw = incoming:pop()
		while raw and Peer.incoming == incoming do
			local ok, message = pcall(json.decode, raw)
			if ok then Peer.handle(message) end
			raw = incoming:pop()
		end
	end
	if Peer.fallback_pending then fallback_to_local() end
	if Peer.waiting_order_shop then
		local waiting = Peer.waiting_order_shop
		Peer.waiting_order_shop.elapsed = Peer.waiting_order_shop.elapsed + (dt or 0)
		if visit_current_shop(waiting.next_round_is_pvp) then
			Peer.waiting_order_shop = nil
			sync_live_state()
			log_new_decisions(waiting.first_decision)
			if waiting.advance_ante then schedule_next_ante() end
		-- The bot can finish a simulated Blind a few seconds before the host's
		-- scoring animation reaches the corresponding shop. Three seconds proved
		-- too short in ordinary play and discarded a shop that appeared one second
		-- later. Keep a finite escape hatch for genuinely unobservable host-skipped
		-- shops, but allow normal animations and payouts to finish first.
		elseif Peer.waiting_order_shop.elapsed >= 60 then
			sendWarnMessage("ORDER_SHOP unavailable; bot skipped this shop instead of inventing offers", "MULTIBOTS")
			if Peer.dependencies.Logger then
				local write_debug = Peer.dependencies.Logger.write_debug or Peer.dependencies.Logger.write
				write_debug("WARN", {
					ante = Peer.ante, kind = "order_shop_timeout", waited = 60,
				})
			end
			Peer.waiting_order_shop = nil
			if waiting.advance_ante then schedule_next_ante() end
		end
	end
	if Peer.waiting_order_shop then return end
	if Peer.next_ante_delay ~= nil then
		Peer.next_ante_delay = Peer.next_ante_delay - (dt or 0)
		if Peer.next_ante_delay <= 0 then
			begin_ante((tonumber(Peer.ante) or 0) + 1)
			dt = 0
		else
			return
		end
	end

	if Peer.pending and not Peer.running and Peer.transport ~= "local" and MP.LOBBY.code then
		start_remote(MP.LOBBY.code)
	end
	if not Peer.in_game or not G.GAME or not G.GAME.round_resets or Peer.pvp then return end
	if Peer.ante == nil then begin_ante(tonumber(G.GAME.round_resets.ante) or 1) end

	Peer.elapsed = Peer.elapsed + (dt or 0)
	local phase = Peer.timeline and Peer.timeline[Peer.phase]
	while phase and phase.duration ~= math.huge and Peer.elapsed >= phase.duration do
		Peer.elapsed = Peer.elapsed - phase.duration
		local previous = phase
		Peer.phase = math.min(Peer.phase + 1, #Peer.timeline)
		phase = Peer.timeline[Peer.phase]
		enter_phase(phase, previous)
		local location = location_for_phase(phase)
		if location then Peer.send({ action = "setLocation", location = location }) end
		if Peer.waiting_order_shop then
			Peer.elapsed = 0
			break
		end
	end
	if phase and phase.type == "loc_ready" and not Peer.ready_sent then
		local timer_player = not Peer.pending or not Peer.pending.behavior
			or Peer.pending.behavior.timer_player ~= false
		if timer_player and Peer.timer_enabled and not Peer.timer_sent then
			Peer.timer_sent = true
			-- A real client sends its current clock here. The headless peer has no
			-- local HUD clock, so publish the lobby base plus this cycle's skips.
			Peer.send({ action = "startAnteTimer", time = Peer.ante_timer_seconds })
		end
		Peer.ready_sent = true
		Peer.send({ action = "readyBlind" })
	end
end

function Peer.reset(leave_lobby)
	-- The result screen intentionally keeps the final simulation alive for its
	-- deck/Joker viewer. This teardown is for leaving bot matchmaking or opening
	-- a fresh setup; Return to Lobby deliberately bypasses it so the connected
	-- peer and lobby can be reused for a rematch.
	if leave_lobby and MP and MP.LOBBY and MP.LOBBY.code then
		if MP.ACTIONS and type(MP.ACTIONS.leave_lobby) == "function" then
			pcall(MP.ACTIONS.leave_lobby)
		end
		MP.LOBBY.code = nil
	end
	if Peer.outgoing then pcall(function() Peer.outgoing:push("__MULTIBOTS_CLOSE__") end) end
	if Peer.incoming then pcall(function() Peer.incoming:clear() end) end
	if Peer.dependencies and Peer.dependencies.Order and Peer.dependencies.Order.clear then
		Peer.dependencies.Order.clear()
	end

	Peer.pending, Peer.replay, Peer.run = nil, nil, nil
	Peer.transport, Peer.local_server, Peer.thread = nil, nil, nil
	Peer.incoming, Peer.outgoing = nil, nil
	Peer.running, Peer.in_game, Peer.pvp = false, false, false
	Peer.joined_sent, Peer.ready_sent, Peer.timer_sent = false, false, false
	Peer.rematch_ready_sent, Peer.terminal_logged = false, false
	Peer.fallback_pending, Peer.waiting_order_shop = false, nil
	Peer.previous_host_id, Peer.host_recovery_attempted = nil, false
	Peer.ante, Peer.timeline, Peer.next_ante_delay = nil, nil, nil
	Peer.phase, Peer.elapsed = 1, 0
	Peer.small_result, Peer.big_result, Peer.boss_result, Peer.pvp_result = nil, nil, nil, nil
	Peer.pvp_session, Peer.playing_hand = nil, false
	Peer.player_score, Peer.bot_hand_index = 0, 0
	Peer.bot_hands, Peer.player_hands = 4, 4
	Peer.player_lives_by_id, Peer.pvp_scores_by_id, Peer.last_pvp_scores_by_id = {}, {}, {}
	Peer.human_players_seen = false
	Peer.bot_skips, Peer.skips_since_pvp = 0, 0
	Peer.blind_tag_seed, Peer.blind_tags_trusted = nil, nil
	Peer.timer_enabled, Peer.ante_timer_seconds, Peer.pvp_start_ante = nil, nil, nil
	Peer.player_id, Peer.nemesis_id, Peer.endgame_requester = nil, nil, nil
	Peer.lobby_players = nil
	Peer.spectator_watchers, Peer.spectator_step = {}, 0
	Peer.last_spectator_streamed_decision, Peer.spectator_shop_cards = 0, {}
	Peer.spectator_outbox, Peer.spectator_waiting_step = {}, nil
end

function Peer.start(setup, e)
	setup = type(setup) == "table" and setup or { difficulty = setup }
	local experimental = protocol_v2()
	local connected = lobby_client().connected == true
	local use_local = not experimental and (Peer.transport == "local" or not connected)
	if Peer.pending or Peer.running or Peer.transport or Peer.local_server then
		Peer.reset(true)
	end
	local difficulty = setup.difficulty or "normal"
	local ruleset = (MP.SP and MP.SP.ruleset) or MP.LOBBY.config.ruleset or "ruleset_mp_blitz"
	Peer.pending = {
		difficulty = difficulty,
		decision_temperature = tonumber(setup.decision_temperature),
		ruleset = ruleset,
		name = setup.name or "MultiBot (Normal)",
		name_mode = setup.name_mode or "classic",
		pace = setup.pace or "standard",
		bot_blind_col = math.max(1, math.min(25, tonumber(setup.bot_blind_col) or 2)),
		behavior = setup.behavior or { timer_player = true, skip_mode = "reactive" },
		strategy_weights = setup.strategy_weights,
		strategy_weight_profile = setup.strategy_weight_profile or "defaults",
	}
	Peer.replay, Peer.run, Peer.in_game, Peer.pvp = nil, nil, false, false
	Peer.player_lives_by_id, Peer.pvp_scores_by_id, Peer.last_pvp_scores_by_id = {}, {}, {}
	Peer.human_players_seen = false
	Peer.joined_sent, Peer.ready_sent = false, false
	Peer.rematch_ready_sent, Peer.terminal_logged = false, false
	Peer.waiting_order_shop = nil
	Peer.next_ante_delay = nil
	Peer.spectator_watchers, Peer.spectator_step = {}, 0
	Peer.last_spectator_streamed_decision, Peer.spectator_shop_cards = 0, {}
	Peer.spectator_outbox, Peer.spectator_waiting_step = {}, nil
	if MP.SP then MP.SP.practice = false end
	if MP.GHOST and MP.GHOST.clear then MP.GHOST.clear() end
	MP.LOBBY.config.ruleset = ruleset
	MP.LOBBY.config.gamemode = MP.LOBBY.config.gamemode or "gamemode_mp_attrition"
	if experimental then
		if not connected or not MP.LOBBY.code then
			Peer.pending = nil
			return false, "Join or create a private lobby before adding a bot."
		end
		start_remote(MP.LOBBY.code)
		return true
	end
	if use_local or not connected then start_local() end
	G.FUNCS.start_lobby(e)
	return true
end

function Peer.configure(dependencies)
	Peer.dependencies = dependencies
end

function Peer.is_active()
	return Peer.pending ~= nil and (Peer.running or Peer.in_game)
end

function Peer.install()
	local send_ref = Client.send
	function Client.send(message)
		if Peer.transport == "local" and Peer.local_server then
			return Peer.local_server:receive("host", copy_message(message))
		end
		return send_ref(message)
	end

	local update_ref = Game.update
	function Game:update(dt)
		local result = update_ref(self, dt)
		Peer.update(dt)
		return result
	end
end

Peer._translate_outgoing = v2_message
Peer._translate_incoming = legacy_message

return Peer
