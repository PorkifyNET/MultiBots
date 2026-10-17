local Order = {
	queue = {},
	area_identity = nil,
	round_identity = nil,
	signature = nil,
	stable_seconds = 0,
	captured = false,
	pending_keys = nil,
	pending_metadata = nil,
	between_shops = false,
	observer_enabled = false,
}

local function copy_map(source)
	local result = {}
	for key, value in pairs(source or {}) do
		if type(value) == "table" then
			result[key] = copy_map(value)
		else
			result[key] = value
		end
	end
	return result
end

local function list_map(values)
	local result = {}
	for _, value in ipairs(values or {}) do result[value] = true end
	return result
end

local function edition_name(edition)
	if type(edition) ~= "table" then return nil end
	return edition.type
		or (edition.negative and "negative")
		or (edition.polychrome and "polychrome")
		or (edition.holo and "holo")
		or (edition.foil and "foil")
end

local function new_random_state(seed)
	return {
		seed = seed,
		hashed_seed = type(pseudohash) == "function" and pseudohash(seed) or nil,
	}
end

-- The human and the headless opponent live in one Lua process. The Order was
-- designed for two processes, each with its own G.GAME.pseudorandom table, so
-- sharing the live table would make every bot poll consume the human's queue.
-- Keep the same keyed PRNG state, but give the bot its own copy.
function Order.begin_run(run, seed)
	if not run then return nil end
	seed = tostring(seed or run.seed or "MULTBOT")
	local live = G and G.GAME and G.GAME.pseudorandom
	local same_seed = live and tostring(live.seed or "") == seed
	local state = {
		random = same_seed and copy_map(live) or new_random_state(seed),
		seed = seed,
		ante = nil,
		first_shop_buffoon = false,
		voucher = nil,
		main_slots = (G.GAME.shop and tonumber(G.GAME.shop.joker_max)) or 2,
		booster_slots = (G.GAME.starting_params and tonumber(G.GAME.starting_params.boosters_in_shop) or 2)
			+ ((G.GAME.modifiers and tonumber(G.GAME.modifiers.extra_boosters)) or 0),
		extra_vouchers = (G.GAME.modifiers and tonumber(G.GAME.modifiers.extra_vouchers)) or 0,
		pool_flags = copy_map(G.GAME.pool_flags),
		edition_rate = tonumber(G.GAME.edition_rate) or 1,
		rates = {},
	}
	for _, rate in ipairs({ "joker", "tarot", "planet", "spectral", "playing_card" }) do
		state.rates[rate] = G.GAME[rate .. "_rate"]
	end
	for _, object_type in ipairs((SMODS.ConsumableType or {}).obj_buffer or {}) do
		state.rates[object_type:lower()] = G.GAME[object_type:lower() .. "_rate"]
	end
	-- startGame is received after Multiplayer has selected Ante 1's voucher.
	-- Reuse that result when both players share a seed, together with the already
	-- advanced Voucher0 state copied above. Different-seed games poll privately.
	if same_seed and G.GAME.current_round and G.GAME.current_round.voucher then
		state.voucher = copy_map(G.GAME.current_round.voucher)
		state.ante = tonumber((G.GAME.round_resets or {}).mp_real_ante
			or (G.GAME.round_resets or {}).ante) or 1
	end
	run.order_shop = state
	return state
end

local function bot_game_view(run, order_state)
	local used_jokers = list_map(run.jokers)
	-- Balatro uses the same used-center map to keep held consumables out of
	-- ordinary pools unless Showman is active. Include the bot's private area.
	for _, consumable in ipairs(run.consumables or {}) do
		local key = type(consumable) == "table" and consumable.key or consumable
		if key then used_jokers[key] = true end
	end
	local used_vouchers = list_map(run.vouchers)
	return used_jokers, used_vouchers, {
		used_packs = {},
		voucher = order_state.voucher or { spawn = {} },
		idol_card = {},
	}
end

