-- Skip Tags and shop Vouchers, checked against the game's source (tag.lua
-- apply_to_run, functions/button_callbacks.lua skip_blind, game.lua shop
-- creation, functions/UI_definitions.lua create_card_for_shop, card.lua
-- Card:apply_to_run / Card:set_cost).
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
local Simulator = base.Simulator

-- A test policy: `hooks` override the Expert's decisions.
local function policy(hooks)
	local modules = {}
	for key, value in pairs(base) do modules[key] = value end
	modules.Policy = setmetatable(hooks, { __index = base.Policy })
	return modules
end

local function new_state(modules, seed, options)
	local state = Simulator.new({ seed = seed, difficulty = "expert", the_order = true }, modules)
	for key, value in pairs(options or {}) do state[key] = value end
	return state
end

local function find_action(actions, wanted)
	for index, action in ipairs(actions) do
		local ok = true
		for key, value in pairs(wanted) do if action[key] ~= value then ok = false; break end end
		if ok then return index, action end
	end
	return nil
end

-- skips the Small Blind only; takes every pack card it can.
local packs_seen = {}
local skip_small = policy({
	skip_pair = function() return true, false end,
	pack_step = function(_, ctx)
		packs_seen[#packs_seen + 1] = { key = ctx.pack.key, cost = ctx.pack.cost, contents = #ctx.contents,
			picks_left = ctx.picks_left, tag = ctx.pack.tag_reward }
		return find_action(ctx.actions, { type = "take" }) or 1
	end,
})
local function skip_for(tag, options, modules)
	local state = new_state(modules or skip_small, "TAG-" .. tag, options)
	Simulator.set_ante(state, 2)
	packs_seen = {}
	Simulator.plan_skips(state, "reactive", { Small = tag, Big = "tag_economy" })
	return state
end
local function last_decision(state, kind)
	for index = #state.decisions, 1, -1 do
		if state.decisions[index].type == kind then return state.decisions[index] end
	end
	return nil
end

---------------------------------------------------------------------------
-- 1. Every vanilla Tag is a reward the headless run applies.
---------------------------------------------------------------------------

local vanilla_tags = {
	"tag_uncommon", "tag_rare", "tag_negative", "tag_foil", "tag_holo", "tag_polychrome",
	"tag_investment", "tag_voucher", "tag_boss", "tag_standard", "tag_charm", "tag_meteor",
	"tag_buffoon", "tag_handy", "tag_garbage", "tag_ethereal", "tag_coupon", "tag_double",
	"tag_juggle", "tag_d_six", "tag_top_up", "tag_skip", "tag_orbital", "tag_economy",
}
local headless = new_state(base, "SUPPORTED")
for _, tag in ipairs(vanilla_tags) do
	assert(Simulator.skip_reward_supported(headless, tag), tag .. " should be a supported skip reward")
end
assert(not Simulator.skip_reward_supported(headless, "tag_mp_gambling_sandbox"),
	"a modded Tag the run cannot apply stays unsupported")
-- A live run needs its private Order queues for hidden cards.
local strict = Simulator.new({ seed = "STRICT", difficulty = "expert", the_order = true,
	strict_order_content = true }, base)
strict.Order = nil
for _, tag in ipairs({ "tag_buffoon", "tag_charm", "tag_meteor", "tag_ethereal", "tag_standard",
	"tag_voucher", "tag_rare", "tag_uncommon" }) do
	assert(not Simulator.skip_reward_supported(strict, tag), tag .. " needs the Order queues in a live run")
end
strict.Order = {
	generate_pack = function() return {} end,
	generate_tag_voucher = function() return nil end,
	generate_tag_joker = function() return nil end,
}
for _, tag in ipairs({ "tag_buffoon", "tag_meteor", "tag_voucher", "tag_rare" }) do
	assert(Simulator.skip_reward_supported(strict, tag), tag .. " is supported with the Order queues")
end

---------------------------------------------------------------------------
-- 2. Pack Tags open their free Booster at once (new_blind_choice).
---------------------------------------------------------------------------

local buffoon = skip_for("tag_buffoon", { money = 10 })
assert(#packs_seen >= 1 and packs_seen[1].key == "p_buffoon_mega_1" and packs_seen[1].cost == 0
	and packs_seen[1].picks_left == 2 and packs_seen[1].tag == "tag_buffoon",
	"Buffoon Tag opens a free Mega Buffoon Pack with two picks")
