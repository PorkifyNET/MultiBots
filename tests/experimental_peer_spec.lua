package.preload.json = function()
	return {
		encode = function() return "{}" end,
		decode = function(raw)
			if raw == "kicked" then
				return {
					version = 2, family = "lobby", action = "kicked",
					payload = { message = "removed" },
				}
			end
			return {}
		end,
	}
end

MP = {
	PROTOCOL = {
		VERSION = 2,
		build_v2_packet_for_schema = function(family, schema_action, action, payload)
			return {
				version = 2, family = family, schema_action = schema_action,
				action = action, payload = payload or {},
			}
		end,
	},
}

local Peer = dofile("bot/peer.lua")
Peer.pending = { options = {} }

local identity = Peer._translate_outgoing({
	action = "username", username = "Test Bot", blindCol = 4, modHash = "same",
})
assert(identity.family == "system" and identity.action == "identity",
	"experimental peers must send protocol-v2 identity packets")
assert(identity.payload.username == "Test Bot" and identity.payload.blindCol == 4,
	"experimental identity must keep the bot name and blind colour separate")

local ready = Peer._translate_outgoing({ action = "readyBlind", handsLeft = 5 })
assert(ready.family == "match" and ready.action == "readyBlind",
	"experimental peers must send match-intent readiness")
assert(ready.payload.blindRow == "Boss" and ready.payload.blindKind == "pvp"
	and ready.payload.handsLeft == 5,
	"bot readiness must identify the PvP Boss row")

Peer.player_id = "bot-1"
local spectator_snapshot = Peer._translate_outgoing({
	action = "spectatorProvideSnapshot", spectatorPlayerId = "spectator-1", snapshotData = "{}",
})
assert(spectator_snapshot.family == "feature" and spectator_snapshot.action == "spectatorProvideSnapshot",
	"experimental bots must answer spectator snapshot requests on the feature channel")
assert(spectator_snapshot.payload.targetPlayerId == "bot-1"
	and spectator_snapshot.payload.spectatorPlayerId == "spectator-1",
	"spectator snapshots must identify both the bot target and requesting spectator")

local spectator_action = Peer._translate_outgoing({
	action = "spectatorActionStream", actionData = '{"step":7,"type":"PLAY_HAND"}', stepIndex = 7,
})
assert(spectator_action.family == "feature" and spectator_action.action == "spectatorActionStream",
	"experimental bots must publish replayable spectator actions on the feature channel")
assert(spectator_action.payload.stepIndex == 7
	and spectator_action.payload.actionData == '{"step":7,"type":"PLAY_HAND"}',
	"spectator actions must preserve their encoded action and sequence number")

local spectator_request = Peer._translate_incoming({
	version = 2, family = "feature", action = "spectatorRequestSnapshot",
	payload = { targetPlayerId = "bot-1", spectatorPlayerId = "spectator-1" },
})
assert(spectator_request.action == "spectatorRequestSnapshot"
	and spectator_request.spectatorPlayerId == "spectator-1",
	"experimental bots must retain routed spectator snapshot requests")

local joined = Peer._translate_incoming({
	version = 2, family = "lobby", action = "joined", payload = {
		playerId = "bot-1", options = { ruleset = "ruleset_mp_experimental" },
		players = {
			{ id = "human-1", isOwner = true },
			{ id = "bot-1", nemesisPlayerId = "human-2" },
		},
	},
})
assert(joined.action == "joinedLobby" and Peer.player_id == "bot-1",
	"experimental lobby snapshots must initialize the bot peer")
assert(Peer.nemesis_id == "human-2" and Peer.pending.options.ruleset == "ruleset_mp_experimental",
	"experimental peers must retain their assigned opponent and lobby options")

local host_action = Peer._translate_outgoing({ action = "makePlayerHost", playerId = "human-1" })
local kick_action = Peer._translate_outgoing({ action = "kickPlayer", playerId = "bot-1" })
assert(host_action.family == "lobby" and host_action.action == "makeHost"
	and host_action.payload.playerId == "human-1",
	"experimental peers must return host status through the lobby action")
assert(kick_action.family == "lobby" and kick_action.action == "kick"
	and kick_action.payload.playerId == "bot-1",
	"experimental peers must be able to remove bots through the lobby action")

local host_actions = {}
Peer.send = function(message) host_actions[#host_actions + 1] = message end
Peer.handle(joined)
assert(Peer.previous_host_id == "human-1",
	"experimental peers must remember the original lobby owner for host recovery")
MP.LOBBY = { multibots_bot_ids = { ["bot-1"] = true, ["bot-2"] = true } }
Peer.handle(Peer._translate_incoming({
	version = 2, family = "lobby", action = "snapshot", payload = {
		isHost = true,
		players = { { id = "human-1", isOwner = true }, { id = "bot-1" } },
	},
}))
assert(host_actions[#host_actions].action == "makePlayerHost"
	and host_actions[#host_actions].playerId == "human-1",
	"a bot that gains host while the original owner remains must return host status")

host_actions = {}
Peer.host_recovery_attempted = false
Peer.handle(Peer._translate_incoming({
	version = 2, family = "lobby", action = "playerLeft",
	payload = { playerId = "human-1", isHost = true },
}))
local kicked_bots = {}
for _, action in ipairs(host_actions) do
	if action.action == "kickPlayer" then kicked_bots[action.playerId] = true end
end
assert(kicked_bots["bot-1"] and kicked_bots["bot-2"],
	"a bot that inherits host after the original owner leaves must kick every known bot")

local end_pvp = Peer._translate_incoming({
	version = 2, family = "match", action = "endPvp", payload = { lost = true },
})
assert(end_pvp.action == "endPvP" and end_pvp.lost == true,
	"experimental match outcomes must feed the existing bot lifecycle")

local alone = Peer._translate_incoming({
	version = 2, family = "endgame", action = "alone", payload = {},
})
assert(alone.action == "aloneGame",
	"experimental alone outcomes must reach the bot-only winner resolver")

local kicked = Peer._translate_incoming({
	version = 2, family = "lobby", action = "kicked", payload = { message = "removed" },
})
assert(kicked.action == "multibotsKicked",
	"a kicked experimental bot must close only its own peer")

local incoming = {
	pop = function(self)
		if self.cleared then return nil end
		self.cleared = true
		return "kicked"
	end,
	clear = function(self) self.cleared = true end,
}
Peer.transport, Peer.incoming = "remote", incoming
Peer.update(0)
assert(Peer.incoming == nil,
	"processing a kick must reset the peer without reading from the cleared incoming queue")

G = { E_MANAGER = { queues = { base = { {}, {}, {} } } } }
Peer.transport = "remote"
local incoming_reads = 0
Peer.incoming = {
	pop = function()
		incoming_reads = incoming_reads + 1
		return nil
	end,
}
MP.MULTIBOTS_ANIMATION_STATE = {
	queue_count = nil, queue_stable = 0, wait_elapsed = 0, quiet_elapsed = 0,
}
Peer.update(0.1)
assert(incoming_reads == 0,
	"experimental peers must pause incoming actions while game animations are queued")
G.E_MANAGER.queues = {}
Peer.update(0.05)
assert(incoming_reads == 0,
	"experimental peers must wait for a short settled interval after animations drain")
Peer.update(0.05)
assert(incoming_reads > 0,
	"experimental peers must resume after the animation queue remains empty")

print("experimental_peer_spec: ok")
