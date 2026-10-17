local Content = {}

local supported_joker_effects = {
	flat_mult = true,
	suit_mult = true,
	hand_mult = true,
	hand_chips = true,
	card_count_mult = true,
	joker_count_mult = true,
	discard_chips = true,
	no_discard_mult = true,
	rank_mult = true,
	rank_chips = true,
	rank_chips_mult = true,
	face_chips = true,
	face_mult = true,
	first_face_xmult = true,
	money_chips = true,
	money_step_mult = true,
	deck_remaining_chips = true,
	hand_usage_mult = true,
	last_hand_xmult = true,
	repeat_hand_xmult = true,
	held_suit_xmult = true,
	held_rank_mult = true,
	straight_scaling_chips = true,
	four_card_scaling_chips = true,
	bus_scaling_mult = true,
	green_scaling_mult = true,
	decaying_chips = true,
	decaying_mult = true,
	discard_decay_xmult = true,
	planet_scaling_xmult = true,
	tarot_scaling_mult = true,
	deck_add_scaling_xmult = true,
	other_joker_sell_mult = true,
	rarity_xmult = true,
	hand_xmult = true,
	suit_chips = true,
	suit_card_mult = true,
	enhancement_count_xmult = true,
	flat_xmult = true,
	flat_chips = true,
	held_rank_xmult = true,
	held_lowest_rank_mult = true,
	empty_slot_xmult = true,
	missing_deck_mult = true,
	stone_count_chips = true,
	enhanced_threshold_xmult = true,
	scoring_suits_xmult = true,
	mixed_suit_xmult = true,
	chance_suit_xmult = true,
	periodic_xmult = true,
	hand_scaling_mult = true,
	rank_scaling_chips = true,
	non_pvp_xmult = true,
	decaying_hand_size = true,
	played_hand_money = true,
	deck_rank_money = true,
	round_money = true,
	discard_face_money = true,
	all_played_score = true,
	retrigger_scoring = true,
	rank_retrigger = true,
	face_retrigger = true,
	round_joker_generation = true,
	round_tarot_generation = true,
	low_money_tarot = true,
	chance_hand_level = true,
	all_faces = true,
	round_resources = true,
	skip_advantage_resources = true,
	copy_joker = true,
	duplicate_shop_offers = true,
	free_shop_reroll = true,
	held_retrigger = true,
	first_scoring_retrigger = true,
	straight_gaps = true,
	skipped_pack_scaling_mult = true,
	pack_tarot_chance = true,
	straight_ace_tarot = true,
	played_card_chip_growth = true,
	debt_limit = true,
	scoring_face_money = true,
	round_stone_card = true,
	round_sealed_card = true,
	free_planets = true,
	rotating_suit_xmult = true,
	discard_suit_scaling_chips = true,
	sacrifice_scaling_mult = true,
	four_card_hands = true,
	blind_scaling_xmult = true,
	discard_rank_money = true,
	pvp_discard_food = true,
	opponent_sale_mult = true,
	scoring_enhancement_money = true,
	double_probabilities = true,
	held_face_money = true,
	straight_flush_spectral = true,
	first_six_spectral = true,
	extra_interest = true,
	single_discard_destroy = true,
	sell_value_growth = true,
	double_tag_on_sell = true,
	played_rank_planet = true,
	avoid_most_played_xmult = true,
	face_gold_conversion = true,
	scoring_suit_money = true,
	suit_merge = true,
	chance_xmult_money = true,
}

local supported_deck_effects = {
	remove = true,
	rank = true,
	suit = true,
	enhance = true,
	add = true,
	immolate = true,
	duplicate = true,
	edition = true,
	seal = true,
	convert = true,
	money = true,
	generate_tarot = true,
	generate_planet = true,
	generate_joker = true,
	repeat_consumable = true,
	pvp_attack = true,
}

local supported_hands = {
	["High Card"] = true,
	["Pair"] = true,
	["Two Pair"] = true,
	["Three of a Kind"] = true,
	["Straight"] = true,
	["Flush"] = true,
	["Full House"] = true,
	["Four of a Kind"] = true,
	["Straight Flush"] = true,
	["Five of a Kind"] = true,
}

local planet_definitions = {
	{ key = "c_pluto", hand = "High Card", cost = 3 },
	{ key = "c_mercury", hand = "Pair", cost = 3 },
	{ key = "c_uranus", hand = "Two Pair", cost = 3 },
	{ key = "c_venus", hand = "Three of a Kind", cost = 3 },
	{ key = "c_saturn", hand = "Straight", cost = 3 },
	{ key = "c_jupiter", hand = "Flush", cost = 3 },
	{ key = "c_earth", hand = "Full House", cost = 3 },
	{ key = "c_mars", hand = "Four of a Kind", cost = 3 },
	{ key = "c_neptune", hand = "Straight Flush", cost = 3 },
	{ key = "c_planet_x", hand = "Five of a Kind", cost = 3, runtime_only = true },
}

