local Cards = dofile("bot/cards.lua")
local Strategy = dofile("bot/strategy.lua")

local state = {
	deck = Cards.standard_deck(),
	jokers = { "j_runner" },
	joker_effects = { j_runner = { kind = "straight_scaling_chips", amount = 15 } },
	levels = { ["High Card"] = 1, Pair = 1, ["Two Pair"] = 1, ["Three of a Kind"] = 1,
		Straight = 2, Flush = 1, ["Full House"] = 1, ["Four of a Kind"] = 1, ["Straight Flush"] = 1 },
	hand_usage = { Straight = 5, Pair = 1 },
	discards_per_round = 3,
	starting_deck_size = 52,
	ante = 3,
	money = 20,
	round_history = { { score = 4000, target = 2000 } },
	base_score = function() return 2000 end,
}

local plan = Strategy.analyze(state)
assert(plan.primary_hand == "Straight", "Runner, levels, and hand history should produce a Straight plan")
assert(plan.confidence > 0.35, "an established build should have meaningful confidence")
assert(Strategy.planet_utility(state, "Straight", plan) > Strategy.planet_utility(state, "Straight Flush", plan),
	"the planned hand's Planet should beat an unused off-plan Planet")
local ordinary_planet = Strategy.planet_utility(state, "Pair", plan)
state.jokers = { "j_constellation" }
state.joker_effects.j_constellation = { kind = "planet_scaling_xmult", initial = 1, amount = 0.1 }
assert(Strategy.planet_utility(state, "Pair", plan) >= ordinary_planet + 14,
	"Constellation should add its permanent XMult growth to every Planet purchase")
local constellation = { key = "j_constellation", utility = 30,
	effect = state.joker_effects.j_constellation }
state.joker_state = { j_constellation = 1.1 }
assert(Strategy.joker_utility(state, constellation, plan) >= 29,
	"a started Constellation engine should not be sold for an ordinary additive Joker")
state.jokers = { "j_runner" }
local xmult_gap = Strategy.joker_utility(state, constellation, plan)
state.ante = 4
assert(Strategy.joker_utility(state, constellation, plan) >= xmult_gap + 12,
	"an established build without XMult should prioritize its first multiplicative engine")
state.ante = 3
state.joker_effects.j_constellation = nil

local matching = { key = "j_crazy", utility = 18, effect = { kind = "hand_mult", hand = "Straight", amount = 12 } }
local conflicting = { key = "j_droll", utility = 18, effect = { kind = "hand_mult", hand = "Flush", amount = 10 } }
assert(Strategy.joker_utility(state, matching, plan) > Strategy.joker_utility(state, conflicting, plan),
	"shop valuation should prefer Jokers matching the current build")
local family = { key = "j_family", utility = 36, effect = { kind = "hand_xmult", hand = "Four of a Kind", amount = 4 } }
assert(Strategy.joker_utility(state, family, plan) < 14,
	"The Family must not be treated as a strong purchase without a Four of a Kind deck")
local order = { key = "j_order", utility = 34, effect = { kind = "hand_xmult", hand = "Straight", amount = 3 } }
local pair_plan_for_order = {
	primary_hand = "Two Pair", secondary_hand = "Pair", shape = plan.shape,
	hand_scores = { ["Two Pair"] = 30, Pair = 25 },
}
assert(Strategy.joker_utility(state, order, pair_plan_for_order) < 14,
	"The Order must not fill a settled Pair/Two Pair build on speculative Straight activation")
local sharp = { key = "j_card_sharp", utility = 30,
	effect = { kind = "repeat_hand_xmult", amount = 3 } }
local sharp_even = Strategy.joker_utility(state, sharp, plan)
state.previous_pvp_score, state.previous_player_score = 5000, 10000
assert(Strategy.joker_utility(state, family, plan) < 14,
	"PvP catch-up pressure must not make an infeasible Four of a Kind payoff purchasable")
assert(Strategy.joker_utility(state, sharp, plan) > sharp_even + 9,
	"a large observed PvP deficit should materially increase XMult upgrade priority")
state.previous_pvp_score, state.previous_player_score = 12000, 10000
assert(Strategy.joker_utility(state, sharp, plan) == sharp_even,
	"PvP catch-up pressure should clear once the bot is no longer trailing")
local ice_cream = { key = "j_ice_cream", utility = 25,
	effect = { kind = "decaying_chips", initial = 100, amount = 5 } }
state.joker_state = { j_ice_cream = 15 }
assert(Strategy.joker_utility(state, ice_cream, plan) < 14,
	"an exhausted Ice Cream must be valued by its remaining Chips rather than its fresh catalog utility")
