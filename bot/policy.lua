local Policy = {}

Policy.profiles = {
	easy = {
		name = "Easy",
		mistake_rate = 0.45,
		play_pool = 0.08,
		discard_strength = 3,
		shop_mistake_rate = 0.5,
		rollouts = 1,
		discard_candidates = 3,
		skip_chance = 0.04,
	},
	normal = {
		name = "Normal",
		mistake_rate = 0.18,
		play_pool = 0.03,
		discard_strength = 4,
		shop_mistake_rate = 0.2,
		rollouts = 2,
		discard_candidates = 4,
		skip_chance = 0.06,
	},
	hard = {
		name = "Hard",
		mistake_rate = 0.06,
		play_pool = 0.01,
		discard_strength = 4,
		shop_mistake_rate = 0.06,
		rollouts = 3,
		discard_candidates = 5,
		skip_chance = 0.08,
	},
	expert = {
		name = "Expert",
		mistake_rate = 0,
		play_pool = 0,
		discard_strength = 4,
		shop_mistake_rate = 0,
		rollouts = 4,
		discard_candidates = 6,
		skip_chance = 0.10,
	},
}

local combination_cache = {}

local function weight(args, key)
	return tonumber(args and args.weights and args.weights[key]) or 1
end

local skip_tag_value = {
	tag_negative = 2.5, tag_polychrome = 2.2, tag_investment = 2.1,
	tag_rare = 1.9, tag_orbital = 1.8, tag_coupon = 1.7,
	tag_holo = 1.6, tag_foil = 1.45, tag_top_up = 1.4,
	tag_uncommon = 1.35, tag_voucher = 1.3, tag_economy = 1.25,
	tag_buffoon = 1.2, tag_meteor = 1.1, tag_charm = 1.0,
	tag_standard = 0.9, tag_handy = 0.8, tag_garbage = 0.75,
	tag_juggle = 0.7, tag_d_six = 0.65, tag_boss = 0.25,
}

local function tag_contains(tag, needle)
	return type(tag) == "string" and tag:lower():find(needle, 1, true) ~= nil
end

local function joker_tag(tag)
	return tag_contains(tag, "uncommon") or tag_contains(tag, "rare")
		or tag_contains(tag, "negative") or tag_contains(tag, "foil")
		or tag_contains(tag, "holo") or tag_contains(tag, "poly")
		or tag_contains(tag, "top_up") or tag_contains(tag, "buffoon")
end

