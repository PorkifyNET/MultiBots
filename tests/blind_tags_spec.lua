-- A bot that reaches an Ante before (or after) the host
-- skips for the tags of its own Ante, not for whatever the host shows right now.
package.preload.json = function()
	return { encode = function() return "{}" end, decode = function() return {} end }
end
function sendDebugMessage() end
local warnings = {}
function sendWarnMessage(message) warnings[#warnings + 1] = message end

local function hash(value)
	local result = 0
	for index = 1, #tostring(value) do result = (result * 31 + tostring(value):byte(index)) % 1009 end
	return result / 1009
end
function pseudohash(value) return hash(value) end
function pseudoseed(key)
	local random = G.GAME.pseudorandom
	if random[key] == nil then random[key] = hash(key .. (random.seed or "")) end
	random[key] = (0.211 + random[key] * 1.618) % 1
	return (random[key] + (random.hashed_seed or 0)) / 2
end
function pseudorandom_element(values, seed)
	return values[math.floor((tonumber(seed) or 0) * #values * 7) % #values + 1]
end
-- Like the game: one "Tag" queue; some tags only from Ante 2.
local TAGS = {
	{ key = "tag_uncommon" }, { key = "tag_rare" }, { key = "tag_holo" }, { key = "tag_economy" },
	{ key = "tag_investment" }, { key = "tag_negative", min_ante = 2 }, { key = "tag_orbital", min_ante = 2 },
}
function get_current_pool(kind, _, _, append)
	assert(kind == "Tag", "only tags are polled here")
	local pool = {}
	for _, tag in ipairs(TAGS) do
		if not tag.min_ante or tag.min_ante <= G.GAME.round_resets.ante then pool[#pool + 1] = tag.key end
	end
	return pool, "Tag" .. (append or "")
end
function get_next_tag_key(append)
	local pool, key = get_current_pool("Tag", nil, nil, append)
	return pseudorandom_element(pool, pseudoseed(key))
end

-- The host's game: a fresh run, its Ante 1 tags drawn at the start.
local function host_game(seed)
	G = { GAME = { pseudorandom = { seed = seed, hashed_seed = pseudohash(seed) }, round_resets = { ante = 1 } } }
	G.GAME.round_resets.blind_tags = { Small = get_next_tag_key(), Big = get_next_tag_key() }
end
local function host_next_ante()
	local resets = G.GAME.round_resets
	resets.ante = resets.ante + 1
	resets.blind_tags = { Small = get_next_tag_key(), Big = get_next_tag_key() }
end
-- Like the game: beating the Boss raises the Ante at once (end_round:
-- ease_ante), the next Ante's tags come only at cash out (G.FUNCS.cash_out,
-- which also sets blind_ante).
local function host_beats_boss()
	local resets = G.GAME.round_resets
	resets.blind_ante = resets.blind_ante or resets.ante
	resets.ante = resets.ante + 1
	resets.blind_states = { Small = "Defeated", Big = "Defeated", Boss = "Defeated" }
end
local function host_cashes_out()
	local resets = G.GAME.round_resets
	resets.blind_ante = resets.ante
	resets.blind_tags = { Small = get_next_tag_key(), Big = get_next_tag_key() }
	resets.blind_states = { Small = "Select", Big = "Upcoming", Boss = "Upcoming" }
end
MP = { LOBBY = { config = {} }, UTILS = {} }

local Order = dofile("bot/order.lua")
local Peer = dofile("bot/peer.lua")
Peer.dependencies = { Order = Order }
local function reset_peer()
	Peer.blind_tag_seed, Peer.blind_tags_trusted, Peer.blind_tags_checked = nil, nil, nil
end

-- What the host will see in every Ante, for comparison.
host_game("*TAGSEED")
local expected = { G.GAME.round_resets.blind_tags }
for ante = 2, 4 do host_next_ante(); expected[ante] = G.GAME.round_resets.blind_tags end

host_game("*TAGSEED")
local host_random = G.GAME.pseudorandom
local before = host_random.Tag
local ante1 = Peer.blind_tags_for_ante(1, G.GAME.round_resets.blind_tags)
assert(ante1.Small == expected[1].Small and ante1.Big == expected[1].Big and Peer.blind_tags_trusted == true,
	"on a shared Ante the host's tags are used and confirm the replay")
local ahead = Peer.blind_tags_for_ante(2, G.GAME.round_resets.blind_tags)
assert(ahead.Small == expected[2].Small and ahead.Big == expected[2].Big,
	"a bot ahead of the host skips for its own Ante's tags")
assert(ahead.Small ~= expected[1].Small or ahead.Big ~= expected[1].Big,
	"the test seed must give different tags in Antes 1 and 2")
local far = Peer.blind_tags_for_ante(4, G.GAME.round_resets.blind_tags)
assert(far.Small == expected[4].Small and far.Big == expected[4].Big, "any later Ante can be replayed")
assert(G.GAME.pseudorandom == host_random and host_random.Tag == before and G.GAME.round_resets.ante == 1,
	"replaying must not touch the host's RNG or Ante")
host_next_ante()
assert(G.GAME.round_resets.blind_tags.Small == expected[2].Small, "the host's own run is unaffected")
host_next_ante(); host_next_ante()
local behind = Peer.blind_tags_for_ante(3, G.GAME.round_resets.blind_tags)
assert(behind.Small == expected[3].Small and behind.Big == expected[3].Big,
	"a bot behind the host skips for its own Ante's tags too")
assert(#warnings == 0, "no warnings while the replay matches")

-- The match that showed the bug: the host has just beaten the Ante 2 Boss
-- (Ante 3 already) but not cashed out, so it still shows Ante 2's tags. The
-- bot starting Ante 3 must neither mistake them for Ante 3's nor stop
-- trusting the replay because of them.
reset_peer()
host_game("*TAGSEED")
host_next_ante()
G.GAME.round_resets.blind_ante = 2
host_beats_boss()
local stale = G.GAME.round_resets.blind_tags
assert(stale.Small == expected[2].Small and G.GAME.round_resets.ante == 3, "the host shows Ante 2's tags in Ante 3")
local fresh = Peer.blind_tags_for_ante(3, stale)
assert(fresh.Small == expected[3].Small and fresh.Big == expected[3].Big and Peer.blind_tags_trusted == true
	and #warnings == 0, "the bot gets Ante 3's tags; the host's Ante 2 tags confirm the replay")
host_cashes_out()
local after = Peer.blind_tags_for_ante(4, G.GAME.round_resets.blind_tags)
assert(after.Small == expected[4].Small and #warnings == 0, "the replay stays trusted after the cash out")
-- Without blind_ante (other versions): a defeated Boss means the previous Ante's tags.
reset_peer()
host_game("*TAGSEED")
host_next_ante()
host_beats_boss()
G.GAME.round_resets.blind_ante = nil
local fallback = Peer.blind_tags_for_ante(3, G.GAME.round_resets.blind_tags)
assert(fallback.Small == expected[3].Small and Peer.blind_tags_trusted == true and #warnings == 0,
	"a beaten Boss before the cash out still shows the previous Ante's tags")

-- A host whose tags do not follow the replay (another mod, a different queue):
-- the replay is not used again; the host's tags are used for its own Ante only.
reset_peer()
host_game("*OTHER")
G.GAME.round_resets.blind_tags = { Small = "tag_rare", Big = "tag_rare" }
local live = G.GAME.round_resets.blind_tags
assert(Peer.blind_tags_for_ante(1, live) == live and Peer.blind_tags_trusted == false and #warnings == 1,
	"a mismatch must be reported and fall back to the host's tags")
assert(Peer.blind_tags_for_ante(2, live) == nil,
	"after a mismatch another Ante's host tags are not used (they would be stale)")
assert(Peer.blind_tags_for_ante(1, live) == live, "the host's tags of the bot's own Ante are still used")

-- Without the replay (older Order module) only the host's own Ante is known.
reset_peer()
Peer.dependencies = { Order = {} }
assert(Peer.blind_tags_for_ante(1, live) == live, "without Order.blind_tags the host's tags are used")
assert(Peer.blind_tags_for_ante(2, live) == nil, "but never as another Ante's tags")

print("blind_tags_spec: ok")
