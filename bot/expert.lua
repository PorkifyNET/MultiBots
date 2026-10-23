-- The Expert: MultiBots' own player, as a decision policy for bot/simulator.lua.
--
-- The simulator holds only the game's rules. It asks its policy
-- (dependencies.Policy, state.Policy) for every player decision, and the
-- Expert is one such policy:
--   Expert.policy(modules) builds it from bot/policy.lua (hand play, shop
--   ranking, skip chances), bot/strategy.lua (build planning) and the card
--   values below; Expert.modules(modules) returns a copy of `modules` whose
--   Policy is the Expert, for Simulator.new / Simulator.run.
-- An external policy may define only some decisions and inherit the rest
-- (setmetatable(mine, { __index = Expert.policy(modules) })). A decision the
-- policy does not define is declined: the first action (leave, skip, done,
-- keep, the first legal target set), no reroll, no skip, no rearrangement.
-- choose_turn is required.
--
-- Card values: bot/expert_values.lua holds the Expert's built-in base value of
-- every card; bot/card_values.yaml (0..100, 50 = no change) lets the user
-- scale them per card. The simulator reads neither.
--
-- Decisions (policy[name](state, ctx); hooks that pick an action return a
-- 1-based index into ctx.actions, optionally followed by a meta table whose
-- `log` fields go into the decision log):
--   choose_turn(args, state)  Play or discard (bot/policy.lua's choose_turn,
--                   given the Expert's hints, weights, difficulty and its
--                   decision stream). args = { hand, discards_left, hands_left,
--                   starting_discards, starting_hands, discards_used_this_hand,
--                   current_score, target, draw_pile, round_name, turn,
--                   evaluate(cards, full_hand[, joker_order]) }.
--   shop_open       Entering a shop, one sale per call.
--                   ctx = { actions } with actions done | sell_joker k (every k).
--                   Expert: sells the rightmost unsupported Joker (content the
--                   simulator cannot model), else done.
--                   A debuffed (expired Perishable) Joker is sold the same way.
--   shop_step       One shop action per call.
--                   ctx = { session, offers, actions, purchases, steps,
--                   shop_rerolls, reroll_cost } with actions (fixed order)
--                   leave | reroll | buy offer [+ sell joker j | + sell
--                   consumable k] | sell_joker j | sell_consumable k | use k.
--                   Every legal action is listed. Expert: its purchase loop;
--                   never rerolls here.
--   reroll_step     After a shop visit (also after a reroll): reroll again?
--                   ctx = { report, cost, rerolls_this_shop, headless }
--                   -> boolean. Expert: its reroll heuristic on a live Order
--                   shop, never on a headless one (headless = true).
--   legacy_pack_step  legacy_shop only: the picks of a pack offered opened.
--                   ctx = { pack, contents, stream } -> the picked contents
--                   (none: the pack is not offered).
--   pack_step       One Booster Pack pick per call.
--                   ctx = { pack, contents, picks_left, picked, session,
--                   actions } with actions skip | take c [+ sell joker j].
--                   Expert: its picks (chosen when the pack opens).
--   consumable_step Held consumables at shop start, blind start and after
--                   Cartomancer. ctx = { source, session, consumables, actions }
--                   with actions done | use k | sell_consumable k.
--   target_step     The cards a Tarot or Spectral changes.
--                   ctx = { tool, effect, hand, actions }: every legal target
--                   set of the drawn hand, in hand order (Death: ordered
--                   pairs, the first card is copied onto the second). May
--                   return index, { cards } to apply the set's cards in another
--                   order (ids of Strength and suit Tarots carry the position).
--                   Expert: its deck-fix targets.
--   boss_disable_step  Luchador: sell it to disable the Boss Blind?
--                   ctx = { boss, simulated, actions } with actions keep |
--                   sell_joker. Expert: sells it when the simulator applies
--                   this Boss's ability (simulated = true).
--   skip_pair       Which Blinds of the Ante to skip.
--                   ctx = { mode, ante, small = { tag, supported },
--                   big = { tag, supported } } -> small_selected, big_selected.
--                   Expert: Policy.should_skip_blind per Blind, then at most
--                   one reactive skip.
--   joker_order     The Joker order a candidate play is scored with (asked
--                   once per evaluate call of choose_turn).
--                   ctx = { cards, full_hand, context, evaluate_order }
--                   -> order[, result]. evaluate_order(order) scores the cards
--                   with exactly that order; a returned result must come from
--                   it. Expert: its layout search (Blueprint and Brainstorm
--                   placement, additive before xMult).
--   arrange_jokers  Free Joker rearrangement. ctx = { source, jokers } with
--                   source "shop" (leaving a shop) or "blind_start" (before
--                   the round's Joker effects) -> a permutation or nil.
--                   Expert: at shop exit additive, Polychrome, then xMult
--                   (nothing while a copy Joker is owned); no change at
--                   blind start.
--   observe(state, event, data)  Announcements at fixed points ("new",
--                   "set_ante", "shop_open", "shop_buy", "shop_sell",
--                   "shop_end", "round_start", "turn", "pvp_effect",
--                   "deck_tool", "decision"). The Expert keeps its own memory
--                   there: build plan (state.strategy_plan, strategy_open),
--                   deck-fix target, settings, and the plan fields of the log.
--
-- The Expert keeps its valuation of a card it bought or saw in a pack on that
-- card (`expert_utility`), so it follows the card when the rules copy it.
-- It sets state.expert_compat, the rule deviations it was tuned with (see
-- bot/simulator.lua): The Emperor / The High Priestess use their cards at
-- once, Judgement can be used with full Joker slots, and a Tarot can be spent
-- without targets.
--
-- Stake stickers (bot/simulator.lua): an owned Joker's are in
-- state.joker_stickers[key] = { eternal } | { perishable, perish_tally } and/or
-- rental; shop offers and Buffoon Pack contents carry eternal / perishable /
-- rental. An Eternal Joker never has a sell_joker action (nor a "+ sell joker"
-- compound); a Perishable Joker whose perish_tally reached 0 is debuffed
-- (Simulator.rules.joker_debuffed) and does nothing; a Rental Joker costs $1
-- and $3 at the end of every round. The run's rules: Simulator.rules.sticker_rules.

local Expert = { hooks = {} }
local R   -- the simulator's rules helpers (Simulator.rules), set by Expert.policy

local function copy_array(source)
	local out = {}
	for i, value in ipairs(source or {}) do out[i] = value end
	return out
end

local function copy_map(source)
	local out = {}
	for key, value in pairs(source or {}) do out[key] = value end
	return out
end

local function has_value(items, value)
	for _, item in ipairs(items) do if item == value then return true end end
	return false
end

---------------------------------------------------------------------------
-- Files next to this one: Lua modules and the card value config.
---------------------------------------------------------------------------

local here = (function()
	local source = debug and debug.getinfo and debug.getinfo(1, "S").source or ""
	return source:match("^@(.*[/\\])")
end)()

local function load_module(name)
	if here then
		local chunk = loadfile(here .. name)
		if chunk then return chunk() end
	end
	local smods = rawget(_G, "SMODS")
	if smods and smods.load_file then return assert(smods.load_file("bot/" .. name, "MultiBots"))() end
	return assert(loadfile("bot/" .. name))()
end

local YamlLite = load_module("yaml_lite.lua")
local BASE = load_module("expert_values.lua")

-- bot/card_values.yaml: the user's 0..100 scale per card (a missing file or
-- card counts as 50). In the game from the mod's folder, headless next to
-- this file.
function Expert.load_card_values(path)
	if not path then
		local smods = rawget(_G, "SMODS")
		local mod = smods and smods.Mods and smods.Mods.MultiBots
		path = mod and mod.path and (mod.path .. "bot/card_values.yaml")
			or ((here or "bot/") .. "card_values.yaml")
	end
	Expert.card_values = YamlLite.load(path, "bot/card_values.yaml") or {}
	return Expert.card_values
end
Expert.load_card_values()

local SETS = { Joker = "jokers", Tarot = "tarots", Planet = "planets", Spectral = "spectrals",
	Voucher = "vouchers", Booster = "packs" }

local function value_set(item)
	if item.set and SETS[item.set] then return SETS[item.set] end
	local key = tostring(item.key or "")
	local prefix = key:sub(1, 2)
	if prefix == "j_" then return "jokers" end
	if prefix == "v_" then return "vouchers" end
	if prefix == "p_" then return "packs" end
	if item.type == "planet" then return "planets" end
	for _, set in ipairs({ "tarots", "spectrals", "planets" }) do
		if BASE[set][key] ~= nil then return set end
	end
	return nil
end

-- A card value scales `value` by value / 50; exactly 50 (or none) leaves it untouched.
local function scaled(set, key, value)
	local section = set and Expert.card_values[set]
	local setting = section and tonumber(section[key])
	if value == nil or setting == nil then return value end
	setting = math.max(0, math.min(100, setting))
	if setting == 50 then return value end
	return value * (setting / 50)
end

-- The Expert's base value of a card: the `utility` a catalog entry brings
-- with it (adapters and test catalogs), else its built-in value; scaled by
-- bot/card_values.yaml.
local function prior(item)
	local set = value_set(item)
	local base = item.utility
	if base == nil and set then base = BASE[set][item.key] end
	return scaled(set, item.key, base)
end

-- What the Expert thinks a held card is worth (its valuation when it bought
-- or picked it, else its base value).
local function base_of(item)
	if item.expert_utility ~= nil then return item.expert_utility end
	return prior(item)
end

-- A copy carrying the Expert's base value as `utility` (what bot/strategy.lua reads).
local function with_prior(item)
	local view = copy_map(item)
	view.utility = base_of(item)
	return view
end

-- Test access to a card's base value.
Expert.prior = prior

local function weight(state, key)
	return tonumber(state and state.weights and state.weights[key]) or 1
end

local function analyze(state)
	if state.Strategy then state.strategy_plan = state.Strategy.analyze(state) end
end

