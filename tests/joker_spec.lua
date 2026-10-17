local Cards = dofile("bot/cards.lua")
local Content = dofile("bot/content.lua")
local Evaluator = dofile("bot/evaluator.lua")

local function card(rank, suit, enhancement)
	return { rank = rank, suit = suit, chips = Cards.chips(rank), enhancement = enhancement }
end

local effects = {}
local defaults = Content.defaults()
for _, joker in ipairs(defaults.jokers) do effects[joker.key] = joker.effect end
assert(#defaults.jokers >= 65, "the built-in Joker catalog should cover substantially more than the starter set")

local function score(cards, jokers, extra)
	local context = {
		joker_effects = effects,
		joker_state = {},
		discards_left = 3,
		hands_left = 4,
		hand_usage = {},
		round_hand_usage = {},
		joker_rarities = {},
		joker_sell_values = {},
		full_deck = cards,
	}
	for key, value in pairs(extra or {}) do context[key] = value end
	return Evaluator.evaluate(cards, {}, jokers or {}, context).score
end

local ace = { card(14, "Spades") }
assert(score(ace, { "j_fibonacci" }) > score(ace), "Fibonacci should score supported ranks")
assert(score(ace, { "j_scholar" }) > score(ace), "Scholar should buff Aces")

local face = { card(13, "Hearts") }
assert(score(face, { "j_scary_face" }) > score(face), "Scary Face should add face-card chips")
assert(score(face, { "j_photograph" }) == score(face) * 2, "Photograph should double the first scoring face")
assert(score(ace, { "j_pareidolia", "j_scary_face", "j_photograph" })
	> score(ace, { "j_scary_face", "j_photograph" }),
	"Pareidolia should make every scoring card activate face-card Jokers")

assert(score(ace, { "j_bull" }, { money = 20 }) > score(ace, { "j_bull" }, { money = 0 }),
	"Bull should value current money")
local dusk_early = score(face, { "j_photograph", "j_dusk" }, { hands_left = 2 })
local dusk_last = score(face, { "j_photograph", "j_dusk" }, { hands_left = 1 })
assert(dusk_last > dusk_early * 2,
	"Dusk should retrigger the scoring card and its Photograph trigger on the final hand")
assert(score(ace, { "j_blue_joker" }, { deck_remaining = 30 }) > score(ace, { "j_blue_joker" }, { deck_remaining = 5 }),
	"Blue Joker should value cards remaining in the deck")
assert(score(ace, { "j_supernova" }, { hand_usage = { ["High Card"] = 8 } })
	> score(ace, { "j_supernova" }, { hand_usage = {} }), "Supernova should use persistent hand history")

local straight = { card(2, "Spades"), card(3, "Hearts"), card(4, "Clubs"), card(5, "Diamonds"), card(6, "Spades") }
assert(score(straight, { "j_hack" }) > score(straight),
	"Hack should retrigger each scoring 2, 3, 4, and 5")
assert(score(straight, { "j_blueprint", "j_hack" }) > score(straight, { "j_hack" }),
	"Blueprint should copy Hack's rank-specific retriggers")
assert(score(straight, { "j_runner" }, { joker_state = { j_runner = 45 } }) > score(straight),
	"Runner should apply accumulated Straight chips")
assert(score(straight, { "j_order" }) == score(straight) * 3, "The Order Joker should apply its Straight X Mult")
assert(score(straight, { "j_card_sharp" }, { round_hand_usage = { Straight = 1 } }) == score(straight) * 3,
	"Card Sharp should recognize a repeated hand this round")

assert(score(ace, { "j_hologram" }, { joker_state = { j_hologram = 2 } }) == score(ace) * 2,
	"Hologram should scale with cards added to the deck")
assert(score(ace, { "j_blueprint", "j_joker" }) == score(ace, { "j_joker", "j_joker" }),
	"Blueprint should copy the Joker immediately to its right")
assert(score(ace, { "j_joker", "j_brainstorm" }) == score(ace, { "j_joker", "j_joker" }),
	"Brainstorm should copy the leftmost Joker")
assert(score(ace, { "j_joker", "j_blueprint", "j_brainstorm" }) == score(ace, { "j_joker", "j_joker", "j_joker" }),
	"Blueprint should be able to copy Brainstorm's resolved leftmost effect")

local function assert_cached_copy_score(cards, jokers, extra)
	local context = {
		joker_effects = effects,
		joker_state = {},
		discards_left = 3,
		hands_left = 4,
		hand_usage = {},
		round_hand_usage = {},
		joker_rarities = {},
		joker_sell_values = {},
		full_deck = cards,
	}
	for key, value in pairs(extra or {}) do context[key] = value end
	local expected = Evaluator.evaluate(cards, {}, jokers, context)
	context.resolved_jokers = Evaluator.resolve_jokers(jokers, effects)
	local actual = Evaluator.evaluate(cards, {}, jokers, context)
	assert(actual.name == expected.name and actual.strength == expected.strength
		and actual.chips == expected.chips and actual.mult == expected.mult and actual.score == expected.score,
		"pre-resolved copy effects must preserve results for " .. table.concat(jokers, ","))
end

assert_cached_copy_score(straight, { "j_blueprint", "j_runner", "j_cavendish" }, {
	joker_state = { j_runner = 45 },
})
assert_cached_copy_score(ace, { "j_joker", "j_blueprint", "j_brainstorm" })
assert_cached_copy_score(ace, { "j_brainstorm", "j_blueprint", "j_joker" })

assert(score(ace, { "j_joker", "j_cavendish" }) > score(ace, { "j_cavendish", "j_joker" }),
	"additive Mult before XMult should outscore the reversed Joker order")
assert(score(ace, { "j_joker" }, { joker_editions = { j_joker = "polychrome" } })
	> score(ace, { "j_joker" }), "Polychrome Joker editions must affect score")
assert(score(ace, {}, { held_cards = { card(2, "Hearts", "m_steel") } }) > score(ace),
	"held Steel cards must apply their X Mult")
assert(score(ace, { "j_constellation" }, { joker_state = { j_constellation = 2 } }) == score(ace) * 2,
	"Constellation should scale with used Planets")
assert(score(ace, { "j_loyalty_card" }, { joker_state = { j_loyalty_card = 2 }, hands_played = 17 }) == score(ace),
	"Loyalty Card must not inherit hands played before it was acquired")
assert(score(ace, { "j_loyalty_card" }, { joker_state = { j_loyalty_card = 1 } }) == score(ace) * 4,
	"Loyalty Card should apply X4 on the sixth hand of its own countdown")

local steel_deck = { card(14, "Spades"), card(2, "Hearts", "m_steel"), card(3, "Clubs", "m_steel") }
assert(score(ace, { "j_steel_joker" }, { full_deck = steel_deck }) > score(ace),
	"Steel Joker should inspect enhancements in the persistent deck")
assert(score(ace, { "j_stuntman" }) > score(ace), "Stuntman should provide its flat chip bonus")
assert(score(ace, { "j_stencil" }, { joker_limit = 5 }) == score(ace) * 5,
	"a lone Joker Stencil should count its own slot as empty")
assert(score(ace, { "j_baron" }, { held_cards = { card(13, "Hearts"), card(13, "Clubs") } })
	> score(ace), "Baron should apply X Mult for held Kings")
local two_pair = { card(8, "Spades"), card(8, "Hearts"), card(3, "Clubs"), card(3, "Diamonds") }
assert(score(two_pair, { "j_trousers" }, { joker_state = { j_trousers = 6 } }) > score(two_pair),
	"Spare Trousers should apply its persistent Two Pair scaling")
local splash_hand = { card(14, "Spades"), card(13, "Hearts"), card(2, "Clubs") }
assert(score(splash_hand, { "j_splash" }) > score(splash_hand),
	"Splash should score every submitted card")
assert(score(splash_hand, { "j_blueprint", "j_splash" }) == score(splash_hand, { "j_splash", "j_splash" }),
	"Blueprint should copy Splash before scoring cards are selected")

local pacifist_effects = { j_mp_pacifist = { kind = "non_pvp_xmult", amount = 10 } }
local pacifist_normal = Evaluator.evaluate(ace, {}, { "j_mp_pacifist" }, {
	joker_effects = pacifist_effects, joker_state = {}, is_pvp = false,
}).score
local pacifist_pvp = Evaluator.evaluate(ace, {}, { "j_mp_pacifist" }, {
	joker_effects = pacifist_effects, joker_state = {}, is_pvp = true,
}).score
assert(pacifist_normal == pacifist_pvp * 10,
	"Pacifist should apply X10 outside PvP and become inert during a PvP Blind")

local ancient_context = {
	joker_effects = { j_ancient = { kind = "rotating_suit_xmult", amount = 1.5 } },
	joker_state = {}, joker_targets = { j_ancient = "Hearts" },
}
assert(Evaluator.evaluate(face, {}, { "j_ancient" }, ancient_context).score > score(face),
	"Ancient Joker should multiply cards matching its current suit")
	local castle_score = Evaluator.evaluate(ace, {}, { "j_castle" }, {
		joker_effects = { j_castle = { kind = "discard_suit_scaling_chips", initial = 0 } },
		joker_state = { j_castle = 30 },
	}).score
assert(castle_score > score(ace),
	"Castle should apply accumulated discard chips")
	local madness_score = Evaluator.evaluate(ace, {}, { "j_madness" }, {
		joker_effects = { j_madness = { kind = "blind_scaling_xmult", initial = 1 } },
		joker_state = { j_madness = 2 },
	}).score
assert(madness_score == score(ace) * 2,
	"Madness should apply its accumulated X Mult")

print("joker_spec: ok")
