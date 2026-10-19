local PeerPool = dofile("bot/peer_pool.lua")
local starts = {}

PeerPool.configure(function()
	return {
		start = function(setup)
			starts[#starts + 1] = setup
			return true
		end,
		update = function() end,
		reset = function() end,
		is_active = function() return true end,
	}
end)

assert(PeerPool.start({ name = "MultiBot", bot_blind_col = 2, difficulty = "expert" }))
assert(PeerPool.start({ name = "Robot", bot_blind_col = 2, difficulty = "expert" }))
assert(PeerPool.start({ name = "MultiBot", bot_blind_col = 2, difficulty = "expert" }))
assert(PeerPool.count() == 3 and starts[1].name == "MultiBot",
	"the first private-lobby bot must keep its configured identity")
assert(starts[2].name == "Robot",
	"bots with different configured names must not receive a numeric suffix")
assert(starts[3].name == "MultiBot 2" and starts[3].bot_blind_col == 4,
	"only a repeated bot name must receive a distinct numeric suffix")
assert(starts[1].decision_temperature == 0.15 and starts[2].decision_temperature == 0.30
	and starts[3].decision_temperature == 0.50,
	"Expert peers should receive distinct bounded decision temperatures")
assert(PeerPool.start({ name = "CaveBot", bot_blind_col = 2, difficulty = "expert" }))
assert(starts[4].decision_temperature == 0.75,
	"the fourth Expert peer should receive the warmest bounded temperature")

PeerPool.reset(false)
local factory_peers, published = {}, {}
PeerPool.configure(function()
	local peer = {
		start = function() return true end,
		update = function() end,
		reset = function() end,
		is_active = function() return true end,
	}
	factory_peers[#factory_peers + 1] = peer
	return peer
end)
PeerPool.on_change(function(_, player_ids) published[#published + 1] = player_ids end)
MP = { LOBBY = { players = {} } }
assert(PeerPool.start({ name = "MultiBot", difficulty = "expert" }))
MP.LOBBY.players = { { id = "host" }, { id = "bot-1" } }
PeerPool.update(0)
assert(#published[#published] == 0,
	"the roster can list a bot before that bot has read its own player ID")
factory_peers[1].player_id = "bot-1"
PeerPool.update(0)
assert(published[#published][1] == "bot-1",
	"a bot's player ID must be published once the bot learns it, without another roster change")
MP = nil

print("peer_pool_spec: ok")