local popcorn = { key = "j_popcorn", utility = 22,
	effect = { kind = "decaying_mult", initial = 20, amount = 4 } }
state.joker_state.j_popcorn = 4
assert(Strategy.joker_utility(state, popcorn, plan) < 14,
	"an exhausted Popcorn must become an eligible replacement target")
state.jokers = { "j_scholar", "j_stencil", "j_gros_michel", "j_odd_todd" }
state.joker_effects.j_stencil = { kind = "empty_slot_xmult" }
local owned_stencil = { key = "j_stencil", utility = 30, effect = state.joker_effects.j_stencil }
assert(Strategy.joker_utility(state, owned_stencil, Strategy.analyze(state)) >= 24,
	"an owned Stencil must count itself as an unoccupied slot when valued")
state.jokers = { "j_runner" }
state.joker_effects.j_stencil = nil
local pacifist = { key = "j_mp_pacifist", utility = 25, effect = { kind = "non_pvp_xmult", amount = 10 } }
assert(Strategy.joker_utility(state, pacifist, plan) < 14,
	"Pacifist must not consume a healthy Attrition build's PvP Joker slot")
state.round_history = { { score = 900, target = 1000, cleared = false } }
state.next_round_is_pvp = true
assert(Strategy.joker_utility(state, pacifist, plan) < 14,
	"Pacifist must not be treated as a survival upgrade when the next round is PvP")
state.next_round_is_pvp = false
state.round_history = { { score = 4000, target = 2000 } }
local steel = { key = "j_steel_joker", utility = 29,
	effect = { kind = "enhancement_count_xmult", enhancement = "m_steel", initial = 1, amount = 0.2 } }
assert(Strategy.joker_utility(state, steel, plan) < 14,
	"Steel Joker must be declined when the deck contains no Steel cards")
state.deck[1].enhancement, state.deck[2].enhancement = "m_steel", "m_steel"
assert(Strategy.joker_utility(state, steel, plan) >= 14,
	"Steel Joker should become purchasable once the deck can activate it")
state.deck[1].enhancement, state.deck[2].enhancement = nil, nil
local baron = { key = "j_baron", utility = 34,
	effect = { kind = "held_rank_xmult", rank = 13, amount = 1.5 } }
assert(Strategy.joker_utility(state, baron, pair_plan_for_order) < 14,
	"Baron should be replaceable when a stock Pair deck consumes its few Kings")
for index = 1, 5 do
	state.deck[index].rank = 13
	if index <= 2 then state.deck[index].enhancement = "m_steel" end
end
assert(Strategy.joker_utility(state, baron, pair_plan_for_order) >= 25,
	"a concentrated King deck with Steel Kings should make Baron a core Joker")
state.deck = Cards.standard_deck()
local flower = { key = "j_flower_pot", utility = 31,
	effect = { kind = "scoring_suits_xmult", count = 4, amount = 3 } }
assert(Strategy.joker_utility(state, flower, pair_plan_for_order) < 14,
	"Flower Pot should be replaceable when the planned scoring hands cannot show four suits")
local straight_plan = {
	primary_hand = "Straight", secondary_hand = "Full House", shape = plan.shape,
	hand_scores = { Straight = 30, ["Full House"] = 20 },
}
assert(Strategy.joker_utility(state, flower, straight_plan)
	> Strategy.joker_utility(state, flower, pair_plan_for_order) + 10,
	"Flower Pot should gain value from repeatable multi-suit five-card hands")
state.jokers = { "j_flower_pot" }
state.joker_effects.j_flower_pot = flower.effect
local _, flower_suit = Strategy.deck_fix_target(state)
assert(flower_suit == nil,
	"Flower Pot should suppress single-suit deck fixing while its condition is owned")
state.jokers, state.joker_effects.j_flower_pot = { "j_runner" }, nil
local license = { key = "j_drivers_license", utility = 34,
	effect = { kind = "enhanced_threshold_xmult", count = 16, amount = 3 } }
assert(Strategy.joker_utility(state, license, plan) < 14,
	"Driver's License must be declined when its enhancement threshold is unreachable")
assert(Strategy.reserve(state, plan) == 15, "a healthy $20 run should preserve most interest while allowing spending")

state.previous_pvp_score, state.previous_player_score = 6000, 10000
assert(Strategy.reserve(state, plan) == 5,
	"a PvP loss should reduce the reserve to the first interest tier")