assert(buffoon.money == 10 and #buffoon.jokers >= 1, "the Buffoon Tag's Jokers are free: "
	.. buffoon.money .. " / " .. #buffoon.jokers)
local opened = last_decision(buffoon, "open_pack")
assert(opened and opened.key == "p_buffoon_mega_1" and opened.source == "tag_buffoon",
	"opening a Tag's pack is logged")

local ethereal = skip_for("tag_ethereal")
assert(packs_seen[1] and packs_seen[1].key == "p_spectral_normal_1" and packs_seen[1].picks_left == 1,
	"Ethereal Tag opens a free Spectral Pack")

local charm = skip_for("tag_charm")
assert(packs_seen[1] and packs_seen[1].key == "p_arcana_mega_1" and packs_seen[1].picks_left == 2,
	"Charm Tag opens a free Mega Arcana Pack")

local meteor = skip_for("tag_meteor")
assert(packs_seen[1] and packs_seen[1].key == "p_celestial_mega_1" and packs_seen[1].contents == 5,
	"Meteor Tag opens a free Mega Celestial Pack")
local meteor_levels = 0
for _, level in pairs(meteor.levels) do meteor_levels = meteor_levels + level - 1 end
assert(meteor_levels == 2, "both Meteor picks level a hand: " .. meteor_levels)

local standard = skip_for("tag_standard")
assert(packs_seen[1] and packs_seen[1].key == "p_standard_mega_1" and #standard.deck == 54,
	"Standard Tag opens a free Mega Standard Pack and both picks join the deck")

-- A live run opens the pack from its Order queues.
local polled = {}
local live_meteor = Simulator.new({ seed = "LIVE-METEOR", difficulty = "expert", the_order = true,
	strict_order_content = true }, skip_small)
live_meteor.Order = {
	generate_pack = function(_, key)
		polled[#polled + 1] = key
		return { { kind = "center", key = "c_mercury" }, { kind = "center", key = "c_venus" } }
	end,
}
Simulator.set_ante(live_meteor, 2)
Simulator.plan_skips(live_meteor, "reactive", { Small = "tag_meteor" })
assert(polled[1] == "p_celestial_mega_1" and live_meteor.levels.Pair == 2
	and live_meteor.levels["Three of a Kind"] == 2, "a live Meteor Tag opens its pack from the Order queues")

---------------------------------------------------------------------------
-- 3. Double Tag copies the next Tag (tag_add), never another Double Tag.
---------------------------------------------------------------------------

local both = policy({ skip_pair = function() return true, true end })
local doubled = new_state(both, "DOUBLE", { money = 10 })
Simulator.set_ante(doubled, 2)
Simulator.plan_skips(doubled, "reactive", { Small = "tag_double", Big = "tag_economy" })
assert(doubled.money == 40 and (doubled.double_tags or 0) == 0,
	"Double Tag + Economy Tag doubles the money twice: " .. doubled.money)
local two_doubles = new_state(both, "TWO-DOUBLES", { money = 10 })
Simulator.set_ante(two_doubles, 2)
Simulator.plan_skips(two_doubles, "reactive", { Small = "tag_double", Big = "tag_double" })
assert(two_doubles.double_tags == 2, "a Double Tag does not copy another Double Tag")
Simulator.set_ante(two_doubles, 3)
Simulator.plan_skips(two_doubles, "reactive", { Small = "tag_investment" })
assert(two_doubles.pending_investment == 75 and two_doubles.double_tags == 0,
	"every held Double Tag copies the next Tag: " .. tostring(two_doubles.pending_investment))
local orbital = new_state(skip_small, "DOUBLE-ORBITAL", { double_tags = 1 })
Simulator.set_ante(orbital, 2)
Simulator.plan_skips(orbital, "reactive", { Small = "tag_orbital" })
local raised = {}
for hand, level in pairs(orbital.levels) do if level > 1 then raised[#raised + 1] = hand .. "=" .. level end end
assert(#raised == 1 and raised[1]:match("=7$"), "a copied Orbital Tag levels the same hand: "
	.. table.concat(raised, ","))

---------------------------------------------------------------------------
-- 4. Boss Tag rerolls this Ante's Boss Blind.
---------------------------------------------------------------------------

local boss = skip_for("tag_boss")
boss.next_boss_blind = "bl_hook"
Simulator.begin_round(boss, 1000, "Boss")
assert(boss.boss_blind and boss.boss_blind ~= "bl_hook" and boss.bosses_used.bl_hook == 1
	and boss.bosses_used[boss.boss_blind] == 1 and not boss.pending_boss_rerolls,
	"a Boss Tag rerolls the Boss; the first one stays counted as used")

---------------------------------------------------------------------------
-- 5. Shop Tags.
---------------------------------------------------------------------------

-- Leaves at once, keeping a copy of the offers.
local seen_offers
local look = policy({
	shop_step = function(_, ctx)
		seen_offers = {}
		for index, offer in ipairs(ctx.offers) do seen_offers[index] = offer end
		return 1
	end,
})
local function offer_for(key)
	for _, offer in ipairs(seen_offers or {}) do if offer.key == key then return offer end end
	return nil
end

-- Polychrome Tag: the next shop Joker without an edition becomes Polychrome and free.
local poly = new_state(look, "POLY-TAG", { money = 0 })
poly.pending_tag_jokers = { { tag = "tag_polychrome", edition = "polychrome" } }
local poly_report = Simulator.visit_shop(poly, { "c_mercury", "j_joker", "j_jolly",
	_metadata = { {}, { edition = "foil" }, {} } })
assert(offer_for("j_joker").edition == "foil" and offer_for("j_joker").cost > 0
	and offer_for("j_jolly").edition == "polychrome" and offer_for("j_jolly").cost == 0
	and #poly.pending_tag_jokers == 0 and poly_report.tag_rewards[1] == "tag_polychrome:j_jolly",
	"Polychrome Tag goes to the first shop Joker without an edition, which is free")
-- A Joker the run cannot simulate takes the edition too.
local lost = new_state(look, "POLY-LOST", { money = 0 })
lost.pending_tag_jokers = { { tag = "tag_polychrome", edition = "polychrome" } }
Simulator.visit_shop(lost, { "j_not_modeled", "j_joker" })
assert(not offer_for("j_joker").edition and #lost.pending_tag_jokers == 0,
	"the first shop Joker takes the edition even when the run cannot simulate it")
-- No Joker in the shop: the Tag waits for the next card created (a reroll too).
local waiting = new_state(look, "POLY-WAIT", { money = 0 })
waiting.pending_tag_jokers = { { tag = "tag_negative", edition = "negative" } }
Simulator.visit_shop(waiting, { "c_mercury", "c_venus" })
assert(#waiting.pending_tag_jokers == 1, "an edition Tag without a shop Joker waits")
Simulator.visit_shop(waiting, { "j_joker" })
assert(offer_for("j_joker").edition == "negative" and offer_for("j_joker").cost == 0,
	"the waiting Negative Tag goes to the next shop Joker")
-- Headless shop: the Tag lands on a main slot Joker, not on a pack.
local headless_poly = new_state(look, "POLY-HEADLESS", { money = 0 })
headless_poly.pending_tag_jokers = { { tag = "tag_foil", edition = "foil" } }
for _ = 1, 10 do
	Simulator.visit_shop(headless_poly)
	if #headless_poly.pending_tag_jokers == 0 then break end
end
assert(#headless_poly.pending_tag_jokers == 0, "the headless shop resolves the Foil Tag")

-- Rare Tag: its free Joker takes the first card slot instead of adding one.
local rare = new_state(look, "RARE-TAG", { money = 0 })
rare.pending_tag_jokers = { { tag = "tag_rare", rarity = "rare" } }
local rare_report = Simulator.visit_shop(rare)
assert(#rare_report.keys == 4 and seen_offers[1].tag_reward == "tag_rare" and seen_offers[1].cost == 0
	and #rare.pending_tag_jokers == 0,
	"a Rare Tag Joker replaces one of the two card slots: " .. table.concat(rare_report.keys, ","))
local plain = new_state(look, "RARE-TAG", { money = 0 })
assert(#Simulator.visit_shop(plain).keys == 5, "without a Tag the shop has two cards")

-- D6 Tag: this shop's rerolls start at $0, Reroll Surplus or not.
local d6 = new_state(look, "D6-TAG", { money = 0, reroll_discount = 2 })
d6.pending_shop_tags = { "tag_d_six" }
Simulator.visit_shop(d6, { "j_joker" })
assert(Simulator.next_reroll_cost(d6, 0) == 0 and Simulator.next_reroll_cost(d6, 2) == 2,
	"D6 Tag: rerolls cost $0, $1, $2 ...")
Simulator.visit_shop(d6, { "j_joker" })
assert(Simulator.next_reroll_cost(d6, 0) == 3, "the next shop costs again")

-- Coupon Tag: the new shop's cards and Boosters are free, its Voucher is not.
local coupon = new_state(look, "COUPON-TAG", { money = 0, shop_discount = 50 })
coupon.pending_shop_tags = { "tag_coupon" }
Simulator.visit_shop(coupon, { "j_joker", "c_mercury", "p_buffoon_normal_1", "v_grabber" })
assert(offer_for("j_joker").cost == 0 and offer_for("c_mercury").cost == 0
	and offer_for("p_buffoon_normal_1").cost == 0 and offer_for("v_grabber").cost == 5
	and #coupon.pending_shop_tags == 0, "Coupon Tag makes cards and packs free, not Vouchers")
Simulator.visit_shop(coupon, { "j_joker" })
assert(offer_for("j_joker").cost > 0, "a Coupon Tag works once")

-- Voucher Tag: one more Voucher in the next shop.
local voucher = new_state(look, "VOUCHER-TAG", { money = 0 })
voucher.pending_shop_tags = { "tag_voucher", "tag_voucher" }
local voucher_report = Simulator.visit_shop(voucher)
local vouchers, distinct = 0, {}
for _, offer in ipairs(seen_offers) do
	if offer.type == "voucher" then vouchers = vouchers + 1; distinct[offer.key] = true end
end
local distinct_count = 0
for _ in pairs(distinct) do distinct_count = distinct_count + 1 end
assert(vouchers == 3 and distinct_count == 3 and #voucher.pending_shop_tags == 0,
	"two Voucher Tags add two different Vouchers to the Ante's: " .. vouchers)
assert(voucher_report.tag_rewards[1]:match("^tag_voucher:v_"), "the Tag's Voucher is reported")
-- A live run polls it from its Order queue, never one already in the shop.
local asked
local live_voucher = Simulator.new({ seed = "LIVE-VOUCHER", difficulty = "expert", the_order = true,
	strict_order_content = true }, look)
live_voucher.Order = { generate_tag_voucher = function(_, in_shop) asked = in_shop; return "v_hone" end }
live_voucher.pending_shop_tags = { "tag_voucher" }
Simulator.visit_shop(live_voucher, { "j_joker", "v_grabber" })
assert(asked and asked.v_grabber and offer_for("v_hone") and offer_for("v_grabber"),
	"a live Voucher Tag polls the Order queue and skips the shop's own Voucher")

---------------------------------------------------------------------------
-- 6. Vouchers.
---------------------------------------------------------------------------

local buyer = policy({
	shop_step = function(_, ctx) return find_action(ctx.actions, { type = "buy" }) or 1 end,
})
local function redeem(state, key)
	local before = #state.vouchers
	Simulator.visit_shop(state, { key })
	assert(#state.vouchers == before + 1, key .. " should be redeemed")
end

-- Tarot / Planet Merchant and Tycoon set the shop rate to 9.6 and 32.
local tycoon = new_state(buyer, "TYCOON", { money = 100 })
redeem(tycoon, "v_tarot_merchant")
assert(math.abs(tycoon.tarot_rate - 2.4) < 1e-9, "Tarot Merchant: rate 9.6 (2.4 x 4)")
redeem(tycoon, "v_tarot_tycoon")
assert(tycoon.tarot_rate == 8, "Tarot Tycoon sets 32 (8 x 4), not 9.6 x 8: " .. tycoon.tarot_rate)
redeem(tycoon, "v_planet_merchant")
redeem(tycoon, "v_planet_tycoon")
assert(tycoon.planet_rate == 8, "Planet Tycoon: rate 32")
local tarots = {}
for _, tool in ipairs(tycoon.deck_tools) do if tool.set == "Tarot" then tarots[tool.key] = true end end
local planets = {}
for _, planet in ipairs(tycoon.planet_pool) do planets[planet.key] = true end
local counts, total = { joker = 0, tarot = 0, planet = 0 }, 0
for _ = 1, 4000 do
	for _, key in ipairs(Simulator.shop_keys(tycoon, true)) do
		total = total + 1
		if key:sub(1, 2) == "j_" then counts.joker = counts.joker + 1
		elseif tarots[key] then counts.tarot = counts.tarot + 1
		elseif planets[key] then counts.planet = counts.planet + 1 end
	end
end
assert(math.abs(counts.tarot / total - 32 / 84) < 0.03 and math.abs(counts.planet / total - 32 / 84) < 0.03,
	string.format("Tycoon shop shares: tarot %.3f planet %.3f", counts.tarot / total, counts.planet / total))

-- Magic Trick: playing cards in the shop ($1), bought into the deck.
local magic = new_state(buyer, "MAGIC-TRICK", { money = 100 })
redeem(magic, "v_magic_trick")
assert(magic.playing_card_rate == 4, "Magic Trick: playing_card_rate 4")
local playing, enhanced, editioned, cards = 0, 0, 0, 0
for _ = 1, 3000 do
	local keys = Simulator.shop_keys(magic, true)
	for index, key in ipairs(keys) do
		cards = cards + 1
		local card = keys._metadata[index].playing_card
		if card then
			playing = playing + 1
			assert(card.rank and card.suit and key == (card.enhancement or "c_base"), "a shop playing card")
			if card.enhancement then enhanced = enhanced + 1 end
			if card.edition then editioned = editioned + 1 end
		end
	end
end
assert(math.abs(playing / cards - 4 / 32) < 0.02 and enhanced == 0 and editioned == 0,
	string.format("Magic Trick: plain playing cards are 4/32 of the shop cards (%.3f)", playing / cards))
local deck_before, money_before = #magic.deck, magic.money
local card_report = Simulator.visit_shop(magic, { "c_base",
	_metadata = { { playing_card = { rank = 14, suit = "Hearts" } } } })
assert(card_report.purchases == 1 and #magic.deck == deck_before + 1 and magic.money == money_before - 1
	and magic.deck[#magic.deck].rank == 14 and magic.deck[#magic.deck].suit == "Hearts",
	"a $1 shop playing card goes into the deck: " .. magic.money)
-- Illusion: 40% Enhanced, 20% with an Edition (never Negative).
redeem(magic, "v_illusion")
playing, enhanced, editioned = 0, 0, 0
local negative = false
for _ = 1, 4000 do
	local keys = Simulator.shop_keys(magic, true)
	for index in ipairs(keys) do
		local card = keys._metadata[index].playing_card
		if card then
			playing = playing + 1
			if card.enhancement then enhanced = enhanced + 1 end
			if card.edition then editioned = editioned + 1 end
			if card.edition == "negative" then negative = true end
		end
	end
end
assert(math.abs(enhanced / playing - 0.4) < 0.05 and math.abs(editioned / playing - 0.2) < 0.04 and not negative,
	string.format("Illusion: enhanced %.3f, edition %.3f", enhanced / playing, editioned / playing))
local priced = new_state(look, "ILLUSION-PRICE", { money = 0 })
Simulator.visit_shop(priced, { "m_glass", _metadata = { { playing_card = {
	rank = 5, suit = "Clubs", enhancement = "m_glass", edition = "polychrome" } } } })
assert(seen_offers[1].type == "playing_card" and seen_offers[1].cost == 6,
	"a Polychrome shop playing card costs $1 + $5")

-- Live catalogs support every Voucher the simulator applies.
local catalog = base.Content.build({ Voucher = {
	{ key = "v_planet_tycoon" }, { key = "v_illusion" }, { key = "v_observatory" },
	{ key = "v_tarot_merchant" }, { key = "v_magic_trick" }, { key = "v_hieroglyph" },
} }, {}, {})
assert(#catalog.vouchers == 5 and catalog.unsupported.Voucher[1] == "v_hieroglyph",
	"Planet Tycoon, Illusion and Observatory are supported; Hieroglyph is not")

-- Observatory: each held Planet of the played hand gives X1.5 Mult.
local pair_player = policy({
	consumable_step = function() return 1 end,   -- keeps the Planets
	choose_turn = function(args)
		local cards = { args.hand[1], args.hand[2] }
		return { type = "play", indices = { 1, 2 }, result = args.evaluate(cards, args.hand) }
	end,
})
local function pair_score(vouchers, held)
	local state = new_state(pair_player, "OBSERVATORY")
	state.vouchers = vouchers
	state.deck = {}
	for index = 1, 8 do
		state.deck[index] = { rank = 9, suit = "Spades", chips = base.Cards.chips(9), id = "S9:" .. index }
	end
	state.consumables = held
	local session = Simulator.begin_round(state, nil, "Small")
	Simulator.step_round(session)
	return session.hands[1].hand_score
end
local mercury = { type = "planet", key = "c_mercury", hand = "Pair" }
local venus = { type = "planet", key = "c_venus", hand = "Three of a Kind" }
local without = pair_score({ "v_telescope" }, { mercury, mercury })
local with_two = pair_score({ "v_telescope", "v_observatory" }, { mercury, mercury })
local off_hand = pair_score({ "v_telescope", "v_observatory" }, { venus })
assert(with_two == math.floor(without * 2.25) and off_hand == without,
	"Observatory: X1.5 per held Pair Planet, nothing for another hand's: "
	.. without .. " / " .. with_two .. " / " .. off_hand)

print("skip_tags_vouchers_spec: ok")
