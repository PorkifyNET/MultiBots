local Evaluator = {}

Evaluator.hands = {
	["High Card"] = { chips = 5, mult = 1, l_chips = 10, l_mult = 1, strength = 1 },
	["Pair"] = { chips = 10, mult = 2, l_chips = 15, l_mult = 1, strength = 2 },
	["Two Pair"] = { chips = 20, mult = 2, l_chips = 20, l_mult = 1, strength = 3 },
	["Three of a Kind"] = { chips = 30, mult = 3, l_chips = 20, l_mult = 2, strength = 4 },
	["Straight"] = { chips = 30, mult = 4, l_chips = 30, l_mult = 3, strength = 5 },
	["Flush"] = { chips = 35, mult = 4, l_chips = 15, l_mult = 2, strength = 6 },
	["Full House"] = { chips = 40, mult = 4, l_chips = 25, l_mult = 2, strength = 7 },
	["Four of a Kind"] = { chips = 60, mult = 7, l_chips = 30, l_mult = 3, strength = 8 },
	["Straight Flush"] = { chips = 100, mult = 8, l_chips = 40, l_mult = 4, strength = 9 },
	["Five of a Kind"] = { chips = 120, mult = 12, l_chips = 35, l_mult = 3, strength = 10 },
	["Flush House"] = { chips = 140, mult = 14, l_chips = 40, l_mult = 4, strength = 11 },
	["Flush Five"] = { chips = 160, mult = 16, l_chips = 50, l_mult = 3, strength = 12 },
}