local function with_private_game(run, callback)
	if not G or not G.GAME or type(pseudoseed) ~= "function"
		or type(pseudorandom) ~= "function" then return nil, "game RNG unavailable" end
	local state = run.order_shop or Order.begin_run(run, run.seed)
	local game, resets = G.GAME, G.GAME.round_resets or {}
	local used_jokers, used_vouchers, current_round = bot_game_view(run, state)
	local saved = {
		random = game.pseudorandom, used_jokers = game.used_jokers,
		used_vouchers = game.used_vouchers, current_round = game.current_round,
		first_shop_buffoon = game.first_shop_buffoon, tags = game.tags,
		pool_flags = game.pool_flags,
		ante = resets.ante, mp_real_ante = resets.mp_real_ante,
		shop_vouchers = G.shop_vouchers,
		extra_vouchers = game.modifiers and game.modifiers.extra_vouchers,
		edition_rate = game.edition_rate,
		rates = {},
		showman = SMODS.showman,
	}
	for rate, _ in pairs(state.rates or {}) do
		saved.rates[rate] = game[rate .. "_rate"]
		game[rate .. "_rate"] = state.rates[rate]
	end
	game.pseudorandom = state.random
	game.used_jokers = used_jokers
	game.used_vouchers = used_vouchers
	game.current_round = current_round
	game.first_shop_buffoon = state.first_shop_buffoon
	game.tags = {}
	game.pool_flags = state.pool_flags
	game.edition_rate = tonumber(run.edition_rate) or state.edition_rate or 1
	-- SMODS.showman normally inspects the human player's live Joker area. The
	-- private bot run must use its own inventory or a human Showman would leak
	-- duplicate permission into the bot's shops.
	SMODS.showman = function()
		for _, key in ipairs(run.jokers or {}) do if key == "j_ring_master" then return true end end
		return false
	end
	if game.modifiers then game.modifiers.extra_vouchers = state.extra_vouchers end
	resets.ante, resets.mp_real_ante = 0, tonumber(run.ante) or 1
	G.shop_vouchers = nil
	local ok, first, second = pcall(callback, state)
	state.first_shop_buffoon = game.first_shop_buffoon == true
	state.voucher = game.current_round and game.current_round.voucher or state.voucher
	game.pseudorandom = saved.random
	game.used_jokers, game.used_vouchers = saved.used_jokers, saved.used_vouchers
	game.current_round, game.first_shop_buffoon = saved.current_round, saved.first_shop_buffoon
	game.tags, game.pool_flags, G.shop_vouchers = saved.tags, saved.pool_flags, saved.shop_vouchers
	game.edition_rate = saved.edition_rate
	SMODS.showman = saved.showman
	if game.modifiers then game.modifiers.extra_vouchers = saved.extra_vouchers end
	for rate, value in pairs(saved.rates) do game[rate .. "_rate"] = value end
	resets.ante, resets.mp_real_ante = saved.ante, saved.mp_real_ante
	if not ok then return nil, first end
	return first, second
end

local function reserve_generated_center(key)
	if key and key ~= "c_base" and not (SMODS.showman and SMODS.showman(key)) then
		G.GAME.used_jokers[key] = true
	end
end

local function pick_from_pool(pool, pool_key)
	local key, attempts = "UNAVAILABLE", 0
	while key == "UNAVAILABLE" do
		attempts = attempts + 1
		local suffix = attempts > 1000 and ("_resample" .. attempts) or ""
		key = pseudorandom_element(pool, pseudoseed(pool_key .. suffix))
	end
	return key
end

local function old_shop_type()
	local rates = {
		{ type = "Joker", value = G.GAME.joker_rate or 0 },
		{ type = "Tarot", value = G.GAME.tarot_rate or 0 },
		{ type = "Planet", value = G.GAME.planet_rate or 0 },
		{ type = (G.GAME.used_vouchers.v_illusion
			and pseudorandom(pseudoseed("illusion")) > 0.6) and "Enhanced" or "Base",
			value = G.GAME.playing_card_rate or 0 },
		{ type = "Spectral", value = G.GAME.spectral_rate or 0 },
	}
	for _, object_type in ipairs((SMODS.ConsumableType or {}).obj_buffer or {}) do
		if object_type ~= "Tarot" and object_type ~= "Planet" and object_type ~= "Spectral" then
			rates[#rates + 1] = {
				type = object_type,
				value = G.GAME[object_type:lower() .. "_rate"] or 0,
			}
		end
	end
	local total = 0
	for _, rate in ipairs(rates) do total = total + rate.value end
	local roll, cursor = pseudorandom(pseudoseed("cdt0")) * total, 0
	for _, rate in ipairs(rates) do
		if roll > cursor and roll <= cursor + rate.value then return rate.type end
		cursor = cursor + rate.value
	end
	return rates[1].type
