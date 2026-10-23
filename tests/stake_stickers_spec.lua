-- Stake stickers (Eternal, Perishable, Rental), checked against the game's
-- source: game.lua start_run (stake >= 4 / 7 / 8) and P_CENTERS
-- (eternal_compat / perishable_compat), common_events.lua create_card (the
-- sticker rolls), card.lua (set_eternal, set_perishable, set_rental, set_cost,
-- can_sell_card, calculate_rental, calculate_perishable, set_debuff, Ankh, Hex,
-- Madness, Ceremonial Dagger), state_events.lua end_round.
local base = {
	PRNG = dofile("bot/prng.lua"),
	Cards = dofile("bot/cards.lua"),
	Content = dofile("bot/content.lua"),
	Evaluator = dofile("bot/evaluator.lua"),
	Strategy = dofile("bot/strategy.lua"),
	Policy = dofile("bot/policy.lua"),
	Simulator = dofile("bot/simulator.lua"),
}
base = dofile("bot/expert.lua").modules(base)   -- MultiBots' Expert decides
local Simulator = base.Simulator
local R = Simulator.rules

-- the Expert with some decisions replaced
local function with_hooks(hooks)
	local modules = {}
	for key, value in pairs(base) do modules[key] = value end
	modules.Policy = setmetatable(hooks, { __index = base.Policy })
	return modules
end

