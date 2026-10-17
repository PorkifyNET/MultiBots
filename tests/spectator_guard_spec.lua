local SpectatorGuard = dofile("bot/spectator_guard.lua")
local bot_ids = { ["bot-1"] = true }
local starts, stops, snapshots, actions, histories = 0, 0, 0, 0, 0
local shown, hidden = {}, 0
local spectator
spectator = {
	target_player_id = nil,
	is_spectating = false,
	start_spectating = function(target_id)
		starts = starts + 1
		spectator.target_player_id = target_id
		spectator.is_spectating = true
		return "started", target_id
	end,
	stop_spectating = function()
		stops = stops + 1
		spectator.is_spectating = false
		spectator.target_player_id = nil
		return "stopped"
	end,
	handle_spectator_history = function() histories = histories + 1 end,
	handle_spectator_action_stream = function() actions = actions + 1 end,
	handle_spectator_receive_snapshot = function() snapshots = snapshots + 1 end,
}

SpectatorGuard.install(
	spectator,
	function() return bot_ids end,
	function(target_id) shown[#shown + 1] = target_id end,
	function() hidden = hidden + 1 end
)

local result, target_id = spectator.start_spectating("bot-1")
assert(result == "started" and target_id == "bot-1" and starts == 1,
	"spectating a bot should enter spectator mode")
assert(shown[1] == "bot-1" and hidden == 0,
	"spectating a bot should show the unavailable gameplay placeholder")
spectator.handle_spectator_history({})
spectator.handle_spectator_action_stream({})
spectator.handle_spectator_receive_snapshot({})
assert(histories == 0 and actions == 0 and snapshots == 0,
	"bot gameplay events must not be applied beneath the placeholder")

local unavailable_shown = #shown
spectator.start_spectating("player-1")
assert(starts == 2 and hidden == 1 and #shown == unavailable_shown,
	"switching to a normal player should remove the placeholder")
spectator.handle_spectator_history({})
spectator.handle_spectator_action_stream({})
spectator.handle_spectator_receive_snapshot({})
assert(histories == 1 and actions == 1 and snapshots == 1,
	"normal player spectator events must retain their existing behavior")

spectator.start_spectating("bot-1")
assert(shown[#shown] == "bot-1", "switching back to a bot should restore the placeholder")
assert(spectator.stop_spectating() == "stopped" and hidden == 2,
	"stopping spectating should remove the placeholder")

print("spectator_guard_spec: ok")