local voucher_definitions = {
	{ key = "v_grabber", cost = 10, utility = 40, effect = "hands", amount = 1 },
	{ key = "v_crystal_ball", cost = 10, utility = 30, effect = "consumable_slots", amount = 1 },
	{ key = "v_overstock_norm", cost = 10, utility = 32, effect = "shop_slots", amount = 1 },
	{ key = "v_overstock_plus", cost = 10, utility = 36, effect = "shop_slots", amount = 1 },
	{ key = "v_paint_brush", cost = 10, utility = 36, effect = "hand_size", amount = 1 },
	{ key = "v_seed_money", cost = 10, utility = 24, effect = "interest_cap", amount = 10 },
	{ key = "v_planet_merchant", cost = 10, utility = 24, effect = "planet_rate", amount = 2 },
	{ key = "v_reroll_surplus", cost = 10, utility = 24, effect = "reroll_discount", amount = 2 },
	{ key = "v_reroll_glut", cost = 10, utility = 30, effect = "reroll_discount", amount = 2, runtime_only = true },
	{ key = "v_clearance_sale", cost = 10, utility = 27, effect = "shop_discount", amount = 25 },
	{ key = "v_liquidation", cost = 10, utility = 34, effect = "shop_discount", amount = 50 },
	{ key = "v_wasteful", cost = 10, utility = 30, effect = "discards", amount = 1 },
	{ key = "v_hone", cost = 10, utility = 25, effect = "edition_rate", amount = 2 },
	{ key = "v_telescope", cost = 10, utility = 30, effect = "celestial_target" },
	{ key = "v_omen_globe", cost = 10, utility = 28, effect = "arcana_spectral_chance", chance = 0.2 },
	{ key = "v_tarot_merchant", cost = 10, utility = 24, effect = "tarot_rate", amount = 2.4, runtime_only = true },
	{ key = "v_tarot_tycoon", cost = 10, utility = 30, effect = "tarot_rate", amount = 8, runtime_only = true },
	{ key = "v_magic_trick", cost = 10, utility = 20, effect = "playing_cards_in_shop", amount = 1, runtime_only = true },
	{ key = "v_money_tree", cost = 10, utility = 32, effect = "interest_cap", amount = 20, runtime_only = true },
	{ key = "v_blank", cost = 10, utility = 1, effect = "none" },
}