local function combinations(count, maximum_size)
	local cache_key = tostring(count) .. ":" .. tostring(maximum_size or 5)
	if combination_cache[cache_key] then return combination_cache[cache_key] end
	local result, current = {}, {}
	local function visit(start, remaining)
		if remaining == 0 then
			local item = {}
			for i, value in ipairs(current) do item[i] = value end
			result[#result + 1] = item
			return
		end
		for index = start, count - remaining + 1 do
			current[#current + 1] = index
			visit(index + 1, remaining - 1)
			current[#current] = nil
		end
	end
	for size = 1, math.min(maximum_size or 5, count) do visit(1, size) end
	combination_cache[cache_key] = result
	return result
end

Policy.combinations = combinations

local function cards_for_indices(hand, indices)
	local cards = {}
	for _, index in ipairs(indices) do cards[#cards + 1] = hand[index] end
	return cards
end

local function contains_hand(name, requested)
	if name == requested then return true end
	if requested == "Straight" then return name == "Straight Flush" end
	if requested == "Two Pair" then return name == "Full House" end
	return false
end

local function scaling_value(result, strategy, hands_left, played_count, weights)
	if not strategy then return 0 end
	local horizon = math.max(1, math.min(3, hands_left or 1))
	local value = 0
	if strategy.runner_growth and contains_hand(result.name, "Straight") then
		value = value + strategy.runner_growth * result.mult * horizon
	end
	if strategy.four_card_growth and played_count == 4 then
		-- Square Joker grows from the number of submitted cards, not the scoring
		-- poker hand. Without this future value a fifth, non-scoring kicker always
		-- won on its few immediate Chips and the bot almost never scaled Square.
		value = value + strategy.four_card_growth * result.mult * horizon
	end
	if strategy.bus_value or strategy.bus_growth then
		local scoring_face = false
		for _, card in ipairs(result.scoring_cards or {}) do
			if card.rank >= 11 and card.rank <= 13 then scoring_face = true; break end
		end
		if scoring_face then
			-- Resetting Ride the Bus destroys accumulated Mult for every future
			-- hand. Allow it only when the immediate score genuinely compensates.
			value = value - (strategy.bus_value or 0) * result.chips * horizon
		else
			value = value + (strategy.bus_growth or 0) * result.chips * horizon
		end
	end
	for hand, amount in pairs(strategy.hand_growth or {}) do
		if contains_hand(result.name, hand) then value = value + amount * result.chips * horizon end
	end
	for rank, amount in pairs(strategy.rank_growth or {}) do
		local count = 0
		for _, card in ipairs(result.scoring_cards or {}) do if card.rank == rank then count = count + 1 end end
		value = value + count * amount * result.mult * horizon
	end
	if strategy.hand_money and strategy.hand_money[result.name] then
		-- Dollars are future shop power, not current chips. Give the requested
		-- hand a meaningful tie-break without sacrificing an imminent clear.
		value = value + strategy.hand_money[result.name] * 35
	end
	if strategy.first_six_spectral and played_count == 1
		and result.scoring_cards and result.scoring_cards[1]
		and result.scoring_cards[1].rank == 6 then
		value = value + 500
	end
	return value * weight({ weights = weights }, "future_value")
end

local function choose_ranked(candidates, profile, rng, mistake_field, pool_field)
	if #candidates == 0 then return nil end
	table.sort(candidates, function(a, b)
		if a.utility == b.utility then return a.key < b.key end
		return a.utility > b.utility
	end)
	local mistake_rate = profile[mistake_field] or 0
	if rng:next() >= mistake_rate then return candidates[1] end
	local fraction = math.max(profile[pool_field] or 0, 1 / #candidates)
	local upper = math.max(2, math.min(#candidates, math.ceil(#candidates * fraction)))
	return candidates[rng:integer(2, upper)]
end

-- Expert temperature only samples near-equal actions. Utilities use different
-- scales for hands and shops, so normalize the window and exponent by the best
-- candidate instead of treating raw Chips as logits.
local function choose_temperature(candidates, temperature, rng)
	temperature = math.max(0, tonumber(temperature) or 0)
	if temperature <= 0 or #candidates < 2 then return candidates[1] end
	table.sort(candidates, function(a, b)
		if a.utility == b.utility then return tostring(a.key) < tostring(b.key) end
		return a.utility > b.utility
	end)
	local best = tonumber(candidates[1].utility) or 0
	local magnitude = math.max(1, math.abs(best))
	local window = math.max(1, magnitude * math.min(0.08, temperature * 0.10))
	local scale = math.max(0.001, magnitude * 0.05 * temperature)
	local eligible, total = {}, 0
	for _, candidate in ipairs(candidates) do
		local utility = tonumber(candidate.utility) or 0
		if best - utility <= window then
			local weighted = { candidate = candidate, weight = math.exp((utility - best) / scale) }
			eligible[#eligible + 1] = weighted
			total = total + weighted.weight
		else
			break
		end
	end
	if #eligible < 2 then return candidates[1] end
	local roll = rng:next() * total
	for _, weighted in ipairs(eligible) do
		roll = roll - weighted.weight
		if roll <= 0 then return weighted.candidate end
	end
	return eligible[#eligible].candidate
end

local function diagnostic_candidate(candidate)
	return {
		type = candidate.type,
		key = candidate.key,
		utility = candidate.utility,
		hand = candidate.result and candidate.result.name or nil,
		score = candidate.result and candidate.result.score or nil,
		count = candidate.count,
	}
end

-- Diagnostics are attached to the returned action only; they never participate
-- in selection. Keep the best three plus the chosen action when difficulty
-- variance deliberately selected something outside that set.
local function attach_diagnostics(chosen, candidates)
	if not chosen then return nil end
	local ranked = {}
	for _, candidate in ipairs(candidates or {}) do ranked[#ranked + 1] = candidate end
	table.sort(ranked, function(a, b)
		if a.utility == b.utility then return tostring(a.key) < tostring(b.key) end
		return a.utility > b.utility
	end)
	local top, chosen_seen = {}, false
	for index = 1, math.min(3, #ranked) do
		top[#top + 1] = diagnostic_candidate(ranked[index])
		if ranked[index] == chosen then chosen_seen = true end
	end
	if not chosen_seen then top[#top + 1] = diagnostic_candidate(chosen) end
	local best = ranked[1] and tonumber(ranked[1].utility) or tonumber(chosen.utility) or 0
	chosen.candidates = top
	chosen.chosen_utility = tonumber(chosen.utility) or 0
	chosen.best_utility = best
	chosen.regret = math.max(0, best - chosen.chosen_utility)
	return chosen
end

local function keep_quality(cards, draw_count, plan, weights)
	local rank_counts, suit_counts = {}, {}
	local distinct = {}
	local chip_value = 0
	for _, card in ipairs(cards) do
		rank_counts[card.rank] = (rank_counts[card.rank] or 0) + 1
		suit_counts[card.suit] = (suit_counts[card.suit] or 0) + 1
		distinct[card.rank] = true
		chip_value = chip_value + card.chips
	end
	local value = chip_value * 0.03
	for _, count in pairs(rank_counts) do
		if count >= 2 then value = value + count * count * 8 end
	end
	local best_suit = 0
	for _, count in pairs(suit_counts) do best_suit = math.max(best_suit, count) end
	value = value + best_suit * best_suit * 2.4
	local best_window = 0
	for low = 2, 10 do
		local present = 0
		for rank = low, low + 4 do if distinct[rank] then present = present + 1 end end
		if low == 2 and distinct[14] then present = present + 1 end
		best_window = math.max(best_window, math.min(5, present))
	end
	-- Replacing several irrelevant cards is valuable. The old heuristic summed
	-- every kept card's value, so it almost always discarded only one card.
	local straight_weight = plan and plan.primary_hand == "Straight" and 5.5 or 2.8
	local suit_weight = plan and plan.primary_hand == "Flush" and 4.5 or 2.4
	value = value - best_suit * best_suit * 2.4 + best_suit * best_suit * suit_weight
	return (value + best_window * best_window * straight_weight + (draw_count or 0) * 5)
		* weight({ weights = weights }, "discard_potential")
end

local function sample_draw(draw_pile, count, rng)
	local available, drawn = {}, {}
	for index, card in ipairs(draw_pile or {}) do available[index] = card end
	for _ = 1, math.min(count, #available) do
		local index = rng:integer(1, #available)
		drawn[#drawn + 1] = available[index]
		table.remove(available, index)
	end
	return drawn
end

local function best_future_play(hand, args)
	local best = 0
	for _, selected in ipairs(combinations(#hand, 5)) do
		local cards = cards_for_indices(hand, selected)
		local result = args.evaluate(cards, hand)
		best = math.max(best, result.score * weight(args, "immediate_score")
			+ scaling_value(result, args.strategy, args.hands_left, #cards, args.weights))
	end
	return best
end

local function rollout_discards(discards, args, profile, survival_emergency)
	if not args.draw_pile or #args.draw_pile == 0 then return discards end
	table.sort(discards, function(a, b)
		if a.utility == b.utility then return a.key < b.key end
		return a.utility > b.utility
	end)
	while #discards > profile.discard_candidates do table.remove(discards) end
	for candidate_index, candidate in ipairs(discards) do
		local selected = {}
		for token in candidate.key:gmatch("[^,]+") do selected[tonumber(token)] = true end
		local kept = {}
		for index, card in ipairs(args.hand) do if not selected[index] then kept[#kept + 1] = card end end
		local total = 0
		for rollout = 1, profile.rollouts do
			local stream = args.rng:fork("discard:" .. candidate.key .. ":" .. rollout)
			local future = {}
			for _, card in ipairs(kept) do future[#future + 1] = card end
			for _, card in ipairs(sample_draw(args.draw_pile, candidate.count, stream)) do future[#future + 1] = card end
			total = total + best_future_play(future, args)
		end
		local strategy = args.strategy or {}
		local average = total / profile.rollouts
		local loss_fraction = math.min(0.8,
			(strategy.discard_score_loss_fraction or 0) * candidate.count)
		local future_hands = math.max(1, math.min(3, args.hands_left or 1))
		local permanent_cost = ((strategy.preserve_green and not survival_emergency and 80 or 0)
			+ (strategy.discard_card_cost or 0) * candidate.count
			+ average * loss_fraction * future_hands) * weight(args, "card_preservation")
		candidate.utility = average - permanent_cost
	end
	return discards
end

function Policy.choose_turn(args)
	local profile = Policy.profiles[args.difficulty] or Policy.profiles.normal
	local indices = combinations(#args.hand, 5)
	local plays = {}
	for _, selected in ipairs(indices) do
		local cards = cards_for_indices(args.hand, selected)
		local result = args.evaluate(cards, args.hand)
		plays[#plays + 1] = {
			type = "play",
			indices = selected,
			result = result,
			utility = result.score * weight(args, "immediate_score")
				+ scaling_value(result, args.strategy, args.hands_left, #cards, args.weights),
			key = table.concat(selected, ","),
		}
	end
	local best_play = choose_ranked(plays, profile, args.rng, "mistake_rate", "play_pool")
	if not best_play then return nil end

	local target_reached = args.target and args.current_score + best_play.result.score >= args.target
	local score_remaining = args.target and math.max(0, args.target - args.current_score) or nil
	local on_clear_pace = score_remaining and best_play.result.score >= score_remaining / math.max(1, args.hands_left or 1)
	local discard_strength = profile.discard_strength
	local preserve_green = args.strategy and args.strategy.preserve_green
	if preserve_green then discard_strength = math.min(discard_strength, 2) end
	local weak_enough_to_redraw = best_play.result.strength < discard_strength
	local required_pace = score_remaining and score_remaining / math.max(1, args.hands_left or 1)
	local last_hand = (tonumber(args.hands_left) or 1) <= 1
	local survival_floor = (preserve_green or last_hand) and 1 or 0.6
	local survival_emergency = required_pace and best_play.result.score
		< required_pace * survival_floor * weight(args, "survival_pressure")
	if survival_emergency then
		-- A nominally respectable hand can still be disastrous when it scores far
		-- below the per-hand pace needed to survive the Blind. Green Joker normally
		-- protects its permanent Mult, but survival takes priority once repeating
		-- the best available score across the remaining hands cannot clear.
		weak_enough_to_redraw = true
	end
	local should_discard = args.discards_left > 0
		and not target_reached
		and not on_clear_pace
		and weak_enough_to_redraw
	if args.discards_left > 0 and args.rng:next() < profile.mistake_rate * 0.25 then
		should_discard = not should_discard
	end
	local discard_budget = args.strategy and tonumber(args.strategy.discard_per_hand_budget)
	local discard_budget_exhausted = discard_budget
		and (tonumber(args.discards_used_this_hand) or 0) >= discard_budget
	if should_discard and not survival_emergency and discard_budget
		and discard_budget_exhausted then
		should_discard = false
	end
	if should_discard and not args.target then
		-- A PvP Blind has no fixed score target, so the old policy could keep
		-- redrawing as long as each sampled hand looked marginally better. With
		-- Merry Andy this regularly spent all seven discards before hand one and
		-- left the remaining three hands with no draw control. Cap one hand at half
		-- the round's supply so later hands can still react to their draws.
		local starting_discards = math.max(0, tonumber(args.starting_discards) or args.discards_left)
		local per_hand_budget = math.max(1, math.ceil(starting_discards / 2))
		if (tonumber(args.discards_used_this_hand) or 0) >= per_hand_budget then
			should_discard = false
		end
	end

	if should_discard then
		local discards = {}
		for _, selected in ipairs(indices) do
			local lookup, kept = {}, {}
			for _, index in ipairs(selected) do lookup[index] = true end
			for index, card in ipairs(args.hand) do if not lookup[index] then kept[#kept + 1] = card end end
			discards[#discards + 1] = {
				type = "discard",
				indices = selected,
				utility = keep_quality(kept, #selected, args.strategy and args.strategy.plan, args.weights),
				count = #selected,
				key = table.concat(selected, ","),
			}
		end
		discards = rollout_discards(discards, args, profile, survival_emergency)
		local discard = choose_ranked(discards, profile, args.rng, "mistake_rate", "play_pool")
		-- A weak poker category is not, by itself, a reason to discard. Once a
		-- rollout exists, compare the improved draw against playing now, including
		-- permanent losses such as Ramen XMult or Green Joker Mult.
		local considered = {}
		for _, candidate in ipairs(plays) do considered[#considered + 1] = candidate end
		for _, candidate in ipairs(discards) do considered[#considered + 1] = candidate end
		if discard_budget_exhausted and discard
			and discard.utility <= best_play.utility * 1.25 then
			return attach_diagnostics(best_play, considered)
		end
		if args.draw_pile and discard
			and discard.utility * weight(args, "risk_tolerance") <= best_play.utility then
			return attach_diagnostics(best_play, considered)
		end
		if args.difficulty == "expert" and not args.target then
			discard = choose_temperature(discards, args.decision_temperature, args.rng)
		end
		return attach_diagnostics(discard, considered)
	end

	local chosen = best_play
	if args.difficulty == "expert" and not args.target then
		chosen = choose_temperature(plays, args.decision_temperature, args.rng)
	end
	return attach_diagnostics(chosen, plays)
end

function Policy.choose_shop(candidates, difficulty, rng, decision_temperature)
	local profile = Policy.profiles[difficulty] or Policy.profiles.normal
	if difficulty == "expert" and (tonumber(decision_temperature) or 0) > 0 then
		return choose_temperature(candidates, decision_temperature, rng)
	end
	return choose_ranked(candidates, profile, rng, "shop_mistake_rate", "play_pool")
end

function Policy.should_skip_blind(args)
	args = args or {}
	local profile = Policy.profiles[args.difficulty] or Policy.profiles.normal
	local mode = args.mode or "reactive"
	if mode == "disabled" or not args.rng then return false end
	if mode == "unlimited_unforgivable" then return true end

	local ante = tonumber(args.ante) or 1
	local money = tonumber(args.money) or 0
	local joker_count = tonumber(args.joker_count) or 0
	-- Every mode except Unlimited Unforgivable respects the standard safety
	-- floor. Unforgivable ignores whether the decision is good, not whether the
	-- run has reached the configured point where skipping is permitted.
	if ante <= 1 or joker_count < 2 or money < 8 then return false end
	if mode == "unforgivable" then return true end

	local negative_or_double = tag_contains(args.tag, "negative") or tag_contains(args.tag, "double")
	if mode == "negative_only" then return negative_or_double end
	if args.reward_supported == false and not args.previous_pvp_dominant then
		-- A strategic skip must either grant a reward the headless run can really
		-- apply or intentionally trade that reward for established PvP pressure.
		-- Otherwise tags such as Meteor silently cost a payout and an entire shop.
		return false
	end
	if args.strict_order_content and mode == "reactive" and joker_tag(args.tag)
		and not tag_contains(args.tag, "negative") and args.reward_supported ~= true then
		-- Rare/Uncommon/pack-style tags create hidden cards in the bot's own
		-- run. Until a shadow Order generator exists, they are not a rational
		-- reactive reward because manufacturing a substitute would be cheating.
		return false
	end
	local previous_score = tonumber(args.previous_score) or 0
	local next_blind_target = tonumber(args.next_blind_target) or 0
	if mode == "reactive" and previous_score > 0 and next_blind_target > 0
		and previous_score < next_blind_target * 1.2 then
		-- Beating a weak PvP opponent does not prove the build can survive the
		-- next mandatory Blind. Require a variance cushion before losing a round
		-- of scaling, payout, and shop access.
		return false
	end

	-- Reactive mode has concrete reasons that override its small exploratory
	-- chance: emergency cash, a starved Joker engine, or deliberate PvP pressure.
	if tag_contains(args.tag, "investment") and money <= 14 then return true end
	if joker_count <= 2 and joker_tag(args.tag) then return true end
	local joker_slots_full = joker_count >= (tonumber(args.joker_limit) or 5)
	local adds_usable_slot = tag_contains(args.tag, "negative")
	if mode == "reactive" and joker_slots_full and joker_tag(args.tag)
		and not adds_usable_slot and not args.previous_pvp_dominant then
		-- A full build should only give up a Blind for a Joker tag when it is
		-- deliberately applying PvP pressure. The ordinary value roll used to
		-- take Rare Tags blindly even when there was nowhere to put the reward.
		return false
	end
	local chance = profile.skip_chance or 0
	chance = chance * (skip_tag_value[args.tag] or 1)
	if args.blind == "Big" then chance = chance * 1.25 end
	if args.previous_pvp_dominant then chance = math.max(chance * 2, 0.35) end
	if mode == "aggressive" then chance = math.max(0.55, chance * 4) end
	return args.rng:next() < math.min(mode == "aggressive" and 0.9 or 0.5, chance)
end

return Policy
