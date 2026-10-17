local Cards = dofile("bot/cards.lua")
local Evaluator = dofile("bot/evaluator.lua")

local function card(rank, suit)
	return { rank = rank, suit = suit, chips = Cards.chips(rank) }
end

local cases = {
	{ "Five of a Kind", { card(9, "Hearts"), card(9, "Spades"), card(9, "Clubs"), card(9, "Diamonds"), card(9, "Hearts") } },
	{ "Straight Flush", { card(10, "Hearts"), card(11, "Hearts"), card(12, "Hearts"), card(13, "Hearts"), card(14, "Hearts") } },
	{ "Four of a Kind", { card(9, "Hearts"), card(9, "Spades"), card(9, "Clubs"), card(9, "Diamonds"), card(2, "Hearts") } },
	{ "Full House", { card(8, "Hearts"), card(8, "Spades"), card(8, "Clubs"), card(4, "Diamonds"), card(4, "Hearts") } },
	{ "Flush", { card(2, "Clubs"), card(5, "Clubs"), card(8, "Clubs"), card(11, "Clubs"), card(14, "Clubs") } },
	{ "Straight", { card(14, "Clubs"), card(2, "Hearts"), card(3, "Spades"), card(4, "Clubs"), card(5, "Diamonds") } },
	{ "Three of a Kind", { card(7, "Clubs"), card(7, "Hearts"), card(7, "Spades"), card(2, "Clubs"), card(4, "Diamonds") } },
	{ "Two Pair", { card(6, "Clubs"), card(6, "Hearts"), card(3, "Spades"), card(3, "Clubs"), card(12, "Diamonds") } },
	{ "Pair", { card(13, "Clubs"), card(13, "Hearts"), card(2, "Spades"), card(5, "Clubs"), card(8, "Diamonds") } },
	{ "High Card", { card(14, "Clubs"), card(12, "Hearts"), card(9, "Spades"), card(5, "Clubs"), card(2, "Diamonds") } },
}

for _, case in ipairs(cases) do
	local result = Evaluator.evaluate(case[2], {}, {}, { discards_left = 3 })
	assert(result.name == case[1], "expected " .. case[1] .. ", got " .. result.name)
	assert(result.score > 0, case[1] .. " should score")
end

local base = Evaluator.evaluate({ card(14, "Spades") }, {}, {}, { discards_left = 3 })
local joker = Evaluator.evaluate({ card(14, "Spades") }, {}, { "j_joker" }, { discards_left = 3 })
assert(joker.score > base.score, "Joker should improve the score")

local adapted = Evaluator.evaluate({ card(14, "Spades") }, {}, { "j_custom" }, {
	discards_left = 3,
	joker_effects = { j_custom = { kind = "flat_mult", amount = 20 } },
})
assert(adapted.score > joker.score, "registered headless effects should participate in scoring")

local pair_cards = { card(8, "Hearts"), card(8, "Spades") }
local stone = card(14, "Clubs")
stone.enhancement = "m_stone"
local pair_score = Evaluator.evaluate(pair_cards, {}, {}, {})
local stone_score = Evaluator.evaluate({ pair_cards[1], pair_cards[2], stone }, {}, {}, {})
assert(stone_score.name == "Pair" and stone_score.score == pair_score.score + 100,
	"Stone cards should always score 50 Chips without changing the poker hand")

local held_king = card(13, "Hearts")
held_king.enhancement = "m_steel"
local held_context = {
	held_cards = { held_king },
	joker_effects = {
		j_baron = { kind = "held_rank_xmult", rank = 13, amount = 1.5 },
		j_mime = { kind = "held_retrigger" },
	},
}
local baron_score = Evaluator.evaluate({ card(14, "Spades") }, {}, { "j_baron" }, held_context)
local mime_score = Evaluator.evaluate({ card(14, "Spades") }, {}, { "j_baron", "j_mime" }, held_context)
assert(math.abs(mime_score.score - baron_score.score * 2.25) < 0.001,
	"Mime should retrigger both a held Steel card and Baron's held-King effect")

local heart = { card(14, "Hearts") }
local heart_base = Evaluator.evaluate(heart, {}, {}, {})
local bloodstone = Evaluator.evaluate(heart, {}, { "j_mp_bloodstone" }, {
	joker_effects = {
		j_mp_bloodstone = { kind = "chance_suit_xmult", suit = "Hearts", chance = 0.5, amount = 1.5 },
	},
})
assert(math.abs(bloodstone.score - heart_base.score * 1.25) < 0.001,
	"Bloodstone should model each Heart trigger at its expected XMult value")

