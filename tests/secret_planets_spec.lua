-- The secret hands' Planets: Planet X (Five of a Kind), Ceres (Flush House) and
-- Eris (Flush Five) are softlocked (game.lua config.softlock): they are in the
-- Planet pool only once their hand has been played this run
-- (common_events.lua get_current_pool), and they level their hand.
local base = {
	PRNG = dofile("bot/prng.lua"),
	Cards = dofile("bot/cards.lua"),
	Content = dofile("bot/content.lua"),
	Evaluator = dofile("bot/evaluator.lua"),
	Strategy = dofile("bot/strategy.lua"),
	Policy = dofile("bot/policy.lua"),
	Simulator = dofile("bot/simulator.lua"),
}
base = dofile("bot/expert.lua").modules(base)
local Simulator, Content, Evaluator = base.Simulator, base.Content, base.Evaluator

local secret = { c_planet_x = "Five of a Kind", c_ceres = "Flush House", c_eris = "Flush Five" }

---------------------------------------------------------------------------
-- 1. Content: the default and the live catalogs hold them, softlocked.
---------------------------------------------------------------------------

local found = {}
for _, planet in ipairs(Content.defaults().planets) do
	if secret[planet.key] then
		assert(planet.hand == secret[planet.key] and planet.softlock, planet.key .. " is a softlocked " .. secret[planet.key])
		found[planet.key] = true
	else
		assert(not planet.softlock, planet.key .. " is not softlocked")
	end
end
assert(found.c_planet_x and found.c_ceres and found.c_eris, "the default catalog has the three secret Planets")

