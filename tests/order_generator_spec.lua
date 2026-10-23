local function hash(value)
	local result = 0
	for index = 1, #tostring(value) do result = (result * 33 + tostring(value):byte(index)) % 997 end
	return result / 997
end

G = {
	GAME = {
		pseudorandom = { seed = "*ORDER", hashed_seed = hash("*ORDER") },
		used_jokers = {}, used_vouchers = {}, pool_flags = {}, tags = {},
		current_round = { voucher = { "v_grabber", spawn = { v_grabber = true } } },
		round_resets = { ante = 1 },
		shop = { joker_max = 2 },
		starting_params = { boosters_in_shop = 2, vouchers_in_shop = 1 },
		modifiers = {
			extra_boosters = 0, extra_vouchers = 0,
			enable_eternals_in_shop = false,
			enable_perishables_in_shop = false,
			enable_rentals_in_shop = false,
		},
		banned_keys = {}, joker_rate = 20, tarot_rate = 0, planet_rate = 0,
		spectral_rate = 0, playing_card_rate = 0,
	},
}

function pseudohash(value) return hash(value) end
function pseudoseed(key)
	local random = G.GAME.pseudorandom
	if random[key] == nil then random[key] = hash(key .. (random.seed or "")) end
	random[key] = (0.173 + random[key] * 1.731) % 1
	return random[key]
end
function pseudorandom(seed)
	if type(seed) == "string" then seed = pseudoseed(seed) end
	return tonumber(seed) or 0
