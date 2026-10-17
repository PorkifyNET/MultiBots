local Playback = {}

local function is_bot_replay()
	return MP.GHOST
		and MP.GHOST.is_active()
		and MP.GHOST.replay
		and MP.GHOST.replay._multibots == true
end

local function bot_hands_remaining()
	if MP.GHOST._hand_idx < 1 then
		local first = MP.GHOST._hands[1]
		return first and ((tonumber(first.hands_left) or 3) + 1) or 0
	end
	local current = MP.GHOST._hands[MP.GHOST._hand_idx]
	return current and (tonumber(current.hands_left) or 0) or 0
end

function Playback.hands_to_play(bot_hands, player_hands)
	return math.max(0, (tonumber(bot_hands) or 0) - (tonumber(player_hands) or 0))
end

local function catch_up_to_player(player_hands)
	local count = Playback.hands_to_play(bot_hands_remaining(), player_hands)
	local played = 0
	while played < count and not MP.GHOST.playback_exhausted() do
		if not MP.GHOST.advance_hand() then break end
		played = played + 1
	end
	return played
end

function Playback.install()
	local init_playback_ref = MP.GHOST.init_playback
	function MP.GHOST.init_playback(ante)
		local initialized = init_playback_ref(ante)
		if not initialized or not is_bot_replay() then return initialized end

		-- A normal ghost exposes its first hand immediately. A bot starts at four
		-- hands and waits for the player to spend one before answering.
		MP.GHOST._hand_idx = 0
		MP.GHOST._advancing = false
		MP.GAME.enemy.score = MP.INSANE_INT.empty()
		MP.GAME.enemy.real_score = MP.INSANE_INT.empty()
		MP.GAME.enemy.score_text = "0"
		MP.GAME.enemy.hands = bot_hands_remaining()
		MP.GAME.enemy.info_received = true
		return true
	end

	local current_target_ref = MP.GHOST.current_target_big
	function MP.GHOST.current_target_big()
		if is_bot_replay() and MP.GHOST._hand_idx < 1 then return to_big(0) end
		return current_target_ref()
	end

	local resolve_mid_ref = MP.GHOST.resolve_pvp_mid_hand
	function MP.GHOST.resolve_pvp_mid_hand(chips)
		if not is_bot_replay() then return resolve_mid_ref(chips) end
		local player_hands = G.GAME.current_round.hands_left or 0
		catch_up_to_player(player_hands)

		-- Once synchronized, do not let the score comparison make the bot dump
		-- additional hands. The next bot hand is unlocked by the next player hand.
		local beat_current = to_big(chips) >= MP.GHOST.current_target_big()
		if MP.GHOST.playback_exhausted() or not beat_current then return resolve_mid_ref(chips) end
		return false
	end

	local resolve_exhausted_ref = MP.GHOST.resolve_pvp_hands_exhausted
	function MP.GHOST.resolve_pvp_hands_exhausted(chips)
		if is_bot_replay() then
			-- The player's last hand reduces their count to zero. Let the bot answer
			-- with every hand it is now entitled to before resolving the round.
			catch_up_to_player(0)
		end
		return resolve_exhausted_ref(chips)
	end
end

return Playback