end

local function order_append(object_type, in_pack)
	if object_type == "Tarot" or object_type == "Planet" or object_type == "Spectral" then
		return object_type .. (in_pack and "_pack" or "")
	end
	if object_type == "Base" or object_type == "Enhanced" then return "sho" end
	-- Multiplayer's create_card wrapper deliberately puts all ordinary
	-- Jokers of a rarity on one game-long queue, regardless of their source.
	return nil
end

local function poll_center(object_type, append)
	if SMODS.optional_features and SMODS.optional_features.object_weights
		and type(SMODS.poll_object) == "function" then
		local key = SMODS.poll_object({
			type = object_type, append = append, guaranteed = object_type == "Enhanced",
		})
		if key == "INTERNAL_PLAYING_CARD" then key = "c_base" end
		return key, {}
	end
	if object_type == "Base" then return "c_base", {} end
	local pool, pool_key = get_current_pool(object_type, nil, nil, append)
	local metadata = {}
	-- The Order advances the Joker edition queue at the same time as the Joker
	-- queue. Preserve the result even though the headless simulator only needs a
	-- subset of stickers/editions today.
	if object_type == "Joker" then
		local attempts, key = 0, "UNAVAILABLE"
		while key == "UNAVAILABLE" do
			local sticker_suffix = ""
			metadata = {}
			local stickers = SMODS.Stickers or {}
			local et_per = pseudorandom("_etper" .. pool_key)
			if G.GAME.modifiers.enable_eternals_in_shop and et_per > 0.7
				and not (stickers.eternal and stickers.eternal.should_apply) then
				metadata.eternal = true
			elseif G.GAME.modifiers.enable_perishables_in_shop and et_per > 0.4 and et_per <= 0.7
				and not (stickers.perishable and stickers.perishable.should_apply) then
				metadata.perishable = true
			end
			if G.GAME.modifiers.enable_rentals_in_shop
				and pseudorandom("_rent" .. pool_key) > 0.7
				and not (stickers.rental and stickers.rental.should_apply) then
				metadata.rental = true
			end
			if metadata.eternal or metadata.perishable or metadata.rental then sticker_suffix = "_sticker" end
			local fallback = attempts > 1000 and ("_resample" .. attempts) or ""
			key = pseudorandom_element(pool, pseudoseed(pool_key .. sticker_suffix .. fallback))
			local edition_key = "edi" .. pool_key .. sticker_suffix
			if key ~= "UNAVAILABLE" and type(poll_edition) == "function" then
				metadata.edition = edition_name(poll_edition(edition_key))
			elseif key == "UNAVAILABLE" then
				-- Rejected queue entries still consume their paired edition entry.
				pseudorandom(pseudoseed(edition_key))
			end
			attempts = attempts + 1
		end
		return key, metadata
	end
	return pick_from_pool(pool, pool_key), metadata
end

local function poll_shop_card()
	if SMODS.optional_features and SMODS.optional_features.object_weights
		and type(SMODS.poll_object_type) == "function" then
		local object_type = SMODS.poll_object_type({ seed = "cdt0" })
		return poll_center(object_type, order_append(object_type, false))
	end
	local object_type = old_shop_type()
	return poll_center(object_type, order_append(object_type, false))
end

local function pack_spec(key)
	local family, size = tostring(key):match("^p_(%a+)_(%a+)_%d+$")
	if family ~= "celestial" and family ~= "buffoon" and family ~= "arcana"
		and family ~= "spectral" and family ~= "standard" then return nil end
	if size ~= "normal" and size ~= "jumbo" and size ~= "mega" then return nil end
	local small = (family == "buffoon" or family == "spectral") and 2 or 3
	local large = (family == "buffoon" or family == "spectral") and 4 or 5
	return {
		family = family,
		choices = size == "normal" and small or large,
		picks = size == "mega" and 2 or 1,
	}
end

local function picked_object(objects, seed_key)
	return pseudorandom_element(objects, pseudoseed(seed_key))
end

