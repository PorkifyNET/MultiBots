local Strategy = {}

local function weight(state, key)
	return tonumber(state and state.weights and state.weights[key]) or 1
end

local hands = {
	"High Card", "Pair", "Two Pair", "Three of a Kind", "Straight",
	"Flush", "Full House", "Four of a Kind", "Straight Flush",
	"Five of a Kind",
}

local base_affinity = {
	["High Card"] = 0,
	["Pair"] = 0,
	["Two Pair"] = 0,
	["Three of a Kind"] = 0,
	["Straight"] = 0,
	["Flush"] = 0,
	["Full House"] = 0,
	["Four of a Kind"] = 0,
	["Straight Flush"] = 0,
	["Five of a Kind"] = 0,
}

local pvp_xmult_kinds = {
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
	first_face_xmult = true,
	retrigger_scoring = true,
	first_scoring_retrigger = true,
	rank_retrigger = true,
	planet_scaling_xmult = true,
	deck_add_scaling_xmult = true,
	enhancement_count_xmult = true,
	empty_slot_xmult = true,
	enhanced_threshold_xmult = true,
	rotating_suit_xmult = true,
	blind_scaling_xmult = true,
	avoid_most_played_xmult = true,
	chance_xmult_money = true,
	copy_joker = true,
}

local pvp_score_kinds = {
	flat_mult = true,
	hand_mult = true,
	hand_chips = true,
	suit_mult = true,
	suit_chips = true,
	suit_card_mult = true,
	rank_mult = true,
	rank_chips = true,
	rank_chips_mult = true,
	face_mult = true,
	face_chips = true,
	green_scaling_mult = true,
	hand_scaling_mult = true,
	straight_scaling_chips = true,
	four_card_scaling_chips = true,
	rank_scaling_chips = true,
	chance_hand_level = true,
	skipped_pack_scaling_mult = true,
	discard_suit_scaling_chips = true,
	sacrifice_scaling_mult = true,
	opponent_sale_mult = true,
}

local rank_target_kinds = {
	rank_mult = true, rank_chips = true, rank_chips_mult = true,
	rank_scaling_chips = true, rank_retrigger = true,
	held_rank_mult = true, held_rank_xmult = true, deck_rank_money = true,
}

local suit_target_kinds = {
	suit_mult = true, suit_chips = true, suit_card_mult = true,
	chance_suit_xmult = true, held_suit_xmult = true,
}

local function pvp_deficit(state)
	local bot = tonumber(state.previous_pvp_score) or 0
	local player = tonumber(state.previous_player_score) or 0
	if bot <= 0 or player <= bot then return 0 end
	return math.min(1, (player - bot) / player)
end