local function rank_groups(cards)
	local groups = {}
	for _, card in ipairs(cards) do
		groups[card.rank] = groups[card.rank] or {}
		groups[card.rank][#groups[card.rank] + 1] = card
	end
	local ordered = {}
	for rank, group in pairs(groups) do ordered[#ordered + 1] = { rank = rank, cards = group, count = #group } end
	table.sort(ordered, function(a, b)
		if a.count == b.count then return a.rank > b.rank end
		return a.count > b.count
	end)
	return ordered
end

local function straight_high(cards, allow_gaps, required)
	required = required or 5
	if #cards ~= required then return nil end
	local seen, ranks = {}, {}
	for _, card in ipairs(cards) do
		if not seen[card.rank] then
			seen[card.rank] = true
			ranks[#ranks + 1] = card.rank
		end
	end
	if #ranks ~= required then return nil end
	table.sort(ranks)
	local function connected(values)
		for index = 2, #values do
			local gap = values[index] - values[index - 1]
			if gap > (allow_gaps and 2 or 1) then return false end
		end
		return true
	end
	if connected(ranks) then return ranks[#ranks] end
	if ranks[#ranks] == 14 then
		local low_ace = { 1 }
		for index = 1, #ranks - 1 do low_ace[#low_ace + 1] = ranks[index] end
		if connected(low_ace) then return ranks[#ranks - 1] end
	end
	return nil
end

local function merged_suit(suit)
	return (suit == "Hearts" or suit == "Diamonds") and "Red" or "Black"
end

local function is_flush(cards, required, suit_merge)
	if #cards ~= (required or 5) then return false end
	local suit = nil
	for _, card in ipairs(cards) do
		-- a debuffed Wild card is not wild (is_suit flush_calc).
		if card.enhancement ~= "m_wild" or card.debuff then
			local card_suit = suit_merge and merged_suit(card.suit) or card.suit
			suit = suit or card_suit
			if card_suit ~= suit then return false end
		end
	end
	return true
end

local function append_group(out, group)
	for _, card in ipairs(group.cards) do out[#out + 1] = card end
end

function Evaluator.classify(cards, allow_straight_gaps, allow_four_card_hands, suit_merge)
	local hand_cards, stones = {}, {}
	for _, card in ipairs(cards) do
		if card.enhancement == "m_stone" then stones[#stones + 1] = card
		else hand_cards[#hand_cards + 1] = card end
	end
	local groups = rank_groups(hand_cards)
	local required = allow_four_card_hands and #hand_cards == 4 and 4 or 5
	local straight = straight_high(hand_cards, allow_straight_gaps, required)
	local flush = is_flush(hand_cards, required, suit_merge)
	local first = groups[1] and groups[1].count or 0
	local second = groups[2] and groups[2].count or 0
	local full_house = first == 3 and second == 2
	local name, scoring = "High Card", {}

	if first == 5 and flush then
		name, scoring = "Flush Five", hand_cards
	elseif full_house and flush then
		name, scoring = "Flush House", hand_cards
	elseif first == 5 then
		name, scoring = "Five of a Kind", hand_cards
	elseif straight and flush then
		name, scoring = "Straight Flush", hand_cards
	elseif groups[1] and groups[1].count == 4 then
		name = "Four of a Kind"
		append_group(scoring, groups[1])
	elseif groups[1] and groups[2] and groups[1].count == 3 and groups[2].count == 2 then
		name, scoring = "Full House", hand_cards
	elseif flush then
		name, scoring = "Flush", hand_cards
	elseif straight then
		name, scoring = "Straight", hand_cards
	elseif groups[1] and groups[1].count == 3 then
		name = "Three of a Kind"
		append_group(scoring, groups[1])
	elseif groups[1] and groups[2] and groups[1].count == 2 and groups[2].count == 2 then
		name = "Two Pair"
		append_group(scoring, groups[1])
		append_group(scoring, groups[2])
	elseif groups[1] and groups[1].count == 2 then
		name = "Pair"
		append_group(scoring, groups[1])
	else
		local highest = hand_cards[1]
		for _, card in ipairs(hand_cards) do if not highest or card.rank > highest.rank then highest = card end end
		if highest then scoring[1] = highest end
	end
	for _, stone in ipairs(stones) do scoring[#scoring + 1] = stone end

	local contained = { [name] = true }
	if first >= 2 then contained["Pair"] = true end
	if first >= 3 then contained["Three of a Kind"] = true end
	if first >= 4 then contained["Four of a Kind"] = true end
	if first == 5 then contained["Five of a Kind"] = true end
	if (first == 2 and second == 2) or full_house then contained["Two Pair"] = true end
	if full_house then contained["Full House"] = true end
	if flush then contained["Flush"] = true end
	if straight then contained["Straight"] = true end
	if straight and flush then contained["Straight Flush"] = true end
	return name, scoring, contained
end

local suit_jokers = {
	j_greedy_joker = { suit = "Diamonds", mult = 3 },
	j_lusty_joker = { suit = "Hearts", mult = 3 },
	j_wrathful_joker = { suit = "Spades", mult = 3 },
	j_gluttenous_joker = { suit = "Clubs", mult = 3 },
}

local function has_rank(ranks, rank)
	for _, wanted in ipairs(ranks or {}) do if wanted == rank then return true end end
	return false
end

-- Card identity as the game sees it (Card:get_id / is_suit / is_face): a Stone
-- card has no rank and no suit; Pareidolia makes every card a face card.
-- a card debuffed by a Boss Blind (card.debuff) has no
-- suit and is no face card for Jokers (is_suit / is_face return nothing).
local function is_stone(card) return card.enhancement == "m_stone" end
local function rank_of(card) return not is_stone(card) and card.rank or nil end
-- is_suit(suit, nil, flush_calc = true) (Blackboard): the base suit even when
-- debuffed; a Wild card only when it is not debuffed; Smeared Joker merges the
-- colours (card.lua Card:is_suit).
local function flush_suited(state, card, suit)
	if is_stone(card) then return false end
	if card.enhancement == "m_wild" and not card.debuff then return true end
	if card.suit == suit then return true end
	return state.suit_merge and merged_suit(card.suit) == merged_suit(suit) or false
end
local function is_face(card)
	return not is_stone(card) and not card.debuff and card.rank >= 11 and card.rank <= 13
end

local function scoring_face(state, card)
	if card.debuff then return false end
	return state.all_cards_are_faces or is_face(card)
end

local function suit_matches(state, card, wanted)
	if is_stone(card) or card.debuff then return false end   -- debuffed = no suit
	if card.enhancement == "m_wild" or card.suit == wanted then return true end
	return state.suit_merge and merged_suit(card.suit) == merged_suit(wanted)
end

local function nominal(card)
	local rank = card.rank or 0
	if rank == 14 then return 11 end
	if rank >= 11 then return 10 end
	return rank
end

local function apply_xmult(state, amount)
	amount = amount or 1
	state.mult = state.mult * amount
	state.x_mult = state.x_mult * amount
end

local INDIVIDUAL = {
	suit_mult = true, suit_card_mult = true, suit_chips = true, rank_mult = true, rank_chips = true,
	rank_chips_mult = true, face_chips = true, face_mult = true, first_face_xmult = true,
	chance_suit_xmult = true, rank_scaling_chips = true, played_card_chip_growth = true,
	rotating_suit_xmult = true,
	rank_xmult = true,   -- group C jokers
}
local HELD = { held_rank_mult = true, held_rank_xmult = true, held_lowest_rank_mult = true }
local NOT_MAIN = { rarity_xmult = true }
for kind in pairs(INDIVIDUAL) do NOT_MAIN[kind] = kind ~= "rank_scaling_chips" or nil end
for kind in pairs(HELD) do NOT_MAIN[kind] = true end
-- group B jokers: The Idol scores per card; Lucky Cat grows per card and
-- gives its X Mult in joker_main.
INDIVIDUAL.rotating_card_xmult = true
INDIVIDUAL.lucky_scaling_xmult = true
NOT_MAIN.rotating_card_xmult = true

local function contains(state, requested)
	return state.contained[requested] == true
end

local apply_adapter
apply_adapter = function(effect, state, joker_key, joker_index, resolving, resolved_jokers)
	if not effect then return end
	if effect.kind == "flat_mult" then
		state.mult = state.mult + effect.amount
	elseif effect.kind == "suit_mult" then
		for _, card in ipairs(state.scoring) do
			if suit_matches(state, card, effect.suit) then
				state.mult = state.mult + effect.amount * card_repetitions(state, card)
			end
		end
	elseif effect.kind == "hand_mult" and contains(state, effect.hand) then
		state.mult = state.mult + effect.amount
	elseif effect.kind == "hand_chips" and contains(state, effect.hand) then
		state.chips = state.chips + effect.amount
	elseif effect.kind == "card_count_mult" and state.played_count <= effect.maximum then
		state.mult = state.mult + effect.amount
	elseif effect.kind == "joker_count_mult" then
		state.mult = state.mult + effect.amount * state.joker_count
	elseif effect.kind == "discard_chips" then
		state.chips = state.chips + effect.amount * state.discards_left
	elseif effect.kind == "no_discard_mult" and state.discards_left == 0 then
		state.mult = state.mult + effect.amount
	elseif effect.kind == "money_chips" then
		state.chips = state.chips + effect.amount * math.max(0, state.context.money or 0)
	elseif effect.kind == "money_step_mult" then
		state.mult = state.mult + effect.amount * math.floor(math.max(0, state.context.money or 0) / effect.dollars)
	elseif effect.kind == "deck_remaining_chips" then
		state.chips = state.chips + effect.amount * (state.context.deck_remaining or 0)
	elseif effect.kind == "hand_usage_mult" then
		local count = (state.context.hand_usage and state.context.hand_usage[state.name]) or 0
		state.mult = state.mult + effect.amount * (count + (effect.include_current and 1 or 0))
	elseif effect.kind == "last_hand_xmult" and state.context.hands_left == 1 then
		apply_xmult(state, effect.amount)
	elseif effect.kind == "repeat_hand_xmult"
		and ((state.context.round_hand_usage and state.context.round_hand_usage[state.name]) or 0) > 0 then
		apply_xmult(state, effect.amount)
	elseif effect.kind == "held_suit_xmult" then
		local valid = true
		for _, card in ipairs(state.context.held_cards or {}) do
			local ok = false
			for _, suit in ipairs(effect.suits or {}) do
				if flush_suited(state, card, suit) then ok = true end
			end
			if not ok then valid = false; break end
		end
		if valid then apply_xmult(state, effect.amount) end
	elseif effect.kind == "straight_scaling_chips" then
		local value = (state.context.joker_state[joker_key] or 0)
		if contains(state, "Straight") then value = value + effect.amount end
		state.chips = state.chips + value
	elseif effect.kind == "four_card_scaling_chips" then
		local value = (state.context.joker_state[joker_key] or 0)
		if state.played_count == 4 then value = value + effect.amount end
		state.chips = state.chips + value
	elseif effect.kind == "bus_scaling_mult" then
		local has_scoring_face = false
		for _, card in ipairs(state.scoring) do if scoring_face(state, card) then has_scoring_face = true; break end end
		if not has_scoring_face then state.mult = state.mult + (state.context.joker_state[joker_key] or 0) + effect.amount end
	elseif effect.kind == "green_scaling_mult" then
		state.mult = state.mult + math.max(0, (state.context.joker_state[joker_key] or 0) + effect.hand_add)
	elseif effect.kind == "decaying_chips" then
		state.chips = state.chips + math.max(0, state.context.joker_state[joker_key] or effect.initial)
	elseif effect.kind == "decaying_mult" then
		state.mult = state.mult + math.max(0, state.context.joker_state[joker_key] or effect.initial)
	elseif effect.kind == "discard_decay_xmult" then
		apply_xmult(state, math.max(1, state.context.joker_state[joker_key] or effect.initial))
	elseif effect.kind == "planet_scaling_xmult" then
		apply_xmult(state, state.context.joker_state[joker_key] or effect.initial)
	elseif effect.kind == "tarot_scaling_mult" then
		state.mult = state.mult + effect.amount * (state.context.tarots_used or 0)
	elseif effect.kind == "deck_add_scaling_xmult" then
		apply_xmult(state, state.context.joker_state[joker_key] or effect.initial)
	elseif effect.kind == "other_joker_sell_mult" then
		for key, value in pairs(state.context.joker_sell_values or {}) do if key ~= joker_key then state.mult = state.mult + value end end
	elseif effect.kind == "rarity_xmult" then
		for key, rarity in pairs(state.context.joker_rarities or {}) do
			if key ~= joker_key and rarity == effect.rarity then apply_xmult(state, effect.amount) end
		end
	elseif effect.kind == "hand_xmult" and contains(state, effect.hand) then
		apply_xmult(state, effect.amount)
	elseif effect.kind == "suit_chips" then
		for _, card in ipairs(state.scoring) do if suit_matches(state, card, effect.suit) then
			state.chips = state.chips + effect.amount * card_repetitions(state, card)
		end end
	elseif effect.kind == "suit_card_mult" then
		for _, card in ipairs(state.scoring) do if suit_matches(state, card, effect.suit) then
			state.mult = state.mult + effect.amount * card_repetitions(state, card)
		end end
	elseif effect.kind == "enhancement_count_xmult" then
		local count = 0
		for _, card in ipairs(state.context.full_deck or {}) do if card.enhancement == effect.enhancement then count = count + 1 end end
		apply_xmult(state, effect.initial + count * effect.amount)
	elseif effect.kind == "flat_xmult" then
		apply_xmult(state, effect.amount)
	elseif effect.kind == "flat_chips" then
		state.chips = state.chips + effect.amount
	elseif effect.kind == "empty_slot_xmult" then
		-- Joker Stencil: empty slots plus every Stencil, only with an empty slot (card.lua).
		local empty = (state.context.joker_limit or 5) - state.joker_count
		if empty > 0 then apply_xmult(state, empty + state.stencils) end
	elseif effect.kind == "missing_deck_mult" then
		state.mult = state.mult + math.max(0, (state.context.starting_deck_size or 52) - #(state.context.full_deck or {})) * effect.amount
	elseif effect.kind == "stone_count_chips" then
		local count = 0
		for _, card in ipairs(state.context.full_deck or {}) do if card.enhancement == "m_stone" then count = count + 1 end end
		state.chips = state.chips + count * effect.amount
	elseif effect.kind == "enhanced_threshold_xmult" then
		local count = 0
		for _, card in ipairs(state.context.full_deck or {}) do if card.enhancement then count = count + 1 end end
		if count >= effect.count then apply_xmult(state, effect.amount) end
	elseif effect.kind == "scoring_suits_xmult" then
		-- Flower Pot: every Wild card fills one missing suit; debuffed cards count
		-- by their suit (is_suit bypass_debuff), debuffed Wild cards not at all.
		local suits, count, wilds = {}, 0, 0
		for _, card in ipairs(state.scoring) do
			if card.enhancement == "m_wild" then
				if not card.debuff then wilds = wilds + 1 end
			elseif not is_stone(card) and not suits[card.suit] then
				suits[card.suit] = true
				count = count + 1
			end
		end
		if math.min(4, count + wilds) >= effect.count then apply_xmult(state, effect.amount) end
	elseif effect.kind == "mixed_suit_xmult" then
		local wanted, other, wilds = false, false, 0
		for _, card in ipairs(state.scoring) do
			if card.debuff then
				-- a debuffed card has no suit (is_suit)
			elseif card.enhancement == "m_wild" then wilds = wilds + 1
			elseif not is_stone(card) then
				if card.suit == effect.suit then wanted = true else other = true end
			end
		end
		if not wanted and wilds > 0 then wanted, wilds = true, wilds - 1 end
		if not other and wilds > 0 then other = true end
		if wanted and other then apply_xmult(state, effect.amount) end
	elseif effect.kind == "chance_suit_xmult" then
		local expected = 1 + math.min(1, (effect.chance or 0.5)
			* (state.context.probability_multiplier or 1)) * ((effect.amount or 1) - 1)
		for _, card in ipairs(state.scoring) do
			if suit_matches(state, card, effect.suit) then
				for _ = 1, card_repetitions(state, card) do apply_xmult(state, expected) end
			end
		end
	elseif effect.kind == "periodic_xmult" then
		-- Loyalty Card owns a countdown that begins when the Joker is acquired.
		-- Run-wide hands played before the purchase must not advance it.
		local remaining = state.context.joker_state[joker_key] or effect.initial or effect.every
		if remaining <= 1 then apply_xmult(state, effect.amount) end
	elseif effect.kind == "hand_scaling_mult" then
		local value = state.context.joker_state[joker_key] or 0
		if contains(state, effect.hand) then value = value + effect.amount end
		state.mult = state.mult + value
	elseif effect.kind == "rank_scaling_chips" then
		state.chips = state.chips + (state.context.joker_state[joker_key] or 0) + (state.growth[joker_key] or 0)
	elseif effect.kind == "rotating_suit_xmult" then
		local target = state.context.joker_targets and state.context.joker_targets[joker_key]
		for _, card in ipairs(state.scoring) do
			if card.suit == target or card.enhancement == "m_wild" then
				for _ = 1, card_repetitions(state, card) do apply_xmult(state, effect.amount) end
			end
		end
	elseif effect.kind == "discard_suit_scaling_chips" then
		state.chips = state.chips + (state.context.joker_state[joker_key] or effect.initial or 0)
	elseif effect.kind == "sacrifice_scaling_mult" or effect.kind == "opponent_sale_mult" then
		state.mult = state.mult + (state.context.joker_state[joker_key] or effect.initial or 0)
	elseif effect.kind == "blind_scaling_xmult" then
		apply_xmult(state, state.context.joker_state[joker_key] or effect.initial or 1)
	elseif effect.kind == "avoid_most_played_xmult" then
		apply_xmult(state, state.context.joker_state[joker_key] or effect.initial or 1)
	elseif effect.kind == "chance_xmult_money" then
		local odds = math.max(1, tonumber(effect.odds) or 4)
		apply_xmult(state, 1 + ((effect.amount or 1) - 1) / odds)
	elseif effect.kind == "skipped_pack_scaling_mult" then
		state.mult = state.mult + (state.context.joker_state[joker_key] or effect.initial or 0)
	elseif effect.kind == "non_pvp_xmult" and not state.context.is_pvp then
		apply_xmult(state, effect.amount)
	-- group B jokers
	elseif effect.kind == "discard_rank_xmult" then
		-- Hit the Road: X Mult gained from Jacks discarded this round.
		apply_xmult(state, math.max(1, state.context.joker_state[joker_key] or effect.initial or 1))
	elseif effect.kind == "lucky_scaling_xmult" then
		-- Lucky Cat: its X Mult including this hand's expected Lucky triggers.
		apply_xmult(state, math.max(1, state.context.joker_state[joker_key] or effect.initial or 1)
			+ (state.growth[joker_key] or 0))
	-- vanilla Jokers group A: Glass Joker, Campfire and Caino score their grown
	-- XMult, Flash Card its grown Mult (card.lua joker_main, copied by Blueprint).
	elseif effect.kind == "glass_shatter_xmult" or effect.kind == "sell_scaling_xmult"
		or effect.kind == "face_destroy_xmult" then
		apply_xmult(state, math.max(1, state.context.joker_state[joker_key] or effect.initial or 1))
	elseif effect.kind == "reroll_scaling_mult" then
		state.mult = state.mult + math.max(0, state.context.joker_state[joker_key] or effect.initial or 0)
	-- group C jokers
	elseif effect.kind == "skip_scaling_xmult" then
		-- Throwback: 1 + skips * extra (card.lua set_cost / joker_main).
		apply_xmult(state, 1 + (state.context.blinds_skipped or 0) * (effect.amount or 0.25))
	elseif effect.kind == "discard_count_xmult" then
		apply_xmult(state, state.context.joker_state[joker_key] or effect.initial or 1)
	elseif effect.kind == "enhancement_steal_xmult" then
		-- Vampire's gain from this hand (context.before) is already in its X Mult.
		apply_xmult(state, (state.context.joker_state[joker_key] or effect.initial or 1)
			+ ((state.vampire_gain or {})[joker_key] or 0))
	elseif effect.kind == "copy_joker" then
		local target_index
		if effect.mode == "leftmost" then
			target_index = 1
		else
			target_index = (joker_index or 0) + 1
		end
		if resolved_jokers then
			local copied = resolved_jokers[target_index]
			if copied then
				apply_adapter(copied.effect, state, copied.key, copied.index, {}, resolved_jokers)
			end
		else
			local target = state.context.jokers and state.context.jokers[target_index]
			local copied = target and state.context.joker_effects and state.context.joker_effects[target]
			resolving = resolving or {}
			if copied and not resolving[target_index] then
				resolving[joker_index or 0] = true
				apply_adapter(copied, state, target, target_index, resolving)
				resolving[joker_index or 0] = nil
			end
		end
	end
end

local function resolved_joker(jokers, effects, index, resolving)
	local key = jokers[index]
	local effect = key and effects[key]
	if not effect then return nil end
	if effect.kind ~= "copy_joker" then return { effect = effect, key = key, index = index } end
	local target = effect.mode == "leftmost" and 1 or index + 1
	resolving = resolving or {}
	if resolving[target] then return nil end
	resolving[target] = true
	local result = resolved_joker(jokers, effects, target, resolving)
	resolving[target] = nil
	return result
end

local function resolved_effect(jokers, effects, index, resolving)
	local result = resolved_joker(jokers, effects, index, resolving)
	return result and result.effect or nil
end

function Evaluator.resolve_jokers(jokers, effects)
	local resolved = {}
	for index = 1, #(jokers or {}) do
		resolved[index] = resolved_joker(jokers, effects or {}, index)
	end
	return resolved
end

local function resolved_effect_at(jokers, effects, index, resolved_jokers)
	if resolved_jokers then
		local result = resolved_jokers[index]
		return result and result.effect or nil
	end
	return resolved_effect(jokers, effects, index)
end

local function resolves_kind(jokers, effects, index, wanted, resolved_jokers)
	local effect = resolved_effect_at(jokers, effects, index, resolved_jokers)
	return effect and effect.kind == wanted or false
end

-- the effect a Joker slot really has (Blueprint/Brainstorm
-- resolved to the Joker they copy), with the copied Joker's key and slot, so
-- the simulator can apply copied money and card effects as the game does.
function Evaluator.resolve_copy(jokers, effects, index)
	local result = resolved_joker(jokers, effects, index)
	if result then return result.effect, result.key, result.index end
	return nil
end

-- A Joker's effect on one scoring card (context.individual, cardarea play).
local function apply_individual(effect, state, card, own_key)
	local kind = effect.kind
	if kind == "suit_mult" or kind == "suit_card_mult" then
		if suit_matches(state, card, effect.suit) then state.mult = state.mult + effect.amount end
	elseif kind == "suit_chips" then
		if suit_matches(state, card, effect.suit) then state.chips = state.chips + effect.amount end
	elseif kind == "rank_mult" then
		if has_rank(effect.ranks, rank_of(card)) then state.mult = state.mult + effect.amount end
	elseif kind == "rank_chips" then
		if has_rank(effect.ranks, rank_of(card)) then state.chips = state.chips + effect.amount end
	elseif kind == "rank_chips_mult" then
		if has_rank(effect.ranks, rank_of(card)) then
			state.chips = state.chips + effect.chips
			state.mult = state.mult + effect.mult
		end
	elseif kind == "face_chips" then
		if scoring_face(state, card) then state.chips = state.chips + effect.amount end
	elseif kind == "face_mult" then
		if scoring_face(state, card) then state.mult = state.mult + effect.amount end
	elseif kind == "first_face_xmult" then
		if card == state.first_face then apply_xmult(state, effect.amount) end
	elseif kind == "chance_suit_xmult" then
		if suit_matches(state, card, effect.suit) then
			-- Oops! All 6s doubles the chance (G.GAME.probabilities.normal).
			apply_xmult(state, 1 + math.min(1, (effect.chance or 0.5)
				* (state.context.probability_multiplier or 1)) * ((effect.amount or 1) - 1))
		end
	elseif kind == "rotating_suit_xmult" then
		local target = state.context.joker_targets and state.context.joker_targets[own_key]
		if target and suit_matches(state, card, target) then apply_xmult(state, effect.amount) end
	elseif kind == "rank_scaling_chips" then
		-- Wee Joker grows on every scored 2, each trigger; a copy does not grow it.
		if own_key and rank_of(card) == effect.rank then
			state.growth[own_key] = (state.growth[own_key] or 0) + effect.amount
		end
	elseif kind == "rank_xmult" then
		-- Triboulet (group C jokers): X Mult per scoring card of the ranks.
		if has_rank(effect.ranks, rank_of(card)) then apply_xmult(state, effect.amount) end
	elseif kind == "played_card_chip_growth" then
		-- Hiker: +5 permanent chips on every trigger, seen by the card's later triggers.
		state.hiker[card] = (state.hiker[card] or 0) + (effect.amount or 5)
	-- group B jokers
	elseif kind == "rotating_card_xmult" then
		-- The Idol: X2 for each scored card of this round's rank and suit
		-- (get_id and is_suit, so Wild cards and Smeared Joker count).
		local target = state.context.idol_card
		if target and rank_of(card) == target.rank and suit_matches(state, card, target.suit) then
			apply_xmult(state, effect.amount)
		end
	elseif kind == "lucky_scaling_xmult" then
		-- Lucky Cat: +X0.25 each time a scored Lucky card triggers (1 in 5 Mult or
		-- 1 in 15 money, per trigger), at its expected rate; a copy does not grow it.
		if own_key and card.enhancement == "m_lucky" then
			local odds = state.context.probability_multiplier or 1
			local chance = 1 - (1 - math.min(1, odds / 5)) * (1 - math.min(1, odds / 15))
			state.growth[own_key] = (state.growth[own_key] or 0) + (effect.amount or 0.25) * chance
		end
	end
end

-- A Joker's effect on one held card (context.individual, cardarea hand).
-- Returns true when it applies to that card.
local function held_applies(effect, state, card)
	local kind = effect.kind
	if kind == "held_rank_mult" or kind == "held_rank_xmult" then return rank_of(card) == effect.rank end
	if kind == "held_lowest_rank_mult" then return card == state.raised_card end
	return false
end

local function apply_held(effect, state, card)
	local kind = effect.kind
	if kind == "held_rank_mult" then
		state.mult = state.mult + effect.amount
	elseif kind == "held_rank_xmult" then
		apply_xmult(state, effect.amount)
	elseif kind == "held_lowest_rank_mult" then
		state.mult = state.mult + (effect.amount or 2) * nominal(card)
	end
end

function Evaluator.evaluate(cards, levels, jokers, context)
	jokers = jokers or {}
	local effects = context and context.joker_effects or {}
	local adapters = context and context.joker_effects
	local allow_straight_gaps, allow_four_card_hands, suit_merge = false, false, false
	for index = 1, #jokers do
		local cached = context and context.resolved_jokers
		if resolves_kind(jokers, effects, index, "straight_gaps", cached) then allow_straight_gaps = true end
		if resolves_kind(jokers, effects, index, "four_card_hands", cached) then allow_four_card_hands = true end
		if resolves_kind(jokers, effects, index, "suit_merge", cached) then suit_merge = true end
	end
	local name, scoring, contained = Evaluator.classify(
		cards, allow_straight_gaps, allow_four_card_hands, suit_merge)
	for index = 1, #jokers do
		if resolves_kind(jokers, effects, index, "all_played_score", context and context.resolved_jokers) then
			scoring = cards
			break
		end
	end
	local hand = Evaluator.hands[name]
	local level = (levels and levels[name]) or 1
	-- The Psychic does not score a hand of fewer than 5
	-- cards (Blind:debuff_hand, h_size_ge); nothing else of the hand happens.
	if context and context.boss_min_cards and #cards < context.boss_min_cards then
		return {
			name = name, strength = hand.strength, chips = 0, mult = 0, score = 0,
			scoring_cards = scoring, contained = contained, card_repetitions = {},
			dollars = 0, growth = {}, hiker = {}, debuffed_hand = true,
		}
	end

	-- Each Joker's effect with copies (Blueprint/Brainstorm) resolved.
	local resolved, owners, targets = {}, {}, {}
	local held_repetitions, scoring_repetitions, stencils = 0, 1, 0
	local all_cards_are_faces = false
	for index = 1, #jokers do
		local entry = context and context.resolved_jokers and context.resolved_jokers[index]
		if not entry then entry = resolved_joker(jokers, effects, index) end
		local effect, key, target = entry and entry.effect, entry and entry.key, entry and entry.index
		resolved[index], targets[index] = effect, target
		owners[index] = effect and key == jokers[index] and key or false
		if effect then
			if effect.kind == "all_faces" then all_cards_are_faces = true end
			if effect.kind == "held_retrigger" then held_repetitions = held_repetitions + 1 end
			if effect.kind == "retrigger_scoring" and context and context.hands_left == 1 then
				scoring_repetitions = scoring_repetitions + 1
			end
		end
		local own = effects[jokers[index]]
		if own and own.kind == "empty_slot_xmult" then stencils = stencils + 1 end
	end

	local base_chips = hand.chips + hand.l_chips * (level - 1)
	local base_mult = hand.mult + hand.l_mult * (level - 1)
	if context and context.boss_halve_base then
		-- The Flint halves base chips and mult (Blind:modify_hand).
		base_mult = math.max(math.floor(base_mult * 0.5 + 0.5), 1)
		base_chips = math.max(math.floor(base_chips * 0.5 + 0.5), 0)
	end
	local state = {
		chips = base_chips,
		mult = base_mult,
		x_mult = 1,
		name = name,
		contained = contained,
		scoring = scoring,
		played_count = #cards,
		joker_count = #jokers,
		stencils = stencils,
		discards_left = (context and context.discards_left) or 0,
		context = context or {},
		all_cards_are_faces = all_cards_are_faces,
		suit_merge = suit_merge,
		growth = {},
		hiker = {},
		dollars = 0,
	}
	-- group C jokers: Vampire (context.before, not copied) takes the
	-- enhancement of every enhanced, non-debuffed scoring card before it scores,
	-- left to right; a Midas Mask to its left has already made the face cards
	-- Gold. The cards score without it and get it back after this evaluation.
	local stolen, enhanced = nil, nil
	for index = 1, #jokers do
		local own = effects[jokers[index]]
		if own and (own.kind == "face_gold_conversion" or own.kind == "enhancement_steal_xmult") then
			if not enhanced then
				enhanced = {}
				for _, card in ipairs(scoring) do enhanced[card] = card.enhancement ~= nil end
			end
			if own.kind == "face_gold_conversion" then
				for _, card in ipairs(scoring) do
					if scoring_face(state, card) then enhanced[card] = true end
				end
			else
				stolen = stolen or {}
				state.vampire_gain = state.vampire_gain or {}
				local count = 0
				for _, card in ipairs(scoring) do
					if not card.debuff and enhanced[card] then
						enhanced[card] = false
						if stolen[card] == nil then stolen[card] = card.enhancement or false end
						count = count + 1
					end
				end
				state.vampire_gain[jokers[index]] = (state.vampire_gain[jokers[index]] or 0)
					+ count * (own.amount or 0.1)
			end
		end
	end
	for card in pairs(stolen or {}) do card.enhancement = nil end
	for _, card in ipairs(scoring) do
		if scoring_face(state, card) then state.first_face = card; break end
	end

	-- Played cards, in order, each trigger (Red Seal and retrigger Jokers).
	local card_repetition_counts = {}
	for scoring_index, card in ipairs(scoring) do
		local repetitions = scoring_repetitions + (card.seal == "Red" and 1 or 0)
		-- a debuffed card scores nothing and is not retriggered.
		if card.debuff then repetitions = -math.huge end
		for index = 1, #jokers do
			local effect = resolved[index]
			if effect and effect.kind == "rank_retrigger" and has_rank(effect.ranks, rank_of(card)) then
				repetitions = repetitions + (effect.repetitions or 1)
			elseif effect and effect.kind == "face_retrigger" and scoring_face(state, card) then
				repetitions = repetitions + (effect.repetitions or 1)
			elseif effect and effect.kind == "first_scoring_retrigger"
				and scoring_index <= (effect.cards or 2) then
				repetitions = repetitions + (effect.repetitions or 1)
			elseif effect and effect.kind == "limited_retrigger" then
				repetitions = repetitions + 1   -- Seltzer (group C jokers)
			end
		end
		repetitions = math.max(0, repetitions)
		card_repetition_counts[card] = repetitions
		for _ = 1, repetitions do
			local bonus = state.hiker[card] or 0
			if is_stone(card) then
				state.chips = state.chips + 50 + (card.perma_bonus or 0) + bonus
			else
				state.chips = state.chips + card.chips + bonus
			end
			if card.enhancement == "m_bonus" then state.chips = state.chips + 30 end
			if card.enhancement == "m_mult" then state.mult = state.mult + 4 end
			if card.enhancement == "m_lucky" then state.mult = state.mult + 4 end   -- expected 1 in 5 for +20
			-- Glass X2, or X1.5 under Multiplayer's reworked Glass (context.glass_xmult).
			if card.enhancement == "m_glass" then apply_xmult(state, state.context.glass_xmult or 2) end
			if card.edition == "foil" then state.chips = state.chips + 50 end
			if card.edition == "holo" then state.mult = state.mult + 10 end
			if card.edition == "polychrome" then apply_xmult(state, 1.5) end
			if card.seal == "Gold" then state.dollars = state.dollars + 3 end
			if adapters then
				for index = 1, #jokers do
					local effect = resolved[index]
					if effect and INDIVIDUAL[effect.kind] then apply_individual(effect, state, card, owners[index]) end
				end
			end
		end
	end

	-- Held cards, in order: Steel, then Jokers. Red Seal and Mime retrigger a held
	-- card only when something applies to it.
	local held = (context and context.held_cards) or {}
	local lowest_rank
	for _, card in ipairs(held) do
		if not is_stone(card) and (not lowest_rank or card.rank <= lowest_rank) then
			lowest_rank, state.raised_card = card.rank, card
		end
	end
	for _, card in ipairs(held) do
		local active = card.enhancement == "m_steel" and not card.debuff
		if adapters and not active then
			for index = 1, #jokers do
				local effect = resolved[index]
				if effect and HELD[effect.kind] and not card.debuff and held_applies(effect, state, card) then active = true; break end
			end
		end
		if active then
			local repetitions = 1 + held_repetitions + (card.seal == "Red" and 1 or 0)
			for _ = 1, repetitions do
				if card.enhancement == "m_steel" then apply_xmult(state, 1.5) end
				if adapters then
					for index = 1, #jokers do
						local effect = resolved[index]
						if effect and HELD[effect.kind] and held_applies(effect, state, card) then
							apply_held(effect, state, card)
						end
					end
				end
			end
		end
	end

	if adapters then
		state.context.joker_state = state.context.joker_state or {}
		state.context.jokers = jokers
		local editions = state.context.joker_editions or {}
		local rarities = state.context.joker_rarities or {}
		for index, joker in ipairs(jokers) do
			local edition = editions[joker]
			if edition == "foil" then state.chips = state.chips + 50 end
			if edition == "holo" then state.mult = state.mult + 10 end
			local effect = resolved[index]
			if effect and not NOT_MAIN[effect.kind] then
				apply_adapter(effect, state, jokers[targets[index]], targets[index], {})
			end
			for other = 1, #jokers do
				local baseball = resolved[other]
				if baseball and baseball.kind == "rarity_xmult" and targets[other] ~= index
					and rarities[joker] == baseball.rarity then
					apply_xmult(state, baseball.amount)
				end
			end
			if edition == "polychrome" then apply_xmult(state, 1.5) end
		end
	else
	for _, joker in ipairs(jokers) do
		if joker == "j_joker" then state.mult = state.mult + 4 end
		local suit_effect = suit_jokers[joker]
		if suit_effect then
			for _, card in ipairs(scoring) do if suit_matches(state, card, suit_effect.suit) then state.mult = state.mult + suit_effect.mult end end
		end
		if joker == "j_jolly" and contains(state, "Pair") then state.mult = state.mult + 8 end
		if joker == "j_zany" and contains(state, "Three of a Kind") then state.mult = state.mult + 12 end
		if joker == "j_mad" and contains(state, "Two Pair") then state.mult = state.mult + 10 end
		if joker == "j_crazy" and contains(state, "Straight") then state.mult = state.mult + 12 end
		if joker == "j_droll" and contains(state, "Flush") then state.mult = state.mult + 10 end
		if joker == "j_sly" and contains(state, "Pair") then state.chips = state.chips + 50 end
		if joker == "j_wily" and contains(state, "Three of a Kind") then state.chips = state.chips + 100 end
		if joker == "j_clever" and contains(state, "Two Pair") then state.chips = state.chips + 80 end
		if joker == "j_devious" and contains(state, "Straight") then state.chips = state.chips + 100 end
		if joker == "j_crafty" and contains(state, "Flush") then state.chips = state.chips + 80 end
		if joker == "j_half" and #cards <= 3 then state.mult = state.mult + 20 end
		if joker == "j_abstract" then state.mult = state.mult + 3 * #jokers end
		if joker == "j_banner" then state.chips = state.chips + 30 * ((context and context.discards_left) or 0) end
		if joker == "j_mystic_summit" and ((context and context.discards_left) or 0) == 0 then state.mult = state.mult + 15 end
	end
	end
	-- Observatory applies X1.5 Mult for each held Planet matching the played
	-- poker hand (Voucher calculate context: other_consumeable).
	if state.context.observatory_xmult then
		for _, consumable in ipairs(state.context.consumables or {}) do
			if consumable.type == "planet" and consumable.hand == state.name then
				apply_xmult(state, state.context.observatory_xmult)
			end
		end
	end
	for card, enhancement in pairs(stolen or {}) do card.enhancement = enhancement or nil end

	return {
		name = name,
		strength = hand.strength,
		chips = state.chips,
		mult = state.mult,
		score = math.max(0, math.floor(state.chips * state.mult)),
		scoring_cards = scoring,
		-- what the simulator applies after the hand.
		contained = contained,
		card_repetitions = card_repetition_counts,
		dollars = state.dollars,
		growth = state.growth,
		hiker = state.hiker,
	}
end
return Evaluator