state.previous_pvp_score, state.previous_player_score = 4000, 10000
assert(Strategy.reserve(state, plan) == 0,
	"a severe PvP loss should release the full reserve for catch-up spending")
state.previous_pvp_score, state.previous_player_score = 12000, 10000

local suit_tool = { key = "c_moon", utility = 25, effect = "suit" }
assert(Strategy.deck_tool_utility(state, suit_tool, plan) < 14,
	"a suit conversion must be declined by a settled non-Flush build")
local heart_tool = { key = "c_sun", utility = 25, effect = "suit", suit = "Hearts" }
assert(Strategy.deck_tool_utility(state, heart_tool, plan) > 25,
	"an unfocused deck should accept conversion toward its default Hearts target")
local flush_plan = {
	primary_hand = "Flush", secondary_hand = "Pair", shape = plan.shape,
	hand_scores = { Flush = 30, Pair = 10 },
}
assert(Strategy.deck_tool_utility(state, suit_tool, flush_plan) > 25,
	"a suit conversion should remain valuable when it advances a Flush build")

local saturated = {
	deck = Cards.standard_deck(), jokers = {}, joker_effects = {},
	levels = {}, hand_usage = { Pair = 5 }, discards_per_round = 3,
	starting_deck_size = 52, strategy_open = true,
}
for _, card in ipairs(saturated.deck) do
	if card.rank == 13 or card.suit == "Hearts" then
		card.enhancement, card.edition, card.seal = "m_lucky", "polychrome", "Red"
	end
end
local saturated_plan = Strategy.analyze(saturated)
assert(Strategy.deck_tool_utility(saturated,
	{ key = "c_empress", utility = 24, effect = "enhance" }, saturated_plan) < 10,
	"enhancement tools should be declined after the chosen rank/suit core is saturated")
assert(Strategy.deck_tool_utility(saturated,
	{ key = "c_aura", utility = 27, effect = "edition" }, saturated_plan) < 10,
	"edition tools should be declined after the chosen rank/suit core is saturated")

do
local stock = {
	deck = Cards.standard_deck(), jokers = {}, joker_effects = {}, levels = {}, hand_usage = { Pair = 4 },
	discards_per_round = 3, starting_deck_size = 52, strategy_open = true, ante = 4,
}
local stock_plan = Strategy.analyze(stock)
local pressure = Strategy.deck_fix_pressure(stock)
local structural = Strategy.deck_tool_utility(stock,
	{ key = "c_hanged_man", utility = 30, effect = "remove", count = 2 }, stock_plan)
local decoration = Strategy.deck_tool_utility(stock,
	{ key = "c_empress", utility = 24, effect = "enhance", enhancement = "m_mult", count = 2 }, stock_plan)
assert(pressure >= 10 and structural > decoration,
	"a late stock deck should prioritize structural Tarot work over another decoration")
for _, card in ipairs(stock.deck) do
	card.suit, card.enhancement = "Hearts", "m_mult"
end
assert(Strategy.deck_fix_pressure(stock) < pressure,
	"deck-fixing pressure should fall after the deck becomes concentrated and modified")
end

state.round_history[1] = { score = 1000, target = 2000 }
assert(Strategy.reserve(state, plan) == 0, "a run below survival pace should spend through its interest reserve")

state.money = 7
state.round_history[1] = { score = 2100, target = 2000, cleared = true }
assert(Strategy.reserve(state, plan) == 5,
	"a narrow clear should preserve the first interest tier instead of treating it as an emergency")

state.round_history[1] = { score = 1500, target = 2000, cleared = false }
assert(Strategy.deck_tool_utility(state,
	{ key = "c_devil", utility = 22, effect = "enhance", enhancement = "m_gold" }, plan) < 10,
	"a failed Blind should suppress non-scoring Gold enhancement spending")
state.round_history[1] = { score = 2100, target = 2000, cleared = true }

local pair_plan = {
	primary_hand = "Two Pair", secondary_hand = "Pair",
	shape = Strategy.analyze(state).shape,
	hand_scores = { ["Two Pair"] = 30, Pair = 25, ["Full House"] = 15 },
}
state.hand_usage = { ["Two Pair"] = 6, Pair = 4, ["Full House"] = 3 }
assert(Strategy.planet_utility(state, "Two Pair", pair_plan)
	> Strategy.planet_utility(state, "Full House", pair_plan),
	"a few lucky Full Houses must not outweigh the feasible planned hand's Planet")
assert(Strategy.hand_feasibility(state, "Full House", pair_plan)
	< Strategy.hand_feasibility(state, "Two Pair", pair_plan),
	"Planet feasibility should distinguish a rare composite hand from a repeatable Two Pair")

