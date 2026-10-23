local modules = {
	PRNG = dofile("bot/prng.lua"),
	Cards = dofile("bot/cards.lua"),
	Content = dofile("bot/content.lua"),
	Evaluator = dofile("bot/evaluator.lua"),
	Strategy = dofile("bot/strategy.lua"),
	Policy = dofile("bot/policy.lua"),
	Simulator = dofile("bot/simulator.lua"),
	Order = dofile("bot/order.lua"),
}
modules = dofile("bot/expert.lua").modules(modules)   -- MultiBots' Expert decides

local function has_value(values, wanted)
	for _, value in ipairs(values or {}) do if value == wanted then return true end end
	return false
end

local deck = modules.Cards.standard_deck()
assert(#deck == 52, "standard deck must contain 52 cards")
local seen = {}
for _, card in ipairs(deck) do
	assert(not seen[card.id], "standard deck contains a duplicate " .. card.id)
	seen[card.id] = true
end

local function run(difficulty, the_order, banned)
	return modules.Simulator.run({
		seed = "SIMTEST",
		difficulty = difficulty,
		max_ante = 4,
		the_order = the_order,
		banned_jokers = banned or {},
	}, modules)
end

local first, first_state = run("normal", true)
local second, second_state = run("normal", true)
for ante = 1, 4 do
	assert(#first[ante].hands == #second[ante].hands, "ordered simulation hand count must be deterministic")
	for index, hand in ipairs(first[ante].hands) do
		assert(hand.score == second[ante].hands[index].score, "ordered simulation score must be deterministic")
	end
end
assert(first_state.the_order and second_state.the_order, "The Order flag should be retained")

local banned_key = "j_joker"
local _, banned_state = run("expert", true, { [banned_key] = true })
for _, joker in ipairs(banned_state.jokers) do assert(joker ~= banned_key, "banned Joker was purchased") end

local abandoned_state = modules.Simulator.new({
	seed = "ABANDONED", difficulty = "normal", the_order = true, deck = "Abandoned Deck",
}, modules)
for _, card in ipairs(abandoned_state.deck) do
	assert(card.rank < 11 or card.rank > 13, "Abandoned Deck should not contain face cards")
end

local checkered_state = modules.Simulator.new({
	seed = "CHECKERED", difficulty = "normal", the_order = true, deck = "Checkered Deck",
}, modules)
for _, card in ipairs(checkered_state.deck) do
	assert(card.suit == "Spades" or card.suit == "Hearts", "Checkered Deck should contain only Spades and Hearts")
end

local _, fixing_state = modules.Simulator.run({
	seed = "DECKFIX", difficulty = "expert", max_ante = 16, the_order = true, deck = "Ghost Deck",
}, modules)
local fixed_deck = fixing_state.ante_states[16].deck
local changed = #fixed_deck ~= 52
for _, card in ipairs(fixed_deck) do
	if card.enhancement or card.edition or card.seal then changed = true end
end
assert(changed, "a long expert run should perform persistent deck fixing")

local easy = run("easy", true)
local expert = run("expert", true)
local function total_score(snapshots)
	local total = 0
	for ante = 1, #snapshots do
		local hands = snapshots[ante].hands
		if #hands > 0 then total = total + tonumber(hands[#hands].score) end
	end
	return total
end
local easy_total, expert_total = total_score(easy), total_score(expert)
-- Difficulty changes both decisions and therefore later shop/extinction RNG
-- paths and supported-content additions change shop pools; one four-Ante seed
-- is not a strict ordering proof. Guard against catastrophic Expert regression
-- while policy_spec checks action quality.
assert(expert_total > easy_total * 0.65,
	"Expert should remain competitive across the deterministic test run: " .. easy_total .. " vs " .. expert_total)

local live = modules.Simulator.new({ seed = "LIVE", difficulty = "normal", the_order = true }, modules)
modules.Simulator.set_ante(live, 1)
assert(#live.decisions == 0, "a live run should not precompute future decisions")
local live_small = modules.Simulator.play_round(live, modules.Simulator.base_score(1), "Small")
assert(#live.decisions > 0, "entering a live blind should produce decisions")
local previous_decision_id = 0
for _, decision in ipairs(live.decisions) do
	assert(decision.plan_exploring, "Ante 1 Small decisions should remain in pre-shop exploration")
	assert(decision.decision_id == previous_decision_id + 1, "decision IDs should be unique and monotonic")
	previous_decision_id = decision.decision_id
	if decision.type == "play" or decision.type == "discard" then
		assert(decision.hand_contents and decision.candidates and decision.snapshot
			and decision.chosen_utility and decision.best_utility and decision.regret,
			"hand decisions should retain compact pre-action state, candidates, utility, and regret")
	end
end
local decisions_after_blind = #live.decisions
modules.Simulator.award_blind(live, "Small", live_small)
modules.Simulator.visit_shop(live)
assert(#live.decisions >= decisions_after_blind, "live shop actions should append to current state")
local shop_diagnostic
for _, decision in ipairs(live.decisions) do
	if decision.type == "shop_decision" then shop_diagnostic = decision end
end
assert(shop_diagnostic and shop_diagnostic.shop_id and shop_diagnostic.offered ~= nil
	and shop_diagnostic.supported ~= nil and shop_diagnostic.evaluated
	and shop_diagnostic.chosen and shop_diagnostic.snapshot and shop_diagnostic.regret ~= nil,
	"each shop should record an analyzable buy/skip decision, including empty or unsupported shops")
assert(live.strategy_open and not live.strategy_plan.exploring,
	"finishing the first shop should unlock persistent build planning")

local riff = modules.Simulator.new({ seed = "RIFF-RAFF", difficulty = "expert" }, modules)
riff.jokers = { "j_riff_raff" }
riff.joker_state.j_riff_raff = 0
modules.Simulator.begin_round(riff, 300, "Small")
assert(#riff.jokers == 3,
	"Riff-Raff should create two distinct Common Jokers when slots are open")

local cartomancer = modules.Simulator.new({ seed = "CARTOMANCER", difficulty = "expert" }, modules)
cartomancer.jokers = { "j_cartomancer" }
cartomancer.deck_tools = {
	{ key = "c_hanged_man", set = "Tarot", cost = 3, utility = 30, effect = "remove", count = 2 },
}
cartomancer.strategy_open = true
modules.Simulator.begin_round(cartomancer, 300, "Small")
assert(#cartomancer.deck == 50 and cartomancer.tarots_used == 1,
	"Cartomancer should create and use one supported Tarot when a Blind is selected")

do
local asteroid_catalog = modules.Content.build({
	Planet = { { key = "c_mp_asteroid", cost = 3, config = {} } },
}, {}, {})
local asteroid_sender = modules.Simulator.new({
	seed = "ASTEROID-SENDER", difficulty = "expert", the_order = true,
	content_catalog = asteroid_catalog,
}, modules)
asteroid_sender.money = 20
local asteroid_report = modules.Simulator.visit_shop(asteroid_sender, { "c_mp_asteroid" })
local asteroid_used = false
for _, decision in ipairs(asteroid_sender.decisions) do
	if decision.type == "use_consumable" and decision.key == "c_mp_asteroid" then asteroid_used = true end
end
assert(asteroid_report.purchases == 1 and asteroid_used and #asteroid_sender.consumables == 0,
	"Asteroid should be bought, consumed, and exposed as a relayable PvP action")
end

do
local astronomer = modules.Simulator.new({ seed = "ASTRONOMER", difficulty = "expert", the_order = true }, modules)
astronomer.money = 20
local astronomer_report = modules.Simulator.visit_shop(astronomer, { "j_astronomer", "c_mercury" })
assert(astronomer_report.purchases == 2 and has_value(astronomer.jokers, "j_astronomer")
	and astronomer.levels.Pair == 2 and astronomer.money == 12,
	"Astronomer should make a Planet in the same shop free after it is installed")
end

do
local marble = modules.Simulator.new({ seed = "MARBLE", difficulty = "expert" }, modules)
marble.jokers = { "j_marble" }
marble.joker_state.j_marble = 0
local marble_deck_size = #marble.deck
modules.Simulator.begin_round(marble, 300, "Small")
local stone_cards = 0
for _, card in ipairs(marble.deck) do if card.enhancement == "m_stone" then stone_cards = stone_cards + 1 end end
assert(#marble.deck == marble_deck_size + 1 and stone_cards == 1 and marble.cards_added == 1,
	"Marble Joker should add one Stone card before each Blind draw")
end

do
local business = modules.Simulator.new({ seed = "BUSINESS", difficulty = "expert", hands_per_round = 1 }, modules)
business.jokers = { "j_business" }
business.joker_state.j_business = 0
business.joker_effects.j_business.odds = 1
business.deck = {}
for index = 1, 8 do
	local card = { suit = modules.Cards.suits[((index - 1) % 4) + 1], rank = 13 }
	modules.Cards.refresh(card, ":business:" .. index)
	business.deck[#business.deck + 1] = card
end
local business_money = business.money
modules.Simulator.play_round(business, 1, "Small")
assert(business.money > business_money,
	"Business Card should award money for scoring face cards when its roll succeeds")
end

do
local omen_found_spectral = false
for attempt = 1, 40 do
	local omen = modules.Simulator.new({ seed = "OMEN-" .. attempt, difficulty = "expert" }, modules)
	omen.money = 30
	omen.vouchers = { "v_omen_globe" }
	modules.Simulator.visit_shop(omen, { "p_arcana_mega_1" })
	for _, decision in ipairs(omen.decisions) do
		if decision.type == "buy_pack" and tostring(decision.picked or ""):find("c_cryptid", 1, true) then
			omen_found_spectral = true
		end
	end
	if omen_found_spectral then break end
end
assert(omen_found_spectral,
	"Omen Globe should allow a supported Spectral card to replace an Arcana Pack Tarot slot")
end

local space = modules.Simulator.new({ seed = "SPACE", difficulty = "expert" }, modules)
space.jokers = { "j_space" }
space.joker_state.j_space = 0
space.rng = {
	fork = function()
		return {
			next = function() return 0 end,
			integer = function(_, low) return low end,
			fork = function(self) return self end,
		}
	end,
}
local levels_before = 0
for _, level in pairs(space.levels) do levels_before = levels_before + level end
modules.Simulator.play_round(space, 1, "Small")
local levels_after = 0
for _, level in pairs(space.levels) do levels_after = levels_after + level end
assert(levels_after == levels_before + 1,
	"Space Joker should deterministically upgrade the played hand when its chance succeeds")

local rich_reroll = modules.Simulator.new({ seed = "RICH-REROLL", difficulty = "expert" }, modules)
modules.Simulator.set_ante(rich_reroll, 6)
rich_reroll.money = 60
rich_reroll.jokers = { "j_joker", "j_abstract" }
assert(modules.Expert.should_reroll(rich_reroll,
	{ purchases = 1, supported_keys = { "j_joker" } }, 5),
	"a rich late build without XMult should reroll even after buying a non-power item")
rich_reroll.interest_cap = 10
rich_reroll.money = 63
assert(modules.Strategy.reserve(rich_reroll, rich_reroll.strategy_plan) == 50,
	"Seed Money's $10 interest cap should preserve $50 when the build is healthy")
assert(modules.Expert.should_reroll(rich_reroll, { purchases = 0, supported_keys = {} }, 7),
	"a late build without XMult should keep rerolling above its interest cap")
rich_reroll.money = 56
assert(not modules.Expert.should_reroll(rich_reroll, { purchases = 0, supported_keys = {} }, 7),
	"a chained reroll must stop when its escalating cost would cross the interest cap")
assert(modules.Simulator.next_reroll_cost(rich_reroll, 0) == 5
	and modules.Simulator.next_reroll_cost(rich_reroll, 3) == 8,
	"shop reroll costs should start at $5 and rise by $1 each time")
local chaos_reroll = modules.Simulator.new({ seed = "CHAOS-REROLL", difficulty = "expert" }, modules)
chaos_reroll.jokers = { "j_chaos" }
-- the free reroll does not raise the price (button_callbacks.lua
-- reroll_shop: calculate_reroll_cost(final_free)), so the next one costs $5.
assert(modules.Simulator.next_reroll_cost(chaos_reroll, 0) == 0
	and modules.Simulator.next_reroll_cost(chaos_reroll, 1) == 5,
	"Chaos should make exactly the first reroll in each shop free")
assert(modules.Expert.should_reroll(chaos_reroll,
	{ purchases = 1, supported_keys = { "j_joker" } }, 0),
	"the bot should always consume Chaos's free reroll")
rich_reroll.money = 5
assert(not modules.Expert.should_reroll(rich_reroll,
	{ purchases = 0, supported_keys = {} }, 5),
	"rerolls must preserve the strategy reserve")
local conditional_reroll = modules.Simulator.new({ seed = "CONDITIONAL-REROLL", difficulty = "expert" }, modules)
modules.Simulator.set_ante(conditional_reroll, 4)
conditional_reroll.money = 34
conditional_reroll.jokers = { "j_baron", "j_photograph" }
assert(modules.Expert.should_reroll(conditional_reroll,
	{ purchases = 1, supported_keys = { "p_arcana_normal_1" } }, 5),
	"conditional Baron and Photograph XMult should not hide a late reliable-power gap")
conditional_reroll.jokers = { "j_cavendish" }
assert(not modules.Expert.should_reroll(conditional_reroll,
	{ purchases = 1, supported_keys = { "j_cavendish" } }, 5),
	"reliable flat XMult should satisfy the late power check")
local repeat_reroll = modules.Simulator.new({ seed = "REPEAT-REROLL", difficulty = "expert" }, modules)
modules.Simulator.set_ante(repeat_reroll, 4)
repeat_reroll.money = 34
repeat_reroll.jokers = { "j_card_sharp" }
repeat_reroll.round_hand_usage = { ["Two Pair"] = 1 }
assert(modules.Expert.should_reroll(repeat_reroll,
	{ purchases = 1, supported_keys = { "j_card_sharp" } }, 5),
	"Card Sharp should not hide a power gap before its repeat-hand condition is proven")
repeat_reroll.round_hand_usage["Two Pair"] = 2
assert(not modules.Expert.should_reroll(repeat_reroll,
	{ purchases = 1, supported_keys = { "j_card_sharp" } }, 5),
	"Card Sharp should satisfy the power check after triggering in the latest blind")
do
local poor_reroll = modules.Simulator.new({ seed = "POOR-REROLL", difficulty = "expert" }, modules)
modules.Simulator.set_ante(poor_reroll, 5)
poor_reroll.money = 8
poor_reroll.jokers = { "j_joker" }
assert(not modules.Expert.should_reroll(poor_reroll,
	{ purchases = 1, supported_keys = { "j_joker" } }, 5),
	"a paid reroll without economy must not spend below the literal interest cap")
poor_reroll.jokers = { "j_golden" }
assert(modules.Expert.should_reroll(poor_reroll,
	{ purchases = 1, supported_keys = { "j_golden" } }, 5),
	"an income Joker should allow catch-up rerolls below the literal interest cap")
poor_reroll.jokers = { "j_joker" }
poor_reroll.money, poor_reroll.ante = 8, 3
poor_reroll.previous_pvp_score, poor_reroll.previous_player_score = 13000, 88000
assert(modules.Expert.should_reroll(poor_reroll,
	{ purchases = 2, supported_keys = { "j_joker" } }, 5),
	"a severe PvP deficit should fund an emergency power reroll despite prior purchases")
end
local live_snapshot = modules.Simulator.snapshot(live)
assert(#live_snapshot.deck > 0 and live_snapshot.money == live.money, "live snapshot should reflect current state")

local ordered_jokers = modules.Simulator.new({ seed = "JOKERORDER", difficulty = "expert" }, modules)
ordered_jokers.jokers = { "j_cavendish", "j_joker" }
modules.Simulator.play_round(ordered_jokers, nil, "Small")
assert(ordered_jokers.jokers[1] == "j_joker" and ordered_jokers.jokers[2] == "j_cavendish",
	"the bot should move additive Mult before XMult before playing")
local logged_reorder = false
for _, decision in ipairs(ordered_jokers.decisions) do
	if decision.type == "reorder_jokers" then logged_reorder = true; break end
end
assert(logged_reorder, "Joker reordering should be visible in compact playtest logs")

local shop_order = modules.Simulator.new({ seed = "SHOP-ORDER", difficulty = "expert" }, modules)
shop_order.jokers = { "j_runner", "j_ramen", "j_stuntman", "j_abstract", "j_square" }
modules.Simulator.visit_shop(shop_order, {})
local abstract_slot, ramen_slot
for index, key in ipairs(shop_order.jokers) do
	if key == "j_abstract" then abstract_slot = index end
	if key == "j_ramen" then ramen_slot = index end
end
assert(abstract_slot < ramen_slot and ramen_slot == #shop_order.jokers,
	"shop state should place additive Mult before Ramen's XMult immediately")

local doomed = modules.Simulator.new({ seed = "DOOMED", difficulty = "easy", the_order = true }, modules)
modules.Simulator.set_ante(doomed, 1)
local impossible = modules.Simulator.play_round(doomed, 1e20, "Boss")
local money_before_failure = doomed.money
assert(not modules.Simulator.award_blind(doomed, "Boss", impossible), "an uncleared blind must not be awarded")
local failure = doomed.decisions[#doomed.decisions]
assert(failure.type == "fail_round" and failure.score < failure.target and failure.hands_used > 0,
	"an uncleared blind must produce a networkable failure decision")
assert(failure.hands_remaining ~= nil and failure.hands_available
	and failure.discards_remaining ~= nil and failure.discards_available
	and failure.consumables_remaining ~= nil and failure.consumables_available ~= nil,
	"blind failures should retain remaining and available resources for outcome-based anomaly detection")
assert(doomed.money == money_before_failure + 9,
	"a failed Boss Blind should retain its base reward and receive $4 comeback gold")

local no_comeback = modules.Simulator.new({
	seed = "NOCOMEBACK", difficulty = "easy", the_order = true, gold_on_life_loss = false,
}, modules)
modules.Simulator.set_ante(no_comeback, 1)
local no_comeback_result = modules.Simulator.play_round(no_comeback, 1e20, "Boss")
local no_comeback_before = no_comeback.money
modules.Simulator.award_blind(no_comeback, "Boss", no_comeback_result)
assert(no_comeback.money == no_comeback_before + 5,
	"disabling comeback gold should leave only the failed Boss payout and interest")

local no_loss_gold = modules.Simulator.new({
	seed = "NOLOSSGOLD", difficulty = "easy", the_order = true, no_gold_on_round_loss = true,
}, modules)
modules.Simulator.set_ante(no_loss_gold, 1)
local no_gold_result = modules.Simulator.play_round(no_loss_gold, 1e20, "Boss")
local no_gold_before = no_loss_gold.money
modules.Simulator.award_blind(no_loss_gold, "Boss", no_gold_result)
assert(no_loss_gold.money == no_gold_before + no_gold_result.hands_left + 4,
	"No Blind Reward on Round Loss should suppress only the Blind's base payout, not comeback gold")

local pvp_loser = modules.Simulator.new({
	seed = "PVPLOSS", difficulty = "normal", the_order = true, gold_on_life_loss = true,
}, modules)
local pvp_before = pvp_loser.money
modules.Simulator.award_blind(pvp_loser, "Boss", {
	cleared = true, life_lost = true, hands_left = 0,
})
assert(pvp_loser.money == pvp_before + 9,
	"a PvP loss must receive the normal payout plus enabled comeback gold")

local ordered_a = modules.Cards.shuffle(modules.Cards.standard_deck(), modules.PRNG.new("*LIVE"), "1:Boss", true)
local ordered_b = modules.Cards.shuffle(modules.Cards.standard_deck(), modules.PRNG.new("*LIVE"), "1:Boss", true)
for index, card in ipairs(ordered_a) do
	assert(card.id == ordered_b[index].id, "ordered shuffle must remain deterministic")
end
local opening = {}
for index = #ordered_a, #ordered_a - 7, -1 do opening[#opening + 1] = ordered_a[index] end
local has_straight_flush = false
for _, indices in ipairs(modules.Policy.combinations(#opening, 5)) do
	local cards = {}
	for _, index in ipairs(indices) do cards[#cards + 1] = opening[index] end
	if modules.Evaluator.classify(cards) == "Straight Flush" then has_straight_flush = true end
end
assert(not has_straight_flush, "ordered shuffle must not stack the known opening Straight Flush")

local replacement_pool = {
	{ key = "j_weak_1", cost = 2, utility = 1, effect = { kind = "flat_mult", amount = 1 } },
	{ key = "j_weak_2", cost = 2, utility = 2, effect = { kind = "flat_mult", amount = 1 } },
	{ key = "j_weak_3", cost = 2, utility = 3, effect = { kind = "flat_mult", amount = 1 } },
	{ key = "j_weak_4", cost = 2, utility = 4, effect = { kind = "flat_mult", amount = 1 } },
	{ key = "j_weak_5", cost = 2, utility = 5, effect = { kind = "flat_mult", amount = 1 } },
	{ key = "j_upgrade", cost = 6, utility = 50, effect = { kind = "flat_mult", amount = 20 } },
}
local replacement = modules.Simulator.new({
	seed = "REPLACE", difficulty = "expert", the_order = true, joker_pool = replacement_pool,
}, modules)
replacement.jokers = { "j_weak_1", "j_weak_2", "j_weak_3", "j_weak_4", "j_weak_5" }
replacement.planet_pool, replacement.deck_tools, replacement.money = {}, {}, 20
modules.Simulator.set_ante(replacement, 3)
for _ = 1, 40 do modules.Simulator.visit_shop(replacement) end
assert(#replacement.jokers == 5, "replacement test must retain the Joker slot limit")
local bought_upgrade, sold_weak = false, false
for _, key in ipairs(replacement.jokers) do if key == "j_upgrade" then bought_upgrade = true end end
for _, decision in ipairs(replacement.decisions) do
	if decision.type == "sell_joker" and decision.key == "j_weak_1" then sold_weak = true end
end
assert(bought_upgrade and sold_weak, "a full build should sell its weakest Joker for a better affordable one")

local skip_off = modules.Simulator.new({
	seed = "SKIP-OFF", difficulty = "expert", the_order = true,
	content_catalog = {
		jokers = { { key = "j_mp_skip_off", cost = 5, utility = 20,
			effect = { kind = "skip_advantage_resources", hands = 1, discards = 1 } } },
		planets = {}, deck_tools = {}, packs = {}, vouchers = {},
	},
}, modules)
skip_off.jokers = { "j_mp_skip_off" }
skip_off.skips, skip_off.opponent_skips = 3, 1
local skip_off_round = modules.Simulator.begin_round(skip_off, 100, "Small")
assert(skip_off_round.starting_hands == skip_off.hands_per_round + 2
	and skip_off_round.starting_discards == skip_off.discards_per_round + 2,
	"Skip-Off should grant one hand and discard per skip lead")

local decayed_replacement = modules.Simulator.new({
	seed = "DECAYED-REPLACE", difficulty = "expert", the_order = true,
	content_catalog = {
		jokers = {
			{ key = "j_ice_cream", cost = 5, utility = 25,
				effect = { kind = "decaying_chips", initial = 100, amount = 5, destroy_at = 0 } },
			{ key = "j_keep_1", cost = 6, utility = 30, effect = { kind = "flat_mult", amount = 12 } },
			{ key = "j_keep_2", cost = 6, utility = 30, effect = { kind = "flat_mult", amount = 12 } },
			{ key = "j_keep_3", cost = 6, utility = 30, effect = { kind = "flat_mult", amount = 12 } },
			{ key = "j_keep_4", cost = 6, utility = 30, effect = { kind = "flat_mult", amount = 12 } },
			{ key = "j_burglar", cost = 6, utility = 30,
				effect = { kind = "round_resources", hands = 3, reset_discards = true } },
		}, planets = {}, deck_tools = {}, packs = {}, vouchers = {},
	},
}, modules)
decayed_replacement.money = 20
decayed_replacement.jokers = { "j_ice_cream", "j_keep_1", "j_keep_2", "j_keep_3", "j_keep_4" }
decayed_replacement.joker_state.j_ice_cream = 15
modules.Simulator.set_ante(decayed_replacement, 4)
modules.Simulator.visit_shop(decayed_replacement, { "j_burglar" })
assert(not has_value(decayed_replacement.jokers, "j_ice_cream")
	and has_value(decayed_replacement.jokers, "j_burglar"),
	"a nearly exhausted temporary Joker should be sold for a durable material upgrade")

local stencil_guard = modules.Simulator.new({
	seed = "STENCIL-GUARD", difficulty = "expert", the_order = true,
	content_catalog = {
		jokers = {
			{ key = "j_stencil", cost = 8, utility = 30, effect = { kind = "empty_slot_xmult" } },
			{ key = "j_keep_1", cost = 4, utility = 25, effect = { kind = "flat_mult", amount = 10 } },
			{ key = "j_keep_2", cost = 4, utility = 25, effect = { kind = "flat_mult", amount = 10 } },
			{ key = "j_keep_3", cost = 4, utility = 25, effect = { kind = "flat_mult", amount = 10 } },
			{ key = "j_smiley", cost = 4, utility = 23, effect = { kind = "face_mult", amount = 5 } },
			{ key = "j_cavendish", cost = 4, utility = 31, effect = { kind = "flat_xmult", amount = 3 } },
		}, planets = {}, deck_tools = {},
	},
}, modules)
stencil_guard.money = 100
stencil_guard.jokers = { "j_stencil", "j_keep_1", "j_keep_2", "j_keep_3" }
modules.Simulator.set_ante(stencil_guard, 4)
modules.Simulator.visit_shop(stencil_guard, { "j_smiley" })
assert(#stencil_guard.jokers == 4,
	"a mediocre additive Joker must not consume Stencil's final x2 slot")
modules.Simulator.visit_shop(stencil_guard, { "j_cavendish" })
assert(#stencil_guard.jokers == 5 and stencil_guard.jokers[5] == "j_cavendish",
	"Stencil may give up its final open slot for a genuinely stronger XMult card")

local scaler_keeper = modules.Simulator.new({
	seed = "KEEP-SCALER", difficulty = "expert", the_order = true,
	content_catalog = {
		jokers = {
			{ key = "j_square", cost = 4, utility = 24,
				effect = { kind = "four_card_scaling_chips", amount = 4 } },
			{ key = "j_runner", cost = 5, utility = 27,
				effect = { kind = "straight_scaling_chips", amount = 15 } },
			{ key = "j_keep_1", cost = 8, utility = 50 },
			{ key = "j_keep_2", cost = 8, utility = 50 },
			{ key = "j_keep_3", cost = 8, utility = 50 },
			{ key = "j_keep_4", cost = 8, utility = 50 },
		}, planets = {}, deck_tools = {},
	},
}, modules)
modules.Simulator.set_ante(scaler_keeper, 6)
scaler_keeper.money = 100
scaler_keeper.jokers = { "j_square", "j_keep_1", "j_keep_2", "j_keep_3", "j_keep_4" }
scaler_keeper.joker_state.j_square = 84
modules.Simulator.visit_shop(scaler_keeper, { "j_runner" })
local bought_fresh_runner = false
for _, key in ipairs(scaler_keeper.jokers) do
	if key == "j_runner" then bought_fresh_runner = true end
end
assert(scaler_keeper.jokers[1] == "j_square" and not bought_fresh_runner,
	"an established +84 Square Joker must not be sold for a fresh Runner")

local mirrored = modules.Simulator.new({
	seed = "MIRROR", difficulty = "expert", the_order = true,
	content_catalog = {
		jokers = { { key = "j_joker", cost = 2, utility = 16, effect = { kind = "flat_mult", amount = 4 } } },
		planets = {}, deck_tools = {},
	},
}, modules)
modules.Simulator.set_ante(mirrored, 2)
modules.Simulator.visit_shop(mirrored, { "j_not_in_order_adapter", "j_joker" })
assert(#mirrored.jokers == 1 and mirrored.jokers[1] == "j_joker",
	"ordered shops must buy only supported keys present in the mirrored Order shop")

local pack_only = modules.Simulator.new({
	seed = "PRIVATEPACK", difficulty = "expert", the_order = true, strict_order_content = true,
	content_catalog = {
		jokers = {}, planets = {},
		deck_tools = { { key = "p_standard_normal_1", set = "Booster", cost = 4, utility = 6, effect = "add" } },
	},
}, modules)
pack_only.Order = {
	generate_pack = function(_, key)
		assert(key == "p_standard_normal_1", "the purchased visible Booster key should be opened")
		return {
			{ kind = "playing_card", rank = 13, suit = "Hearts", enhancement = "m_lucky",
				edition = "polychrome", seal = "Red" },
			{ kind = "playing_card", rank = 2, suit = "Clubs" },
			{ kind = "playing_card", rank = 3, suit = "Clubs" },
		}
	end,
}
pack_only.money = 20
local pack_report = modules.Simulator.visit_shop(pack_only, { "j_unsupported_modded", "p_standard_normal_1" })
assert(pack_report.purchases == 1 and #pack_only.deck == 53 and pack_only.money == 16,
	"a bought Order Booster should privately generate and apply its best supported card")
local packed_card = pack_only.deck[#pack_only.deck]
assert(packed_card.rank == 13 and packed_card.suit == "Hearts" and packed_card.edition == "polychrome",
	"the bot should choose from the private pack contents rather than inventing a reward")
assert(#pack_report.keys == 2 and #pack_report.supported_keys == 1,
	"a privately generatable Order Booster should be a supported offer")

do
local pack_jokers = modules.Simulator.new({
	seed = "PACK-JOKERS", difficulty = "expert", the_order = true, strict_order_content = true,
	content_catalog = {
		jokers = {
			{ key = "j_hallucination", cost = 4, utility = 20,
				effect = { kind = "pack_tarot_chance", odds = 1 } },
			{ key = "j_red_card", cost = 5, utility = 23,
				effect = { kind = "skipped_pack_scaling_mult", amount = 3 } },
		},
		planets = {}, packs = { "p_standard_mega_1" },
		deck_tools = { { key = "c_star", set = "Tarot", cost = 3, utility = 25,
			effect = "suit", suit = "Diamonds", count = 3 } },
	},
}, modules)
pack_jokers.jokers = { "j_hallucination", "j_red_card" }
pack_jokers.joker_state.j_hallucination = 0
pack_jokers.joker_state.j_red_card = 0
pack_jokers.Order = { generate_pack = function()
	return { { kind = "playing_card", rank = 13, suit = "Hearts",
		edition = "polychrome", seal = "Red" } }
end }
pack_jokers.money = 20
local pack_joker_report = modules.Simulator.visit_shop(pack_jokers, { "p_standard_mega_1" })
assert(pack_joker_report.purchases == 1 and #pack_jokers.consumables == 1,
	"Hallucination should create a Tarot when its Booster-open chance succeeds")
assert(pack_jokers.joker_state.j_red_card == 3,
	"Red Card should gain +3 Mult when remaining Mega Booster picks are skipped")
end

do
local superposition = modules.Simulator.new({
	seed = "SUPERPOSITION", difficulty = "expert", hands_per_round = 1, discards_per_round = 0,
	content_catalog = {
		jokers = { { key = "j_superposition", cost = 4, utility = 20,
			effect = { kind = "straight_ace_tarot" } } },
		planets = {}, packs = {},
		deck_tools = { { key = "c_star", set = "Tarot", cost = 3, utility = 25,
			effect = "suit", suit = "Diamonds", count = 3 } },
	},
}, modules)
superposition.jokers = { "j_superposition" }
superposition.joker_state.j_superposition = 0
superposition.deck = {
	{ rank = 14, suit = "Hearts", chips = 11, id = "sa" },
	{ rank = 2, suit = "Spades", chips = 2, id = "s2" },
	{ rank = 3, suit = "Clubs", chips = 3, id = "s3" },
	{ rank = 4, suit = "Diamonds", chips = 4, id = "s4" },
	{ rank = 5, suit = "Hearts", chips = 5, id = "s5" },
}
superposition.starting_deck_size = #superposition.deck
local superposition_round = modules.Simulator.play_round(superposition, 1, "Small")
assert(superposition_round.cleared and #superposition.consumables == 1,
	"Superposition should create a Tarot after scoring an Ace Straight")
end

local marginal_buffoon = modules.Simulator.new({
	seed = "MARGINAL-BUFFOON", difficulty = "expert", the_order = true, strict_order_content = true,
}, modules)
marginal_buffoon.Order = {
	generate_pack = function()
		return {
			{ kind = "center", key = "j_ceremonial" },
			{ kind = "center", key = "j_mystic_summit" },
		}
	end,
}
marginal_buffoon.money = 9
local marginal_report = modules.Simulator.visit_shop(marginal_buffoon, { "p_buffoon_normal_1" })
assert(marginal_report.purchases == 1 and marginal_buffoon.jokers[1] == "j_mystic_summit",
	"a paid Buffoon Pack should install its best positive supported Joker when a slot is open")

local multi_rank_pack = modules.Simulator.new({
	seed = "MULTI-RANK-PACK", difficulty = "expert", the_order = true, strict_order_content = true,
}, modules)
multi_rank_pack.jokers = { "j_hack", "j_fibonacci" }
multi_rank_pack.Order = {
	generate_pack = function()
		return {
			{ kind = "playing_card", rank = 5, suit = "Clubs" },
			{ kind = "playing_card", rank = 7, suit = "Clubs" },
			{ kind = "playing_card", rank = 9, suit = "Diamonds" },
		}
	end,
}
multi_rank_pack.money = 20
modules.Simulator.set_ante(multi_rank_pack, 2)
local multi_rank_report = modules.Simulator.visit_shop(multi_rank_pack, { "p_standard_normal_1" })
local multi_rank_card = multi_rank_pack.deck[#multi_rank_pack.deck]
assert(multi_rank_report.purchases == 1 and multi_rank_card.rank == 5,
	"Standard Packs should preserve every rank supported by multi-rank Jokers, not only one target rank")

-- a Booster's cards are unknown until it is opened (as in
-- the game), so only the old peeking shop (legacy_shop) can see that this pack
-- holds nothing useful.
local useless_arcana = modules.Simulator.new({
	seed = "OPTIONALPACK", difficulty = "expert", legacy_shop = true,
	content_catalog = {
		jokers = {}, planets = {},
		deck_tools = { { key = "c_moon", set = "Tarot", cost = 3, utility = 25,
			effect = "suit", suit = "Spades", count = 3 } },
	},
}, modules)
useless_arcana.money = 20
useless_arcana.strategy_open = true
useless_arcana.strategy_plan = modules.Strategy.analyze(useless_arcana)
local arcana_report = modules.Simulator.visit_shop(useless_arcana, { "p_arcana_normal_1" })
assert(arcana_report.purchases == 0 and useless_arcana.money == 20,
	"an Arcana Pack containing no useful deck-fixing option should be skipped")

local useful_spectral = modules.Simulator.new({
	seed = "SPECTRALPACK", difficulty = "expert",
	content_catalog = {
		jokers = {}, planets = {},
		deck_tools = { { key = "c_cryptid", set = "Spectral", cost = 4, utility = 32,
			effect = "duplicate", count = 1 } },
	},
}, modules)
useful_spectral.money = 20
useful_spectral.strategy_open = true
useful_spectral.strategy_plan = modules.Strategy.analyze(useful_spectral)
local spectral_report = modules.Simulator.visit_shop(useful_spectral, { "p_spectral_normal_1" })
-- a pack's cards are drawn when it is opened, from all 16
-- vanilla Spectrals (only Cryptid is in this catalog): Cryptid is applied when it shows.
do
local spectral_revealed = ""
for _, decision in ipairs(useful_spectral.decisions) do
	if decision.type == "buy_pack" then spectral_revealed = decision.modeled or "" end
end
assert(spectral_report.purchases == 1
	and #useful_spectral.deck == (spectral_revealed:find("c_cryptid", 1, true) and 53 or 52),
	"a useful visible Spectral Pack should apply its selected deck tool")
end

local hologram_standard = modules.Simulator.new({
	seed = "STANDARDPACK", difficulty = "expert",
	content_catalog = { jokers = {}, planets = {}, deck_tools = {} },
}, modules)
hologram_standard.money = 20
hologram_standard.jokers = { "j_hologram" }
local standard_report = modules.Simulator.visit_shop(hologram_standard, { "p_standard_normal_1" })
assert(standard_report.purchases == 1 and #hologram_standard.deck == 53
	and hologram_standard.cards_added == 1,
	"Standard Packs should choose and install a visible playing card when adding cards has synergy")

local off_plan = modules.Simulator.new({
	seed = "OFFPLAN", difficulty = "expert", the_order = true,
	content_catalog = {
		jokers = {}, planets = {},
		deck_tools = { { key = "c_low_value", set = "Tarot", cost = 3, utility = 18,
			effect = "enhance", count = 1 } },
	},
}, modules)
off_plan.money = 20
local off_plan_report = modules.Simulator.visit_shop(off_plan, { "c_low_value" })
assert(off_plan_report.purchases == 0,
	"an adjusted shop priority below the quality floor must not become a purchase merely by being the only offer")

local hologram = modules.Simulator.new({
	seed = "HOLOGRAM", difficulty = "expert", the_order = true,
	content_catalog = {
		jokers = { { key = "j_hologram", cost = 7, utility = 31,
			effect = { kind = "deck_add_scaling_xmult", initial = 1, amount = 0.25 } } },
		planets = {}, deck_tools = {},
	},
}, modules)
hologram.money = 20
modules.Simulator.set_ante(hologram, 2)
local hologram_report = modules.Simulator.visit_shop(hologram, { "j_hologram" })
assert(hologram_report.purchases == 0 and #hologram.jokers == 0,
	"Hologram must not be bought without prior deck growth or a simultaneously affordable card-adding enabler")

local turtle = modules.Simulator.new({
	seed = "TURTLE", difficulty = "expert", the_order = true,
	content_catalog = {
		jokers = { { key = "j_mp_turtle_bean", cost = 6, utility = 24,
			effect = { kind = "decaying_hand_size", initial = 4, amount = 1 } } },
		planets = {}, deck_tools = {},
	},
}, modules)
turtle.jokers = { "j_mp_turtle_bean" }
turtle.joker_state.j_mp_turtle_bean = 4
modules.Simulator.set_ante(turtle, 2)
for remaining = 3, 1, -1 do
	modules.Simulator.play_round(turtle, 1, "Small")
	assert(turtle.joker_state.j_mp_turtle_bean == remaining,
		"Turtle Bean should lose exactly one hand-size bonus after every Blind")
end
modules.Simulator.play_round(turtle, 1, "Small")
assert(#turtle.jokers == 0 and turtle.joker_state.j_mp_turtle_bean == nil,
	"Turtle Bean should expire after its fourth completed Blind")

local melting = modules.Simulator.new({
	seed = "MELTING", difficulty = "expert", the_order = true,
	content_catalog = {
		jokers = {
			{ key = "j_ice_cream", cost = 5, utility = 25,
				effect = { kind = "decaying_chips", initial = 100, amount = 5, destroy_at = 0 } },
			{ key = "j_popcorn", cost = 5, utility = 22,
				effect = { kind = "decaying_mult", initial = 20, amount = 4, destroy_at = 0 } },
		},
		planets = {}, deck_tools = {},
	},
}, modules)
modules.Simulator.set_ante(melting, 2)
melting.jokers = { "j_ice_cream", "j_popcorn" }
melting.joker_state.j_ice_cream = 5
melting.joker_state.j_popcorn = 4
modules.Simulator.play_round(melting, 1, "Small")
assert(#melting.jokers == 0 and melting.joker_state.j_ice_cream == nil
	and melting.joker_state.j_popcorn == nil,
	"Ice Cream and Popcorn should be destroyed at zero instead of occupying dead Joker slots")
local destroyed = {}
for _, decision in ipairs(melting.decisions) do
	if decision.type == "destroy_joker" then destroyed[decision.key] = true end
end
assert(destroyed.j_ice_cream and destroyed.j_popcorn,
	"expiring food Jokers should produce diagnostic destruction decisions")

local economy = modules.Simulator.new({
	seed = "ECONOMY", difficulty = "expert", the_order = true,
	content_catalog = {
		jokers = {}, planets = {},
		deck_tools = { { key = "c_hanged_man", set = "Tarot", cost = 3, utility = 30, effect = "remove", count = 2 } },
	},
}, modules)
economy.money = 10
modules.Simulator.set_ante(economy, 2)
economy.round_history = { { score = 900, target = 800, cleared = true } }
modules.Simulator.visit_shop(economy, { "c_hanged_man" })
modules.Simulator.visit_shop(economy, { "c_hanged_man" })
assert(economy.money >= 5,
	"repeat consumable purchases should not erase a healthy run's first interest tier")

local labelled_pvp = modules.Simulator.new({ seed = "PVP-LABEL", difficulty = "expert", the_order = true }, modules)
modules.Simulator.set_ante(labelled_pvp, 2)
modules.Simulator.play_round(labelled_pvp, nil, "Boss", "PvP")
for _, decision in ipairs(labelled_pvp.decisions) do
	assert(decision.round == "PvP", "prepared PvP actions should not be diagnosed as Boss Blind actions")
end

local celestial = modules.Simulator.new({ seed = "CELESTIAL", difficulty = "expert", the_order = true }, modules)
celestial.money = 26
modules.Simulator.set_ante(celestial, 2)
local celestial_report = modules.Simulator.visit_shop(celestial, { "p_celestial_jumbo_1" })
assert(celestial_report.purchases == 1 and celestial.planets_used == 1,
	"a visible Celestial Pack should deterministically choose and use a supported Planet")

local constellation_fuel = modules.Simulator.new({
	seed = "CONSTELLATION-FUEL", difficulty = "expert", the_order = true,
}, modules)
constellation_fuel.money = 8
constellation_fuel.jokers = { "j_constellation" }
constellation_fuel.joker_state.j_constellation = 1
modules.Simulator.set_ante(constellation_fuel, 2)
local constellation_report = modules.Simulator.visit_shop(constellation_fuel, { "p_celestial_jumbo_1" })
assert(constellation_report.purchases == 1 and constellation_fuel.planets_used == 1
	and constellation_fuel.joker_state.j_constellation > 1,
	"Constellation should permit a valuable Celestial Pack to break the normal cash reserve")

local unsupported_packs = modules.Simulator.new({
	seed = "UNSUPPORTED-PACKS", difficulty = "expert", the_order = true,
	strict_order_content = true,
	content_catalog = {
		jokers = {}, deck_tools = {}, packs = { "p_celestial_normal_1" },
		planets = { { key = "c_mercury", hand = "Pair", cost = 3 } },
		unsupported = { Planet = {
			"c_mod_planet_01", "c_mod_planet_02", "c_mod_planet_03", "c_mod_planet_04",
			"c_mod_planet_05", "c_mod_planet_06", "c_mod_planet_07", "c_mod_planet_08",
			"c_mod_planet_09", "c_mod_planet_10", "c_mod_planet_11", "c_mod_planet_12",
		} },
	},
}, modules)
unsupported_packs.money = 26
modules.Simulator.set_ante(unsupported_packs, 2)
local unsupported_pack_report = modules.Simulator.visit_shop(unsupported_packs, { "p_celestial_normal_1" })
assert(unsupported_pack_report.purchases == 0,
	"hidden Order packs dominated by unsupported content should be risk-adjusted instead of bought at full value")

local buffoon = modules.Simulator.new({ seed = "BUFFOON", difficulty = "expert", the_order = true }, modules)
buffoon.money = 26
modules.Simulator.set_ante(buffoon, 2)
local buffoon_report = modules.Simulator.visit_shop(buffoon, { "p_buffoon_jumbo_1" })
assert(buffoon_report.purchases == 1 and #buffoon.jokers == 1,
	"a visible Buffoon Pack should deterministically choose a supported Joker")

local empty_build = modules.Simulator.new({
	seed = "BUFFOON-FIRST", difficulty = "expert", the_order = true, strict_order_content = true,
}, modules)
empty_build.money = 20
local empty_report = modules.Simulator.visit_shop(empty_build, {
	"p_arcana_normal_1", "p_buffoon_normal_1",
})
local first_pack
for _, decision in ipairs(empty_build.decisions) do
	if decision.type == "buy_pack" then first_pack = first_pack or decision.key end
end
assert(empty_report.purchases >= 1 and first_pack == "p_buffoon_normal_1",
	"an empty Joker build should prioritize a Buffoon Pack over a utility pack")

local negative_pack = modules.Simulator.new({
	seed = "NEGATIVE-PACK", difficulty = "expert", the_order = true, strict_order_content = true,
	weights = { economy_value = 2 },
}, modules)
negative_pack.money = 20
local negative_report = modules.Simulator.visit_shop(negative_pack, { "p_arcana_normal_1" })
assert(negative_report.purchases == 0 and negative_pack.money == 20,
	"a first-look pack with negative contextual utility must be skipped")

local duplicate_packs = modules.Simulator.new({ seed = "DUPLICATE-PACKS", difficulty = "expert", the_order = true }, modules)
duplicate_packs.money = 26
modules.Simulator.set_ante(duplicate_packs, 2)
local duplicate_report = modules.Simulator.visit_shop(duplicate_packs, {
	"p_buffoon_normal_1", "p_buffoon_normal_1",
})
-- a Booster's cards are unknown until it is bought (as in
-- the game), so both packs are paid for and opened; their contents differ.
assert(duplicate_report.purchases == 2 and duplicate_packs.money == 18 and #duplicate_packs.jokers <= 2,
	"duplicate Buffoon keys should be bought unopened and have independent contents")
local duplicate_buys = {}
for _, decision in ipairs(duplicate_packs.decisions) do
	if decision.type == "buy_pack" then duplicate_buys[#duplicate_buys + 1] = decision end
end
assert(#duplicate_buys == 2 and duplicate_buys[1].modeled ~= duplicate_buys[2].modeled,
	"each purchased duplicate Buffoon Pack should reveal its own cards")

local duplicate_jokers = modules.Simulator.new({ seed = "DUPLICATE-JOKERS", difficulty = "expert" }, modules)
duplicate_jokers.money = 20
modules.Simulator.set_ante(duplicate_jokers, 2)
local duplicate_joker_report = modules.Simulator.visit_shop(duplicate_jokers, { "j_square", "j_square" })
assert(duplicate_joker_report.purchases == 1 and #duplicate_jokers.jokers == 1,
	"a duplicate shop offer must not allow two copies of a Joker without Showman")

local showman_jokers = modules.Simulator.new({ seed = "SHOWMAN-JOKERS", difficulty = "expert" }, modules)
showman_jokers.money = 20
showman_jokers.jokers = { "j_ring_master" }
modules.Simulator.set_ante(showman_jokers, 2)
local showman_report = modules.Simulator.visit_shop(showman_jokers, { "j_square", "j_square" })
assert(showman_report.purchases == 2 and #showman_jokers.jokers == 3,
	"an active Showman should allow the bot to acquire duplicate Jokers")

showman_jokers = modules.Simulator.new({
	seed = "VAGABOND", difficulty = "expert", hands_per_round = 1,
	content_catalog = {
		jokers = { { key = "j_vagabond", cost = 6, utility = 24,
			effect = { kind = "low_money_tarot", threshold = 3 } } },
		planets = {}, packs = {}, vouchers = {},
		deck_tools = { { key = "c_strength", set = "Tarot", cost = 3,
			effect = "rank", amount = 1 } },
	},
}, modules)
showman_jokers.jokers, showman_jokers.money = { "j_vagabond" }, 3
modules.Simulator.play_round(showman_jokers, nil, "Small")
assert(#showman_jokers.consumables == 1,
	"Vagabond should generate a Tarot after a hand played at or below its money threshold")

showman_jokers = modules.Simulator.new({
	seed = "CERTIFICATE", difficulty = "expert",
	content_catalog = {
		jokers = { { key = "j_certificate", cost = 6, utility = 25,
			effect = { kind = "round_sealed_card", count = 1 } } },
		planets = {}, deck_tools = {}, packs = {}, vouchers = {},
	},
}, modules)
showman_jokers.jokers = { "j_certificate" }
showman_report = #showman_jokers.deck
modules.Simulator.begin_round(showman_jokers, 100, "Small")
assert(#showman_jokers.deck == showman_report + 1 and showman_jokers.deck[#showman_jokers.deck].seal,
	"Certificate should add one sealed playing card at Blind start")

showman_jokers = modules.Simulator.new({
	seed = "SIXTH-SENSE", difficulty = "expert", hands_per_round = 1,
	content_catalog = {
		jokers = { { key = "j_sixth_sense", cost = 6, utility = 25,
			effect = { kind = "first_six_spectral" } } },
		planets = {}, packs = {}, vouchers = {},
		deck_tools = { { key = "c_aura", set = "Spectral", cost = 4, effect = "edition" } },
	},
}, modules)
showman_jokers.jokers, showman_jokers.deck = { "j_sixth_sense" }, {}
for rank = 2, 9 do
	showman_report = {
		suit = modules.Cards.suits[((rank - 2) % #modules.Cards.suits) + 1],
		rank = ({ 2, 4, 6, 8, 10, 12, 13, 14 })[rank - 1],
	}
	modules.Cards.refresh(showman_report, ":sixth:" .. rank)
	showman_jokers.deck[#showman_jokers.deck + 1] = showman_report
end
modules.Simulator.play_round(showman_jokers, nil, "Small")
assert(#showman_jokers.deck == 7 and #showman_jokers.consumables == 1,
	"Sixth Sense should prioritize, destroy, and convert the first single 6 into a Spectral card")

local arcana = modules.Simulator.new({ seed = "ARCANA", difficulty = "expert", the_order = true }, modules)
arcana.money = 26
modules.Simulator.set_ante(arcana, 2)
local arcana_report = modules.Simulator.visit_shop(arcana, { "p_arcana_jumbo_1" })
assert(arcana_report.purchases == 1 and arcana.tarots_used == 1,
	"a visible Arcana Pack should deterministically choose and apply a supported Tarot")

local telescope = modules.Simulator.new({ seed = "TELESCOPE", difficulty = "expert" }, modules)
telescope.money = 20
telescope.vouchers = { "v_telescope" }
telescope.hand_usage.Pair = 12
telescope.strategy_open = true
local telescope_report = modules.Simulator.visit_shop(telescope, { "p_celestial_normal_1" })
assert(telescope_report.purchases == 1 and telescope.levels.Pair == 2,
	"Telescope should guarantee the most-played hand's Planet in Celestial Packs")

local emperor = modules.Simulator.new({ seed = "EMPEROR", difficulty = "expert" }, modules)
emperor.money = 20
modules.Simulator.set_ante(emperor, 2)
local emperor_report = modules.Simulator.visit_shop(emperor, { "c_emperor" })
assert(emperor_report.purchases == 1 and emperor.tarots_used == 3,
	"Emperor should use itself and two generated supported Tarot cards")

local priestess = modules.Simulator.new({ seed = "PRIESTESS", difficulty = "expert" }, modules)
priestess.money = 20
modules.Simulator.set_ante(priestess, 2)
local priestess_report = modules.Simulator.visit_shop(priestess, { "c_high_priestess" })
assert(priestess_report.purchases == 1 and priestess.tarots_used == 1 and priestess.planets_used == 2,
	"High Priestess should generate and use two supported Planet cards")

local judgement = modules.Simulator.new({ seed = "JUDGEMENT", difficulty = "expert" }, modules)
judgement.money = 20
modules.Simulator.set_ante(judgement, 2)
local judgement_report = modules.Simulator.visit_shop(judgement, { "c_judgement" })
assert(judgement_report.purchases == 1 and judgement.tarots_used == 1 and #judgement.jokers == 1,
	"Judgement should generate and install one supported Joker when a slot is open")

local inventory = modules.Simulator.new({ seed = "CONSUMABLE-INVENTORY", difficulty = "expert", the_order = true }, modules)
inventory.money = 12
modules.Simulator.set_ante(inventory, 2)
local held_report = modules.Simulator.visit_shop(inventory, { "c_hermit", "c_temperance", "c_hermit" })
assert(held_report.purchases == 2 and #inventory.consumables == 2
	and inventory.consumables[1].key == "c_hermit" and inventory.consumables[2].key == "c_temperance",
	"shop consumables should occupy the persistent two-card consumable area instead of firing on purchase")
assert(inventory.tarots_used == 0,
	"held Tarots must not count for Fortune Teller until the bot actually uses them")
local held_snapshot = modules.Simulator.snapshot(inventory)
assert(held_snapshot.consumable_limit == 2 and #held_snapshot.consumables == 2,
	"consumable inventory and capacity should survive snapshots")
inventory.money = 14
modules.Simulator.visit_shop(inventory, {})
assert(#inventory.consumables == 1 and inventory.consumables[1].key == "c_temperance"
	and inventory.tarots_used == 1 and inventory.money == 28,
	"the bot should cash a material Hermit payout at shop start instead of repeatedly spending below its cap")
local used_hermit = false
for _, decision in ipairs(inventory.decisions) do
	if decision.type == "use_consumable" and decision.key == "c_hermit" then used_hermit = true end
end
assert(used_hermit, "later consumable use should be explicit in bot diagnostics")

local replacement_inventory = modules.Simulator.new({
	seed = "CONSUMABLE-REPLACEMENT", difficulty = "expert", the_order = true,
}, modules)
replacement_inventory.money = 12
modules.Simulator.set_ante(replacement_inventory, 2)
modules.Simulator.visit_shop(replacement_inventory, { "c_hermit", "c_temperance" })
replacement_inventory.money = 8
local replacement_report = modules.Simulator.visit_shop(replacement_inventory, { "c_immolate" })
local sold_consumable = false
for _, decision in ipairs(replacement_inventory.decisions) do
	if decision.type == "sell_consumable" and decision.key == "c_temperance" then sold_consumable = true end
end
assert(replacement_report.purchases == 1 and sold_consumable,
	"a materially stronger consumable should be able to replace and sell the weakest full-slot card")

local crystal_ball = modules.Simulator.new({ seed = "CRYSTAL-BALL", difficulty = "expert", the_order = true }, modules)
crystal_ball.money = 20
modules.Simulator.set_ante(crystal_ball, 2)
local crystal_report = modules.Simulator.visit_shop(crystal_ball, { "v_crystal_ball" })
assert(crystal_report.purchases == 1 and crystal_ball.consumable_limit == 3,
	"Crystal Ball should expand the bot's consumable area from two slots to three")

local enhancements_before = 0
for _, card in ipairs(arcana.deck) do if card.enhancement then enhancements_before = enhancements_before + 1 end end
arcana.money = 20
modules.Simulator.visit_shop(arcana, { "c_lovers" })
modules.Simulator.visit_shop(arcana, { "c_lovers" })
local enhancements_after = 0
for _, card in ipairs(arcana.deck) do if card.enhancement then enhancements_after = enhancements_after + 1 end end
assert(enhancements_after >= enhancements_before + 2,
	"repeated enhancement tools should target unenhanced cards instead of overwriting prior work")

-- Tarots act on cards in hand (card.lua use_consumeable), so
-- they are checked on what they change, not on reaching a deck-wide target.
local deck_fix = modules.Simulator.new({ seed = "TARGETED-DECK-FIX", difficulty = "expert", the_order = true }, modules)
deck_fix.money = 50
modules.Simulator.set_ante(deck_fix, 2)
modules.Simulator.visit_shop(deck_fix, { "c_chariot" })
do
local steel = 0
for _, card in ipairs(deck_fix.deck) do if card.enhancement == "m_steel" then steel = steel + 1 end end
assert(steel == 1, "The Chariot should make one card Steel")
local ranks_before = {}
for _, card in ipairs(deck_fix.deck) do ranks_before[card] = card.rank end
modules.Simulator.visit_shop(deck_fix, { "c_strength" })
local raised = 0
for _, card in ipairs(deck_fix.deck) do
	if card.rank ~= ranks_before[card] then
		raised = raised + 1
		assert(card.rank == (ranks_before[card] == 14 and 2 or ranks_before[card] + 1), "Strength raises a rank by one")
	end
end
assert(raised == 2, "Strength should raise two cards")
local hearts_before = 0
for _, card in ipairs(deck_fix.deck) do if card.suit == "Hearts" then hearts_before = hearts_before + 1 end end
modules.Simulator.visit_shop(deck_fix, { "c_sun" })
local hearts_after = 0
for _, card in ipairs(deck_fix.deck) do if card.suit == "Hearts" then hearts_after = hearts_after + 1 end end
assert(hearts_after > hearts_before and hearts_after <= hearts_before + 3, "suit conversion should convert up to three cards")
end

local skipper = modules.Simulator.new({ seed = "SKIPPER", difficulty = "expert", the_order = true }, modules)
modules.Simulator.set_ante(skipper, 1)
skipper.money = 20
skipper.jokers = { "j_joker", "j_jolly", "j_sly", "j_half", "j_abstract" }
assert(next(modules.Simulator.plan_skips(skipper, "reactive")) == nil,
	"simulator should never schedule an Ante 1 skip")
modules.Simulator.set_ante(skipper, 2)
local no_skips = modules.Simulator.plan_skips(skipper, "disabled")
assert(next(no_skips) == nil and skipper.skips == 0,
	"disabled Blind skipping should leave the run and timeline untouched")
assert(modules.Simulator.record_pvp_outcome(skipper, 1500, 900),
	"a score at least 50% above the player should be remembered as dominant")
assert(not modules.Simulator.record_pvp_outcome(skipper, 1000, 900),
	"a narrow PvP result should not enable pressure skipping")
skipper.skip_plans[2] = nil
local unsupported_tag_plan = modules.Simulator.plan_skips(skipper, "reactive", { Small = "tag_mp_gambling_sandbox" })
assert(not unsupported_tag_plan.Small,
	"Reactive simulation must not skip for a modded Tag reward it cannot apply")

local pressure_skipper = modules.Simulator.new({ seed = "PRESSURE-SKIPPER", difficulty = "expert" }, modules)
modules.Simulator.set_ante(pressure_skipper, 4)
pressure_skipper.money = 11
pressure_skipper.jokers = { "j_joker", "j_jolly", "j_sly", "j_half", "j_abstract" }
pressure_skipper.previous_pvp_dominant = true
pressure_skipper.Policy = setmetatable({ should_skip_blind = function() return true end }, { __index = pressure_skipper.Policy })
local pressure_plan = modules.Simulator.plan_skips(pressure_skipper, "reactive", {
	Small = "tag_mp_gambling_sandbox", Big = "tag_economy",
})
assert(not pressure_plan.Small and pressure_plan.Big and pressure_skipper.skips == 1,
	"Reactive pressure must choose the supported reward instead of chaining both Blind skips")

local tagger = modules.Simulator.new({
	seed = "TAGGER", difficulty = "expert", the_order = true,
	content_catalog = {
		jokers = {
			{ key = "j_common_test", cost = 2, utility = 16, rarity = 1, effect = { kind = "flat_mult", amount = 4 } },
			{ key = "j_rare_test", cost = 8, utility = 40, rarity = 3, effect = { kind = "flat_xmult", amount = 3 } },
		}, planets = {}, deck_tools = {},
	},
}, modules)
modules.Simulator.set_ante(tagger, 2)
tagger.money = 20
tagger.jokers = { "j_common_test", "a", "b", "c", "d" }
tagger.joker_limit = 5
modules.Simulator.plan_skips(tagger, "unforgivable", { Small = "tag_rare" })
modules.Simulator.visit_shop(tagger, {})
local owns_rare = false
for _, key in ipairs(tagger.jokers) do if key == "j_rare_test" then owns_rare = true end end
assert(owns_rare and #tagger.jokers == 5,
	"a Rare Tag skip should create a free supported Rare Joker offer and replace a weaker Joker")

local negative = modules.Simulator.new({
	seed = "NEGATIVE-TAG", difficulty = "expert", the_order = true,
	content_catalog = {
		jokers = {
			{ key = "j_negative_test", cost = 4, utility = 20, rarity = 1,
				effect = { kind = "flat_mult", amount = 8 } },
		}, planets = {}, deck_tools = {},
	},
}, modules)
modules.Simulator.set_ante(negative, 2)
negative.money = 20
negative.jokers = { "a", "b", "c", "d", "e" }
modules.Simulator.plan_skips(negative, "negative_only", { Small = "tag_negative" })
-- the Negative Tag makes the next shop Joker Negative and free
-- (tag.lua store_joker_modify) instead of adding a Joker of its own.
local negative_report = modules.Simulator.visit_shop(negative, { "j_negative_test" })
assert(#negative.jokers == 6 and negative.joker_limit == 6
	and negative.joker_editions.j_negative_test == "negative",
	"Negative Tag should add a slot-neutral Negative Joker even when the build is full")
assert(negative_report.tag_rewards[1] == "tag_negative:j_negative_test",
	"Negative Tag reward should be explicit in shop diagnostics")
local negative_snapshot = modules.Simulator.snapshot(negative)
assert(negative_snapshot.joker_editions.j_negative_test == "negative",
	"Negative Joker editions must survive snapshots used by result inspection")

local strict_order = modules.Simulator.new({
	seed = "STRICT-ORDER", difficulty = "expert", the_order = true, strict_order_content = true,
	content_catalog = {
		jokers = {
			{ key = "j_visible", cost = 4, utility = 1, rarity = 1,
				effect = { kind = "flat_mult", amount = 10 } },
		},
		planets = {}, deck_tools = {},
	},
}, modules)
strict_order.money = 20
strict_order.jokers = { "a", "b" }
modules.Simulator.set_ante(strict_order, 2)
modules.Simulator.plan_skips(strict_order, "negative_only", { Small = "tag_negative" })
strict_order.money = 0
local strict_keys = { "j_visible", "p_buffoon_normal_1" }
strict_keys._metadata = { {}, {} }
local strict_report = modules.Simulator.visit_shop(strict_order, strict_keys)
assert(#strict_order.jokers == 3 and strict_order.jokers[3] == "j_visible"
	and strict_order.joker_editions.j_visible == "negative" and strict_order.money == 0,
	"a live Order Negative Tag must make the next observed base-edition Joker free and slot-neutral")
assert(strict_report.tag_rewards[1] == "tag_negative:j_visible",
	"strict Order diagnostics should identify the observed Joker modified by a tag")
assert(#strict_report.supported_keys == 2,
	"strict live Order runs should recognize privately generatable packs without opening unpaid ones")

local forced_negative = modules.Simulator.new({
	seed = "FORCED-NEGATIVE", difficulty = "expert", the_order = true, strict_order_content = true,
	content_catalog = {
		jokers = {
			{ key = "j_weak_negative", cost = 4, utility = 1, rarity = 1,
				effect = { kind = "flat_mult", amount = 1 } },
			{ key = "j_strong_offer", cost = 4, utility = 40, rarity = 1,
				effect = { kind = "flat_xmult", amount = 3 } },
		}, planets = {}, deck_tools = {},
	},
}, modules)
forced_negative.money = 20
forced_negative.jokers = { "a", "b" }
modules.Simulator.set_ante(forced_negative, 2)
modules.Simulator.plan_skips(forced_negative, "negative_only", { Small = "tag_negative" })
local forced_keys = { "j_weak_negative", "j_strong_offer" }
forced_keys._metadata = { {}, {} }
local forced_report = modules.Simulator.visit_shop(forced_negative, forced_keys)
assert(forced_report.purchases == 2 and forced_negative.joker_editions.j_weak_negative == "negative",
	"a free Negative Tag reward must be taken before stronger paid offers: purchases="
		.. tostring(forced_report.purchases) .. ", edition="
		.. tostring(forced_negative.joker_editions.j_weak_negative))

local learned_standard = modules.Simulator.new({
	seed = "LEARNED-STANDARD", difficulty = "expert", the_order = true, strict_order_content = true,
}, modules)
learned_standard.money = 20
learned_standard.jokers = { "j_joker", "j_jolly", "j_sly", "j_half", "j_abstract" }
learned_standard.pack_history.standard = { opened = 2, picked = 0 }
local learned_report = modules.Simulator.visit_shop(learned_standard, { "p_standard_normal_1" })
assert(learned_report.purchases == 0 and learned_standard.money == 20,
	"repeated empty Standard Packs should lower later expected value below the purchase floor")

local grabber = modules.Simulator.new({ seed = "GRABBER", difficulty = "expert", the_order = true }, modules)
modules.Simulator.set_ante(grabber, 2)
grabber.money = 20
local grabber_report = modules.Simulator.visit_shop(grabber, { "v_grabber" })
assert(grabber_report.purchases == 1 and grabber.vouchers[1] == "v_grabber",
	"an observed Grabber voucher should be bought and retained by the headless run")
local grabber_round = modules.Simulator.play_round(grabber, 1e20, "Small")
assert(grabber_round.hands_available == 5,
	"Grabber should permanently add one hand to every later Blind")

local voucher_state = modules.Simulator.new({ seed = "MORE-VOUCHERS", difficulty = "expert", the_order = true }, modules)
voucher_state.money = 100
local voucher_report = modules.Simulator.visit_shop(voucher_state,
	{ "v_overstock_norm", "v_paint_brush", "v_seed_money" })
assert(voucher_report.purchases == 2 and voucher_state.shop_slots == 3 and voucher_state.hand_size_bonus == 1,
	"Overstock and Paint Brush should expand later shops and draws")
modules.Simulator.visit_shop(voucher_state, { "v_seed_money" })
assert(voucher_state.interest_cap == 10, "Seed Money should raise the interest cap from $5 to $10")

local economy_vouchers = modules.Simulator.new({ seed = "ECONOMY-VOUCHERS", difficulty = "expert", the_order = true }, modules)
economy_vouchers.money = 100
modules.Simulator.visit_shop(economy_vouchers, { "v_reroll_surplus" })
assert(economy_vouchers.reroll_discount == 2
	and modules.Simulator.next_reroll_cost(economy_vouchers, 0) == 3
	and modules.Simulator.next_reroll_cost(economy_vouchers, 2) == 5,
	"Reroll Surplus should reduce every reroll cost by $2")
modules.Simulator.visit_shop(economy_vouchers, { "v_clearance_sale" })
local money_before_discounted_joker = economy_vouchers.money
local discounted_report = modules.Simulator.visit_shop(economy_vouchers, { "j_joker" })
assert(discounted_report.purchases == 1
	and economy_vouchers.money == money_before_discounted_joker - 1,
	"Clearance Sale should apply its 25% floor-rounded discount to shop cards")
local discounted_pack = modules.Simulator.visit_shop(economy_vouchers, { "p_arcana_normal_1" })
assert(discounted_pack.evaluated:find("p_arcana_normal_1~pack~3~", 1, true),
	"Clearance Sale should discount a $4 Booster Pack to $3")
do
modules.Simulator.visit_shop(economy_vouchers, { "v_overstock_plus", "v_liquidation" })
assert(economy_vouchers.shop_slots == 3 and economy_vouchers.shop_discount == 50,
	"Overstock Plus and Liquidation should apply their upgraded shop effects")
local liquidated_pack = modules.Simulator.visit_shop(economy_vouchers, { "p_arcana_normal_1" })
assert(liquidated_pack.evaluated:find("p_arcana_normal_1~pack~2~", 1, true),
	"Liquidation should discount a $4 Booster Pack to $2")
end

do
local fool = modules.Simulator.new({ seed = "FOOL", difficulty = "expert", the_order = true }, modules)
fool.money = 100
modules.Simulator.visit_shop(fool, { "c_heirophant" })
local enhanced_before_fool = 0
for _, playing_card in ipairs(fool.deck) do
	if playing_card.enhancement == "m_bonus" then enhanced_before_fool = enhanced_before_fool + 1 end
end
local fool_report = modules.Simulator.visit_shop(fool, { "c_fool" })
local enhanced_after_fool = 0
for _, playing_card in ipairs(fool.deck) do
	if playing_card.enhancement == "m_bonus" then enhanced_after_fool = enhanced_after_fool + 1 end
end
assert(fool_report.purchases == 1 and enhanced_after_fool == enhanced_before_fool + 2,
	"The Fool should repeat the last used Tarot effect")
end
do
local fixer = modules.Simulator.new({ seed = "DECK-FIX-BUDGET", difficulty = "expert", the_order = true }, modules)
modules.Simulator.set_ante(fixer, 4)
fixer.money = 100
local fixer_report = modules.Simulator.visit_shop(fixer,
	{ "v_overstock_norm", "v_paint_brush", "c_hanged_man", "c_strength" })
assert(fixer_report.purchases == 4 and #fixer.vouchers == 2 and #fixer.deck == 50,
	"a shop should allow two permanent purchases plus two immediate deck-fixing purchases")
assert(fixer.deck_fix_rank == 13 and fixer.deck_fix_suit == "Hearts",
	"the first structural Tarot should lock a stable deck-fixing target")
fixer.jokers = { "j_arrowhead" }
local locked_rank, locked_suit = modules.Strategy.deck_fix_target(fixer)
assert(locked_rank == 13 and locked_suit == "Hearts",
	"a later Joker must not discard an established deck-fixing target")
end
do
local discards_before_wasteful = economy_vouchers.discards_per_round
modules.Simulator.visit_shop(economy_vouchers, { "v_wasteful" })
modules.Simulator.visit_shop(economy_vouchers, { "v_hone" })
assert(economy_vouchers.discards_per_round == discards_before_wasteful + 1
	and economy_vouchers.edition_rate == 2,
	"Wasteful should add one discard and Hone should double the private edition rate")

local credit = modules.Simulator.new({ seed = "CREDIT", difficulty = "expert", the_order = true }, modules)
credit.money = 0
credit.jokers = { "j_credit_card" }
local credit_report = modules.Simulator.visit_shop(credit, { "j_joker" })
assert(credit_report.purchases == 1 and credit.money == -2,
	"Credit Card should permit a strong shop purchase below $0")
credit.money = -19
local credit_limit_report = modules.Simulator.visit_shop(credit, { "j_stuntman" })
assert(credit_limit_report.purchases == 0 and credit.money == -19,
	"Credit Card must reject purchases that would exceed its $20 debt limit")

local hiker = modules.Simulator.new({ seed = "HIKER", difficulty = "expert" }, modules)
hiker.jokers = { "j_hiker" }
modules.Simulator.play_round(hiker, 1, "Small")
local hiked
for _, card in ipairs(hiker.deck) do if (card.perma_bonus or 0) > 0 then hiked = card; break end end
assert(hiked and hiked.perma_bonus == 5,
	"Hiker should permanently add +5 Chips to each scoring card after it scores")
local hiked_bonus = hiked.perma_bonus
modules.Cards.refresh(hiked, ":hiker-test")
assert(hiked.chips == modules.Cards.chips(hiked.rank) + hiked_bonus,
	"rank or suit refreshes must preserve Hiker's permanent card Chips")
end

local merchant = modules.Simulator.new({ seed = "PLANET-MERCHANT", difficulty = "expert", the_order = true }, modules)
merchant.money = 20
merchant.jokers = { "j_constellation" }
merchant.joker_effects.j_constellation = { kind = "planet_scaling_xmult", initial = 1, amount = 0.1 }
local merchant_report = modules.Simulator.visit_shop(merchant, { "v_planet_merchant" })
-- Planet rate x2.4 (4 -> 9.6, game.lua v_planet_merchant extra = 9.6/4).
assert(merchant_report.purchases == 1 and math.abs(merchant.planet_rate - 2.4) < 1e-9,
	"Planet Merchant should be supported and increase Planet frequency for Constellation")

local income_jokers = modules.Simulator.new({ seed = "MORE-INCOME", difficulty = "expert", the_order = true }, modules)
income_jokers.money = 50
income_jokers.round_history = { { score = 400, target = 300, cleared = true, discards_used = 0 } }
local income_report = modules.Simulator.visit_shop(income_jokers, { "j_golden", "j_delayed_grat" })
assert(income_report.purchases == 2, "Golden Joker and Delayed Gratification should be supported purchases")
income_jokers.money = 0
modules.Simulator.award_blind(income_jokers, "Small", {
	cleared = true, hands_left = 0, discards_left = 3, discards_available = 3,
})
assert(income_jokers.money == 13,
	"Golden Joker and untouched Delayed Gratification should pay $4 and $6 after the Blind")

local economy_jokers = modules.Simulator.new({ seed = "ECONOMY-JOKERS", difficulty = "expert", the_order = true }, modules)
modules.Simulator.set_ante(economy_jokers, 2)
economy_jokers.money = 50
local economy_report = modules.Simulator.visit_shop(economy_jokers, { "j_todo_list", "j_cloud_9" })
assert(economy_report.purchases == 2 and #economy_jokers.jokers == 2,
	"To Do List and Cloud 9 should be supported Order shop purchases")
local nines = 0
for _, card in ipairs(economy_jokers.deck) do if card.rank == 9 then nines = nines + 1 end end
local before_cloud = economy_jokers.money
modules.Simulator.award_blind(economy_jokers, "Small", { cleared = true, hands_left = 0 })
assert(economy_jokers.money == before_cloud + 3 + 5 + nines,
	"Cloud 9 should pay once per Nine alongside the normal Blind payout and capped interest")
modules.Simulator.play_round(economy_jokers, 1, "Small")
local todo_target = economy_jokers.joker_state.j_todo_list
assert(type(todo_target) == "string" and modules.Evaluator.hands[todo_target],
	"To Do List should select a supported deterministic poker-hand target each round")

local burglar = modules.Simulator.new({ seed = "BURGLAR", difficulty = "expert", the_order = true }, modules)
modules.Simulator.set_ante(burglar, 2)
burglar.money = 20
modules.Simulator.visit_shop(burglar, { "j_burglar" })
local burglar_round = modules.Simulator.play_round(burglar, 1e20, "Small")
assert(burglar_round.hands_available == 7 and burglar_round.discards_available == 0,
	"Burglar should add three hands and remove every discard for the selected Blind")

local merry = modules.Simulator.new({ seed = "MERRY", difficulty = "expert", the_order = true }, modules)
modules.Simulator.set_ante(merry, 2)
merry.money = 20
modules.Simulator.visit_shop(merry, { "j_merry_andy" })
local merry_round = modules.Simulator.play_round(merry, 1e20, "Small")
assert(merry_round.hands_available == 4 and merry_round.discards_available == 7,
	"Merry Andy should add three discards to the Red Deck's four without changing hand count")

local investor = modules.Simulator.new({ seed = "INVEST", difficulty = "expert", the_order = true }, modules)
modules.Simulator.set_ante(investor, 2)
investor.money = 10
investor.jokers = { "j_joker", "j_jolly" }
modules.Simulator.plan_skips(investor, "reactive", { Small = "tag_investment" })
local before_investment = investor.money
modules.Simulator.award_blind(investor, "Boss", { cleared = true, hands_left = 0 })
assert(investor.money >= before_investment + 30,
	"Investment Tag should pay its $25 after the next cleared Boss/PvP Blind")

local reckless = modules.Simulator.new({ seed = "RECKLESS", difficulty = "easy", the_order = true }, modules)
modules.Simulator.set_ante(reckless, 1)
local reckless_plan = modules.Simulator.plan_skips(reckless, "unlimited_unforgivable", {
	Small = "tag_boss", Big = "tag_garbage",
})
assert(reckless_plan.Small and reckless_plan.Big and reckless.skips == 2,
	"Unlimited Unforgivable must schedule both Ante 1 skips without economy or Jokers")

local stable_build = modules.Simulator.new({
	seed = "STABLE-BUILD", difficulty = "expert", the_order = true,
	content_catalog = {
		jokers = {
			{ key = "j_even_steven", cost = 4, utility = 23,
				effect = { kind = "rank_mult", ranks = { 2, 4, 6, 8, 10 }, amount = 4 } },
			{ key = "j_ice_cream", cost = 5, utility = 25,
				effect = { kind = "decaying_chips", initial = 100, amount = 5, destroy_at = 0 } },
			{ key = "j_a", cost = 8, utility = 35 }, { key = "j_b", cost = 8, utility = 35 },
			{ key = "j_c", cost = 8, utility = 35 }, { key = "j_d", cost = 8, utility = 35 },
		}, planets = {}, deck_tools = {},
	},
}, modules)
modules.Simulator.set_ante(stable_build, 5)
stable_build.money = 100
stable_build.jokers = { "j_even_steven", "j_a", "j_b", "j_c", "j_d" }
local stable_report = modules.Simulator.visit_shop(stable_build, { "j_ice_cream" })
assert(stable_report.purchases == 0 and stable_build.jokers[1] == "j_even_steven",
	"a marginal temporary Joker must not displace an established working Joker")

local suit_build = modules.Simulator.new({ seed = "SUIT-BUILD", difficulty = "expert" }, modules)
for index, card in ipairs(suit_build.deck) do if index <= 30 then card.suit = "Hearts" end end
suit_build.jokers = { "j_onyx_agate", "j_arrowhead" }
assert(suit_build.joker_effects.j_arrowhead and suit_build.joker_effects.j_arrowhead.suit == "Spades",
	"Arrowhead test fixture should expose its suit effect")
local _, preferred_suit = modules.Strategy.deck_fix_target(suit_build)
assert(preferred_suit == "Spades",
	"Arrowhead and Onyx Agate should redirect even a Heart-heavy deck toward the stronger Joker suit: " .. tostring(preferred_suit))

local stepped = modules.Simulator.new({ seed = "STEPPED-PVP", difficulty = "expert" }, modules)
local pvp_session = modules.Simulator.begin_round(stepped, nil, "Boss", "PvP")
assert(#stepped.decisions == 0, "starting PvP must not precompute every hand")
local first_pvp_hand = modules.Simulator.step_round(pvp_session)
assert(first_pvp_hand and #pvp_session.hands == 1 and not pvp_session.finished,
	"a live PvP step should resolve exactly one played hand")
stepped.levels["Pair"] = 4
assert(modules.Simulator.apply_pvp_effect(stepped, "asteroid") and stepped.levels["Pair"] == 3,
	"an incoming Asteroid must alter the live bot run before its next hand")
local money_before_gambling = stepped.money
assert(modules.Simulator.apply_pvp_effect(stepped, "letsGoGamblingNemesis")
	and stepped.money == money_before_gambling + 10,
	"Let's Go Gambling's nemesis payout must reach the bot's persistent economy")
modules.Simulator.step_round(pvp_session)
assert(#pvp_session.hands == 2, "the second PvP hand should only exist after a second live step")
modules.Simulator.finish_round(pvp_session)

local loyalty = modules.Simulator.new({
	seed = "LOYALTY-COUNTDOWN", difficulty = "expert", hands_per_round = 6,
}, modules)
loyalty.jokers = { "j_loyalty_card" }
loyalty.joker_state.j_loyalty_card = 6
loyalty.hands_played = 17
local loyalty_session = modules.Simulator.begin_round(loyalty, 1e12, "Small")
for remaining = 5, 1, -1 do
	assert(modules.Simulator.step_round(loyalty_session), "Loyalty countdown fixture should play a hand")
	assert(loyalty.joker_state.j_loyalty_card == remaining,
		"Loyalty Card should count its own hands independently of the run total")
end
assert(modules.Simulator.step_round(loyalty_session), "Loyalty Card should reach its activation hand")
assert(loyalty.joker_state.j_loyalty_card == 6,
	"Loyalty Card should reset its countdown after its activation hand")
modules.Simulator.finish_round(loyalty_session)

local extinction_found = false
for attempt = 1, 100 do
	local food = modules.Simulator.new({ seed = "MICHEL-" .. attempt, difficulty = "normal" }, modules)
	food.jokers = { "j_gros_michel" }
	food.joker_state.j_gros_michel = 0
	modules.Simulator.play_round(food, 1, "Small")
	if food.pool_flags.gros_michel_extinct then
		extinction_found = true
		assert(not has_value(food.jokers, "j_gros_michel"), "an extinct Gros Michel must be destroyed")
		food.money = 100
		modules.Simulator.visit_shop(food, { "j_cavendish" })
		assert(has_value(food.jokers, "j_cavendish"),
			"Cavendish should enter the bot pool after Gros Michel becomes extinct")
		break
	end
end
assert(extinction_found, "Gros Michel must have a deterministic 1-in-6 end-of-round extinction path")

print("simulator_spec: ok")
