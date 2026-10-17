local SpectatorGuard = {}

local function pack(...)
	return { n = select("#", ...), ... }
end

local function is_bot_target(target_id, bot_ids)
	return target_id ~= nil and bot_ids and bot_ids[tostring(target_id)] == true
end

function SpectatorGuard.install(spectator, get_bot_ids, show_unavailable, hide_unavailable)
	local start_spectating = spectator and spectator.start_spectating
	if type(start_spectating) ~= "function" then
		error("Experimental Multiplayer spectator API is unavailable")
	end

	spectator.start_spectating = function(target_id, ...)
		local results = pack(start_spectating(target_id, ...))
		if is_bot_target(target_id, get_bot_ids()) then
			show_unavailable(target_id)
		else
			hide_unavailable()
		end
		return table.unpack(results, 1, results.n)
	end

	local stop_spectating = spectator.stop_spectating
	if type(stop_spectating) == "function" then
		spectator.stop_spectating = function(...)
			hide_unavailable()
			return stop_spectating(...)
		end
	end

	for _, method_name in ipairs({
		"handle_spectator_history",
		"handle_spectator_action_stream",
		"handle_spectator_receive_snapshot",
	}) do
		local handler = spectator[method_name]
		if type(handler) == "function" then
			local function wrap(original_handler)
				return function(payload, ...)
					if spectator.is_spectating
						and is_bot_target(spectator.target_player_id, get_bot_ids()) then
						return
					end
					return original_handler(payload, ...)
				end
			end
			spectator[method_name] = wrap(handler)
		end
	end
end

return SpectatorGuard