local function poll_standard_card()
	-- Mirrors Multiplayer's Standard Booster poll followed by SMODS.create_card.
	-- The Order deliberately fixes these keys to Ante 0.
	local edition = type(poll_edition) == "function"
		and edition_name(poll_edition("standard_edition0", 2, true)) or nil
	local seal = type(SMODS.poll_seal) == "function" and SMODS.poll_seal({ mod = 10 }) or nil
	local enhanced = pseudorandom(pseudoseed("stdset0")) > 0.6
	local suit = picked_object(SMODS.Suits, "sccsuitsta0")
	local rank = picked_object(SMODS.Ranks, "sccranksta0")
	local enhancement
	if enhanced then enhancement = select(1, poll_center("Enhanced", "sta")) end
	return {
		kind = "playing_card",
		suit = suit and (suit.key or suit.name),
		rank = rank and (tonumber(rank.id) or tonumber(rank.nominal)),
		enhancement = enhancement ~= "c_base" and enhancement or nil,
		edition = edition,
		seal = seal,
	}
end

local function poll_pack_card(family)
	if family == "standard" then return poll_standard_card() end
	local object_type = family == "celestial" and "Planet"
		or (family == "arcana" and "Tarot")
		or (family == "spectral" and "Spectral")
		or "Joker"
	local key, metadata = poll_center(object_type, order_append(object_type, true))
	return { kind = "center", key = key, edition = metadata and metadata.edition }
end

-- Uncommon / Rare Tag Joker for the bot's own run.
-- Mirrors tag.lua (create_card('Joker', shop, nil, 0.9 / 1, ..., 'uta' / 'rta'))
-- under Multiplayer's The Order, whose create_card wrapper runs at Ante 0 and
-- replaces a Joker's key_append with its rarity: the Joker comes from its own
-- rarity queue ("Joker20.9" / "Joker31") and its edition from "edi0.90" /
-- "edi10". Only the bot's private RNG copy is consumed.
local TAG_RARITY = { uncommon = 0.9, rare = 1 }
function Order.generate_tag_joker(run, rarity)
	local rarity_value = TAG_RARITY[rarity]
	if not rarity_value or type(get_current_pool) ~= "function" then return nil, "unsupported tag" end
	return with_private_game(run, function()
		local pool, pool_key = get_current_pool("Joker", rarity_value, nil, rarity_value)
		local available = false
		for _, key in ipairs(pool or {}) do available = available or key ~= "UNAVAILABLE" end
		if not available then return nil end   -- e.g. every Rare already owned: the Tag does nothing
		local key = pick_from_pool(pool, pool_key)
		local edition = type(poll_edition) == "function"
			and edition_name(poll_edition("edi" .. tostring(rarity_value) .. "0")) or nil
		reserve_generated_center(key)
		return { kind = "center", key = key, edition = edition }
	end)
end