local live = Content.build({
	Planet = {
		{ key = "c_mercury", cost = 3, config = { hand_type = "Pair" } },
		{ key = "c_planet_x", cost = 3, config = { hand_type = "Five of a Kind", softlock = true } },
		{ key = "c_ceres", cost = 3, config = { hand_type = "Flush House", softlock = true } },
		{ key = "c_eris", cost = 3, config = { hand_type = "Flush Five", softlock = true } },
	},
}, {}, {})
assert(#live.planets == 4 and Content.summary(live).skipped == 0, "Ceres and Eris are supported")
for _, planet in ipairs(live.planets) do
	assert((planet.softlock == true) == (secret[planet.key] ~= nil), planet.key .. " keeps its softlock")
end

---------------------------------------------------------------------------
-- 2. The pool rule: only after the hand was played.
---------------------------------------------------------------------------

local function new_state(seed, options)
	local state = Simulator.new({ seed = seed, difficulty = "expert", the_order = true }, base)
	for key, value in pairs(options or {}) do state[key] = value end
	return state
end

local unlocked = Simulator.planet_unlocked
local state = new_state("SECRET-RULE")
assert(unlocked(state, { key = "c_mercury", hand = "Pair" }), "a base Planet is always in the pool")
assert(not unlocked(state, { key = "c_ceres", hand = "Flush House", softlock = true }), "Ceres before a Flush House")
assert(not unlocked(state, { key = "Flush Five", hand = "Flush Five" }), "a secret hand's Planet even without the flag")
state.hand_usage["Flush House"] = 1
assert(unlocked(state, { key = "c_ceres", hand = "Flush House", softlock = true }), "Ceres after a Flush House")
assert(not unlocked(state, { key = "c_eris", hand = "Flush Five", softlock = true }), "Eris still locked")

-- The headless shop (Planet slots forced by the rate).
local function shop_planets(state, visits)
	local seen = {}
	for _ = 1, visits do
		for _, key in ipairs(Simulator.shop_keys(state, true)) do seen[key] = true end
	end
	return seen
end
local locked_shop = shop_planets(new_state("SECRET-SHOP", { planet_rate = 1000 }), 200)
assert(not locked_shop.c_planet_x and not locked_shop.c_ceres and not locked_shop.c_eris,
	"no secret Planet in a shop before its hand is played")
assert(locked_shop.c_mercury and locked_shop.c_pluto, "the base Planets are offered")
local played = new_state("SECRET-SHOP", { planet_rate = 1000 })
played.hand_usage["Flush House"] = 2
local open_shop = shop_planets(played, 200)
assert(open_shop.c_ceres and not open_shop.c_eris and not open_shop.c_planet_x,
	"Ceres is offered after a Flush House, the other secret Planets are not")

-- Celestial Packs (the pack_step sees the contents).
local function pack_contents(hand_usage)
	local seen = {}
	local modules = {}
	for key, value in pairs(base) do modules[key] = value end
	modules.Policy = setmetatable({
		shop_step = function(_, ctx)
			for index, action in ipairs(ctx.actions) do
				if action.type == "buy" and action.item_type == "pack" then return index end
			end
			return 1
		end,
		pack_step = function(_, ctx)
			for _, item in ipairs(ctx.contents) do seen[item.key] = true end
			return 1
		end,
	}, { __index = base.Policy })
	local pack_state = Simulator.new({ seed = "SECRET-PACK", difficulty = "expert", the_order = true }, modules)
	for hand, count in pairs(hand_usage) do pack_state.hand_usage[hand] = count end
	for visit = 1, 40 do
		pack_state.money, pack_state.round = 100, visit   -- a new draw each visit
		Simulator.visit_shop(pack_state, { "p_celestial_mega_1" })
	end
	return seen
end
local locked_pack = pack_contents({})
assert(locked_pack.c_mercury and not locked_pack.c_ceres and not locked_pack.c_eris and not locked_pack.c_planet_x,
	"no secret Planet in a Celestial Pack before its hand is played")
local open_pack = pack_contents({ ["Flush Five"] = 1 })
assert(open_pack.c_eris and not open_pack.c_ceres, "Eris in a Celestial Pack after a Flush Five")

-- The High Priestess creates Planets from the same pool.
local priestess = new_state("SECRET-PRIESTESS", { consumable_limit = 100 })
for _ = 1, 60 do
	Simulator.apply_consumable(priestess, { type = "deck_tool", set = "Tarot", key = "c_high_priestess",
		effect = "generate_planet", count = 2 })
end
for _, consumable in ipairs(priestess.consumables) do
	assert(not secret[consumable.key], "The High Priestess made " .. consumable.key .. " before its hand")
end
for _, hand in pairs(secret) do
	assert((priestess.levels[hand] or 1) == 1, "The High Priestess levelled " .. hand)
end
assert(#priestess.consumables + priestess.planets_used > 0, "The High Priestess makes Planets")

---------------------------------------------------------------------------
-- 3. Using them: their hand levels up and scores with that level.
---------------------------------------------------------------------------

local levels = new_state("SECRET-LEVELS")
assert(Simulator.apply_consumable(levels, { type = "planet", key = "c_ceres", hand = "Flush House" }))
assert(Simulator.apply_consumable(levels, { type = "planet", key = "c_eris", hand = "Flush Five" }))
assert(Simulator.apply_consumable(levels, { type = "planet", key = "c_planet_x", hand = "Five of a Kind" }))
assert(levels.levels["Flush House"] == 2 and levels.levels["Flush Five"] == 2
	and levels.levels["Five of a Kind"] == 2 and levels.planets_used == 3, "each levels its secret hand")
local function card(rank, suit) return { rank = rank, suit = suit, chips = base.Cards.chips(rank) } end
local flush_house = { card(8, "Hearts"), card(8, "Hearts"), card(8, "Hearts"), card(4, "Hearts"), card(4, "Hearts") }
local level_one = Evaluator.evaluate(flush_house, {}, {}, {})
local level_two = Evaluator.evaluate(flush_house, levels.levels, {}, {})
assert(level_one.name == "Flush House" and level_two.name == "Flush House", "a Flush House")
assert(level_two.chips - level_one.chips == 40 and level_two.mult - level_one.mult == 4,
	"Ceres: +40 Chips, +4 Mult (game.lua Flush House l_chips / l_mult)")
-- Black Hole levels the secret hands too.
Simulator.apply_consumable(levels, { type = "deck_tool", set = "Spectral", key = "c_black_hole",
	effect = "level_all_hands" })
assert(levels.levels["Flush House"] == 3 and levels.levels["Flush Five"] == 3 and levels.levels.Pair == 2,
	"Black Hole: every hand, secret ones included")
-- Buy and Use works for them as for any Planet.
assert(Simulator.buy_and_use_ready(levels, { type = "planet", key = "c_ceres", hand = "Flush House" }))

-- The Telescope's Planet: the most played hand, secret hands included; a tie
-- goes to the stronger hand (G.handlist order).
local telescope = new_state("SECRET-TELESCOPE", { vouchers = { "v_telescope" } })
telescope.hand_usage.Pair, telescope.hand_usage["Flush House"] = 3, 3
local guaranteed = Simulator.rules.telescope_planet(telescope)
assert(guaranteed and guaranteed.key == "c_ceres", "Telescope: " .. tostring(guaranteed and guaranteed.key))
telescope.hand_usage.Pair = 4
assert(Simulator.rules.telescope_planet(telescope).key == "c_mercury", "a more played base hand wins")

---------------------------------------------------------------------------
-- 4. A live run's Order polls with the bot's own played hands, not the
-- player's (bot/order.lua).
---------------------------------------------------------------------------

local function hash(value)
	local result = 0
	for index = 1, #tostring(value) do result = (result * 33 + tostring(value):byte(index)) % 997 end
	return result / 997
end
G = {
	GAME = {
		pseudorandom = { seed = "*SECRET", hashed_seed = hash("*SECRET") },
		used_jokers = {}, used_vouchers = {}, pool_flags = {}, tags = {},
		current_round = {}, round_resets = { ante = 1 },
		modifiers = { extra_vouchers = 0 },
		-- the player has played a Flush House; the bot has not
		hands = {
			Pair = { played = 0, visible = true, level = 1 },
			["Flush House"] = { played = 5, visible = true, level = 1 },
		},
	},
}
function pseudohash(value) return hash(value) end
function pseudoseed(key)
	local random = G.GAME.pseudorandom
	if random[key] == nil then random[key] = hash(key .. (random.seed or "")) end
	random[key] = (0.173 + random[key] * 1.731) % 1
	return random[key]
end
function pseudorandom(seed)
	if type(seed) == "string" then seed = pseudoseed(seed) end
	return tonumber(seed) or 0
end
function pseudorandom_element(values, seed)
	return values[math.floor((tonumber(seed) or 0) * #values) % #values + 1]
end
local pool_visible = {}
function get_current_pool(object_type, _, _, append)
	assert(object_type == "Planet", "unexpected pool " .. tostring(object_type))
	pool_visible[#pool_visible + 1] = G.GAME.hands["Flush House"].visible
	local pool = {}
	for _, center in ipairs({ { "c_mercury", "Pair" }, { "c_ceres", "Flush House", true } }) do
		local hand = G.GAME.hands[center[2]]
		pool[#pool + 1] = (not center[3] or hand.played > 0) and center[1] or "UNAVAILABLE"
	end
	return pool, "Planet" .. tostring(append or "")
end
SMODS = { ConsumableType = { obj_buffer = {} }, Stickers = {}, optional_features = {} }

local Order = dofile("bot/order.lua")
local live_hands = G.GAME.hands
local function polled(run)
	local seen = {}
	for _ = 1, 30 do
		local cards = Order.generate_pack(run, "p_celestial_normal_1")
		for _, item in ipairs(cards or {}) do seen[item.key] = true end
	end
	return seen
end
local bot_run = { seed = "*SECRET", ante = 1, jokers = {}, consumables = {}, vouchers = {}, hand_usage = {} }
local locked_order = polled(bot_run)
assert(locked_order.c_mercury and not locked_order.c_ceres, "the player's Flush House does not unlock the bot's Ceres")
assert(pool_visible[1] == false, "the bot's unplayed secret hand is hidden")
assert(G.GAME.hands == live_hands and live_hands["Flush House"].played == 5, "the player's hands are restored")
bot_run.hand_usage["Flush House"] = 1
local open_order = polled(bot_run)
assert(open_order.c_ceres, "the bot's own Flush House unlocks Ceres")
assert(G.GAME.hands == live_hands, "the player's hands are restored")

print("secret_planets_spec: ok")