local function new_state(modules, seed, jokers, options)
	local state = Simulator.new({
		seed = seed, difficulty = "expert", the_order = true,
		stake = options and options.stake, sticker_rules = options and options.sticker_rules,
		strict_order_content = options and options.strict_order_content,
	}, modules)
	-- Ceremonial Dagger and Madness are in live catalogs only (runtime_only)
	local runtime = base.Content.build({ Joker = {
		{ key = "j_ceremonial", cost = 6, rarity = 2 }, { key = "j_madness", cost = 7, rarity = 2 },
	} }, {}, {})
	for _, joker in ipairs(runtime.jokers) do
		state.joker_pool[#state.joker_pool + 1] = joker
		state.joker_effects[joker.key] = joker.effect
	end
	state.jokers = jokers or {}
	for _, key in ipairs(state.jokers) do state.joker_state[key] = state.joker_state[key] or 0 end
	return state
end

local function count(list, wanted)
	local total = 0
	for _, value in ipairs(list) do if value == wanted then total = total + 1 end end
	return total
end

---------------------------------------------------------------------------
-- 1. Which Stake enables which sticker.
---------------------------------------------------------------------------

local white, black, orange, gold = Simulator.sticker_rules(1), Simulator.sticker_rules(4),
	Simulator.sticker_rules(7), Simulator.sticker_rules(8)
assert(not white.eternal and not white.perishable and not white.rental, "White Stake: no stickers")
assert(Simulator.sticker_rules(3).eternal == false, "Green Stake: no Eternal yet")
assert(black.eternal and not black.perishable and not black.rental, "Black Stake: Eternal")
assert(orange.eternal and orange.perishable and not orange.rental, "Orange Stake: Perishable too")
assert(gold.eternal and gold.perishable and gold.rental, "Gold Stake: Rental too")
local run_rules = new_state(base, "RULES", {}, { stake = 2, sticker_rules = { rental = true } })
assert(R.sticker_rules(run_rules).rental and not R.sticker_rules(run_rules).eternal,
	"options.sticker_rules (the live game's modifiers) win over the Stake number")

---------------------------------------------------------------------------
-- 2. Shop Jokers: the rolls, their shares and the compatibility rules.
---------------------------------------------------------------------------

-- Every offered Joker of many headless shops, at a Stake.
local function shop_jokers(stake, visits)
	local seen = {}
	local modules = with_hooks({
		shop_step = function(_, ctx)
			for _, offer in ipairs(ctx.offers) do
				if offer.type == "joker" and not offer.tag_reward then seen[#seen + 1] = offer end
			end
			return 1
		end,
	})
	local state = new_state(modules, "STICKER-SHOP-" .. stake, {}, { stake = stake })
	for visit = 1, visits do
		state.round = visit
		Simulator.visit_shop(state)
	end
	return seen
end

local function shares(offers)
	local eternal, eternal_compat, perishable, perishable_compat, rental = 0, 0, 0, 0, 0
	for _, offer in ipairs(offers) do
		local key = offer.key
		local can_eternal = key ~= "j_gros_michel" and key ~= "j_ice_cream" and key ~= "j_cavendish"
			and key ~= "j_luchador" and key ~= "j_turtle_bean" and key ~= "j_diet_cola" and key ~= "j_popcorn"
			and key ~= "j_ramen" and key ~= "j_selzer" and key ~= "j_mr_bones" and key ~= "j_invisible"
		local can_perish = key ~= "j_ceremonial" and key ~= "j_ride_the_bus" and key ~= "j_runner"
			and key ~= "j_constellation" and key ~= "j_green_joker" and key ~= "j_red_card"
			and key ~= "j_madness" and key ~= "j_square" and key ~= "j_vampire" and key ~= "j_hologram"
			and key ~= "j_rocket" and key ~= "j_obelisk" and key ~= "j_lucky_cat" and key ~= "j_flash"
			and key ~= "j_trousers" and key ~= "j_castle" and key ~= "j_glass" and key ~= "j_wee"
		assert(not (offer.eternal and offer.perishable), "never Eternal and Perishable: " .. key)
		assert(can_eternal or not offer.eternal, "not eternal_compat: " .. key)
		assert(can_perish or not offer.perishable, "not perishable_compat: " .. key)
		if offer.rental then
			assert(offer.cost == 1 or offer.cost == 0, "a Rental Joker costs $1: " .. key .. " " .. tostring(offer.cost))
		end
		if can_eternal then eternal_compat = eternal_compat + 1 end
		if can_perish then perishable_compat = perishable_compat + 1 end
		if offer.eternal then eternal = eternal + 1 end
		if offer.perishable then perishable = perishable + 1 end
		if offer.rental then rental = rental + 1 end
	end
	return eternal / math.max(1, eternal_compat), perishable / math.max(1, perishable_compat),
		rental / math.max(1, #offers)
end

local low = shop_jokers(1, 300)
local e, p, r = shares(low)
assert(#low > 100 and e == 0 and p == 0 and r == 0, "White Stake shops have no stickers")

local high = shop_jokers(8, 1500)
e, p, r = shares(high)
assert(#high > 1000, "enough shop Jokers: " .. #high)
-- poll > 0.7: Eternal 30%; 0.4 < poll <= 0.7: Perishable 30%; Rental 30%.
assert(math.abs(e - 0.3) < 0.04 and math.abs(p - 0.3) < 0.04 and math.abs(r - 0.3) < 0.04,
	string.format("Gold Stake sticker shares: eternal %.3f perishable %.3f rental %.3f", e, p, r))

local black_offers = shop_jokers(4, 600)
e, p, r = shares(black_offers)
assert(math.abs(e - 0.3) < 0.05 and p == 0 and r == 0,
	string.format("Black Stake: Eternal only (%.3f %.3f %.3f)", e, p, r))

-- A live Order shop's rolls (bot/order.lua, per card) are applied with the
-- compatibility rules; a Rental Joker costs $1, also under Liquidation.
local offered = {}
local order_modules = with_hooks({
	shop_step = function(_, ctx)
		for _, offer in ipairs(ctx.offers) do offered[offer.key] = offer end
		return 1
	end,
})
local live = new_state(order_modules, "STICKER-ORDER", {}, { stake = 8, strict_order_content = true })
live.shop_discount = 50
local report = Simulator.visit_shop(live, {
	"j_gros_michel", "j_ride_the_bus", "j_joker", "j_jolly",
	_metadata = {
		{ eternal = true }, { perishable = true, rental = true },
		{ eternal = true, perishable = true, rental = true }, { perishable = true, edition = "polychrome" },
	},
})
assert(not offered.j_gros_michel.eternal, "Gros Michel cannot be Eternal")
assert(not offered.j_ride_the_bus.perishable and offered.j_ride_the_bus.rental and offered.j_ride_the_bus.cost == 1,
	"Ride the Bus cannot be Perishable; Rental costs $1 under Liquidation too")
assert(offered.j_joker.eternal and not offered.j_joker.perishable and offered.j_joker.rental
	and offered.j_joker.cost == 1, "Eternal wins over Perishable; Rental at $1")
assert(offered.j_jolly.perishable and offered.j_jolly.edition == "polychrome", "Perishable with its edition")
assert(report.evaluated:find("j_joker~joker~1~none~eternal+rental", 1, true),
	"the shop log shows the stickers: " .. report.evaluated)

---------------------------------------------------------------------------
-- 3. Rental: $3 every round end (below $0 too), sells for $1.
---------------------------------------------------------------------------

local function end_round(state, round_name)
	local session = Simulator.begin_round(state, nil, round_name or "Small")
	return Simulator.finish_round(session)
end

-- a Joker bought from an offer (shop_step "buy" of offer 1)
local function buy(state, key, rolls)
	local modules = state.Policy
	local bought = false
	state.Policy = setmetatable({
		shop_step = function(_, ctx)
			if bought then return 1 end
			for position, action in ipairs(ctx.actions) do
				if action.type == "buy" and action.key == key then bought = true; return position end
			end
			return 1
		end,
	}, { __index = modules })
	Simulator.visit_shop(state, { key, _metadata = { rolls } })
	state.Policy = modules
	return bought
end

local rental = new_state(base, "STICKER-RENTAL", {}, { stake = 8, strict_order_content = true })
rental.money = 1
assert(buy(rental, "j_jolly", { rental = true }), "a $1 Rental Joker is affordable with $1")
assert(rental.money == 0 and rental.joker_stickers.j_jolly.rental, "the Rental Joker cost $1")
assert(R.joker_sell_value(rental, "j_jolly") == 1, "a Rental Joker sells for $1")
end_round(rental)
assert(rental.money == -3, "Rental costs $3 at the end of the round, below $0 too: " .. rental.money)
local paid = 0
for _, decision in ipairs(rental.decisions) do
	if decision.type == "pay_rental" and decision.key == "j_jolly" then paid = paid + decision.value end
end
assert(paid == 3, "the rent is logged")
-- Rent is paid before cash out: interest counts the money left.
rental.money = 13
end_round(rental)
assert(rental.money == 10)
Simulator.award_blind(rental, "Small", { cleared = true, hands_left = 0, discards_left = 0 })
assert(rental.money == 10 + 2 + 0 + 0, "interest after rent: " .. rental.money)

---------------------------------------------------------------------------
-- 4. Perishable: debuffed after 5 rounds; a debuffed Joker does nothing.
---------------------------------------------------------------------------

local perish = new_state(base, "STICKER-PERISH", {}, { stake = 8, strict_order_content = true })
perish.money = 20
assert(buy(perish, "j_joker", { perishable = true }))
assert(buy(perish, "j_credit_card", { perishable = true }))
perish.joker_editions.j_joker = "holo"
assert(perish.joker_stickers.j_joker.perish_tally == 5, "a Perishable Joker starts with 5 rounds")
for round = 1, 4 do end_round(perish) end
assert(perish.joker_stickers.j_joker.perish_tally == 1 and not R.joker_debuffed(perish, "j_joker"),
	"4 rounds: 1 left, still working")
assert(R.debt_limit(perish) == 20, "Credit Card still allows debt")
local snapshot = Simulator.snapshot(perish)
assert(snapshot.joker_stickers.j_joker.perish_tally == 1, "snapshots keep the tally")
end_round(perish)
assert(perish.joker_stickers.j_joker.perish_tally == 0 and R.joker_debuffed(perish, "j_joker"),
	"after the 5th round the Joker is debuffed")
assert(perish.joker_effects.j_joker == nil and R.debt_limit(perish) == 0,
	"a debuffed Joker has no effect (remove_from_deck: no more debt)")
assert(#perish.jokers == 2 and R.joker_sell_value(perish, "j_joker") >= 1, "it keeps its slot and sell value")
local debuffs = 0
for _, decision in ipairs(perish.decisions) do
	if decision.type == "debuff_joker" then debuffs = debuffs + 1 end
end
assert(debuffs == 2, "both Perishable Jokers were debuffed in the log")
local last = perish.decisions[#perish.decisions]
local logged = last.snapshot:match("joker_stickers:([^|]*)") or ""
assert(logged:find("j_joker:perishable0", 1, true) and logged:find("j_credit_card:perishable0", 1, true),
	"the decision snapshot shows the tallies: " .. last.snapshot)
end_round(perish)
assert(perish.joker_stickers.j_joker.perish_tally == 0, "the tally stops at 0")

-- Scoring: +4 Mult and Holo +10 Mult only while not debuffed.
local function first_card_mult(state)
	local mult
	state.Policy = setmetatable({
		choose_turn = function(args)
			local result = args.evaluate({ args.hand[1] }, args.hand)
			mult = mult or result.mult
			return { type = "play", indices = { 1 }, result = result }
		end,
	}, { __index = base.Policy })
	local session = Simulator.begin_round(state, nil, "Small")
	state.hand = { { rank = 9, suit = "Spades", chips = 9, id = "S9" } }
	Simulator.step_round(session)
	state.Policy = base.Policy
	return mult
end
local working = new_state(base, "STICKER-WORKING", { "j_joker" })
working.joker_editions.j_joker = "holo"
assert(first_card_mult(working) == 1 + 4 + 10, "Joker +4 and Holo +10")
local dead = new_state(base, "STICKER-DEAD", { "j_joker" })
dead.joker_editions.j_joker = "holo"
dead.joker_stickers.j_joker = { perishable = true, perish_tally = 1 }
end_round(dead)
assert(first_card_mult(dead) == 1, "a debuffed Joker and its edition score nothing")

-- Selling it puts the effect back for a later copy of that Joker.
local sell_dead = new_state(base, "STICKER-SELL-DEAD", { "j_joker" })
sell_dead.joker_stickers.j_joker = { perishable = true, perish_tally = 1 }
end_round(sell_dead)
local sold = false
sell_dead.Policy = setmetatable({
	shop_open = function(_, ctx)
		for position, action in ipairs(ctx.actions) do
			if action.type == "sell_joker" then sold = true; return position end
		end
		return 1
	end,
	shop_step = function() return 1 end,
}, { __index = base.Policy })
Simulator.visit_shop(sell_dead, {})
assert(sold and #sell_dead.jokers == 0 and sell_dead.joker_effects.j_joker ~= nil
	and sell_dead.joker_stickers.j_joker == nil, "a sold debuffed Joker leaves no trace")

-- The Expert sells a debuffed Joker when it enters the shop.
local expert_dead = new_state(base, "STICKER-EXPERT-DEAD", { "j_joker", "j_jolly" })
expert_dead.joker_stickers.j_joker = { perishable = true, perish_tally = 1 }
end_round(expert_dead)
expert_dead.money = 0
Simulator.visit_shop(expert_dead, {})
assert(count(expert_dead.jokers, "j_joker") == 0 and count(expert_dead.jokers, "j_jolly") == 1,
	"the Expert sells its debuffed Joker")

---------------------------------------------------------------------------
-- 5. Eternal: never sold, never destroyed.
---------------------------------------------------------------------------

local eternal_open = new_state(base, "STICKER-ETERNAL-OPEN", { "j_joker", "j_jolly" })
eternal_open.joker_stickers.j_joker = { eternal = true }
local open_actions, step_actions
eternal_open.Policy = setmetatable({
	shop_open = function(_, ctx) open_actions = ctx.actions; return 1 end,
	shop_step = function(_, ctx) step_actions = ctx.actions; return 1 end,
}, { __index = base.Policy })
eternal_open.joker_limit = 2
eternal_open.money = 50
Simulator.visit_shop(eternal_open, { "j_zany" })
for _, actions in ipairs({ open_actions, step_actions }) do
	for _, action in ipairs(actions) do
		assert(not (action.type == "sell_joker" and action.key == "j_joker"), "no sale of an Eternal Joker")
		assert(not (action.sell_key == "j_joker"), "no buy + sell of an Eternal Joker")
	end
end
local jolly_sale = false
for _, action in ipairs(step_actions) do
	if action.type == "sell_joker" and action.key == "j_jolly" then jolly_sale = true end
end
assert(jolly_sale, "the other Joker can be sold")

-- Ceremonial Dagger does not slice an Eternal Joker (no Mult either).
local dagger = new_state(base, "STICKER-DAGGER", { "j_ceremonial", "j_joker" })
dagger.joker_stickers.j_joker = { eternal = true }
Simulator.begin_round(dagger, nil, "Small")
assert(#dagger.jokers == 2 and (dagger.joker_state.j_ceremonial or 0) == 0, "the Eternal Joker survives the Dagger")
local slicing = new_state(base, "STICKER-DAGGER-2", { "j_ceremonial", "j_jolly" })
Simulator.begin_round(slicing, nil, "Small")
assert(#slicing.jokers == 1, "a normal Joker is sliced")

-- Madness destroys only a non-Eternal Joker.
for seed = 1, 10 do
	local madness = new_state(base, "STICKER-MADNESS-" .. seed, { "j_madness", "j_joker", "j_jolly" })
	madness.joker_stickers.j_joker = { eternal = true }
	Simulator.begin_round(madness, nil, "Small")
	assert(count(madness.jokers, "j_joker") == 1 and count(madness.jokers, "j_jolly") == 0,
		"Madness spares the Eternal Joker")
end
local only_eternal = new_state(base, "STICKER-MADNESS-NONE", { "j_madness", "j_joker" })
only_eternal.joker_stickers.j_joker = { eternal = true }
Simulator.begin_round(only_eternal, nil, "Small")
assert(#only_eternal.jokers == 2, "Madness destroys nothing when every other Joker is Eternal")

-- Hex and Ankh keep Eternal Jokers.
local function spectral(state, key)
	for _, tool in ipairs(state.deck_tools) do
		if tool.key == key then
			local copy = {}
			for name, value in pairs(tool) do copy[name] = value end
			copy.type = "deck_tool"
			return copy
		end
	end
	error("no " .. key)
end
for seed = 1, 6 do
	local hex = new_state(base, "STICKER-HEX-" .. seed, { "j_joker", "j_jolly", "j_mad" })
	hex.joker_stickers.j_jolly = { eternal = true }
	assert(Simulator.apply_consumable(hex, spectral(hex, "c_hex")))
	assert(count(hex.jokers, "j_jolly") == 1 and #hex.jokers <= 2, "Hex spares the Eternal Joker")
	local ankh = new_state(base, "STICKER-ANKH-" .. seed, { "j_joker", "j_jolly", "j_mad" })
	ankh.joker_stickers.j_jolly = { eternal = true }
	assert(Simulator.apply_consumable(ankh, spectral(ankh, "c_ankh")))
	assert(count(ankh.jokers, "j_jolly") >= 1, "Ankh spares the Eternal Joker")
	assert(#ankh.jokers == 3 or #ankh.jokers == 2, "Ankh: the copy plus the Eternal Joker")
end

-- The Expert never tries to sell an Eternal Joker for a better offer.
local full = new_state(base, "STICKER-EXPERT-FULL", { "j_joker", "j_jolly", "j_mad", "j_zany", "j_crazy" })
for _, key in ipairs(full.jokers) do full.joker_stickers[key] = { eternal = true } end
full.money = 100
Simulator.visit_shop(full, { "j_blueprint", "j_stencil" })
assert(#full.jokers == 5 and count(full.jokers, "j_blueprint") == 0, "no slot can be freed")
local mixed = new_state(base, "STICKER-EXPERT-MIXED", { "j_joker", "j_jolly", "j_mad", "j_zany", "j_crazy" })
for _, key in ipairs({ "j_jolly", "j_mad", "j_zany", "j_crazy" }) do mixed.joker_stickers[key] = { eternal = true } end
mixed.money = 100
Simulator.visit_shop(mixed, { "j_blueprint" })
for _, key in ipairs({ "j_jolly", "j_mad", "j_zany", "j_crazy" }) do
	assert(count(mixed.jokers, key) == 1, "the Eternal Jokers stay: " .. key)
end

---------------------------------------------------------------------------
-- 6. Multiplayer's all_eternal mutator: every created Joker is Eternal
-- (create_card), except one that cannot be.
---------------------------------------------------------------------------

local mutator = new_state(base, "STICKER-ALL-ETERNAL", {}, { sticker_rules = { all_eternal = true } })
mutator.money = 20
assert(buy(mutator, "j_jolly", {}) and mutator.joker_stickers.j_jolly.eternal, "a bought Joker is Eternal")
assert(buy(mutator, "j_gros_michel", {}) and mutator.joker_stickers.j_gros_michel == nil,
	"Gros Michel cannot be Eternal")
local judged_jokers, plain_jokers = 0, 0
for seed = 1, 12 do
	local judged = new_state(base, "STICKER-JUDGEMENT-" .. seed, {}, { sticker_rules = { all_eternal = true } })
	assert(Simulator.apply_consumable(judged, spectral(judged, "c_judgement")))
	for _, key in ipairs(judged.jokers) do
		judged_jokers = judged_jokers + 1
		assert(judged.joker_stickers[key] and judged.joker_stickers[key].eternal or key == "j_gros_michel"
			or key == "j_ice_cream" or key == "j_cavendish" or key == "j_turtle_bean" or key == "j_diet_cola"
			or key == "j_popcorn" or key == "j_ramen" or key == "j_selzer" or key == "j_invisible"
			or key == "j_luchador" or key == "j_mr_bones",
			"Judgement's Joker is Eternal: " .. key)
	end
	local plain = new_state(base, "STICKER-JUDGEMENT-PLAIN-" .. seed, {}, { stake = 8 })
	assert(Simulator.apply_consumable(plain, spectral(plain, "c_judgement")))
	plain_jokers = plain_jokers + #plain.jokers
	assert(next(plain.joker_stickers) == nil, "Judgement's Joker has no stake sticker")
end
assert(judged_jokers > 0 and plain_jokers > 0, "Judgement created Jokers")

---------------------------------------------------------------------------
-- 7. Buffoon Packs.
---------------------------------------------------------------------------

-- a live Order pack's rolls (Order.generate_pack descriptors)
local pack_state = new_state(base, "STICKER-PACK", {}, { stake = 8, strict_order_content = true })
pack_state.Order = {
	generate_pack = function()
		return {
			{ kind = "center", key = "j_jolly", eternal = true, rental = true },
			{ kind = "center", key = "j_joker", perishable = true },
		}
	end,
}
local contents
pack_state.Policy = setmetatable({
	pack_step = function(_, ctx)
		contents = ctx.contents
		for position, action in ipairs(ctx.actions) do
			if action.type == "take" and ctx.contents[action.index].key == "j_jolly" then return position end
		end
		return 1
	end,
	shop_step = function(_, ctx)
		for position, action in ipairs(ctx.actions) do
			if action.type == "buy" then return position end
		end
		return 1
	end,
}, { __index = base.Policy })
pack_state.money = 10
Simulator.visit_shop(pack_state, { "p_buffoon_normal_1" })
assert(contents and contents[1].eternal and contents[1].rental and contents[1].cost == 0
	and contents[2].perishable, "pack cards carry their stickers and stay free")
assert(pack_state.joker_stickers.j_jolly and pack_state.joker_stickers.j_jolly.eternal
	and pack_state.joker_stickers.j_jolly.rental, "the picked Joker keeps them")

-- headless Buffoon Packs roll them like the shop
local pack_seen, pack_eternal = 0, 0
local pack_modules = with_hooks({
	pack_step = function(_, ctx)
		for _, item in ipairs(ctx.contents) do
			if item.type == "joker" then
				pack_seen = pack_seen + 1
				if item.eternal then pack_eternal = pack_eternal + 1 end
				assert(not (item.eternal and item.perishable), "pack Joker: never both")
			end
		end
		return 1
	end,
	shop_step = function(_, ctx)
		for position, action in ipairs(ctx.actions) do
			if action.type == "buy" and action.item_type == "pack" then return position end
		end
		return 1
	end,
})
local headless_packs = new_state(pack_modules, "STICKER-PACKS", {}, { stake = 4 })
for visit = 1, 200 do
	headless_packs.round = visit
	headless_packs.money = 100
	Simulator.visit_shop(headless_packs, { "p_buffoon_jumbo_1" })
end
assert(pack_seen > 300 and math.abs(pack_eternal / pack_seen - 0.3 * 139 / 150) < 0.08,
	"about 30% of compatible pack Jokers are Eternal at Black Stake: " .. pack_eternal .. "/" .. pack_seen)

-- The Expert takes a Rental Joker only while it can pay a round of rent.
local function expert_buys_rental(owned_rentals)
	local state = new_state(base, "STICKER-EXPERT-RENT", { "j_jolly", "j_mad" }, { stake = 8, strict_order_content = true })
	if owned_rentals then
		state.joker_stickers.j_jolly, state.joker_stickers.j_mad = { rental = true }, { rental = true }
	end
	state.money = 8
	Simulator.visit_shop(state, { "j_joker", _metadata = { { rental = true } } })
	return count(state.jokers, "j_joker") == 1
end
assert(expert_buys_rental(false), "$8 - $1 pays the $3 rent: the Expert buys it")
assert(not expert_buys_rental(true), "$8 - $1 cannot pay three Rental Jokers' $9")

-- Whole Gold Stake runs: the Expert plays with every sticker.
local stickered, rents = 0, 0
for _, seed in ipairs({ "GOLD-1", "GOLD-2", "GOLD-3" }) do
	local _, export = Simulator.run({ seed = seed, difficulty = "expert", max_ante = 6, the_order = true, stake = 8 }, base)
	for _, decision in ipairs(export.decisions) do
		if decision.type == "pay_rental" then rents = rents + 1 end
		if decision.type == "shop_decision" and tostring(decision.evaluated):find("~eternal", 1, true) then
			stickered = stickered + 1
		end
	end
	assert(type(export.joker_stickers) == "table", "the export lists the stickers")
end
assert(stickered > 0, "Gold Stake shops offer stickered Jokers")

---------------------------------------------------------------------------
-- 8. The live peer reads the lobby run's modifiers.
---------------------------------------------------------------------------

package.preload.json = package.preload.json or function()
	return { encode = function() return "{}" end, decode = function() return {} end }
end
G = { GAME = { stake = 9, modifiers = { enable_eternals_in_shop = true, enable_perishables_in_shop = true } } }
local Peer = dofile("bot/peer.lua")
Peer.run = { stake = 9 }
local rules = Peer.live_sticker_rules()
assert(rules and rules.eternal and rules.perishable and not rules.rental and not rules.all_eternal,
	"Multiplayer's Planet Stake: Eternal and Perishable, no Rental")
G.GAME.stake = 1
assert(Peer.live_sticker_rules() == nil, "another run's modifiers are not used")
G = nil

print("stake_stickers_spec: ok")