-- Small/Big Blind tags of `ante` in the game started from `seed_state`
-- ({ seed, hashed_seed } of the host's run). The game
-- draws both tags of every Ante from one "Tag" queue (get_next_tag_key, two
-- draws per Ante from Ante 1), so replaying that queue on a fresh copy gives
-- any Ante's tags without waiting for the host to reach it. The host's RNG
-- and Ante are restored afterwards.
function Order.blind_tags(seed_state, ante)
	ante = tonumber(ante)
	if not (seed_state and ante and ante >= 1 and G and G.GAME and G.GAME.round_resets)
		or type(get_next_tag_key) ~= "function" then return nil end
	local game, resets = G.GAME, G.GAME.round_resets
	local saved_random, saved_ante, saved_real = game.pseudorandom, resets.ante, resets.mp_real_ante
	game.pseudorandom = { seed = seed_state.seed, hashed_seed = seed_state.hashed_seed }
	local ok, tags = pcall(function()
		local result
		for current = 1, ante do
			resets.ante, resets.mp_real_ante = current, current
			result = { Small = get_next_tag_key(), Big = get_next_tag_key() }
		end
		return result
	end)
	game.pseudorandom, resets.ante, resets.mp_real_ante = saved_random, saved_ante, saved_real
	if not ok then return nil end
	return tags
end

-- Contents are polled only after the bot pays for a pack. This gives it the
-- same information boundary as a player while consuming only its private RNG.
function Order.generate_pack(run, pack_key)
	local spec = pack_spec(pack_key)
	if not spec then return nil, "unsupported Booster" end
	return with_private_game(run, function()
		local cards = {}
		for _ = 1, spec.choices do
			local card = poll_pack_card(spec.family)
			cards[#cards + 1] = card
			if card.kind == "center" then reserve_generated_center(card.key) end
		end
		cards.picks = spec.picks
		cards.family = spec.family
		return cards
	end)
end

local function ensure_voucher(run, state)
	local ante = tonumber(run.ante) or 1
	if state.ante == ante and state.voucher then return end
	state.ante = ante
	state.voucher = type(SMODS.get_next_vouchers) == "function"
		and SMODS.get_next_vouchers() or { spawn = {} }
	G.GAME.current_round.voucher = state.voucher
end

local function append_vouchers(keys, state, run)
	local owned = list_map(run.vouchers)
	for _, key in ipairs(state.voucher or {}) do
		if not owned[key] and (state.voucher.spawn or {})[key] then keys[#keys + 1] = key end
	end
end

local function append_packs(keys, state)
	local count = tonumber(state.booster_slots) or 2
	for _ = 1, count do
		local key
		if not state.first_shop_buffoon and not G.GAME.banned_keys.p_buffoon_normal_1 then
			-- Vanilla randomizes only between two visually equivalent first Buffoon
			-- packs with math.random. Choosing _1 keeps this headless path isolated;
			-- neither branch consumes an Order queue.
			key = "p_buffoon_normal_1"
			state.first_shop_buffoon = true
			G.GAME.first_shop_buffoon = true
		else
			local center = get_pack("shop_pack")
			key = center and center.key
		end
		if key then keys[#keys + 1] = key end
	end
end

-- Generate a shop from the bot's private Order queues. `main_only` is the
-- reroll operation: it consumes fresh main-shop cards without moving the pack
-- or voucher queues. A skipped Blind simply never calls this function.
function Order.generate_shop(run, options)
	options = options or {}
	return with_private_game(run, function(state)
		ensure_voucher(run, state)
		local keys, metadata = {}, {}
		local slots = tonumber(options.slots) or tonumber(state.main_slots) or 2
		for _ = 1, slots do
			local key, info = poll_shop_card()
			if key then
				keys[#keys + 1] = key
				metadata[#keys] = info or {}
				reserve_generated_center(key)
			end
		end
		if not options.main_only then
			append_packs(keys, state)
			append_vouchers(keys, state, run)
		end
		keys._metadata = metadata
		return keys
	end)
end

function Order.generate_reroll(run, options)
	options = copy_map(options or {})
	options.main_only = true
	return Order.generate_shop(run, options)
end

local function card_key(card)
	return card and card.config and card.config.center and card.config.center.key
end

local function card_edition(card)
	local edition = card and card.edition
	if type(edition) ~= "table" then return nil end
	return edition.type
		or (edition.negative and "negative")
		or (edition.polychrome and "polychrome")
		or (edition.holo and "holo")
		or (edition.foil and "foil")
end

local function collect_keys()
	local keys, metadata = {}, {}
	local areas = {}
	if G.shop_jokers then areas[#areas + 1] = G.shop_jokers end
	if G.shop_booster then areas[#areas + 1] = G.shop_booster end
	if G.shop_vouchers then areas[#areas + 1] = G.shop_vouchers end
	for _, area in ipairs(areas) do
		for _, card in ipairs((area and area.cards) or {}) do
			local key = card_key(card)
			if key then
				keys[#keys + 1] = key
				metadata[#keys] = { edition = card_edition(card) }
			end
		end
	end
	return keys, metadata
end

function Order.clear()
	Order.queue = {}
	Order.area_identity = nil
	Order.round_identity = nil
	Order.signature = nil
	Order.stable_seconds = 0
	Order.captured = false
	Order.pending_keys = nil
	Order.pending_metadata = nil
	Order.between_shops = false
end

local function current_round_identity()
	if not G or not G.GAME or G.GAME.round == nil then return nil end
	local resets = G.GAME.round_resets or {}
	local ante = resets.mp_real_ante or resets.ante or 0
	return tostring(ante) .. ":" .. tostring(G.GAME.round)
end

function Order.push(keys, metadata)
	local snapshot = {}
	for _, key in ipairs(keys or {}) do snapshot[#snapshot + 1] = key end
	snapshot._metadata = metadata or {}
	Order.queue[#Order.queue + 1] = snapshot
end

function Order.take()
	if #Order.queue == 0 then return nil end
	return table.remove(Order.queue, 1)
end

local function remember_pending(keys, metadata)
	Order.pending_keys, Order.pending_metadata = {}, {}
	for index, key in ipairs(keys or {}) do
		Order.pending_keys[index] = key
		Order.pending_metadata[index] = metadata and metadata[index] or {}
	end
end

local function flush_pending()
	if Order.captured or not Order.pending_keys or #Order.pending_keys == 0 then return end
	Order.push(Order.pending_keys, Order.pending_metadata)
	Order.captured = true
	Order.pending_keys = nil
	Order.pending_metadata = nil
end

local function is_pack_state(state)
	if not G or not G.STATES then return false end
	-- Different Balatro/Steamodded versions expose either one generic BOOSTER
	-- state or one state per pack family. A pack temporarily hides the shop, but
	-- returning from it must not make the remaining cards look like a new shop.
	for name, value in pairs(G.STATES) do
		if value == state and (name == "BOOSTER" or tostring(name):find("PACK", 1, true)) then
			return true
		end
	end
	return false
end

function Order.update(dt)
	if not G or not G.STATES or G.STATE ~= G.STATES.SHOP or not G.shop_jokers then
		-- Animation skipping can leave a shop before the stability debounce.
		-- Preserve the last non-empty view rather than losing that Order shop.
		flush_pending()
		-- Booster packs temporarily leave SHOP and may rebuild G.shop_jokers on
		-- return. Keep the completed round token so the remaining cards are not
		-- mistaken for the next shop.
		Order.area_identity = nil
		Order.signature = nil
		Order.stable_seconds = 0
		if G and G.STATES and not is_pack_state(G.STATE) then
			Order.between_shops = true
		end
		return
	end
	local round_identity = current_round_identity()
	if round_identity and Order.round_identity ~= round_identity then
		flush_pending()
		Order.round_identity = round_identity
		Order.area_identity = nil
		Order.signature = nil
		Order.stable_seconds = 0
		Order.captured = false
		Order.pending_keys = nil
		Order.pending_metadata = nil
	end
	-- Multiplayer can open several real shops without changing G.GAME.round
	-- (notably after skipped Blinds and while the bot is catching up). The old
	-- round-only guard captured the first one and then suppressed every later
	-- shop, causing one-minute ORDER_SHOP timeouts. A non-pack departure from the
	-- shop is the reliable boundary between those visits.
	if Order.between_shops then
		flush_pending()
		Order.area_identity = nil
		Order.signature = nil
		Order.stable_seconds = 0
		Order.captured = false
		Order.pending_keys = nil
		Order.pending_metadata = nil
		Order.between_shops = false
	end
	if round_identity and Order.captured then return end
	local identity = tostring(G.shop_jokers)
	if Order.area_identity ~= identity then
		Order.area_identity = identity
		Order.signature = nil
		Order.stable_seconds = 0
		-- Area identity remains the fallback on game versions without G.GAME.round.
		if not round_identity then Order.captured = false end
	end
	if Order.captured then return end

	local keys, metadata = collect_keys()
	if #keys == 0 then return end
	remember_pending(keys, metadata)
	local signature = table.concat(keys, "|")
	if signature ~= Order.signature then
		Order.signature = signature
		Order.stable_seconds = 0
		return
	end
	Order.stable_seconds = Order.stable_seconds + (dt or 0)
	-- One tenth of a second is enough to avoid observing cards while their areas
	-- are still being populated, but short enough to beat animation-skip shop
	-- inputs. The round token prevents this from recapturing post-pack leftovers.
	if Order.stable_seconds >= 0.1 then
		Order.push(keys, metadata)
		Order.captured = true
		Order.pending_keys = nil
		Order.pending_metadata = nil
	end
end

function Order.install()
	local update_ref = Game.update
	function Game:update(dt)
		local result = update_ref(self, dt)
		-- Retained for compatibility diagnostics only. Normal bot matches generate
		-- from their private queues and must not accumulate the human's shops.
		if Order.observer_enabled then Order.update(dt) end
		return result
	end
end

function Order.enable_observer(value)
	Order.observer_enabled = value == true
end

return Order
