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

print("peer_pool_spec: ok")