local joker_definitions = {
	{ key = "j_joker", cost = 2, utility = 16, effect = { kind = "flat_mult", amount = 4 } },
	{ key = "j_greedy_joker", cost = 5, utility = 21, effect = { kind = "suit_mult", suit = "Diamonds", amount = 3 } },
	{ key = "j_lusty_joker", cost = 5, utility = 21, effect = { kind = "suit_mult", suit = "Hearts", amount = 3 } },
	{ key = "j_wrathful_joker", cost = 5, utility = 21, effect = { kind = "suit_mult", suit = "Spades", amount = 3 } },
	{ key = "j_gluttenous_joker", cost = 5, utility = 21, effect = { kind = "suit_mult", suit = "Clubs", amount = 3 } },
	{ key = "j_jolly", cost = 3, utility = 25, effect = { kind = "hand_mult", hand = "Pair", amount = 8 } },
	{ key = "j_zany", cost = 4, utility = 21, effect = { kind = "hand_mult", hand = "Three of a Kind", amount = 12 } },
	{ key = "j_mad", cost = 4, utility = 24, effect = { kind = "hand_mult", hand = "Two Pair", amount = 10 } },
	{ key = "j_crazy", cost = 4, utility = 18, effect = { kind = "hand_mult", hand = "Straight", amount = 12 } },
	{ key = "j_droll", cost = 4, utility = 19, effect = { kind = "hand_mult", hand = "Flush", amount = 10 } },
	{ key = "j_sly", cost = 3, utility = 20, effect = { kind = "hand_chips", hand = "Pair", amount = 50 } },
	{ key = "j_wily", cost = 4, utility = 18, effect = { kind = "hand_chips", hand = "Three of a Kind", amount = 100 } },
	{ key = "j_clever", cost = 4, utility = 22, effect = { kind = "hand_chips", hand = "Two Pair", amount = 80 } },
	{ key = "j_devious", cost = 4, utility = 17, effect = { kind = "hand_chips", hand = "Straight", amount = 100 } },
	{ key = "j_crafty", cost = 4, utility = 18, effect = { kind = "hand_chips", hand = "Flush", amount = 80 } },
	{ key = "j_half", cost = 5, utility = 27, effect = { kind = "card_count_mult", maximum = 3, amount = 20 } },
	{ key = "j_abstract", cost = 4, utility = 23, effect = { kind = "joker_count_mult", amount = 3 } },
	{ key = "j_banner", cost = 5, utility = 18, effect = { kind = "discard_chips", amount = 30 } },
	{ key = "j_mystic_summit", cost = 5, utility = 17, effect = { kind = "no_discard_mult", amount = 15 } },
	{ key = "j_fibonacci", cost = 8, utility = 34, effect = { kind = "rank_mult", ranks = { 14, 2, 3, 5, 8 }, amount = 8 } },
	{ key = "j_scary_face", cost = 4, utility = 22, effect = { kind = "face_chips", amount = 30 } },
	{ key = "j_even_steven", cost = 4, utility = 23, effect = { kind = "rank_mult", ranks = { 2, 4, 6, 8, 10 }, amount = 4 } },
	{ key = "j_odd_todd", cost = 4, utility = 22, effect = { kind = "rank_chips", ranks = { 14, 3, 5, 7, 9 }, amount = 31 } },
	{ key = "j_scholar", cost = 4, utility = 25, effect = { kind = "rank_chips_mult", ranks = { 14 }, chips = 20, mult = 4 } },
	{ key = "j_supernova", cost = 5, utility = 26, effect = { kind = "hand_usage_mult", amount = 1, include_current = true } },
	{ key = "j_ride_the_bus", cost = 6, utility = 28, effect = { kind = "bus_scaling_mult", amount = 1 } },
	{ key = "j_blackboard", cost = 6, utility = 28, effect = { kind = "held_suit_xmult", suits = { "Spades", "Clubs" }, amount = 3 } },
	{ key = "j_runner", cost = 5, utility = 27, effect = { kind = "straight_scaling_chips", amount = 15 } },
	{ key = "j_ice_cream", cost = 5, utility = 25,
		effect = { kind = "decaying_chips", initial = 100, amount = 5, destroy_at = 0 } },
	{ key = "j_blue_joker", cost = 5, utility = 24, effect = { kind = "deck_remaining_chips", amount = 2 } },
	{ key = "j_constellation", cost = 6, utility = 30, effect = { kind = "planet_scaling_xmult", initial = 1, amount = 0.1 } },
	{ key = "j_green_joker", cost = 4, utility = 27, effect = { kind = "green_scaling_mult", hand_add = 1, discard_sub = 1 } },
	{ key = "j_card_sharp", cost = 6, utility = 30, effect = { kind = "repeat_hand_xmult", amount = 3 } },
	{ key = "j_square", cost = 4, utility = 24, effect = { kind = "four_card_scaling_chips", amount = 4 } },
	{ key = "j_photograph", cost = 5, utility = 28, effect = { kind = "first_face_xmult", amount = 2 } },
	{ key = "j_fortune_teller", cost = 6, utility = 25, effect = { kind = "tarot_scaling_mult", amount = 1 } },
	{ key = "j_baseball", cost = 8, utility = 32, effect = { kind = "rarity_xmult", rarity = 2, amount = 1.5 } },
	{ key = "j_bull", cost = 6, utility = 25, effect = { kind = "money_chips", amount = 2 } },
	{ key = "j_popcorn", cost = 5, utility = 22,
		effect = { kind = "decaying_mult", initial = 20, amount = 4, destroy_at = 0 } },
	{ key = "j_ramen", cost = 6, utility = 29,
		effect = { kind = "discard_decay_xmult", initial = 2, amount = 0.01, destroy_at = 1 } },
	{ key = "j_walkie_talkie", cost = 4, utility = 23, effect = { kind = "rank_chips_mult", ranks = { 4, 10 }, chips = 10, mult = 4 } },
	{ key = "j_smiley", cost = 4, utility = 23, effect = { kind = "face_mult", amount = 5 } },
	{ key = "j_acrobat", cost = 6, utility = 27, effect = { kind = "last_hand_xmult", amount = 3 } },
	{ key = "j_dusk", cost = 5, utility = 29, effect = { kind = "retrigger_scoring" } },
	{ key = "j_hack", cost = 6, utility = 29,
		effect = { kind = "rank_retrigger", ranks = { 2, 3, 4, 5 }, repetitions = 1 } },
	{ key = "j_sock_and_buskin", cost = 6, utility = 29,
		effect = { kind = "face_retrigger", repetitions = 1 } },
	{ key = "j_riff_raff", cost = 6, utility = 28,
		effect = { kind = "round_joker_generation", count = 2, rarity = 1 } },
	{ key = "j_cartomancer", cost = 6, utility = 26,
		effect = { kind = "round_tarot_generation", count = 1 } },
	{ key = "j_certificate", cost = 6, utility = 25, runtime_only = true,
		effect = { kind = "round_sealed_card", count = 1 } },
	{ key = "j_sixth_sense", cost = 6, utility = 25, runtime_only = true,
		effect = { kind = "first_six_spectral" } },
	{ key = "j_vagabond", cost = 6, utility = 24, runtime_only = true,
		effect = { kind = "low_money_tarot", threshold = 3 } },
	{ key = "j_ring_master", cost = 5, utility = 18, runtime_only = true,
		effect = { kind = "duplicate_shop_offers" } },
	{ key = "j_space", cost = 5, utility = 25,
		effect = { kind = "chance_hand_level", odds = 4 } },
	{ key = "j_pareidolia", cost = 5, utility = 23, effect = { kind = "all_faces" } },
	{ key = "j_swashbuckler", cost = 4, utility = 24, effect = { kind = "other_joker_sell_mult" } },
	{ key = "j_bootstraps", cost = 7, utility = 27, effect = { kind = "money_step_mult", dollars = 5, amount = 2 } },
	{ key = "j_hologram", cost = 7, utility = 31, effect = { kind = "deck_add_scaling_xmult", initial = 1, amount = 0.25 } },
	{ key = "j_duo", cost = 8, utility = 32, effect = { kind = "hand_xmult", hand = "Pair", amount = 2 } },
	{ key = "j_trio", cost = 8, utility = 34, effect = { kind = "hand_xmult", hand = "Three of a Kind", amount = 3 } },
	{ key = "j_family", cost = 8, utility = 36, effect = { kind = "hand_xmult", hand = "Four of a Kind", amount = 4 } },
	{ key = "j_order", cost = 8, utility = 34, effect = { kind = "hand_xmult", hand = "Straight", amount = 3 } },
	{ key = "j_tribe", cost = 8, utility = 33, effect = { kind = "hand_xmult", hand = "Flush", amount = 2 } },
	{ key = "j_arrowhead", cost = 7, utility = 30, effect = { kind = "suit_chips", suit = "Spades", amount = 50 } },
	{ key = "j_onyx_agate", cost = 7, utility = 29, effect = { kind = "suit_card_mult", suit = "Clubs", amount = 7 } },
	{ key = "j_shoot_the_moon", cost = 5, utility = 25, effect = { kind = "held_rank_mult", rank = 12, amount = 13 } },
	{ key = "j_steel_joker", cost = 7, utility = 29, effect = { kind = "enhancement_count_xmult", enhancement = "m_steel", initial = 1, amount = 0.2 } },
	{ key = "j_cavendish", cost = 4, utility = 31,
		effect = { kind = "flat_xmult", amount = 3, requires_pool_flag = "gros_michel_extinct",
			extinction_odds = 1000 } },
	{ key = "j_gros_michel", cost = 5, utility = 27,
		effect = { kind = "flat_mult", amount = 15, blocks_pool_flag = "gros_michel_extinct",
			extinction_odds = 6, sets_pool_flag = "gros_michel_extinct" } },
	{ key = "j_stuntman", cost = 7, utility = 35, effect = { kind = "flat_chips", amount = 250, hand_size = -2 } },
	{ key = "j_stencil", cost = 8, utility = 30, effect = { kind = "empty_slot_xmult" } },
	{ key = "j_raised_fist", cost = 5, utility = 24, effect = { kind = "held_lowest_rank_mult", amount = 2 } },
	{ key = "j_baron", cost = 8, utility = 34, effect = { kind = "held_rank_xmult", rank = 13, amount = 1.5 } },
	{ key = "j_erosion", cost = 6, utility = 25, effect = { kind = "missing_deck_mult", amount = 4 } },
	{ key = "j_stone", cost = 6, utility = 27, effect = { kind = "stone_count_chips", amount = 25 } },
	{ key = "j_drivers_license", cost = 7, utility = 34, effect = { kind = "enhanced_threshold_xmult", count = 16, amount = 3 } },
	{ key = "j_flower_pot", cost = 6, utility = 31, effect = { kind = "scoring_suits_xmult", count = 4, amount = 3 } },
	{ key = "j_seeing_double", cost = 6, utility = 29, effect = { kind = "mixed_suit_xmult", suit = "Clubs", amount = 2 } },
	{ key = "j_loyalty_card", cost = 5, utility = 28,
		effect = { kind = "periodic_xmult", every = 6, initial = 6, amount = 4 } },
	{ key = "j_trousers", cost = 6, utility = 29, effect = { kind = "hand_scaling_mult", hand = "Two Pair", amount = 2 } },
	{ key = "j_wee", cost = 8, utility = 32, effect = { kind = "rank_scaling_chips", rank = 2, amount = 8 } },
	{ key = "j_todo_list", cost = 4, utility = 21,
		effect = { kind = "played_hand_money", amount = 4 } },
	{ key = "j_cloud_9", cost = 7, utility = 22,
		effect = { kind = "deck_rank_money", rank = 9, amount = 1 } },
	{ key = "j_golden", cost = 6, utility = 24,
		effect = { kind = "round_money", amount = 4 } },
	{ key = "j_delayed_grat", cost = 4, utility = 21,
		effect = { kind = "round_money", per_unused_discard = 2, requires_no_discard = true } },
	{ key = "j_faceless", cost = 4, utility = 22,
		effect = { kind = "discard_face_money", count = 3, amount = 5 } },
	{ key = "j_splash", cost = 3, utility = 20,
		effect = { kind = "all_played_score" } },
	{ key = "j_burglar", cost = 6, utility = 30,
		effect = { kind = "round_resources", hands = 3, reset_discards = true } },
	{ key = "j_merry_andy", cost = 7, utility = 25,
		effect = { kind = "round_resources", discards = 3, hand_size = -1 } },
	{ key = "j_misprint", cost = 4, utility = 20,
		effect = { kind = "flat_mult", amount = 11.5 } },
	{ key = "j_juggler", cost = 4, utility = 21,
		effect = { kind = "round_resources", hand_size = 1 } },
	{ key = "j_drunkard", cost = 4, utility = 21,
		effect = { kind = "round_resources", discards = 1 } },
	{ key = "j_troubadour", cost = 6, utility = 25,
		effect = { kind = "round_resources", hands = -1, hand_size = 2 } },
	{ key = "j_blueprint", cost = 10, utility = 34,
		effect = { kind = "copy_joker", mode = "right" } },
	{ key = "j_brainstorm", cost = 10, utility = 34,
		effect = { kind = "copy_joker", mode = "leftmost" } },
	{ key = "j_chaos", cost = 4, utility = 18, effect = { kind = "free_shop_reroll" } },
	{ key = "j_mime", cost = 5, utility = 22, effect = { kind = "held_retrigger" } },
	{ key = "j_hiker", cost = 5, utility = 28, effect = { kind = "played_card_chip_growth", amount = 5 } },
	{ key = "j_credit_card", cost = 1, utility = 17, effect = { kind = "debt_limit", amount = 20 } },
	{ key = "j_business", cost = 4, utility = 20,
		effect = { kind = "scoring_face_money", odds = 2, amount = 2 } },
	{ key = "j_marble", cost = 6, utility = 25,
		effect = { kind = "round_stone_card", count = 1 } },
	{ key = "j_astronomer", cost = 8, utility = 27,
		effect = { kind = "free_planets" } },
	{ key = "j_hallucination", cost = 4, utility = 20,
		effect = { kind = "pack_tarot_chance", odds = 2 } },
	{ key = "j_8_ball", cost = 5, utility = 22,
		effect = { kind = "played_rank_planet", rank = 8, count = 2 } },
	{ key = "j_egg", cost = 4, utility = 18,
		effect = { kind = "sell_value_growth", amount = 3 } },
	{ key = "j_obelisk", cost = 8, utility = 31,
		effect = { kind = "avoid_most_played_xmult", initial = 1, amount = 0.2 } },
	{ key = "j_midas_mask", cost = 6, utility = 24,
		effect = { kind = "face_gold_conversion" } },
	{ key = "j_smeared", cost = 7, utility = 27,
		effect = { kind = "suit_merge" } },
	{ key = "j_rough_gem", cost = 7, utility = 24,
		effect = { kind = "scoring_suit_money", suit = "Diamonds", amount = 1 } },
	{ key = "j_red_card", cost = 5, utility = 23,
		effect = { kind = "skipped_pack_scaling_mult", amount = 3 } },
	{ key = "j_shortcut", cost = 7, utility = 27, effect = { kind = "straight_gaps" } },
	{ key = "j_superposition", cost = 4, utility = 20, effect = { kind = "straight_ace_tarot" } },
	{ key = "j_mp_pacifist", cost = 4, utility = 25, multiplayer = true,
		effect = { kind = "non_pvp_xmult", amount = 10 } },
	{ key = "j_mp_hanging_chad", cost = 4, utility = 27, multiplayer = true,
		effect = { kind = "first_scoring_retrigger", cards = 2, repetitions = 1 } },
	{ key = "j_mp_turtle_bean", cost = 6, utility = 24, multiplayer = true,
		effect = { kind = "decaying_hand_size", initial = 4, amount = 1 } },
	{ key = "j_mp_bloodstone", cost = 7, utility = 31, multiplayer = true,
		effect = { kind = "chance_suit_xmult", suit = "Hearts", chance = 0.5, amount = 1.5 } },
	{ key = "j_mp_lets_go_gambling", cost = 6, utility = 29, multiplayer = true,
		effect = { kind = "chance_xmult_money", odds = 4, amount = 4, dollars = 10 } },
	{ key = "j_mp_penny_pincher", cost = 4, utility = 18, multiplayer = true,
		effect = { kind = "round_money", amount = 2 } },
	{ key = "j_mp_skip_off", cost = 5, utility = 20, multiplayer = true,
		effect = { kind = "skip_advantage_resources", hands = 1, discards = 1 } },
	{ key = "j_ancient", cost = 8, utility = 31, runtime_only = true,
		effect = { kind = "rotating_suit_xmult", amount = 1.5 } },
	{ key = "j_castle", cost = 6, utility = 27, runtime_only = true,
		effect = { kind = "discard_suit_scaling_chips", amount = 3, initial = 0 } },
	{ key = "j_ceremonial", cost = 6, utility = 12, runtime_only = true,
		effect = { kind = "sacrifice_scaling_mult", amount = 2, initial = 0 } },
	{ key = "j_diet_cola", cost = 6, utility = 21, runtime_only = true,
		effect = { kind = "double_tag_on_sell" } },
	{ key = "j_four_fingers", cost = 7, utility = 25, runtime_only = true,
		effect = { kind = "four_card_hands" } },
	{ key = "j_gift", cost = 6, utility = 21, runtime_only = true,
		effect = { kind = "sell_value_growth", amount = 1 } },
	{ key = "j_madness", cost = 7, utility = 10, runtime_only = true,
		effect = { kind = "blind_scaling_xmult", amount = 0.5, initial = 1 } },
	{ key = "j_mail", cost = 4, utility = 22, runtime_only = true,
		effect = { kind = "discard_rank_money", amount = 5 } },
	{ key = "j_mp_pizza", cost = 4, utility = 18, multiplayer = true,
		effect = { kind = "pvp_discard_food", discards = 2, enemy_discards = 1 } },
	{ key = "j_mp_taxes", cost = 5, utility = 22, multiplayer = true,
		effect = { kind = "opponent_sale_mult", amount = 4, initial = 0 } },
	{ key = "j_mp_ticket", cost = 8, utility = 24, multiplayer = true,
		effect = { kind = "scoring_enhancement_money", enhancement = "m_gold", amount = 4 } },
	{ key = "j_oops", cost = 4, utility = 24, runtime_only = true,
		effect = { kind = "double_probabilities", amount = 2 } },
	{ key = "j_reserved_parking", cost = 6, utility = 20, runtime_only = true,
		effect = { kind = "held_face_money", odds = 2, amount = 1 } },
	{ key = "j_seance", cost = 6, utility = 17, runtime_only = true,
		effect = { kind = "straight_flush_spectral" } },
	{ key = "j_to_the_moon", cost = 5, utility = 23, runtime_only = true,
		effect = { kind = "extra_interest", amount = 1 } },
	{ key = "j_trading", cost = 6, utility = 27, runtime_only = true,
		effect = { kind = "single_discard_destroy", amount = 3 } },
}

