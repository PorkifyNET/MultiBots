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
-- 4. Shop rules: rerolls and debt (functions/button_callbacks.lua).
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

print("simulator_rules_spec: ok")
