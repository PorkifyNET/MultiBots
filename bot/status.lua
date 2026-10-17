local Status = {
	_replay = nil,
	ante = nil,
	phase = 1,
	elapsed = 0,
	timeline = {},
	config = nil,
}

local default_pace = {
	selecting_seconds = 4,
	blind_base_seconds = 8,
	seconds_per_action = 5.5,
	minimum_blind_seconds = 25,
	shop_seconds = 18,
}

local function is_active()
	return MP
		and MP.GHOST
		and MP.GHOST.is_active()
		and MP.GHOST.replay
		and MP.GHOST.replay._multibots == true
end

local function localized(key)
	local dictionary = G.localization and G.localization.misc and G.localization.misc.dictionary
	return (dictionary and dictionary[key]) or key
end

local function blind_key(kind)
	return G.GAME
		and G.GAME.round_resets
		and G.GAME.round_resets.blind_choices
		and G.GAME.round_resets.blind_choices[kind]
		or ""
end

local function decision_count(replay, ante, round)
	local count = 0
	local state = replay and replay._multibots_state
	for _, decision in ipairs((state and state.decisions) or {}) do
		if decision.ante == ante and decision.round == round then count = count + 1 end
	end
	return count
end

local function pace_value(key)
	local pace = Status.config and Status.config.pace
	return tonumber(pace and pace[key]) or default_pace[key]
end

local function blind_duration(replay, ante, blind)
	local actions = decision_count(replay, ante, blind)
	return math.max(
		pace_value("minimum_blind_seconds"),
		pace_value("blind_base_seconds") + actions * pace_value("seconds_per_action")
	)
end

local function build_timeline(replay, ante, pvp_start_ante, skipped)
	skipped = skipped or {}
	local timeline = {
		{ type = "loc_selecting", duration = pace_value("selecting_seconds") },
	}
	if not skipped.Small then
		timeline[#timeline + 1] = { type = "loc_playing", blind = "Small", duration = blind_duration(replay, ante, "Small") }
		timeline[#timeline + 1] = { type = "loc_shop", duration = pace_value("shop_seconds") }
	end
	if not skipped.Big then
		timeline[#timeline + 1] = { type = "loc_playing", blind = "Big", duration = blind_duration(replay, ante, "Big") }
		timeline[#timeline + 1] = { type = "loc_shop", duration = pace_value("shop_seconds") }
	end
	if ante < (tonumber(pvp_start_ante) or 2) then
		timeline[#timeline + 1] = {
			type = "loc_playing",
			blind = "Boss",
			duration = blind_duration(replay, ante, "Boss"),
		}
		timeline[#timeline + 1] = { type = "loc_shop", duration = math.huge }
	else
		timeline[#timeline + 1] = { type = "loc_ready", duration = math.huge }
	end
	local ready_at = 0
	for _, phase in ipairs(timeline) do
		if phase.duration ~= math.huge then ready_at = ready_at + phase.duration end
	end
	return timeline, ready_at
end

local function set_location(location_type, blind)
	if not MP.GAME or not MP.GAME.enemy then return end
	local location_blind = blind and blind_key(blind) or ""
	local signature = location_type .. ":" .. location_blind
	if Status._signature == signature then return end
	Status._signature = signature
	MP.GAME.enemy.location_type = location_type
	MP.GAME.enemy.location = localized(location_type)
	MP.GAME.enemy.location_blind = location_blind
	MP.GAME.enemy.location_full = location_type .. "-" .. location_blind
	if MP.UI.update_enemy_location_render then MP.UI.update_enemy_location_render() end
end

local function reset_for_ante(replay, ante)
	Status.ante = ante
	Status.phase = 1
	Status.elapsed = 0
	local pvp_start = MP.LOBBY and MP.LOBBY.config and MP.LOBBY.config.pvp_start_round
	Status.timeline, Status.ready_at = build_timeline(replay, ante, pvp_start)
	Status._signature = nil
end

function Status.update(dt)
	if not is_active() or not G.GAME or not G.GAME.round_resets then
		Status._replay = nil
		return
	end
	local replay = MP.GHOST.replay
	local ante = G.GAME.round_resets.ante or 1
	if Status._replay ~= replay or Status.ante ~= ante then
		Status._replay = replay
		reset_for_ante(replay, ante)
	end

	local pvp_active = MP.is_pvp_boss and MP.is_pvp_boss() and G.GAME.facing_blind
	if pvp_active then
		set_location("loc_playing", G.GAME.blind_on_deck or "Boss")
	else
		Status.elapsed = Status.elapsed + (dt or 0)
		local phase = Status.timeline[Status.phase]
		while phase and Status.elapsed >= phase.duration do
			Status.elapsed = Status.elapsed - phase.duration
			Status.phase = math.min(Status.phase + 1, #Status.timeline)
			phase = Status.timeline[Status.phase]
		end
		if phase then set_location(phase.type, phase.blind) end
	end

	-- Match live Multiplayer exactly: opponent location replaces the round
	-- score only in blind selection and the shop. During every playable blind,
	-- restore the player's own round-score panel.
	local between_blinds = G.STATE == G.STATES.BLIND_SELECT or G.STATE == G.STATES.SHOP
	local location_visible = G.HUD and G.HUD:get_UIE_by_ID("mp_enemy_location_render") ~= nil
	local can_show = G.HUD and between_blinds and not MP.LOBBY.config.enemy_location_disabled
	if can_show and not location_visible and MP.UI.show_enemy_location then
		MP.UI.show_enemy_location()
	elseif not can_show and location_visible and MP.UI.hide_enemy_location then
		MP.UI.hide_enemy_location()
	end
end

function Status.is_active()
	return is_active()
end

function Status.configure(config)
	Status.config = config
end

function Status.build_timeline(replay, ante, pvp_start_ante, skipped)
	return build_timeline(replay, ante, pvp_start_ante, skipped)
end

function Status.seconds_until_ready()
	return math.max(0, (Status.ready_at or 0) - (Status.elapsed or 0))
end

function Status.install()
	local update_ref = Game.update
	function Game:update(dt)
		local result = update_ref(self, dt)
		Status.update(dt)
		return result
	end
end

return Status
