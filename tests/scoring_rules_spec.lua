-- balatro-brain patch: hand scoring follows the game's evaluate_play
-- (functions/state_events.lua, card.lua). Every expected number below is worked
-- out by hand from the vanilla rules.
local Cards = dofile("bot/cards.lua")
local Content = dofile("bot/content.lua")
local Evaluator = dofile("bot/evaluator.lua")

local effects, rarities = {}, {}
for _, joker in ipairs(Content.defaults().jokers) do
	effects[joker.key] = joker.effect
	rarities[joker.key] = joker.rarity
end

local function card(rank, suit, extra)
	local result = { rank = rank, suit = suit, chips = Cards.chips(rank) }
	for key, value in pairs(extra or {}) do result[key] = value end
	return result
end
local function score(cards, jokers, context)
	context = context or {}
	context.joker_effects = context.joker_effects or effects
	context.joker_rarities = context.joker_rarities or rarities
	return Evaluator.evaluate(cards, {}, jokers or {}, context)
end
local function near(a, b) return math.abs(a - b) < 1e-6 end

-- Red Seal retriggers a scoring card: a red-sealed Glass card doubles twice.
local flush = { card(2, "Hearts"), card(4, "Hearts"), card(6, "Hearts"), card(8, "Hearts"),
	card(10, "Hearts", { enhancement = "m_glass", seal = "Red" }) }
local red = score(flush)
assert(red.name == "Flush" and near(red.mult, 16) and red.chips == 35 + 30 + 10,
	"a Red Seal should score its card twice (Glass x2 twice, chips twice)")

-- Per-card Joker bonuses apply as each card scores, before later cards and held Steel.
local aces = { card(14, "Hearts"), card(14, "Spades") }
local fib = score(aces, { "j_fibonacci" }, { held_cards = { card(9, "Clubs", { enhancement = "m_steel" }) } })
assert(near(fib.mult, 27) and fib.score == 864, "Fibonacci adds before held Steel x1.5: (2+8+8)*1.5")
local lusty_flush = { card(2, "Hearts"), card(4, "Hearts"), card(6, "Hearts"), card(8, "Hearts"),
	card(10, "Hearts", { enhancement = "m_glass" }) }
local lusty = score(lusty_flush, { "j_lusty_joker" })
assert(near(lusty.mult, 35), "Lusty Joker on the cards before a Glass card is doubled: (4+3*4)*2+3")

-- Baron (held Kings) multiplies before any Joker's main effect.
local fives = { card(5, "Hearts"), card(5, "Spades") }
local kings = { card(13, "Clubs"), card(13, "Diamonds") }
local baron = score(fives, { "j_joker", "j_jolly", "j_baron" }, { held_cards = kings })
assert(near(baron.mult, 16.5) and baron.score == 330, "Baron: 2*1.5*1.5, then Joker +4 and Jolly +8")

-- Photograph applies when the first face card scores, not at its slot.
local face_pair = { card(12, "Hearts"), card(12, "Spades") }
local photo = score(face_pair, { "j_photograph", "j_joker" })
assert(near(photo.mult, 2 * 2 + 4), "Photograph x2 on the first Queen, then Joker +4")

-- The secret hands.
local five_aces = { card(14, "Hearts"), card(14, "Spades"), card(14, "Clubs"), card(14, "Diamonds"), card(14, "Hearts") }
local five = score(five_aces)
assert(five.name == "Five of a Kind" and five.score == (120 + 55) * 12, "Five of a Kind")
assert(five.contained["Four of a Kind"] and five.contained["Pair"] and not five.contained["Two Pair"],
	"Five of a Kind contains Four/Three of a Kind and a Pair, not Two Pair")
local flush_house = { card(7, "Diamonds"), card(7, "Diamonds"), card(7, "Diamonds"), card(4, "Diamonds"), card(4, "Diamonds") }
assert(score(flush_house).name == "Flush House", "Flush House")
local flush_five = { card(14, "Spades"), card(14, "Spades"), card(14, "Spades"), card(14, "Spades"), card(14, "Spades") }
assert(score(flush_five).name == "Flush Five", "Flush Five")

-- A Flush with two equal ranks contains a Pair (Duo x2).
local pair_flush = { card(2, "Hearts"), card(2, "Clubs", { enhancement = "m_wild" }), card(5, "Hearts"),
	card(9, "Hearts"), card(13, "Hearts") }