end
function pseudorandom_element(values, seed)
	local index = math.floor((tonumber(seed) or 0) * #values) % #values + 1
	return values[index]
end
function get_current_pool(object_type, _, _, append)
	reset_idol_card()
	local pools = {
		Joker = { "j_joker", "j_jolly", "j_banner" },
		Tarot = { "c_strength", "c_hanged_man", "c_magician" },
		Planet = { "c_mercury", "c_venus", "c_earth" },
		Spectral = { "c_immolate", "c_cryptid", "c_aura" },
		Enhanced = { "m_lucky", "m_steel", "m_gold" },
	}
	assert(pools[object_type], "unexpected pool " .. tostring(object_type))
	local available = {}
	for _, key in ipairs(pools[object_type]) do
		if not G.GAME.used_jokers[key] or (SMODS.showman and SMODS.showman(key)) then
			available[#available + 1] = key
		end
	end
	if #available == 0 then available[1] = "UNAVAILABLE" end
	return available, object_type .. "0" .. tostring(append or "")
end
function reset_idol_card()
	G.GAME.current_round.idol_card.rank = "Ace"
	G.GAME.current_round.idol_card.suit = "Spades"
end
local observed_edition_rate
function poll_edition(key)
	observed_edition_rate = G.GAME.edition_rate
	pseudorandom(key)
	return G.GAME.edition_rate == 2 and { foil = true } or nil
end
function get_pack(key)
	local pick = pseudorandom(pseudoseed(key .. "0"))
	return { key = pick < 0.5 and "p_arcana_normal_1" or "p_celestial_normal_1" }
end

SMODS = {
	ConsumableType = { obj_buffer = {} }, Stickers = {}, optional_features = {},
	Suits = {
		{ key = "Spades", card_key = "S" }, { key = "Hearts", card_key = "H" },
		{ key = "Clubs", card_key = "C" }, { key = "Diamonds", card_key = "D" },
	},
	Ranks = {
		{ key = "2", id = 2, card_key = "2" }, { key = "King", id = 13, card_key = "K" },
		{ key = "Ace", id = 14, card_key = "A" },
	},
	poll_seal = function()
		pseudorandom(pseudoseed("stdseal0"))
		return "Red"
	end,
	get_next_vouchers = function()
		pseudorandom(pseudoseed("Voucher0"))
		return { "v_grabber", spawn = { v_grabber = true } }
	end,
}

local Order = dofile("bot/order.lua")
local run = { seed = "*ORDER", ante = 1, jokers = {}, vouchers = {} }
local human_random = G.GAME.pseudorandom
Order.begin_run(run, run.seed)

local normal_picker = pseudorandom_element
pseudorandom_element = function(values) return values[1] end
local dedupe_run = { seed = "DEDUPE", ante = 1, jokers = {}, vouchers = {} }
Order.begin_run(dedupe_run, dedupe_run.seed)
local deduped = assert(Order.generate_reroll(dedupe_run))
assert(deduped[1] ~= deduped[2],
	"a private shop must reserve its first center while generating its second slot")
local showman_run = { seed = "SHOWMAN", ante = 1, jokers = { "j_ring_master" }, vouchers = {} }
Order.begin_run(showman_run, showman_run.seed)
local repeated = assert(Order.generate_reroll(showman_run))
assert(repeated[1] == repeated[2], "an owned Showman should permit duplicate shop centers")
pseudorandom_element = normal_picker

local hone_run = { seed = "HONE", ante = 1, jokers = {}, vouchers = { "v_hone" }, edition_rate = 2 }
Order.begin_run(hone_run, hone_run.seed)
local hone_shop = assert(Order.generate_reroll(hone_run))
assert(observed_edition_rate == 2 and hone_shop._metadata[1].edition == "foil",
	"Hone should double the bot's private edition rate without using the human player's rate")

local first = assert(Order.generate_shop(run))
assert(#first == 5, "a generated shop should contain main cards, packs, and its voucher")
assert(first[3] == "p_buffoon_normal_1", "the first Buffoon pack should not consume an Order queue")
assert(first[5] == "v_grabber", "the independently tracked Ante voucher should be offered")
assert(G.GAME.pseudorandom == human_random and human_random.cdt0 == nil,
	"private shop generation must restore and leave the human RNG untouched")
assert(run.order_shop.random.cdt0 ~= nil, "the bot's private main-shop queue should advance")

local pack_queue_after_shop = run.order_shop.random.shop_pack0
local reroll = assert(Order.generate_reroll(run))
assert(#reroll == 2, "a reroll should replace only the main shop slots")
assert(run.order_shop.random.shop_pack0 == pack_queue_after_shop,
	"rerolls must not advance Booster queues")

local human_snapshot = {}
for key, value in pairs(human_random) do human_snapshot[key] = value end
local arcana = assert(Order.generate_pack(run, "p_arcana_normal_1"))
assert(#arcana == 3 and arcana.picks == 1 and arcana.family == "arcana",
	"a normal Arcana Pack should privately poll three choices")
for _, card in ipairs(arcana) do
	assert(card.kind == "center" and tostring(card.key):sub(1, 2) == "c_",
		"Arcana Pack results should be consumable descriptors")
end
assert(run.order_shop.random.Tarot0Tarot_pack ~= nil,
	"pack Tarots must advance the dedicated Tarot_pack queue")
for key, value in pairs(human_snapshot) do
	assert(human_random[key] == value, "opening a bot pack must not advance the human RNG")
end

local standard = assert(Order.generate_pack(run, "p_standard_normal_1"))
assert(#standard == 3 and standard.picks == 1, "a normal Standard Pack should poll three cards")
for _, card in ipairs(standard) do
	assert(card.kind == "playing_card" and card.suit and card.rank,
		"Standard Pack results should include independently polled fronts")
end
assert(human_random.stdset0 == nil and human_random.sccsuitsta0 == nil,
	"Standard Pack queues must remain private to the bot")

run.vouchers = { "v_grabber" }
local second = assert(Order.generate_shop(run))
assert(#second == 4, "an owned voucher should disappear while the main and Booster queues continue")

run.ante = 2
local third = assert(Order.generate_shop(run))
assert(#third == 4, "a newly polled voucher already owned by the bot should remain unavailable")
assert(G.GAME.current_round.voucher[1] == "v_grabber",
	"private voucher polling must restore the human's current voucher table")
assert(G.GAME.current_round.idol_card == nil,
	"private Idol resets must not modify or leak state into the human round")

-- The bot's own Vouchers set its private shop rates (card.lua apply_to_run).
local observed_rates = {}
local pool_ref = get_current_pool
get_current_pool = function(...)
	observed_rates[#observed_rates + 1] = { tarot = G.GAME.tarot_rate, planet = G.GAME.planet_rate }
	return pool_ref(...)
end
local merchant_run = { seed = "MERCHANT", ante = 1, jokers = {},
	vouchers = { "v_tarot_merchant", "v_tarot_tycoon", "v_planet_merchant" }, tarot_rate = 8, planet_rate = 2.4 }
Order.begin_run(merchant_run, merchant_run.seed)
assert(Order.generate_reroll(merchant_run))
get_current_pool = pool_ref
assert(observed_rates[1].tarot == 32 and math.abs(observed_rates[1].planet - 9.6) < 1e-9,
	"Tarot Tycoon and Planet Merchant set the bot's private rates to 32 and 9.6")
assert(G.GAME.tarot_rate == 0 and G.GAME.planet_rate == 0, "the human's shop rates are restored")

-- Overstock adds a slot to the bot's shop; a Rare Tag's Joker takes one.
local overstock_run = { seed = "OVERSTOCK", ante = 1, jokers = {}, vouchers = {}, shop_slots = 2 }
Order.begin_run(overstock_run, overstock_run.seed)
overstock_run.shop_slots = 3
assert(#Order.generate_reroll(overstock_run) == 3, "the bot's Overstock adds a card slot")
overstock_run.pending_tag_jokers = { { tag = "tag_rare", rarity = "rare" } }
assert(#Order.generate_reroll(overstock_run) == 2, "a Rare Tag's Joker takes one of the card slots")

-- Magic Trick: playing cards in the bot's shop, with their fronts.
local joker_rate = G.GAME.joker_rate
G.GAME.joker_rate = 0
local trick_run = { seed = "TRICK", ante = 1, jokers = {}, vouchers = { "v_magic_trick" }, playing_card_rate = 4 }
Order.begin_run(trick_run, trick_run.seed)
G.GAME.joker_rate = joker_rate
local trick = assert(Order.generate_reroll(trick_run))
local front = trick._metadata[1].playing_card
assert(trick[1] == "c_base" and front and front.suit and front.rank and not front.enhancement,
	"Magic Trick puts playing cards with a front in the bot's shop")
assert(G.GAME.playing_card_rate == 0, "the human's playing card rate is restored")

-- Omen Globe: Spectral cards in the bot's Arcana Packs.
local omen_run = { seed = "OMEN", ante = 1, jokers = {}, vouchers = { "v_omen_globe" } }
Order.begin_run(omen_run, omen_run.seed)
local pseudorandom_ref = pseudorandom
pseudorandom = function(seed)
	if seed == "omen_globe" then return 0.9 end
	return pseudorandom_ref(seed)
end
local omen = assert(Order.generate_pack(omen_run, "p_arcana_normal_1"))
pseudorandom = pseudorandom_ref
local spectral_keys = { c_immolate = true, c_cryptid = true, c_aura = true }
for _, card in ipairs(omen) do
	assert(spectral_keys[card.key], "an Omen Globe roll above 0.8 makes an Arcana card Spectral: " .. tostring(card.key))
end

-- Voucher Tag: the bot's own Voucher_fromtag poll, never a Voucher in its shop.
function get_next_voucher_key(from_tag)
	assert(from_tag, "a Voucher Tag polls get_next_voucher_key(true)")
	for _, key in ipairs({ "v_grabber", "v_hone" }) do
		if not (G.ARGS.voucher_tag or {})[key] and not G.GAME.used_vouchers[key] then return key end
	end
	return "UNAVAILABLE"
end
assert(Order.generate_tag_voucher({ seed = "TAGV", ante = 1, jokers = {}, vouchers = {} }, { v_grabber = true })
	== "v_hone" and G.ARGS.voucher_tag == nil, "the Voucher Tag skips the shop's Voucher")
get_next_voucher_key = nil

G, SMODS = nil, nil
print("order_generator_spec: ok")
