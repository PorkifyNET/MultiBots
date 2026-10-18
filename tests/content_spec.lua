local Content = dofile("bot/content.lua")

local defaults = Content.defaults()
assert(#defaults.jokers >= 65, "default content should expose the expanded vanilla Joker adapter catalog")
local default_packs = {}
for _, key in ipairs(defaults.packs) do default_packs[key] = true end
assert(default_packs.p_spectral_normal_1 and default_packs.p_spectral_normal_2
	and default_packs.p_spectral_jumbo_1 and default_packs.p_spectral_mega_1,
	"default content should expose every vanilla Spectral Pack")
assert(Content.pack_topic("p_spectral_normal_1") == "spectrals"
	and Content.pack_topic("p_spectral_jumbo_1") == "spectrals"
	and Content.pack_topic("p_spectral_mega_1") == "spectrals",
	"Spectral Packs should appear under Spectrals / Other in How It Works")
local space_supported, chaos_supported, mime_supported, hiker_supported, credit_supported = false, false, false, false, false
local requested = {}
local generated_tarots = {}
for _, joker in ipairs(defaults.jokers) do
	if joker.key == "j_space" and joker.effect.kind == "chance_hand_level" then space_supported = true end
	if joker.key == "j_chaos" and joker.effect.kind == "free_shop_reroll" then chaos_supported = true end
	if joker.key == "j_mime" and joker.effect.kind == "held_retrigger" then mime_supported = true end
	if joker.key == "j_hiker" and joker.effect.kind == "played_card_chip_growth" then hiker_supported = true end
	if joker.key == "j_credit_card" and joker.effect.kind == "debt_limit" then credit_supported = true end
	if joker.key == "j_hallucination" or joker.key == "j_red_card"
		or joker.key == "j_shortcut" or joker.key == "j_superposition" then
		requested[joker.key] = joker.effect.kind
	end
end
for _, tool in ipairs(defaults.deck_tools) do
	if tool.key == "c_emperor" or tool.key == "c_high_priestess" or tool.key == "c_judgement"
		or tool.key == "c_fool" then
		generated_tarots[tool.key] = tool.effect
	end
end
assert(space_supported, "Space Joker should expose its probabilistic hand-level adapter")
assert(chaos_supported and mime_supported, "Chaos and Mime should expose their economy and held-card adapters")
assert(hiker_supported and credit_supported, "Hiker and Credit Card should expose scaling and debt adapters")
assert(requested.j_hallucination == "pack_tarot_chance"
	and requested.j_red_card == "skipped_pack_scaling_mult"
	and requested.j_shortcut == "straight_gaps"
	and requested.j_superposition == "straight_ace_tarot",
	"reported vanilla objects should expose their exact headless mechanics")
assert(generated_tarots.c_emperor == "generate_tarot"
	and generated_tarots.c_high_priestess == "generate_planet"
	and generated_tarots.c_judgement == "generate_joker"
	and generated_tarots.c_fool == "repeat_consumable",
	"generative Tarot cards should expose distinct headless adapters")

local pools = {
	Joker = {
		{ key = "j_jolly", cost = 7, rarity = 2, name = "Jolly Joker" },
		{ key = "j_joker", cost = 9, rarity = 1, name = "Joker" },
		{ key = "j_unmodelled", cost = 1 },
	},
	Planet = {
		{ key = "c_mercury", cost = 4, config = { hand_type = "Pair" } },
		{ key = "c_broken_planet", cost = 4, config = {} },
		{ key = "c_planet_x", cost = 4, config = { hand_type = "Five of a Kind" } },
	},
	Tarot = {
		{ key = "c_star", cost = 5 },
		{ key = "c_tower", cost = 3 },
		{ key = "c_unknown_tarot", cost = 3 },
	},
	Spectral = {
		{ key = "c_cryptid", cost = 6 },
	},
	Booster = {
		{ key = "p_celestial_jumbo_1", cost = 6 },
	},
	Voucher = {
		{ key = "v_overstock_norm", cost = 10 },
	},
}

local catalog = Content.build(pools, {}, { j_jolly = true })
assert(#catalog.jokers == 1 and catalog.jokers[1].key == "j_joker", "ruleset bans must filter adapters")
assert(catalog.jokers[1].cost == 9, "runtime center cost must replace fallback cost")
assert(catalog.jokers[1].effect.kind == "flat_mult", "Joker must retain its headless scoring adapter")
assert(#catalog.planets == 2 and catalog.planets[1].hand == "Pair"
	and catalog.planets[2].hand == "Five of a Kind", "Planet hand type must come from runtime metadata")
assert(#catalog.deck_tools == 3, "only registered deck tools in active pools should be offered")
assert(catalog.deck_tools[1].key == "c_cryptid" and catalog.deck_tools[2].key == "c_star",
	"content pools must be sorted by stable key for ordered runs")
assert(catalog.deck_tools[3].key == "c_tower", "Tower should expose its Stone enhancement adapter")

local summary = Content.summary(catalog)
assert(summary.skipped == 3, "unsupported runtime content should be counted")
assert(summary.packs == 1, "supported strategic Booster Packs should be reported separately")

Content.register_joker({
	key = "j_test_adapter", cost = 3, utility = 20,
	effect = { kind = "flat_mult", amount = 12 },
})
pools.Joker[#pools.Joker + 1] = { key = "j_test_adapter", cost = 8 }
local extended = Content.build(pools, {}, {})
local found = false
for _, offer in ipairs(extended.jokers) do
	if offer.key == "j_test_adapter" then
		found = offer.cost == 8 and offer.effect.amount == 12
	end
end
assert(found, "registered adapters must join future runtime catalogs")

local multiplayer = Content.build({
	Joker = {
		{ key = "j_mp_pacifist", cost = 4 },
		{ key = "j_mp_turtle_bean", cost = 6 },
		{ key = "j_mp_bloodstone", cost = 7 },
		{ key = "j_mp_hanging_chad", cost = 4 },
	},
}, {}, {})
assert(#multiplayer.jokers == 4, "active Multiplayer Joker centers should receive headless adapters")
local multiplayer_effects = {}
for _, joker in ipairs(multiplayer.jokers) do multiplayer_effects[joker.key] = joker.effect.kind end
assert(multiplayer_effects.j_mp_bloodstone == "chance_suit_xmult"
	and multiplayer_effects.j_mp_hanging_chad == "first_scoring_retrigger"
	and multiplayer_effects.j_mp_pacifist == "non_pvp_xmult"
	and multiplayer_effects.j_mp_turtle_bean == "decaying_hand_size",
	"Multiplayer Joker adapters should expose their distinct scoring and lifecycle effects")
for _, joker in ipairs(defaults.jokers) do
	assert(not joker.multiplayer, "generic defaults must not leak Multiplayer-only centers into vanilla simulations")
end

local reported = Content.build({
	Joker = {
		{ key = "j_hallucination", cost = 4 }, { key = "j_mp_hanging_chad", cost = 4 },
		{ key = "j_red_card", cost = 5 }, { key = "j_shortcut", cost = 7 },
		{ key = "j_superposition", cost = 4 },
	},
	Voucher = { { key = "v_blank", cost = 10 } },
}, {}, {})
assert(#reported.jokers == 5 and #reported.vouchers == 1
	and Content.summary(reported).skipped == 0,
	"all six reported runtime objects should be supported instead of logged as unknown")

local match_reported = Content.build({
	Joker = {
		{ key = "j_business", cost = 4 },
		{ key = "j_marble", cost = 6 },
		{ key = "j_astronomer", cost = 8 },
	},
	Planet = { { key = "c_mp_asteroid", cost = 3, config = {} } },
	Voucher = { { key = "v_omen_globe", cost = 10 } },
}, {}, {})
local match_effects = {}
for _, joker in ipairs(match_reported.jokers) do match_effects[joker.key] = joker.effect.kind end
assert(match_effects.j_business == "scoring_face_money"
	and match_effects.j_marble == "round_stone_card"
	and match_effects.j_astronomer == "free_planets",
	"the three reported vanilla Jokers should expose their distinct headless mechanics")
assert(#match_reported.deck_tools == 1 and match_reported.deck_tools[1].key == "c_mp_asteroid"
	and #match_reported.vouchers == 1 and match_reported.vouchers[1].key == "v_omen_globe"
	and Content.summary(match_reported).skipped == 0,
	"Asteroid and Omen Globe should be recognized without remaining in the unsupported report")

local lucky_fortune_reported = Content.build({
	Joker = {
		{ key = "j_8_ball" }, { key = "j_egg" }, { key = "j_midas_mask" },
		{ key = "j_mp_lets_go_gambling" }, { key = "j_mp_penny_pincher" },
		{ key = "j_mp_skip_off" },
		{ key = "j_obelisk" }, { key = "j_rough_gem" }, { key = "j_smeared" },
	},
	Planet = {
		{ key = "c_earth", config = { hand_type = "Full House" } },
		{ key = "c_mercury", config = { hand_type = "Pair" } },
		{ key = "c_mp_asteroid", config = {} },
		{ key = "c_neptune", config = { hand_type = "Straight Flush" } },
		{ key = "c_saturn", config = { hand_type = "Straight" } },
	},
	Voucher = { { key = "v_tarot_tycoon" } },
}, {}, {})
assert(#lucky_fortune_reported.jokers == 9 and #lucky_fortune_reported.planets == 4
	and #lucky_fortune_reported.deck_tools == 1 and #lucky_fortune_reported.vouchers == 1
	and Content.summary(lucky_fortune_reported).skipped == 0,
	"all Lucky Fortune report objects should have headless adapters")

local violet_chad_reported = Content.build({
	Joker = {
		{ key = "j_ring_master" }, { key = "j_vagabond" },
		{ key = "j_certificate" }, { key = "j_sixth_sense" },
	},
}, {}, {})
assert(#violet_chad_reported.jokers == 4 and Content.summary(violet_chad_reported).skipped == 0,
	"reported Violet Chad Jokers should have headless adapters")

local bold_hierophant_reported = Content.build({
	Spectral = { { key = "c_mp_ouija_standard", cost = 4, config = { extra = { destroy = 3 } } } },
}, {}, {})
assert(#bold_hierophant_reported.deck_tools == 1
	and bold_hierophant_reported.deck_tools[1].key == "c_mp_ouija_standard"
	and bold_hierophant_reported.deck_tools[1].destroy_count == 3
	and Content.summary(bold_hierophant_reported).skipped == 0,
	"Multiplayer Ouija should expose its three-card destruction adapter")

local jolly_midas_reported = Content.build({
	Planet = { { key = "c_planet_x", cost = 3, config = { hand_type = "Five of a Kind" } } },
	Joker = {
		{ key = "j_ancient" }, { key = "j_castle" }, { key = "j_ceremonial" },
		{ key = "j_diet_cola" }, { key = "j_four_fingers" }, { key = "j_gift" },
		{ key = "j_madness" }, { key = "j_mail" }, { key = "j_mp_pizza" },
		{ key = "j_mp_taxes" }, { key = "j_mp_ticket" }, { key = "j_oops" },
		{ key = "j_reserved_parking" }, { key = "j_seance" },
		{ key = "j_to_the_moon" }, { key = "j_trading" },
	},
	Voucher = {
		{ key = "v_magic_trick" }, { key = "v_money_tree" },
		{ key = "v_reroll_glut" }, { key = "v_tarot_merchant" },
	},
}, {}, {})
assert(#jolly_midas_reported.planets == 1 and #jolly_midas_reported.jokers == 16
	and #jolly_midas_reported.vouchers == 4 and Content.summary(jolly_midas_reported).skipped == 0,
	"all 21 Jolly Midas report objects should have headless adapters")

print("content_spec: ok")