local smeared_flush = {
	card(2, "Hearts"), card(5, "Diamonds"), card(8, "Hearts"),
	card(11, "Diamonds"), card(14, "Hearts"),
}
assert(Evaluator.evaluate(smeared_flush, {}, {}, {}).name == "High Card",
	"mixed red suits should not naturally form a Flush")
assert(Evaluator.evaluate(smeared_flush, {}, { "j_smeared" }, {
	joker_effects = { j_smeared = { kind = "suit_merge" } },
}).name == "Flush", "Smeared Joker should merge Hearts with Diamonds for Flush detection")

local shortcut_cards = {
	card(2, "Hearts"), card(4, "Spades"), card(6, "Clubs"),
	card(8, "Diamonds"), card(10, "Hearts"),
}
assert(Evaluator.evaluate(shortcut_cards, {}, {}, {}).name == "High Card",
	"one-rank gaps should not form a natural Straight")
local shortcut = Evaluator.evaluate(shortcut_cards, {}, { "j_shortcut" }, {
	joker_effects = { j_shortcut = { kind = "straight_gaps" } },
})
assert(shortcut.name == "Straight", "Shortcut should permit one-rank gaps between Straight cards")

local four_finger_straight = {
	card(3, "Hearts"), card(4, "Spades"), card(5, "Clubs"), card(6, "Diamonds"),
}
assert(Evaluator.evaluate(four_finger_straight, {}, {}, {}).name == "High Card",
	"four cards should not naturally form a Straight")
assert(Evaluator.evaluate(four_finger_straight, {}, { "j_four_fingers" }, {
	joker_effects = { j_four_fingers = { kind = "four_card_hands" } },
}).name == "Straight", "Four Fingers should permit a four-card Straight")

local chad_cards = {
	card(2, "Hearts"), card(3, "Spades"), card(4, "Clubs"),
	card(5, "Diamonds"), card(6, "Hearts"),
}
local chad_base = Evaluator.evaluate(chad_cards, {}, {}, {})
local chad = Evaluator.evaluate(chad_cards, {}, { "j_mp_hanging_chad" }, {
	joker_effects = { j_mp_hanging_chad = {
		kind = "first_scoring_retrigger", cards = 2, repetitions = 1,
	} },
})
assert(chad.score > chad_base.score,
	"Multiplayer Hanging Chad should retrigger the first two scoring cards")

local red_card = Evaluator.evaluate(heart, {}, { "j_red_card" }, {
	joker_effects = { j_red_card = { kind = "skipped_pack_scaling_mult", amount = 3 } },
	joker_state = { j_red_card = 6 },
})
assert(red_card.mult == heart_base.mult + 6,
	"Red Card should add its accumulated skipped-Booster Mult")

local flower_cards = {
	card(8, "Hearts"), card(8, "Spades"), card(3, "Clubs"), card(3, "Hearts"),
}
flower_cards[4].enhancement = "m_wild"
local flower_base = Evaluator.evaluate(flower_cards, {}, {}, {})
local flower_score = Evaluator.evaluate(flower_cards, {}, { "j_flower_pot" }, {
	joker_effects = { j_flower_pot = { kind = "scoring_suits_xmult", count = 4, amount = 3 } },
})
assert(math.abs(flower_score.score - flower_base.score * 3) < 0.001,
	"a scoring Wild card should provide Flower Pot's missing suits")

local face = { card(13, "Hearts") }
local low = { card(10, "Hearts") }
local face_base = Evaluator.evaluate(face, {}, {}, {})
local low_base = Evaluator.evaluate(low, {}, {}, {})
local sock_context = { joker_effects = {
	j_sock_and_buskin = { kind = "face_retrigger", repetitions = 1 },
} }
assert(Evaluator.evaluate(face, {}, { "j_sock_and_buskin" }, sock_context).score > face_base.score,
	"Sock and Buskin should retrigger scoring face cards")
assert(Evaluator.evaluate(low, {}, { "j_sock_and_buskin" }, sock_context).score == low_base.score,
	"Sock and Buskin should not retrigger non-face cards")
sock_context.joker_effects.j_pareidolia = { kind = "all_faces" }
assert(Evaluator.evaluate(low, {}, { "j_pareidolia", "j_sock_and_buskin" }, sock_context).score > low_base.score,
	"Pareidolia should make non-face cards eligible for Sock and Buskin")

print("evaluator_spec: ok")
