local Policy = dofile("bot/policy.lua")
local PRNG = dofile("bot/prng.lua")

local hand = {
	{ rank = 2, chips = 2, suit = "Spades" }, { rank = 3, chips = 3, suit = "Hearts" },
	{ rank = 4, chips = 4, suit = "Clubs" }, { rank = 5, chips = 5, suit = "Diamonds" },
	{ rank = 6, chips = 6, suit = "Spades" },
}

local function growth_evaluator(cards)
	if #cards == 5 then
		return { name = "Straight", strength = 5, chips = 50, mult = 2, score = 100, scoring_cards = cards }
	elseif #cards == 4 then
		return { name = "Four of a Kind", strength = 8, chips = 75, mult = 2, score = 150, scoring_cards = cards }
	end
	return { name = "High Card", strength = 1, chips = 10, mult = 1, score = 10, scoring_cards = cards }
end

local immediate = Policy.choose_turn({
	difficulty = "expert", hand = hand, discards_left = 0, hands_left = 4,
	rng = PRNG.new("IMMEDIATE"), evaluate = growth_evaluator,
})
assert(immediate.result.name == "Four of a Kind", "without a scaler, policy should maximize immediate score")
assert(immediate.candidates and #immediate.candidates <= 4
	and immediate.best_utility >= immediate.chosen_utility and immediate.regret >= 0,
	"turn policy should expose top-three-plus-chosen diagnostics without changing its choice")

local runner = Policy.choose_turn({
	difficulty = "expert", hand = hand, discards_left = 0, hands_left = 4,
	rng = PRNG.new("RUNNER"), evaluate = growth_evaluator,
	strategy = { runner_growth = 15, hand_growth = {}, rank_growth = {} },
})
assert(runner.result.name == "Straight", "Runner's permanent growth should make a close Straight preferable")