local duo = score(pair_flush, { "j_duo" })
assert(duo.name == "Flush" and near(duo.mult, 8), "Duo should double a Flush that contains a Pair")
local four = score({ card(9, "Hearts"), card(9, "Spades"), card(9, "Clubs"), card(9, "Diamonds") }, { "j_mad" })
assert(near(four.mult, 7), "Four of a Kind does not contain Two Pair (Mad Joker)")

-- Joker foil/holo apply before the Joker's effect, polychrome after.
local holo = score({ card(14, "Hearts") }, { "j_cavendish" }, {
	joker_editions = { j_cavendish = "holo" },
})
assert(near(holo.mult, (1 + 10) * 3), "holo +10 Mult comes before Cavendish's x3")

-- Raised Fist uses the card value (King = 10).
local fist = score({ card(14, "Hearts") }, { "j_raised_fist" }, { held_cards = { card(13, "Clubs"), card(14, "Clubs") } })
assert(near(fist.mult, 1 + 20), "Raised Fist doubles the lowest held card's value")
local fist_mime = score({ card(14, "Hearts") }, { "j_raised_fist", "j_mime" },
	{ held_cards = { card(3, "Clubs"), card(3, "Spades") } })
assert(near(fist_mime.mult, 1 + 6 + 6), "Raised Fist picks one lowest card (the last); Mime retriggers it")

-- Stone cards have no rank or suit for Jokers.
local stone_ace = card(14, "Hearts", { enhancement = "m_stone" })
local scholar = score({ stone_ace }, { "j_scholar", "j_lusty_joker" })
assert(scholar.chips == 5 + 50 and near(scholar.mult, 1), "a Stone card is not an Ace or a Heart")
local board = score({ card(14, "Spades") }, { "j_blackboard" }, { held_cards = { card(2, "Spades"), stone_ace } })
assert(near(board.mult, 1), "a held Stone card is neither a Spade nor a Club (Blackboard)")

-- Flower Pot: one Wild fills one missing suit; Seeing Double: Club + Wild.
local pot = score({ card(13, "Hearts"), card(13, "Spades", { enhancement = "m_wild" }) }, { "j_flower_pot" })
assert(near(pot.mult, 2), "a Wild card fills only one missing suit for Flower Pot")
local double = score({ card(13, "Clubs"), card(13, "Hearts", { enhancement = "m_wild" }) }, { "j_seeing_double" })
assert(near(double.mult, 4), "Seeing Double: Club plus a Wild card counts as another suit")

-- Baseball Card: x1.5 right after each Uncommon Joker's own effect.
local baseball = score({ card(14, "Hearts") }, { "j_baseball", "j_joker" }, {
	joker_rarities = { j_baseball = 3, j_joker = 2 },
})
assert(near(baseball.mult, (1 + 4) * 1.5), "Baseball Card acts on the Uncommon Joker")
local baseball_order = score({ card(14, "Hearts") }, { "j_joker", "j_baseball", "j_jolly" }, {
	joker_rarities = { j_baseball = 3, j_joker = 2, j_jolly = 1 },
})
assert(near(baseball_order.mult, (1 + 4) * 1.5), "Baseball multiplies at the Uncommon Joker, not at its own slot")

-- Wee Joker grows on every trigger of a 2 (Hack retriggers it).
local wee = score({ card(2, "Hearts") }, { "j_hack", "j_wee" }, { joker_state = {} })
assert(wee.chips == 5 + 2 * 2 + 16 and wee.growth.j_wee == 16, "Wee Joker +8 per trigger, twice with Hack")

-- Joker Stencil: empty slots plus every Stencil.
local stencil = score({ card(14, "Hearts") }, { "j_stencil", "j_stencil_b" }, {
	joker_effects = { j_stencil = effects.j_stencil, j_stencil_b = effects.j_stencil }, joker_limit = 5,
})
assert(near(stencil.mult, 5 * 5), "each Stencil gives x(3 empty + 2 Stencils)")

-- Hiker's +5 is seen by the same card's later triggers.
local hiker = score({ card(14, "Hearts", { seal = "Red" }) }, { "j_hiker" })
assert(hiker.chips == 5 + 11 + 16 and hiker.hiker[hiker.scoring_cards[1]] == 10,
	"Hiker: the retrigger already has +5, and the card keeps +10")

-- Gold Seal pays $3 per trigger; the score is floored, not rounded.
local gold = score({ card(14, "Hearts", { seal = "Gold" }) }, { "j_hack" })
assert(gold.dollars == 3, "a Gold Seal pays $3 when scored")
local lucky = score({ card(3, "Hearts", { enhancement = "m_lucky" }) })
assert(lucky.score == math.floor((5 + 3) * (1 + 4)), "scores are floored")

print("scoring_rules_spec: ok")