---------------------------------------------------------------------------
-- Deck fixing: which rank and suit the Expert works its deck towards, and
-- the cards its Tarots and Spectrals target.
---------------------------------------------------------------------------

local function dominant_suit(deck)
	local counts, best_suit, best_count = {}, "Spades", -1
	for _, card in ipairs(deck) do counts[card.suit] = (counts[card.suit] or 0) + 1 end
	for _, suit in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
		if (counts[suit] or 0) > best_count then best_suit, best_count = suit, counts[suit] or 0 end
	end
	return best_suit
end

local function card_quality(card)
	return card.rank + (card.enhancement and 8 or 0) + (card.edition and 12 or 0) + (card.seal and 5 or 0)
end

local function ordered_cards(deck, ascending, score_card)
	local result = {}
	for _, card in ipairs(deck) do result[#result + 1] = card end
	table.sort(result, function(a, b)
		local aq, bq = (score_card or card_quality)(a), (score_card or card_quality)(b)
		if aq == bq then return a.id < b.id end
		if ascending then return aq < bq end
		return aq > bq
	end)
	return result
end

local function deck_fix_preferences(state)
	if state.Strategy and state.Strategy.deck_fix_target then
		return state.Strategy.deck_fix_target(state)
	end
	local rank_counts, suit_counts = {}, {}
	for _, card in ipairs(state.deck or {}) do
		rank_counts[card.rank] = (rank_counts[card.rank] or 0) + 1
		suit_counts[card.suit] = (suit_counts[card.suit] or 0) + 1
	end
	local rank_scores, suit_scores = {}, {}
	for rank = 2, 14 do rank_scores[rank] = rank_counts[rank] or 0 end
	for _, suit in ipairs(state.Cards.suits or { "Spades", "Hearts", "Clubs", "Diamonds" }) do
		suit_scores[suit] = suit_counts[suit] or 0
	end
	-- Kings and Hearts are the strongest neutral destination: they preserve
	-- face-card synergies and can grow into Baron/Bloodstone-style engines.
	rank_scores[13] = (rank_scores[13] or 0) + 1.5
	suit_scores.Hearts = (suit_scores.Hearts or 0) + 1.5
	for _, key in ipairs(state.jokers or {}) do
		local effect = state.joker_effects and state.joker_effects[key]
		if effect then
			if effect.rank then rank_scores[effect.rank] = (rank_scores[effect.rank] or 0) + 8 end
			for _, rank in ipairs(effect.ranks or {}) do
				-- Broad parity/Fibonacci-style effects should inform card value without
				-- arbitrarily choosing the first of several equally supported ranks.
				rank_scores[rank] = (rank_scores[rank] or 0) + 1
			end
			if effect.suit then suit_scores[effect.suit] = (suit_scores[effect.suit] or 0) + 8 end
		end
	end
	local best_rank, best_rank_score = 13, -1
	for rank = 2, 14 do
		if (rank_scores[rank] or 0) > best_rank_score then
			best_rank, best_rank_score = rank, rank_scores[rank] or 0
		end
	end
	local best_suit, best_suit_score = "Hearts", -1
	for _, suit in ipairs({ "Hearts", "Spades", "Clubs", "Diamonds" }) do
		if (suit_scores[suit] or 0) > best_suit_score then
			best_suit, best_suit_score = suit, suit_scores[suit] or 0
		end
	end
	return best_rank, best_suit
end

local function joker_card_synergy(state, card)
	local score = 0
	for _, key in ipairs(state.jokers or {}) do
		local effect = state.joker_effects and state.joker_effects[key]
		if effect then
			if effect.rank == card.rank then score = score + 8 end
			for _, rank in ipairs(effect.ranks or {}) do
				if rank == card.rank then score = score + 5; break end
			end
			if effect.suit == card.suit then score = score + 5 end
		end
	end
	return score
end

local function deck_fix_score(state, card, rank, suit)
	if not rank or not suit then rank, suit = deck_fix_preferences(state) end
	local score = (card.rank or 0) * 0.1 + joker_card_synergy(state, card)
	if card.rank == rank then score = score + 18 end
	if card.suit == suit then score = score + 7 end
	if card.rank == 13 then score = score + 2 end
	if card.suit == "Hearts" then score = score + 1 end
	if card.rank == 13 and card.suit == "Hearts" then score = score + 3 end
	if card.enhancement then score = score + 8 end
	if card.edition then score = score + (card.edition == "polychrome" and 12 or 7) end
	if card.seal then score = score + (card.seal == "Red" and 10 or 5) end
	return score
end

local function next_rank(card) return card.rank == 14 and 2 or card.rank + 1 end

-- The cards the Expert targets among the hand-size draw `hand`
-- (convert: { source, target }; duplicate: { source }).
local function default_targets(state, tool, hand, low, high, fix_score, preferred_rank)
	local effect, cards = tool.effect, {}
	if effect == "remove" then
		for index = 1, math.min(tool.count or 2, #low - 1) do cards[#cards + 1] = low[index] end
	elseif effect == "rank" then
		local target_rank = preferred_rank
		local candidates = ordered_cards(hand, false, function(card)
			return (next_rank(card) == target_rank and 100 or 0) + fix_score(card)
		end)
		for index = 1, math.min(tool.count or 2, #candidates) do cards[#cards + 1] = candidates[index] end
	elseif effect == "suit" then
		local target = tool.suit or dominant_suit(state.deck)
		local candidates = ordered_cards(hand, false, function(card)
			return fix_score(card) + (card.suit ~= target and 20 or 0)
		end)
		for _, card in ipairs(candidates) do
			if card.suit ~= target and #cards < (tool.count or 3) then cards[#cards + 1] = card end
		end
	elseif effect == "enhance" then
		local eligible = {}
		for _, card in ipairs(ordered_cards(hand, false, fix_score)) do
			if not card.enhancement then eligible[#eligible + 1] = card end
		end
		for index = 1, math.min(tool.count or 2, #eligible) do cards[#cards + 1] = eligible[index] end
	elseif effect == "convert" then
		if high[1] and low[1] and high[1] ~= low[1] then cards = { high[1], low[1] } end
	elseif effect == "duplicate" then
		if high[1] then cards = { high[1] } end
	elseif effect == "edition" or effect == "seal" then
		for _, card in ipairs(high) do
			if not card[effect] then cards = { card }; break end
		end
	end
	return cards
end

local TARGET_SUITS = { "Spades", "Hearts", "Clubs", "Diamonds" }
local MAX_TARGET_SETS = 8

-- Up to 8 suggested target sets among the drawn hand (low/high), deduplicated
-- by card set; the Expert's own set first (Expert.default_targets).
local function target_suggestions(state, tool, default, low, high, preferred_rank, preferred_suit)
	local actions, seen = {}, {}
	local effect = tool.effect
	local function add(cards)
		if #cards == 0 or #actions >= MAX_TARGET_SETS then return end
		local ids = {}
		for index, card in ipairs(cards) do ids[index] = tostring(card.id) end
		if effect ~= "convert" then table.sort(ids) end   -- convert: ordered source, target
		local key = table.concat(ids, ",")
		if seen[key] then return end
		seen[key] = true
		local action = { type = "target", cards = cards }
		if effect == "convert" then action.source, action.target = cards[1], cards[2] end
		actions[#actions + 1] = action
	end
	local function take(list, count, accept)
		local cards = {}
		for _, card in ipairs(list) do
			if #cards >= count then break end
			if accept(card) then cards[#cards + 1] = card end
		end
		return cards
	end
	add(default)
	if effect == "suit" or effect == "enhance" or effect == "seal" or effect == "edition" or effect == "duplicate" then
		local suit_target = tool.suit or dominant_suit(state.deck)
		local count = effect == "suit" and (tool.count or 3) or (effect == "enhance" and (tool.count or 2) or 1)
		local function eligible(card)
			if effect == "suit" then return card.suit ~= suit_target end
			if effect == "enhance" then return not card.enhancement end
			if effect == "edition" then return not card.edition end
			if effect == "seal" then return not card.seal end
			return true
		end
		for _, suit in ipairs(TARGET_SUITS) do
			add(take(high, count, function(card) return card.suit == suit and eligible(card) end))
		end
		add(take(high, count, function(card) return card.rank == preferred_rank and eligible(card) end))
	elseif effect == "remove" then
		local count = math.min(tool.count or 2, #low - 1)
		for _, suit in ipairs(TARGET_SUITS) do
			if suit ~= preferred_suit then add(take(low, count, function(card) return card.suit == suit end)) end
		end
		add(take(low, count, function(card) return not card.enhancement end))
	elseif effect == "rank" then
		local counts = {}
		for _, card in ipairs(state.deck) do counts[card.rank] = (counts[card.rank] or 0) + 1 end
		local ranks = {}
		for rank in pairs(counts) do ranks[#ranks + 1] = rank end
		table.sort(ranks, function(a, b)
			if counts[a] == counts[b] then return a > b end
			return counts[a] > counts[b]
		end)
		for index = 1, math.min(3, #ranks) do
			local wanted = ranks[index]
			add(take(high, tool.count or 2, function(card) return next_rank(card) == wanted end))
		end
	elseif effect == "convert" then
		for index = 1, 4 do
			if high[index] and low[1] and high[index] ~= low[1] then add({ high[index], low[1] }) end
		end
		for _, suit in ipairs(TARGET_SUITS) do
			if low[1] and suit ~= low[1].suit then
				local lowest = take(low, 1, function(card) return card.suit == suit end)[1]
				if lowest and high[1] and lowest ~= high[1] then add({ high[1], lowest }) end
			end
		end
	end
	return actions
end

-- The rank/suit preferences of the tool being used, taken when the simulator
-- announces it ("deck_tool"), before the deck-fix memory is written.
local tool_preferences = setmetatable({}, { __mode = "k" })

local function remember_deck_fix(state, tool)
	local preferred_rank, preferred_suit = deck_fix_preferences(state)
	tool_preferences[state] = { tool = tool, rank = preferred_rank, suit = preferred_suit }
	if tool.effect == "rank" then
		state.deck_fix_rank = state.deck_fix_rank or preferred_rank
	elseif tool.effect == "suit" then
		state.deck_fix_suit = state.deck_fix_suit or tool.suit or preferred_suit
	elseif tool.effect == "remove" or tool.effect == "immolate"
		or tool.effect == "convert" or tool.effect == "duplicate" then
		state.deck_fix_rank = state.deck_fix_rank or preferred_rank
		state.deck_fix_suit = state.deck_fix_suit or preferred_suit
	end
end

local function expert_targets(state, tool, hand)
	local preferences = tool_preferences[state]
	local preferred_rank, preferred_suit
	if preferences and preferences.tool == tool then
		preferred_rank, preferred_suit = preferences.rank, preferences.suit
	else
		preferred_rank, preferred_suit = deck_fix_preferences(state)
	end
	local function fix_score(card) return deck_fix_score(state, card, preferred_rank, preferred_suit) end
	local low = ordered_cards(hand, true, fix_score)
	local high = ordered_cards(hand, false, fix_score)
	local cards = default_targets(state, tool, hand, low, high, fix_score, preferred_rank)
	return cards, low, high, preferred_rank, preferred_suit
end

-- Test access: the Expert's targets and suggestions for `hand`.
function Expert.default_targets(state, tool, hand)
	local cards, low, high, preferred_rank, preferred_suit = expert_targets(state, tool, hand)
	return cards, target_suggestions(state, tool, cards, low, high, preferred_rank, preferred_suit)
end

local function same_cards(left, right, ordered)
	if #left ~= #right then return false end
	if ordered then
		for index, card in ipairs(left) do if right[index] ~= card then return false end end
		return true
	end
	local wanted = {}
	for _, card in ipairs(left) do wanted[card] = true end
	for _, card in ipairs(right) do if not wanted[card] then return false end end
	return true
end

-- With no deck-fix target in the drawn hand the Expert spends the card
-- without targets (the "none" action of its targetless_tools rule), else
-- takes the first set.
local function no_target(ctx)
	for index, action in ipairs(ctx.actions) do
		if action.type == "none" then return index end
	end
	return 1
end

function Expert.hooks.target_step(state, ctx)
	local cards = expert_targets(state, ctx.tool, ctx.hand)
	if #cards == 0 then return no_target(ctx) end
	for index, action in ipairs(ctx.actions) do
		if same_cards(cards, action.cards, ctx.effect == "convert") then
			return index, { cards = cards }
		end
	end
	return 1
end

---------------------------------------------------------------------------
-- Valuations.
---------------------------------------------------------------------------

-- share of the vanilla Jokers of `rarity` the run simulates (the rest give
-- nothing, see the simulator's roll_vanilla_joker).
local function joker_rarity_share(state, rarity)
	local supported = 0
	for _, joker in ipairs(state.joker_pool or {}) do
		if R.inferred_rarity(joker) == rarity and not state.banned[joker.key] then supported = supported + 1 end
	end
	local total = math.max(supported, R.vanilla_jokers_by_rarity[rarity] or 0)
	return total > 0 and supported / total or 0
end

-- Spectral value adjusted for what using it costs right now: Jokers the card
-- destroys, money Wraith takes, Ectoplasm's growing hand size loss. A card
-- that cannot be used is worth nothing but its sale.
local function spectral_offer_utility(state, offer)
	local utility = offer.utility or 0
	local usable = R.spectral_usable(state, offer)
	if usable == false then return 0 end
	local jokers = #(state.jokers or {})
	if offer.effect == "generate_joker" and offer.rarity then
		utility = utility * joker_rarity_share(state, offer.rarity)
		if offer.clear_money then utility = utility - math.max(0, state.money or 0) * 0.5 end
	elseif offer.effect == "duplicate_joker" or offer.effect == "polychrome_joker" then
		utility = utility - (jokers - 1) * 17
	elseif offer.effect == "negative_joker" then
		utility = utility - ((state.ecto_minus or 1) - 1) * 12
	elseif offer.effect == "hand_rank" then
		utility = utility - math.max(0, 8 - R.current_hand_size(state)) * 4
	end
	return math.max(0, utility)
end

-- The Expert's value of a Planet card (bot/strategy.lua), scaled by its card value.
local function planet_value(state, key, hand, fallback)
	local value = state.Strategy and state.Strategy.planet_utility(state, hand, state.strategy_plan) or fallback
	return scaled("planets", key, value)
end

local function deck_tool_utility(state, tool)
	local offer = with_prior(tool)
	if state.Strategy then offer.utility = state.Strategy.deck_tool_utility(state, offer, state.strategy_plan) end
	if offer.effect == "repeat_consumable" then
		local last = state.last_consumable
		if not last then
			offer.utility = 0
		elseif last.type == "planet" then
			offer.utility = planet_value(state, last.key, last.hand, base_of(last) or 10)
		else
			offer.utility = state.Strategy and state.Strategy.deck_tool_utility(
				state, with_prior(last), state.strategy_plan
			) or base_of(last) or 0
		end
	end
	if offer.set == "Spectral" and R.spectral_usable(state, offer) ~= nil then
		offer.utility = spectral_offer_utility(state, offer)
	end
	if offer.effect == "add" then
		offer.utility = offer.utility + (has_value(state.jokers, "j_hologram") and 12 or 0)
			+ (#state.deck < state.starting_deck_size - 5 and 6 or 0)
			- math.max(0, #state.deck - state.starting_deck_size) * 2
	end
	return offer.utility
end

-- Test access to the Expert's value of a Tarot or Spectral.
Expert.deck_tool_value = function(state, tool) return deck_tool_utility(state, tool) end

local function consumable_utility(state, consumable)
	if consumable.type == "planet" then
		return (planet_value(state, consumable.key, consumable.hand, base_of(consumable) or 10))
			* weight(state, "consumable_value")
	end
	if consumable.type == "deck_tool" then
		return (deck_tool_utility(state, consumable) or 0) * weight(state, "consumable_value")
	end
	return (base_of(consumable) or 0) * weight(state, "consumable_value")
end

local function joker_utility(state, joker)
	return state.Strategy and state.Strategy.joker_utility(state, with_prior(joker), state.strategy_plan)
		or prior(joker)
end

local enhancement_value = {
	m_bonus = 5, m_mult = 5, m_lucky = 8, m_glass = 7,
	m_steel = 9, m_gold = 8, m_wild = 4,
}
local edition_value = { foil = 4, holo = 6, polychrome = 11 }
local seal_value = { Red = 9, Blue = 5, Gold = 6, Purple = 5 }

local function playing_card_utility(state, card)
	local preferred_rank, preferred_suit = deck_fix_preferences(state)
	local exact, perfect = 0, 0
	for _, existing in ipairs(state.deck or {}) do
		if existing.rank == preferred_rank and existing.suit == preferred_suit then
			exact = exact + 1
			if existing.enhancement and existing.edition == "polychrome" and existing.seal == "Red" then
				perfect = perfect + 1
			end
		end
	end

	local value = -5 + joker_card_synergy(state, card)
	if card.rank == preferred_rank then value = value + math.max(4, 12 - math.floor(exact / 4)) end
	if card.suit == preferred_suit then value = value + 5 end
	if card.rank == preferred_rank and card.suit == preferred_suit then
		value = value + math.max(2, 7 - math.floor(perfect / 3))
	end
	value = value + (enhancement_value[card.enhancement] or 0)
	value = value + (edition_value[card.edition] or 0)
	value = value + (seal_value[card.seal] or 0)
	if has_value(state.jokers, "j_hologram") then value = value + 12 end
	-- A bloated deck makes an ordinary off-target card actively harmful.
	value = value - math.max(0, #state.deck - state.starting_deck_size) * 0.75
	return value
end

local function pack_support_probability(state, spec)
	local set = spec.family == "buffoon" and "Joker"
		or (spec.family == "celestial" and "Planet")
		or (spec.family == "arcana" and "Tarot") or "Spectral"
	local chance = 1
	if spec.family ~= "standard" then
		local supported = 0
		if set == "Joker" then
			supported = #(state.joker_pool or {})
		elseif set == "Planet" then
			supported = #(state.planet_pool or {})
		else
			for _, tool in ipairs(state.deck_tools or {}) do
				if tool.set == set then supported = supported + 1 end
			end
		end
		local unsupported = state.content_catalog and state.content_catalog.unsupported
			and #(state.content_catalog.unsupported[set] or {}) or 0
		local total = supported + unsupported
		if total <= 0 then return 0 end
		local modeled_rate = supported / total
		local visible_choices = math.max(1, tonumber(spec.choices) or 1)
		chance = 1 - (1 - modeled_rate) ^ visible_choices
	end

	-- Revealed packs are also evidence about whether the modeled cards are useful
	-- to this particular build. Blend that evidence with the catalog prior so a
	-- run stops repeatedly paying for a family that keeps producing no valid pick.
	local history = state.pack_history and state.pack_history[spec.family]
	if history and (history.opened or 0) > 0 then
		chance = (chance * 2 + (history.picked or 0)) / (2 + history.opened)
	end
	return math.max(0, math.min(1, chance))
end

local function expected_pack_utility(state, spec, key)
	local missing = math.max(0, (state.joker_limit or 5) - #(state.jokers or {}))
	local value
	if spec.family == "buffoon" then value = 16 + missing * 4 end
	if spec.family == "celestial" then
		local plan = state.strategy_plan or {}
		value = 15 + math.min(8, (state.hand_usage[plan.primary_hand] or 0) * 0.5)
		if R.telescope_planet(state) then value = value + 8 end
	end
	if spec.family == "arcana" then
		local pressure = state.Strategy and state.Strategy.deck_fix_pressure
			and state.Strategy.deck_fix_pressure(state) or 0
		value = 17 + pressure + math.max(0, 52 - #state.deck) * 0.5
		if has_value(state.vouchers or {}, "v_omen_globe") then value = value + 4 end
	end
	if spec.family == "spectral" then value = state.ghost_deck and 23 or 18 end
	-- Standard Packs can advance the target card plan, but become less attractive
	-- as ordinary additions bloat an already large deck.
	if spec.family == "standard" then
		value = math.max(10, 17 - math.max(0, #state.deck - state.starting_deck_size) * 1.5)
	end
	return scaled("packs", key, (value or 0) * pack_support_probability(state, spec) * weight(state, "pack_value"))
end

local function joker_sell_utility(state, key)
	local details = with_prior(R.joker_details(state, key))
	if state.Strategy then return state.Strategy.joker_utility(state, details, state.strategy_plan) end
	return details.utility or 0
end

local function reserve(state)
	return state.Strategy and state.Strategy.reserve(state, state.strategy_plan) or 0
end

local scaling_kinds = {
	straight_scaling_chips = true,
	four_card_scaling_chips = true,
	bus_scaling_mult = true,
	green_scaling_mult = true,
	planet_scaling_xmult = true,
	tarot_scaling_mult = true,
	deck_add_scaling_xmult = true,
	hand_scaling_mult = true,
	rank_scaling_chips = true,
	chance_hand_level = true,
	played_card_chip_growth = true,
	discard_suit_scaling_chips = true,
	sacrifice_scaling_mult = true,
	blind_scaling_xmult = true,
	opponent_sale_mult = true,
	avoid_most_played_xmult = true,
	-- group C jokers
	enhancement_steal_xmult = true,
	discard_count_xmult = true,
	-- group B jokers
	lucky_scaling_xmult = true,
}

local power_kinds = {
	flat_xmult = true,
	hand_xmult = true,
	repeat_hand_xmult = true,
	held_suit_xmult = true,
	held_rank_xmult = true,
	rarity_xmult = true,
	scoring_suits_xmult = true,
	mixed_suit_xmult = true,
	chance_suit_xmult = true,
	periodic_xmult = true,
	retrigger_scoring = true,
	first_scoring_retrigger = true,
	rank_retrigger = true,
	face_retrigger = true,
	round_joker_generation = true,
	round_tarot_generation = true,
	held_retrigger = true,
	rotating_suit_xmult = true,
	blind_scaling_xmult = true,
	avoid_most_played_xmult = true,
	chance_xmult_money = true,
	-- group C jokers
	limited_retrigger = true,
	rank_xmult = true,
	skip_scaling_xmult = true,
}

local function shop_priority(state, offer)
	local value = offer.utility or 0
	local missing = math.max(0, state.joker_limit - #state.jokers)
	if offer.type == "joker" then
		value = value + math.min(16, missing * 4)
		local effect = state.joker_effects[offer.key]
		-- Filling Stencil's final open slot removes half of its current XMult.
		-- Price that opportunity cost into ordinary Joker offers so a mediocre
		-- additive card cannot quietly turn x2 into x1. Negative Jokers and other
		-- Stencils do not consume the protected slot.
		if offer.edition ~= "negative" and (not effect or effect.kind ~= "empty_slot_xmult") then
			local stencils = 0
			for _, key in ipairs(state.jokers or {}) do
				local owned = state.joker_effects[key]
				if owned and owned.kind == "empty_slot_xmult" then stencils = stencils + 1 end
			end
			if stencils > 0 then
				local factor = math.max(1, state.joker_limit - #state.jokers + stencils)
				if factor > 1 then value = value - stencils * (40 / factor) end
			end
		end
		if effect and scaling_kinds[effect.kind] then value = value + ((state.ante or 1) <= 3 and 7 or 3) end
		if effect and power_kinds[effect.kind] then value = value + ((state.ante or 1) >= 2 and 6 or 3) end
		if effect and effect.kind == "deck_add_scaling_xmult" and (state.cards_added or 0) == 0 then
			-- Hologram is inert until another purchase adds cards. Do not value the
			-- promise of scaling like established scaling when the bot cannot also
			-- afford an enabler after buying it.
			value = value - 14
			if state.money - (offer.cost or 0) < 4 then value = value - 8 end
		end
	elseif offer.type == "pack" and offer.family == "buffoon" and missing > 0 then
		value = value + math.min(12, missing * 3)
	elseif missing >= 2 then
		-- Consumables remain useful, but an incomplete scoring engine should not
		-- repeatedly beat a viable Joker merely because pack utility is additive.
		value = value - math.min(12, missing * 3)
	end
	return value
end

-- The purchase priority of an offer (the shop candidates' `utility`).
local function offer_priority(state, offer)
	return shop_priority(state, offer) - (weight(state, "economy_value") - 1) * offer.cost * 4
end

-- The Expert's value of a shop offer before its purchase priority: refreshed
-- at every shop decision, except a Voucher's, which keeps its value from when
-- the Expert first saw it.
local voucher_values = setmetatable({}, { __mode = "k" })

local function offer_value(state, offer)
	if offer.type == "voucher" then
		if voucher_values[offer] == nil then
			local value = prior(offer)
			if offer.effect == "planet_rate" and R.has_joker_kind(state, "planet_scaling_xmult") then
				value = (value or 0) + 10
			end
			voucher_values[offer] = value or false
		end
		return voucher_values[offer] or nil
	end
	if not state.Strategy then
		if offer.type == "joker" then return prior(R.joker_details(state, offer.key)) end
		if offer.type == "planet" then
			return scaled("planets", offer.key, (prior(offer) or 10)
				+ (state.hand_usage[offer.hand] or 0) * 4 + (state.levels[offer.hand] or 1))
		end
	end
	if offer.type == "joker" then
		return state.Strategy.joker_utility(state, with_prior(R.joker_details(state, offer.key)), state.strategy_plan)
	elseif offer.type == "planet" then
		return planet_value(state, offer.key, offer.hand, nil)
	elseif offer.type == "deck_tool" then
		for _, tool in ipairs(state.deck_tools) do
			if tool.key == offer.key then return deck_tool_utility(state, tool) end
		end
		return deck_tool_utility(state, offer)
	elseif offer.type == "pack" then
		return expected_pack_utility(state, R.pack_spec(offer.key) or offer, offer.key)
	elseif offer.type == "playing_card" and offer.card then
		-- a shop playing card (Magic Trick): valued like a Standard Pack card.
		return playing_card_utility(state, offer.card)
	end
	return prior(offer)
end

-- The Expert's view of the offers: copies carrying their value as `utility`.
local function offer_views(state, offers)
	local views = {}
	for index, offer in ipairs(offers) do
		local view = copy_map(offer)
		view.utility = offer_value(state, offer)
		views[index] = view
	end
	return views
end

---------------------------------------------------------------------------
-- Held consumables.
---------------------------------------------------------------------------

local function weakest_consumable(state)
	local weakest_index, weakest, weakest_value
	for index, consumable in ipairs(state.consumables or {}) do
		local value = consumable_utility(state, consumable)
		if weakest_value == nil or value < weakest_value
			or (value == weakest_value and tostring(consumable.key) < tostring(weakest.key)) then
			weakest_index, weakest, weakest_value = index, consumable, value
		end
	end
	return weakest_index, weakest, weakest_value
end

local function consumable_room(state, incoming)
	if #(state.consumables or {}) < (state.consumable_limit or 2) then return true end
	local index, weakest, weakest_value = weakest_consumable(state)
	local incoming_value = consumable_utility(state, incoming)
	if weakest and incoming_value >= (weakest_value or 0) + 3 then
		return true, index, weakest, R.consumable_sell_value(weakest)
	end
	return false
end

local function money_consumable_gain(state, consumable)
	if consumable.sell_value then
		local gain = 0
		for _, key in ipairs(state.jokers or {}) do
			gain = gain + R.joker_sell_value(state, key)
		end
		return math.min(consumable.cap or gain, gain)
	end
	local gain = math.max(0, state.money) * (consumable.multiplier or 1)
	return math.min(consumable.cap or gain, gain)
end

local function should_use_consumable(state, consumable, source)
	if consumable.type == "planet" then return true end
	if consumable.type ~= "deck_tool" then return false end
	if consumable.effect == "money" then
		local gain = money_consumable_gain(state, consumable)
		local target = consumable.sell_value and 10 or math.min(consumable.cap or 20, 16)
		return gain >= target
			or (source == "shop_start" and gain >= 10)
			or (source == "make_room" and gain >= math.max(4, target * 0.5))
	end
	return state.strategy_open and consumable_utility(state, consumable) >= 10
end

-- The old use_held_consumables loop, one use per call: scan downward from the
-- cursor and use the first consumable should_use_consumable accepts.
local function default_consumable_use(state, actions, session, source)
	local cursor = math.min(session.cursor or 0, #state.consumables)
	for index = cursor, 1, -1 do
		if should_use_consumable(state, state.consumables[index], source) then
			local position = R.find_action(actions, "use", index)
			if position then
				session.cursor = index - 1
				return position
			end
		end
	end
	session.cursor = 0
	return nil
end

function Expert.hooks.consumable_step(state, ctx)
	local session = ctx.session
	if session.cursor == nil then session.cursor = #state.consumables end
	return default_consumable_use(state, ctx.actions, session, ctx.source) or 1
end

---------------------------------------------------------------------------
-- Jokers: replacement, layout.
---------------------------------------------------------------------------

local function weakest_joker(state)
	local weakest_index, weakest
	for index, key in ipairs(state.jokers) do
		-- A Negative Joker supplies its own slot. Selling it cannot create room
		-- for a normal replacement, so it is not a capacity sacrifice candidate.
		-- An Eternal Joker cannot be sold at all; a debuffed (expired
		-- Perishable) one does nothing and goes first.
		if (not state.joker_editions or state.joker_editions[key] ~= "negative")
			and R.joker_sellable(state, key) then
			local details = with_prior(R.joker_details(state, key))
			if state.Strategy then details.utility = state.Strategy.joker_utility(state, details, state.strategy_plan) end
			if R.joker_debuffed(state, key) then details.utility = 0 end
			if not weakest or details.utility < weakest.utility
				or (details.utility == weakest.utility and key < weakest.key) then
				weakest_index, weakest = index, details
			end
		end
	end
	return weakest_index, weakest
end

-- A Rental Joker costs $3 every round: the Expert takes one only while the
-- money left pays a round of rent for every Rental Joker it would own.
local function rent_covered(state, offer)
	if not offer.rental then return true end
	local rentals = 1
	for _, key in ipairs(state.jokers) do
		local stickers = state.joker_stickers and state.joker_stickers[key]
		if stickers and stickers.rental then rentals = rentals + 1 end
	end
	return (tonumber(state.money) or 0) - (tonumber(offer.cost) or 0) >= 3 * rentals
end

local function worthwhile_replacement(offer, weakest)
	if not offer or not weakest then return false end
	local current = tonumber(weakest.utility) or 0
	local improvement = (tonumber(offer.utility) or 0) - current
	-- Raw catalog values omit the switching cost of selling a working build
	-- piece. Require a material upgrade instead of a one- or two-point churn.
	return improvement >= math.max(3, current * 0.1)
end

local function can_install_joker(state, choice)
	if not R.joker_available(state, choice.key) then return false end
	if #state.jokers < state.joker_limit or choice.edition == "negative" then return true end
	local _, weakest = weakest_joker(state)
	return worthwhile_replacement(choice, weakest)
end

local xmult_effects = {
	first_face_xmult = true,
	last_hand_xmult = true,
	repeat_hand_xmult = true,
	held_suit_xmult = true,
	discard_decay_xmult = true,
	planet_scaling_xmult = true,
	deck_add_scaling_xmult = true,
	rarity_xmult = true,
	hand_xmult = true,
	enhancement_count_xmult = true,
	flat_xmult = true,
	held_rank_xmult = true,
	empty_slot_xmult = true,
	enhanced_threshold_xmult = true,
	scoring_suits_xmult = true,
	mixed_suit_xmult = true,
	chance_suit_xmult = true,
	periodic_xmult = true,
	non_pvp_xmult = true,
	retrigger_scoring = true,
	rank_retrigger = true,
	face_retrigger = true,
	rotating_suit_xmult = true,
	blind_scaling_xmult = true,
	avoid_most_played_xmult = true,
	chance_xmult_money = true,
	-- group C jokers
	limited_retrigger = true,
	rank_xmult = true,
	skip_scaling_xmult = true,
	enhancement_steal_xmult = true,
	discard_count_xmult = true,
	-- group B jokers
	discard_rank_xmult = true,
	rotating_card_xmult = true,
	lucky_scaling_xmult = true,
}

local function same_order(left, right)
	if #(left or {}) ~= #(right or {}) then return false end
	for index, key in ipairs(left or {}) do if key ~= right[index] then return false end end
	return true
end

local function ordinary_joker_order(state)
	local indexed = {}
	for index, key in ipairs(state.jokers or {}) do indexed[#indexed + 1] = { key = key, index = index } end
	table.sort(indexed, function(left, right)
		local left_effect = state.joker_effects[left.key]
		local right_effect = state.joker_effects[right.key]
		local left_x = left_effect and xmult_effects[left_effect.kind] or false
		local right_x = right_effect and xmult_effects[right_effect.kind] or false
		local left_poly = (state.joker_editions or {})[left.key] == "polychrome"
		local right_poly = (state.joker_editions or {})[right.key] == "polychrome"
		local left_phase = left_x and 3 or (left_poly and 2 or 1)
		local right_phase = right_x and 3 or (right_poly and 2 or 1)
		if left_phase == right_phase then return left.index < right.index end
		return left_phase < right_phase
	end)
	local result = {}
	for _, entry in ipairs(indexed) do result[#result + 1] = entry.key end
	return result
end

-- Leaving a shop: additive, then Polychrome, then xMult Jokers, unless a
-- Blueprint/Brainstorm is owned (its layout is chosen per hand).
function Expert.hooks.arrange_jokers(state, ctx)
	if ctx.source ~= "shop" then return nil end
	for _, key in ipairs(state.jokers or {}) do
		local effect = state.joker_effects[key]
		if effect and effect.kind == "copy_joker" then return nil end
	end
	local ordered = ordinary_joker_order(state)
	if same_order(state.jokers, ordered) then return nil end
	return ordered
end

-- The Joker layout a play is scored with.
function Expert.hooks.joker_order(state, ctx)
	local evaluate = ctx.evaluate_order
	local current = copy_array(state.jokers)
	local has_copy = false
	for _, key in ipairs(current) do
		local effect = state.joker_effects[key]
		if effect and effect.kind == "copy_joker" then has_copy = true; break end
	end
	local best_order = current
	local best_result = evaluate(current)

	if has_copy and #current <= 8 and not state.exact_joker_order then
		-- Speed: the exhaustive search below costs 120
		-- evaluations per scored play with 5 Jokers (720 with 6, 5040 with 7) and
		-- made Expert games with an early Blueprint/Brainstorm 10-30x slower once
		-- the shop offers Buffoon Packs and Rares at the game's rates. What the
		-- layout really decides is which Joker each copy copies (the one to its
		-- right for Blueprint, the leftmost for Brainstorm) and that additive
		-- effects come before xMult ones. So: the other Jokers in the usual
		-- additive -> Polychrome -> xMult order, any one of them moved to the
		-- front, and every copy Joker tried at every position (20 layouts for 5
		-- Jokers). `exact_joker_order` keeps the exhaustive search.
		local copies, others = {}, {}
		local position = {}
		for index, key in ipairs(current) do
			position[key] = index
			local effect = state.joker_effects[key]
			if effect and effect.kind == "copy_joker" then copies[#copies + 1] = key else others[#others + 1] = key end
		end
		local editions = state.joker_editions or {}
		local function phase(key)
			local effect = state.joker_effects[key]
			if effect and xmult_effects[effect.kind] then return 3 end
			return editions[key] == "polychrome" and 2 or 1
		end
		table.sort(others, function(left, right)
			local lp, rp = phase(left), phase(right)
			if lp == rp then return position[left] < position[right] end
			return lp < rp
		end)
		local tried = { [table.concat(current, ",")] = true }
		local function try(order)
			local signature = table.concat(order, ",")
			if tried[signature] then return end
			tried[signature] = true
			local result = evaluate(order)
			if result.score > best_result.score then best_order, best_result = copy_array(order), result end
		end
		local function place(order, index)
			if index > #copies then try(order); return end
			for slot = 1, #order + 1 do
				local next_order = copy_array(order)
				table.insert(next_order, slot, copies[index])
				place(next_order, index + 1)
			end
		end
		for front = 0, #others do
			local base = copy_array(others)
			if front > 0 then table.insert(base, 1, table.remove(base, front)) end
			place(base, 1)
		end
		-- Then improve the best layout by moving one Joker at a time until no
		-- move helps (catches Editions, Baseball Card and copied xMult details).
		for round = 1, 6 do
			-- (the first pass explores around the current layout, the rest around the best)
			local start = round == 1 and current or best_order
			for from = 1, #start do
				for to = 1, #start do
					if to ~= from then
						local moved = copy_array(start)
						table.insert(moved, to, table.remove(moved, from))
						try(moved)
					end
				end
			end
			if round > 1 and best_order == start then break end
		end
	elseif has_copy and #current <= 7 then
		-- Copy Jokers make adjacency and the leftmost slot part of the scoring
		-- decision. Normal runs have at most five slots, so an exhaustive search is
		-- both exact and small (120 layouts); seven slots is still a safe ceiling.
		local used, order = {}, {}
		local function visit(depth)
			if depth > #current then
				local result = evaluate(order)
				if result.score > best_result.score then
					best_order, best_result = copy_array(order), result
				end
				return
			end
			for index, key in ipairs(current) do
				if not used[index] then
					used[index] = true
					order[depth] = key
					visit(depth + 1)
					used[index] = nil
				end
			end
		end
		visit(1)
	else
		local ordered = ordinary_joker_order(state)
		local result = evaluate(ordered)
		if result.score > best_result.score then best_order, best_result = ordered, result end
	end
	return best_order, best_result
end

-- The `strategy` argument of choose_turn: discard costs and scaling hints.
function Expert.turn_hints(state)
	local strategy = { hand_growth = {}, rank_growth = {}, hand_money = {}, plan = state.strategy_plan }
	for _, key in ipairs(state.jokers) do
		local effect = state.joker_effects[key]
		if effect then
			if effect.kind == "green_scaling_mult" then
				strategy.preserve_green = true
				local current = math.max(0, state.joker_state[key] or 0)
				strategy.discard_score_loss_fraction = (strategy.discard_score_loss_fraction or 0)
					+ (effect.discard_sub or 1) / math.max(4, current + 4)
			elseif effect.kind == "discard_decay_xmult" then
				strategy.discard_card_cost = (strategy.discard_card_cost or 0) + 45
				-- Ramen can justify a redraw, but repeatedly rerolling the same hand
				-- burns permanent XMult far faster than the replacement draw repays it.
				strategy.discard_per_hand_budget = 1
				local current = math.max(1, state.joker_state[key] or effect.initial or 1)
				strategy.discard_score_loss_fraction = (strategy.discard_score_loss_fraction or 0)
					+ (effect.amount or 0) / current
			elseif effect.kind == "discard_chips" then
				strategy.discard_card_cost = (strategy.discard_card_cost or 0) + 8
			elseif effect.kind == "straight_scaling_chips" then
				strategy.runner_growth = (strategy.runner_growth or 0) + effect.amount
			elseif effect.kind == "four_card_scaling_chips" then
				strategy.four_card_growth = (strategy.four_card_growth or 0) + effect.amount
			elseif effect.kind == "bus_scaling_mult" then
				strategy.bus_value = (strategy.bus_value or 0) + (state.joker_state[key] or 0)
				strategy.bus_growth = (strategy.bus_growth or 0) + (effect.amount or 1)
			elseif effect.kind == "hand_scaling_mult" then
				strategy.hand_growth[effect.hand] = (strategy.hand_growth[effect.hand] or 0) + effect.amount
			elseif effect.kind == "rank_scaling_chips" then
				strategy.rank_growth[effect.rank] = (strategy.rank_growth[effect.rank] or 0) + effect.amount
			elseif effect.kind == "played_hand_money" and type(state.joker_state[key]) == "string" then
				local hand = state.joker_state[key]
				strategy.hand_money[hand] = (strategy.hand_money[hand] or 0) + effect.amount
			elseif effect.kind == "first_six_spectral" and next(state.round_hand_usage or {}) == nil then
				strategy.first_six_spectral = true
			end
		end
	end
	return strategy
end

---------------------------------------------------------------------------
-- Booster Packs.
---------------------------------------------------------------------------

local function minimum_pack_utility(state, family)
	if family == "buffoon" then
		local open_slots = math.max(0, (state.joker_limit or 5) - #(state.jokers or {}))
		-- Once the pack is paid for, a positive Joker in a genuinely open slot is
		-- better than taking nothing. Preserve Stencil's empty-slot XMult instead.
		if open_slots > 0 and not R.has_joker_kind(state, "empty_slot_xmult") then return 1 end
		return 14
	end
	if family == "standard" then return 5 end
	return 10
end

local function choose_pack_contents(state, candidates, picks, stream, minimum)
	local remaining, selected = {}, {}
	for _, candidate in ipairs(candidates) do
		if (candidate.utility or 0) >= minimum then remaining[#remaining + 1] = copy_map(candidate) end
	end
	for pick = 1, math.min(picks, #remaining) do
		local choice = state.Policy.choose_shop(remaining, state.difficulty,
			stream:fork("pick:" .. pick), state.decision_temperature)
		if not choice then break end
		selected[#selected + 1] = choice
		for index, candidate in ipairs(remaining) do
			if candidate.key == choice.key then table.remove(remaining, index); break end
		end
	end
	return selected
end

-- The Expert's picks of an opened pack. The streams are the pack's own:
-- "ordered_pack_choice:..." for a live Order pack, the contents stream
-- "pack_contents:..." for a headless one (forks only, so nothing advances).
local function select_pack_contents(state, pack, views)
	local label = (pack.ordered_unopened and "ordered_pack_choice:" or "pack_contents:")
		.. state.ante .. ":" .. state.round .. ":" .. pack.key .. ":" .. tostring(pack.instance or 1)
	local spec = R.pack_spec(pack.key) or {}
	return choose_pack_contents(state, views, pack.picks or spec.picks or 1,
		state.rng:fork(label), minimum_pack_utility(state, pack.family or spec.family))
end

-- The Expert's value of a card in an opened pack.
local function content_value(state, item)
	if item.type == "planet" then return planet_value(state, item.key, item.hand, prior(item) or 10) end
	if item.type == "joker" then return joker_utility(state, R.joker_details(state, item.key)) end
	if item.type == "deck_tool" then
		for _, tool in ipairs(state.deck_tools or {}) do
			if tool.key == item.key then return deck_tool_utility(state, tool) end
		end
		return deck_tool_utility(state, item)
	end
	if item.type == "playing_card" and item.card then return playing_card_utility(state, item.card) end
	return prior(item)
end

local function pack_has_applicable_choice(state, pack)
	if pack.ordered_unopened then return state.Order and type(state.Order.generate_pack) == "function" end
	if pack.headless_unopened then return true end   -- opened when bought
	for _, choice in ipairs(pack.selected or {}) do   -- legacy_shop: picked when offered
		if choice.type ~= "joker" or can_install_joker(state, choice) then return true end
	end
	return false
end

-- The old apply_pack walk over pack.selected: a Joker that is unavailable, or
-- has no room and no worthwhile replacement, is passed over (old install_joker
-- returned false); a Joker that needs room replaces the weakest Joker in place.
local function expert_pack_action(state, ctx, choice)
	local content
	for index, item in ipairs(ctx.contents) do
		if not ctx.session.taken[index] and item.key == choice.key then content = index; break end
	end
	if not content then return nil end
	if choice.type == "joker" then
		if not R.joker_available(state, choice.key) or not rent_covered(state, choice) then return nil end
		if #state.jokers < state.joker_limit or choice.edition == "negative" then
			return R.find_take(ctx.actions, content, nil)
		end
		local index, weakest = weakest_joker(state)
		if not worthwhile_replacement(choice, weakest) then return nil end
		return R.find_take(ctx.actions, content, index)
	end
	return R.find_take(ctx.actions, content, nil)
end

-- legacy_shop: a pack is offered with its picks, and only when the Expert
-- would pick something.
function Expert.hooks.legacy_pack_step(state, ctx)
	local views = {}
	for index, item in ipairs(ctx.contents) do
		item.expert_utility = content_value(state, item)
		views[index] = copy_map(item)
		views[index].utility = item.expert_utility
	end
	local spec = R.pack_spec(ctx.pack.key)
	return choose_pack_contents(state, views, spec.picks, ctx.stream, minimum_pack_utility(state, spec.family))
end

function Expert.hooks.pack_step(state, ctx)
	local session = ctx.session
	local mine = session.expert
	if not mine then
		-- The pack's cards are valued and the picks made once, when it opens
		-- (a legacy_shop pack was picked when offered). A picked card keeps its
		-- value (`expert_utility`).
		local selected = ctx.pack.selected
		if not selected then
			local views = {}
			for index, item in ipairs(ctx.contents) do
				item.expert_utility = content_value(state, item)
				views[index] = copy_map(item)
				views[index].utility = item.expert_utility
			end
			selected = select_pack_contents(state, ctx.pack, views)
		end
		mine = { selected = selected, cursor = 0 }
		session.expert = mine
	end
	while mine.cursor < #mine.selected do
		mine.cursor = mine.cursor + 1
		local position = expert_pack_action(state, ctx, mine.selected[mine.cursor])
		if position then return position end
	end
	return 1
end

---------------------------------------------------------------------------
-- Shop.
---------------------------------------------------------------------------

local function immediate_consumable(offer)
	if offer.type == "planet" or offer.type == "deck_tool" then return true end
	return offer.type == "pack"
		and (offer.family == "arcana" or offer.family == "celestial" or offer.family == "spectral")
end

-- Upstream's Expert treats Planets (and Celestial Packs) as worth buying while
-- an Astronomer is owned or on offer in this shop (it plans to buy it first).
-- only an owned Astronomer makes them free (card.lua
-- Card:set_cost, `free_planets` in the simulator's offer refresh); upstream
-- also set their price to $0 while Astronomer was merely offered.
local function free_planets_ready(state, offers)
	if R.has_joker_kind(state, "free_planets") then return true end
	for _, offer in ipairs(offers or {}) do
		local effect = offer.type == "joker" and state.joker_effects and state.joker_effects[offer.key]
		if effect and effect.kind == "free_planets" then return true end
	end
	return false
end

-- The purchase candidate built from an offer (old affordable-loop fields).
local function shop_candidate(state, offer, offer_index, reserve_before)
	local candidate = copy_map(offer)
	candidate.offer_index = offer_index
	candidate.base_utility = offer.utility or 0
	candidate.utility = offer_priority(state, offer)
	candidate.reserve_before = reserve_before
	return candidate
end

-- A Negative Joker raises `joker_limit`, but occupying its new capacity does
-- not consume one of the build's ordinary slots. Let a modest positive Joker
-- use that otherwise-wasted capacity; normal empty slots keep the stricter
-- threshold so the bot does not buy every early filler it sees.
local function negative_bonus_slot_open(state)
	local negatives = 0
	for _, edition in pairs(state.joker_editions or {}) do
		if edition == "negative" then negatives = negatives + 1 end
	end
	local count, limit = #(state.jokers or {}), state.joker_limit or 5
	return negatives > 0 and count < limit and count >= limit - negatives
end

-- The old purchase-loop body (affordable build, free-negative scan, choose_shop),
-- verbatim; indentation kept for merging. Returns choice, affordable, reserve.
local function expert_shop_choice(state, session, counts, offers)
	local purchases = session.purchases
	local permanent_purchases, consumable_purchases = counts.permanent, counts.consumable
	do
		local reserve = state.Strategy and state.Strategy.reserve(state, state.strategy_plan) or 0
		local affordable = {}
		for offer_index, offer in ipairs(offers) do
			local free_planet = free_planets_ready(state, offers)
			if R.has_joker_kind(state, "free_planets")
				and (offer.type == "planet" or (offer.type == "pack" and offer.family == "celestial")) then
				offer.cost = 0
			end
			offer.cost = tonumber(offer.cost) or 0
			local candidate = shop_candidate(state, offer, offer_index, reserve)
			-- a card the Expert buys keeps its purchase priority as its value
			session.offers[offer_index].expert_utility = candidate.utility
			local consumable_purchase = immediate_consumable(offer)
			local capacity_available = consumable_purchase and consumable_purchases < 2
				or not consumable_purchase and permanent_purchases < 2
			local missing = math.max(0, state.joker_limit - #state.jokers)
			local strong_empty_slot_joker = offer.type == "joker" and missing > 0
				and (offer.utility or 0) >= 14
			local strong_buffoon = offer.type == "pack" and offer.family == "buffoon" and missing > 0
				and (offer.utility or 0) >= 26
			local strong_survival_voucher = offer.type == "voucher" and (offer.utility or 0) >= 30
			local constellation_fuel = R.has_joker_kind(state, "planet_scaling_xmult")
				and (offer.type == "planet" or (offer.type == "pack" and offer.family == "celestial"))
				and (offer.utility or 0) >= 14
			local can_break_reserve = strong_empty_slot_joker or strong_buffoon
				or strong_survival_voucher or constellation_fuel
			local can_spend = offer.cost <= state.money + R.debt_limit(state)
				and (state.money - offer.cost >= reserve or can_break_reserve)
			local effect = offer.type == "joker" and state.joker_effects[offer.key]
			local enabler_ready = true
			if effect and effect.kind == "deck_add_scaling_xmult" and (state.cards_added or 0) == 0 then
				enabler_ready = false
				for _, other in ipairs(offers) do
					if other ~= offer and other.type == "deck_tool" and other.effect == "add"
						and offer.cost + other.cost <= state.money then
						enabler_ready = true
						break
					end
				end
			end
			local pack_applicable = offer.type ~= "pack" or pack_has_applicable_choice(state, offer)
			local priority_sufficient = free_planet or candidate.utility >= 10
			if offer.type == "pack" and not priority_sufficient then
				local history = state.pack_history[offer.family] or { opened = 0 }
				-- One high-value first look is legitimate even while another need (most
				-- commonly empty Joker slots) depresses its shop priority. Once the bot
				-- has actually sampled that family, ordinary priority rules apply.
				priority_sufficient = candidate.utility > 0 and history.opened == 0
					and (offer.utility or 0) >= 14
			end
			local is_consumable = offer.type == "planet" or offer.type == "deck_tool"
			local room, replace_index, replace_card, replace_value = true
			if is_consumable then
				if R.consumable_available(state, offer.key) then
					room, replace_index, replace_card, replace_value = consumable_room(state, offer)
				else
					room = false
				end
			end
			if replace_card and offer.cost <= state.money + replace_value
				and (state.money + replace_value - offer.cost >= reserve) then
				can_spend = true
				candidate.replace_consumable_index = replace_index
				candidate.sell_consumable_key = replace_card.key
				candidate.sell_consumable_value = replace_value
			end
			if capacity_available and offer.type ~= "joker" and room and pack_applicable
				and can_spend and (free_planet or (offer.utility or 0) >= 10)
				and priority_sufficient then
				affordable[#affordable + 1] = candidate
			elseif offer.type == "joker" and R.joker_available(state, offer.key) and rent_covered(state, offer) then
				local slot_available = #state.jokers < state.joker_limit or offer.edition == "negative"
				local free_negative = offer.edition == "negative" and offer.cost == 0
				local minimum = negative_bonus_slot_open(state) and 1 or 14
				if free_negative then
					candidate.free_negative = true
					candidate.utility = math.max(100, candidate.utility)
				end
				if capacity_available and enabler_ready and slot_available and can_spend
					and ((offer.utility or 0) >= minimum or free_negative)
					and (candidate.utility >= minimum or free_negative) then
					affordable[#affordable + 1] = candidate
				elseif enabler_ready and #state.jokers >= state.joker_limit then
					local index, weakest = weakest_joker(state)
					-- (none when every Joker is Eternal or Negative)
					local sell_value = weakest and R.joker_sell_value(state, weakest.key) or 0
					-- the debt allowance after the sale (selling a
					-- Credit Card removes it), as the shop_step compound action.
					if worthwhile_replacement(offer, weakest)
						and offer.cost <= state.money + sell_value + R.debt_limit(state, index) then
						candidate.replace_index = index
						candidate.sell_key = weakest.key
						candidate.sell_value = sell_value
						affordable[#affordable + 1] = candidate
					end
				end
			end
		end

		local choice
		for _, candidate in ipairs(affordable) do
			if candidate.free_negative then choice = candidate; break end
		end
		-- The decision stream is the shop's next decision draw (the simulator
		-- advances The Order's shop counter when the purchase or leave happens).
		choice = choice or state.Policy.choose_shop(
			affordable, state.difficulty, R.decision_stream(state, "decision:" .. (purchases + 1)),
			state.decision_temperature
		)
		return choice, affordable, reserve
	end
end

-- The sell action of a ready Invisible Joker with another Joker to copy (the
-- Expert sells it as soon as it can).
local function ready_invisible_action(state, actions)
	if #state.jokers < 2 or #state.jokers > state.joker_limit then return nil end
	for position, action in ipairs(actions) do
		local effect = action.type == "sell_joker" and state.joker_effects[action.key]
		if effect and effect.kind == "sell_duplicate_joker"
			and (tonumber(state.joker_state[action.key]) or 0) >= (effect.rounds or 2) then
			return position
		end
	end
	return nil
end

-- The decision log's view of a shop decision: the three best candidates (and
-- the chosen one), the best value missed, the money reserve.
local function ranked_candidates(candidates, chosen)
	local ranked = {}
	for _, candidate in ipairs(candidates or {}) do ranked[#ranked + 1] = candidate end
	table.sort(ranked, function(a, b)
		if a.utility == b.utility then return tostring(a.key) < tostring(b.key) end
		return a.utility > b.utility
	end)
	local out, seen = {}, false
	for index = 1, math.min(3, #ranked) do
		local candidate = ranked[index]
		out[#out + 1] = table.concat({ tostring(candidate.type), tostring(candidate.key),
			string.format("%.3f", tonumber(candidate.utility) or 0) }, "~")
		if candidate == chosen then seen = true end
	end
	if chosen and not seen then
		out[#out + 1] = table.concat({ tostring(chosen.type), tostring(chosen.key),
			string.format("%.3f", tonumber(chosen.utility) or 0) }, "~")
	end
	return #out > 0 and table.concat(out, ";") or "none", ranked[1]
end

local function shop_log(state, choice, affordable, reserve_money)
	local text, best = ranked_candidates(affordable, choice)
	if not choice then
		return {
			candidates = text, chosen_utility = 0, best_utility = best and best.utility or 0,
			regret = best and math.max(0, tonumber(best.utility) or 0) or 0,
			best_alternative = best and best.key or "none", reserve = reserve_money,
			reserve_reason = #affordable == 0 and "no_eligible_affordable_offer" or "policy_skip",
		}
	end
	local alternative
	for _, candidate in ipairs(affordable) do
		if candidate ~= choice and (not alternative or candidate.utility > alternative.utility) then alternative = candidate end
	end
	return {
		candidates = text, chosen_utility = choice.utility,
		best_utility = best and best.utility or choice.utility,
		regret = math.max(0, (tonumber(best and best.utility) or 0) - (tonumber(choice.utility) or 0)),
		best_alternative = alternative and alternative.key or "skip", reserve = reserve_money,
		reserve_reason = state.money - choice.cost >= reserve_money and "preserves_reserve"
			or "approved_reserve_exception",
		utility = choice.base_utility, priority = choice.utility,
	}
end

function Expert.hooks.shop_step(state, ctx)
	local session = ctx.session
	-- The Expert's own bookkeeping of this visit: purchases by kind and the
	-- held-consumable scan that follows every purchase.
	local mine = session.expert
	if not mine then
		mine = { seen = 0, permanent = 0, consumable = 0 }
		session.expert = mine
	end
	local offers = offer_views(state, session.offers)
	local bought = session.bought or {}
	while mine.seen < #bought do
		mine.seen = mine.seen + 1
		if immediate_consumable(bought[mine.seen]) then
			mine.consumable = mine.consumable + 1
		else
			mine.permanent = mine.permanent + 1
		end
		mine.use_cursor = #state.consumables
	end
	-- 1. The old use_held_consumables(state, "shop") after every purchase.
	if mine.use_cursor then
		local cursor = { cursor = mine.use_cursor }
		local position = default_consumable_use(state, ctx.actions, cursor, "shop")
		mine.use_cursor = position and cursor.cursor or nil
		if position then return position end
	end
	-- A ready Invisible Joker is sold for its copy.
	local invisible = ready_invisible_action(state, ctx.actions)
	if invisible then return invisible end
	-- 2. The old loop condition: no log entry, no decision draw.
	if #session.offers == 0 or session.purchases >= 4 then return 1, { silent = true } end
	-- 3.-5. The old purchase decision.
	local choice, affordable, reserve_before = expert_shop_choice(state, session, mine, offers)
	local meta = { log = shop_log(state, choice, affordable, reserve_before) }
	if not choice then return 1, meta end
	for position, action in ipairs(ctx.actions) do
		if action.type == "buy" and action.offer_index == choice.offer_index
			and action.sell_joker == choice.replace_index and action.sell_consumable == choice.replace_consumable_index then
			return position, meta
		end
	end
	error("shop_step: the Expert's purchase is not a legal action: " .. tostring(choice.key))
end

-- Entering a shop: sell the Jokers the simulator cannot model, rightmost first.
-- A debuffed (expired Perishable) Joker is sold too.
function Expert.hooks.shop_open(state, ctx)
	local unsupported = state.content_catalog and state.content_catalog.unsupported
		and state.content_catalog.unsupported.Joker
	local unsupported_keys = {}
	for _, key in ipairs(type(unsupported) == "table" and unsupported or {}) do unsupported_keys[key] = true end
	for index = #state.jokers, 1, -1 do
		local key = state.jokers[index]
		if unsupported_keys[key] or R.joker_debuffed(state, key) then
			local position = R.find_action(ctx.actions, "sell_joker", index)
			if position then return position end
		end
	end
	return 1
end

local economy_joker_kinds = {
	played_hand_money = true,
	deck_rank_money = true,
	round_money = true,
	discard_face_money = true,
	scoring_face_money = true,
	discard_rank_money = true,
	scoring_enhancement_money = true,
	scoring_suit_money = true,
	held_face_money = true,
	extra_interest = true,
	single_discard_destroy = true,
	unique_planet_money = true,   -- group C jokers
	boss_scaling_money = true,    -- group B jokers
}

local function has_economy_joker(state)
	for _, key in ipairs(state.jokers or {}) do
		local effect = state.joker_effects and state.joker_effects[key]
		if effect and economy_joker_kinds[effect.kind] then return true end
	end
	return false
end

-- The Expert's reroll heuristic (its reroll_step on a live Order shop).
function Expert.should_reroll(state, report, cost)
	cost = tonumber(cost) or 5
	if not report then return false end
	if cost == 0 then return true end
	local interest_floor = math.max(0, (tonumber(state.interest_cap) or 5) * 5)
	local economy_joker = has_economy_joker(state)
	local previous_bot = tonumber(state.previous_pvp_score) or 0
	local previous_player = tonumber(state.previous_player_score) or 0
	local emergency = (tonumber(state.ante) or 1) >= 3 and previous_bot > 0
		and previous_player >= previous_bot * 2
	if not economy_joker and not emergency and state.money - cost < interest_floor then return false end
	local reserve_money = not economy_joker and state.Strategy
		and state.Strategy.reserve(state, state.strategy_plan) or 0
	if emergency then reserve_money = 0 end
	if state.money - cost < reserve_money then return false end
	local has_power = false
	for _, key in ipairs(state.jokers or {}) do
		local effect = state.joker_effects and state.joker_effects[key]
		local kind = effect and effect.kind
		local current = effect and ((state.joker_state and state.joker_state[key]) or effect.initial) or 1
		local repeat_hand_active = false
		if kind == "repeat_hand_xmult" then
			for _, uses in pairs(state.round_hand_usage or {}) do
				if uses >= 2 then
					repeat_hand_active = true
					break
				end
			end
		end
		local reliable = kind == "flat_xmult"
			or kind == "rotating_suit_xmult"
			or (kind == "blind_scaling_xmult" and (current or 1) >= 1.5)
			or ((kind == "planet_scaling_xmult" or kind == "deck_add_scaling_xmult"
				or kind == "discard_decay_xmult") and (current or 1) >= 1.2)
			or repeat_hand_active
			or (kind == "hand_xmult" and state.strategy_plan
				and (effect.hand == state.strategy_plan.primary_hand
					or effect.hand == state.strategy_plan.secondary_hand)
				and (state.strategy_plan.confidence or 0) >= 0.35)
			or (kind == "empty_slot_xmult"
				and (state.joker_limit or 5) - #(state.jokers or {}) + 1 >= 2)
		if reliable and xmult_effects[kind] then
			has_power = true
			break
		end
	end
	local surplus = state.money - cost - reserve_money
	local late_power_gap = (tonumber(state.ante) or 1) >= 4 and not has_power
	if emergency and not has_power then return state.money >= cost end
	if late_power_gap then return true end
	if (tonumber(report.purchases) or 0) > 0 then return false end
	if surplus >= 25 then return true end
	local chance = ({ easy = 0.05, normal = 0.16, hard = 0.28, expert = 0.40 })[state.difficulty] or 0.16
	local missing_jokers = math.max(0, (state.joker_limit or 5) - #(state.jokers or {}))
	if missing_jokers >= 3 then chance = chance + 0.25
	elseif missing_jokers > 0 then chance = chance + 0.10 end
	if #(report.supported_keys or {}) == 0 then chance = chance + 0.10 end
	if surplus >= 10 then chance = chance + 0.15 end
	if late_power_gap then chance = chance + 0.20 end
	local stream = state.rng:fork(string.format(
		"reroll:%s:%s:%s", tostring(state.ante), tostring(state.shop_visits), tostring(state.times_rerolled)
	))
	return stream:next() < math.min(0.8, chance)
end

-- The Expert rerolls live Order shops only; its headless runs never reroll.
function Expert.hooks.reroll_step(state, ctx)
	if ctx.headless then return false end
	return Expert.should_reroll(state, ctx.report, ctx.cost)
end

-- Luchador: sold against any Boss whose ability the simulator applies.
function Expert.hooks.boss_disable_step(_, ctx)
	return ctx.simulated and 2 or 1
end

---------------------------------------------------------------------------
-- Blind skips.
---------------------------------------------------------------------------

-- Policy.should_skip_blind per Blind. Reactive pressure is useful once per
-- Ante. Chaining both skips after one dominant PvP result throws away two
-- payouts, two shops, and two rounds of scaling. If both rolls fire, keep the
-- skip with an actual modeled reward; otherwise prefer Big Blind because it
-- applies pressure later in the Ante.
function Expert.hooks.skip_pair(state, ctx)
	local should_skip = state.Policy and state.Policy.should_skip_blind
	if not should_skip then return false, false end
	local ante = ctx.ante
	local selected = {}
	for _, blind in ipairs({ "Small", "Big" }) do
		local candidate = blind == "Small" and ctx.small or ctx.big
		selected[blind] = should_skip({
			mode = ctx.mode,
			difficulty = state.difficulty,
			ante = ante,
			blind = blind,
			money = state.money,
			joker_count = #state.jokers,
			joker_limit = state.joker_limit,
			tag = candidate.tag,
			previous_pvp_dominant = state.previous_pvp_dominant == true,
			previous_score = state.previous_pvp_score,
			next_blind_target = R.base_score(ante, R.blind_scaling(state.stake))
				* (blind == "Small" and 1.5 or 2),
			strict_order_content = state.strict_order_content,
			reward_supported = candidate.supported,
			rng = state.rng:fork("skip:" .. ante .. ":" .. blind),
		})
	end
	local small, big = selected.Small, selected.Big
	if ctx.mode == "reactive" and state.previous_pvp_dominant and small and big then
		if ctx.small.supported and not ctx.big.supported then
			big = false
		else
			small = false
		end
	end
	return small, big
end

---------------------------------------------------------------------------
-- Notifications.
---------------------------------------------------------------------------

function Expert.observe(state, event, data)
	if event == "decision" then
		-- the build plan behind every logged decision
		local plan = state.strategy_plan
		data.plan_primary = plan and plan.primary_hand
		data.plan_secondary = plan and plan.secondary_hand
		data.plan_confidence = plan and plan.confidence
		data.plan_exploring = plan and plan.exploring or false
		if data.type == "shop_decision" and data.regret == nil then   -- a shop with nothing to decide
			data.candidates, data.chosen_utility, data.best_utility, data.regret = "none", 0, 0, 0
			data.best_alternative = "none"
			data.reserve = state.Strategy and state.Strategy.reserve(state, state.strategy_plan) or 0
		end
	elseif event == "deck_tool" then
		remember_deck_fix(state, data)
	elseif event == "new" then
		-- The Expert's settings come with the run's options.
		local config = state.Policy and state.Policy.expert_config or {}
		local options = state.options or {}
		state.Strategy = config.Strategy
		state.weights = config.Weights and config.Weights.copy(options.weights) or copy_map(options.weights or {})
		state.difficulty = options.difficulty or "normal"
		state.decision_temperature = math.max(0, tonumber(options.decision_temperature) or 0)
		state.exact_joker_order = options.exact_joker_order == true   -- the exhaustive joker_order search
		-- the rule deviations the Expert was tuned with (see bot/simulator.lua)
		state.expert_compat = { use_created_cards = true, judgement_without_slot = true, targetless_tools = true }
		state.strategy_open = false
		analyze(state)
	elseif event == "shop_buy" then
		state.strategy_open = true
		analyze(state)
	elseif event == "shop_end" or event == "set_ante" then
		-- Loaded/custom runs that begin after Ante 1 have already passed the
		-- point where first-shop exploration is meaningful.
		if not state.strategy_open and (event == "shop_end" or state.ante > 1) then
			state.strategy_open = true
			analyze(state)
		end
	else   -- shop_open, shop_sell, round_start, turn, pvp_effect
		analyze(state)
	end
end

---------------------------------------------------------------------------
-- The Expert as a policy.
---------------------------------------------------------------------------

local function candidates_string(candidates)
	local out = {}
	for _, candidate in ipairs(candidates or {}) do
		out[#out + 1] = table.concat({
			tostring(candidate.type or "unknown"), tostring(candidate.key or ""),
			string.format("%.3f", tonumber(candidate.utility) or 0),
			tostring(candidate.hand or ""), tostring(candidate.score or ""),
		}, "~")
	end
	return #out > 0 and table.concat(out, ";") or "none"
end

-- The Expert built on bot/policy.lua (`modules.Policy`), bot/strategy.lua and
-- bot/weights.lua; it reads its settings (difficulty, decision_temperature,
-- weights, exact_joker_order) from the run's options. Returns modules.Policy
-- unchanged when that already is an Expert.
function Expert.policy(modules)
	local engine = modules.Policy
	if engine and engine.expert_config then return engine end
	assert(engine and engine.choose_turn, "Expert.policy needs bot/policy.lua as modules.Policy")
	assert(modules.Simulator and modules.Simulator.rules, "Expert.policy needs the simulator as modules.Simulator")
	R = modules.Simulator.rules
	local policy = setmetatable({}, { __index = engine })
	for name, hook in pairs(Expert.hooks) do policy[name] = hook end
	policy.observe = Expert.observe
	policy.expert_config = { Strategy = modules.Strategy, Weights = modules.Weights }
	-- bot/policy.lua's hand play with the Expert's hints, settings and its
	-- decision stream for the turn.
	function policy.choose_turn(args, state)
		args.difficulty = state.difficulty
		args.decision_temperature = state.decision_temperature
		args.rng = state.rng:fork("decision:" .. state.ante .. ":" .. tostring(args.round_name)
			.. ":" .. tostring(args.turn) .. ":" .. state.difficulty)
		args.strategy = Expert.turn_hints(state)
		args.weights = state.weights
		local action = engine.choose_turn(args)
		if action then
			-- bot/policy.lua's diagnostics, for the decision log
			action.log = {
				candidates = candidates_string(action.candidates),
				chosen_utility = action.chosen_utility or action.utility,
				best_utility = action.best_utility or action.utility,
				regret = action.regret or 0,
			}
		end
		return action
	end
	return policy
end

-- A copy of `modules` whose Policy is the Expert (what Simulator.new and
-- Simulator.run take as dependencies).
function Expert.modules(modules)
	local out = {}
	for key, value in pairs(modules) do out[key] = value end
	out.Policy = Expert.policy(modules)
	out.Expert = Expert
	return out
end

return Expert
