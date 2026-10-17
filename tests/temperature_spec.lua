local Policy = dofile("bot/policy.lua")
local PRNG = dofile("bot/prng.lua")

local shop = {
	{ key = "best", utility = 100 },
	{ key = "close", utility = 96 },
	{ key = "bad", utility = 80 },
}

assert(Policy.choose_shop(shop, "expert", PRNG.new("zero"), 0).key == "best",
	"zero temperature must preserve deterministic Expert behavior")
local first = Policy.choose_shop(shop, "expert", PRNG.new("repeat"), 0.75).key
local second = Policy.choose_shop(shop, "expert", PRNG.new("repeat"), 0.75).key
assert(first == second, "temperature decisions must remain deterministic for a run seed")

local seen = {}
for index = 1, 80 do
	local choice = Policy.choose_shop(shop, "expert", PRNG.new("shop-" .. index), 0.75)
	seen[choice.key] = true
	assert(choice.key ~= "bad", "temperature must not select a materially worse shop action")
end
assert(seen.best and seen.close, "warmer Expert bots should vary between close shop actions")

local hand = {
	{ rank = 10, suit = "Hearts", chips = 10 },
	{ rank = 9, suit = "Spades", chips = 9 },
}
local function evaluate(cards)
	local score = #cards == 2 and 100 or 98
	return { name = "High Card", strength = 1, chips = score, mult = 1,
		score = score, scoring_cards = cards }
end

for index = 1, 40 do
	local action = Policy.choose_turn({
		difficulty = "expert", decision_temperature = 0.75,
		hand = hand, discards_left = 0, hands_left = 1,
		current_score = 0, target = 100,
		rng = PRNG.new("survival-" .. index), evaluate = evaluate,
	})
	assert(#action.indices == 2 and action.result.score == 100,
		"temperature must not vary a forced Blind-clearing play")
end

local pvp_counts = {}
for index = 1, 80 do
	local action = Policy.choose_turn({
		difficulty = "expert", decision_temperature = 0.75,
		hand = hand, discards_left = 0, hands_left = 4,
		rng = PRNG.new("pvp-" .. index), evaluate = evaluate,
	})
	pvp_counts[#action.indices] = true
end
assert(pvp_counts[1] and pvp_counts[2],
	"temperature should vary close PvP plays when survival is not forced")

print("temperature_spec: ok")
