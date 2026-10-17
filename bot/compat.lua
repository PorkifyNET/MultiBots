local Compat = {}

local function configured_stake()
	local lobby = MP and MP.LOBBY and MP.LOBBY.config or {}
	return tonumber(lobby.stake) or tonumber(G and G.GAME and G.GAME.stake) or 1
end

function Compat.install()
	-- Experimental Multiplayer's The Order reset hook expects Idol state to be
	-- initialized, but its snapshot playback can clear it between rounds.
	if MP and type(reset_idol_card) == "function" and not MP._multibots_idol_card_guard then
		local reset_idol_card_ref = reset_idol_card
		function reset_idol_card(...)
			local current_round = G and G.GAME and G.GAME.current_round
			if type(current_round) == "table" and current_round.idol_card == nil then
				current_round.idol_card = {}
			end
			return reset_idol_card_ref(...)
		end
		MP._multibots_idol_card_guard = true
	end

	-- Some deployed Multiplayer API servers still omit `stake` from startGame.
	-- Multiplayer 0.5.5 passes that nil value to both the replay manifest and
	-- lobby_start_run, even though the authoritative value is in lobbyOptions.
	-- Fill the missing field at those two public boundaries without replacing
	-- Multiplayer's private startGame action handler.
	if MP and MP.RLOG and type(MP.RLOG.begin_run) == "function" and not MP.RLOG._multibots_stake_default then
		local begin_run_ref = MP.RLOG.begin_run
		function MP.RLOG.begin_run(manifest)
			manifest = manifest or {}
			if tonumber(manifest.stake) == nil then manifest.stake = configured_stake() end
			return begin_run_ref(manifest)
		end
		MP.RLOG._multibots_stake_default = true
	end

	if G and G.FUNCS and type(G.FUNCS.lobby_start_run) == "function"
		and not G.FUNCS._multibots_stake_default then
		local lobby_start_run_ref = G.FUNCS.lobby_start_run
		function G.FUNCS.lobby_start_run(e, args)
			args = args or {}
			if tonumber(args.stake) == nil then args.stake = configured_stake() end
			return lobby_start_run_ref(e, args)
		end
		G.FUNCS._multibots_stake_default = true
	end
end

return Compat
