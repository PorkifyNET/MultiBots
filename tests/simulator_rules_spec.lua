-- simulator rules outside hand scoring, checked against the
-- game's source (card.lua calculate_joker / calculate_seal /
-- get_end_of_round_effect, functions/state_events.lua end_round,
-- functions/common_events.lua poll_edition / create_card, game.lua).
local base = {
	PRNG = dofile("bot/prng.lua"),
	Cards = dofile("bot/cards.lua"),
	Content = dofile("bot/content.lua"),
	Evaluator = dofile("bot/evaluator.lua"),
	Strategy = dofile("bot/strategy.lua"),
	Policy = dofile("bot/policy.lua"),
	Simulator = dofile("bot/simulator.lua"),
}
local Simulator = base.Simulator

-- A scripted player: `script(args, turn)` returns { type, indices } and the
-- move is scored with the simulator's own evaluate.
local function scripted(script)
	local modules = {}
	for key, value in pairs(base) do modules[key] = value end
	local turn = 0
	modules.Policy = setmetatable({
		choose_turn = function(args)
			turn = turn + 1
			local move = script(args, turn)
			if not move then return nil end
			if move.type == "play" then
				local cards = {}
				for i, index in ipairs(move.indices) do cards[i] = args.hand[index] end
				move.result = args.evaluate(cards, args.hand)
			end
			return move
		end,
	}, { __index = base.Policy })
	return modules
end

local function card(rank, suit, extra)
	local result = { rank = rank, suit = suit or "Spades", chips = base.Cards.chips(rank), id = tostring(rank) }
	for key, value in pairs(extra or {}) do result[key] = value end
	return result
end

local function deck_of(count, rank, extra)
	local deck = {}
	for index = 1, count do
		deck[index] = card(rank, "Spades", extra)
		deck[index].id = "S" .. rank .. ":" .. index
	end
	return deck
end

local function new_state(modules, seed, jokers, options)
	local state = Simulator.new({ seed = seed, difficulty = "expert", the_order = true }, modules)
	state.jokers = jokers or {}
	for _, key in ipairs(state.jokers) do state.joker_state[key] = state.joker_state[key] or 0 end
	for key, value in pairs(options or {}) do state[key] = value end
	return state
end

local function play_first(_, _) return { type = "play", indices = { 1 } } end

---------------------------------------------------------------------------
-- 1. Blueprint / Brainstorm copy money and card effects.
---------------------------------------------------------------------------

-- To Do List (context.before, no blueprint guard): the copy pays for the copied
-- Joker's hand.
local todo = new_state(scripted(play_first), "TODO", { "j_blueprint", "j_todo_list" })
todo.money = 0
local session = Simulator.begin_round(todo, nil, "Small")
todo.joker_state.j_todo_list = "High Card"
todo.hand = { card(9), card(5, "Hearts") }
Simulator.step_round(session)
assert(todo.money == 8, "Blueprint copying To Do List pays its $4 again: " .. tostring(todo.money))

-- Faceless Joker (context.discard): 3 face cards discarded pay $5, twice.
local faceless = new_state(scripted(function(_, turn)
	if turn == 1 then return { type = "discard", indices = { 1, 2, 3 } } end
	return { type = "play", indices = { 1 } }
end), "FACELESS", { "j_faceless", "j_brainstorm" })
faceless.deck = deck_of(20, 13)
faceless.money = 0
local faceless_session = Simulator.begin_round(faceless, nil, "Small")
Simulator.step_round(faceless_session)
assert(faceless.money == 10, "Brainstorm copying Faceless Joker pays $5 again: " .. tostring(faceless.money))