local ordinary = {
	deck = Cards.standard_deck(), jokers = { "j_lusty_joker" },
	joker_effects = { j_lusty_joker = { kind = "suit_mult", suit = "Hearts", amount = 3 } },
	levels = {}, hand_usage = {}, discards_per_round = 3, starting_deck_size = 52,
}
local ordinary_plan = Strategy.analyze(ordinary)
assert(ordinary_plan.shape.rank_focus == 0,
	"the ordinary four cards of each rank must not look like rank-fixed pair support")
assert(ordinary_plan.primary_hand ~= "Flush",
	"a suit payoff alone must not imply a Flush build in an evenly split deck")

local late_runner_state = {
	deck = Cards.standard_deck(), jokers = {}, joker_effects = {}, joker_state = {},
	levels = {}, hand_usage = { Pair = 8, ["Two Pair"] = 5 }, discards_per_round = 3,
	starting_deck_size = 52, ante = 4, previous_pvp_score = 5000, previous_player_score = 10000,
}
local late_runner = { key = "j_runner", utility = 27,
	effect = { kind = "straight_scaling_chips", amount = 15 } }
assert(Strategy.joker_utility(late_runner_state, late_runner, pair_plan_for_order) < 14,
	"a PvP deficit must not justify starting an unaligned Runner build late")
late_runner_state.ante = 2
assert(Strategy.joker_utility(late_runner_state, late_runner, pair_plan_for_order) < 14,
	"Ante 2 must not justify buying a fresh Runner into an established Pair build")

local square_conflict = {
	deck = Cards.standard_deck(), jokers = { "j_half" }, joker_state = {}, ante = 3,
	joker_effects = { j_half = { kind = "card_count_mult", maximum = 3, amount = 20 } },
	levels = {}, hand_usage = { Pair = 8 }, discards_per_round = 3, starting_deck_size = 52,
}
local square_offer = { key = "j_square", utility = 24,
	effect = { kind = "four_card_scaling_chips", amount = 4 } }
assert(Strategy.joker_utility(square_conflict, square_offer, pair_plan_for_order) <= 14,
	"a fresh Square Joker must be rejected while Half Joker makes every four-card play self-defeating")

local fixed = {
	deck = Cards.standard_deck(), jokers = { "j_green_joker" }, ante = 3,
	joker_effects = { j_green_joker = { kind = "green_scaling_mult", hand_add = 1, discard_sub = 1 } },
	joker_state = { j_green_joker = 8 }, levels = {}, hand_usage = { ["Two Pair"] = 7, Pair = 4 },
	discards_per_round = 3, starting_deck_size = 52, deck_fix_rank = 13, deck_fix_suit = "Hearts",
}
for index = 1, 4 do fixed.deck[index].rank = 13 end
local fixed_plan = Strategy.analyze(fixed)
local scholar = { key = "j_scholar", utility = 25,
	effect = { kind = "rank_chips_mult", ranks = { 14 }, chips = 20, mult = 4 } }
local arrowhead = { key = "j_arrowhead", utility = 30,
	effect = { kind = "suit_chips", suit = "Spades", amount = 50 } }
local stuntman = { key = "j_stuntman", utility = 35,
	effect = { kind = "flat_chips", amount = 250, hand_size = -2 } }
assert(Strategy.joker_utility(fixed, scholar, fixed_plan) < 14,
	"a rank-fixed King deck must reject Scholar's conflicting Ace payoff")
assert(Strategy.joker_utility(fixed, arrowhead, fixed_plan) <= 16,
	"a suit-fixed Hearts deck must strongly discount Arrowhead's conflicting Spade payoff")
assert(Strategy.joker_utility(fixed, stuntman, fixed_plan) < 14,
	"Green Joker and a Two Pair plan must reject Stuntman's hand-size conflict")
fixed.jokers, fixed.joker_effects = { "j_scholar" }, { j_scholar = scholar.effect }
fixed.deck_fix_rank = nil
local scholar_rank = Strategy.deck_fix_target(fixed)
assert(scholar_rank == 14,
	"Scholar must direct future deck fixing toward Aces instead of the neutral King default")

ordinary.hand_usage = { ["Straight Flush"] = 1 }
local lucky_plan = Strategy.analyze(ordinary)
assert(lucky_plan.primary_hand ~= "Straight Flush" and lucky_plan.confidence < 0.5,
	"one lucky Straight Flush must not masquerade as a repeatable stock-deck strategy")