local square = Policy.choose_turn({
	difficulty = "expert", hand = hand, discards_left = 0, hands_left = 4,
	rng = PRNG.new("SQUARE"), strategy = { four_card_growth = 4 },
	evaluate = function(cards)
		return { name = "Pair", strength = 2, chips = #cards * 10, mult = 10,
			score = #cards * 100, scoring_cards = cards }
	end,
})
assert(#square.indices == 4,
	"Square Joker should accept a small immediate loss to submit four cards and gain permanent Chips")

local bus_hand = {
	{ rank = 12, chips = 10 }, { rank = 8, chips = 8 },
}
local function bus_evaluator(cards)
	if cards[1].rank == 12 then
		return { name = "High Card", strength = 1, chips = 40, mult = 5, score = 200, scoring_cards = cards }
	end
	return { name = "High Card", strength = 1, chips = 30, mult = 5, score = 150, scoring_cards = cards }
end
local bus = Policy.choose_turn({
	difficulty = "expert", hand = bus_hand, discards_left = 0, hands_left = 3,
	rng = PRNG.new("BUS"), evaluate = bus_evaluator,
	strategy = { bus_value = 12, bus_growth = 1, hand_growth = {}, rank_growth = {} },
})
assert(bus.indices[1] == 2,
	"Ride the Bus should preserve substantial accumulated Mult instead of taking a small face-card gain")

local pair_hand = {
	{ rank = 8, chips = 8, suit = "Spades" },
	{ rank = 8, chips = 8, suit = "Hearts" },
}
local function pair_evaluator(cards)
	if #cards == 2 then
		return { name = "Pair", strength = 2, chips = 50, mult = 2, score = 100, scoring_cards = cards }
	end
	return { name = "High Card", strength = 1, chips = 10, mult = 1, score = 10, scoring_cards = cards }
end
local green = Policy.choose_turn({
	difficulty = "expert", hand = pair_hand, discards_left = 3, hands_left = 4,
	current_score = 0, target = 400, rng = PRNG.new("GREEN"), evaluate = pair_evaluator,
	strategy = { preserve_green = true, hand_growth = {}, rank_growth = {} },
})
assert(green.type == "play" and green.result.name == "Pair",
	"Green Joker should play a reasonable Pair instead of spending a discard and losing scaling")

local green_emergency_hand, green_emergency_draw = {}, {}
for rank = 2, 9 do
	green_emergency_hand[#green_emergency_hand + 1] = { rank = rank, chips = rank, suit = "Spades" }
end
for rank = 10, 14 do
	green_emergency_draw[#green_emergency_draw + 1] = {
		rank = rank, chips = rank, suit = "Hearts", improved = true,
	}
end
local green_emergency = Policy.choose_turn({
	difficulty = "expert", hand = green_emergency_hand, draw_pile = green_emergency_draw,
	discards_left = 4, hands_left = 1, current_score = 326, target = 450,
	rng = PRNG.new("GREEN-EMERGENCY"),
	evaluate = function(cards)
		local improved = false
		for _, card in ipairs(cards) do if card.improved then improved = true; break end end
		return { name = "Pair", strength = 2, chips = 50, mult = improved and 4 or 2,
			score = improved and 200 or 100, scoring_cards = cards }
	end,
	strategy = {
		preserve_green = true, discard_score_loss_fraction = 0.125,
		hand_growth = {}, rank_growth = {},
	},
})
assert(green_emergency.type == "discard",
	"Green Joker must spend a discard when projected remaining hands cannot clear the Blind")

local final_draw = {
	{ rank = 9, chips = 9, suit = "Hearts", improved = true },
	{ rank = 10, chips = 10, suit = "Hearts", improved = true },
	{ rank = 11, chips = 10, suit = "Hearts", improved = true },
	{ rank = 12, chips = 10, suit = "Hearts", improved = true },
	{ rank = 13, chips = 10, suit = "Hearts", improved = true },
}
local final_hand_shortfall = Policy.choose_turn({
	difficulty = "expert", hand = hand, draw_pile = final_draw,
	discards_left = 2, hands_left = 1, current_score = 0, target = 100,
	rng = PRNG.new("FINAL-HAND-SHORTFALL"), evaluate = function(cards)
		local improved = false
		for _, card in ipairs(cards) do if card.improved then improved = true end end
		return { name = "Full House", strength = 7, chips = 49, mult = 2,
			score = improved and 110 or 98, scoring_cards = cards }
	end,
})
assert(final_hand_shortfall.type == "discard",
	"the final hand must redraw a strong category when its score cannot clear the Blind")

local strong_but_slow = Policy.choose_turn({
	difficulty = "expert", hand = hand, draw_pile = final_draw,
	discards_left = 3, hands_left = 3, current_score = 0, target = 3000,
	rng = PRNG.new("STRONG-BUT-SLOW"), evaluate = function(cards)
		local improved = false
		for _, card in ipairs(cards) do if card.improved then improved = true end end
		return { name = "Straight", strength = 5, chips = 50, mult = 2,
			score = improved and 1500 or 100, scoring_cards = cards }
	end,
})
assert(strong_but_slow.type == "discard",
	"a strong category far below required pace must not bypass an available redraw")

local costly_hand, costly_draw = {}, {}
for rank = 2, 6 do
	costly_hand[#costly_hand + 1] = { rank = rank, chips = rank, suit = "Spades" }
	costly_draw[#costly_draw + 1] = { rank = rank + 7, chips = rank + 7, suit = "Hearts", improved = true }
end
local ramen_preserved = Policy.choose_turn({
	difficulty = "expert", hand = costly_hand, draw_pile = costly_draw,
	discards_left = 3, hands_left = 4, current_score = 0, target = 100000,
	rng = PRNG.new("RAMEN-PRESERVE"),
	evaluate = function(cards)
		local improved = false
		for _, card in ipairs(cards) do if card.improved then improved = true end end
		return { name = "High Card", strength = 1, chips = 100, mult = 100,
			score = improved and 10200 or 10000, scoring_cards = cards }
	end,
	strategy = {
		discard_card_cost = 45, discard_score_loss_fraction = 0.01,
		hand_growth = {}, rank_growth = {},
	},
})
assert(ramen_preserved.type == "play",
	"a tiny redraw improvement must not burn more persistent Ramen XMult than it gains")

local ramen_budgeted = Policy.choose_turn({
	difficulty = "expert", hand = costly_hand, draw_pile = costly_draw,
	discards_left = 3, hands_left = 4, current_score = 0, target = 100000,
	discards_used_this_hand = 1, rng = PRNG.new("RAMEN-BUDGET"),
	evaluate = function(cards)
		local improved = false
		for _, card in ipairs(cards) do if card.improved then improved = true end end
		return { name = "High Card", strength = 1, chips = 100, mult = 100,
			score = improved and 11000 or 10000, scoring_cards = cards }
	end,
	strategy = {
		discard_card_cost = 45, discard_score_loss_fraction = 0.005,
		discard_per_hand_budget = 1, hand_growth = {}, rank_growth = {},
	},
})
assert(ramen_budgeted.type == "play",
	"Ramen should not repeatedly burn permanent XMult while redrawing the same hand")

local ramen_survival = Policy.choose_turn({
	difficulty = "expert", hand = costly_hand, draw_pile = costly_draw,
	discards_left = 2, hands_left = 2, current_score = 0, target = 50000,
	discards_used_this_hand = 1, rng = PRNG.new("RAMEN-SURVIVAL"),
	evaluate = function(cards)
		local improved = false
		for _, card in ipairs(cards) do if card.improved then improved = true end end
		return { name = "High Card", strength = 1, chips = 100, mult = 100,
			score = improved and 30000 or 10000, scoring_cards = cards }
	end,
	strategy = {
		discard_card_cost = 45, discard_score_loss_fraction = 0.005,
		discard_per_hand_budget = 1, hand_growth = {}, rank_growth = {},
	},
})
assert(ramen_survival.type == "discard",
	"Ramen's normal discard budget must not block a redraw when current pace cannot survive the Blind")

local weak_trips = Policy.choose_turn({
	difficulty = "expert", hand = hand, discards_left = 2, hands_left = 4,
	current_score = 0, target = 7500, rng = PRNG.new("WEAK-TRIPS"),
	evaluate = function(cards)
		return { name = "Three of a Kind", strength = 4, chips = 100, mult = 5,
			score = 500, scoring_cards = cards }
	end,
})
assert(weak_trips.type == "discard",
	"a weak Three of a Kind below the required scoring pace should not consume a hand before available discards")

local pvp_budgeted = Policy.choose_turn({
	difficulty = "expert", hand = hand, draw_pile = costly_draw,
	discards_left = 3, starting_discards = 7, starting_hands = 4,
	discards_used_this_hand = 4, hands_left = 4,
	rng = PRNG.new("PVP-DISCARD-BUDGET"), evaluate = function(cards)
		local improved = false
		for _, card in ipairs(cards) do if card.improved then improved = true end end
		return { name = "High Card", strength = 1, chips = 10, mult = 1,
			score = improved and 1000 or 10, scoring_cards = cards }
	end,
})
assert(pvp_budgeted.type == "play",
	"PvP should preserve later-hand redraws after spending the current hand's discard share")

local always_low = { next = function() return 0 end }
local always_high = { next = function() return 0.99 end }
assert(not Policy.should_skip_blind({
	difficulty = "expert", ante = 1, blind = "Small", money = 20,
	joker_count = 5, joker_limit = 5, rng = always_low,
}), "the bot must not skip while establishing its Ante 1 build")
assert(not Policy.should_skip_blind({
	difficulty = "expert", ante = 2, blind = "Small", money = 4,
	joker_count = 5, joker_limit = 5, rng = always_low,
}), "the bot must not skip without enough economy")
assert(Policy.should_skip_blind({
	difficulty = "expert", ante = 2, blind = "Big", money = 20,
	joker_count = 5, joker_limit = 5, rng = always_low,
}), "a developed bot should be able to select a Blind skip")
assert(not Policy.should_skip_blind({
	mode = "disabled", difficulty = "expert", ante = 8, blind = "Big", money = 100,
	joker_count = 5, joker_limit = 5, tag = "tag_negative", rng = always_low,
}), "Disabled mode must reject every skip")
assert(Policy.should_skip_blind({
	mode = "negative_only", difficulty = "normal", ante = 2, blind = "Small", money = 8,
	joker_count = 2, joker_limit = 5, tag = "tag_negative", rng = always_high,
}), "Negative-only mode must guarantee an eligible Negative Tag skip")
assert(not Policy.should_skip_blind({
	mode = "negative_only", difficulty = "normal", ante = 2, blind = "Small", money = 8,
	joker_count = 2, joker_limit = 5, tag = "tag_investment", rng = always_low,
}), "Negative-only mode must reject other tags")
assert(Policy.should_skip_blind({
	mode = "unforgivable", difficulty = "easy", ante = 2, blind = "Small", money = 8,
	joker_count = 2, joker_limit = 5, tag = "tag_boss", rng = always_high,
}), "Unforgivable mode must skip every Blind after meeting its limits")
assert(not Policy.should_skip_blind({
	mode = "unforgivable", difficulty = "easy", ante = 1, blind = "Small", money = 100,
	joker_count = 5, joker_limit = 5, rng = always_low,
}), "Unforgivable mode must retain the standard Ante limit")
assert(Policy.should_skip_blind({
	mode = "unlimited_unforgivable", difficulty = "easy", ante = 1, blind = "Small", money = 0,
	joker_count = 0, joker_limit = 5, rng = always_high,
}), "Unlimited Unforgivable must waive every standard skip limit")
assert(Policy.should_skip_blind({
	mode = "reactive", difficulty = "normal", ante = 2, blind = "Small", money = 10,
	joker_count = 2, joker_limit = 5, tag = "tag_investment", rng = always_high,
}), "Reactive mode should take emergency Investment Tags")
assert(Policy.should_skip_blind({
	mode = "reactive", difficulty = "normal", ante = 2, blind = "Big", money = 20,
	joker_count = 5, joker_limit = 5, previous_pvp_dominant = true, rng = { next = function() return 0.34 end },
}), "Reactive mode should sometimes convert a dominant PvP lead into timer pressure")
assert(not Policy.should_skip_blind({
	mode = "reactive", difficulty = "expert", ante = 7, blind = "Small", money = 69,
	joker_count = 5, joker_limit = 5, tag = "tag_negative", previous_pvp_dominant = true,
	previous_score = 54848, next_blind_target = 52500, rng = always_low,
}), "Reactive mode must not skip when the previous score lacks a 20% next-Blind safety margin")
assert(not Policy.should_skip_blind({
	mode = "reactive", difficulty = "expert", ante = 5, blind = "Small", money = 44,
	joker_count = 5, joker_limit = 5, tag = "tag_rare", rng = always_low,
}), "Reactive mode must not take a Joker tag with full slots absent a pressure reason")
assert(not Policy.should_skip_blind({
	mode = "reactive", difficulty = "expert", ante = 3, blind = "Small", money = 20,
	joker_count = 2, joker_limit = 5, tag = "tag_rare", strict_order_content = true, rng = always_low,
}), "strict Order mode must not skip for a hidden Joker reward it cannot observe")
assert(not Policy.should_skip_blind({
	mode = "reactive", difficulty = "expert", ante = 4, blind = "Small", money = 57,
	joker_count = 5, joker_limit = 5, tag = "tag_meteor", reward_supported = false, rng = always_low,
}), "Reactive mode must not sacrifice a Blind for an unmodeled tag reward")
assert(Policy.should_skip_blind({
	mode = "aggressive", difficulty = "easy", ante = 2, blind = "Small", money = 8,
	joker_count = 2, joker_limit = 5, tag = "tag_boss", rng = { next = function() return 0.54 end },
}), "Aggressive mode should have a substantially raised skip floor")

print("policy_spec: ok")
