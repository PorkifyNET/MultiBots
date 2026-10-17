local encoded_boards = {}

package.preload.json = function()
	return { encode = function() return "{}" end, decode = function() return {} end }
end

package.preload.json = function()
	return {
		encode = function(value)
			if value and value.type then
				local index = value.data and value.data.index
				local area = value.data and value.data.area
				return tostring(value.type) .. ":" .. tostring(value.step)
					.. (index and (":" .. tostring(index)) or "")
					.. (area and (":" .. tostring(area)) or "")
			end
			if value and value.step and value.hand then
				encoded_boards[value.step] = value
			end
			return "{}"
		end,
		decode = function() return {} end,
	}
end

function sendDebugMessage() end
function sendWarnMessage() end

G = {
	GAME = {
		stake = 1,
		round_resets = {
			ante = 2,
			blind_choices = { Small = "bl_small", Big = "bl_big", Boss = "bl_boss" },
		},
	},
}
MP = {
	LOBBY = { code = nil, config = { timer_base_seconds = 150, timer_increment_seconds = 30 } },
	UTILS = {
		timer_base = function() return 150 end,
		joker_to_string = function(card) return card.encoded end,
		card_to_string = function(card) return card.encoded end,
	},
}

local Peer = dofile("bot/peer.lua")
local sent = {}
local boss_rounds, awarded_bosses, visited_shops = 0, 0, 0
local emit_asteroid_on_shop = false
local planned_skips = {}
local log_entries = {}
local terminal_actions = {}
local pvp_steps, pvp_effects = 0, {}
Peer.send = function(message) sent[#sent + 1] = message end
Peer.dependencies = {
	Logger = {
		write = function(kind, values) log_entries[#log_entries + 1] = { kind = kind, values = values } end,
		finish = function(action) terminal_actions[#terminal_actions + 1] = action end,
	},
	Status = { build_timeline = function()
		return { { type = "loc_selecting", duration = math.huge } }
	end },
	Simulator = {
		base_score = function() return 300 end,
		play_round = function(_, _, blind)
			if blind == "Boss" then boss_rounds = boss_rounds + 1 end
			return { hands = {}, score = 0, hands_left = 0, hands_used = 4, cleared = false }
		end,
		begin_round = function(state)
			return { state = state, starting_hands = 5, hands = {}, cumulative = 0, finished = false }
		end,
		step_round = function(session)
			pvp_steps = pvp_steps + 1
			local hand = { score = tostring(pvp_steps * 100), hands_left = 5 - pvp_steps }
			session.hands[#session.hands + 1] = hand
			session.cumulative = pvp_steps * 100
			return hand, nil, false
		end,
		finish_round = function(session)
			session.finished = true
			return { hands = session.hands, score = session.cumulative, hands_left = 5 - pvp_steps,
				hands_used = pvp_steps, hands_available = 5, cleared = true }
		end,
		apply_pvp_effect = function(_, action) pvp_effects[#pvp_effects + 1] = action; return true end,
		award_blind = function(_, blind)
			if blind == "Boss" then awarded_bosses = awarded_bosses + 1 end
		end,
		visit_shop = function(state)
			visited_shops = visited_shops + 1
			if emit_asteroid_on_shop then
				state.decisions[#state.decisions + 1] = { type = "use_consumable", key = "c_mp_asteroid" }
				emit_asteroid_on_shop = false
			end
			return { keys = {}, supported_keys = {} }
		end,
		shop_phase = function(state, keys)
			return Peer.dependencies.Simulator.visit_shop(state, keys)
		end,
		set_ante = function(state, ante) state.ante = ante end,
		plan_skips = function() return planned_skips end,
	snapshot = function() return {} end,
		export = function(state, ante_states) return { decisions = state.decisions, ante_states = ante_states or {} } end,
	},
}
Peer.run = { decisions = {}, jokers = {}, joker_state = {}, deck = {}, money = 0 }
Peer.replay = { ante_snapshots = {}, _multibots_state = { ante_states = {} } }
Peer.in_game = true
Peer.pvp = false
Peer.ante = 2
Peer.phase = 1
Peer.elapsed = 0
Peer.timeline = {
	{ type = "loc_selecting", duration = 0 },
	{ type = "loc_playing", blind = "Small", duration = math.huge },
}

Peer.update(0)
assert(sent[1] and sent[1].action == "newRound",
	"entering the Small Blind must announce a distinct Multiplayer round")

Peer.phase = 1
Peer.elapsed = 0
Peer.timeline = {
	{ type = "loc_shop", duration = 0 },
	{ type = "loc_playing", blind = "Big", duration = math.huge },
}
Peer.update(0)
assert(sent[3] and sent[3].action == "newRound",
	"entering the Big Blind in the same Ante must announce another Multiplayer round")

G.GAME.round_resets.ante = 1 -- A watched bot snapshot may rewind the shared presentation board.
Peer.ante, Peer.phase, Peer.elapsed = 2, 1, 0
Peer.run.the_order = false
Peer.timeline = {
	{ type = "loc_selecting", duration = 0 },
	{ type = "loc_playing", blind = "Boss", duration = 0 },
	{ type = "loc_shop", duration = math.huge },
}
Peer.update(0)
assert(Peer.ante == 2 and Peer.next_ante_delay ~= nil,
	"a completed Boss shop must remain visible for the configured shop duration")
Peer.update(18)
assert(Peer.ante == 3 and boss_rounds == 1 and awarded_bosses == 1 and visited_shops == 1,
	"bot progression must advance independently of a spectator snapshot's shared Ante")

sent = {}
Peer.pending = { behavior = { timer_player = true, skip_mode = "reactive" } }
Peer.timer_enabled = true
Peer.timer_sent, Peer.ready_sent = false, false
Peer.ante, Peer.phase, Peer.elapsed = 3, 1, 0
Peer.timeline = {
	{ type = "loc_selecting", duration = 0 },
	{ type = "loc_ready", duration = math.huge },
}
Peer.update(0)
local timer_index, ready_index
for index, message in ipairs(sent) do
	if message.action == "startAnteTimer" then timer_index = index end
	if message.action == "readyBlind" then ready_index = index end
end
assert(timer_index and ready_index and timer_index < ready_index,
	"bot timer pressure must be sent before readiness can start the PvP Blind")

sent, planned_skips = {}, { Small = true }
G.GAME.round_resets.ante = 4
Peer.ante, Peer.phase, Peer.elapsed = nil, 1, 0
Peer.ready_sent, Peer.timer_sent = false, false
Peer.update(0)
local skip_message
for _, message in ipairs(sent) do if message.action == "skip" then skip_message = message end end
assert(skip_message and skip_message.skips == 1,
	"a planned Blind skip must be published through Multiplayer's skip action")

sent = {}
Peer.phase, Peer.elapsed, Peer.ready_sent, Peer.timer_sent = 1, 0, false, false
Peer.timeline = {
	{ type = "loc_selecting", duration = 0 },
	{ type = "loc_ready", duration = math.huge },
}
Peer.update(0)
local skip_timer
for _, message in ipairs(sent) do
	if message.action == "startAnteTimer" then skip_timer = message.time end
end
assert(skip_timer == 180,
	"one bot Blind skip must add the configured Timer Increment to its announced Ante timer")

sent = {}
Peer.in_game, Peer.ante, Peer.pvp = true, 1, false
Peer.pvp_start_ante = 2
Peer.run.decisions = {}
Peer.handle({ action = "soldJoker" })
assert(pvp_effects[1] == "soldJoker",
	"opponent Joker sales must reach Taxes tracking outside the PvP Blind")
pvp_effects = {}
Peer.handle({ action = "startBlind" })
assert(Peer.pvp and pvp_steps == 1 and Peer.bot_hands == 4,
	"the server's PvP start must be honored even if the bot's local Ante is behind")
local pvp_location
for _, message in ipairs(sent) do
	if message.action == "setLocation" then pvp_location = message.location end
end
assert(pvp_location == "loc_playing-bl_mp_nemesis",
	"starting PvP must update the bot location instead of leaving it marked as selecting")
Peer.handle({ action = "asteroid" })
assert(pvp_effects[1] == "asteroid", "opponent PvP effects must reach the live bot simulation")
Peer.handle({ action = "enemyInfo", handsLeft = 3, score = 50, skips = 2 })
assert(pvp_steps == 2 and Peer.bot_hands == 3,
	"the bot should answer one player hand and stop again when remaining hands match")
assert(Peer.run.opponent_skips == 2,
	"enemy skip counts must reach Skip-Off's live simulation state")
emit_asteroid_on_shop = true
Peer.handle({ action = "endPvP", lost = false })
assert(Peer.pvp_session == nil, "ending PvP should finalize and discard its live round session")
Peer.pvp_start_ante = nil
local sent_asteroid = false
for _, message in ipairs(sent) do if message.action == "asteroid" then sent_asteroid = true end end
assert(sent_asteroid, "a consumed bot Asteroid must be relayed to the Multiplayer opponent")

Peer.run.jokers = { "j_joker" }
Peer.run.joker_editions = { j_joker = "foil" }
Peer.run.deck = { { suit = "Spades", rank = 14, enhancement = "m_bonus", edition = "foil", seal = "Red" } }
G.jokers = { cards = { { encoded = "j_runner-none-none-none" } } }
G.playing_cards = {
	{ encoded = "H-K-m_mult-none-Gold" },
	{ encoded = "S-A-c_base-none-none" },
}
Peer.in_game, Peer.pvp = true, false
Peer.handle({ action = "startBlind" })
Peer.handle({ action = "enemyInfo", handsLeft = 3, score = 250 })
Peer.handle({ action = "winGame" })
assert(not Peer.in_game and Peer.timeline == nil and Peer.next_ante_delay == nil,
	"a terminal server message must stop queued phase progression")
local final_bot, final_player, terminal_pvp, terminal_pvp_index, final_bot_index
for index, entry in ipairs(log_entries) do
	if entry.kind == "FINAL_BOT" then final_bot = entry end
	if entry.kind == "FINAL_PLAYER" then final_player = entry end
	if entry.kind == "PVP" and entry.values.bot_score == 300 and entry.values.player_score == 250 then
		terminal_pvp, terminal_pvp_index = entry, index
	end
	if entry.kind == "FINAL_BOT" then final_bot_index = index end
end
assert(terminal_pvp and terminal_pvp_index < final_bot_index,
	"a terminal PvP result must be recorded before final logs and report rendering")
assert(final_bot and final_bot.values.jokers == "j_joker@foil"
	and final_bot.values.deck == "S-A-m_bonus-foil-Red",
	"terminal logs must include the bot's final Jokers and complete card encoding")
assert(final_player and final_player.values.jokers == "j_runner-none-none-none"
	and final_player.values.deck == "H-K-m_mult-none-Gold;S-A-none-none-none",
	"terminal logs must include the human opponent's final Jokers and deck")

sent = {}
Peer.running = true
Peer.handle({ action = "stopGame" })
assert(#sent == 1 and sent[1].action == "readyLobby",
	"returning from results must ready the bot for a same-lobby rematch")
Peer.handle({ action = "stopGame" })
assert(#sent == 1, "duplicate stopGame messages must not send duplicate lobby readiness")
local terminal_count = 0
for _, entry in ipairs(log_entries) do
	if entry.kind == "FINAL_BOT" or entry.kind == "FINAL_PLAYER" then terminal_count = terminal_count + 1 end
end
assert(terminal_count == 2, "returning to the lobby must not duplicate terminal build logs")

sent = {}
MP.LOBBY.multibots_bot_ids = { ["bot-opponent"] = true }
Peer.nemesis_id = "bot-opponent"
Peer.in_game, Peer.ante, Peer.pvp = true, 2, false
Peer.run.decisions = {}
local steps_before_bot_match = pvp_steps
Peer.handle({ action = "startBlind" })
assert(pvp_steps == steps_before_bot_match + 1,
	"a bot opponent should not wait for a human to play the opening PvP hand")
Peer.handle({ action = "enemyInfo", handsLeft = 3, score = 150 })
assert(pvp_steps == steps_before_bot_match + 2,
	"a bot should continue PvP when its bot opponent reports a new hand")
MP.LOBBY.multibots_bot_ids = nil
Peer.nemesis_id = nil

sent = {}
MP.LOBBY.multibots_bot_ids = { ["bot-opponent"] = true, ["bot-self"] = true }
MP.LOBBY.players = {
	{ id = "human-1" },
	{ id = "human-2" },
	{ id = "bot-opponent" },
	{ id = "bot-self" },
}
MP.LOBBY.multibots_human_hands = nil
Peer.player_id, Peer.nemesis_id = "bot-self", "bot-opponent"
Peer.in_game, Peer.ante, Peer.pvp = true, 2, false
local previous_pvp_steps = pvp_steps
pvp_steps = 0
local steps_before_human_frontier = pvp_steps
Peer.handle({ action = "startBlind" })
assert(pvp_steps == steps_before_human_frontier,
	"a bot facing another bot must wait when the lobby contains humans")
Peer.handle({ action = "enemyInfo", playerId = "human-1", handsLeft = 3, score = 100 })
assert(pvp_steps == steps_before_human_frontier,
	"one human playing must not trigger bots while another human still has more hands")
Peer.handle({ action = "enemyInfo", playerId = "human-2", handsLeft = 3, score = 200 })
assert(pvp_steps == steps_before_human_frontier + 2 and Peer.bot_hands == 3,
	"bots should play only until their remaining hands match the most active human")
Peer.handle({ action = "enemyInfo", playerId = "human-1", handsLeft = 2, score = 300 })
assert(pvp_steps == steps_before_human_frontier + 2,
	"bots should continue waiting while any human has more hands remaining")
Peer.handle({ action = "enemyInfo", playerId = "human-2", handsLeft = 2, score = 350 })
assert(pvp_steps == steps_before_human_frontier + 3 and Peer.bot_hands == 2,
	"bots should catch up when the lobby's maximum human hand count decreases")
MP.LOBBY.multibots_bot_ids = nil
MP.LOBBY.multibots_human_hands = nil
Peer.player_id, Peer.nemesis_id = nil, nil
pvp_steps = previous_pvp_steps

sent = {}
MP.LOBBY.players = {
	{ id = "host" },
	{ id = "human-2" },
}
MP.LOBBY.multibots_human_hands = nil
Peer.lobby_players = nil
Peer.player_id, Peer.nemesis_id = "bot-self", "host"
Peer.in_game, Peer.ante, Peer.pvp = true, 2, false
Peer.player_lives_by_id = {}
pvp_steps = 0
Peer.handle({ action = "startBlind" })
Peer.handle({ action = "enemyInfo", playerId = "human-2", handsLeft = 1, score = 100 })
assert(pvp_steps == 0, "a living human with hands remaining must still gate bot hands")
Peer.handle({ action = "enemyInfo", playerId = "host", handsLeft = 4, score = 100, lives = 0 })
assert(pvp_steps == 4 and Peer.bot_hands == 1,
	"an eliminated host's stale hands must not block bots from catching up to living humans")
MP.LOBBY.players = nil
MP.LOBBY.multibots_human_hands = nil
Peer.player_id, Peer.nemesis_id = nil, nil
pvp_steps = previous_pvp_steps

sent = {}
MP.LOBBY.players = {
	{ id = "host" },
	{ id = "human-2" },
	{ id = "bot-self" },
}
MP.LOBBY.multibots_bot_ids = { ["bot-self"] = true }
MP.LOBBY.multibots_human_hands = nil
Peer.lobby_players = nil
Peer.player_id, Peer.nemesis_id = "bot-self", "host"
Peer.in_game, Peer.ante, Peer.pvp = true, 2, false
Peer.player_lives_by_id = {}
pvp_steps = 0
Peer.handle({ action = "startBlind" })
Peer.handle({ action = "enemyInfo", playerId = "human-2", handsLeft = 1, score = 100 })
assert(pvp_steps == 0, "the bot should wait while the host still has the most hands")
Peer.handle({ action = "lobbyInfo", players = {
	{ id = "host", is_spectator = true },
	{ id = "human-2" },
	{ id = "bot-self" },
} })
assert(pvp_steps == 4 and Peer.bot_hands == 1,
	"a lobby update marking the host as a spectator must release its stale hand gate")

sent = {}
MP.LOBBY.players = { { id = "host", is_spectator = true }, { id = "bot-self" } }
MP.LOBBY.multibots_human_hands = nil
Peer.lobby_players = nil
Peer.player_id, Peer.nemesis_id = "bot-self", "host"
Peer.in_game, Peer.ante, Peer.pvp = true, 2, false
pvp_steps = 0
Peer.handle({ action = "startBlind" })
assert(pvp_steps == 5 and Peer.bot_hands == 0,
	"an already-spectating host must not leave the bot waiting at its initial hand count")
MP.LOBBY.players = nil
MP.LOBBY.multibots_bot_ids = nil
MP.LOBBY.multibots_human_hands = nil
Peer.lobby_players = nil
Peer.player_id, Peer.nemesis_id = nil, nil
pvp_steps = previous_pvp_steps

MP.LOBBY.multibots_bot_ids = { ["bot-a"] = true, ["bot-b"] = true }
Peer.player_id, Peer.nemesis_id = "bot-b", nil
Peer.player_lives_by_id, Peer.pvp_scores_by_id, Peer.last_pvp_scores_by_id = {}, {}, {}
Peer.pvp_result = { score = "501" }
Peer.in_game, Peer.pvp = true, true
Peer.handle({ action = "enemyInfo", playerId = "bot-a", handsLeft = 2, score = "500", lives = 3 })
Peer.handle({ action = "playerInfo", lives = 4 })
Peer.handle({ action = "endPvP" })
assert(Peer.player_lives_by_id["bot-a"] == 3 and Peer.player_lives_by_id["bot-b"] == 4
	and Peer.last_pvp_scores_by_id["bot-a"] == "500"
	and Peer.last_pvp_scores_by_id["bot-b"] == "501",
	"PvP enemy/player updates must retain lives and each bot's final score for winner resolution")

local function resolve_alone(player_id, bot_ids, lives, scores, players)
	MP.LOBBY.multibots_bot_ids = {}
	for _, bot_id in ipairs(bot_ids) do MP.LOBBY.multibots_bot_ids[bot_id] = true end
	Peer.player_id, Peer.nemesis_id = player_id, nil
	Peer.lobby_players = players
	Peer.player_lives_by_id = lives
	Peer.last_pvp_scores_by_id = scores
	Peer.pvp_scores_by_id, Peer.pvp_session, Peer.pvp_result = {}, nil, nil
	Peer.in_game, Peer.pvp, Peer.terminal_logged = true, false, false
	local terminal_count = #terminal_actions
	Peer.handle({ action = "aloneGame" })
	return terminal_actions[terminal_count + 1]
end

local bot_roster = {
	{ id = "bot-a" }, { id = "bot-b" }, { id = "bot-c" },
	{ id = "human", isOwner = true },
}
local bot_ids = { "bot-a", "bot-b", "bot-c" }
MP.LOBBY.multibots_bot_ids = { ["bot-a"] = true, ["bot-b"] = true, ["bot-c"] = true }
Peer.player_id, Peer.nemesis_id = "bot-b", nil
Peer.lobby_players = bot_roster
Peer.player_lives_by_id = { ["bot-a"] = 4, ["bot-b"] = 4, ["bot-c"] = 3, human = 1 }
Peer.last_pvp_scores_by_id = { ["bot-a"] = "500", ["bot-b"] = "700" }
Peer.human_players_seen = true
Peer.in_game, Peer.pvp, Peer.terminal_logged = true, false, false
local before_human_elimination = #terminal_actions
Peer.handle({ action = "enemyInfo", playerId = "human", handsLeft = 0, score = "0", lives = 0 })
assert(terminal_actions[before_human_elimination + 1] == "winGame",
	"eliminating the last human must immediately award the bot-only winner")

assert(resolve_alone("bot-a", bot_ids,
	{ ["bot-a"] = 4, ["bot-b"] = 4, ["bot-c"] = 3, human = 0 },
	{ ["bot-a"] = "900", ["bot-b"] = "100", ["bot-c"] = "999999" }, bot_roster) == "winGame",
	"a bot with the most lives must win even if a lower-life bot scored more")
assert(resolve_alone("bot-b", bot_ids,
	{ ["bot-a"] = 4, ["bot-b"] = 4, ["bot-c"] = 2, human = 0 },
	{ ["bot-a"] = "90071992547409930", ["bot-b"] = "90071992547409931" }, bot_roster) == "winGame",
	"when lives tie, the highest exact last-PvP score must determine the winner")
assert(resolve_alone("bot-a", bot_ids,
	{ ["bot-a"] = 4, ["bot-b"] = 4, ["bot-c"] = 2, human = 0 },
	{ ["bot-a"] = "500", ["bot-b"] = "500" }, bot_roster) == "winGame",
	"an unresolved lives and score tie must go to the lowest player ID")
assert(resolve_alone("bot-a", bot_ids,
	{ ["bot-a"] = 4, ["bot-b"] = 4, ["bot-c"] = 2, human = 1 },
	{ ["bot-a"] = "500", ["bot-b"] = "900" }, bot_roster) == "loseGame",
	"bots must not claim victory while a human still has lives")

local left_lobby = 0
MP.LOBBY.code = "BOTAA"
MP.ACTIONS = { leave_lobby = function() left_lobby = left_lobby + 1 end }
Peer.pending = { difficulty = "expert" }
Peer.transport, Peer.running = "local", true
Peer.local_server = { in_game = false }
Peer.bot_skips, Peer.skips_since_pvp = 4, 2
Peer.reset(true)
assert(left_lobby == 1 and MP.LOBBY.code == nil,
	"resetting a completed bot match must leave its old lobby")
assert(Peer.pending == nil and Peer.transport == nil and Peer.local_server == nil and not Peer.running,
	"resetting must discard the finished peer and embedded server")
assert(Peer.bot_skips == 0 and Peer.skips_since_pvp == 0,
	"per-match counters must not leak into the next bot match")

MP.PROTOCOL = { VERSION = 2 }
MP.SPECTATOR = {
	is_spectating = true,
	target_player_id = "bot-stream",
	current_step = 0,
	pending_replay_queue = {},
}
MP.MULTIBOTS_ANIMATION_STATE = {
	queue_count = nil, queue_stable = 0, wait_elapsed = 0, quiet_elapsed = 0,
}
G.STATES = { SELECTING_HAND = 1, SHOP = 2 }
Peer.player_id = "bot-stream"
Peer.spectator_watchers = { ["spectator-1"] = true }
Peer.spectator_step = 0
Peer.spectator_outbox = {}
Peer.spectator_waiting_step = nil
Peer.ante, Peer.phase, Peer.elapsed = 1, 1, 0
Peer.run = {
	decisions = {}, jokers = {}, joker_state = {}, joker_editions = {},
	levels = {}, deck = {}, draw_pile = {}, used_cards = {}, hand = {},
	consumables = {}, money = 5, hands_per_round = 4, discards_per_round = 3,
	consumable_limit = 2, joker_limit = 5, round = 1, the_order = false,
}
Peer.replay = { ante_snapshots = {}, _multibots_state = { ante_states = {} } }
Peer.in_game = true
Peer.timeline = {
	{ type = "loc_selecting", duration = 0 },
	{ type = "loc_playing", blind = "Small", duration = math.huge },
}
Peer.dependencies.Simulator.play_round = function(state, _, blind)
	state.decisions[#state.decisions + 1] = {
		type = "play", ante = 1, round = blind,
		hand_contents = "S2:Spades:2:none:none:none",
		selected = "S2:Spades:2:none:none:none",
		current_score = 0, hands_remaining = 4, discards_remaining = 3, money = 5,
		snapshot = "draw:H3:Hearts:3:none:none:none",
	}
	state.decisions[#state.decisions + 1] = {
		type = "play", ante = 1, round = blind,
		hand_contents = "H3:Hearts:3:none:none:none",
		selected = "H3:Hearts:3:none:none:none",
		current_score = 5, hands_remaining = 3, discards_remaining = 3, money = 5,
		snapshot = "draw:D4:Diamonds:4:none:none:none|used:S2:Spades:2:none:none:none",
	}
	state.decisions[#state.decisions + 1] = {
		type = "buy_pack", key = "p_buffoon_normal_1",
		picked = "j_joker", revealed = "j_joker",
	}
	state.decisions[#state.decisions + 1] = {
		type = "buy_voucher", key = "v_overstock_norm",
	}
	return { hands = {}, score = 5, hands_left = 3, hands_used = 1, cleared = true }
end
Peer.spectator_shop_cards = { "p_buffoon_normal_1", "v_overstock_norm" }
sent = {}
Peer.update(0)
assert(#Peer.spectator_outbox == 8,
	"each scoring action needs its own hand snapshot, followed by shop purchases and pack picks")
assert(Peer.spectator_outbox[2].kind == "snapshot"
	and Peer.spectator_outbox[4].kind == "snapshot",
	"each simulated hand must be preceded by an authoritative spectator snapshot")
assert(encoded_boards[2].hand[1].id == 2 and encoded_boards[2].deck[1].id == 3
	and encoded_boards[4].hand[1].id == 3 and encoded_boards[4].deck[1].id == 4
	and encoded_boards[4].discard[1].id == 2,
	"each snapshot must restore that decision's hand, draw pile, and used-card pile")
Peer.update(0)
assert(sent[#sent].action == "spectatorActionStream"
	and sent[#sent].actionData == "SELECT_BLIND:1",
	"the first replay action should select the blind")
MP.SPECTATOR.current_step = 1
Peer.update(0)
assert(sent[#sent].action == "spectatorProvideSnapshot",
	"the hand snapshot must follow Blind selection instead of invalidating queued actions")
MP.SPECTATOR.current_step = 2
Peer.update(0)
assert(sent[#sent].action == "spectatorActionStream"
	and sent[#sent].actionData == "PLAY_HAND:3",
	"the scoring action should follow its authoritative hand/deck snapshot")
MP.SPECTATOR.current_step = 3
Peer.update(0)
assert(sent[#sent].action == "spectatorProvideSnapshot",
	"the second simulated hand must replace local draws before its action")
MP.SPECTATOR.current_step = 4
Peer.update(0)
assert(sent[#sent].actionData == "PLAY_HAND:5",
	"the second scoring action should follow its own authoritative snapshot")
MP.SPECTATOR.current_step = 5
Peer.update(0)
assert(sent[#sent].actionData == "BUY_BOOSTER:6:1",
	"the bot's Booster purchase should be replayed after scoring")
MP.SPECTATOR.current_step = 6
Peer.update(0)
assert(sent[#sent].actionData == "SELECT_PACK_CARD:7:1",
	"the bot's chosen Booster card should be picked after the pack opens")
MP.SPECTATOR.current_step = 7
Peer.update(0)
assert(sent[#sent].actionData == "BUY_CARD:8:1:shop_vouchers",
	"voucher purchases should target the Voucher shop area rather than the Joker area")
MP.SPECTATOR.current_step = 8
Peer.update(0)
Peer.phase, Peer.elapsed = 1, 0
Peer.timeline = {
	{ type = "loc_playing", blind = "Small", duration = 0 },
	{ type = "loc_shop", duration = math.huge },
}
Peer.update(0)
Peer.update(0)
assert(sent[#sent].action == "spectatorActionStream"
	and sent[#sent].actionData == "CASH_OUT:9",
	"the Blind payout action should be streamed after scoring completes")
Peer.phase, Peer.elapsed = 1, 0
Peer.timeline = {
	{ type = "loc_shop", duration = 0 },
	{ type = "loc_playing", blind = "Big", duration = math.huge },
}
Peer.update(0)
local sent_before_ack = #sent
Peer.update(0)
assert(#sent == sent_before_ack,
	"the next shop/Blind transition must wait until the payout action has completed")
MP.SPECTATOR.current_step = 9
Peer.update(0)
assert(sent[#sent].actionData == "TOGGLE_SHOP:10",
	"leaving the Shop should be replayed before selecting the next Blind")
MP.SPECTATOR.current_step = 10
Peer.update(0)
assert(sent[#sent].actionData == "SELECT_BLIND:11",
	"the next Blind should be selected only after the Shop transition")

print("peer_round_spec: ok")