assert(Strategy.hand_feasibility(ordinary, "Straight Flush", lucky_plan) < 0.1,
	"rare-hand feasibility must discount isolated observed outcomes")

ordinary.strategy_open = false
local exploration = Strategy.analyze(ordinary)
assert(exploration.exploring and exploration.primary_hand == nil and exploration.confidence == 0,
	"the bot must remain strategically uncommitted before seeing its first shop")
assert(Strategy.joker_utility(ordinary, matching, exploration) < matching.utility,
	"the first shop must feasibility-discount conditional Jokers without committing to their hand")
local unconditional = { key = "j_joker", utility = 16, effect = { kind = "flat_mult", amount = 4 } }
assert(Strategy.joker_utility(ordinary, unconditional, exploration) == unconditional.utility,
	"exploration should preserve the catalog value of unconditional scoring")
assert(Strategy.joker_utility(ordinary, order, exploration) < 14,
	"an exploratory first shop must not assume The Order is already active")

local economy_state = {
	deck = Cards.standard_deck(), jokers = {}, joker_effects = {}, levels = {},
	hand_usage = { Pair = 6 }, discards_per_round = 3, starting_deck_size = 52,
	round_history = { { score = 1000, target = 800, cleared = true, discards_used = 2 } },
}
local economy_plan = Strategy.analyze(economy_state)
local delayed = { key = "j_delayed_grat", utility = 21,
	effect = { kind = "round_money", per_unused_discard = 2, requires_no_discard = true } }
assert(Strategy.joker_utility(economy_state, delayed, economy_plan) < 14,
	"Delayed Gratification should be declined after the bot demonstrated discard-dependent play")
economy_state.round_history[1].discards_used = 0
assert(Strategy.joker_utility(economy_state, delayed, economy_plan) > 14,
	"Delayed Gratification should remain viable after a no-discard round")
local loyalty = { key = "j_loyalty_card", utility = 28,
	effect = { kind = "periodic_xmult", every = 6, initial = 6, amount = 4 } }
economy_state.next_round_is_pvp = true
economy_state.hands_per_round = 5
assert(Strategy.joker_utility(economy_state, loyalty, economy_plan) < 14,
	"a fresh Loyalty Card must be rejected when PvP ends before its first activation")
economy_state.next_round_is_pvp = false
assert(Strategy.joker_utility(economy_state, loyalty, economy_plan) >= 14,
	"Loyalty Card should retain long-horizon value outside an imminent PvP round")
local todo = { key = "j_todo_list", utility = 21,
	effect = { kind = "played_hand_money", amount = 4 } }
economy_state.money, economy_state.ante, economy_state.next_round_is_pvp = 40, 6, true
assert(Strategy.joker_utility(economy_state, todo, economy_plan) < 14,
	"late-game surplus cash must make an economy-only Joker replaceable before PvP")
economy_state.money, economy_state.ante, economy_state.next_round_is_pvp = nil, nil, false
local faceless = { key = "j_faceless", utility = 22,
	effect = { kind = "discard_face_money", count = 3, amount = 5 } }
assert(Strategy.joker_utility(economy_state, faceless, economy_plan) < 14,
	"Faceless Joker should not assume a stock deck will pursue its three-face discard trigger")
local troubadour = { key = "j_troubadour", utility = 25,
	effect = { kind = "round_resources", hands = -1, hand_size = 2 } }
assert(Strategy.joker_utility(economy_state, troubadour, economy_plan) < 14,
	"Troubadour's larger hand should not outweigh losing one scoring hand in an ordinary build")
local pareidolia = { key = "j_pareidolia", utility = 23, effect = { kind = "all_faces" } }
assert(Strategy.joker_utility(economy_state, pareidolia, economy_plan) < 14,
	"Pareidolia should be declined without face-card synergy")
economy_state.jokers = { "j_photograph" }
economy_state.joker_effects.j_photograph = { kind = "first_face_xmult", amount = 2 }
assert(Strategy.joker_utility(economy_state, pareidolia, economy_plan) >= 14,
	"Pareidolia should become viable beside Photograph")
economy_state.jokers[#economy_state.jokers + 1] = "j_pareidolia"
economy_state.joker_effects.j_pareidolia = { kind = "all_faces" }
assert(Strategy.joker_utility(economy_state, faceless, economy_plan) >= 14,
	"Pareidolia should make Faceless Joker's discard condition reliable")

assert(plan.confidence > 0 and plan.confidence < 1,
	"confidence should be normalized strategic support rather than a saturating gap bonus")

print("strategy_spec: ok")