local deck_tool_definitions = {
	{ key = "c_fool", set = "Tarot", cost = 3, utility = 24, effect = "repeat_consumable" },
	{ key = "c_emperor", set = "Tarot", cost = 3, utility = 26, effect = "generate_tarot", count = 2 },
	{ key = "c_high_priestess", set = "Tarot", cost = 3, utility = 25, effect = "generate_planet", count = 2 },
	{ key = "c_judgement", set = "Tarot", cost = 3, utility = 27, effect = "generate_joker", count = 1 },
	{ key = "c_hanged_man", set = "Tarot", cost = 3, utility = 30, effect = "remove", count = 2 },
	{ key = "c_strength", set = "Tarot", cost = 3, utility = 22, effect = "rank", count = 2 },
	{ key = "c_star", set = "Tarot", cost = 3, utility = 25, effect = "suit", suit = "Diamonds", count = 3 },
	{ key = "c_moon", set = "Tarot", cost = 3, utility = 25, effect = "suit", suit = "Clubs", count = 3 },
	{ key = "c_sun", set = "Tarot", cost = 3, utility = 25, effect = "suit", suit = "Hearts", count = 3 },
	{ key = "c_world", set = "Tarot", cost = 3, utility = 25, effect = "suit", suit = "Spades", count = 3 },
	{ key = "c_empress", set = "Tarot", cost = 3, utility = 24, effect = "enhance", enhancement = "m_mult", count = 2 },
	{ key = "c_heirophant", set = "Tarot", cost = 3, utility = 23, effect = "enhance", enhancement = "m_bonus", count = 2 },
	{ key = "c_magician", set = "Tarot", cost = 3, utility = 23, effect = "enhance", enhancement = "m_lucky", count = 2 },
	{ key = "c_lovers", set = "Tarot", cost = 3, utility = 22, effect = "enhance", enhancement = "m_wild", count = 1 },
	{ key = "c_justice", set = "Tarot", cost = 3, utility = 26, effect = "enhance", enhancement = "m_glass", count = 1 },
	{ key = "c_death", set = "Tarot", cost = 3, utility = 28, effect = "convert" },
	{ key = "c_chariot", set = "Tarot", cost = 3, utility = 27, effect = "enhance", enhancement = "m_steel", count = 1 },
	{ key = "c_devil", set = "Tarot", cost = 3, utility = 22, effect = "enhance", enhancement = "m_gold", count = 1 },
	{ key = "c_tower", set = "Tarot", cost = 3, utility = 22, effect = "enhance", enhancement = "m_stone", count = 1 },
	{ key = "c_wheel_of_fortune", set = "Tarot", cost = 3, utility = 24, effect = "edition" },
	{ key = "c_hermit", set = "Tarot", cost = 3, utility = 30, effect = "money", multiplier = 1, cap = 20 },
	{ key = "c_temperance", set = "Tarot", cost = 3, utility = 24, effect = "money", sell_value = true, cap = 50 },
	{ key = "p_standard_normal_1", set = "Booster", cost = 4, utility = 6, effect = "add" },
	{ key = "p_standard_normal_2", set = "Booster", cost = 4, utility = 6, effect = "add" },
	{ key = "p_standard_normal_3", set = "Booster", cost = 4, utility = 6, effect = "add" },
	{ key = "p_standard_normal_4", set = "Booster", cost = 4, utility = 6, effect = "add" },
	{ key = "p_standard_jumbo_1", set = "Booster", cost = 6, utility = 7, effect = "add" },
	{ key = "p_standard_jumbo_2", set = "Booster", cost = 6, utility = 7, effect = "add" },
	{ key = "p_standard_mega_1", set = "Booster", cost = 8, utility = 9, effect = "add" },
	{ key = "p_standard_mega_2", set = "Booster", cost = 8, utility = 9, effect = "add" },
	{ key = "p_spectral_normal_1", set = "Booster", cost = 4, utility = 18, effect = "add" },
	{ key = "p_spectral_normal_2", set = "Booster", cost = 4, utility = 18, effect = "add" },
	{ key = "p_spectral_jumbo_1", set = "Booster", cost = 6, utility = 20, effect = "add" },
	{ key = "p_spectral_mega_1", set = "Booster", cost = 8, utility = 24, effect = "add" },
	{ key = "c_immolate", set = "Spectral", cost = 4, utility = 35, effect = "immolate", count = 5, spectral = true },
	{ key = "c_cryptid", set = "Spectral", cost = 4, utility = 32, effect = "duplicate", count = 2, spectral = true },
	{ key = "c_aura", set = "Spectral", cost = 4, utility = 27, effect = "edition", spectral = true },
	{ key = "c_deja_vu", set = "Spectral", cost = 4, utility = 21, effect = "seal", seal = "Red", spectral = true },
	{ key = "c_mp_asteroid", set = "Planet", cost = 3, utility = 27,
		effect = "pvp_attack", action = "asteroid", multiplayer = true },
}