local function score_deficit(state)
	local deficit = pvp_deficit(state)
	local target = tonumber(state.upcoming_score_target) or 0
	local recent = state.round_history and state.round_history[#state.round_history]
	local score = recent and tonumber(recent.score) or 0
	if target > 0 and score > 0 and score < target then
		deficit = math.max(deficit, math.min(1, (target - score) / target))
	end
	return deficit
end

local function copy_map(source)
	local out = {}
	for key, value in pairs(source or {}) do out[key] = value end
	return out
end

local function add(scores, hand, amount)
	if hand and scores[hand] then scores[hand] = scores[hand] + amount end
end

local function add_containing(scores, hand, amount)
	add(scores, hand, amount)
	if hand == "Pair" then
		add(scores, "Two Pair", amount * 0.5)
		add(scores, "Three of a Kind", amount * 0.5)
		add(scores, "Full House", amount * 0.4)
		add(scores, "Four of a Kind", amount * 0.3)
		add(scores, "Five of a Kind", amount * 0.2)
	elseif hand == "Two Pair" then
		add(scores, "Full House", amount * 0.5)
	elseif hand == "Three of a Kind" then
		add(scores, "Full House", amount * 0.5)
		add(scores, "Four of a Kind", amount * 0.4)
		add(scores, "Five of a Kind", amount * 0.3)
	elseif hand == "Straight" then
		add(scores, "Straight Flush", amount * 0.4)
	elseif hand == "Flush" then
		add(scores, "Straight Flush", amount * 0.4)
	end
end

local function hand_payoff_weight(hand, shape)
	if hand == "Four of a Kind" then
		return math.min(1, 0.10 + (shape.rank_focus or 0) * 0.05)
	elseif hand == "Straight Flush" then
		return math.min(1, 0.04 + math.max(0, (shape.dominant_ratio or 0) - 0.25) * 1.2
			+ (shape.straight_focus or 0) * 0.8)
	elseif hand == "Five of a Kind" then
		return math.min(1, 0.02 + (shape.rank_focus or 0) * 0.04)
	elseif hand == "Full House" then
		return math.min(1, 0.40 + (shape.rank_focus or 0) * 0.04)
	elseif hand == "Three of a Kind" then
		return math.min(1, 0.55 + (shape.rank_focus or 0) * 0.04)
	end
	return 1
end

local function deck_shape(deck)
	local suits, ranks, enhanced = {}, {}, 0
	for _, card in ipairs(deck or {}) do
		suits[card.suit] = (suits[card.suit] or 0) + 1
		ranks[card.rank] = (ranks[card.rank] or 0) + 1
		if card.enhancement then enhanced = enhanced + 1 end
	end
	local dominant_suit, dominant_count = "Spades", 0
	for suit, count in pairs(suits) do if count > dominant_count then dominant_suit, dominant_count = suit, count end end
	-- A normal 52-card deck has four cards of every rank; those ordinary copies
	-- are not evidence of a pair build. Measure concentration above the deck's
	-- average rank population so only actual rank fixing creates affinity.
	local rank_average = #deck > 0 and #deck / 13 or 0
	local rank_focus = 0
	for _, count in pairs(ranks) do rank_focus = rank_focus + math.max(0, count - rank_average) end
	local best_window, best_window_cards = 0, 0
	for low = 2, 10 do
		local present, cards = 0, 0
		if low == 2 then
			for rank = 2, 5 do if ranks[rank] then present = present + 1; cards = cards + ranks[rank] end end
			if ranks[14] then present = present + 1; cards = cards + ranks[14] end
		else
			for rank = low, low + 4 do if ranks[rank] then present = present + 1; cards = cards + ranks[rank] end end
		end
		if present > best_window or (present == best_window and cards > best_window_cards) then
			best_window, best_window_cards = math.min(5, present), cards
		end
	end
	return {
		suits = suits,
		ranks = ranks,
		dominant_suit = dominant_suit,
		dominant_ratio = #deck > 0 and dominant_count / #deck or 0,
		rank_focus = rank_focus,
		straight_window = best_window,
		straight_focus = math.max(0, (#deck > 0 and best_window_cards / #deck or 0) - 5 / 13),
		enhanced = enhanced,
	}
end

local function effect_affinity(scores, effect, shape, state)
	if not effect then return end
	if effect.kind == "hand_mult" or effect.kind == "hand_chips" or effect.kind == "hand_xmult" then
		-- A powerful payoff is not evidence that the deck can make its hand. In
		-- particular, The Family must not turn a stock deck into a supposed Four
		-- of a Kind build merely by occupying a Joker slot.
		local amount = (effect.kind == "hand_xmult" and 28 or 18) * hand_payoff_weight(effect.hand, shape)
		add_containing(scores, effect.hand, amount)
	elseif effect.kind == "straight_scaling_chips" then
		add_containing(scores, "Straight", 34)
	elseif effect.kind == "hand_scaling_mult" then
		add_containing(scores, effect.hand, 34)
	elseif effect.kind == "repeat_hand_xmult" or effect.kind == "hand_usage_mult" then
		for hand, count in pairs(state.hand_usage or {}) do add(scores, hand, count * 2.5) end
	elseif effect.kind == "suit_mult" or effect.kind == "suit_chips" or effect.kind == "suit_card_mult"
		or effect.kind == "chance_suit_xmult" then
		-- Suit payoffs work in any hand. They imply a Flush build only after the
		-- deck is genuinely concentrated in the Joker's rewarded suit.
		add(scores, "High Card", 3)
		add(scores, "Pair", 3)
		local rewarded_ratio = shape.suits[effect.suit] and shape.suits[effect.suit] / math.max(1, #state.deck) or 0
		if effect.suit == shape.dominant_suit and rewarded_ratio > 0.32 then
			add_containing(scores, "Flush", (rewarded_ratio - 0.30) * 55)
		end
	elseif effect.kind == "rank_mult" or effect.kind == "rank_chips" or effect.kind == "rank_chips_mult"
		or effect.kind == "rank_scaling_chips" or effect.kind == "face_mult" or effect.kind == "face_chips"
		or effect.kind == "first_face_xmult" or effect.kind == "green_scaling_mult" then
		add(scores, "High Card", 14)
		add(scores, "Pair", 10)
		add(scores, "Two Pair", 7)
	elseif effect.kind == "card_count_mult" then
		add(scores, "High Card", 12)
		add(scores, "Pair", 10)
	elseif effect.kind == "four_card_scaling_chips" then
		add(scores, "Pair", 8)
		add(scores, "Two Pair", 10)
	elseif effect.kind == "four_card_hands" then
		add(scores, "Straight", 10)
		add(scores, "Flush", 10)
	end
end

function Strategy.analyze(state)
	local scores = copy_map(base_affinity)
	local shape = deck_shape(state.deck or {})
	if state.strategy_open == false then
		return {
			primary_hand = nil,
			secondary_hand = nil,
			confidence = 0,
			exploring = true,
			hand_scores = scores,
			shape = shape,
		}
	end
	local total_usage = 0
	for _, count in pairs(state.hand_usage or {}) do total_usage = total_usage + count end
	for _, hand in ipairs(hands) do
		local level = (state.levels and state.levels[hand]) or 1
		local usage = (state.hand_usage and state.hand_usage[hand]) or 0
		scores[hand] = scores[hand] + (level - 1) * 12
		if total_usage > 0 then
			-- A lucky rare hand is evidence that it happened, not that the stock
			-- deck can build around it. Discount observed history by the same deck
			-- feasibility used for conditional Joker payoffs.
			scores[hand] = scores[hand] + usage / total_usage * 30 * hand_payoff_weight(hand, shape)
		end
	end
	add(scores, "Flush", math.max(0, shape.dominant_ratio - 0.25) * 60)
	add(scores, "Straight", shape.straight_focus * 55)
	add(scores, "Pair", shape.rank_focus * 1.2)
	add(scores, "Two Pair", shape.rank_focus * 0.9)
	for _, key in ipairs(state.jokers or {}) do effect_affinity(scores, state.joker_effects[key], shape, state) end
	local alignment = weight(state, "plan_alignment")
	for _, hand in ipairs(hands) do
		scores[hand] = base_affinity[hand] + (scores[hand] - base_affinity[hand]) * alignment
	end

	local ordered = {}
	for _, hand in ipairs(hands) do ordered[#ordered + 1] = { hand = hand, score = scores[hand] } end
	table.sort(ordered, function(a, b)
		if a.score == b.score then return a.hand < b.hand end
		return a.score > b.score
	end)
	local first, second = ordered[1], ordered[2]
	local total_score = 0
	for _, candidate in ipairs(ordered) do total_score = total_score + math.max(0, candidate.score) end
	-- This is the primary plan's share of all positive strategic evidence. It
	-- behaves like a readable support ratio and cannot hit 100% merely because
	-- the runner-up trails by an arbitrary threshold.
	local confidence = total_score <= 0 and 0 or first.score / total_score
	return {
		primary_hand = first.hand,
		secondary_hand = second.hand,
		confidence = confidence,
		hand_scores = scores,
		shape = shape,
	}
end

local function hand_matches(effect_hand, plan)
	return effect_hand == plan.primary_hand or effect_hand == plan.secondary_hand
		or (effect_hand == "Pair" and (plan.primary_hand == "Two Pair" or plan.primary_hand == "Full House"))
		or (effect_hand == "Straight" and plan.primary_hand == "Straight Flush")
		or (effect_hand == "Flush" and plan.primary_hand == "Straight Flush")
end

local function count_deck_cards(state, predicate)
	local count = 0
	for _, card in ipairs(state.deck or {}) do if predicate(card) then count = count + 1 end end
	return count
end

local flower_hand_support = {
	["High Card"] = 0.01,
	Pair = 0.02,
	["Two Pair"] = 0.22,
	["Three of a Kind"] = 0.08,
	Straight = 0.55,
	Flush = 0.01,
	["Full House"] = 0.45,
	["Four of a Kind"] = 0.80,
	["Straight Flush"] = 0.01,
	["Five of a Kind"] = 0.002,
}

local scoring_card_count = {
	["High Card"] = 1, Pair = 2, ["Two Pair"] = 4, ["Three of a Kind"] = 3,
	Straight = 5, Flush = 5, ["Full House"] = 5, ["Four of a Kind"] = 4,
	["Straight Flush"] = 5,
	["Five of a Kind"] = 5,
}

local function flower_pot_support(state, plan)
	local deck = state.deck or {}
	if #deck == 0 then return 0 end
	local suits = { Hearts = 0, Spades = 0, Clubs = 0, Diamonds = 0 }
	local wilds = 0
	for _, card in ipairs(deck) do
		if card.enhancement == "m_wild" then
			wilds = wilds + 1
		elseif suits[card.suit] ~= nil then
			suits[card.suit] = suits[card.suit] + 1
		end
	end
	local minimum = #deck
	for _, suit in ipairs({ "Hearts", "Spades", "Clubs", "Diamonds" }) do
		minimum = math.min(minimum, suits[suit])
	end
	local ordinary = math.max(1, #deck - wilds)
	local balance = math.min(1, minimum / (ordinary / 4))
	local function hand_support(hand)
		if not hand then return 0.12 * balance end
		local natural = (flower_hand_support[hand] or 0.05) * balance
		-- Wilds cover missing suits, but must first be drawn and belong to the
		-- scoring subset. Pair/High Card builds therefore gain much less than a
		-- five-card hand from the same number of Wild cards.
		local drawn_wild = math.min(0.5, wilds * 8 / #deck)
		local scoring_share = (scoring_card_count[hand] or 3) / 5
		return math.min(1, natural + drawn_wild * scoring_share)
	end
	if plan.exploring then return hand_support(nil) end
	return hand_support(plan.primary_hand) * 0.7 + hand_support(plan.secondary_hand) * 0.3
end

local structural_feasibility = {
	["High Card"] = 1,
	["Pair"] = 0.82,
	["Two Pair"] = 0.48,
	["Three of a Kind"] = 0.20,
	["Straight"] = 0.24,
	["Flush"] = 0.18,
	["Full House"] = 0.10,
	["Four of a Kind"] = 0.025,
	["Straight Flush"] = 0.008,
	["Five of a Kind"] = 0.001,
}

function Strategy.hand_feasibility(state, hand, plan)
	plan = plan or Strategy.analyze(state)
	local total_usage = 0
	for _, count in pairs(state.hand_usage or {}) do total_usage = total_usage + count end
	local shape = plan.shape or deck_shape(state.deck or {})
	local observed = total_usage > 0 and ((state.hand_usage and state.hand_usage[hand]) or 0) / total_usage or 0
	observed = observed * hand_payoff_weight(hand, shape)
	local structural = structural_feasibility[hand] or 0
	if hand == "Pair" then
		structural = structural + math.min(0.12, shape.rank_focus * 0.012)
	elseif hand == "Two Pair" then
		structural = structural + math.min(0.24, shape.rank_focus * 0.024)
	elseif hand == "Three of a Kind" or hand == "Full House" then
		structural = structural + math.min(0.35, shape.rank_focus * 0.035)
	elseif hand == "Four of a Kind" then
		structural = structural + math.min(0.30, shape.rank_focus * 0.03)
	elseif hand == "Five of a Kind" then
		structural = structural + math.min(0.25, shape.rank_focus * 0.025)
	elseif hand == "Straight" then
		structural = structural + math.min(0.35, shape.straight_focus * 1.8)
	elseif hand == "Flush" then
		structural = structural + math.max(0, shape.dominant_ratio - 0.25) * 2.2
	elseif hand == "Straight Flush" then
		structural = structural + math.max(0, shape.dominant_ratio - 0.25) * shape.straight_focus
	end
	-- Observed plays matter, but never make a structurally rare hand look as
	-- repeatable as the build's bread-and-butter hand after one lucky draw.
	return math.min(1, structural * 0.65 + observed * 0.7)
end

function Strategy.joker_utility(state, joker, plan)
	plan = plan or Strategy.analyze(state)
	local value = joker.utility or 0
	local base_value = value
	local effect = joker.effect
	-- Catch-up pressure may promote a viable scoring upgrade, but it must not
	-- resurrect a conditional Joker that the build cannot realistically use.
	local catchup_factor = 1
	if not effect then return value * weight(state, "joker_value") end
	if plan.exploring and (effect.kind == "hand_mult" or effect.kind == "hand_chips"
		or effect.kind == "hand_xmult" or effect.kind == "hand_scaling_mult") then
		-- Exploration means the bot has not committed to a build; it does not mean
		-- every conditional payoff is online. Use stock-deck/observed feasibility
		-- so a first-shop Pair payoff can remain plausible while rare XMult such
		-- as The Order or The Family cannot consume the only scoring slot at its
		-- fully-active catalog value.
		local feasibility = Strategy.hand_feasibility(state, effect.hand, plan)
		if effect.kind == "hand_xmult" then
			value = math.min(value, 9 + feasibility * 10)
			catchup_factor = 0
		else
			value = math.min(value, 9 + feasibility * 15)
		end
	end
	if not plan.exploring then
		if (effect.kind == "hand_mult" or effect.kind == "hand_chips" or effect.kind == "hand_xmult"
			or effect.kind == "hand_scaling_mult") then
			local feasibility = Strategy.hand_feasibility(state, effect.hand, plan)
			if hand_matches(effect.hand, plan) then
				value = value + 14 * math.max(0.25, feasibility)
			else
				-- Large base utility values describe the Joker at full activation. Scale
				-- them down when the current deck cannot realistically trigger it.
				-- Conditional X Mult is especially costly when it occupies a slot but
				-- almost never activates; this prevents speculative purchases such as
				-- The Order in a settled Pair/Two Pair build.
				local inactive_penalty = effect.kind == "hand_xmult" and 10 or 5
				value = value - inactive_penalty - (1 - feasibility) * 20
				if effect.kind == "hand_xmult" then
					value = math.min(value, 10 + feasibility * 3)
					catchup_factor = 0
				end
			end
		elseif effect.kind == "straight_scaling_chips" then
			local current = (state.joker_state and state.joker_state[joker.key]) or 0
			local straight_plan = plan.primary_hand == "Straight" or plan.secondary_hand == "Straight"
			value = value + current / 4
				+ (straight_plan and 16 or 4)
			local owned = false
			for _, key in ipairs(state.jokers or {}) do
				if key == joker.key then owned = true; break end
			end
			-- Runner is an investment, not an emergency score Joker. Once the run is
			-- established, do not buy a fresh copy into an unrelated build merely
			-- because the previous PvP score was low.
			if not owned and current <= 0 and not straight_plan then
				local feasibility = Strategy.hand_feasibility(state, "Straight", plan)
				value = math.min(value, 9 + feasibility * 8)
				catchup_factor = 0
			end
		elseif effect.kind == "four_card_scaling_chips" then
			local current = (state.joker_state and state.joker_state[joker.key]) or 0
			-- Established permanent Chips are real build equity. Without including
			-- them, a heavily scaled Square/Runner/Wee Joker looks like its fresh
			-- catalog copy and can be sold for a weaker, unscaled replacement.
			value = value + current / 4
			for _, owned_key in ipairs(state.jokers or {}) do
				local owned = state.joker_effects and state.joker_effects[owned_key]
				if owned and owned.kind == "card_count_mult" and (owned.maximum or 5) < 4 then
					-- Half Joker's +Mult switches off on the exact four-card submissions
					-- Square needs. A fresh Square in that build is effectively a blank
					-- Joker; established Square Chips can eventually outweigh the conflict.
					value = value - 10
					break
				end
			end
		elseif effect.kind == "rank_scaling_chips" then
			local current = (state.joker_state and state.joker_state[joker.key]) or 0
			value = value + current / 4
		elseif effect.kind == "suit_mult" or effect.kind == "suit_chips" or effect.kind == "suit_card_mult" then
			value = value + (plan.primary_hand == "Flush" and 10 or plan.shape.dominant_ratio * 8)
		end
	end

	-- Activation checks are independent of the chosen poker-hand plan. Static
	-- catalog utility assumes the condition is online; an inert conditional
	-- Joker must not fill a slot just because its theoretical ceiling is high.
	if effect.kind == "decaying_chips" then
		-- Temporary Jokers must be valued at what they have left, not at the
		-- strength printed on a fresh shop copy. Otherwise an exhausted Ice Cream
		-- can occupy a slot for several Antes and prevent a durable replacement.
		local current = (state.joker_state and state.joker_state[joker.key]) or effect.initial or 0
		value = 5 + math.max(0, current) / 5
	elseif effect.kind == "decaying_mult" then
		local current = (state.joker_state and state.joker_state[joker.key]) or effect.initial or 0
		value = 6 + math.max(0, current) * 0.8
	elseif effect.kind == "green_scaling_mult" then
		local current = (state.joker_state and state.joker_state[joker.key]) or 0
		value = value + current * 0.8
		if state.discards_per_round > 3 then value = value - 2 end
	elseif effect.kind == "joker_count_mult" then
		value = 12 + (effect.amount or 0) * math.max(1, #(state.jokers or {}))
	elseif effect.kind == "hand_usage_mult" then
		local best = 0
		for _, count in pairs(state.hand_usage or {}) do best = math.max(best, count) end
		value = 12 + best * (effect.amount or 1)
	elseif effect.kind == "bus_scaling_mult" then
		local current = (state.joker_state and state.joker_state[joker.key]) or 0
		-- Ride the Bus needs time to compound and asks the policy to avoid face
		-- cards. Starting it late is usually worse than preserving an open slot
		-- for immediate scoring, especially in an already established build.
		value = 18 + current - (current == 0 and math.max(0, (state.ante or 1) - 2) * 3 or 0)
	elseif effect.kind == "planet_scaling_xmult" then
		local current = (state.joker_state and state.joker_state[joker.key]) or effect.initial or 1
		-- Even an unscaled Constellation is a live XMult engine: every future
		-- Planet both improves a hand and permanently grows it. The old baseline
		-- of 18 made the bot sell X1.1 Constellation for ordinary additive Jokers.
		value = 24 + math.max(0, current - 1) * 50
	elseif effect.kind == "rank_retrigger" then
		local matching = count_deck_cards(state, function(card)
			for _, rank in ipairs(effect.ranks or {}) do if card.rank == rank then return true end end
			return false
		end)
		value = 12 + math.min(20, matching * 1.25)
	elseif effect.kind == "face_retrigger" then
		local faces = count_deck_cards(state, function(card) return card.rank >= 11 and card.rank <= 13 end)
		local enablers = 0
		for _, key in ipairs(state.jokers or {}) do
			local owned = state.joker_effects and state.joker_effects[key]
			if owned and (owned.kind == "face_chips" or owned.kind == "face_mult"
				or owned.kind == "first_face_xmult" or owned.kind == "all_faces") then
				enablers = enablers + 1
			end
		end
		value = 8 + math.min(24, faces * 1.2) + enablers * 4
	elseif effect.kind == "first_scoring_retrigger" then
		value = 18 + (effect.cards or 2) * (effect.repetitions or 1) * 5
	elseif effect.kind == "held_retrigger" then
		local steel = count_deck_cards(state, function(card) return card.enhancement == "m_steel" end)
		local enablers = 0
		for _, key in ipairs(state.jokers or {}) do
			local owned = state.joker_effects and state.joker_effects[key]
			if owned and (owned.kind == "held_rank_mult" or owned.kind == "held_rank_xmult"
				or owned.kind == "held_lowest_rank_mult") then enablers = enablers + 1 end
		end
		value = 8 + math.min(26, steel * 2 + enablers * 8)
	elseif effect.kind == "round_joker_generation" then
		local owned = false
		for _, key in ipairs(state.jokers or {}) do if key == joker.key then owned = true; break end end
		local open_after = math.max(0, (state.joker_limit or 5) - #(state.jokers or {}) - (owned and 0 or 1))
		value = 8 + math.min(effect.count or 2, open_after) * 10
	elseif effect.kind == "round_tarot_generation" then
		local pressure = Strategy.deck_fix_pressure and Strategy.deck_fix_pressure(state) or 0
		value = 18 + math.min(8, pressure * 0.4)
	elseif effect.kind == "pack_tarot_chance" then
		local pressure = Strategy.deck_fix_pressure and Strategy.deck_fix_pressure(state) or 0
		value = 14 + math.min(8, pressure * 0.3)
	elseif effect.kind == "straight_ace_tarot" then
		local feasibility = Strategy.hand_feasibility(state, "Straight", plan)
		value = 8 + feasibility * 16
	elseif effect.kind == "straight_gaps" then
		local straight_plan = plan.primary_hand == "Straight" or plan.secondary_hand == "Straight"
		value = straight_plan and 30 or 14
	elseif effect.kind == "skipped_pack_scaling_mult" then
		local current = (state.joker_state and state.joker_state[joker.key]) or 0
		-- A fresh Red Card contributes no score. Buy scoring first; once acquired
		-- through a free source, value the Mult it has actually earned.
		value = current > 0 and 16 + current * 0.9 or 10
	elseif effect.kind == "chance_hand_level" then
		-- Each trigger is a persistent Planet effect. Value the remaining time to
		-- trigger it, while keeping a late copy useful but below immediate power.
		value = math.max(17, 27 - math.max(0, (state.ante or 1) - 1) * 2)
	elseif effect.kind == "periodic_xmult" then
		local remaining = (state.joker_state and state.joker_state[joker.key])
			or effect.initial or effect.every or 6
		local horizon = tonumber(state.hands_per_round) or 4
		-- A fresh Loyalty Card does nothing if its countdown cannot reach the
		-- active hand before the imminent PvP round ends.
		if state.next_round_is_pvp == true and remaining > horizon then
			value = 8
			catchup_factor = 0
		end
	elseif effect.kind == "deck_add_scaling_xmult" then
		local current = (state.joker_state and state.joker_state[joker.key]) or effect.initial or 1
		value = 18 + math.max(0, current - 1) * 50
	elseif effect.kind == "hand_scaling_mult" then
		local current = (state.joker_state and state.joker_state[joker.key]) or 0
		value = value + current * 0.8
	elseif effect.kind == "discard_suit_scaling_chips" then
		local current = (state.joker_state and state.joker_state[joker.key]) or 0
		value = 18 + current / 4
	elseif effect.kind == "sacrifice_scaling_mult" or effect.kind == "opponent_sale_mult" then
		local current = (state.joker_state and state.joker_state[joker.key]) or 0
		value = 14 + current * 0.8
		if effect.kind == "sacrifice_scaling_mult" and #(state.jokers or {}) > 1 then value = value - 12 end
	elseif effect.kind == "blind_scaling_xmult" then
		local current = (state.joker_state and state.joker_state[joker.key]) or effect.initial or 1
		value = 18 + math.max(0, current - 1) * 40
		if #(state.jokers or {}) > 0 and current <= 1 then value = 8 end
	elseif effect.kind == "avoid_most_played_xmult" then
		local current = (state.joker_state and state.joker_state[joker.key]) or effect.initial or 1
		value = 18 + math.max(0, current - 1) * 38
	elseif effect.kind == "chance_xmult_money" then
		local odds = math.max(1, tonumber(effect.odds) or 4)
		local expected_xmult = 1 + ((effect.amount or 1) - 1) / odds
		value = 18 + (expected_xmult - 1) * 18 + (effect.dollars or 0) / odds
	elseif effect.kind == "played_rank_planet" then
		local matching = count_deck_cards(state, function(card) return card.rank == effect.rank end)
		value = 10 + math.min(20, matching * 2.5)
	elseif effect.kind == "face_gold_conversion" then
		local faces = count_deck_cards(state, function(card) return card.rank >= 11 and card.rank <= 13 end)
		value = 10 + math.min(24, faces * 1.4)
	elseif effect.kind == "scoring_suit_money" then
		local matching = count_deck_cards(state, function(card) return card.suit == effect.suit end)
		value = 10 + math.min(20, matching * 0.9)
	elseif effect.kind == "suit_merge" then
		local shape = plan.shape or {}
		value = 16 + math.min(16, (shape.dominant_ratio or 0.25) * 20)
	elseif effect.kind == "tarot_scaling_mult" then
		value = 16 + (state.tarots_used or 0) * (effect.amount or 1)
	elseif effect.kind == "enhancement_count_xmult" then
		local count = count_deck_cards(state, function(card) return card.enhancement == effect.enhancement end)
		value = 8 + count * 5
		if count == 0 then catchup_factor = 0 end
	elseif effect.kind == "held_rank_xmult" then
		local matching = count_deck_cards(state, function(card) return card.rank == effect.rank end)
		local steel = count_deck_cards(state, function(card)
			return card.rank == effect.rank and card.enhancement == "m_steel"
		end)
		local held_retrigger = false
		for _, key in ipairs(state.jokers or {}) do
			local owned = state.joker_effects and state.joker_effects[key]
			if owned and owned.kind == "held_retrigger" then held_retrigger = true; break end
		end
		value = 8 + math.min(25, matching * 2.2 + steel * 3) + (held_retrigger and 8 or 0)
		local consumes_rank = plan.primary_hand == "Pair" or plan.primary_hand == "Two Pair"
			or plan.primary_hand == "Three of a Kind" or plan.primary_hand == "Full House"
			or plan.primary_hand == "Four of a Kind"
		if consumes_rank then value = value - 4 end
		if matching <= 4 then catchup_factor = 0 end
	elseif effect.kind == "scoring_suits_xmult" then
		local support = flower_pot_support(state, plan)
		value = 7 + support * 30
		if support < 0.25 then catchup_factor = 0 end
	elseif effect.kind == "chance_suit_xmult" then
		local count = count_deck_cards(state, function(card)
			return card.suit == effect.suit or card.enhancement == "m_wild"
		end)
		value = 12 + math.min(28, count * 1.4)
	elseif effect.kind == "stone_count_chips" then
		local count = count_deck_cards(state, function(card) return card.enhancement == "m_stone" end)
		value = 8 + count * 4
	elseif effect.kind == "missing_deck_mult" then
		local missing = math.max(0, (state.starting_deck_size or 52) - #(state.deck or {}))
		value = 8 + missing * 2.5
	elseif effect.kind == "empty_slot_xmult" then
		local owned = false
		for _, key in ipairs(state.jokers or {}) do
			if key == joker.key then owned = true; break end
		end
		-- A Stencil already in the build does not count itself as occupied. A
		-- shop offer does consume a slot when installed, so its projected factor
		-- remains the number of slots currently open.
		local effective_slots = math.max(1,
			(state.joker_limit or 5) - #(state.jokers or {}) + (owned and 1 or 0))
		value = effective_slots <= 1 and 10 or 14 + effective_slots * 5
	elseif effect.kind == "enhanced_threshold_xmult" then
		local enhanced = count_deck_cards(state, function(card) return card.enhancement ~= nil end)
		value = enhanced >= (effect.count or 16) and value + 15 or 8 + enhanced * 0.7
		if enhanced < (effect.count or 16) then catchup_factor = 0 end
	elseif effect.kind == "non_pvp_xmult" then
		-- Pacifist can rescue a run that is actually failing normal Blinds, but in
		-- Attrition it otherwise consumes a slot while doing nothing in Nemesis.
		-- In particular, never replace a live scoring Joker with it in the final
		-- shop before PvP: the survival help cannot apply until the next Ante.
		local recent = state.round_history and state.round_history[#state.round_history]
		local survival_emergency = recent and recent.target
			and (recent.cleared == false or (recent.score or 0) < recent.target * 1.05)
		if state.next_round_is_pvp == true then
			value = math.min(value, 8)
			catchup_factor = 0
		else
			value = value + (survival_emergency and 5 or -15)
		end
	elseif effect.kind == "decaying_hand_size" then
		value = value + math.max(0, (state.joker_state and state.joker_state[joker.key]) or effect.initial or 0)
	elseif effect.kind == "deck_rank_money" then
		local count = count_deck_cards(state, function(card) return card.rank == effect.rank end)
		value = 12 + count * 2.5
	elseif effect.kind == "round_money" then
		local payout = effect.amount or (effect.per_unused_discard or 0) * (state.discards_per_round or 0)
		if effect.requires_no_discard then
			local recent = state.round_history and state.round_history[#state.round_history]
			value = recent and recent.discards_used == 0 and 14 + payout * 1.5 or 8
		else
			value = 14 + payout * 1.5
		end
	elseif effect.kind == "discard_face_money" then
		local every_card_is_face = false
		for _, key in ipairs(state.jokers or {}) do
			local owned = state.joker_effects and state.joker_effects[key]
			if owned and owned.kind == "all_faces" then every_card_is_face = true; break end
		end
		local faces = every_card_is_face and #(state.deck or {})
			or count_deck_cards(state, function(card) return card.rank >= 11 and card.rank <= 13 end)
		value = 6 + math.min(16, faces * 0.6)
	elseif effect.kind == "scoring_face_money" then
		local every_card_is_face = false
		for _, key in ipairs(state.jokers or {}) do
			local owned = state.joker_effects and state.joker_effects[key]
			if owned and owned.kind == "all_faces" then every_card_is_face = true; break end
		end
		local faces = every_card_is_face and #(state.deck or {})
			or count_deck_cards(state, function(card) return card.rank >= 11 and card.rank <= 13 end)
		local expected_per_face = (effect.amount or 2) / math.max(1, effect.odds or 2)
		value = 10 + math.min(18, faces * expected_per_face * 0.8)
	elseif effect.kind == "round_stone_card" then
		local stone_synergy = 0
		for _, key in ipairs(state.jokers or {}) do
			local owned = state.joker_effects and state.joker_effects[key]
			if owned and (owned.kind == "stone_count_chips" or owned.kind == "deck_add_scaling_xmult") then
				stone_synergy = stone_synergy + 7
			end
		end
		value = 17 + stone_synergy - math.max(0, #(state.deck or {}) - (state.starting_deck_size or 52)) * 0.5
	elseif effect.kind == "free_planets" then
		local remaining_antes = math.max(1, 6 - (tonumber(state.ante) or 1))
		value = 18 + math.min(12, remaining_antes * 2)
	elseif effect.kind == "all_faces" then
		local synergies = 0
		for _, key in ipairs(state.jokers or {}) do
			local owned = state.joker_effects and state.joker_effects[key]
			if owned and (owned.kind == "face_chips" or owned.kind == "face_mult"
				or owned.kind == "first_face_xmult" or owned.kind == "discard_face_money") then
				synergies = synergies + 1
			end
		end
		value = 8 + synergies * 9
	elseif effect.kind == "all_played_score" then
		value = 16
	elseif effect.kind == "played_hand_money" then
		local target = state.joker_state and state.joker_state[joker.key]
		local feasibility = type(target) == "string" and Strategy.hand_feasibility(state, target, plan) or 0.35
		value = 15 + feasibility * 14
	elseif effect.kind == "round_resources" then
		local hands = effect.hands or 0
		local discards = effect.discards or 0
		local lost_discards = effect.reset_discards and (state.discards_per_round or 3) or 0
		local easy_plan = plan.primary_hand == "High Card" or plan.primary_hand == "Pair"
		local discard_value = easy_plan and 0.75 or 1.5
		-- Hand size affects every draw and every hand. Merry Andy's -1 hand size
		-- was previously charged only two utility points, making three extra
		-- discards look like a universal upgrade even in Pair/High Card builds.
		-- Losing a scoring hand is much more expensive than gaining one extra
		-- draw: weak builds cannot recover that missing quarter of their attempts.
		local hand_value = hands < 0 and 18 or 4
		value = 18 + hands * hand_value + discards * discard_value - lost_discards * 1.5
			+ (effect.hand_size or 0) * 6
	elseif effect.kind == "copy_joker" then
		value = #(state.jokers or {}) == 0 and 8 or 24
		for _, key in ipairs(state.jokers or {}) do
			local owned = state.joker_effects and state.joker_effects[key]
			if owned and owned.kind ~= "copy_joker" then
				if pvp_xmult_kinds[owned.kind] then value = math.max(value, 42)
				elseif pvp_score_kinds[owned.kind] then value = math.max(value, 32) end
			end
		end
	end

	-- Once Tarot work has committed the deck to a rank or suit, conditional
	-- Jokers should reinforce that target. Otherwise a high catalog value can
	-- replace a coherent scorer with an effect aimed at the untouched quarter of
	-- the deck (for example Scholar in a King-fixed build).
	if state.deck_fix_rank and rank_target_kinds[effect.kind] then
		local matches = effect.rank == state.deck_fix_rank
		for _, rank in ipairs(effect.ranks or {}) do
			if rank == state.deck_fix_rank then matches = true; break end
		end
		if not matches then
			local target_count = count_deck_cards(state, function(card) return card.rank == state.deck_fix_rank end)
			local offered_count = count_deck_cards(state, function(card)
				if effect.rank then return card.rank == effect.rank end
				for _, rank in ipairs(effect.ranks or {}) do if card.rank == rank then return true end end
				return false
			end)
			value = value - 16 - math.min(10, math.max(0, target_count - offered_count) * 2)
			catchup_factor = 0
		end
	end
	if state.deck_fix_suit and suit_target_kinds[effect.kind] and effect.suit
		and effect.suit ~= state.deck_fix_suit then
		local target_count = count_deck_cards(state, function(card) return card.suit == state.deck_fix_suit end)
		local offered_count = count_deck_cards(state, function(card) return card.suit == effect.suit end)
		value = value - 16 - math.min(10, math.max(0, target_count - offered_count) * 2)
		catchup_factor = 0
	end

	-- Hand-size losses are much more damaging to composite-hand plans. They are
	-- worse again beside Green Joker, where replacing bad cards also sacrifices
	-- permanent Mult.
	if effect.kind ~= "round_resources" and (effect.hand_size or 0) < 0 then
		local easy_plan = plan.primary_hand == "High Card" or plan.primary_hand == "Pair"
		value = value + effect.hand_size * (easy_plan and 4 or 8)
		for _, key in ipairs(state.jokers or {}) do
			local owned = state.joker_effects and state.joker_effects[key]
			if owned and owned.kind == "green_scaling_mult" then value = value - 6; break end
		end
	end

	-- A PvP loss is evidence that merely surviving the ordinary Blinds is no
	-- longer enough. Let the measured score deficit break close shop ties toward
	-- multiplicative or immediate scoring upgrades; the bonus naturally clears
	-- after the bot catches up at the next PvP Blind.
	local deficit = score_deficit(state)
	if deficit > 0 then
		if pvp_xmult_kinds[effect.kind] then
			value = value + catchup_factor * (4 + deficit * 12)
		elseif pvp_score_kinds[effect.kind] then
			value = value + catchup_factor * (2 + deficit * 6)
		end
		if deficit >= 0.35 and (tonumber(state.ante) or 1) >= 4
			and pvp_score_kinds[effect.kind] and not pvp_xmult_kinds[effect.kind] then
			value = value - 4 * deficit
		end
	end
	local ante = tonumber(state.ante) or 1
	if catchup_factor > 0 and ante >= 3 and pvp_xmult_kinds[effect.kind] then
		local has_xmult = false
		for _, key in ipairs(state.jokers or {}) do
			local owned = state.joker_effects and state.joker_effects[key]
			if owned and pvp_xmult_kinds[owned.kind] then has_xmult = true; break end
		end
		if not has_xmult then value = value + (ante >= 4 and 20 or 8) end
	end
	if effect.kind == "deck_rank_money" or effect.kind == "played_hand_money"
		or effect.kind == "joker_income" or effect.kind == "discard_money"
		or effect.kind == "round_money" or effect.kind == "scoring_face_money"
		or effect.kind == "discard_rank_money" or effect.kind == "scoring_enhancement_money"
		or effect.kind == "held_face_money" or effect.kind == "extra_interest"
		or effect.kind == "single_discard_destroy" then
		value = base_value + (value - base_value) * weight(state, "economy_value")
	end
	local final = base_value * weight(state, "joker_value")
		+ (value - base_value) * weight(state, "joker_synergy")
	if effect.kind == "deck_rank_money" or effect.kind == "played_hand_money"
		or effect.kind == "joker_income" or effect.kind == "discard_money"
		or effect.kind == "round_money" or effect.kind == "scoring_face_money"
		or effect.kind == "discard_rank_money" or effect.kind == "scoring_enhancement_money"
		or effect.kind == "held_face_money" or effect.kind == "extra_interest"
		or effect.kind == "single_discard_destroy" then
		local cash = tonumber(state.money) or 0
		local ante = tonumber(state.ante) or 1
		if cash >= 25 and ante >= 4 then
			final = final * (state.next_round_is_pvp == true and 0.25 or 0.4)
		end
	end
	return final
end

function Strategy.planet_utility(state, hand, plan)
	plan = plan or Strategy.analyze(state)
	if plan.exploring then return 8 + ((state.levels and state.levels[hand]) or 1) end
	local feasibility = Strategy.hand_feasibility(state, hand, plan)
	local base = 3 + ((state.levels and state.levels[hand]) or 1)
	local value = base + feasibility * 14
	if hand == plan.primary_hand then value = value + 26 * feasibility
	elseif hand == plan.secondary_hand then value = value + 14 * feasibility
	elseif (plan.hand_scores[hand] or 0) >= (plan.hand_scores[plan.primary_hand] or 0) * 0.7 then
		value = value + 4 * feasibility
	end
	for _, key in ipairs(state.jokers or {}) do
		local effect = state.joker_effects and state.joker_effects[key]
		if effect and effect.kind == "planet_scaling_xmult" then
			-- X0.1 of permanent global scaling is worth buying even when the Planet
			-- itself targets a secondary hand.
			value = value + 14 * ((effect.amount or 0.1) / 0.1)
		end
	end
	return base + (value - base) * weight(state, "plan_alignment")
end

local function deck_fix_target(state)
	local rank_scores, suit_scores = {}, { Hearts = 0, Spades = 0, Clubs = 0, Diamonds = 0 }
	local rank_counts, suit_counts = {}, {}
	local rank_synergy, suit_synergy, suit_diversity = false, false, false
	for rank = 2, 14 do rank_scores[rank] = 0 end
	for _, card in ipairs(state.deck or {}) do
		rank_counts[card.rank] = (rank_counts[card.rank] or 0) + 1
		suit_counts[card.suit] = (suit_counts[card.suit] or 0) + 1
	end
	for _, key in ipairs(state.jokers or {}) do
		local effect = state.joker_effects and state.joker_effects[key]
		if effect then
			if effect.kind == "scoring_suits_xmult" then suit_diversity = true end
			if effect.rank then
				rank_synergy = true
				rank_scores[effect.rank] = (rank_scores[effect.rank] or 0) + 14
			end
			local rank_weights = {
				rank_mult = 12, rank_chips = 12, rank_chips_mult = 14,
				rank_scaling_chips = 14, rank_retrigger = 16,
			}
			for _, rank in ipairs(effect.ranks or {}) do
				rank_synergy = true
				rank_scores[rank] = (rank_scores[rank] or 0) + (rank_weights[effect.kind] or 12)
			end
			if effect.suit then
				suit_synergy = true
				local weights = { suit_chips = 14, suit_card_mult = 13, held_suit_xmult = 16 }
				suit_scores[effect.suit] = (suit_scores[effect.suit] or 0) + (weights[effect.kind] or 12)
			end
		end
	end
	-- Without a defining engine, concentration is valuable. Once a Joker names
	-- a rank or suit, the existing deck becomes only a tiny tie-breaker so prior
	-- Tarot choices cannot lock the bot into the wrong direction forever.
	for rank = 2, 14 do
		rank_scores[rank] = (rank_scores[rank] or 0) + (rank_counts[rank] or 0) * (rank_synergy and 0.02 or 1)
	end
	for _, suit in ipairs({ "Hearts", "Spades", "Clubs", "Diamonds" }) do
		suit_scores[suit] = (suit_scores[suit] or 0) + (suit_counts[suit] or 0) * (suit_synergy and 0.02 or 1)
	end
	-- King of Hearts remains a sensible neutral destination, but only while the
	-- run has no explicit rank/suit engine to build around.
	if not rank_synergy then rank_scores[13] = (rank_scores[13] or 0) + 2.5 end
	if not suit_synergy then suit_scores.Hearts = (suit_scores.Hearts or 0) + 2.5 end
	local best_rank, best_rank_score = 13, -1
	for rank = 2, 14 do
		if (rank_scores[rank] or 0) > best_rank_score then best_rank, best_rank_score = rank, rank_scores[rank] end
	end
	local best_suit, best_suit_score = "Hearts", -1
	for _, suit in ipairs({ "Hearts", "Spades", "Clubs", "Diamonds" }) do
		if (suit_scores[suit] or 0) > best_suit_score then best_suit, best_suit_score = suit, suit_scores[suit] end
	end
	-- Flower Pot needs all four suits among scoring cards. While it is owned,
	-- suppress the normal single-suit target so Tarot work does not dismantle
	-- the condition the Joker was bought to exploit.
	local target_suit = state.deck_fix_suit or best_suit
	if suit_diversity then target_suit = nil end
	return state.deck_fix_rank or best_rank, target_suit
end

Strategy.deck_fix_target = deck_fix_target

function Strategy.deck_fix_pressure(state)
	local deck = state.deck or {}
	if #deck == 0 then return 0 end
	local rank, suit = deck_fix_target(state)
	local base_cards, aligned = 0, 0
	for _, card in ipairs(deck) do
		if not card.enhancement and not card.edition and not card.seal then base_cards = base_cards + 1 end
		if card.rank == rank or card.suit == suit then aligned = aligned + 1 end
	end
	local base_ratio = base_cards / #deck
	local alignment_gap = 1 - aligned / #deck
	local ante = tonumber(state.ante) or 1
	local late = math.min(6, math.max(0, ante - 1) * 1.5)
	local maturity = math.min(1, math.max(0, ante - 1) * 0.5)
	return math.max(0, math.min(20, base_ratio * 10 + alignment_gap * 8 + late - 4)) * maturity
end

local function count_cards(state, predicate)
	local count = 0
	for _, card in ipairs(state.deck or {}) do if predicate(card) then count = count + 1 end end
	return count
end

function Strategy.deck_tool_utility(state, tool, plan)
	plan = plan or Strategy.analyze(state)
	local value = tool.utility or 0
	local base = value
	local pressure = Strategy.deck_fix_pressure(state)
	local structural = tool.effect == "remove" or tool.effect == "immolate"
		or tool.effect == "rank" or tool.effect == "suit"
		or tool.effect == "convert" or tool.effect == "duplicate"
	if plan.exploring then return value + (structural and pressure or 0) end
	if tool.effect == "remove" or tool.effect == "immolate" then
		value = value + (state.deck and #state.deck > 45 and 9 or 3) + pressure
	elseif tool.effect == "suit" then
		-- Suit conversion is powerful when it advances a Flush, but it does
		-- essentially nothing for a settled rank/High Card engine. Its catalog
		-- utility describes the best case and must not make Moon/Sun/Star/World
		-- look like generic scoring upgrades in an unrelated build.
		local _, preferred = deck_fix_target(state)
		local convertible = count_cards(state, function(card) return card.suit ~= (tool.suit or preferred) end)
		if convertible == 0 then
			value = math.min(value, 8)
		elseif plan.primary_hand == "Flush" or tool.suit == preferred then
			value = value + (plan.primary_hand == "Flush" and 14 or 6) + pressure
		else
			value = math.min(value, 8)
		end
	elseif tool.effect == "rank" or tool.effect == "convert" or tool.effect == "duplicate" then
		value = value + ((plan.primary_hand == "Two Pair" or plan.primary_hand == "Three of a Kind"
			or plan.primary_hand == "Full House" or plan.primary_hand == "Four of a Kind") and 10 or 3)
			+ pressure
		if tool.effect == "rank" then
			local preferred_rank = deck_fix_target(state)
			local useful = count_cards(state, function(card)
				return (card.rank == 14 and 2 or card.rank + 1) == preferred_rank
			end)
			if useful == 0 then value = math.min(value, 8) end
		end
	elseif tool.effect == "enhance" or tool.effect == "edition" or tool.effect == "seal" then
		-- Persistent card quality compounds with later conversions and copies.
		-- Once all cards in the chosen rank/suit core already carry this layer,
		-- decline the tool instead of endlessly decorating unrelated Aces.
		local enhanced = plan.shape and plan.shape.enhanced or 0
		local preferred_rank, preferred_suit = deck_fix_target(state)
		local useful = count_cards(state, function(card)
			if card.rank ~= preferred_rank and card.suit ~= preferred_suit then return false end
			if tool.effect == "enhance" then return not card.enhancement end
			if tool.effect == "edition" then return not card.edition end
			return not card.seal
		end)
		if useful == 0 then
			value = math.min(value, 8)
		else
			value = value + math.max(3, 8 - math.floor(enhanced / 4)) + math.min(5, useful)
				+ pressure * 0.15
		end
		-- Gold Cards improve later payouts but contribute nothing to the Blind
		-- currently threatening the run. After a failed normal Blind, do not spend
		-- the emergency reserve on Devil while an immediate scoring purchase may
		-- still be available. Other enhancements retain their value because they
		-- can directly score or affect cards held in hand.
		local recent = state.round_history and state.round_history[#state.round_history]
		if tool.effect == "enhance" and tool.enhancement == "m_gold"
			and recent and recent.target and recent.cleared == false then
			value = math.min(value, 8)
		end
	elseif tool.effect == "add" then
		value = value - math.max(0, #state.deck - state.starting_deck_size) * 3
	elseif tool.effect == "money" then
		value = value + ((state.money or 0) < 20 and 8 or -5)
	end
	return base + (value - base) * weight(state, "deck_manipulation")
end

function Strategy.reserve(state, plan)
	if (state.ante or 1) <= 1 then return 0 end
	-- A severe PvP loss is direct evidence that the current build is below the
	-- match's scoring pace. Preserve only the first interest tier after a modest
	-- loss, and spend through the reserve after losing at least half the target.
	local deficit = pvp_deficit(state)
	if deficit >= 0.5 then return 0 end
	local recent = state.round_history and state.round_history[#state.round_history]
	-- A genuine loss justifies emergency spending. Merely clearing by a narrow
	-- margin does not: repeatedly dropping to $0 prevents the interest engine
	-- from ever recovering and makes the next Ante weaker still.
	if recent and recent.target and (recent.cleared == false or (recent.score or 0) < recent.target) then return 0 end
	local money = math.max(0, state.money or 0)
	local interest_band = math.floor(math.max(0, money - 5) / 5) * 5
	local interest_cash_cap = math.max(5, (tonumber(state.interest_cap) or 5) * 5)
	local reserve = math.min(money, math.min(interest_cash_cap, math.max(5, interest_band)))
	if deficit > 0 then reserve = math.min(reserve, 5) end
	return reserve * weight(state, "interest_preservation")
end

return Strategy