-- Riff-raff (setting_blind): two Common Jokers per copy while there is room.
local riff = new_state(scripted(play_first), "RIFF", { "j_blueprint", "j_riff_raff" }, { joker_limit = 10 })
Simulator.begin_round(riff, nil, "Small")
-- Alone, Riff-raff makes at most 2 (draws of unsupported Commons are left out);
-- with its copy it gets four draws.
assert(#riff.jokers > 4, "Riff-raff and its copy create up to four Jokers: " .. #riff.jokers)

-- Burglar (setting_blind): +3 Hands per copy, no discards.
local burglar = new_state(scripted(play_first), "BURGLAR", { "j_burglar", "j_brainstorm" })
local burglar_session = Simulator.begin_round(burglar, nil, "Small")
assert(burglar_session.hands_left == 4 + 3 + 3 and burglar_session.discards_left == 0,
	"Brainstorm copying Burglar adds 3 more Hands: " .. burglar_session.hands_left)

-- Space Joker (context.before): every copy rolls; with odds 1 both level up.
local space = new_state(scripted(play_first), "SPACE", { "j_space", "j_brainstorm" })
space.joker_effects.j_space = { kind = "chance_hand_level", odds = 1 }
local space_session = Simulator.begin_round(space, nil, "Small")
space.hand = { card(9), card(5, "Hearts") }
Simulator.step_round(space_session)
assert(space.levels["High Card"] == 3, "Space Joker and its copy each level the hand")

-- Mime (repetition, cardarea hand) copied: a held Gold card pays three times.
local mime = new_state(scripted(play_first), "MIME", { "j_blueprint", "j_mime" })
mime.money = 0
mime.hand = { card(5, "Hearts", { enhancement = "m_gold" }) }
Simulator.award_blind(mime, "Small", { cleared = true, hands_left = 0, score = 1 })
-- $3 blind + Gold 3 x (1 + Mime + Blueprint) = 9, interest floor(9 / 5) = 1.
assert(mime.money == 3 + 9 + 1, "Blueprint copying Mime retriggers held Gold: " .. mime.money)

-- Not copied: Wee Joker's growth, Green Joker's discard penalty and scaling.
local wee = new_state(scripted(play_first), "WEE", { "j_blueprint", "j_wee" })
local wee_session = Simulator.begin_round(wee, nil, "Small")
wee.hand = { card(2), card(9) }
Simulator.step_round(wee_session)
assert(wee.joker_state.j_wee == 8, "a copy of Wee Joker scores its chips but does not grow it")

---------------------------------------------------------------------------
-- 2. Blue and Purple Seals.
---------------------------------------------------------------------------

-- Blue Seal held at the end of the round: the Planet of the last hand played.
local blue = new_state(scripted(play_first), "BLUE", {})
blue.hand = { card(5, "Hearts", { seal = "Blue" }) }
blue.last_hand_played = "Flush"
Simulator.award_blind(blue, "Small", { cleared = true, hands_left = 0, score = 1 })
assert(#blue.consumables == 1 and blue.consumables[1].type == "planet" and blue.consumables[1].hand == "Flush",
	"a held Blue Seal creates the last hand's Planet")
-- Only while there is room; Mime retriggers it.
local blue_full = new_state(scripted(play_first), "BLUE-MIME", { "j_mime" }, { consumable_limit = 3 })
blue_full.hand = { card(5, "Hearts", { seal = "Blue" }), card(6, "Hearts", { seal = "Blue" }) }
blue_full.last_hand_played = "Pair"
Simulator.award_blind(blue_full, "Small", { cleared = true, hands_left = 0, score = 1 })
assert(#blue_full.consumables == 3, "Blue Seals stop at the consumable limit: " .. #blue_full.consumables)

-- Blue Seal through a played round: the last hand of the round counts.
local blue_round = new_state(scripted(function(args)
	for index, held in ipairs(args.hand) do
		if held.seal ~= "Blue" then return { type = "play", indices = { index } } end
	end
end), "BLUE-ROUND", {}, { hands_per_round = 1 })
blue_round.deck = deck_of(8, 7)
blue_round.deck[1].seal = "Blue"
local blue_session = Simulator.begin_round(blue_round, nil, "Small")
Simulator.step_round(blue_session)
Simulator.award_blind(blue_round, "Small", blue_session.result)
assert(#blue_round.consumables == 1 and blue_round.consumables[1].hand == "High Card",
	"the held Blue Seal card gives the Planet of the hand just played")

-- Purple Seal discarded: a Tarot, if there is room.
local purple = new_state(scripted(function(args, turn)
	if turn == 1 then
		for index, held in ipairs(args.hand) do
			if held.seal == "Purple" then return { type = "discard", indices = { index } } end
		end
	end
	return { type = "play", indices = { 1 } }
end), "PURPLE", {})
purple.deck = deck_of(8, 4)
purple.deck[1].seal = "Purple"
purple.deck[2].seal = "Purple"
local purple_session = Simulator.begin_round(purple, nil, "Small")
Simulator.step_round(purple_session)
assert(#purple.consumables == 1 and purple.consumables[1].set == "Tarot",
	"a discarded Purple Seal creates a Tarot")

---------------------------------------------------------------------------
-- 3. The headless shop is built like the real one.
---------------------------------------------------------------------------

local shop = new_state(base, "SHOP", {})
local first = Simulator.shop_keys(shop, false)
assert(#first == 5 and first[3] == "p_buffoon_normal_1" and first[5]:sub(1, 2) == "v_",
	"a shop has 2 cards, 2 Boosters (the first shop a Buffoon Pack) and the Ante's Voucher")
local voucher = first[5]
local again = Simulator.shop_keys(shop, false)
assert(#again == 5 and again[5] == voucher, "the Ante's Voucher stays in every shop of the Ante")
assert(#Simulator.shop_keys(shop, true) == 2, "a reroll refreshes only the two cards")
shop.ante = 2
local next_ante = Simulator.shop_keys(shop, false)
assert(next_ante[#next_ante]:sub(1, 2) == "v_", "every Ante rolls a Voucher")

-- Card types 20 : 4 : 4 and Joker editions (poll_edition, rate 1, Negative 0.3%).
local types, editions, jokers = { joker = 0, other = 0 }, {}, 0
local counter = new_state(base, "SHOP-STATS", {})
for _ = 1, 6000 do
	local keys = Simulator.shop_keys(counter, true)
	for index, key in ipairs(keys) do
		if key:sub(1, 2) == "j_" then
			types.joker = types.joker + 1
			jokers = jokers + 1
			local edition = keys._metadata[index].edition
			if edition then editions[edition] = (editions[edition] or 0) + 1 end
		else
			types.other = types.other + 1
		end
	end
end
local joker_share = types.joker / (types.joker + types.other)
assert(math.abs(joker_share - 20 / 28) < 0.02, "Jokers fill 20/28 of the shop cards: " .. joker_share)
local function rate(name) return (editions[name] or 0) / jokers end
assert(math.abs(rate("foil") - 0.02) < 0.006 and math.abs(rate("holo") - 0.014) < 0.005
	and math.abs(rate("polychrome") - 0.003) < 0.003 and math.abs(rate("negative") - 0.003) < 0.003,
	string.format("shop Joker editions: foil %.4f holo %.4f poly %.4f negative %.4f",
		rate("foil"), rate("holo"), rate("polychrome"), rate("negative")))

-- Edition price add-ons (Card:set_cost): a Polychrome Joker costs $5 more, a
-- Negative Joker gives its own slot.
local priced = new_state(base, "PRICED", {})
priced.money = 0
local report = Simulator.visit_shop(priced, { "j_joker", "j_joker", _metadata = { { edition = "polychrome" }, {} } })
assert(report.evaluated:find("j_joker~joker~7~", 1, true), "Polychrome adds $5: " .. report.evaluated)

-- Clearance Sale discounts Vouchers too (Card:set_cost).
local sale = new_state(base, "SALE", {})
sale.money = 0
sale.shop_discount = 50
local sale_report = Simulator.visit_shop(sale, { "v_grabber" })
assert(sale_report.evaluated:find("v_grabber~voucher~5~", 1, true), "Liquidation halves a Voucher: " .. sale_report.evaluated)

-- Boosters are bought unopened: the offer shows no cards until apply.
local unopened = new_state(base, "UNOPENED", {})
unopened.money = 0
local pack_report = Simulator.visit_shop(unopened, { "p_celestial_normal_1" })
assert(pack_report.evaluated:find("p_celestial_normal_1~pack~4~", 1, true), "a Celestial Pack costs $4")

---------------------------------------------------------------------------
-- 4. Boss Blinds of non-PvP Boss rounds (blind.lua, game.lua P_BLINDS).
---------------------------------------------------------------------------

local function boss_round(boss, jokers, hand)
	local state = new_state(scripted(play_first), "BOSS-" .. boss, jokers or {})
	state.next_boss_blind = boss
	local session = Simulator.begin_round(state, 1000000, "Boss")
	if hand then state.hand = hand end
	return state, session
end

-- The Club debuffs Clubs: no chips and no Joker effects for them.
local club, club_session = boss_round("bl_club", { "j_gluttenous_joker" })
club.hand = { card(14, "Clubs", { debuff = true }), card(13, "Hearts") }
Simulator.step_round(club_session)
assert(club.boss_blind == "bl_club" and club_session.hands[1].hand_score == 5,
	"a debuffed Ace of Clubs scores nothing: " .. tostring(club_session.hands[1].hand_score))
local club_deck = new_state(base, "CLUB-DECK", {})
club_deck.next_boss_blind = "bl_club"
club_deck.deck = { card(5, "Clubs"), card(5, "Hearts", { enhancement = "m_wild" }),
	card(5, "Clubs", { enhancement = "m_stone" }), card(5, "Spades") }
Simulator.begin_round(club_deck, 1000000, "Boss")
assert(club_deck.deck[1].debuff and club_deck.deck[2].debuff and not club_deck.deck[3].debuff
	and not club_deck.deck[4].debuff, "The Club debuffs Clubs and Wild cards, not Stone cards")
-- The Psychic: fewer than 5 cards score nothing.
local _, psychic_session = boss_round("bl_psychic", {}, { card(14), card(13) })
Simulator.step_round(psychic_session)
assert(psychic_session.hands[1].hand_score == 0, "The Psychic does not score a 1-card hand")
-- The Needle: one hand; The Water: no discards; The Manacle: -1 hand size.
local _, needle_session = boss_round("bl_needle")
assert(needle_session.hands_left == 1, "The Needle leaves one hand")
local _, water_session = boss_round("bl_water")
assert(water_session.discards_left == 0, "The Water leaves no discards")
local manacle = boss_round("bl_manacle")
assert(#manacle.hand == 7, "The Manacle draws 7 cards: " .. #manacle.hand)
-- The Hook discards two random held cards when a hand is played.
local hook, hook_session = boss_round("bl_hook", {}, { card(2), card(13), card(12), card(11) })
hook.draw_pile = {}
Simulator.step_round(hook_session)
assert(#hook.hand == 1 and hook.discarded_cards == 2, "The Hook discards 2 of the 3 held cards")
-- The Pillar debuffs the cards played earlier in the Ante.
local pillar = new_state(scripted(play_first), "PILLAR", {})
pillar.deck = deck_of(8, 9)
local pillar_small = Simulator.begin_round(pillar, 1000000, "Small")
local played = pillar.hand[1]
Simulator.step_round(pillar_small)
pillar.next_boss_blind = "bl_pillar"
Simulator.begin_round(pillar, 1000000, "Boss")
assert(played.debuff == true, "The Pillar debuffs a card played this Ante")
-- No Boss in a PvP round; the Ante 1 pool has the eight Bosses with minimum Ante 1.
local pvp = new_state(base, "PVP-BOSS", {})
Simulator.begin_round(pvp, nil, "Boss", "PvP")
assert(pvp.boss_blind == nil, "a PvP Blind has no Boss effect")
local seen, count = {}, 0
for index = 1, 400 do seen[Simulator.pick_boss(base.PRNG.new("PICK" .. index), 1)] = true end
for _ in pairs(seen) do count = count + 1 end
assert(count == 8 and not seen.bl_wall and not seen.bl_needle, "Ante 1 has 8 Bosses: " .. count)
assert(Simulator.pick_boss(base.PRNG.new("USED"), 1, {
	bl_hook = 1, bl_club = 1, bl_manacle = 1, bl_psychic = 1, bl_goad = 1, bl_head = 1, bl_window = 1,
}) == "bl_pillar", "get_new_boss prefers the least used Boss")

---------------------------------------------------------------------------
-- 5. Economy and other rules.
---------------------------------------------------------------------------

-- Joker sell value includes the edition (Card:set_cost): Swashbuckler adds a
-- Foil Joker's (2 + 2) / 2 = 2.
local swash = new_state(scripted(play_first), "SWASH", { "j_swashbuckler", "j_joker" })
swash.joker_editions.j_joker = "foil"
local swash_session = Simulator.begin_round(swash, nil, "Small")
swash.hand = { card(3), card(9, "Hearts") }
Simulator.step_round(swash_session)
assert(swash_session.hands[1].hand_score == (5 + 3 + 50) * (1 + 2 + 4),
	"Swashbuckler counts the edition in the sell value: " .. swash_session.hands[1].hand_score)

-- Chaos the Clown: the free reroll does not raise the price.
local chaos = new_state(base, "CHAOS", { "j_chaos" })
assert(Simulator.next_reroll_cost(chaos, 0) == 0 and Simulator.next_reroll_cost(chaos, 1) == 5
	and Simulator.next_reroll_cost(chaos, 2) == 6, "Chaos: $0, then $5, $6")

-- Tags: Speed Tag $5 per skip (this one included), Handy Tag $1 per hand played.
local tagged = new_state(base, "TAGS", { "j_joker", "j_jolly" })
tagged.money, tagged.ante, tagged.hands_played = 20, 3, 7
tagged.Policy = setmetatable({ should_skip_blind = function() return true end }, { __index = base.Policy })
Simulator.plan_skips(tagged, "reactive", { Small = "tag_skip", Big = "tag_handy" })
assert(tagged.money == 20 + 5 + 7, "Speed Tag $5, Handy Tag $7: " .. tagged.money)
-- Orbital Tag: +3 levels to one hand.
local orbital = new_state(base, "ORBITAL", { "j_joker", "j_jolly" })
orbital.money, orbital.ante = 20, 3
orbital.Policy = tagged.Policy
Simulator.plan_skips(orbital, "reactive", { Small = "tag_orbital", Big = "tag_orbital" })
local levels = 0
for _, level in pairs(orbital.levels) do levels = levels + level - 1 end
assert(levels == 6, "two Orbital Tags give 6 levels")

-- Antimatter adds a Joker slot.
local anti = new_state(base, "ANTIMATTER", {})
anti.money = 100
anti.vouchers = { "v_blank" }
Simulator.visit_shop(anti, { "v_antimatter" })
assert(anti.vouchers[2] == "v_antimatter" and anti.joker_limit == 6, "Antimatter: +1 Joker slot")

-- Green Deck pays $2 per hand and $1 per discard left, and no interest.
local green = Simulator.new({ seed = "GREEN", difficulty = "expert", deck = "b_green" }, base)
green.money = 50
Simulator.award_blind(green, "Small", { cleared = true, hands_left = 2, discards_left = 3, score = 1 })
assert(green.money == 50 + 3 + 4 + 3, "Green Deck payout: " .. green.money)
-- Blue Stake: -1 discard (game.lua start_run).
local blue_stake = Simulator.new({ seed = "STAKE", difficulty = "expert", stake = 5 }, base)
assert(blue_stake.discards_per_round == 3, "Red Deck at Blue Stake: 3 + 1 - 1 discards")

-- Glass: X1.5 under Multiplayer's standard rulesets, X2 with vanilla content.
local function glass_score(ruleset)
	local state = Simulator.new({ seed = "GLASS", difficulty = "expert", ruleset = ruleset }, scripted(play_first))
	local session = Simulator.begin_round(state, nil, "Small")
	state.hand = { card(10, "Hearts", { enhancement = "m_glass" }), card(3) }
	Simulator.step_round(session)
	return session.hands[1].hand_score
end
assert(glass_score("ruleset_mp_blitz") == math.floor(15 * 1.5) and glass_score("ruleset_mp_vanilla") == 30,
	"Glass X1.5 in Blitz, X2 in Vanilla: " .. glass_score("ruleset_mp_blitz"))
local blitz = Simulator.new({ seed = "JUSTICE", difficulty = "expert", ruleset = "ruleset_mp_blitz" }, base)
for _, tool in ipairs(blitz.deck_tools) do
	assert(tool.key ~= "c_justice", "Justice is banned by Multiplayer's standard layer")
end

-- The fast copy-Joker layout search finds the exhaustive search's best score
-- (Blueprint must copy Cavendish and sit after the additive Jokers).
local function best_layout(exact)
	local modules = scripted(function() return nil end)
	local result
	modules.Policy.choose_turn = function(args)
		result = args.evaluate({ card(14), card(14, "Hearts") }, args.hand)
		return nil
	end
	local state = new_state(modules, "LAYOUT", { "j_cavendish", "j_jolly", "j_blueprint", "j_joker", "j_sly" })
	state.pool_flags.gros_michel_extinct = true
	state.exact_joker_order = exact
	Simulator.step_round(Simulator.begin_round(state, nil, "Small"))
	return result
end
local fast_layout, exact_layout = best_layout(false), best_layout(true)
assert(fast_layout.score == exact_layout.score and fast_layout.score == math.floor((10 + 22 + 50) * (2 + 8 + 4) * 9),
	"fast layout " .. fast_layout.score .. " vs exhaustive " .. exact_layout.score)

---------------------------------------------------------------------------
-- 6. Shop rules: rerolls and debt (functions/button_callbacks.lua).
---------------------------------------------------------------------------

-- An external policy whose shop_step is `step(state, ctx, default)`.
local function shop_player(step)
	local modules = {}
	for key, value in pairs(base) do modules[key] = value end
	modules.Policy = setmetatable({ shop_step = step }, { __index = base.Policy })
	return modules
end
local function find_action(ctx, wanted)
	for index, action in ipairs(ctx.actions) do
		local ok = true
		for key, value in pairs(wanted) do if action[key] ~= value then ok = false; break end end
		if ok then return index, action end
	end
	return nil
end

-- A reroll replaces only the main card slots (reroll_shop :2872-2887 refills
-- G.shop_jokers only): the unbought Booster Packs and the Voucher stay.
local first_offers, bought_pack, second_offers
local keeper = new_state(shop_player(function(_, ctx)
	if not first_offers then
		first_offers = {}
		for _, offer in ipairs(ctx.offers) do first_offers[#first_offers + 1] = offer end
	end
	if second_offers == nil and ctx.shop_rerolls > 0 then
		second_offers = {}
		for _, offer in ipairs(ctx.offers) do second_offers[#second_offers + 1] = offer end
		return 1
	end
	if not bought_pack then
		local index, action = find_action(ctx, { type = "buy", item_type = "pack" })
		if index then bought_pack = action.offer; return index end
	end
	return find_action(ctx, { type = "reroll" }) or 1
end), "KEEP-OFFERS", {}, { money = 50 })
local keep_report = Simulator.visit_shop(keeper)
assert(bought_pack and keep_report.reroll_requested, "the test player buys a pack and rerolls")
assert(Simulator.pay_reroll(keeper, keep_report.reroll_cost))
local reroll_report = Simulator.visit_shop(keeper)
assert(#reroll_report.keys == 2, "the reroll's own keys are the two main slots")
local expected_kept, kept = {}, {}
for _, offer in ipairs(first_offers) do
	if (offer.type == "pack" or offer.type == "voucher") and offer ~= bought_pack then expected_kept[offer] = true end
end
for _, offer in ipairs(second_offers) do
	if offer.type == "pack" or offer.type == "voucher" then
		assert(expected_kept[offer], "only unbought Boosters / the Voucher of the visit come back")
		kept[offer] = true
	end
end
for offer in pairs(expected_kept) do assert(kept[offer], "an unbought " .. offer.key .. " survives the reroll") end

-- Rerolls may go into debt like purchases (can_reroll :2077: dollars - bankrupt_at >= cost).
local function reroll_listed(jokers, money)
	local listed
	local state = new_state(shop_player(function(_, ctx)
		listed = find_action(ctx, { type = "reroll" }) ~= nil
		return 1
	end), "DEBT-REROLL", jokers, { money = money })
	Simulator.visit_shop(state, { "j_jolly" })
	return listed
end
assert(reroll_listed({ "j_credit_card" }, 2) and not reroll_listed({ "j_joker" }, 2),
	"with Credit Card a $5 reroll is possible at $2")
local in_debt = new_state(base, "DEBT-PAY", { "j_credit_card" }, { money = 2 })
assert(Simulator.pay_reroll(in_debt, 5) and in_debt.money == -3, "a reroll may take the money to -$3")
in_debt.money = -16
assert(not Simulator.pay_reroll(in_debt, 5) and in_debt.money == -16, "but not below -$20")
local no_card = new_state(base, "DEBT-NONE", { "j_joker" }, { money = 2 })
assert(not Simulator.pay_reroll(no_card, 5) and no_card.money == 2, "no debt without Credit Card")

-- Sell, then buy: the sale value counts, and selling Credit Card removes its
-- debt allowance (card.lua remove_from_deck :656, can_buy :56).
local function compounds(jokers, money)
	local found = {}
	local state = new_state(shop_player(function(_, ctx)
		for _, action in ipairs(ctx.actions) do
			if action.type == "buy" and action.sell_key then found[action.sell_key] = true end
			if action.type == "buy" and not action.sell_key and action.item_type == "joker" then found.plain = true end
		end
		return 1
	end), "COMPOUND", jokers, { money = money })
	Simulator.visit_shop(state, { "j_blueprint" })   -- $10
	return found
end
local five = { "j_credit_card", "j_joker", "j_jolly", "j_mad", "j_crazy" }
local debt_compounds = compounds(five, -5)
assert(not debt_compounds.plain and debt_compounds.j_mad and not debt_compounds.j_credit_card,
	"at -$5: sell Mad Joker ($2, still -$20 allowed) and buy, but not by selling the Credit Card")
local cash_compounds = compounds({ "j_joker", "j_jolly", "j_mad", "j_crazy", "j_zany" }, 8)
assert(cash_compounds.j_mad and not cash_compounds.j_joker,
	"at $8: $8 + $2 sale pays $10, $8 + $1 does not")

---------------------------------------------------------------------------
-- 7. Spectral cards (card.lua use_consumeable / can_use_consumeable).
---------------------------------------------------------------------------

local function spectral(state, key)
	for _, tool in ipairs(state.deck_tools) do
		if tool.key == key then
			local held = {}
			for field, value in pairs(tool) do held[field] = value end
			held.type = "deck_tool"
			return held
		end
	end
	error("missing Spectral " .. key)
end
local function use(state, key)
	local held = spectral(state, key)
	assert(Simulator.consumable_usable(state, held), key .. " is usable")
	return Simulator.apply_consumable(state, held)
end

-- all 18 vanilla Spectrals are simulated
local keys = { "c_familiar", "c_grim", "c_incantation", "c_talisman", "c_aura", "c_wraith", "c_sigil",
	"c_ouija", "c_ectoplasm", "c_immolate", "c_ankh", "c_deja_vu", "c_hex", "c_trance", "c_medium",
	"c_cryptid", "c_soul", "c_black_hole" }
local probe = new_state(base, "SPECTRAL-LIST", {})
for _, key in ipairs(keys) do spectral(probe, key) end

-- Familiar / Grim / Incantation: -1 card, +3 / +2 / +4 enhanced (never Stone) cards of their ranks.
for key, spec in pairs({ c_familiar = { 3, 11, 13 }, c_grim = { 2, 14, 14 }, c_incantation = { 4, 2, 10 } }) do
	local state = new_state(base, "SPECTRAL-" .. key, {}, { deck = deck_of(20, 7) })
	assert(use(state, key))
	assert(#state.deck == 20 - 1 + spec[1], key .. " destroys 1 card and adds " .. spec[1])
	local added = 0
	for _, c in ipairs(state.deck) do
		if c.enhancement then
			added = added + 1
			assert(c.rank >= spec[2] and c.rank <= spec[3] and c.enhancement ~= "m_stone",
				key .. " adds enhanced cards of its ranks")
		end
	end
	assert(added == spec[1], key .. " adds " .. spec[1] .. " enhanced cards")
end

-- Talisman / Trance / Medium seal one card (through target_step).
for key, seal in pairs({ c_talisman = "Gold", c_trance = "Blue", c_medium = "Purple" }) do
	local state = new_state(base, "SPECTRAL-" .. key, {}, { deck = deck_of(20, 9) })
	assert(use(state, key))
	local sealed = 0
	for _, c in ipairs(state.deck) do if c.seal then assert(c.seal == seal); sealed = sealed + 1 end end
	assert(sealed == 1, key .. " seals exactly one card " .. seal)
end

-- Sigil: the hand turns to one suit. Ouija: one rank and -1 hand size.
local sigil = new_state(base, "SPECTRAL-SIGIL", {}, { deck = deck_of(8, 5) })
for index, c in ipairs(sigil.deck) do c.suit = base.Cards.suits[index % 4 + 1] end
assert(use(sigil, "c_sigil"))
for _, c in ipairs(sigil.deck) do assert(c.suit == sigil.deck[1].suit, "Sigil gives the hand one suit") end
local ouija = new_state(base, "SPECTRAL-OUIJA", {}, { deck = deck_of(8, 5) })
for index, c in ipairs(ouija.deck) do c.rank = index + 2 end
assert(use(ouija, "c_ouija"))
for _, c in ipairs(ouija.deck) do assert(c.rank == ouija.deck[1].rank, "Ouija gives the hand one rank") end
assert(ouija.hand_size_bonus == -1, "Ouija: -1 hand size")

-- Black Hole levels every hand.
local hole = new_state(base, "SPECTRAL-HOLE", {})
assert(use(hole, "c_black_hole"))
for _, name in ipairs({ "High Card", "Straight Flush", "Five of a Kind", "Flush House", "Flush Five" }) do
	assert(hole.levels[name] == 2, "Black Hole levels " .. name)
end

-- Wraith: a Rare Joker, money to $0; needs a free slot.
local wraith = new_state(base, "SPECTRAL-WRAITH", {}, { money = 30 })
assert(use(wraith, "c_wraith") and wraith.money == 0, "Wraith sets money to $0")
for _, key in ipairs(wraith.jokers) do
	for _, joker in ipairs(wraith.joker_pool) do
		if joker.key == key then assert(joker.rarity == 3, "Wraith's Joker is Rare") end
	end
end
local full = new_state(base, "SPECTRAL-FULL", { "j_joker", "j_jolly", "j_mad", "j_zany", "j_crazy" })
assert(not Simulator.consumable_usable(full, spectral(full, "c_wraith")), "Wraith needs a free Joker slot")
assert(not Simulator.consumable_usable(full, spectral(full, "c_ankh")), "Ankh needs a free Joker slot")
assert(Simulator.deck_tool_offer(full, spectral(full, "c_wraith")).utility == 0, "an unusable Wraith is worth 0")

-- Ankh: the remaining Joker is duplicated, the others destroyed.
local ankh = new_state(base, "SPECTRAL-ANKH", { "j_joker", "j_jolly" })
assert(use(ankh, "c_ankh"))
assert(#ankh.jokers == 2 and ankh.jokers[1] == ankh.jokers[2], "Ankh leaves two copies of one Joker")

-- Hex: Polychrome on an editionless Joker, all others destroyed.
local hex = new_state(base, "SPECTRAL-HEX", { "j_joker", "j_jolly", "j_mad" })
hex.joker_editions.j_mad = "foil"
assert(use(hex, "c_hex"))
assert(#hex.jokers == 1 and hex.jokers[1] ~= "j_mad" and hex.joker_editions[hex.jokers[1]] == "polychrome",
	"Hex keeps one Polychrome Joker")
local all_foil = new_state(base, "SPECTRAL-HEX-NONE", { "j_joker" })
all_foil.joker_editions.j_joker = "foil"
assert(not Simulator.consumable_usable(all_foil, spectral(all_foil, "c_hex")), "Hex needs an editionless Joker")

-- Ectoplasm: Negative (+1 slot), hand size -1 then -2.
local ecto = new_state(base, "SPECTRAL-ECTO", { "j_joker", "j_jolly" })
local limit = ecto.joker_limit
assert(use(ecto, "c_ectoplasm") and ecto.joker_limit == limit + 1 and ecto.hand_size_bonus == -1)
assert(use(ecto, "c_ectoplasm") and ecto.joker_limit == limit + 2 and ecto.hand_size_bonus == -3,
	"the second Ectoplasm costs 2 hand size")
assert(not Simulator.consumable_usable(ecto, spectral(ecto, "c_ectoplasm")), "no editionless Joker left")

-- The Soul: the default pool has simulated Legendaries (Chicot, Caino,
-- Perkeo, Triboulet, Yorick), so it creates a Joker the run can use.
local soul = new_state(base, "SPECTRAL-SOUL", {})
assert(Simulator.deck_tool_offer(soul, spectral(soul, "c_soul")).utility > 0,
	"The Soul has value with simulated Legendary Jokers")

-- Ghost Deck starts with Hex.
local ghost = Simulator.new({ seed = "SPECTRAL-GHOST", difficulty = "expert", deck = "Ghost Deck" }, base)
assert(ghost.consumables[1] and ghost.consumables[1].key == "c_hex", "Ghost Deck starts with Hex")

---------------------------------------------------------------------------
-- 8. Vanilla Jokers group B (card.lua calculate_joker, game.lua P_CENTERS).
---------------------------------------------------------------------------

-- Live catalogs list them (runtime_only); rarities and costs from game.lua.
local group_b_catalog = base.Content.build({ Joker = {
	{ key = "j_hit_the_road", cost = 8, rarity = 3 }, { key = "j_idol", cost = 6, rarity = 2 },
	{ key = "j_invisible", cost = 8, rarity = 3 }, { key = "j_luchador", cost = 5, rarity = 2 },
	{ key = "j_lucky_cat", cost = 6, rarity = 2 }, { key = "j_matador", cost = 7, rarity = 2 },
	{ key = "j_mr_bones", cost = 5, rarity = 2 }, { key = "j_perkeo", cost = 20, rarity = 4 },
	{ key = "j_rocket", cost = 6, rarity = 2 }, { key = "j_blueprint", cost = 10, rarity = 3 },
	{ key = "j_joker", cost = 2, rarity = 1 },
} })
assert(#group_b_catalog.jokers == 11 and not group_b_catalog.unsupported.Joker,
	"every group B Joker has a headless adapter")
local group_b_effects = {}
for _, joker in ipairs(group_b_catalog.jokers) do group_b_effects[joker.key] = joker.effect end

local function group_b_state(modules, seed, jokers, options)
	local state = new_state(modules, seed, {}, options)
	state.joker_pool = group_b_catalog.jokers
	for key, effect in pairs(group_b_effects) do state.joker_effects[key] = effect end
	state.jokers = jokers
	for _, key in ipairs(jokers) do
		local effect = state.joker_effects[key]
		state.joker_state[key] = effect and effect.initial or 0
	end
	return state
end

local function evaluate_b(cards, jokers, context)
	context.joker_effects = group_b_effects
	context.joker_state = context.joker_state or {}
	return base.Evaluator.evaluate(cards, {}, jokers, context)
end

-- Hit the Road: X0.5 per discarded Jack (not debuffed), reset at end of round.
local road = group_b_state(scripted(function(_, turn)
	if turn == 1 then return { type = "discard", indices = { 1, 2, 3 } } end
	return { type = "play", indices = { 1 } }
end), "ROAD", { "j_hit_the_road" })
local road_session = Simulator.begin_round(road, nil, "Small")
road.hand = { card(11), card(11, "Hearts"), card(11, "Clubs", { debuff = true }), card(5) }
Simulator.step_round(road_session)
assert(road.joker_state.j_hit_the_road == 2, "two live Jacks discarded: X2, got " .. tostring(road.joker_state.j_hit_the_road))
assert(road_session.hands[1].hand_score == evaluate_b({ card(5) }, {}, {}).score * 2, "the X2 scores")
Simulator.finish_round(road_session)
assert(road.joker_state.j_hit_the_road == 1, "Hit the Road resets at the end of the round")

-- The Idol: X2 per scored card of the round's rank and suit (Wild cards count).
local idol = { idol_card = { rank = 14, suit = "Spades" } }
local plain_pair = evaluate_b({ card(14), card(14, "Hearts") }, {}, {}).mult
assert(evaluate_b({ card(14), card(14, "Hearts") }, { "j_idol" }, idol).mult == plain_pair * 2,
	"only the Ace of Spades matches")
assert(evaluate_b({ card(14), card(14, "Hearts", { enhancement = "m_wild" }) }, { "j_idol" }, idol).mult
	== evaluate_b({ card(14), card(14, "Hearts", { enhancement = "m_wild" }) }, {}, {}).mult * 4,
	"a Wild Ace matches the suit too")
assert(evaluate_b({ card(14), card(14, "Hearts") }, { "j_blueprint", "j_idol" }, idol).mult == plain_pair * 4,
	"Blueprint copies The Idol")
local idol_state = group_b_state(base, "IDOL", { "j_idol" })
idol_state.deck = deck_of(10, 9)
for index = 1, 5 do idol_state.deck[index].enhancement = "m_stone" end
Simulator.begin_round(idol_state, nil, "Small")
assert(idol_state.idol_card.rank == 9 and idol_state.idol_card.suit == "Spades",
	"the Idol card is a random non-Stone card of the deck")

-- Lucky Cat: +X0.25 per Lucky trigger, at the expected rate 1 - (4/5)(14/15).
local lucky_chance = 1 - (4 / 5) * (14 / 15)
local lucky = { card(9, "Spades", { enhancement = "m_lucky" }) }
local lucky_plain = evaluate_b(lucky, {}, {}).mult
local lucky_result = evaluate_b(lucky, { "j_lucky_cat" }, { joker_state = { j_lucky_cat = 1.5 } })
assert(math.abs(lucky_result.mult - lucky_plain * (1.5 + 0.25 * lucky_chance)) < 1e-9,
	"Lucky Cat applies its X Mult with this hand's expected growth")
assert(math.abs(lucky_result.growth.j_lucky_cat - 0.25 * lucky_chance) < 1e-12, "the growth is reported")
local cat = group_b_state(scripted(play_first), "CAT", { "j_lucky_cat" })
local cat_session = Simulator.begin_round(cat, nil, "Small")
cat.hand = { card(9, "Spades", { enhancement = "m_lucky" }), card(5) }
Simulator.step_round(cat_session)
assert(math.abs(cat.joker_state.j_lucky_cat - (1 + 0.25 * lucky_chance)) < 1e-12, "Lucky Cat keeps the growth")

-- Matador: $8 for each hand that triggers the Boss Blind, from every copy;
-- The Hook's trigger is reset by Blind:debuff_hand, so it pays nothing.
local function matador_money(boss, jokers, cards)
	local state = group_b_state(scripted(function(_, turn)
		if turn == 1 then return { type = "play", indices = { 1 } } end
	end), "MATADOR:" .. boss, jokers, { money = 0 })
	state.next_boss_blind = boss
	local session = Simulator.begin_round(state, 1e9, "Boss")
	state.hand = cards or { card(9), card(5), card(6), card(7) }
	Simulator.step_round(session)
	return state.money
end
assert(matador_money("bl_flint", { "j_matador" }) == 8, "The Flint triggers on every hand")
assert(matador_money("bl_flint", { "j_blueprint", "j_matador" }) == 16, "Blueprint copies Matador")
assert(matador_money("bl_psychic", { "j_matador" }) == 8, "a hand The Psychic debuffs pays")
assert(matador_money("bl_hook", { "j_matador" }) == 0, "The Hook does not count")
assert(matador_money("bl_club", { "j_matador" }, { card(9, "Clubs", { debuff = true }), card(5) }) == 8,
	"a debuffed scoring card triggers the Boss")

-- Mr. Bones: a lost Blind with at least 25% of its chips is saved, without the
-- Blind reward, and Mr. Bones is destroyed.
local function bones(score)
	local state = group_b_state(base, "BONES", { "j_mr_bones" }, { money = 0 })
	local session = Simulator.begin_round(state, 100, "Small")
	session.cumulative, session.hands_left = score, 0
	local result = Simulator.finish_round(session)
	return state, result
end
local saved_state, saved_result = bones(25)
assert(saved_result.cleared and saved_result.saved and #saved_state.jokers == 0, "25% of the chips is saved")
assert(Simulator.award_blind(saved_state, "Small", saved_result) and saved_state.money == 0,
	"a saved Blind pays no reward: " .. tostring(saved_state.money))
local lost_state, lost_result = bones(24)
assert(not lost_result.cleared and #lost_state.jokers == 1, "below 25% the run is not saved")

-- Rocket: $1 at the end of the round, +$2 per defeated Boss Blind before the payout.
local rocket = group_b_state(base, "ROCKET", { "j_rocket" }, { money = 0 })
local rocket_result = Simulator.finish_round(Simulator.begin_round(rocket, nil, "Small"))
assert(rocket.joker_state.j_rocket == 1, "no growth after a Small Blind")
Simulator.award_blind(rocket, "Small", rocket_result)
assert(rocket.money == 3 + 4 + 1, "Small $3 + 4 hands + Rocket $1: " .. tostring(rocket.money))
rocket.money = 0
rocket_result = Simulator.finish_round(Simulator.begin_round(rocket, nil, "Boss", "PvP"))
assert(rocket.joker_state.j_rocket == 3, "a Boss Blind raises the payout to $3")
assert(Simulator.award_blind(rocket, "Boss", rocket_result) and rocket.money == 5 + 4 + 3,
	"Boss $5 + 4 hands + Rocket $3: " .. tostring(rocket.money))

-- Invisible Joker: after 2 rounds the Expert sells it for a copy of another Joker.
local invisible = group_b_state(base, "INVISIBLE", { "j_invisible", "j_joker" }, { money = 0 })
for _ = 1, 2 do Simulator.finish_round(Simulator.begin_round(invisible, nil, "Small")) end
assert(invisible.joker_state.j_invisible == 2, "Invisible Joker counts the rounds")
Simulator.visit_shop(invisible, {})
assert(#invisible.jokers == 2 and invisible.jokers[1] == "j_joker" and invisible.jokers[2] == "j_joker",
	"the sale duplicates the other Joker: " .. table.concat(invisible.jokers, ","))
local early = group_b_state(shop_player(function(_, ctx)
	return find_action(ctx, { type = "sell_joker", key = "j_invisible" }) or 1
end), "INVISIBLE-EARLY", { "j_invisible", "j_joker" })
Simulator.visit_shop(early, {})
assert(#early.jokers == 1, "sold before 2 rounds it copies nothing")

-- Luchador: sold at the Boss Blind it disables the Boss (The Water keeps the discards).
local function luchador(keep)
	local modules = {}
	for key, value in pairs(base) do modules[key] = value end
	if keep then modules.Policy = setmetatable({ boss_disable_step = function() return 1 end }, { __index = base.Policy }) end
	local state = group_b_state(modules, "LUCHADOR", { "j_luchador" }, { money = 0 })
	state.next_boss_blind = "bl_water"
	local session = Simulator.begin_round(state, 1e9, "Boss")
	return state, session
end
local sold_state, sold_session = luchador(false)
assert(#sold_state.jokers == 0 and sold_state.money == 2 and sold_state.boss_blind == nil
	and sold_session.discards_left > 0, "the Expert sells Luchador and The Water is disabled")
local kept_state, kept_session = luchador(true)
assert(#kept_state.jokers == 1 and kept_state.boss_blind == "bl_water" and kept_session.discards_left == 0,
	"a policy may keep it")

-- Perkeo: at the end of the shop, a Negative copy of a held consumable (its own
-- slot, given back when it leaves).
local perkeo = group_b_state(base, "PERKEO", { "j_perkeo" })
perkeo.consumables = { { type = "deck_tool", key = "c_hermit", set = "Tarot", effect = "money", multiplier = 1, cap = 20, cost = 3 } }
local perkeo_report = Simulator.visit_shop(perkeo, {})
assert(not perkeo_report.reroll_requested and #perkeo.consumables == 2 and perkeo.consumables[2].negative
	and perkeo.consumable_limit == 3, "Perkeo adds a Negative copy and its slot")
local released
local seller = group_b_state(shop_player(function(state, ctx)
	if #state.consumables == 2 then
		return find_action(ctx, { type = "sell_consumable", index = 2 }) or 1
	end
	released = state.consumable_limit
	return 1
end), "PERKEO-SELL", {})
seller.consumables = perkeo.consumables
seller.consumable_limit = 3
Simulator.visit_shop(seller, {})
assert(released == 2, "selling the Negative copy gives its slot back: " .. tostring(released))

---------------------------------------------------------------------------
-- 9. Vanilla Jokers group A (card.lua calculate_joker, game.lua P_CENTERS).
---------------------------------------------------------------------------

local group_a_keys = {
	"j_bloodstone", "j_hanging_chad", "j_glass", "j_campfire", "j_flash",
	"j_burnt", "j_dna", "j_chicot", "j_caino",
}
local group_a_centers = {}
for index, key in ipairs(group_a_keys) do group_a_centers[index] = { key = key } end
local group_a_catalog = base.Content.build({ Joker = group_a_centers }, {})
assert(#group_a_catalog.jokers == #group_a_keys and not group_a_catalog.unsupported.Joker,
	"every group A Joker has a simulator adapter")
local group_a = {}
for _, joker in ipairs(group_a_catalog.jokers) do group_a[joker.key] = joker end

-- A state whose catalog also has the group A Jokers, each at its starting value.
local function group_a_state(modules, seed, jokers, options)
	local state = new_state(modules, seed, jokers, options)
	for _, joker in ipairs(group_a_catalog.jokers) do
		state.joker_effects[joker.key] = joker.effect
		state.joker_pool[#state.joker_pool + 1] = joker
	end
	for _, key in ipairs(state.jokers) do
		local effect = state.joker_effects[key]
		state.joker_state[key] = effect and effect.initial or 0
	end
	return state
end

local function score_with(jokers, cards, joker_state)
	local effects = {}
	for _, key in ipairs(jokers) do
		effects[key] = group_a[key] and group_a[key].effect or nil
	end
	effects.j_blueprint = { kind = "copy_joker", mode = "right" }
	return base.Evaluator.evaluate(cards, nil, jokers, { joker_effects = effects, joker_state = joker_state or {} })
end

-- Hanging Chad: the first scoring card triggers 2 more times; Blueprint copies it.
assert(score_with({ "j_hanging_chad" }, { card(9) }).chips == 5 + 9 * 3, "Hanging Chad retriggers twice")
assert(score_with({ "j_blueprint", "j_hanging_chad" }, { card(9) }).chips == 5 + 9 * 5,
	"Blueprint copying Hanging Chad retriggers twice more")

-- Bloodstone: 1 in 2 for X1.5 per scored Heart (expected X1.25).
assert(math.abs(score_with({ "j_bloodstone" }, { card(9, "Hearts") }).mult - 1.25) < 1e-9,
	"Bloodstone: expected X1.25 per Heart")

-- Glass Joker / Campfire / Caino score their grown XMult, Flash Card its Mult.
assert(score_with({ "j_glass" }, { card(9) }, { j_glass = 2.5 }).mult == 2.5, "Glass Joker scores its XMult")
assert(score_with({ "j_blueprint", "j_campfire" }, { card(9) }, { j_campfire = 2 }).mult == 4,
	"Blueprint copies Campfire's XMult")
assert(score_with({ "j_flash" }, { card(9) }, { j_flash = 6 }).mult == 7, "Flash Card scores its Mult")

-- Glass Joker +X0.75 and Caino +X1 per shattered Glass face card.
local shatter = group_a_state(scripted(function() return { type = "play", indices = { 1, 2, 3, 4, 5 } } end),
	"GLASS-JOKER", { "j_glass", "j_caino" })
shatter.deck = deck_of(30, 13, { enhancement = "m_glass" })
for _ = 1, 4 do   -- a few rounds, so some Glass Card shatters
	local shatter_session = Simulator.begin_round(shatter, nil, "Small")
	while not shatter_session.finished do Simulator.step_round(shatter_session) end
end
local shattered = 0
for _, decision in ipairs(shatter.decisions) do
	if decision.type == "glass_shattered" then shattered = shattered + 1 end
end
assert(shattered > 0, "the test run shatters a Glass Card")
assert(math.abs(shatter.joker_state.j_glass - (1 + 0.75 * shattered)) < 1e-9
	and shatter.joker_state.j_caino == 1 + shattered,
	"Glass Joker and Caino grow per shattered Glass King: " .. tostring(shatter.joker_state.j_glass))

-- Campfire: +X0.25 per card sold (not itself), back to X1 after a Boss Blind.
local campfire = group_a_state(shop_player(function(_, ctx)
	return find_action(ctx, { type = "sell_joker", key = "j_joker" }) or 1
end), "CAMPFIRE", { "j_campfire", "j_joker" }, { money = 0 })
Simulator.visit_shop(campfire, { "v_blank" })
assert(campfire.joker_state.j_campfire == 1.25, "Campfire grows when a Joker is sold")
local boss_session = Simulator.begin_round(campfire, nil, "Boss", "PvP")
Simulator.finish_round(boss_session)
assert(campfire.joker_state.j_campfire == 1, "Campfire resets when a Boss Blind is defeated")

-- Flash Card: +2 Mult per reroll.
local flash = group_a_state(base, "FLASH", { "j_flash" }, { money = 20 })
assert(Simulator.pay_reroll(flash, 5) and Simulator.pay_reroll(flash, 6))
assert(flash.joker_state.j_flash == 4, "Flash Card grows by 2 per reroll")

-- Burnt Joker: only the first discard of the round levels its hand; Blueprint again.
local burnt = group_a_state(scripted(function(_, turn)
	if turn <= 2 then return { type = "discard", indices = { 1, 2 } } end
	return { type = "play", indices = { 1 } }
end), "BURNT", { "j_blueprint", "j_burnt" })
burnt.deck = deck_of(20, 13)
Simulator.step_round(Simulator.begin_round(burnt, nil, "Small"))
assert(burnt.levels.Pair == 3, "Burnt Joker and its copy level the first discarded Pair: " .. burnt.levels.Pair)

-- DNA: a single card played as the first hand is copied into deck and hand.
local dna = group_a_state(scripted(play_first), "DNA", { "j_dna" })
dna.deck = deck_of(20, 9)
local dna_session = Simulator.begin_round(dna, nil, "Small")
Simulator.step_round(dna_session)
assert(#dna.deck == 21 and dna.cards_added == 1, "DNA copies the single played card")
Simulator.step_round(dna_session)
assert(#dna.deck == 21, "DNA copies only on the first hand")

-- Chicot: the Boss Blind is disabled (The Needle keeps all hands, The Manacle the hand size).
local chicot = group_a_state(scripted(play_first), "CHICOT", { "j_chicot" })
chicot.next_boss_blind = "bl_needle"
local chicot_session = Simulator.begin_round(chicot, 10000, "Boss")
assert(chicot_session.hands_left == 4 and chicot.boss_blind == nil, "Chicot disables The Needle")
local chicot_manacle = group_a_state(scripted(play_first), "CHICOT-MANACLE", { "j_chicot" })
chicot_manacle.next_boss_blind = "bl_manacle"
Simulator.begin_round(chicot_manacle, 10000, "Boss")
assert(#chicot_manacle.hand == 8, "Chicot undoes The Manacle's -1 hand size")
local needle = group_a_state(scripted(play_first), "NO-CHICOT", { "j_joker" })
needle.next_boss_blind = "bl_needle"
assert(Simulator.begin_round(needle, 10000, "Boss").hands_left == 1, "without Chicot The Needle allows one hand")

---------------------------------------------------------------------------
-- 10. Vanilla Jokers group C (card.lua calculate_joker, game.lua P_CENTERS).
---------------------------------------------------------------------------

local function one_hand(jokers, hand, setup, script)
	local state = new_state(scripted(script or play_first), "GROUP-C", jokers)
	if setup then setup(state) end
	local session = Simulator.begin_round(state, nil, "Small")
	state.hand = hand
	Simulator.step_round(session)
	return state, session.hands[1].hand_score, session
end

-- Triboulet: X2 per scoring King or Queen; Blueprint copies it.
local _, tribo = one_hand({ "j_triboulet" }, { card(13), card(5, "Hearts") })
assert(tribo == 15 * 2, "Triboulet doubles a King: " .. tribo)
local _, tribo_copy = one_hand({ "j_blueprint", "j_triboulet" }, { card(13), card(5, "Hearts") })
assert(tribo_copy == 15 * 4, "Blueprint copies Triboulet: " .. tribo_copy)

-- Seltzer: retriggers played cards, one charge per hand, drunk at the last.
local seltzer, seltzer_score = one_hand({ "j_selzer" }, { card(9), card(5, "Hearts") },
	function(state) state.joker_state.j_selzer = 10 end)
assert(seltzer_score == 5 + 9 + 9 and seltzer.joker_state.j_selzer == 9, "Seltzer retriggers: " .. seltzer_score)
local drunk = one_hand({ "j_selzer" }, { card(9), card(5, "Hearts") },
	function(state) state.joker_state.j_selzer = 1 end)
assert(#drunk.jokers == 0, "Seltzer is gone after its last hand")

-- Throwback: X0.25 per Blind skipped.
local _, throwback = one_hand({ "j_throwback" }, { card(9), card(5, "Hearts") },
	function(state) state.skips = 2 end)
assert(throwback == math.floor(14 * 1.5), "Throwback with 2 skips: " .. throwback)

-- Golden Ticket: $4 per scoring Gold card trigger (Red Seal pays twice).
local ticket = one_hand({ "j_ticket" }, { card(5, "Hearts", { enhancement = "m_gold", seal = "Red" }) },
	function(state) state.money = 0 end)
assert(ticket.money == 8, "Golden Ticket pays per trigger: " .. ticket.money)

-- Turtle Bean: +5 hand size, -1 per round, eaten at 0.
local bean = new_state(scripted(play_first), "BEAN", { "j_turtle_bean" })
bean.joker_state.j_turtle_bean = 5
local bean_session = Simulator.begin_round(bean, nil, "Small")
assert(#bean.hand == 13, "Turtle Bean draws 13 cards: " .. #bean.hand)
Simulator.finish_round(bean_session)
assert(bean.joker_state.j_turtle_bean == 4, "Turtle Bean loses 1 hand size per round")

-- Vampire: removes the enhancements before scoring and gains X0.1 for each.
local mult_nine, bonus_nine = card(9, "Hearts", { enhancement = "m_mult" }), card(9, "Spades", { enhancement = "m_bonus" })
local vampire, vampire_score = one_hand({ "j_vampire" }, { mult_nine, bonus_nine },
	function(state) state.joker_state.j_vampire = 1 end,
	function() return { type = "play", indices = { 1, 2 } } end)
assert(vampire_score == math.floor(28 * 2 * 1.2) and math.abs(vampire.joker_state.j_vampire - 1.2) < 1e-9
	and mult_nine.enhancement == nil and bonus_nine.enhancement == nil,
	"Vampire takes two enhancements: " .. vampire_score)

-- Yorick: X1 more every 23 cards discarded.
local yorick = new_state(scripted(function(_, turn)
	if turn == 1 then return { type = "discard", indices = { 1, 2, 3 } } end
	return { type = "play", indices = { 1 } }
end), "YORICK", { "j_yorick" })
yorick.deck = deck_of(20, 9)
yorick.joker_state.j_yorick = 1
yorick.joker_counters = { j_yorick = 3 }
local yorick_session = Simulator.begin_round(yorick, nil, "Small")
Simulator.step_round(yorick_session)
assert(yorick.joker_state.j_yorick == 2 and yorick.joker_counters.j_yorick == 23
	and yorick_session.hands[1].hand_score == 14 * 2, "Yorick gains X1 at the 23rd discard")

-- Satellite: $1 per unique Planet card used this run.
local function cash_out(jokers)
	local state = new_state(base, "SATELLITE", jokers, { money = 0 })
	state.planet_keys_used = { c_pluto = true, c_mercury = true }
	Simulator.award_blind(state, "Small", { cleared = true, hands_left = 0, score = 1 })
	return state.money
end
assert(cash_out({ "j_satellite" }) == cash_out({}) + 2, "Satellite pays $2 for two Planets")

print("simulator_rules_spec: ok")