local function copy(source)
	local result = {}
	for key, value in pairs(source or {}) do result[key] = value end
	return result
end

local function replace_or_add(definitions, definition)
	assert(type(definition) == "table" and type(definition.key) == "string", "headless adapter requires a key")
	for index, existing in ipairs(definitions) do
		if existing.key == definition.key then definitions[index] = copy(definition); return end
	end
	definitions[#definitions + 1] = copy(definition)
end

function Content.register_joker(definition)
	assert(type(definition.effect) == "table", "Joker adapter requires a declarative effect")
	assert(supported_joker_effects[definition.effect.kind], "unsupported Joker effect kind: " .. tostring(definition.effect.kind))
	replace_or_add(joker_definitions, definition)
end

function Content.register_deck_tool(definition)
	assert(type(definition.set) == "string" and type(definition.effect) == "string",
		"deck-tool adapter requires set and effect")
	assert(supported_deck_effects[definition.effect], "unsupported deck-tool effect: " .. tostring(definition.effect))
	replace_or_add(deck_tool_definitions, definition)
end

local function center_lookup(pools)
	local lookup = {}
	for set, pool in pairs(pools or {}) do
		lookup[set] = {}
		for _, center in ipairs(pool or {}) do
			if center and center.key then lookup[set][center.key] = center end
		end
	end
	return lookup
end

local function actual_offer(definition, center)
	local offer = copy(definition)
	if center then
		offer.cost = tonumber(center.cost) or offer.cost
		offer.rarity = center.rarity
		offer.name = center.name
	end
	return offer
end

local function stable_sort(items)
	table.sort(items, function(a, b) return tostring(a.key) < tostring(b.key) end)
	return items
end

local function note_unsupported(catalog, set, center)
	if not center or not center.key or catalog.banned[center.key] then return end
	catalog.unsupported[set] = catalog.unsupported[set] or {}
	catalog.unsupported[set][#catalog.unsupported[set] + 1] = center.key
end

local function supported_pack_key(key)
	local family, size = tostring(key):match("^p_(%a+)_(%a+)_%d+$")
	return (family == "celestial" or family == "buffoon" or family == "arcana"
		or family == "spectral" or family == "standard")
		and (size == "normal" or size == "jumbo" or size == "mega")
end

function Content.pack_topic(key)
	local family = tostring(key):match("^p_(%a+)_")
	return family == "arcana" and "tarots"
		or family == "celestial" and "planets"
		or family == "spectral" and "spectrals"
		or nil
end

function Content.build(pools, centers, banned)
	local catalog = {
		banned = banned or {},
		jokers = {},
		planets = {},
		deck_tools = {},
		vouchers = {},
		packs = {},
		unsupported = {},
	}
	local lookup = center_lookup(pools)
	local supported = {}
	local registered_planet_tools = {}
	for _, definition in ipairs(deck_tool_definitions) do
		if definition.set == "Planet" then registered_planet_tools[definition.key] = true end
	end

	for _, definition in ipairs(joker_definitions) do
		local center = lookup.Joker and lookup.Joker[definition.key]
		if center and not catalog.banned[definition.key] then
			catalog.jokers[#catalog.jokers + 1] = actual_offer(definition, center)
			supported[definition.key] = true
		end
	end
	for _, center in ipairs((pools and pools.Joker) or {}) do
		if not supported[center.key] then note_unsupported(catalog, "Joker", center) end
	end

	for _, center in ipairs((pools and pools.Planet) or {}) do
		local hand = center.config and center.config.hand_type
		if registered_planet_tools[center.key] then
			-- Special Multiplayer Planets are consumables, but do not level one of
			-- the bot's own poker hands. Their registered deck-tool adapter below
			-- owns the effect and keeps them out of the unsupported report.
		elseif supported_hands[hand] and not catalog.banned[center.key] then
			catalog.planets[#catalog.planets + 1] = {
				key = center.key,
				hand = hand,
				cost = tonumber(center.cost) or 3,
				name = center.name,
			}
		else
			note_unsupported(catalog, "Planet", center)
		end
	end

	for _, definition in ipairs(deck_tool_definitions) do
		local center = lookup[definition.set] and lookup[definition.set][definition.key]
		if definition.set ~= "Booster" and center and not catalog.banned[definition.key] then
			catalog.deck_tools[#catalog.deck_tools + 1] = actual_offer(definition, center)
			supported[definition.key] = true
		end
	end
	for _, definition in ipairs(voucher_definitions) do
		local center = lookup.Voucher and lookup.Voucher[definition.key]
		if center and not catalog.banned[definition.key] then
			catalog.vouchers[#catalog.vouchers + 1] = actual_offer(definition, center)
			supported[definition.key] = true
		end
	end
	for _, center in ipairs((pools and pools.Booster) or {}) do
		if supported_pack_key(center.key) and not catalog.banned[center.key] then
			catalog.packs[#catalog.packs + 1] = center.key
			supported[center.key] = true
		end
	end
	for _, set in ipairs({ "Tarot", "Spectral", "Booster", "Voucher" }) do
		for _, center in ipairs((pools and pools[set]) or {}) do
			if not supported[center.key] then note_unsupported(catalog, set, center) end
		end
	end

	stable_sort(catalog.jokers)
	stable_sort(catalog.planets)
	stable_sort(catalog.deck_tools)
	stable_sort(catalog.vouchers)
	for _, keys in pairs(catalog.unsupported) do table.sort(keys) end
	return catalog
end

-- balatro-brain patch: vanilla rarities (game.lua P_CENTERS). Live catalogs
-- read them from the game; without them the default catalog never triggered
-- Baseball Card or Riff-raff and guessed shop rarities from the cost.
local VANILLA_RARITY = {
	j_joker = 1,
	j_greedy_joker = 1,
	j_lusty_joker = 1,
	j_wrathful_joker = 1,
	j_gluttenous_joker = 1,
	j_jolly = 1,
	j_zany = 1,
	j_mad = 1,
	j_crazy = 1,
	j_droll = 1,
	j_sly = 1,
	j_wily = 1,
	j_clever = 1,
	j_devious = 1,
	j_crafty = 1,
	j_half = 1,
	j_abstract = 1,
	j_banner = 1,
	j_mystic_summit = 1,
	j_fibonacci = 2,
	j_scary_face = 1,
	j_even_steven = 1,
	j_odd_todd = 1,
	j_scholar = 1,
	j_supernova = 1,
	j_ride_the_bus = 1,
	j_blackboard = 2,
	j_runner = 1,
	j_ice_cream = 1,
	j_blue_joker = 1,
	j_constellation = 2,
	j_green_joker = 1,
	j_card_sharp = 2,
	j_square = 1,
	j_photograph = 1,
	j_fortune_teller = 1,
	j_baseball = 3,
	j_bull = 2,
	j_popcorn = 1,
	j_ramen = 2,
	j_walkie_talkie = 1,
	j_smiley = 1,
	j_acrobat = 2,
	j_dusk = 2,
	j_hack = 2,
	j_sock_and_buskin = 2,
	j_riff_raff = 1,
	j_cartomancer = 2,
	j_space = 2,
	j_pareidolia = 2,
	j_swashbuckler = 1,
	j_bootstraps = 2,
	j_hologram = 2,
	j_duo = 3,
	j_trio = 3,
	j_family = 3,
	j_order = 3,
	j_tribe = 3,
	j_arrowhead = 2,
	j_onyx_agate = 2,
	j_shoot_the_moon = 1,
	j_steel_joker = 2,
	j_cavendish = 1,
	j_gros_michel = 1,
	j_stuntman = 3,
	j_stencil = 2,
	j_raised_fist = 1,
	j_baron = 3,
	j_erosion = 2,
	j_stone = 2,
	j_drivers_license = 3,
	j_flower_pot = 2,
	j_seeing_double = 2,
	j_loyalty_card = 2,
	j_trousers = 2,
	j_wee = 3,
	j_todo_list = 1,
	j_cloud_9 = 2,
	j_golden = 1,
	j_delayed_grat = 1,
	j_faceless = 1,
	j_splash = 1,
	j_burglar = 2,
	j_merry_andy = 2,
	j_misprint = 1,
	j_juggler = 1,
	j_drunkard = 1,
	j_troubadour = 2,
	j_blueprint = 3,
	j_brainstorm = 3,
	j_chaos = 1,
	j_mime = 2,
	j_hiker = 2,
	j_credit_card = 1,
	j_business = 1,
	j_marble = 2,
	j_astronomer = 2,
	j_hallucination = 1,
	j_red_card = 1,
	j_shortcut = 2,
	j_superposition = 1,
}

function Content.defaults()
	return {
		banned = {},
		jokers = stable_sort((function()
			local out = {}
			for _, definition in ipairs(joker_definitions) do
				-- Multiplayer-only centers belong in runtime catalogs only when the
				-- active ruleset exposes them; generic simulations remain vanilla.
				if not definition.multiplayer and not definition.runtime_only then
					local entry = copy(definition)
					entry.rarity = entry.rarity or VANILLA_RARITY[entry.key]
					out[#out + 1] = entry
				end
			end
			return out
		end)()),
		planets = stable_sort((function()
			local out = {}
			for _, definition in ipairs(planet_definitions) do
				if not definition.runtime_only then out[#out + 1] = copy(definition) end
			end
			return out
		end)()),
		packs = (function()
			local out = {}
			for _, definition in ipairs(deck_tool_definitions) do
				if definition.set == "Booster" then out[#out + 1] = definition.key end
			end
			table.sort(out)
			return out
		end)(),
		vouchers = stable_sort((function()
			local out = {}
			for _, definition in ipairs(voucher_definitions) do
				if not definition.runtime_only then out[#out + 1] = copy(definition) end
			end
			return out
		end)()),
		deck_tools = stable_sort((function()
			local out = {}
			for _, definition in ipairs(deck_tool_definitions) do
				if definition.set ~= "Booster" and not definition.multiplayer then
					out[#out + 1] = copy(definition)
				end
			end
			return out
		end)()),
		unsupported = {},
	}
end

function Content.summary(catalog)
	local skipped, examples = 0, {}
	for _, set in ipairs({ "Joker", "Planet", "Tarot", "Spectral", "Booster", "Voucher" }) do
		local keys = catalog.unsupported[set] or {}
		skipped = skipped + #keys
		for _, key in ipairs(keys) do
			if #examples < 8 then examples[#examples + 1] = key end
		end
	end
	return {
		jokers = #catalog.jokers,
		planets = #catalog.planets,
		deck_tools = #catalog.deck_tools,
		vouchers = #(catalog.vouchers or {}),
		packs = #(catalog.packs or {}),
		skipped = skipped,
		examples = examples,
	}
end

return Content
