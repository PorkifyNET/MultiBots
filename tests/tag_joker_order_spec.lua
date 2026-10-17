-- Uncommon/Rare Tags under The Order give the bot its
-- Joker from its own private Order queues instead of nothing.
local function hash(value)
	local result = 0
	for index = 1, #tostring(value) do result = (result * 33 + tostring(value):byte(index)) % 997 end
	return result / 997
end

G = {
	GAME = {
		pseudorandom = { seed = "*TAGS", hashed_seed = hash("*TAGS") },
		used_jokers = {}, used_vouchers = {}, pool_flags = {}, tags = {},
		current_round = {}, round_resets = { ante = 3 },
		shop = { joker_max = 2 }, starting_params = { boosters_in_shop = 2 },
		modifiers = { extra_boosters = 0, extra_vouchers = 0 },
		banned_keys = {},
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
local pool_calls = {}
-- Vanilla get_current_pool: rarity 0.9 -> 2, 1 -> 3; key "Joker" .. rarity .. append.
function get_current_pool(object_type, rarity, legendary, append)
	assert(object_type == "Joker", "a tag Joker is polled from the Joker pool")
	pool_calls[#pool_calls + 1] = { rarity = rarity, append = append, ante = G.GAME.round_resets.ante }
	local level = rarity > 0.95 and 3 or (rarity > 0.7 and 2 or 1)
	local pools = { [2] = { "j_hack", "j_dusk" }, [3] = { "j_blueprint" } }
	local available = {}
	for _, key in ipairs(pools[level]) do
		available[#available + 1] = G.GAME.used_jokers[key] and "UNAVAILABLE" or key
	end
	return available, "Joker" .. level .. tostring(append or "")
end
local edition_keys = {}
function poll_edition(key)
	edition_keys[#edition_keys + 1] = key
	pseudorandom(key)
	return nil
end
SMODS = { ConsumableType = { obj_buffer = {} }, Stickers = {}, optional_features = {} }

local Order = dofile("bot/order.lua")
local human_random = G.GAME.pseudorandom
local run = { seed = "*TAGBOT", ante = 3, jokers = {}, vouchers = {} }
Order.begin_run(run, run.seed)

local uncommon = assert(Order.generate_tag_joker(run, "uncommon"))
assert(uncommon.kind == "center" and (uncommon.key == "j_hack" or uncommon.key == "j_dusk"),
	"an Uncommon Tag should yield an Uncommon Joker")
assert(pool_calls[1].rarity == 0.9 and pool_calls[1].append == 0.9 and pool_calls[1].ante == 0,
	"The Order polls a Tag Joker at Ante 0 with its rarity as the queue key")
assert(edition_keys[1] == "edi0.90", "the Tag Joker's edition comes from its own rarity edition queue")
assert(run.order_shop.random["Joker20.9"] ~= nil and human_random["Joker20.9"] == nil,
	"only the bot's private RNG copy should advance")
assert(G.GAME.pseudorandom == human_random and G.GAME.round_resets.ante == 3,
	"the human's RNG and Ante must be restored")

local rare = assert(Order.generate_tag_joker(run, "rare"))
assert(rare.key == "j_blueprint" and pool_calls[2].rarity == 1, "a Rare Tag should yield a Rare Joker")
run.jokers = { "j_blueprint" }
assert(Order.generate_tag_joker(run, "rare") == nil,
	"a Rare Tag does nothing when every Rare is already owned, as in the game")
G = nil

-- The simulator: a skipped Uncommon Tag turns into a free Joker in the next shop.
local modules = {
	PRNG = dofile("bot/prng.lua"), Cards = dofile("bot/cards.lua"), Content = dofile("bot/content.lua"),
	Evaluator = dofile("bot/evaluator.lua"), Strategy = dofile("bot/strategy.lua"),
	Policy = dofile("bot/policy.lua"), Simulator = dofile("bot/simulator.lua"), Order = Order,
}
modules = dofile("bot/expert.lua").modules(modules)   -- MultiBots' Expert decides
local function strict_run(order)
	local state = modules.Simulator.new({
		seed = "TAGRUN", difficulty = "expert", the_order = true, strict_order_content = true,
	}, modules)
	state.Order = order
	state.money = 4
	return state
end

local generated = {}
local state = strict_run({
	generate_tag_joker = function(run_state, rarity)
		generated[#generated + 1] = rarity
		return { kind = "center", key = "j_hack" }
	end,
})
modules.Simulator.set_ante(state, 2)
local before = #state.decisions
state.Policy = setmetatable({ should_skip_blind = function(args)
	assert(args.reward_supported == true, "an Order-backed Uncommon Tag is a supported reward")
	return args.blind == "Small"
end }, { __index = modules.Policy })
local skips = modules.Simulator.plan_skips(state, "reactive", { Small = "tag_uncommon", Big = "tag_economy" })
assert(skips.Small and #state.pending_tag_jokers == 1 and state.pending_tag_jokers[1].rarity == "uncommon",
	"skipping for an Uncommon Tag should queue its Joker")
state.Policy = modules.Policy
modules.Simulator.visit_shop(state, { "c_mercury" })
assert(generated[1] == "uncommon", "the Tag Joker should come from the Order generator")
local bought = false
for index = before + 1, #state.decisions do
	local decision = state.decisions[index]
	if decision.type == "buy_joker" and decision.key == "j_hack" and decision.source == "tag_uncommon" then bought = true end
end
assert(bought and state.jokers[1] == "j_hack" and state.money == 4,
	"the free Tag Joker should be offered (and is worth taking at $0)")
assert(#state.pending_tag_jokers == 0, "a resolved Tag reward is not offered again")

-- Without an Order generator (or for a Joker the run cannot model) nothing is invented.
local plain = strict_run({})
plain.Order = nil
modules.Simulator.set_ante(plain, 2)
plain.Policy = setmetatable({ should_skip_blind = function(args)
	assert(args.reward_supported == false, "without a generator the Tag reward is not supported")
	return false
end }, { __index = modules.Policy })
modules.Simulator.plan_skips(plain, "reactive", { Small = "tag_uncommon", Big = "tag_rare" })
local unknown = strict_run({ generate_tag_joker = function() return { kind = "center", key = "j_not_modeled" } end })
unknown.pending_tag_jokers = { { tag = "tag_uncommon", rarity = "uncommon" } }
modules.Simulator.visit_shop(unknown, { "c_mercury" })
assert(#unknown.jokers == 0, "an unmodeled Tag Joker is not replaced by a made-up one")

print("tag_joker_order_spec: ok")
