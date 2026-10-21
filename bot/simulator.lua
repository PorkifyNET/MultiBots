local Simulator = {}
local unpack_values = table.unpack or unpack

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

-- The simulator holds the game's rules and nothing else. Every player
-- decision is asked from the run's policy (dependencies.Policy, kept as
-- state.Policy): decide(state, name, ctx) calls policy[name](state, ctx).
-- A policy that has no function for a decision declines it: the caller passes
-- the decline (the first action, no reroll, no skip, no change). bot/expert.lua
-- describes every decision and its ctx; its Expert is MultiBots' own policy.
-- Hooks that pick an action return a 1-based index into ctx.actions
-- (optionally followed by a meta table whose `log` fields go into the
-- decision's log entry).
local function decide(state, name, ctx, ...)
	local hook = state.Policy[name]
	if hook then return hook(state, ctx) end
	return ...
end

-- Rule deviations a policy may ask for (state.expert_compat, set by the
-- policy): MultiBots' Expert was tuned with them and plays identically only
-- with them.
--   use_created_cards       The Emperor / The High Priestess use the cards they
--                           create at once instead of putting them into the
--                           consumable slots.
--   judgement_without_slot  Judgement can be used with full Joker slots (it
--                           then does nothing).
--   targetless_tools        A Tarot or Spectral that takes targets can be spent
--                           without any (target_step lists a "none" action).
local NO_COMPAT = {}
local function compat(state)
	return state.expert_compat or NO_COMPAT
end

-- Announcements at fixed points of the run (policy.observe(state, event, data)),
-- for a policy that keeps its own memory.
local function notify(state, event, data)
	local observe = state.Policy.observe
	if observe then observe(state, event, data) end
end

local blind_amounts = { 300, 800, 2000, 5000, 11000, 20000, 35000, 50000 }
-- Vanilla get_blind_amount (misc_functions.lua), including
-- the Green (scaling 2) and Purple (scaling 3) Stake tables and Antes past 8.
local scaled_blind_amounts = {
	[2] = { 300, 900, 2600, 8000, 20000, 36000, 60000, 100000 },
	[3] = { 300, 1000, 3200, 9000, 25000, 60000, 110000, 200000 },
}

function Simulator.blind_scaling(stake)
	stake = tonumber(stake) or 1
	return stake >= 6 and 3 or (stake >= 3 and 2 or 1)
end

function Simulator.base_score(ante, scaling)
	local amounts = scaled_blind_amounts[scaling] or blind_amounts
	ante = tonumber(ante) or 1
	if ante < 1 then return 100 end
	if ante <= #amounts then return amounts[ante] end
	local k, a, b, c = 0.75, amounts[#amounts], 1.6, ante - #amounts
	local d = 1 + 0.2 * c
	local amount = math.floor(a * (b + (k * c) ^ d) ^ c)
	return amount - amount % (10 ^ math.floor(math.log(amount) / math.log(10) - 1))
end

local planet_names = {
	"High Card", "Pair", "Two Pair", "Three of a Kind", "Straight",
	"Flush", "Full House", "Four of a Kind", "Straight Flush",
	"Five of a Kind",
}

-- The secret poker hands (hidden until played). Their Planets (Planet X, Ceres,
-- Eris: config.softlock) are in the Planet pool only once that hand has been
-- played this run (common_events.lua get_current_pool: softlock and
-- G.GAME.hands[hand].played > 0), in shops, Celestial Packs and The High
-- Priestess alike.
local secret_hands = { ["Five of a Kind"] = true, ["Flush House"] = true, ["Flush Five"] = true }
local function planet_unlocked(state, planet)
	if not (planet.softlock or secret_hands[planet.hand]) then return true end
	return ((state.hand_usage or {})[planet.hand] or 0) > 0
end
-- Every poker hand, strongest first (game.lua G.handlist).
local hand_list = {
	"Flush Five", "Flush House", "Five of a Kind", "Straight Flush", "Four of a Kind", "Full House",
	"Flush", "Straight", "Three of a Kind", "Two Pair", "Pair", "High Card",
}

local enhancements = { "m_bonus", "m_mult", "m_lucky", "m_glass", "m_steel", "m_gold", "m_wild" }
local standard_enhancements = { "m_bonus", "m_mult", "m_lucky", "m_glass", "m_steel", "m_gold", "m_wild", "m_stone" }
local editions = { "foil", "holo", "polychrome" }
local seals = { "Red", "Blue", "Gold", "Purple" }

local function copy_deck(state)
	return state.Cards.copy_deck(state.deck)
end

local function apply_deck_back(state, deck_name)
	local normalized = tostring(deck_name or ""):lower()
	if normalized == "red deck" or normalized == "b_red" then
		state.discards_per_round = state.discards_per_round + 1
	elseif normalized == "blue deck" or normalized == "b_blue" then
		state.hands_per_round = state.hands_per_round + 1
	elseif normalized == "black deck" or normalized == "b_black" then
		state.hands_per_round = math.max(1, state.hands_per_round - 1)
		state.joker_limit = state.joker_limit + 1
	-- more decks from back.lua / game.lua P_CENTERS configs.
	elseif normalized == "yellow deck" or normalized == "b_yellow" then
		state.money = state.money + 10
	elseif normalized == "green deck" or normalized == "b_green" then
		state.money_per_hand, state.money_per_discard, state.no_interest = 2, 1, true
	elseif normalized == "painted deck" or normalized == "b_painted" then
		state.hand_size_bonus = (state.hand_size_bonus or 0) + 2
		state.joker_limit = math.max(1, state.joker_limit - 1)
	elseif normalized == "nebula deck" or normalized == "b_nebula" then
		state.consumable_limit = math.max(0, state.consumable_limit - 1)
		state.deck_vouchers = { "v_telescope" }
	elseif normalized == "magic deck" or normalized == "b_magic" then
		state.deck_vouchers, state.deck_consumables = { "v_crystal_ball" }, { "c_fool", "c_fool" }
	elseif normalized == "zodiac deck" or normalized == "b_zodiac" then
		state.deck_vouchers = { "v_tarot_merchant", "v_planet_merchant", "v_overstock_norm" }
	elseif normalized == "ghost deck" or normalized == "b_ghost" then
		state.deck_consumables = { "c_hex" }   -- game.lua b_ghost config consumables
	end
	if normalized:find("abandoned", 1, true) or normalized == "b_abandoned" then
		for index = #state.deck, 1, -1 do
			local rank = state.deck[index].rank
			if rank >= 11 and rank <= 13 then table.remove(state.deck, index) end
		end
	elseif normalized:find("checkered", 1, true) or normalized == "b_checkered" then
		for index, card in ipairs(state.deck) do
			if card.suit == "Clubs" then card.suit = "Spades" end
			if card.suit == "Diamonds" then card.suit = "Hearts" end
			state.Cards.refresh(card, ":checkered:" .. index)
		end
	elseif normalized:find("erratic", 1, true) or normalized == "b_erratic" then
		local stream = state.rng:fork("deck_back:erratic")
		for index, card in ipairs(state.deck) do
			card.suit = state.Cards.suits[stream:integer(1, #state.Cards.suits)]
			card.rank = stream:integer(2, 14)
			state.Cards.refresh(card, ":erratic:" .. index)
		end
	end
end

-- the suit a suit Tarot without a fixed suit converts to (vanilla suit
-- Tarots all name one)
local function dominant_suit(deck)
	local counts, best_suit, best_count = {}, "Spades", -1
	for _, card in ipairs(deck) do counts[card.suit] = (counts[card.suit] or 0) + 1 end
	for _, suit in ipairs({ "Spades", "Hearts", "Clubs", "Diamonds" }) do
		if (counts[suit] or 0) > best_count then best_suit, best_count = suit, counts[suit] or 0 end
	end
	return best_suit
end

local function remove_card(deck, target)
	for index, card in ipairs(deck) do
		if card == target then table.remove(deck, index); return end
	end
end

local function adjust_owned_jokers(state, effect_kind, amount)
	for _, key in ipairs(state.jokers or {}) do
		local effect = state.joker_effects and state.joker_effects[key]
		if effect and effect.kind == effect_kind then
			local value = (state.joker_state[key] or effect.initial or 0) + amount * (effect.amount or 1)
			if effect.destroy_at ~= nil then value = math.max(effect.destroy_at, value) end
			state.joker_state[key] = value
		end
	end
end

local function initialize_joker(state, key)
	local effect = state.joker_effects[key]
	state.joker_state[key] = effect and effect.initial or 0
end

-- vanilla Jokers group A: playing cards destroyed and cards sold.
-- Caino gains X1 per destroyed face card (card.lua calculate_joker
-- cards_destroyed / remove_playing_cards; Card:is_face: not debuffed, every
-- card with Pareidolia, a Stone card otherwise not). Glass Joker gains X0.75
-- per Glass Card that counts (`glass`: shattered ones, or the ones The Hanged
-- Man destroys, using_consumeable). Neither is copied by Blueprint.
local function note_cards_destroyed(state, cards, glass)
	local all_faces, faces = false, 0
	for _, key in ipairs(state.jokers or {}) do
		local effect = state.joker_effects[key]
		if effect and effect.kind == "all_faces" then all_faces = true end
	end
	for _, card in ipairs(cards or {}) do
		if not card.debuff and (all_faces
			or (card.enhancement ~= "m_stone" and card.rank >= 11 and card.rank <= 13)) then
			faces = faces + 1
		end
	end
	for _, key in ipairs(state.jokers or {}) do
		local effect = state.joker_effects[key]
		if effect and effect.kind == "face_destroy_xmult" and faces > 0 then
			state.joker_state[key] = math.max(1, state.joker_state[key] or effect.initial or 1)
				+ faces * (effect.amount or 1)
		elseif effect and effect.kind == "glass_shatter_xmult" and (glass or 0) > 0 then
			state.joker_state[key] = math.max(1, state.joker_state[key] or effect.initial or 1)
				+ glass * (effect.amount or 0.75)
		end
	end
end

-- Campfire gains X0.25 for every card sold, Joker or consumable, except
-- itself (G.FUNCS.sell_card: selling_card for the other Jokers; not copied).
local function note_card_sold(state, sold_key)
	for _, key in ipairs(state.jokers or {}) do
		local effect = state.joker_effects[key]
		if key ~= sold_key and effect and effect.kind == "sell_scaling_xmult" then
			state.joker_state[key] = math.max(1, state.joker_state[key] or effect.initial or 1)
				+ (effect.amount or 0.25)
		end
	end
end

-- the game's poll_edition (common_events.lua). Guaranteed
-- (no Negative): foil 50%, holo 35%, polychrome 15%. Otherwise 4% / 2% / 0.6%
-- times rate * mod; with `negative` allowed (shop and pack Jokers) 0.3% * mod
-- Negative first, not scaled by the edition rate.
local function poll_edition(stream, guaranteed, mod, rate, negative)
	local roll = stream:next()
	if guaranteed then
		if negative and roll > 1 - 0.003 * 25 then return "negative" end
		if roll > 0.85 then return "polychrome" end
		if roll > 0.5 then return "holo" end
		return "foil"
	end
	local scale = (rate or 1) * (mod or 1)
	if negative and roll > 1 - 0.003 * (mod or 1) then return "negative" end
	if roll > 1 - 0.006 * scale then return "polychrome" end
	if roll > 1 - 0.02 * scale then return "holo" end
	if roll > 1 - 0.04 * scale then return "foil" end
	return nil
end

-- Card:set_cost extra cost of an edition.
local edition_extra_cost = { foil = 2, holo = 3, polychrome = 5, negative = 5 }

-- a Joker's sell value as Card:set_cost computes it:
-- max(1, floor(cost / 2)) with cost = floor((base + edition extra + 0.5) *
-- (100 - discount) / 100), so editions raise it and Clearance Sale lowers it.
local function joker_sell_value(state, key)
	local base = 2
	for _, joker in ipairs(state.joker_pool or {}) do
		if joker.key == key then base = tonumber(joker.cost) or 2; break end
	end
	local extra = edition_extra_cost[(state.joker_editions or {})[key]] or 0
	local cost = math.max(1, math.floor((base + extra + 0.5) * (100 - (state.shop_discount or 0)) / 100))
	-- Card.sell_cost = max(1, floor(cost / 2)) + ability.extra_value: Gift Card
	-- raises every Joker's extra value (sell_value_bonus, upstream), Egg only its
	-- own (joker_extra_value; card.lua calculate_joker end_of_round).
	return math.max(1, math.floor(cost / 2)) + (state.sell_value_bonus or 0)
		+ ((state.joker_extra_value or {})[key] or 0)
end

local sold_joker_rules   -- group B jokers (defined with their rules below)

-- Diet Cola creates a Double Tag when sold (card.lua Card:sell_card / calculate_joker selling_self).
local function note_joker_sold(state, key, replacing)
	note_card_sold(state, key)   -- Campfire
	local sold_effect = state.joker_effects[key]
	if sold_effect and sold_effect.kind == "double_tag_on_sell" then
		state.double_tags = (state.double_tags or 0) + 1
	end
	sold_joker_rules(state, key, replacing)
end

-- Hook target_step: an external policy can override which cards a Tarot or
-- Spectral targets (ctx in bot/expert.lua).
local function targeted_tool(tool)
	local effect = tool.effect
	if effect == "edition" then return tool.key ~= "c_wheel_of_fortune" end
	return effect == "remove" or effect == "rank" or effect == "suit" or effect == "enhance"
		or effect == "seal" or effect == "convert" or effect == "duplicate"
end

-- How many highlighted cards a targeted tool takes at most (card.lua
-- can_use_consumeable, config max_highlighted). Death takes exactly 2; Aura,
-- Cryptid and the seal Spectrals 1.
local function target_limit(tool)
	local effect = tool.effect
	if effect == "rank" or effect == "remove" or effect == "enhance" then return tool.count or 2 end
	if effect == "suit" then return tool.count or 3 end
	return 1
end

-- Every legal target set among the drawn hand, in a fixed order (by size,
-- then hand position). Death takes an ordered pair (the first card is copied
-- onto the second), Aura a card without an edition.
local function legal_target_sets(tool, hand)
	local actions = {}
	if tool.effect == "convert" then
		for i, source in ipairs(hand) do
			for j, target in ipairs(hand) do
				if i ~= j then
					actions[#actions + 1] = { type = "target", cards = { source, target }, source = source, target = target }
				end
			end
		end
		return actions
	end
	local eligible = {}
	for _, card in ipairs(hand) do
		if tool.effect ~= "edition" or not card.edition then eligible[#eligible + 1] = card end
	end
	local chosen = {}
	local function extend(size, start)
		if #chosen == size then
			actions[#actions + 1] = { type = "target", cards = copy_array(chosen) }
			return
		end
		for index = start, #eligible - (size - #chosen) + 1 do
			chosen[#chosen + 1] = eligible[index]
			extend(size, index + 1)
			chosen[#chosen] = nil
		end
	end
	for size = 1, math.min(target_limit(tool), #eligible) do extend(size, 1) end
	return actions
end

-- `cards` holds exactly the cards of `set` (in any order).
local function same_cards(cards, set)
	if #cards ~= #set then return false end
	local wanted = {}
	for _, card in ipairs(set) do wanted[card] = true end
	for _, card in ipairs(cards) do
		if not wanted[card] then return false end
		wanted[card] = nil
	end
	return true
end

-- the hand-size draw a deck tool picks its targets from
local function tool_hand(state, stream)
	local hand_size = 8 + (state.hand_size_bonus or 0)
	for _, key in ipairs(state.jokers or {}) do
		local effect = state.joker_effects and state.joker_effects[key]
		if effect and effect.hand_size then hand_size = hand_size + effect.hand_size end
		if effect and effect.kind == "decaying_hand_size" then
			hand_size = hand_size + math.max(0, state.joker_state[key] or effect.initial or 0)
		end
	end
	local in_hand = state.Cards.shuffle(state.deck, stream, "tool_hand", false)
	for index = #in_hand, math.max(1, hand_size) + 1, -1 do in_hand[index] = nil end
	return in_hand
end

local function apply_deck_tool(state, tool, stream)
	notify(state, "deck_tool", tool)
	-- Tarots and Spectrals act on cards highlighted in hand
	-- (card.lua Card:use_consumeable, can_use_consumeable), not on any card of the
	-- deck: the targets are chosen among a hand-size draw of the deck.
	local in_hand = tool_hand(state, stream)
	-- Hook target_step. The targets are picked first, then applied with the same
	-- draws from `stream` (one per targeted card at most).
	local targets = {}
	if targeted_tool(tool) then
		local actions = legal_target_sets(tool, in_hand)
		if #actions > 0 then
			if compat(state).targetless_tools then actions[#actions + 1] = { type = "none", cards = {} } end
			local ctx = { tool = tool, effect = tool.effect, hand = in_hand, actions = actions }
			local index, meta = decide(state, "target_step", ctx, 1)
			local action = actions[index]
			if not action then error("target_step returned an invalid action index " .. tostring(index)) end
			targets = action.cards
			-- meta.cards: the same cards in the order they are applied (only the
			-- ids of Strength and suit Tarots depend on it; Death's pair is ordered).
			if meta and meta.cards and tool.effect ~= "convert" then
				if not same_cards(meta.cards, targets) then
					error("target_step returned cards that are not the chosen set's")
				end
				targets = meta.cards
			end
		end
	end
	if tool.effect == "remove" then
		for _, card in ipairs(targets) do remove_card(state.deck, card) end
		local glass = 0   -- Glass Joker counts The Hanged Man's Glass Cards
		for _, card in ipairs(targets) do if card.enhancement == "m_glass" then glass = glass + 1 end end
		note_cards_destroyed(state, targets, glass)
	elseif tool.effect == "immolate" then
		-- Immolate destroys 5 random cards of the hand (pseudoshuffle 'immolate').
		for index = 1, math.min(tool.count or 5, #in_hand - 1) do remove_card(state.deck, in_hand[index]) end
		note_cards_destroyed(state, { unpack_values(in_hand, 1, math.min(tool.count or 5, #in_hand - 1)) }, 0)
		state.money = state.money + 20
	elseif tool.effect == "rank" then
		for index, card in ipairs(targets) do
			card.rank = card.rank == 14 and 2 or card.rank + 1
			state.Cards.refresh(card, ":strength:" .. state.ante .. ":" .. state.round .. ":" .. index)
		end
	elseif tool.effect == "suit" then
		local target = tool.suit or dominant_suit(state.deck)
		for changed, card in ipairs(targets) do
			card.suit = target
			state.Cards.refresh(card, ":suit:" .. state.ante .. ":" .. state.round .. ":" .. changed)
		end
	elseif tool.effect == "enhance" then
		for _, card in ipairs(targets) do
			card.enhancement = tool.enhancement or enhancements[stream:integer(1, #enhancements)]
		end
	elseif tool.effect == "convert" and #targets == 2 then
		local source, target = targets[1], targets[2]
		target.suit = source.suit
		target.rank = source.rank
		target.enhancement = source.enhancement
		target.edition = source.edition
		target.seal = source.seal
		state.Cards.refresh(target, ":death:" .. state.ante .. ":" .. state.round)
	elseif tool.effect == "add" then
		local card = {
			suit = state.Cards.suits[stream:integer(1, #state.Cards.suits)],
			rank = stream:integer(2, 14),
			enhancement = stream:next() < 0.4 and enhancements[stream:integer(1, #enhancements)] or nil,
		}
		state.Cards.refresh(card, ":added:" .. state.ante .. ":" .. state.round .. ":" .. #state.deck)
		state.deck[#state.deck + 1] = card
		state.cards_added = state.cards_added + 1
		adjust_owned_jokers(state, "deck_add_scaling_xmult", 1)
	elseif tool.effect == "duplicate" and targets[1] then
		for copy_index = 1, tool.count or 1 do
			local card = {}
			for key, value in pairs(targets[1]) do card[key] = value end
			state.Cards.refresh(card, ":copy:" .. state.ante .. ":" .. state.round .. ":" .. copy_index .. ":" .. #state.deck)
			state.deck[#state.deck + 1] = card
			state.cards_added = state.cards_added + 1
			adjust_owned_jokers(state, "deck_add_scaling_xmult", 1)
		end
	elseif tool.effect == "edition" and tool.key == "c_wheel_of_fortune" then
		-- The Wheel of Fortune: 1 in 4, a random Joker without an edition.
		local editionless = {}
		for _, key in ipairs(state.jokers or {}) do
			if not state.joker_editions[key] then editionless[#editionless + 1] = key end
		end
		if #editionless > 0 and stream:next() < 0.25 then
			local key = editionless[stream:integer(1, #editionless)]
			state.joker_editions[key] = poll_edition(stream, true)
		end
	elseif tool.effect == "edition" then
		for _, card in ipairs(targets) do card.edition = poll_edition(stream, true) end
	elseif tool.effect == "seal" then
		for _, card in ipairs(targets) do card.seal = tool.seal or seals[stream:integer(1, #seals)] end
	elseif tool.effect == "create_cards" and #in_hand > 1 then
		-- Familiar, Grim, Incantation: one random card of the hand is destroyed,
		-- then `count` cards of a random listed rank and suit are added, each
		-- with a random enhancement other than Stone (card.lua use_consumeable).
		remove_card(state.deck, in_hand[stream:integer(1, #in_hand)])
		local ranks = tool.ranks or { 14 }
		for index = 1, tool.count or 1 do
			local card = {
				rank = ranks[stream:integer(1, #ranks)],
				suit = state.Cards.suits[stream:integer(1, #state.Cards.suits)],
				enhancement = enhancements[stream:integer(1, #enhancements)],
			}
			state.Cards.refresh(card, ":" .. tool.key .. ":" .. state.ante .. ":" .. state.round .. ":" .. index
				.. ":" .. #state.deck)
			state.deck[#state.deck + 1] = card
			state.cards_added = state.cards_added + 1
			adjust_owned_jokers(state, "deck_add_scaling_xmult", 1)
		end
	elseif (tool.effect == "hand_suit" or tool.effect == "hand_rank") and #in_hand > 1 then
		-- Sigil: every card in hand becomes one random suit. Ouija: one random
		-- rank, and the hand size drops by 1. Multiplayer Ouija instead destroys
		-- three random cards before converting the survivors.
		local suit = tool.effect == "hand_suit"
			and ({ "Spades", "Hearts", "Diamonds", "Clubs" })[stream:integer(1, 4)] or nil
		local rank = tool.effect == "hand_rank" and stream:integer(2, 14) or nil
		local first_survivor = 1
		if tool.effect == "hand_rank" and tool.destroy_count then
			local destroyed_count = math.min(tool.destroy_count, #in_hand)
			local destroyed = {}
			for index = 1, destroyed_count do
				destroyed[index] = in_hand[index]
				remove_card(state.deck, in_hand[index])
			end
			note_cards_destroyed(state, destroyed, 0)
			first_survivor = destroyed_count + 1
		end
		for index = first_survivor, #in_hand do
			local card = in_hand[index]
			card.suit = suit or card.suit
			card.rank = rank or card.rank
			state.Cards.refresh(card, ":" .. tool.key .. ":" .. state.ante .. ":" .. state.round .. ":" .. index)
		end
		state.hand_size_bonus = (state.hand_size_bonus or 0) + (tool.hand_size or 0)
	elseif tool.effect == "level_all_hands" then
		-- Black Hole: +1 level to every poker hand, secret hands included.
		for _, name in ipairs(planet_names) do state.levels[name] = (state.levels[name] or 1) + 1 end
		for _, name in ipairs({ "Flush House", "Flush Five" }) do
			state.levels[name] = (state.levels[name] or 1) + 1
		end
	elseif tool.effect == "money" then
		local gain
		if tool.sell_value then
			gain = 0
			for _, key in ipairs(state.jokers or {}) do
				for _, joker in ipairs(state.joker_pool or {}) do
					if joker.key == key then gain = gain + joker_sell_value(state, key); break end
				end
			end
		else
			gain = math.max(0, state.money) * (tool.multiplier or 1)
		end
		state.money = state.money + math.min(tool.cap or gain, gain)
	end
end

local function has_value(items, value)
	for _, item in ipairs(items) do if item == value then return true end end
	return false
end

local function has_joker_kind(state, wanted)
	for _, key in ipairs(state.jokers or {}) do
		local effect = state.joker_effects and state.joker_effects[key]
		if effect and effect.kind == wanted then return true end
	end
	return false
end

-- every Joker slot whose effect (its own, or the one a
-- Blueprint/Brainstorm in that slot copies) is one of `kinds`, left to right:
-- { slot = key of the Joker in the slot, key = key of the Joker whose effect
-- and state are used, effect = ..., copy = true for a copy }. Only for effects
-- the game lets Blueprint copy (calculate_joker without `not context.blueprint`):
-- money (To Do List, Business Card, Faceless Joker), cards and Jokers created
-- (Riff-raff, Cartomancer, Marble Joker, Superposition, Hallucination), Space
-- Joker's level up, Burglar's hands and Mime's retriggers.
local function joker_slots(state, kinds)
	local out = {}
	local jokers, effects = state.jokers or {}, state.joker_effects or {}
	local resolve = state.Evaluator and state.Evaluator.resolve_copy
	for index, slot in ipairs(jokers) do
		local effect, key = effects[slot], slot
		if resolve and effect and effect.kind == "copy_joker" then effect, key = resolve(jokers, effects, index) end
		if effect and kinds[effect.kind] then
			out[#out + 1] = { slot = slot, key = key, effect = effect, copy = key ~= slot }
		end
	end
	return out
end


-- how far money may go below $0 (-G.GAME.bankrupt_at).
-- Each Credit Card lowers bankrupt_at by its extra when added and raises it
-- again when removed (card.lua add_to_deck :594 / remove_from_deck :656), so
-- copies stack. `without_slot` leaves out the Joker in that slot: the limit
-- that holds once it has been sold (a "sell, then buy" in the shop).
local function debt_limit(state, without_slot)
	local limit = 0
	for slot, key in ipairs(state.jokers or {}) do
		local effect = state.joker_effects and state.joker_effects[key]
		if slot ~= without_slot and effect and effect.kind == "debt_limit" then
			limit = limit + (effect.amount or 20)
		end
	end
	return limit
end

-- the game's can_buy / can_reroll test
-- (functions/button_callbacks.lua:56 and :2077): free, or cost <= dollars - bankrupt_at.
local function can_pay(state, cost, debt)
	cost = tonumber(cost) or 0
	return cost <= 0 or cost <= (tonumber(state.money) or 0) + (debt or debt_limit(state))
end

local function allows_duplicates(state)
	return has_value(state.jokers or {}, "j_ring_master")
end

local function joker_available(state, key)
	local effect = state.joker_effects and state.joker_effects[key]
	if effect and effect.requires_pool_flag
		and not (state.pool_flags and state.pool_flags[effect.requires_pool_flag]) then return false end
	if effect and effect.blocks_pool_flag
		and state.pool_flags and state.pool_flags[effect.blocks_pool_flag] then return false end
	-- group C jokers: enhancement_gate (get_current_pool) keeps Golden Ticket out
	-- of the pool until the deck has a Gold card.
	if effect and effect.enhancement_gate then
		local gated = true
		for _, card in ipairs(state.deck or {}) do
			if card.enhancement == effect.enhancement_gate then gated = false; break end
		end
		if gated then return false end
	end
	return allows_duplicates(state) or not has_value(state.jokers or {}, key)
end

-- a Joker with an enhancement_gate (game.lua P_CENTERS, Glass Joker) is in
-- the pool only while a playing card has that enhancement (get_current_pool).
local function enhancement_gate_open(state, key)
	local effect = state.joker_effects and state.joker_effects[key]
	local wanted = effect and effect.pool_enhancement
	if not wanted then return true end
	for _, card in ipairs(state.deck or {}) do
		if card.enhancement == wanted then return true end
	end
	return false
end

local function rarity_matches(value, wanted)
	if wanted == "rare" then return value == 3 or tostring(value):lower() == "rare" end
	if wanted == "uncommon" then return value == 2 or tostring(value):lower() == "uncommon" end
	return true
end

-- Under The Order the Joker comes from the bot's private Order queues
-- (Order.generate_tag_joker), like the real Tag in a live game.
local function order_tag_jokers(state)
	return state.Order and type(state.Order.generate_tag_joker) == "function"
end

local function queued_tag_joker(state, reward, index)
	if state.strict_order_content then
		if not order_tag_jokers(state) or not reward.rarity then return nil end
		local generated = state.Order.generate_tag_joker(state, reward.rarity)
		if not generated or not generated.key then return nil end
		for _, joker in ipairs(state.joker_pool or {}) do
			if joker.key == generated.key then
				return {
					type = "joker", key = joker.key, cost = 0,
					tag_reward = reward.tag, edition = generated.edition,
				}
			end
		end
		return nil   -- a Joker the headless run cannot model
	end
	local eligible = {}
	for _, joker in ipairs(state.joker_pool or {}) do
		if not state.banned[joker.key] and joker_available(state, joker.key)
			and rarity_matches(joker.rarity, reward.rarity)
			-- Legendaries come only from The Soul (group A and C jokers).
			and tonumber(joker.rarity) ~= 4 and enhancement_gate_open(state, joker.key) then
			eligible[#eligible + 1] = joker
		end
	end
	if #eligible == 0 then return nil end
	local stream = state.rng:fork("skip_tag:" .. state.ante .. ":" .. reward.tag .. ":" .. index)
	local joker = eligible[stream:integer(1, #eligible)]
	return {
		type = "joker", key = joker.key, cost = 0,
		tag_reward = reward.tag, edition = reward.edition,
	}
end

local function inferred_rarity(joker)
	if joker.rarity then return tonumber(joker.rarity) or 1 end
	if (joker.cost or 0) >= 8 then return 3 end
	if (joker.cost or 0) >= 6 then return 2 end
	return 1
end

-- a Joker as create_card makes one for a shop or a
-- Buffoon Pack: rarity 70/25/5 % first, then uniform among the available
-- Jokers of that rarity (get_current_pool), then its edition (poll_edition,
-- Negative possible). Vanilla Jokers the headless run does not simulate take
-- their share of the draw and, as in a live game, give nothing the bot can
-- use ("j_unsupported"). Returns key, edition.
-- game.lua P_CENTERS has 61 / 64 / 20; Multiplayer Attrition bans the Uncommon
-- Mr. Bones, Luchador and Matador (gamemodes/attrition.lua). The 5 Legendaries
-- only come from The Soul (forced rarity 4).
local vanilla_jokers_by_rarity = { 61, 61, 20, 5 }
local function roll_vanilla_joker(state, stream, taken, forced_rarity)
	local rarity_roll = stream:next()
	local rarity = forced_rarity or (rarity_roll > 0.95 and 3 or (rarity_roll > 0.7 and 2 or 1))
	local eligible, supported = {}, 0
	for _, joker in ipairs(state.joker_pool or {}) do
		if inferred_rarity(joker) == rarity then
			supported = supported + 1
			if not state.banned[joker.key] and not (taken and taken[joker.key])
				and joker_available(state, joker.key) and enhancement_gate_open(state, joker.key) then
				eligible[#eligible + 1] = joker.key
			end
		end
	end
	local unsupported = math.max(0, (vanilla_jokers_by_rarity[rarity] or 0) - supported)
	local key
	if #eligible + unsupported == 0 then
		key = "j_joker"   -- an exhausted rarity gives a plain Joker (get_current_pool)
	else
		key = eligible[stream:integer(1, #eligible + unsupported)] or "j_unsupported"
	end
	return key, poll_edition(stream:fork("edition"), false, 1, state.edition_rate, true)
end

-- the 16 Spectral cards a shop or pack can show (game.lua).
local vanilla_spectrals = {
	"c_familiar", "c_grim", "c_incantation", "c_talisman", "c_aura", "c_wraith", "c_sigil", "c_ouija",
	"c_ectoplasm", "c_immolate", "c_ankh", "c_deja_vu", "c_hex", "c_trance", "c_medium", "c_cryptid",
}

local function joker_details(state, key)
	for _, joker in ipairs(state.joker_pool or {}) do
		if joker.key == key then return joker end
	end
	return { key = key, cost = 2 }
end


local function set_joker_edition(state, key, edition)
	if not edition then return end
	state.joker_editions[key] = edition
	if edition == "negative" then state.joker_limit = state.joker_limit + 1 end
end

local function clear_joker(state, key)
	if state.joker_editions[key] == "negative" then
		state.joker_limit = math.max(1, state.joker_limit - 1)
	end
	state.joker_editions[key] = nil
	state.joker_state[key] = nil
	if state.joker_targets then state.joker_targets[key] = nil end
	if state.joker_extra_value then state.joker_extra_value[key] = nil end
	if state.joker_counters then state.joker_counters[key] = nil end   -- group C jokers (Yorick)
end


local function score_string(value)
	if value < 1e15 then return string.format("%.0f", value) end
	return string.format("%.12e", value)
end

local function card_string(card)
	if not card then return "?" end
	return table.concat({
		tostring(card.id or "?"), tostring(card.suit or "?"), tostring(card.rank or "?"),
		tostring(card.enhancement or "none"), tostring(card.edition or "none"),
		tostring(card.seal or "none"),
	}, ":")
end

local function cards_string(cards, limit)
	local out = {}
	for index, card in ipairs(cards or {}) do
		if not limit or index <= limit then out[#out + 1] = card_string(card) end
	end
	return #out > 0 and table.concat(out, ",") or "none"
end

-- a log entry plus the fields its policy logged with the decision
local function with_log(decision, log)
	for name, field in pairs(log or {}) do
		if decision[name] == nil then decision[name] = field end
	end
	return decision
end

local function compact_snapshot(state, extra)
	extra = extra or {}
	local joker_state, joker_editions, levels = {}, {}, {}
	for _, key in ipairs(state.jokers or {}) do
		if state.joker_state and state.joker_state[key] ~= nil then
			joker_state[#joker_state + 1] = key .. ":" .. tostring(state.joker_state[key])
		end
		if state.joker_editions and state.joker_editions[key] then
			joker_editions[#joker_editions + 1] = key .. ":" .. tostring(state.joker_editions[key])
		end
	end
	for _, hand in ipairs(planet_names) do
		levels[#levels + 1] = hand .. ":" .. tostring(state.levels and state.levels[hand] or 1)
	end
	return table.concat({
		"seed:" .. tostring(state.seed or ""),
		"ante:" .. tostring(extra.ante or state.ante or ""),
		"round:" .. tostring(extra.round or state.current_round or state.round or ""),
		"turn:" .. tostring(extra.turn or ""),
		"money:" .. tostring(extra.money or state.money or 0),
		"score:" .. tostring(extra.current_score or ""),
		"target:" .. tostring(extra.required_score or extra.target or ""),
		"hands:" .. tostring(extra.hands_remaining or ""),
		"discards:" .. tostring(extra.discards_remaining or ""),
		"hand:" .. tostring(extra.hand_contents or cards_string(state.hand)),
		"draw:" .. cards_string(state.draw_pile),
		"used:" .. cards_string(state.used_cards),
		"deck:" .. cards_string(state.deck),
		"jokers:" .. table.concat(state.jokers or {}, ","),
		"joker_state:" .. (#joker_state > 0 and table.concat(joker_state, ",") or "none"),
		"joker_editions:" .. (#joker_editions > 0 and table.concat(joker_editions, ",") or "none"),
		"levels:" .. table.concat(levels, ","),
		"consumables:" .. (function()
			local held = {}
			for _, item in ipairs(state.consumables or {}) do held[#held + 1] = item.key end
			return #held > 0 and table.concat(held, ",") or "none"
		end)(),
	}, "|")
end

local function supported_pack_content(state, pack_key)
	local family = tostring(pack_key):match("^p_(%a+)_")
	local catalog = state.content_catalog
	if not catalog then return nil end
	local supported = {}
	local function collect(offers, set)
		for _, offer in ipairs(offers or {}) do
			if offer.key and (not set or offer.set == set) then supported[offer.key] = true end
		end
	end
	if family == "celestial" then
		collect(catalog.planets)
		collect(catalog.deck_tools, "Planet")
	elseif family == "buffoon" then
		collect(catalog.jokers)
	elseif family == "arcana" then
		collect(catalog.deck_tools, "Tarot")
	elseif family == "spectral" then
		collect(catalog.deck_tools, "Spectral")
	end
	local keys = {}
	for key in pairs(supported) do keys[#keys + 1] = key end
	table.sort(keys)
	return #keys > 0 and table.concat(keys, ",") or nil
end

local function record_decision(state, decision)
	state.next_decision_id = (state.next_decision_id or 0) + 1
	decision.decision_id = decision.decision_id or state.next_decision_id
	decision.money = decision.money == nil and state.money or decision.money
	decision.deck_size = #state.deck
	decision.joker_count = #state.jokers
	decision.jokers = decision.jokers or table.concat(state.jokers or {}, ",")
	local held = {}
	for _, consumable in ipairs(state.consumables or {}) do held[#held + 1] = consumable.key end
	decision.consumables = #held > 0 and table.concat(held, ",") or "none"
	local scalers = {}
	for _, key in ipairs(state.jokers) do
		local value = state.joker_state[key]
		if value and value ~= 0 then scalers[#scalers + 1] = key .. ":" .. tostring(value) end
	end
	table.sort(scalers)
	decision.scalers = #scalers > 0 and table.concat(scalers, ",") or "none"
	decision.snapshot = decision.snapshot or compact_snapshot(state, decision)
	notify(state, "decision", decision)   -- the policy may add its own fields
	state.decisions[#state.decisions + 1] = decision
end


local function expire_owned_jokers(state, effect_kind)
	for index = #state.jokers, 1, -1 do
		local key = state.jokers[index]
		local effect = state.joker_effects[key]
		local value = state.joker_state[key]
		if effect and effect.kind == effect_kind and effect.destroy_at ~= nil
			and value ~= nil and value <= effect.destroy_at + 1e-9 then
			table.remove(state.jokers, index)
			clear_joker(state, key)
			record_decision(state, {
				type = "destroy_joker", key = key, reason = effect_kind,
				ante = state.ante, round = state.current_round or state.round,
			})
		end
	end
end

local function draw_to_limit(state, limit)
	while #state.hand < limit and #state.draw_pile > 0 do
		state.hand[#state.hand + 1] = table.remove(state.draw_pile)
	end
end

local function current_hand_size(state)
	local size = 8 + (state.hand_size_bonus or 0) + (state.round_hand_size or 0)
	for _, key in ipairs(state.jokers) do
		local effect = state.joker_effects[key]
		if effect and effect.hand_size then size = size + effect.hand_size end
		if effect and effect.kind == "decaying_hand_size" then
			size = size + math.max(0, state.joker_state[key] or effect.initial or 0)
		end
	end
	return math.max(1, size)
end

local function current_round_resources(state)
	local hands, discards, reset = state.hands_per_round, state.discards_per_round, false
	if state.pizza_bonus_ante == state.ante then discards = discards + (state.pizza_discards or 0) end
	for _, key in ipairs(state.jokers) do
		local effect = state.joker_effects[key]
		if effect and effect.kind == "round_resources" then
			hands = hands + (effect.hands or 0)
			if effect.reset_discards then reset = true else discards = discards + (effect.discards or 0) end
		elseif effect and effect.kind == "skip_advantage_resources" then
			local advantage = math.max(0, (tonumber(state.skips) or 0) - (tonumber(state.opponent_skips) or 0))
			hands = hands + advantage * (effect.hands or 0)
			discards = discards + advantage * (effect.discards or 0)
		end
	end
	-- a Blueprint/Brainstorm copying Burglar adds its hands
	-- again (setting_blind, card.lua); the other hand/discard Jokers act in
	-- add_to_deck, which is never copied.
	for _, entry in ipairs(joker_slots(state, { round_resources = true })) do
		if entry.copy and entry.effect.reset_discards then hands = hands + (entry.effect.hands or 0) end
	end
	if reset then discards = 0 end   -- Burglar removes every discard when the Blind is set
	return math.max(1, hands), math.max(0, discards)
end

local function held_cards(full_hand, played)
	local selected, held = {}, {}
	for _, card in ipairs(played or {}) do selected[card] = true end
	for _, card in ipairs(full_hand or {}) do if not selected[card] then held[#held + 1] = card end end
	return held
end

-- Boss Blinds of Boss rounds that are not PvP Blinds
-- (in Multiplayer the Antes before PvP starts, usually Ante 1). game.lua
-- P_BLINDS (minimum Ante, debuffed suit), blind.lua (effects), get_new_boss
-- (least used eligible Boss); Multiplayer Attrition bans The Wall
-- (gamemodes/attrition.lua). Simulated effects: suit debuffs (Club, Goad, Head,
-- Window), The Plant, The Pillar, The Psychic, The Flint, The Needle, The
-- Water, The Manacle, The Hook and The Tooth; the others play as a plain Boss.
local boss_blinds = {
	{ key = "bl_hook", min = 1 }, { key = "bl_club", min = 1, suit = "Clubs" },
	{ key = "bl_manacle", min = 1 }, { key = "bl_psychic", min = 1 },
	{ key = "bl_goad", min = 1, suit = "Spades" }, { key = "bl_head", min = 1, suit = "Hearts" },
	{ key = "bl_window", min = 1, suit = "Diamonds" }, { key = "bl_pillar", min = 1 },
	{ key = "bl_mouth", min = 2 }, { key = "bl_fish", min = 2 }, { key = "bl_house", min = 2 },
	{ key = "bl_mark", min = 2 }, { key = "bl_wheel", min = 2 }, { key = "bl_arm", min = 2 },
	{ key = "bl_water", min = 2 }, { key = "bl_needle", min = 2 }, { key = "bl_flint", min = 2 },
	{ key = "bl_tooth", min = 3 }, { key = "bl_eye", min = 3 }, { key = "bl_plant", min = 4 },
	{ key = "bl_serpent", min = 5 }, { key = "bl_ox", min = 6 },
}
local boss_suit = {}
for _, boss in ipairs(boss_blinds) do boss_suit[boss.key] = boss.suit end

-- The Boss get_new_boss would pick: an eligible Boss used least often so far.
function Simulator.pick_boss(rng, ante, used)
	used = used or {}
	ante = math.max(1, tonumber(ante) or 1)
	local fewest
	for _, boss in ipairs(boss_blinds) do
		if boss.min <= ante and (not fewest or (used[boss.key] or 0) < fewest) then fewest = used[boss.key] or 0 end
	end
	local eligible = {}
	for _, boss in ipairs(boss_blinds) do
		if boss.min <= ante and (used[boss.key] or 0) == fewest then eligible[#eligible + 1] = boss.key end
	end
	return eligible[rng:integer(1, #eligible)]
end

-- Card debuffs of the current Boss (Blind:debuff_card): its suit (Wild cards
-- have every suit, Stone cards none), face cards for The Plant, cards played
-- earlier this Ante for The Pillar. No Boss clears them.
local function set_boss_debuffs(state)
	local boss = state.boss_blind
	local suit = boss and boss_suit[boss]
	local all_faces = boss == "bl_plant" and has_joker_kind(state, "all_faces")
	for _, card in ipairs(state.deck or {}) do
		local debuff = false
		if suit then
			debuff = card.enhancement ~= "m_stone" and (card.enhancement == "m_wild" or card.suit == suit)
		elseif boss == "bl_plant" then
			debuff = all_faces or (card.enhancement ~= "m_stone" and card.rank >= 11 and card.rank <= 13)
		elseif boss == "bl_pillar" then
			debuff = card.played_this_ante == true
		end
		card.debuff = debuff or nil
	end
end

-- Glass Cards under the lobby's ruleset. Multiplayer's
-- standard, classic and wsob layers rework them to X1.5 (1 in 4 to break),
-- the sandbox layer to X1.5 (1 in 3); vanilla-content rulesets keep X2, 1 in 4
-- (multiplayer objects/enhancements/mp_glass.lua, layers/*.lua, rulesets/*.lua).
local vanilla_glass_rulesets = { vanilla = true, majorleague = true, minorleague = true, release = true, badlatro = true }
local function glass_rules(state)
	local key = tostring(state.ruleset or ""):gsub("^ruleset_mp_", "")
	if vanilla_glass_rulesets[key] then return 2, 4 end
	if key == "sandbox" or key == "chaos" then return 1.5, 3 end
	return 1.5, 4
end

local function joker_context(state, cards, hands_left, discards_left, full_hand)
	local rarities, sell_values = {}, {}
	for _, key in ipairs(state.jokers) do
		local details = joker_details(state, key)
		rarities[key] = details.rarity
		sell_values[key] = joker_sell_value(state, key)
	end
	return {
		discards_left = discards_left,
		hands_left = hands_left,
		joker_effects = state.joker_effects,
		joker_state = state.joker_state,
		joker_targets = state.joker_targets,
		money = state.money,
		deck_remaining = #state.draw_pile,
		full_deck = state.deck,
		held_cards = held_cards(full_hand or state.hand, cards),
		hand_usage = state.hand_usage,
		round_hand_usage = state.round_hand_usage,
		hands_played = state.hands_played,
		rounds_completed = state.rounds_completed,
		discarded_cards = state.discarded_cards,
		planets_used = state.planets_used,
		tarots_used = state.tarots_used,
		cards_added = state.cards_added,
		joker_rarities = rarities,
		joker_sell_values = sell_values,
		joker_limit = state.joker_limit,
		joker_editions = state.joker_editions,
		starting_deck_size = state.starting_deck_size,
		is_pvp = state.current_round == "PvP",
		glass_xmult = (glass_rules(state)),
		boss_min_cards = state.boss_blind == "bl_psychic" and 5 or nil,
		boss_halve_base = state.boss_blind == "bl_flint" or nil,
		probability_multiplier = has_joker_kind(state, "double_probabilities") and 2 or 1,
		idol_card = state.idol_card,   -- group B jokers
		blinds_skipped = state.skips,   -- group C jokers (Throwback)
	}
end

local function same_order(left, right)
	if #(left or {}) ~= #(right or {}) then return false end
	for index, key in ipairs(left or {}) do if key ~= right[index] then return false end end
	return true
end

-- An order a hook returns must be a permutation of the owned Jokers.
local function check_joker_order(state, order, hook)
	local counts = {}
	for _, key in ipairs(state.jokers) do counts[key] = (counts[key] or 0) + 1 end
	local valid = type(order) == "table" and #order == #state.jokers
	for _, key in ipairs(valid and order or {}) do
		if not counts[key] or counts[key] == 0 then valid = false; break end
		counts[key] = counts[key] - 1
	end
	if not valid then error(hook .. " returned an order that is not a permutation of the Jokers") end
end

-- Scores `cards` with exactly `order`. A Blueprint/Brainstorm layout's copies
-- are resolved once per order and turn (`resolved_order_cache`).
local function order_evaluator(state, cards, context, resolved_order_cache)
	local has_copy = false
	for _, key in ipairs(state.jokers) do
		local effect = state.joker_effects[key]
		if effect and effect.kind == "copy_joker" then has_copy = true; break end
	end
	return function(order)
		if has_copy then
			local cache_key = table.concat(order, "\0")
			local resolved = resolved_order_cache[cache_key]
			if not resolved then
				resolved = state.Evaluator.resolve_jokers(order, state.joker_effects)
				resolved_order_cache[cache_key] = resolved
			end
			context.resolved_jokers = resolved
		end
		return state.Evaluator.evaluate(cards, state.levels, order, context)
	end
end

-- Hook joker_order: the Joker layout a candidate play is scored with (arranging
-- Jokers is a free player action). A result the hook returns must come from
-- ctx.evaluate_order with that order; otherwise the simulator scores it.
local function scored_play(state, cards, context, resolved_order_cache, full_hand)
	local evaluate_order = order_evaluator(state, cards, context, resolved_order_cache)
	local ctx = { cards = cards, full_hand = full_hand, context = context, evaluate_order = evaluate_order }
	local hook = state.Policy.joker_order
	if not hook then   -- no decision: the current order
		local result = evaluate_order(state.jokers)
		result.joker_order = copy_array(state.jokers)
		return result
	end
	local produced = {}
	ctx.evaluate_order = function(candidate)
		local scored = evaluate_order(candidate)
		produced[scored] = copy_array(candidate)
		return scored
	end
	local order, result = hook(state, ctx)
	order = order or state.jokers
	check_joker_order(state, order, "joker_order")
	if not result or not produced[result] or not same_order(produced[result], order) then
		result = evaluate_order(order)
	end
	result.joker_order = copy_array(order)
	return result
end

-- Hook arrange_jokers: a free rearrangement of the Jokers (leaving a shop,
-- starting a Blind).
local function arrange_jokers(state, source)
	local order = decide(state, "arrange_jokers", { source = source, jokers = copy_array(state.jokers) })
	if order == nil then return false end
	check_joker_order(state, order, "arrange_jokers")
	if same_order(state.jokers, order) then return false end
	local previous = state.jokers
	state.jokers = copy_array(order)
	record_decision(state, {
		type = "reorder_jokers", from = table.concat(previous, ","),
		to = table.concat(state.jokers, ","), source = source,
		ante = state.ante, round = state.current_round or state.round,
	})
	return true
end

local function generate_tarot(state, source, label)
	if #(state.consumables or {}) >= (state.consumable_limit or 2) then return false end
	local eligible = {}
	for _, tool in ipairs(state.deck_tools or {}) do
		if tool.set == "Tarot" then eligible[#eligible + 1] = tool end
	end
	if #eligible == 0 then return false end
	local stream = state.rng:fork(table.concat({
		"generated_tarot", tostring(source), tostring(label), tostring(state.ante),
		tostring(state.round), tostring(state.hands_played), tostring(#state.consumables),
	}, ":"))
	local choice = copy_map(eligible[stream:integer(1, #eligible)])
	choice.type = "deck_tool"
	state.consumables[#state.consumables + 1] = choice
	record_decision(state, {
		type = "create_consumable", key = choice.key, source = source,
		ante = state.ante, round = state.current_round or state.round,
	})
	return true
end

-- the Planet of `hand` into the consumable slots if there
-- is room (Blue Seal, Card:get_end_of_round_effect in card.lua).
local function generate_hand_planet(state, hand, source)
	if not hand or #(state.consumables or {}) >= (state.consumable_limit or 2) then return false end
	for _, planet in ipairs(state.planet_pool or {}) do
		if planet.hand == hand then
			state.consumables[#state.consumables + 1] = {
				type = "planet", key = planet.key, hand = hand, cost = planet.cost,
			}
			record_decision(state, {
				type = "create_consumable", key = planet.key, source = source,
				ante = state.ante, round = state.current_round or state.round,
			})
			return true
		end
	end
	return false
end

local function generate_spectral(state, source, label)
	if #(state.consumables or {}) >= (state.consumable_limit or 2) then return false end
	local eligible = {}
	for _, tool in ipairs(state.deck_tools or {}) do
		if tool.set == "Spectral" and not tool.hidden then eligible[#eligible + 1] = tool end
	end
	if #eligible == 0 then return false end
	local stream = state.rng:fork(table.concat({
		"generated_spectral", tostring(source), tostring(label), tostring(state.ante),
		tostring(state.round), tostring(state.hands_played), tostring(#state.consumables),
	}, ":"))
	local choice = copy_map(eligible[stream:integer(1, #eligible)])
	choice.type = "deck_tool"
	state.consumables[#state.consumables + 1] = choice
	record_decision(state, { type = "create_consumable", key = choice.key, source = source,
		ante = state.ante, round = state.current_round or state.round })
	return true
end

---------------------------------------------------------------------------
-- group B jokers: Hit the Road, The Idol, Invisible Joker, Luchador, Lucky
-- Cat, Matador, Mr. Bones, Perkeo, Rocket (card.lua calculate_joker,
-- calculate_dollar_bonus; functions/state_events.lua end_round).
---------------------------------------------------------------------------

-- Bosses whose ability the simulator applies (a disabled one does nothing).
local simulated_boss_abilities = {
	bl_hook = true, bl_club = true, bl_goad = true, bl_head = true, bl_window = true,
	bl_manacle = true, bl_psychic = true, bl_pillar = true, bl_needle = true,
	bl_water = true, bl_flint = true, bl_tooth = true, bl_plant = true,
}

-- Blind:disable for the simulated Bosses: no more debuffs, The Manacle's hand
-- size comes back, The Needle's and The Water's limits are never applied.
local function disable_boss(state, source)
	local boss = state.boss_blind
	if not boss then return false end
	if boss == "bl_manacle" then state.round_hand_size = (state.round_hand_size or 0) + 1 end
	state.boss_blind = nil
	state.boss_disabled = boss
	for _, card in ipairs(state.deck or {}) do card.debuff = nil end
	record_decision(state, { type = "disable_boss", key = source, boss = boss,
		ante = state.ante, round = state.current_round or state.round })
	return true
end

-- Selling a Joker (context.selling_self, never seen by Blueprint/Brainstorm):
-- Luchador disables the current Boss Blind; Invisible Joker, after 2 rounds,
-- copies a random other Joker if the slots hold it (copy_card drops Negative).
-- `replacing`: the sale makes room for a purchase in the same slot, which the
-- copy would take in the game, so no copy is made.
sold_joker_rules = function(state, key, replacing)
	local effect = state.joker_effects[key]
	if not effect then return end
	if effect.kind == "sell_disable_boss" then
		disable_boss(state, key)
	elseif effect.kind == "sell_duplicate_joker" and not replacing
		and (tonumber(state.joker_state[key]) or 0) >= (effect.rounds or 2) then
		local others, skipped = {}, false
		for _, other in ipairs(state.jokers) do
			if other == key and not skipped then skipped = true else others[#others + 1] = other end
		end
		if #others > 0 and #state.jokers <= state.joker_limit then
			local stream = state.rng:fork(table.concat({
				"invisible", tostring(state.ante), tostring(state.round), tostring(state.shop_visits),
			}, ":"))
			local copied = others[stream:integer(1, #others)]
			state.jokers[#state.jokers + 1] = copied
			if state.joker_state[copied] == nil then initialize_joker(state, copied) end
			record_decision(state, { type = "create_joker", key = copied, source = key,
				ante = state.ante, round = state.current_round or state.round })
		end
	end
end

-- Hook boss_disable_step: whether to sell Luchador once the Boss Blind is set.
-- ctx = { boss, simulated (the simulator applies this Boss's ability),
-- actions = { keep, sell_joker } }.

local function offer_boss_disable(state)
	if not state.boss_blind then return end
	local slot
	for index, key in ipairs(state.jokers) do
		local effect = state.joker_effects[key]
		if effect and effect.kind == "sell_disable_boss" then slot = index; break end
	end
	if not slot then return end
	local key = state.jokers[slot]
	local actions = {
		{ type = "keep" },
		{ type = "sell_joker", index = slot, key = key, value = joker_sell_value(state, key) },
	}
	local index = decide(state, "boss_disable_step", {
		boss = state.boss_blind, simulated = simulated_boss_abilities[state.boss_blind] == true, actions = actions,
	}, 1)
	local action = actions[index]
	if not action then error("boss_disable_step returned an invalid action index " .. tostring(index)) end
	if action.type ~= "sell_joker" then return end
	state.money = state.money + action.value
	record_decision(state, { type = "sell_joker", key = key, value = action.value,
		source = "boss_disable", ante = state.ante, round = state.round })
	note_joker_sold(state, key)
	clear_joker(state, key)
	table.remove(state.jokers, slot)
end

-- The Idol's card for the round (reset_idol_card): a random non-Stone card of the deck.
local function pick_idol_card(state)
	if not has_joker_kind(state, "rotating_card_xmult") then return end
	local valid = {}
	for _, card in ipairs(state.deck or {}) do
		if card.enhancement ~= "m_stone" then valid[#valid + 1] = card end
	end
	state.idol_card = { rank = 14, suit = "Spades" }
	if #valid == 0 then return end
	local stream = state.rng:fork("idol:" .. tostring(state.ante) .. ":" .. tostring(state.round))
	local card = valid[stream:integer(1, #valid)]
	state.idol_card = { rank = card.rank, suit = card.suit }
end

-- Hit the Road (context.discard, not copied): X0.5 per discarded Jack that is not debuffed.
local function discard_rank_jokers(state, discarded)
	for _, key in ipairs(state.jokers) do
		local effect = state.joker_effects[key]
		if effect and effect.kind == "discard_rank_xmult" then
			for _, card in ipairs(discarded or {}) do
				if card.rank == effect.rank and card.enhancement ~= "m_stone" and not card.debuff then
					state.joker_state[key] = math.max(effect.initial or 1, tonumber(state.joker_state[key]) or 0)
						+ (effect.amount or 0.5)
				end
			end
		end
	end
end

-- After a played hand: Lucky Cat keeps this hand's growth; Matador pays $8
-- for every hand that triggers the Boss Blind (Blind.triggered: The Flint, a
-- debuffed scoring card, a hand The Psychic debuffs), also for every copy.
local function hand_trigger_jokers(state, result)
	local seen = {}
	for _, key in ipairs(state.jokers) do
		local effect = state.joker_effects[key]
		if effect and effect.kind == "lucky_scaling_xmult" and not seen[key] then
			seen[key] = true
			local growth = result.growth and result.growth[key] or 0
			if growth > 0 then
				state.joker_state[key] = math.max(effect.initial or 1, tonumber(state.joker_state[key]) or 0) + growth
			end
		end
	end
	if not state.boss_blind then return end
	local triggered = result.debuffed_hand == true or state.boss_blind == "bl_flint"
	if not triggered then
		for _, card in ipairs(result.scoring_cards or {}) do
			if card.debuff then triggered = true; break end
		end
	end
	if not triggered then return end
	for _, entry in ipairs(joker_slots(state, { boss_trigger_money = true })) do
		local amount = entry.effect.amount or 8
		state.money = state.money + amount
		record_decision(state, { type = "joker_income", key = entry.slot, value = amount,
			hand = result.name, ante = state.ante, round = state.current_round or state.round })
	end
end

-- end_round (context.end_of_round, not copied): Mr. Bones saves a lost Blind
-- with at least 25% of its chips and is destroyed; Rocket's payout grows by $2
-- after a Boss Blind; Invisible Joker counts the round; Hit the Road resets.
-- Returns true when Mr. Bones saved the round.
local function end_of_round_jokers(state, session)
	for _, key in ipairs(state.jokers) do
		local effect = state.joker_effects[key]
		if effect and effect.kind == "boss_scaling_money" and session.round_name == "Boss" then
			state.joker_state[key] = (tonumber(state.joker_state[key]) or effect.initial or 1) + (effect.amount or 2)
		elseif effect and effect.kind == "sell_duplicate_joker" then
			state.joker_state[key] = (tonumber(state.joker_state[key]) or 0) + 1
		elseif effect and effect.kind == "discard_rank_xmult" then
			state.joker_state[key] = effect.initial or 1
		end
	end
	if not (session.target and session.cumulative < session.target) then return false end
	for index, key in ipairs(state.jokers) do
		local effect = state.joker_effects[key]
		if effect and effect.kind == "prevent_death"
			and session.cumulative / session.target >= (effect.threshold or 0.25) then
			table.remove(state.jokers, index)
			clear_joker(state, key)
			record_decision(state, { type = "destroy_joker", key = key, reason = "prevent_death",
				ante = state.ante, round = state.current_round or state.round })
			return true
		end
	end
	return false
end

-- Rocket's end-of-round payout (calculate_dollar_bonus; never copied).
local function rocket_income(state)
	local income = 0
	for _, key in ipairs(state.jokers) do
		local effect = state.joker_effects[key]
		if effect and effect.kind == "boss_scaling_money" then
			local amount = tonumber(state.joker_state[key]) or effect.initial or 1
			income = income + amount
			record_decision(state, { type = "joker_income", key = key, value = amount,
				ante = state.ante, round = state.current_round or state.round })
		end
	end
	return income
end

-- Perkeo (context.ending_shop, also every copy): a Negative copy of a random
-- held consumable; a Negative consumable brings its own slot.
local function shop_end_jokers(state)
	for index, entry in ipairs(joker_slots(state, { shop_end_negative_consumable = true })) do
		if #state.consumables == 0 then return end
		local stream = state.rng:fork(table.concat({
			"perkeo", tostring(state.ante), tostring(state.shop_visits), tostring(index),
		}, ":"))
		local copy = copy_map(state.consumables[stream:integer(1, #state.consumables)])
		copy.negative = true
		state.consumable_limit = state.consumable_limit + 1
		state.consumables[#state.consumables + 1] = copy
		record_decision(state, { type = "create_consumable", key = copy.key, source = entry.slot,
			edition = "negative", ante = state.ante, round = state.current_round or state.round })
	end
end

-- A consumable leaves the slots: a Negative one takes its slot with it.
local function release_consumable(state, consumable)
	if consumable and consumable.negative then
		state.consumable_limit = math.max(0, state.consumable_limit - 1)
	end
end

local function update_scaling_jokers(state, result, played_cards)
	for _, key in ipairs(state.jokers) do
		local effect = state.joker_effects[key]
		if effect then
			local current = state.joker_state[key] or 0
			if effect.kind == "straight_scaling_chips"
				and (result.contained and result.contained.Straight
					or result.name == "Straight" or result.name == "Straight Flush") then
				state.joker_state[key] = current + effect.amount
			elseif effect.kind == "four_card_scaling_chips" and #played_cards == 4 then
				state.joker_state[key] = current + effect.amount
			elseif effect.kind == "green_scaling_mult" then
				state.joker_state[key] = current + effect.hand_add
			elseif effect.kind == "hand_scaling_mult" and (result.name == effect.hand
				or (result.contained and result.contained[effect.hand])
				or (effect.hand == "Two Pair" and result.name == "Full House")) then
				state.joker_state[key] = current + effect.amount
			elseif effect.kind == "rank_scaling_chips" then
				if result.growth then current = current + (result.growth[key] or 0)
				else
					for _, card in ipairs(result.scoring_cards or {}) do
						if card.rank == effect.rank and card.enhancement ~= "m_stone" then
							current = current + effect.amount
						end
					end
				end
				state.joker_state[key] = current
			elseif effect.kind == "played_card_chip_growth" and not result.hiker then
				for _, card in ipairs(result.scoring_cards or {}) do
					card.perma_bonus = (card.perma_bonus or 0) + (effect.amount or 5)
					card.chips = (card.chips or state.Cards.chips(card.rank)) + (effect.amount or 5)
				end
			elseif effect.kind == "played_rank_planet" then
				-- 8 Ball creates a Tarot, 1 in 4 for each scored 8,
				-- per trigger, while there is room (card.lua calculate_joker :3106).
				-- Upstream made a Planet from `state.planets`, which is never set.
				local odds = math.max(1, (tonumber(effect.odds) or 4)
					/ (has_joker_kind(state, "double_probabilities") and 2 or 1))
				for index, card in ipairs(result.scoring_cards or {}) do
					if card.rank == effect.rank and card.enhancement ~= "m_stone" and not card.debuff then
						for trigger = 1, (result.card_repetitions and result.card_repetitions[card]) or 1 do
							local stream = state.rng:fork(table.concat({
								"8ball", key, state.ante, state.round, state.hands_played, index, trigger,
							}, ":"))
							if stream:next() < 1 / odds then generate_tarot(state, key, "8ball:" .. index .. ":" .. trigger) end
						end
					end
				end
			elseif effect.kind == "avoid_most_played_xmult" then
				local most = 0
				for _, uses in pairs(state.hand_usage or {}) do most = math.max(most, uses) end
				if (state.hand_usage[result.name] or 0) >= most then
					state.joker_state[key] = effect.initial or 1
				else
					state.joker_state[key] = math.max(effect.initial or 1, current) + (effect.amount or 0.2)
				end
			elseif effect.kind == "face_gold_conversion" then
				for _, card in ipairs(result.scoring_cards or {}) do
					if card.rank >= 11 and card.rank <= 13 then card.enhancement = "m_gold" end
				end
			elseif effect.kind == "bus_scaling_mult" then
				local scoring_face = false
				for _, card in ipairs(result.scoring_cards or {}) do
					if has_joker_kind(state, "all_faces")
						or (card.enhancement ~= "m_stone" and card.rank >= 11 and card.rank <= 13) then
						scoring_face = true
						break
					end
				end
				state.joker_state[key] = scoring_face and 0 or current + effect.amount
			elseif effect.kind == "periodic_xmult" then
				-- The hand whose pre-score countdown is one receives the effect, then
				-- Loyalty Card begins a fresh six-hand cycle.
				state.joker_state[key] = current <= 1 and (effect.every or 6) or current - 1
			elseif effect.kind == "low_money_tarot"
				and (tonumber(state.money) or 0) <= (effect.threshold or 4) then
				generate_tarot(state, key, "low_money_hand")
			elseif effect.kind == "first_six_spectral" and #played_cards == 1
				and played_cards[1].rank == 6 then
				local round_hands = 0
				for _, uses in pairs(state.round_hand_usage or {}) do round_hands = round_hands + uses end
				if round_hands == 1 then
					remove_card(state.deck, played_cards[1])
					generate_spectral(state, key, "first_six")
					record_decision(state, { type = "destroy_playing_card", key = key,
						ante = state.ante, round = state.current_round or state.round })
				end
			elseif effect.kind == "enhancement_steal_xmult" then
				-- group C jokers: Vampire (context.before, not copied), in Joker
				-- order, so a Midas Mask to its left has made the faces Gold.
				local count = 0
				for _, card in ipairs(result.scoring_cards or {}) do
					if card.enhancement and not card.debuff then
						card.enhancement = nil
						count = count + 1
					end
				end
				state.joker_state[key] = (state.joker_state[key] or effect.initial or 1) + count * (effect.amount or 0.1)
			end
		end
	end
	-- Superposition, and every Blueprint/Brainstorm copying it.
	if result.name == "Straight" or result.name == "Straight Flush" then
		for _, entry in ipairs(joker_slots(state, { straight_ace_tarot = true })) do
			local has_ace = false
			for _, card in ipairs(result.scoring_cards or {}) do
				if card.rank == 14 and card.enhancement ~= "m_stone" then has_ace = true; break end
			end
			if has_ace then generate_tarot(state, entry.slot, "straight_ace") end
		end
	end
end

-- Things the game does around a scored hand.
-- Space Joker (context.before): 1 in 4 to level the hand before it scores.
local function roll_hand_level_jokers(state, hand_name)
	local leveled = false
	-- A Blueprint/Brainstorm copying Space Joker rolls again (its slot names the roll).
	for _, entry in ipairs(joker_slots(state, { chance_hand_level = true })) do
		local key, effect = entry.slot, entry.effect
		do
			local odds = math.max(1, (tonumber(effect.odds) or 4)
				/ (has_joker_kind(state, "double_probabilities") and 2 or 1))
			local stream = state.rng:fork(table.concat({
				"joker_hand_level", key, state.ante, state.round, state.hands_played,
			}, ":"))
			if stream:next() < 1 / odds then
				state.levels[hand_name] = (state.levels[hand_name] or 1) + 1
				leveled = true
				record_decision(state, {
					type = "joker_hand_level", key = key, hand = hand_name,
					value = state.levels[hand_name], ante = state.ante,
					round = state.current_round or state.round,
				})
			end
		end
	end
	return leveled
end

-- Hiker's permanent chips, Gold Seal and Lucky Card money, Glass Cards breaking
-- (1 in 4 after scoring, removed from the deck).
local function after_scoring(state, result)
	for card, bonus in pairs(result.hiker or {}) do
		card.perma_bonus = (card.perma_bonus or 0) + bonus
		card.chips = (card.chips or state.Cards.chips(card.rank)) + bonus
	end
	local dollars = tonumber(result.dollars) or 0
	for index, card in ipairs(result.scoring_cards or {}) do
		if card.enhancement == "m_lucky" then
			for trigger = 1, (result.card_repetitions and result.card_repetitions[card]) or 1 do
				local stream = state.rng:fork(table.concat({
					"lucky_money", state.ante, state.round, state.hands_played, index, trigger,
				}, ":"))
				if stream:next() < 1 / 15 then dollars = dollars + 20 end
			end
		end
	end
	if dollars > 0 then
		state.money = state.money + dollars
		record_decision(state, {
			type = "scoring_income", value = dollars, ante = state.ante, round = state.current_round or state.round,
		})
	end
	local shattered = {}
	for index, card in ipairs(result.scoring_cards or {}) do
		if card.enhancement == "m_glass" then
			local stream = state.rng:fork(table.concat({
				"glass", state.ante, state.round, state.hands_played, index,
			}, ":"))
			local _, glass_odds = glass_rules(state)
			if stream:next() < 1 / glass_odds then
				remove_card(state.deck, card)
				shattered[#shattered + 1] = card
				record_decision(state, {
					type = "glass_shattered", card = tostring(card.id or card.rank),
					ante = state.ante, round = state.current_round or state.round,
				})
			end
		end
	end
	-- Caino and Glass Joker (context.cards_destroyed, glass_shattered).
	if #shattered > 0 then note_cards_destroyed(state, shattered, #shattered) end
end

local function update_discard_jokers(state, discarded)
	for _, key in ipairs(state.jokers) do
		local effect = state.joker_effects[key]
		if effect and effect.kind == "green_scaling_mult" then
			state.joker_state[key] = math.max(0, (state.joker_state[key] or 0) - effect.discard_sub)
		elseif effect and effect.kind == "discard_suit_scaling_chips" then
			local target = state.joker_targets[key]
			for _, card in ipairs(discarded or {}) do
				if card.suit == target or card.enhancement == "m_wild" then
					state.joker_state[key] = (state.joker_state[key] or 0) + (effect.amount or 3)
				end
			end
		elseif effect and effect.kind == "discard_rank_money" then
			local count = 0
			for _, card in ipairs(discarded or {}) do
				if card.rank == state.joker_targets[key] then count = count + 1 end
			end
			if count > 0 then
				local amount = count * (effect.amount or 5)
				state.money = state.money + amount
				record_decision(state, { type = "joker_income", key = key, value = amount,
					ante = state.ante, round = state.current_round or state.round })
			end
		elseif effect and effect.kind == "discard_count_xmult" then
			-- group C jokers: Yorick (context.discard, each card, not copied).
			state.joker_counters = state.joker_counters or {}
			for _ = 1, #(discarded or {}) do
				local left = state.joker_counters[key] or effect.discards or 23
				if left <= 1 then
					state.joker_counters[key] = effect.discards or 23
					state.joker_state[key] = (state.joker_state[key] or effect.initial or 1) + (effect.amount or 1)
				else
					state.joker_counters[key] = left - 1
				end
			end
		elseif effect and effect.kind == "single_discard_destroy"
			and #discarded == 1 and not state.joker_round_flags[key] then
			state.joker_round_flags[key] = true
			remove_card(state.deck, discarded[1])
			note_cards_destroyed(state, { discarded[1] }, 0)   -- Caino
			state.money = state.money + (effect.amount or 3)
			record_decision(state, { type = "destroy_playing_card", key = key,
				value = effect.amount or 3, ante = state.ante, round = state.current_round or state.round })
		end
	end
	-- Faceless Joker pays again for every Blueprint/Brainstorm
	-- copying it (context.discard has no blueprint guard); a Stone card is not a
	-- face card (Card:is_face) unless Pareidolia makes every card one.
	for _, entry in ipairs(joker_slots(state, { discard_face_money = true })) do
		local effect = entry.effect
		local faces = 0
		for _, card in ipairs(discarded or {}) do
			if has_joker_kind(state, "all_faces")
				or (card.enhancement ~= "m_stone" and card.rank >= 11 and card.rank <= 13) then
				faces = faces + 1
			end
		end
		if faces >= (effect.count or 3) then
			state.money = state.money + (effect.amount or 0)
			record_decision(state, {
				type = "joker_income", key = entry.slot, value = effect.amount or 0,
				ante = state.ante, round = state.current_round or state.round,
			})
		end
	end
	discard_rank_jokers(state, discarded)   -- group B jokers
	-- a discarded Purple Seal card creates a Tarot if there
	-- is room (Card:calculate_seal, context.discard, card.lua).
	for index, card in ipairs(discarded or {}) do
		if card.seal == "Purple" then generate_tarot(state, "purple_seal", tostring(index)) end
	end
end


local function prepare_round_jokers(state, round_name)
	local generators, tarot_generators = 0, 0
	local index = 1
	while index <= #state.jokers do
		local key = state.jokers[index]
		local effect = state.joker_effects[key]
		if effect and effect.kind == "sacrifice_scaling_mult" and state.jokers[index + 1] then
			local victim = state.jokers[index + 1]
			local sell = joker_sell_value(state, victim)
			state.joker_state[key] = (state.joker_state[key] or 0) + sell * (effect.amount or 2)
			table.remove(state.jokers, index + 1)
			clear_joker(state, victim)
			record_decision(state, { type = "destroy_joker", key = victim, source = key,
				value = sell * (effect.amount or 2), ante = state.ante, round = state.current_round or state.round })
		elseif effect and effect.kind == "blind_scaling_xmult"
			and (round_name == "Small" or round_name == "Big") then
			state.joker_state[key] = (state.joker_state[key] or effect.initial or 1) + (effect.amount or 0.5)
			local victims = {}
			for candidate = 1, #state.jokers do if candidate ~= index then victims[#victims + 1] = candidate end end
			if #victims > 0 then
				local stream = state.rng:fork("madness:" .. state.ante .. ":" .. state.round)
				local victim_index = victims[stream:integer(1, #victims)]
				local victim = state.jokers[victim_index]
				table.remove(state.jokers, victim_index)
				clear_joker(state, victim)
				if victim_index < index then index = index - 1 end
				record_decision(state, { type = "destroy_joker", key = victim, source = key,
					ante = state.ante, round = state.current_round or state.round })
			end
		end
		index = index + 1
	end
	for _, key in ipairs(state.jokers) do
		local effect = state.joker_effects[key]
		if effect and effect.kind == "played_hand_money" then
			local stream = state.rng:fork(
				"joker_target:" .. key .. ":" .. state.ante .. ":" .. state.round .. ":" .. tostring(round_name)
			)
			state.joker_state[key] = planet_names[stream:integer(1, #planet_names)]
		elseif effect and effect.kind == "rotating_suit_xmult"
			or effect and effect.kind == "discard_suit_scaling_chips" then
			local stream = state.rng:fork("joker_suit:" .. key .. ":" .. state.ante .. ":" .. state.round)
			state.joker_targets[key] = state.Cards.suits[stream:integer(1, #state.Cards.suits)]
		elseif effect and effect.kind == "discard_rank_money" then
			local stream = state.rng:fork("joker_rank:" .. key .. ":" .. state.ante .. ":" .. state.round)
			state.joker_targets[key] = stream:integer(2, 14)
		elseif effect and effect.kind == "opponent_sale_mult" and round_name == "PvP" then
			state.joker_state[key] = (state.joker_state[key] or 0)
				+ (state.pending_opponent_sells or 0) * (effect.amount or 4)
		end
	end
	-- Riff-raff, Cartomancer and Marble Joker act again for
	-- every Blueprint/Brainstorm copying them (setting_blind, card.lua).
	for _, entry in ipairs(joker_slots(state, {
		round_joker_generation = true, round_tarot_generation = true, round_stone_card = true,
		round_sealed_card = true,
	})) do
		local key, effect = entry.slot, entry.effect
		if effect.kind == "round_joker_generation" then
			generators = generators + (effect.count or 2)
		elseif effect.kind == "round_tarot_generation" then
			tarot_generators = tarot_generators + (effect.count or 1)
		elseif effect.kind == "round_stone_card" then
			local stream = state.rng:fork(table.concat({
				"marble", key, tostring(state.ante), tostring(state.round), tostring(round_name),
			}, ":"))
			for generated = 1, effect.count or 1 do
				local card = {
					suit = state.Cards.suits[stream:integer(1, #state.Cards.suits)],
					rank = stream:integer(2, 14), enhancement = "m_stone",
				}
				state.Cards.refresh(card, ":marble:" .. state.ante .. ":" .. state.round .. ":" .. generated
					.. (entry.copy and (":" .. key) or ""))
				state.deck[#state.deck + 1] = card
				state.cards_added = state.cards_added + 1
				adjust_owned_jokers(state, "deck_add_scaling_xmult", 1)
				record_decision(state, {
					type = "create_playing_card", key = key, enhancement = "m_stone",
					ante = state.ante, round = state.current_round or state.round,
				})
			end
		elseif effect and effect.kind == "round_sealed_card" then
			local stream = state.rng:fork(table.concat({
				"certificate", key, tostring(state.ante), tostring(state.round), tostring(round_name),
			}, ":"))
			local seals = { "Blue", "Gold", "Purple", "Red" }
			for generated = 1, effect.count or 1 do
				local card = {
					suit = state.Cards.suits[stream:integer(1, #state.Cards.suits)],
					rank = stream:integer(2, 14), seal = seals[stream:integer(1, #seals)],
				}
				state.Cards.refresh(card, ":certificate:" .. state.ante .. ":" .. state.round .. ":" .. generated
					.. (entry.copy and (":" .. key) or ""))
				state.deck[#state.deck + 1] = card
				state.cards_added = state.cards_added + 1
				adjust_owned_jokers(state, "deck_add_scaling_xmult", 1)
				record_decision(state, { type = "create_playing_card", key = key, seal = card.seal,
					ante = state.ante, round = state.current_round or state.round })
			end
		end
	end
	for generated = 1, tarot_generators do
		if #(state.consumables or {}) >= (state.consumable_limit or 2) then break end
		local eligible = {}
		for _, tool in ipairs(state.deck_tools or {}) do
			local duplicate = false
			for _, held in ipairs(state.consumables or {}) do
				if held.key == tool.key then duplicate = true; break end
			end
			if tool.set == "Tarot" and not duplicate and tool.effect ~= "repeat_consumable" then
				eligible[#eligible + 1] = tool
			end
		end
		if #eligible == 0 then break end
		local stream = state.rng:fork(string.format(
			"cartomancer:%s:%s:%s", tostring(state.ante), tostring(state.round), tostring(generated)
		))
		local choice = copy_map(eligible[stream:integer(1, #eligible)])
		choice.type = "deck_tool"
		state.consumables[#state.consumables + 1] = choice
		record_decision(state, {
			type = "create_consumable", key = choice.key, source = "j_cartomancer",
			ante = state.ante, round = state.current_round or state.round,
		})
	end
	for generated = 1, generators do
		if #state.jokers >= state.joker_limit then break end
		local stream = state.rng:fork(string.format(
			"riff_raff:%s:%s:%s", tostring(state.ante), tostring(state.round), tostring(generated)
		))
		-- a Common Joker as create_card makes it (unsupported
		-- Commons take their share; an edition is rolled).
		local key, edition = roll_vanilla_joker(state, stream, nil, 1)
		local choice
		for _, candidate in ipairs(state.joker_pool or {}) do
			if candidate.key == key and joker_available(state, key) then choice = candidate; break end
		end
		if choice then
		state.jokers[#state.jokers + 1] = choice.key
		initialize_joker(state, choice.key)
		set_joker_edition(state, choice.key, edition)
		record_decision(state, {
			type = "create_joker", key = choice.key, source = "j_riff_raff",
			ante = state.ante, round = state.current_round or state.round,
		})
		end
	end
	pick_idol_card(state)   -- group B jokers
	if round_name == "PvP" then state.pending_opponent_sells = 0 end
end

local function apply_played_hand_income(state, result)
	-- To Do List and Business Card pay again for every
	-- Blueprint/Brainstorm copying them (no blueprint guard in card.lua); a copy
	-- of To Do List pays for the copied Joker's hand.
	-- Golden Ticket, Rough Gem, Reserved Parking and Seance have no blueprint
	-- guard either (card.lua calculate_joker individual / joker_main).
	for _, entry in ipairs(joker_slots(state, {
		played_hand_money = true, scoring_face_money = true, scoring_enhancement_money = true,
		scoring_suit_money = true, chance_xmult_money = true, held_face_money = true,
		straight_flush_spectral = true,
	})) do
		local key, effect = entry.slot, entry.effect
		if effect.kind == "played_hand_money" and state.joker_state[entry.key] == result.name then
			state.money = state.money + effect.amount
			record_decision(state, {
				type = "joker_income", key = key, value = effect.amount,
				hand = result.name, ante = state.ante, round = state.current_round or state.round,
			})
		elseif effect.kind == "scoring_enhancement_money" then
			local income = 0
			for _, card in ipairs(result.scoring_cards or {}) do
				if card.enhancement == effect.enhancement then
					-- group C jokers: Golden Ticket pays per trigger (context.individual).
					local triggers = effect.per_trigger and ((result.card_repetitions or {})[card] or 1) or 1
					income = income + (effect.amount or 4) * triggers
				end
			end
			state.money = state.money + income
			if income > 0 then record_decision(state, { type = "joker_income", key = key,
				value = income, ante = state.ante, round = state.current_round or state.round }) end
		elseif effect.kind == "scoring_suit_money" then
			local income = 0
			for _, card in ipairs(result.scoring_cards or {}) do
				if card.suit == effect.suit or card.enhancement == "m_wild" then
					income = income + (effect.amount or 1)
				end
			end
			state.money = state.money + income
			if income > 0 then record_decision(state, { type = "joker_income", key = key,
				value = income, ante = state.ante, round = state.current_round or state.round }) end
		elseif effect.kind == "chance_xmult_money" and not entry.copy then
			state.money = state.money + (effect.dollars or 0) / math.max(1, tonumber(effect.odds) or 4)
		elseif effect.kind == "held_face_money" then
			local income = 0
			local odds = math.max(1, (tonumber(effect.odds) or 2)
				/ (has_joker_kind(state, "double_probabilities") and 2 or 1))
			for index, card in ipairs(state.hand or {}) do
				if has_joker_kind(state, "all_faces") or (card.rank >= 11 and card.rank <= 13) then
					local stream = state.rng:fork(table.concat({ "reserved", key, state.ante,
						state.round, state.hands_played, index }, ":"))
					if stream:next() < 1 / odds then income = income + (effect.amount or 1) end
				end
			end
			state.money = state.money + income
			if income > 0 then record_decision(state, { type = "joker_income", key = key,
				value = income, ante = state.ante, round = state.current_round or state.round }) end
		elseif effect.kind == "straight_flush_spectral" and result.name == "Straight Flush" then
			generate_spectral(state, key, "straight_flush")
		elseif effect.kind == "scoring_face_money" then
			local income = 0
			local odds = math.max(1, (tonumber(effect.odds) or 2)
				/ (has_joker_kind(state, "double_probabilities") and 2 or 1))
			for index, card in ipairs(result.scoring_cards or {}) do
				if has_joker_kind(state, "all_faces")
					or (card.enhancement ~= "m_stone" and card.rank >= 11 and card.rank <= 13) then
					for trigger = 1, (result.card_repetitions and result.card_repetitions[card]) or 1 do
						local stream = state.rng:fork(table.concat({
							"business", key, state.ante, state.round, state.hands_played, index,
						}, ":") .. (trigger > 1 and (":" .. trigger) or ""))
						if stream:integer(1, odds) == 1 then income = income + (effect.amount or 2) end
					end
				end
			end
			if income > 0 then
				state.money = state.money + income
				record_decision(state, {
					type = "joker_income", key = key, value = income,
					hand = result.name, ante = state.ante, round = state.current_round or state.round,
				})
			end
		end
	end
end

-- group C jokers: the Planet cards used this run, by key (G.GAME.consumeable_usage).
local function note_planet_used(state, key)
	if not key then return end
	state.planet_keys_used = state.planet_keys_used or {}
	state.planet_keys_used[key] = true
end

local function end_round_joker_income(state, result)
	local income = 0
	for _, key in ipairs(state.jokers) do
		local effect = state.joker_effects[key]
		if effect and effect.kind == "unique_planet_money" then
			-- group C jokers: Satellite (calculate_dollar_bonus).
			local unique = 0
			for _ in pairs(state.planet_keys_used or {}) do unique = unique + 1 end
			local amount = unique * (effect.amount or 1)
			income = income + amount
			if amount > 0 then
				record_decision(state, { type = "joker_income", key = key, value = amount,
					ante = state.ante, round = state.current_round or state.round })
			end
		end
		if effect and effect.kind == "deck_rank_money" then
			local count = 0
			for _, card in ipairs(state.deck) do
				if card.rank == effect.rank and card.enhancement ~= "m_stone" then count = count + 1 end
			end
			local amount = count * effect.amount
			income = income + amount
			if amount > 0 then
				record_decision(state, {
					type = "joker_income", key = key, value = amount,
					ante = state.ante, round = state.current_round or state.round,
				})
			end
		elseif effect and effect.kind == "round_money" then
			local amount = effect.amount or 0
			if effect.per_unused_discard then
				local unused = (result and result.discards_left) or 0
				local available = (result and result.discards_available) or state.discards_per_round or 0
				amount = (not effect.requires_no_discard or unused == available)
					and unused * effect.per_unused_discard or 0
			end
			income = income + amount
			if amount > 0 then
				record_decision(state, {
					type = "joker_income", key = key, value = amount,
					ante = state.ante, round = state.current_round or state.round,
				})
			end
		end
	end
	income = income + rocket_income(state)   -- group B jokers
	return income
end

local function create_levels()
	local levels = {}
	for _, name in ipairs(planet_names) do levels[name] = 1 end
	return levels
end

local function editionless_joker_slots(state)
	local slots = {}
	for index, key in ipairs(state.jokers or {}) do
		if not state.joker_editions[key] then slots[#slots + 1] = index end
	end
	return slots
end

-- can_use_consumeable (card.lua) for the Spectrals that need a Joker or more
-- than one card in hand; nil for every other consumable.
local function spectral_usable(state, consumable)
	if consumable.set ~= "Spectral" then return nil end
	local effect = consumable.effect
	if effect == "generate_joker" then return #state.jokers < state.joker_limit end
	if effect == "duplicate_joker" then
		return #state.jokers > 0 and state.joker_limit > 1 and #state.jokers < state.joker_limit
	end
	if effect == "polychrome_joker" or effect == "negative_joker" then
		return #editionless_joker_slots(state) > 0
	end
	if effect == "create_cards" or effect == "hand_suit" or effect == "hand_rank" then
		return #(state.deck or {}) >= math.max(2, tonumber(consumable.destroy_count) or 2)
	end
	return nil
end

-- a deck tool as a shop or pack offer
local function tool_offer(tool)
	local offer = copy_map(tool)
	offer.type = "deck_tool"
	return offer
end

local function consumable_sell_value(consumable)
	return math.max(1, math.floor((tonumber(consumable.cost) or 2) / 2))
end

local function consumable_available(state, key)
	if allows_duplicates(state) then return true end
	for _, consumable in ipairs(state.consumables or {}) do
		if consumable.key == key then return false end
	end
	return true
end

local install_joker

local function store_consumable(state, choice)
	if not consumable_available(state, choice.key) then return false end
	if #state.consumables >= state.consumable_limit then return false end
	local stored = copy_map(choice)
	stored.offer_index = nil
	stored.replace_consumable_index = nil
	stored.sell_consumable_key = nil
	stored.sell_consumable_value = nil
	state.consumables[#state.consumables + 1] = stored
	return true
end

local function remember_consumable(state, consumable)
	if consumable.key == "c_fool" then return end
	if consumable.type ~= "planet" and not (consumable.type == "deck_tool" and consumable.set == "Tarot") then return end
	state.last_consumable = copy_map(consumable)
end

-- Ankh and Hex destroy every Joker but the one in slot `keep` (card.lua
-- use_consumeable: start_dissolve, not a sale). Returns the kept key.
local function destroy_jokers_except(state, keep, source)
	local kept = state.jokers[keep]
	for index = #state.jokers, 1, -1 do
		if index ~= keep then
			local key = table.remove(state.jokers, index)
			-- a duplicate of the kept Joker shares its per-key state
			if key ~= kept then clear_joker(state, key) end
			record_decision(state, { type = "destroy_joker", key = key, source = source,
				ante = state.ante, round = state.current_round or state.round })
		end
	end
	return kept
end

local apply_consumable
apply_consumable = function(state, consumable, source)
	remember_consumable(state, consumable)
	if consumable.type == "planet" then
		state.levels[consumable.hand] = (state.levels[consumable.hand] or 1) + 1
		state.planets_used = state.planets_used + 1
		adjust_owned_jokers(state, "planet_scaling_xmult", 1)
		note_planet_used(state, consumable.key)
	elseif consumable.type == "deck_tool" then
		local stream = state.rng:fork(
			"held_consumable:" .. state.ante .. ":" .. state.round .. ":" .. consumable.key
			.. ":" .. tostring(state.consumables_used + 1)
		)
		if consumable.effect == "generate_tarot" then
			local eligible = {}
			for _, tool in ipairs(state.deck_tools or {}) do
				if tool.set == "Tarot" and tool.key ~= consumable.key
					and tool.effect ~= "generate_tarot" and tool.effect ~= "generate_planet"
					and tool.effect ~= "generate_joker" then eligible[#eligible + 1] = tool end
			end
			-- The Emperor / High Priestess create at most as many cards as there
			-- are free consumable slots, into those slots (card.lua use_consumeable).
			local room = math.max(0, (state.consumable_limit or 2) - #(state.consumables or {}))
			for index = 1, math.min(consumable.count or 2, #eligible, room) do
				local picked = table.remove(eligible, stream:integer(1, #eligible))
				if compat(state).use_created_cards then
					apply_deck_tool(state, picked, stream:fork("tarot:" .. index))
					remember_consumable(state, { type = "deck_tool", key = picked.key, set = picked.set,
						effect = picked.effect })
					state.tarots_used = state.tarots_used + 1
				else
					local created = copy_map(picked)
					created.type = "deck_tool"
					state.consumables[#state.consumables + 1] = created
					record_decision(state, {
						type = "create_consumable", key = created.key, source = consumable.key,
						ante = state.ante, round = state.current_round or state.round,
					})
				end
			end
		elseif consumable.effect == "generate_planet" then
			local eligible = {}
			for _, planet in ipairs(state.planet_pool or {}) do
				if planet_unlocked(state, planet) then eligible[#eligible + 1] = planet end
			end
			local room = math.max(0, (state.consumable_limit or 2) - #(state.consumables or {}))
			for _ = 1, math.min(consumable.count or 2, #eligible, room) do
				local picked = table.remove(eligible, stream:integer(1, #eligible))
				if compat(state).use_created_cards then
					state.levels[picked.hand] = (state.levels[picked.hand] or 1) + 1
					remember_consumable(state, { type = "planet", key = picked.key, hand = picked.hand })
					state.planets_used = state.planets_used + 1
					adjust_owned_jokers(state, "planet_scaling_xmult", 1)
					note_planet_used(state, picked.key)
				else
					state.consumables[#state.consumables + 1] = {
						type = "planet", key = picked.key, hand = picked.hand, cost = picked.cost,
					}
					record_decision(state, {
						type = "create_consumable", key = picked.key, source = consumable.key,
						ante = state.ante, round = state.current_round or state.round,
					})
				end
			end
		elseif consumable.effect == "generate_joker" then
			-- Judgement makes a Joker like the shop does
			-- (rarity 70/25/5, edition) and needs a free Joker slot (card.lua
			-- use_consumeable / can_use_consumeable).
			-- Wraith and The Soul force a Rare / Legendary Joker.
			if #state.jokers < state.joker_limit then
				local key, edition = roll_vanilla_joker(state, stream:fork("judgement"), nil, consumable.rarity)
				for _, joker in ipairs(state.joker_pool or {}) do
					if joker.key == key and joker_available(state, key) then
						local picked = copy_map(joker)
						picked.cost = 0
						picked.edition = edition
						install_joker(state, picked)
						break
					end
				end
			end
			-- Wraith then sets money to $0 (ease_dollars(-G.GAME.dollars)).
			if consumable.clear_money then state.money = 0 end
		elseif consumable.effect == "duplicate_joker" then
			-- Ankh: copies a random Joker and destroys all others; the copy
			-- loses Negative. Needs a free Joker slot (Card:check_use).
			if #state.jokers > 0 and #state.jokers < state.joker_limit then
				local kept = destroy_jokers_except(state, stream:integer(1, #state.jokers), consumable.key)
				state.jokers[#state.jokers + 1] = kept
			end
		elseif consumable.effect == "polychrome_joker" or consumable.effect == "negative_joker" then
			-- Hex: a random Joker without an edition becomes Polychrome and every
			-- other Joker is destroyed. Ectoplasm: it becomes Negative and the hand
			-- size drops by 1, then 2, 3... on later uses (G.GAME.ecto_minus).
			local slots = editionless_joker_slots(state)
			if #slots > 0 then
				local slot = slots[stream:integer(1, #slots)]
				local key = state.jokers[slot]
				if consumable.effect == "polychrome_joker" then
					set_joker_edition(state, key, "polychrome")
					destroy_jokers_except(state, slot, consumable.key)
				else
					set_joker_edition(state, key, "negative")
					state.ecto_minus = state.ecto_minus or 1
					state.hand_size_bonus = (state.hand_size_bonus or 0) - state.ecto_minus
					state.ecto_minus = state.ecto_minus + 1
				end
			end
		elseif consumable.effect == "repeat_consumable" then
			local repeated = state.last_consumable
			if not repeated or not apply_consumable(state, copy_map(repeated), "fool") then return false end
		else
			apply_deck_tool(state, consumable, stream)   -- target_step
		end
		if consumable.set == "Tarot" then state.tarots_used = state.tarots_used + 1 end
	else
		return false
	end
	state.consumables_used = state.consumables_used + 1
	record_decision(state, {
		type = "use_consumable", key = consumable.key, source = source,
		chosen = "use:" .. tostring(consumable.key),
		ante = state.ante, round = state.current_round or state.round,
	})
	return true
end

-- Hook consumable_step: when held consumables are used or sold. Whether a
-- held consumable can be used right now under the simulator's (deck-wide)
-- rules (card.lua can_use_consumeable).
local function consumable_usable(state, consumable)
	if consumable.type == "planet" then return true end
	if consumable.type ~= "deck_tool" then return false end
	if consumable.effect == "repeat_consumable" then return state.last_consumable ~= nil end
	local spectral_rule = spectral_usable(state, consumable)
	if spectral_rule ~= nil then return spectral_rule end
	if consumable.effect == "generate_joker" then
		-- Judgement needs a free Joker slot
		return #state.jokers < state.joker_limit or compat(state).judgement_without_slot == true
	end
	return true
end

-- Buy and Use (G.FUNCS.can_buy_and_use): a Tarot, Planet or Spectral offer can
-- be bought and used at once when it is affordable and Card:can_use_consumeable
-- allows it in the shop. The card never enters the consumable slots, so they
-- may be full. No card is in hand in the shop, so a card that targets hand
-- cards cannot be used there (Aura, Cryptid, the enhancement, suit and seal
-- cards, Familiar, Sigil, Ouija...).
local function buy_and_use_ready(state, offer)
	if offer.type == "planet" then return true end
	if offer.type ~= "deck_tool" then return false end
	local effect = offer.effect
	if effect == "money" or effect == "level_all_hands" or effect == "pvp_attack" then
		return true   -- The Hermit, Temperance, Black Hole, Asteroid
	end
	if effect == "edition" then   -- The Wheel of Fortune: a Joker without an edition
		return offer.key == "c_wheel_of_fortune" and #editionless_joker_slots(state) > 0
	end
	local room = #state.consumables < state.consumable_limit
	if effect == "generate_tarot" or effect == "generate_planet" then return room end   -- Emperor, High Priestess
	if effect == "repeat_consumable" then return room and state.last_consumable ~= nil end   -- The Fool
	if effect == "generate_joker" then return #state.jokers < state.joker_limit end   -- Judgement, Wraith, The Soul
	if effect == "duplicate_joker" or effect == "polychrome_joker" or effect == "negative_joker" then
		return spectral_usable(state, offer) == true   -- Ankh, Hex, Ectoplasm
	end
	return false
end

-- A Buy and Use purchase: the bought card is used at once, after it is paid
-- (button_callbacks.lua buy_from_shop, id 'buy_and_use': G.FUNCS.use_card).
local function use_bought_consumable(state, choice)
	local card = copy_map(choice)
	card.offer_index, card.use_now = nil, nil
	return apply_consumable(state, card, "buy_and_use")
end

-- Actions of a consumable step: done, use k (usable, k ascending), sell k.
local function consumable_actions(state, actions)
	actions = actions or { { type = "done" } }
	for index, consumable in ipairs(state.consumables) do
		if consumable_usable(state, consumable) then
			actions[#actions + 1] = { type = "use", index = index, key = consumable.key }
		end
	end
	for index, consumable in ipairs(state.consumables) do
		actions[#actions + 1] = { type = "sell_consumable", index = index, key = consumable.key,
			value = consumable_sell_value(consumable) }
	end
	return actions
end

local function find_action(actions, kind, index)
	for position, action in ipairs(actions) do
		if action.type == kind and action.index == index then return position end
	end
	return nil
end

local function sell_consumable(state, index, source)
	local sold = table.remove(state.consumables, index)
	release_consumable(state, sold)   -- group B jokers
	local value = consumable_sell_value(sold)
	state.money = state.money + value
	note_card_sold(state)   -- Campfire
	record_decision(state, {
		type = "sell_consumable", key = sold.key, value = value, ante = state.ante, round = state.round,
		source = source,
	})
end

-- Executor of a use/sell_consumable action (consumable_step and shop_step).
local function run_consumable_action(state, action, source)
	if action.type == "use" then
		local consumable = table.remove(state.consumables, action.index)
		release_consumable(state, consumable)   -- group B jokers
		apply_consumable(state, consumable, source)
	elseif action.type == "sell_consumable" then
		sell_consumable(state, action.index, source)
	end
end

-- Replaces use_held_consumables(state, source): sources "shop_start",
-- "blind_start" and "cartomancer".
local function consumable_phase(state, source)
	if #state.consumables == 0 then return end
	local session = {}
	for _ = 1, 2 * #state.consumables + 1 do
		if #state.consumables == 0 then break end   -- nothing left to decide
		local ctx = { source = source, session = session, consumables = state.consumables,
			actions = consumable_actions(state) }
		local index = decide(state, "consumable_step", ctx, 1)
		local action = ctx.actions[index]
		if not action then error("consumable_step returned an invalid action index " .. tostring(index)) end
		if action.type == "done" then break end
		run_consumable_action(state, action, source)
	end
end

local function use_held_consumables(state, source)
	return consumable_phase(state, source)
end

local function shop_stream(state, label)
	if state.the_order then
		state.shop_index = state.shop_index + 1
		return state.rng:fork("ordered_shop:" .. state.shop_index .. ":" .. label)
	end
	return state.rng:fork("shop:" .. state.ante .. ":" .. state.round .. ":" .. label)
end

-- The shop's next purchase-decision stream, for whichever policy decides
-- (without advancing anything). Under The Order the shop counter also numbers
-- these decision draws; the simulator advances it when the decision is carried
-- out (count_shop_decision), so shop generation depends only on what was done
-- in the shop, never on which policy's code ran.
local function decision_stream(state, label)
	if state.the_order then
		return state.rng:fork("ordered_shop:" .. (state.shop_index + 1) .. ":" .. label)
	end
	return state.rng:fork("shop:" .. state.ante .. ":" .. state.round .. ":" .. label)
end

-- MultiBots' shop decision draws: one per purchase (except a free Negative
-- Joker, which is taken without a draw) and one for leaving a shop that still
-- has offers after fewer than 4 purchases.
local function count_shop_decision(state)
	if state.the_order then state.shop_index = state.shop_index + 1 end
end

local pack_offer

local function pack_spec(key)
	local family, size = tostring(key):match("^p_(%a+)_(%a+)_%d+$")
	if family ~= "celestial" and family ~= "buffoon" and family ~= "arcana"
		and family ~= "spectral" and family ~= "standard" then return nil end
	if size ~= "normal" and size ~= "jumbo" and size ~= "mega" then return nil end
	local small_choices = (family == "buffoon" or family == "spectral") and 2 or 3
	local large_choices = (family == "buffoon" or family == "spectral") and 4 or 5
	return {
		family = family, size = size,
		cost = size == "normal" and 4 or (size == "jumbo" and 6 or 8),
		choices = size == "normal" and small_choices or large_choices,
		picks = size == "mega" and 2 or 1,
	}
end

local function offer_for_key(state, key, instance)
	for _, joker in ipairs(state.joker_pool or {}) do
		if joker.key == key and not state.banned[key] and joker_available(state, key) then
			return {
				type = "joker", key = key, cost = joker.cost,
			}
		end
	end
	for _, planet in ipairs(state.planet_pool or {}) do
		if planet.key == key and consumable_available(state, key) then
			local hand = planet.hand
			return {
				type = "planet", key = key, hand = hand, cost = planet.cost,
			}
		end
	end
	-- Packs need their own decision path. In particular, Standard Packs must
	-- never fall through to the old direct "add a random card" shortcut.
	if pack_spec(key) then return pack_offer and pack_offer(state, key, instance) or nil end
	for _, tool in ipairs(state.deck_tools or {}) do
		if tool.key == key and consumable_available(state, key) then
			return tool_offer(tool)
		end
	end
	for _, voucher in ipairs(state.voucher_pool or {}) do
		if voucher.key == key and not has_value(state.vouchers, key) then
			local offer = copy_map(voucher)
			offer.type = "voucher"
			return offer
		end
	end
	if pack_offer then return pack_offer(state, key, instance) end
	return nil
end

local function apply_voucher(state, voucher)
	if has_value(state.vouchers, voucher.key) then return false end
	state.vouchers[#state.vouchers + 1] = voucher.key
	if voucher.effect == "hands" then
		state.hands_per_round = state.hands_per_round + (voucher.amount or 1)
	elseif voucher.effect == "consumable_slots" then
		state.consumable_limit = state.consumable_limit + (voucher.amount or 1)
	elseif voucher.effect == "shop_slots" then
		state.shop_slots = state.shop_slots + (voucher.amount or 1)
	elseif voucher.effect == "hand_size" then
		state.hand_size_bonus = state.hand_size_bonus + (voucher.amount or 1)
	elseif voucher.effect == "interest_cap" then
		state.interest_cap = math.max(state.interest_cap or 5, voucher.amount or 10)
	elseif voucher.effect == "planet_rate" then
		state.planet_rate = (state.planet_rate or 1) * (voucher.amount or 2)
	elseif voucher.effect == "tarot_rate" then
		state.tarot_rate = (state.tarot_rate or 1) * (voucher.amount or 2.4)
	elseif voucher.effect == "playing_cards_in_shop" then
		state.playing_cards_in_shop = true
	elseif voucher.effect == "reroll_discount" then
		state.reroll_discount = (state.reroll_discount or 0) + (voucher.amount or 2)
	elseif voucher.effect == "shop_discount" then
		state.shop_discount = math.max(state.shop_discount or 0, voucher.amount or 25)
	elseif voucher.effect == "discards" then
		state.discards_per_round = state.discards_per_round + (voucher.amount or 1)
	elseif voucher.effect == "edition_rate" then
		state.edition_rate = math.max(state.edition_rate or 1, voucher.amount or 2)
	elseif voucher.effect == "joker_slots" then
		state.joker_limit = state.joker_limit + (voucher.amount or 1)   -- Antimatter
	elseif voucher.effect == "celestial_target" then
		-- Presence in state.vouchers is the Telescope flag used when packs open.
	elseif voucher.effect == "arcana_spectral_chance" then
		-- Presence in state.vouchers controls Arcana generation below.
	end
	return true
end


local function random_joker(pool, stream)
	-- Legendary Jokers never appear in a shop (only The Soul creates them).
	local rarity_rates = { [1] = 0.70, [2] = 0.25, [3] = 0.05, [4] = 0 }
	local total = 0
	for _, joker in ipairs(pool) do total = total + (rarity_rates[inferred_rarity(joker)] or 0.05) end
	local roll = stream:next() * total
	for _, joker in ipairs(pool) do
		roll = roll - (rarity_rates[inferred_rarity(joker)] or 0.05)
		if roll <= 0 then return joker end
	end
	return pool[#pool]
end

local function sample_unique(pool, count, stream)
	local available, result = {}, {}
	for _, item in ipairs(pool or {}) do available[#available + 1] = item end
	for _ = 1, math.min(count, #available) do
		local index = stream:integer(1, #available)
		result[#result + 1] = table.remove(available, index)
	end
	return result
end

local function random_standard_card(state, stream, index)
	local card = {
		suit = state.Cards.suits[stream:integer(1, #state.Cards.suits)],
		rank = stream:integer(2, 14),
	}
	if stream:next() < 0.40 then card.enhancement = standard_enhancements[stream:integer(1, #standard_enhancements)] end
	card.edition = poll_edition(stream, false, 2, state.edition_rate)
	if stream:next() < 0.20 then card.seal = seals[stream:integer(1, #seals)] end
	return {
		type = "playing_card",
		key = "standard_card_" .. tostring(index) .. "_" .. tostring(card.rank) .. "_" .. tostring(card.suit),
		card = card, cost = 0,
	}
end

-- Telescope: the Planet of the most played hand (none before a hand is played),
-- secret hands included once played; a tie goes to the stronger hand
-- (G.handlist order, Celestial Pack create_card).
local function telescope_planet(state)
	if not has_value(state.vouchers or {}, "v_telescope") then return nil end
	local preferred
	local best_count = 0
	for _, hand in ipairs(hand_list) do
		local count = (state.hand_usage and state.hand_usage[hand]) or 0
		if count > best_count then preferred, best_count = hand, count end
	end
	if not preferred then return nil end
	for _, planet in ipairs(state.planet_pool or {}) do
		if planet.hand == preferred then return planet end
	end
	return nil
end

local function guarantee_telescope_planet(state, raw, choices)
	local guaranteed = telescope_planet(state)
	if not guaranteed then return raw end
	for _, item in ipairs(raw) do if item.key == guaranteed.key then return raw end end
	if #raw >= (choices or 1) then raw[#raw] = guaranteed else raw[#raw + 1] = guaranteed end
	return raw
end

local function pack_candidates(state, key, spec, instance)
	local stream = state.rng:fork("pack_contents:" .. state.ante .. ":" .. state.round .. ":" .. key
		.. ":" .. tostring(instance or 1))
	local raw = {}
	if spec.family == "celestial" then
		local eligible = {}
		for _, planet in ipairs(state.planet_pool) do
			if consumable_available(state, planet.key) and planet_unlocked(state, planet) then
				eligible[#eligible + 1] = planet
			end
		end
		raw = guarantee_telescope_planet(state, sample_unique(eligible, spec.choices, stream), spec.choices)
	elseif spec.family == "buffoon" then
		-- each card like a shop Joker (roll_vanilla_joker),
		-- with its edition; unsupported Jokers leave their card out.
		local taken = {}
		for index = 1, spec.choices do
			local key, edition = roll_vanilla_joker(state, stream:fork("buffoon:" .. index), taken)
			taken[key] = true
			for _, joker in ipairs(state.joker_pool or {}) do
				if joker.key == key and not state.banned[key] and joker_available(state, key) then
					local entry = copy_map(joker)
					entry.edition = edition
					raw[#raw + 1] = entry
					break
				end
			end
		end
	elseif spec.family == "arcana" or spec.family == "spectral" then
		local tarot, spectral = {}, {}
		for _, tool in ipairs(state.deck_tools) do
			if consumable_available(state, tool.key) then
				if tool.set == "Tarot" then tarot[#tarot + 1] = tool end
				if tool.set == "Spectral" then spectral[#spectral + 1] = tool end
			end
		end
		-- Spectral cards come from all 16 vanilla Spectrals;
		-- the ones the headless run does not simulate leave their card out, as
		-- unsupported cards of a live pack do (ordered_pack_candidates).
		local supported_spectral, spectral_keys = {}, {}
		for _, tool in ipairs(spectral) do supported_spectral[tool.key] = tool end
		for _, key in ipairs(vanilla_spectrals) do
			if consumable_available(state, key) then spectral_keys[#spectral_keys + 1] = key end
		end
		local function draw_spectral()
			if #spectral_keys == 0 then return nil end
			local key = table.remove(spectral_keys, stream:integer(1, #spectral_keys))
			return supported_spectral[key]
		end
		if spec.family == "arcana" and has_value(state.vouchers or {}, "v_omen_globe") then
			for _ = 1, spec.choices do
				if stream:next() < 0.2 then
					raw[#raw + 1] = draw_spectral()
				elseif #tarot > 0 then
					raw[#raw + 1] = table.remove(tarot, stream:integer(1, #tarot))
				end
			end
		elseif spec.family == "arcana" then
			raw = sample_unique(tarot, spec.choices, stream)
		else
			for _ = 1, spec.choices do raw[#raw + 1] = draw_spectral() end
		end
	elseif spec.family == "standard" then
		for index = 1, spec.choices do raw[#raw + 1] = random_standard_card(state, stream, index) end
	end
	-- create_card with `soulable` (common_events.lua): each card of an Arcana or
	-- Spectral Pack is The Soul with a 0.3% roll, each card of a Celestial or
	-- Spectral Pack Black Hole. Its own stream keeps the other draws unchanged.
	if spec.family == "arcana" or spec.family == "celestial" or spec.family == "spectral" then
		local hidden = {}
		for _, tool in ipairs(state.deck_tools or {}) do
			if tool.hidden and consumable_available(state, tool.key) then hidden[tool.key] = tool end
		end
		local soul_stream = state.rng:fork("pack_soul:" .. state.ante .. ":" .. state.round .. ":" .. key
			.. ":" .. tostring(instance or 1))
		for index = 1, spec.choices do
			local forced
			if spec.family ~= "celestial" and soul_stream:next() > 0.997 then forced = hidden.c_soul or forced end
			if spec.family ~= "arcana" and soul_stream:next() > 0.997 then forced = hidden.c_black_hole or forced end
			if forced then
				hidden[forced.key] = nil
				raw[math.min(index, #raw + 1)] = forced
			end
		end
	end

	local candidates = {}
	for _, item in ipairs(raw) do
		if spec.family == "celestial" and not item.set then
			candidates[#candidates + 1] = {
				type = "planet", key = item.key, hand = item.hand, cost = 0,
			}
		elseif spec.family == "buffoon" then
			candidates[#candidates + 1] = {
				type = "joker", key = item.key, cost = 0, edition = item.edition,
			}
		elseif spec.family == "standard" then
			candidates[#candidates + 1] = item
		else
			local candidate = tool_offer(item)
			candidate.cost = 0
			candidates[#candidates + 1] = candidate
		end
	end
	return candidates, stream
end


local function ordered_pack_candidates(state, descriptors)
	local candidates = {}
	for index, descriptor in ipairs(descriptors or {}) do
		if descriptor.kind == "playing_card" and descriptor.suit and descriptor.rank then
			local card = {
				suit = descriptor.suit, rank = tonumber(descriptor.rank),
				enhancement = descriptor.enhancement,
				edition = descriptor.edition, seal = descriptor.seal,
			}
			candidates[#candidates + 1] = {
				type = "playing_card",
				key = "ordered_standard_" .. tostring(index),
				card = card, cost = 0,
			}
		elseif descriptor.kind == "center" and descriptor.key then
			local key, candidate = descriptor.key
			for _, planet in ipairs(state.planet_pool or {}) do
				if planet.key == key then
					candidate = {
						type = "planet", key = key, hand = planet.hand, cost = 0,
					}
					break
				end
			end
			if not candidate then
				for _, joker in ipairs(state.joker_pool or {}) do
					if joker.key == key and not state.banned[key] and joker_available(state, key) then
						candidate = {
							type = "joker", key = key, cost = 0, edition = descriptor.edition,
						}
						break
					end
				end
			end
			if not candidate then
				for _, tool in ipairs(state.deck_tools or {}) do
					if tool.key == key then
						candidate = tool_offer(tool)
						candidate.cost = 0
						break
					end
				end
			end
			if candidate then candidates[#candidates + 1] = candidate end
		end
	end
	return candidates
end

pack_offer = function(state, key, instance)
	local spec = pack_spec(key)
	if not spec then return nil end
	-- In a live Order game, decide whether to buy from the visible pack type and
	-- expected value. The contents stay unknown until apply_pack runs after the
	-- cost is paid, just like opening a real Booster.
	if state.strict_order_content then
		return {
			type = "pack", key = key, cost = spec.cost,
			family = spec.family, picks = spec.picks, instance = instance or 1,
			ordered_unopened = true,
		}
	end
	-- a Booster's cards are unknown until it is bought and
	-- opened, in every game. The headless shop offers it unopened, like the live
	-- path above, and apply_pack draws its cards (pack_candidates) when opened.
	if not state.legacy_shop then
		return {
			type = "pack", key = key, cost = spec.cost,
			family = spec.family, picks = spec.picks, instance = instance or 1,
			headless_unopened = true,
		}
	end
	-- legacy_shop (MultiBots' old shop model): a pack is offered opened, with
	-- the policy's picks (legacy_pack_step: { pack, contents, stream } -> the
	-- picked contents), and only when it picks something.
	local candidates, stream = pack_candidates(state, key, spec, instance)
	if #candidates == 0 then return nil end
	local pack = {
		type = "pack", key = key, cost = spec.cost, family = spec.family, contents = candidates,
		picks = spec.picks, instance = instance or 1,
	}
	pack.selected = decide(state, "legacy_pack_step", { pack = pack, contents = candidates, stream = stream }, nil)
	if not pack.selected or #pack.selected == 0 then return nil end
	return pack
end

-- the replacement block shared by the pack_step compound "take + sell joker"
-- (same order of effects and log entry as the old install_joker).
local function replace_joker_in_place(state, index, choice)
	local key = state.jokers[index]
	local sell_value = joker_sell_value(state, key)
	state.money = state.money + sell_value
	note_joker_sold(state, key, true)
	clear_joker(state, key)
	state.jokers[index] = choice.key
	initialize_joker(state, choice.key)
	set_joker_edition(state, choice.key, choice.edition)
	record_decision(state, {
		type = "sell_joker", key = key, value = sell_value,
		ante = state.ante, round = state.round, source = "buffoon_pack",
	})
end

-- A Joker goes into a free slot (a Negative brings its own); never an
-- automatic sale.
install_joker = function(state, choice)
	if not joker_available(state, choice.key) then return false end
	if #state.jokers < state.joker_limit or choice.edition == "negative" then
		state.jokers[#state.jokers + 1] = choice.key
		initialize_joker(state, choice.key)
		set_joker_edition(state, choice.key, choice.edition)
		return true
	end
	return false
end

-- Hook pack_step: an external policy can override Booster Pack picks. Actions: skip, take c (legal contents),
-- then take c + sell joker j (joker contents when the slots are full, j not
-- Negative). Contents already taken in this pack are not listed again.
local function pack_actions(state, contents, taken)
	local actions, compounds = { { type = "skip" } }, {}
	for index, item in ipairs(contents) do
		if not taken[index] then
			local take = { type = "take", index = index, key = item.key }
			if item.type == "joker" then
				if joker_available(state, item.key) then
					if #state.jokers < state.joker_limit or item.edition == "negative" then
						actions[#actions + 1] = take
					else
						for slot, key in ipairs(state.jokers) do
							if state.joker_editions[key] ~= "negative" then
								compounds[#compounds + 1] = {
									type = "take", index = index, key = item.key,
									sell_joker = slot, sell_key = key, sell_value = joker_sell_value(state, key),
								}
							end
						end
					end
				end
			elseif item.type == "planet" then
				actions[#actions + 1] = take
			elseif item.type == "deck_tool" then
				if consumable_usable(state, item) then actions[#actions + 1] = take end
			elseif item.type == "playing_card" and item.card then
				actions[#actions + 1] = take
			end
		end
	end
	for _, action in ipairs(compounds) do actions[#actions + 1] = action end
	return actions
end

local function find_take(actions, index, sell_joker)
	for position, action in ipairs(actions) do
		if action.type == "take" and action.index == index and action.sell_joker == sell_joker then return position end
	end
	return nil
end

local function apply_pack(state, pack)
	local picked = {}
	if pack.ordered_unopened then
		local descriptors = state.Order and state.Order.generate_pack
			and state.Order.generate_pack(state, pack.key) or nil
		pack.revealed = {}
		for _, descriptor in ipairs(descriptors or {}) do
			if descriptor.kind == "center" then
				pack.revealed[#pack.revealed + 1] = tostring(descriptor.key or "unknown")
			elseif descriptor.kind == "playing_card" then
				pack.revealed[#pack.revealed + 1] = table.concat({
					tostring(descriptor.suit or "?"), tostring(descriptor.rank or "?"),
					tostring(descriptor.enhancement or "none"), tostring(descriptor.edition or "none"),
					tostring(descriptor.seal or "none"),
				}, "-")
			end
		end
		pack.contents = ordered_pack_candidates(state, descriptors)
		if pack.family == "celestial" then
			local guaranteed = telescope_planet(state)
			if guaranteed then
				local found = false
				for _, candidate in ipairs(pack.contents) do
					if candidate.key == guaranteed.key then found = true; break end
				end
				if not found then
					local candidate = {
						type = "planet", key = guaranteed.key, hand = guaranteed.hand, cost = 0,
					}
					if #pack.contents > 0 then pack.contents[#pack.contents] = candidate
					else pack.contents[1] = candidate end
				end
			end
		end
		pack.modeled = {}
		for _, candidate in ipairs(pack.contents or {}) do pack.modeled[#pack.modeled + 1] = tostring(candidate.key) end
	end
	if pack.headless_unopened then
		-- open a headless Booster (see pack_offer).
		local spec = pack_spec(pack.key)
		local candidates = pack_candidates(state, pack.key, spec, pack.instance)
		pack.contents = candidates
		pack.modeled = {}
		for _, candidate in ipairs(candidates) do pack.modeled[#pack.modeled + 1] = tostring(candidate.key) end
	end
	-- a Blueprint/Brainstorm copying Hallucination rolls too
	-- (context.open_booster has no blueprint guard).
	for _, entry in ipairs(joker_slots(state, { pack_tarot_chance = true })) do
		local key, effect = entry.slot, entry.effect
		do
			local odds = math.max(1, tonumber(effect.odds) or 2)
			local stream = state.rng:fork(table.concat({
				"hallucination", key, tostring(state.ante), tostring(state.round),
				tostring(pack.key), tostring(pack.instance or 1),
			}, ":"))
			if stream:next() < 1 / odds then generate_tarot(state, key, pack.key) end
		end
	end
	-- Pack picks are optional. Never replace a rejected policy choice with the
	-- least-bad remaining card merely because the pack permits another pick.
	-- Hook pack_step, one decision per pick (see pack_actions).
	local contents = pack.contents or {}
	local session = { taken = {} }
	for _ = 1, #contents + 1 do
		if #picked >= (pack.picks or 1) then break end
		local ctx = {
			pack = pack, contents = contents, picks_left = (pack.picks or 1) - #picked, picked = picked,
			session = session, actions = pack_actions(state, contents, session.taken),
		}
		local index = decide(state, "pack_step", ctx, 1)
		local action = ctx.actions[index]
		if not action then error("pack_step returned an invalid action index " .. tostring(index)) end
		if action.type ~= "take" then break end
		session.taken[action.index] = true
		local choice = contents[action.index]
		local applied = false
		if choice.type == "planet" then
			state.levels[choice.hand] = (state.levels[choice.hand] or 1) + 1
			state.planets_used = state.planets_used + 1
			adjust_owned_jokers(state, "planet_scaling_xmult", 1)
			note_planet_used(state, choice.key)
			remember_consumable(state, choice)
			applied = true
		elseif choice.type == "joker" then
			if action.sell_joker then
				replace_joker_in_place(state, action.sell_joker, choice)
				applied = true
			else
				applied = install_joker(state, choice)
			end
		elseif choice.type == "deck_tool" then
			-- The Emperor, High Priestess and Judgement from a
			-- pack create their cards too (apply_deck_tool has no branch for them).
			if choice.effect == "repeat_consumable" or choice.effect == "pvp_attack"
				or choice.effect == "generate_tarot" or choice.effect == "generate_planet"
				or choice.effect == "generate_joker" or choice.effect == "duplicate_joker"
				or choice.effect == "polychrome_joker" or choice.effect == "negative_joker" then
				applied = apply_consumable(state, choice, "pack")
			else
				apply_deck_tool(state, choice, state.rng:fork("pack_use:" .. state.ante .. ":" .. state.round .. ":" .. choice.key))
				if choice.set == "Tarot" then state.tarots_used = state.tarots_used + 1 end
				remember_consumable(state, choice)
				applied = true
			end
		elseif choice.type == "playing_card" and choice.card then
			local card = copy_map(choice.card)
			state.Cards.refresh(card, ":standard:" .. state.ante .. ":" .. state.round .. ":" .. #state.deck)
			state.deck[#state.deck + 1] = card
			state.cards_added = state.cards_added + 1
			adjust_owned_jokers(state, "deck_add_scaling_xmult", 1)
			applied = true
		end
		if applied then picked[#picked + 1] = choice.key end
	end
	state.pack_history[pack.family] = state.pack_history[pack.family] or { opened = 0, picked = 0 }
	local history = state.pack_history[pack.family]
	history.opened = history.opened + 1
	if #picked > 0 then history.picked = history.picked + 1 end
	if #picked < (pack.picks or 1) then
		for _, key in ipairs(state.jokers or {}) do
			local effect = state.joker_effects[key]
			if effect and effect.kind == "skipped_pack_scaling_mult" then
				state.joker_state[key] = (state.joker_state[key] or effect.initial or 0)
					+ (effect.amount or 3)
			end
		end
	end
	return picked
end

local function shop_items_string(items)
	local out = {}
	for _, item in ipairs(items or {}) do
		out[#out + 1] = table.concat({
			tostring(item.key or "unknown"), tostring(item.type or "unknown"), tostring(item.cost or ""),
			tostring(item.edition or "none"),
		}, "~")
	end
	return #out > 0 and table.concat(out, ";") or "none"
end

-- the shop a headless run sees, built like the real one
-- (and like Order.generate_shop in a live game) instead of the old two mixed
-- slots that never offered Vouchers or any Booster but Standard Packs.
--   * main slots (2 + Overstock), type by G.GAME rates (game.lua: Joker 20,
--     Tarot 4, Planet 4, Spectral 2 with the Ghost Deck; UI_definitions.lua
--     create_card_for_shop); a Joker's rarity rolls 70/25/5 % first
--     (common_events.lua get_current_pool), its edition with poll_edition;
--   * two Booster Packs by their weights (game.lua P_CENTERS, get_pack), the
--     first shop of a run a Buffoon Pack (get_pack: first_shop_buffoon);
--   * the Ante's Voucher until it is bought (get_next_voucher_key, rolled
--     again each Ante).
-- A reroll (Simulator.pay_reroll) refreshes only the main slots, as the game's
-- reroll_shop does. Keys the headless run cannot simulate give no offer, exactly
-- as unsupported keys from the live game do.
local vanilla_boosters = {
	{ "p_arcana_normal_1", 1 }, { "p_arcana_normal_2", 1 }, { "p_arcana_normal_3", 1 }, { "p_arcana_normal_4", 1 },
	{ "p_arcana_jumbo_1", 1 }, { "p_arcana_jumbo_2", 1 }, { "p_arcana_mega_1", 0.25 }, { "p_arcana_mega_2", 0.25 },
	{ "p_celestial_normal_1", 1 }, { "p_celestial_normal_2", 1 }, { "p_celestial_normal_3", 1 },
	{ "p_celestial_normal_4", 1 }, { "p_celestial_jumbo_1", 1 }, { "p_celestial_jumbo_2", 1 },
	{ "p_celestial_mega_1", 0.25 }, { "p_celestial_mega_2", 0.25 },
	{ "p_spectral_normal_1", 0.3 }, { "p_spectral_normal_2", 0.3 }, { "p_spectral_jumbo_1", 0.3 },
	{ "p_spectral_mega_1", 0.07 },
	{ "p_standard_normal_1", 1 }, { "p_standard_normal_2", 1 }, { "p_standard_normal_3", 1 },
	{ "p_standard_normal_4", 1 }, { "p_standard_jumbo_1", 1 }, { "p_standard_jumbo_2", 1 },
	{ "p_standard_mega_1", 0.25 }, { "p_standard_mega_2", 0.25 },
	{ "p_buffoon_normal_1", 0.6 }, { "p_buffoon_normal_2", 0.6 }, { "p_buffoon_jumbo_1", 0.6 },
	{ "p_buffoon_mega_1", 0.15 },
}
-- Base Vouchers, each followed by the upgrade that requires it (game.lua).
local vanilla_vouchers = {
	{ "v_overstock_norm", "v_overstock_plus" }, { "v_clearance_sale", "v_liquidation" },
	{ "v_hone", "v_glow_up" }, { "v_reroll_surplus", "v_reroll_glut" },
	{ "v_crystal_ball", "v_omen_globe" }, { "v_telescope", "v_observatory" },
	{ "v_grabber", "v_nacho_tong" }, { "v_wasteful", "v_recyclomancy" },
	{ "v_tarot_merchant", "v_tarot_tycoon" }, { "v_planet_merchant", "v_planet_tycoon" },
	{ "v_seed_money", "v_money_tree" }, { "v_blank", "v_antimatter" },
	{ "v_magic_trick", "v_illusion" }, { "v_paint_brush", "v_palette" },
	-- Hieroglyph/Petroglyph and Director's Cut/Retcon are banned in Multiplayer
	-- Attrition (multiplayer gamemodes/attrition.lua banned_vouchers).
}

local function headless_shop_keys(state, reroll)
	local stream = shop_stream(state, reroll and "arena_reroll" or "arena_visit")
	local keys, metadata, taken = {}, {}, {}
	local function add(key, info)
		keys[#keys + 1] = key
		metadata[#keys] = info or {}
		taken[key] = true
	end
	local planet_weight = 4 * (tonumber(state.planet_rate) or 1)
	local spectral_weight = state.ghost_deck and 2 or 0
	local total = 20 + 4 + planet_weight + spectral_weight
	for slot = 1, state.shop_slots or 2 do
		local slot_stream = stream:fork("slot:" .. slot)
		local roll = slot_stream:next() * total
		if roll < 20 then
			local key, edition = roll_vanilla_joker(state, slot_stream, taken)
			add(key, { edition = edition })
		elseif roll < 24 then
			local eligible = {}
			for _, tool in ipairs(state.deck_tools or {}) do
				if tool.set == "Tarot" and not taken[tool.key] and consumable_available(state, tool.key) then
					eligible[#eligible + 1] = tool.key
				end
			end
			if #eligible > 0 then add(eligible[slot_stream:integer(1, #eligible)]) end
		elseif roll < 24 + planet_weight then
			local eligible = {}
			for _, planet in ipairs(state.planet_pool or {}) do
				if not taken[planet.key] and consumable_available(state, planet.key)
					and planet_unlocked(state, planet) then
					eligible[#eligible + 1] = planet.key
				end
			end
			if #eligible > 0 then add(eligible[slot_stream:integer(1, #eligible)]) end
		else
			local eligible = {}
			for _, key in ipairs(vanilla_spectrals) do
				if not taken[key] and consumable_available(state, key) then eligible[#eligible + 1] = key end
			end
			if #eligible > 0 then add(eligible[slot_stream:integer(1, #eligible)]) end
		end
	end
	if not reroll then
		for pack = 1, 2 do
			local key
			if not state.first_shop_buffoon then
				state.first_shop_buffoon = true
				key = "p_buffoon_normal_1"
			else
				local weight_total = 0
				for _, booster in ipairs(vanilla_boosters) do weight_total = weight_total + booster[2] end
				local poll = stream:fork("pack:" .. pack):next() * weight_total
				for _, booster in ipairs(vanilla_boosters) do
					poll = poll - booster[2]
					if poll <= 0 then key = booster[1]; break end
				end
				key = key or vanilla_boosters[#vanilla_boosters][1]
			end
			add(key)
		end
		if not state.ante_voucher or state.ante_voucher.ante ~= state.ante then
			local eligible = {}
			for _, pair in ipairs(vanilla_vouchers) do
				if not has_value(state.vouchers or {}, pair[1]) then
					eligible[#eligible + 1] = pair[1]
				elseif not has_value(state.vouchers or {}, pair[2]) then
					eligible[#eligible + 1] = pair[2]
				end
			end
			local voucher_stream = state.rng:fork("arena_voucher:" .. tostring(state.ante))
			state.ante_voucher = {
				ante = state.ante,
				key = #eligible > 0 and eligible[voucher_stream:integer(1, #eligible)] or nil,
			}
		end
		local voucher = state.ante_voucher.key
		if voucher and not has_value(state.vouchers or {}, voucher) then add(voucher) end
	end
	keys._metadata = metadata
	return keys
end

-- Hook shop_step: one atomic shop action per decision.
local SHOP_MAX_STEPS = 64
-- Not a game rule: only a guard against a policy that never stops rerolling
-- (every reroll costs $1 more, so money ends any real reroll chain first).
local REROLL_GUARD = 100

-- The prices before every shop decision: Astronomer makes Planets and
-- Celestial Packs free (card.lua Card:set_cost; idempotent).
local function refresh_offer_costs(state, offers)
	for _, offer in ipairs(offers) do
		if has_joker_kind(state, "free_planets")
			and (offer.type == "planet" or (offer.type == "pack" and offer.family == "celestial")) then
			offer.cost = 0
		end
		offer.cost = tonumber(offer.cost) or 0
	end
end

-- The legal shop actions in a fixed order: leave, reroll, per offer (buy, buy +
-- sell joker j, buy + sell consumable k, buy_and_use), sell joker j, sell
-- consumable k, use k.
-- Every legal action is listed.
local function shop_actions(state, session)
	local offers = session.offers
	local actions = { { type = "leave" } }
	local reroll_cost = Simulator.next_reroll_cost(state, state.shop_rerolls or 0)
	local debt = debt_limit(state)
	-- a reroll may go into debt like a purchase (can_reroll,
	-- functions/button_callbacks.lua:2077, checks dollars - bankrupt_at).
	if not state.shop_no_reroll and can_pay(state, reroll_cost, debt)
		and (state.shop_rerolls or 0) < REROLL_GUARD then
		actions[#actions + 1] = { type = "reroll", cost = reroll_cost }
	end
	local joker_values = {}
	for slot, key in ipairs(state.jokers) do joker_values[slot] = joker_sell_value(state, key) end
	local jokers_full = #state.jokers >= state.joker_limit
	local consumables_full = #state.consumables >= state.consumable_limit
	for offer_index, offer in ipairs(offers) do
		local cost = tonumber(offer.cost) or 0
		local function buy(extra)
			local action = {
				type = "buy", offer_index = offer_index, offer = offer, key = offer.key, item_type = offer.type,
				cost = cost,
			}
			for name, field in pairs(extra or {}) do action[name] = field end
			actions[#actions + 1] = action
		end
		local affordable = cost == 0 or cost <= state.money + debt
		if offer.type == "joker" then
			if joker_available(state, offer.key) then
				if (not jokers_full or offer.edition == "negative") and affordable then buy() end
				if jokers_full then
					for slot, key in ipairs(state.jokers) do
						-- the game sells first, then buys: the sale
						-- value counts and a sold Credit Card no longer allows debt
						-- (card.lua remove_from_deck :656, button_callbacks.lua can_buy :56).
						if state.joker_editions[key] ~= "negative"
							and (cost == 0 or cost <= state.money + joker_values[slot] + debt_limit(state, slot)) then
							buy({ sell_joker = slot, sell_key = key, sell_value = joker_values[slot] })
						end
					end
				end
			end
		elseif offer.type == "planet" or offer.type == "deck_tool" then
			if consumable_available(state, offer.key) then
				if not consumables_full and affordable then buy() end
				if consumables_full then
					for index, consumable in ipairs(state.consumables) do
						local sale = consumable_sell_value(consumable)
						if cost == 0 or cost <= state.money + sale + debt then
							buy({ sell_consumable = index, sell_key = consumable.key, sell_value = sale })
						end
					end
				end
			end
			-- Buy and Use, with or without a free consumable slot.
			if affordable and buy_and_use_ready(state, offer) then
				actions[#actions + 1] = { type = "buy_and_use", offer_index = offer_index, offer = offer,
					key = offer.key, item_type = offer.type, cost = cost }
			end
		elseif offer.type == "voucher" then
			if affordable and not has_value(state.vouchers, offer.key) then buy() end
		elseif offer.type == "pack" then   -- bought unopened; opening it runs pack_step
			if affordable then buy({ family = offer.family, picks = offer.picks }) end
		end
	end
	for slot, key in ipairs(state.jokers) do
		actions[#actions + 1] = { type = "sell_joker", index = slot, key = key, value = joker_values[slot] }
	end
	for index, consumable in ipairs(state.consumables) do
		actions[#actions + 1] = { type = "sell_consumable", index = index, key = consumable.key,
			value = consumable_sell_value(consumable) }
	end
	for index, consumable in ipairs(state.consumables) do
		if consumable_usable(state, consumable) then
			actions[#actions + 1] = { type = "use", index = index, key = consumable.key }
		end
	end
	return actions, reroll_cost
end

-- A Joker sale (shop_open, shop_step).
local function sell_joker(state, index, extra)
	local key = state.jokers[index]
	local sale = joker_sell_value(state, key)
	state.money = state.money + sale
	note_joker_sold(state, key)
	clear_joker(state, key)
	table.remove(state.jokers, index)
	local decision = { type = "sell_joker", key = key, value = sale, ante = state.ante, round = state.round, source = "shop" }
	for name, field in pairs(extra or {}) do decision[name] = field end
	record_decision(state, decision)
end

local function visit_shop(state, ordered_keys)
	-- rerolls paid since the last visit belong to this shop.
	if not state.shop_reroll_pending then state.shop_rerolls = 0 end
	-- Hook shop_open: Joker sales on entering the shop (e.g. of the Jokers the
	-- simulator cannot model).
	local unsupported = state.content_catalog and state.content_catalog.unsupported
		and state.content_catalog.unsupported.Joker
	local unsupported_keys = {}
	for _, key in ipairs(type(unsupported) == "table" and unsupported or {}) do unsupported_keys[key] = true end
	for _ = 1, #state.jokers + 1 do
		local ctx = { actions = { { type = "done" } } }
		for slot, key in ipairs(state.jokers) do
			ctx.actions[#ctx.actions + 1] = { type = "sell_joker", index = slot, key = key,
				value = joker_sell_value(state, key), unsupported = unsupported_keys[key] or nil }
		end
		local index = decide(state, "shop_open", ctx, 1)
		local action = ctx.actions[index]
		if not action then error("shop_open returned an invalid action index " .. tostring(index)) end
		if action.type == "done" then break end
		sell_joker(state, action.index, unsupported_keys[action.key]
			and { reason = "unsupported", round = state.current_round or state.round } or nil)
	end
	notify(state, "shop_open")
	use_held_consumables(state, "shop_start")
	-- without a live game's keys, build the real shop
	-- (headless_shop_keys); `legacy_shop` keeps MultiBots' old generator.
	local reroll = state.shop_reroll_pending == true
	state.shop_reroll_pending = nil
	-- a reroll replaces only the main card slots
	-- (functions/button_callbacks.lua reroll_shop :2872-2887 empties and refills
	-- G.shop_jokers only); the visit's unbought Booster Packs and Voucher stay.
	-- The reroll's keys (headless_shop_keys(state, true), or the live game's
	-- Order.generate_reroll) are main slots only, so the kept offers are added
	-- back here, after the new cards (the shop's layout).
	local kept_offers = reroll and state.shop_kept_offers or {}
	state.shop_kept_offers = nil
	if not ordered_keys and not state.legacy_shop then ordered_keys = headless_shop_keys(state, reroll) end
	local offers, supported_keys, tag_rewards = {}, {}, {}
	if ordered_keys then
		local occurrences = {}
		for ordered_index, key in ipairs(ordered_keys) do
			occurrences[key] = (occurrences[key] or 0) + 1
			local offer = offer_for_key(state, key, occurrences[key])
			if offer then
				local metadata = ordered_keys._metadata and ordered_keys._metadata[ordered_index]
				if offer.type == "joker" and metadata then
					offer.edition = metadata.edition
					offer.cost = (tonumber(offer.cost) or 0) + (edition_extra_cost[offer.edition] or 0)
				end
				-- Boosters and the Voucher are not main slots.
				if offer.type == "pack" or offer.type == "voucher" then offer.survives_reroll = true end
				offers[#offers + 1] = offer
				supported_keys[#supported_keys + 1] = key
			end
		end
		-- the kept Boosters and Voucher, repriced from their
		-- list price (a Clearance Sale bought before the reroll reprices every
		-- card, card.lua apply_to_run :1917-1921 set_cost).
		for _, offer in ipairs(kept_offers) do
			offer.cost = offer.list_cost or offer.cost
			offers[#offers + 1] = offer
			supported_keys[#supported_keys + 1] = offer.key
		end
	else
	local planet_multiplier = math.max(1, math.min(2, state.planet_rate or 1))
	local shop_rate_total = 0.55 + 0.23 * planet_multiplier + 0.22
	local joker_cutoff = 0.55 / shop_rate_total
	local planet_cutoff = (0.55 + 0.23 * planet_multiplier) / shop_rate_total
	for slot = 1, state.shop_slots or 2 do
		local stream = shop_stream(state, "slot:" .. slot)
		local roll = stream:next()
		local pool = state.joker_pool or {}
		if roll < joker_cutoff and #pool > 0 then
			local joker = random_joker(pool, stream)
			if not state.banned[joker.key] and joker_available(state, joker.key) then
				offers[#offers + 1] = {
					type = "joker",
					key = joker.key,
					cost = joker.cost,
				}
			end
		elseif roll < planet_cutoff and #state.planet_pool > 0 then
			local eligible = {}
			for _, planet in ipairs(state.planet_pool) do
				if consumable_available(state, planet.key) and planet_unlocked(state, planet) then
					eligible[#eligible + 1] = planet
				end
			end
			local planet = #eligible > 0 and eligible[stream:integer(1, #eligible)] or nil
			if planet then
			local hand = planet.hand
			offers[#offers + 1] = {
				type = "planet",
				key = planet.key,
				hand = hand,
				cost = planet.cost,
			}
			end
		elseif #state.deck_tools > 0 or #state.pack_pool > 0 then
			local eligible = {}
			for _, tool in ipairs(state.deck_tools) do
				if consumable_available(state, tool.key) and not tool.hidden
					and (not tool.spectral or state.ghost_deck or stream:next() < 0.2) then
					eligible[#eligible + 1] = tool
				end
			end
			for _, key in ipairs(state.pack_pool) do eligible[#eligible + 1] = { key = key, pack = true } end
			if #eligible > 0 then
				local tool = eligible[stream:integer(1, #eligible)]
				local offer = tool.pack and pack_offer(state, tool.key, slot) or tool_offer(tool)
				if offer then offers[#offers + 1] = offer end
			end
		end
	end
	end
	-- the price before the discount, for a kept offer's repricing.
	for _, offer in ipairs(offers) do
		if offer.survives_reroll and not offer.list_cost then offer.list_cost = tonumber(offer.cost) or 0 end
	end
	if (state.shop_discount or 0) > 0 then
		-- Card:set_cost discounts Vouchers too (card.lua).
		for _, offer in ipairs(offers) do
			offer.cost = math.max(1, math.floor(((tonumber(offer.cost) or 0) + 0.5)
				* (100 - state.shop_discount) / 100))
		end
	end
	local unresolved_rewards = {}
	for index, reward in ipairs(state.pending_tag_jokers or {}) do
		-- also in the headless shop, an edition Tag gives its
		-- edition to the next shop Joker without one and makes it free (tag.lua
		-- store_joker_modify) instead of adding a Joker.
		if (state.strict_order_content or not state.legacy_shop) and reward.edition then
			local modified
			for _, offer in ipairs(offers) do
				if offer.type == "joker" and not offer.edition then
					offer.edition = reward.edition
					offer.tag_reward = reward.tag
					-- Every edition Tag makes the affected shop Joker free. This is
					-- especially important for Negative: declining a free, slot-neutral
					-- Joker can never improve the current build.
					offer.cost = 0
					modified = offer
					break
				end
			end
			if modified then
				tag_rewards[#tag_rewards + 1] = reward.tag .. ":" .. modified.key
			else
				unresolved_rewards[#unresolved_rewards + 1] = reward
			end
		elseif not state.strict_order_content or reward.rarity then
			local offer = queued_tag_joker(state, reward, index)
			if offer then
				offers[#offers + 1] = offer
				tag_rewards[#tag_rewards + 1] = reward.tag .. ":" .. offer.key
			end
		end
	end
	state.pending_tag_jokers = unresolved_rewards
	if not ordered_keys then
		for _, offer in ipairs(offers) do supported_keys[#supported_keys + 1] = offer.key end
	end
	local all_offered_keys = copy_array(ordered_keys or {})
	-- the kept Boosters and Voucher are offered too.
	for _, offer in ipairs(kept_offers) do all_offered_keys[#all_offered_keys + 1] = offer.key end
	if #all_offered_keys == 0 then
		for _, offer in ipairs(offers) do all_offered_keys[#all_offered_keys + 1] = offer.key end
	end
	local all_evaluated = shop_items_string(offers)
	local shop_id = tostring(state.ante or "?") .. ":" .. tostring((state.shop_visits or 0) + 1)
	if #offers == 0 then
		record_decision(state, {
			type = "shop_decision", shop_id = shop_id, chosen = "skip",
			offered = table.concat(all_offered_keys, ","), supported = table.concat(supported_keys, ","),
			evaluated = "none", reserve_reason = "no_supported_offers",
			ante = state.ante, round = state.current_round or state.round,
		})
	end
	-- a decision's log entry plus the fields its policy logged with it (meta.log)
	local function log_with(decision, meta)
		for name, field in pairs(meta and meta.log or {}) do
			if decision[name] == nil then decision[name] = field end
		end
		record_decision(state, decision)
	end

	-- Hook shop_step: one decision per atomic action. session.bought lists this
	-- visit's purchases; policies may keep their own fields in it.
	local session = { purchases = 0, bought = {}, offers = offers, steps = 0 }
	local reroll_requested, requested_reroll_cost
	while session.steps < SHOP_MAX_STEPS do
		refresh_offer_costs(state, offers)
		local actions, reroll_cost = shop_actions(state, session)
		local ctx = {
			session = session, offers = offers, actions = actions, purchases = session.purchases,
			steps = session.steps, shop_rerolls = state.shop_rerolls or 0, reroll_cost = reroll_cost,
		}
		local index, meta = decide(state, "shop_step", ctx, 1)
		local action = actions[index]
		if not action then error("shop_step returned an invalid action index " .. tostring(index)) end
		session.steps = session.steps + 1
		if action.type == "leave" then
			if #offers > 0 and session.purchases < 4 then count_shop_decision(state) end
			if not (meta and meta.silent) then
				log_with({
					type = "shop_decision", shop_id = shop_id, chosen = "skip", offered = table.concat(all_offered_keys, ","),
					supported = table.concat(supported_keys, ","), evaluated = all_evaluated,
					ante = state.ante, round = state.current_round or state.round,
				}, meta)
			end
			break
		elseif action.type == "reroll" then
			reroll_requested, requested_reroll_cost = true, action.cost
			break
		elseif action.type == "buy" or action.type == "buy_and_use" then
			local choice = copy_map(offers[action.offer_index])
			choice.offer_index = action.offer_index
			choice.use_now = action.type == "buy_and_use" or nil
			if not (choice.type == "joker" and choice.edition == "negative" and choice.cost == 0) then
				count_shop_decision(state)
			end
			if action.sell_joker then
				choice.replace_index, choice.sell_key, choice.sell_value = action.sell_joker, action.sell_key, action.sell_value
			end
			if action.sell_consumable then
				choice.replace_consumable_index = action.sell_consumable
				choice.sell_consumable_key, choice.sell_consumable_value = action.sell_key, action.sell_value
			end
			log_with({
				type = "shop_decision", shop_id = shop_id,
				chosen = (choice.use_now and "buy_and_use_" or "buy_") .. tostring(choice.type) .. ":" .. tostring(choice.key),
				offered = table.concat(all_offered_keys, ","), supported = table.concat(supported_keys, ","),
				evaluated = all_evaluated, replacement = choice.sell_key or choice.sell_consumable_key,
				ante = state.ante, round = state.current_round or state.round,
			}, meta)
			table.remove(offers, choice.offer_index)
			if choice.replace_index then
				state.money = state.money + choice.sell_value
				note_joker_sold(state, choice.sell_key, true)
				record_decision(state, {
					type = "sell_joker",
					key = choice.sell_key,
					value = choice.sell_value,
					ante = state.ante,
					round = state.round,
				})
				clear_joker(state, choice.sell_key)
				state.jokers[choice.replace_index] = choice.key
				initialize_joker(state, choice.key)
				set_joker_edition(state, choice.key, choice.edition)
			end
			if choice.replace_consumable_index then
				local sold = table.remove(state.consumables, choice.replace_consumable_index)
				release_consumable(state, sold)   -- group B jokers
				state.money = state.money + choice.sell_consumable_value
				note_card_sold(state)   -- Campfire
				record_decision(state, {
					type = "sell_consumable", key = sold and sold.key or choice.sell_consumable_key,
					value = choice.sell_consumable_value, ante = state.ante, round = state.round,
				})
			end
			state.money = state.money - choice.cost
			if choice.use_now then
				-- Buy and Use: never stored, used once its purchase is recorded (below)
			elseif choice.type == "joker" then
				if not choice.replace_index then
					state.jokers[#state.jokers + 1] = choice.key
					initialize_joker(state, choice.key)
					set_joker_edition(state, choice.key, choice.edition)
				end
			elseif choice.type == "planet" then
				store_consumable(state, choice)
			elseif choice.type == "pack" then
				choice.picked = apply_pack(state, choice)
			elseif choice.type == "voucher" then
				apply_voucher(state, choice)
			else
				store_consumable(state, choice)
			end
			record_decision(state, {
				type = "buy_" .. choice.type,
				key = choice.key,
				picked = choice.picked and table.concat(choice.picked, ",") or nil,
				revealed = choice.revealed and table.concat(choice.revealed, ",") or nil,
				modeled = choice.modeled and table.concat(choice.modeled, ",") or nil,
				supported = choice.type == "pack" and supported_pack_content(state, choice.key) or nil,
				source = choice.tag_reward,
				ante = state.ante,
				round = state.round,
			})
			if choice.use_now then use_bought_consumable(state, choice) end
			session.purchases = session.purchases + 1
			session.bought[#session.bought + 1] = choice
			notify(state, "shop_buy", choice)
		elseif action.type == "sell_joker" then
			sell_joker(state, action.index)
			notify(state, "shop_sell", action)
		else   -- sell_consumable / use
			run_consumable_action(state, action, "shop")
			if action.type == "sell_consumable" then notify(state, "shop_sell", action) end
		end
	end
	if not reroll_requested then shop_end_jokers(state) end   -- group B jokers
	-- what a reroll of this shop keeps (see kept_offers).
	state.shop_kept_offers = {}
	for _, offer in ipairs(offers) do
		if offer.survives_reroll then state.shop_kept_offers[#state.shop_kept_offers + 1] = offer end
	end
	-- Hook arrange_jokers (leaving the shop).
	arrange_jokers(state, "shop")
	state.shop_visits = (state.shop_visits or 0) + 1
	notify(state, "shop_end")
	return {
		keys = copy_array(ordered_keys or {}),
		supported_keys = supported_keys,
		evaluated = all_evaluated,
		purchases = session.purchases,
		money = state.money,
		reroll_requested = reroll_requested,   -- shop_step chose "reroll"
		reroll_cost = requested_reroll_cost,
		tag_rewards = tag_rewards,
	}
end

-- vanilla Jokers group A: round and hand rules.
-- A playing card created during a round goes into the deck and the hand
-- (playing_card_joker_effects: Hologram).
local function add_round_card(state, card, source)
	state.deck[#state.deck + 1] = card
	state.hand[#state.hand + 1] = card
	state.cards_added = state.cards_added + 1
	adjust_owned_jokers(state, "deck_add_scaling_xmult", 1)
	record_decision(state, {
		type = "create_playing_card", key = source, seal = card.seal,
		ante = state.ante, round = state.current_round or state.round,
	})
end

-- Chicot (setting_blind and add_to_deck, not copied) disables the Boss Blind:
-- no effect, debuff or hand size change (Blind:disable, shared with Luchador).
local function disable_boss_blind(state)
	if not state.boss_blind then return end
	for _, key in ipairs(state.jokers or {}) do
		local effect = state.joker_effects[key]
		if effect and effect.kind == "disable_boss" then
			disable_boss(state, key)
			return
		end
	end
end

-- DNA (context.before, copied by Blueprint): a single card played as the
-- first hand of the round is copied into the deck and the hand, once per copy.
local function copy_first_hand_card(state, session, played)
	if #session.hands > 0 or #played ~= 1 then return false end
	local copies = joker_slots(state, { first_hand_single_copy = true })
	for index, entry in ipairs(copies) do
		local card = {}
		for key, value in pairs(played[1]) do card[key] = value end
		state.Cards.refresh(card, ":dna:" .. state.ante .. ":" .. state.round .. ":" .. index .. ":" .. #state.deck)
		add_round_card(state, card, entry.slot)
	end
	return #copies > 0
end

-- Burnt Joker (context.pre_discard, copied by Blueprint): the first discard of
-- the round levels up the discarded poker hand, once per copy. The Hook's
-- discards do not count (context.hook).
local function level_first_discard(state, session, discarded)
	local entries = joker_slots(state, { first_discard_level = true })
	if #entries == 0 or #discarded == 0 then return end
	local hand = state.Evaluator.evaluate(discarded, state.levels, state.jokers,
		joker_context(state, discarded, session.hands_left, session.discards_left, state.hand)).name
	for _, entry in ipairs(entries) do
		state.levels[hand] = (state.levels[hand] or 1) + 1
		record_decision(state, {
			type = "joker_hand_level", key = entry.slot, hand = hand, value = state.levels[hand],
			ante = state.ante, round = state.current_round or state.round,
		})
	end
end

local function begin_round(state, target, round_name, telemetry_name)
	state.round = state.round + 1
	state.current_round = telemetry_name or round_name
	state.next_round_is_pvp = false
	-- Juggle Tag's hand size lasts this round (temp_handsize).
	state.round_hand_size, state.pending_hand_size = state.pending_hand_size, nil
	state.joker_round_flags = {}
	use_held_consumables(state, "blind_start")
	-- the Boss Blind of a Boss round with a target (not PvP).
	state.boss_blind = nil
	if round_name == "Boss" and target and telemetry_name ~= "PvP" then
		local boss = state.next_boss_blind
			or Simulator.pick_boss(state.rng:fork("boss:" .. tostring(state.ante)), state.ante, state.bosses_used)
		state.next_boss_blind = nil
		state.boss_blind = boss
		state.bosses_used = state.bosses_used or {}
		state.bosses_used[boss] = (state.bosses_used[boss] or 0) + 1
		if boss == "bl_manacle" then state.round_hand_size = (state.round_hand_size or 0) - 1 end
	end
	-- Hook arrange_jokers (before the round's Joker effects, e.g. which Joker
	-- Ceremonial Dagger destroys).
	arrange_jokers(state, "blind_start")
	prepare_round_jokers(state, round_name)
	use_held_consumables(state, "cartomancer")
	disable_boss_blind(state)   -- Chicot
	offer_boss_disable(state)   -- group B jokers: Luchador, if the Boss is still active
	set_boss_debuffs(state)
	state.draw_pile = state.Cards.shuffle(state.deck, state.rng, state.ante .. ":" .. round_name, state.the_order)
	state.hand = {}
	state.used_cards = {}
	state.round_hand_usage = {}
	notify(state, "round_start")
	draw_to_limit(state, current_hand_size(state))

	local hands_left, discards_left = current_round_resources(state)
	if state.boss_blind == "bl_needle" then hands_left = 1 end   -- one hand (Blind:set_blind)
	if state.boss_blind == "bl_water" then discards_left = 0 end -- no discards
	return {
		state = state, target = target, round_name = round_name,
		telemetry_name = telemetry_name, hands_left = hands_left,
		discards_left = discards_left, starting_hands = hands_left,
		starting_discards = discards_left, cumulative = 0, hands = {}, turn = 0,
		starting_consumables = #(state.consumables or {}),
		discards_used_this_hand = 0,
		finished = false, history_recorded = false,
	}
end

local function can_continue_round(session)
	return session.hands_left > 0 and #session.state.hand > 0
		and (not session.target or session.cumulative < session.target)
end

local function expire_end_of_round_food(state)
	for index = #state.jokers, 1, -1 do
		local key = state.jokers[index]
		local effect = state.joker_effects[key]
		local odds = effect and tonumber(effect.extinction_odds)
		if odds and odds > 0 then
			local stream = state.rng:fork(string.format(
				"food_extinction:%s:%s:%s:%s", tostring(state.ante), tostring(state.round), key, tostring(index)
			))
			if stream:integer(1, odds) == 1 then
				table.remove(state.jokers, index)
				clear_joker(state, key)
				if effect.sets_pool_flag then
					state.pool_flags[effect.sets_pool_flag] = true
					if state.order_shop and state.order_shop.pool_flags then
						state.order_shop.pool_flags[effect.sets_pool_flag] = true
					end
				end
				record_decision(state, {
					type = "destroy_joker", key = key, reason = "extinction",
					ante = state.ante, round = state.current_round or state.round,
				})
			end
		end
	end
end

local function finish_round(session)
	if session.finished then return session.result end
	local state = session.state
	adjust_owned_jokers(state, "decaying_mult", -1)
	expire_owned_jokers(state, "decaying_mult")
	for index = #state.jokers, 1, -1 do
		local key = state.jokers[index]
		local effect = state.joker_effects[key]
		if effect and effect.kind == "decaying_hand_size" then
			local remaining = math.max(0, (state.joker_state[key] or effect.initial or 0) - (effect.amount or 1))
			state.joker_state[key] = remaining
			if remaining <= 0 then
				table.remove(state.jokers, index)
				clear_joker(state, key)
			end
		end
	end
	expire_end_of_round_food(state)
	-- Campfire goes back to X1 when a Boss Blind is defeated (end_of_round, not copied).
	if session.round_name == "Boss" then
		for _, key in ipairs(state.jokers) do
			local effect = state.joker_effects[key]
			if effect and effect.kind == "sell_scaling_xmult" then state.joker_state[key] = effect.initial or 1 end
		end
	end
	state.round_hand_size = nil
	if session.round_name == "Boss" then
		-- a defeated Boss resets played_this_ante (end_round).
		for _, card in ipairs(state.deck or {}) do card.played_this_ante = nil end
	end
	-- unused discards for the Garbage Tag (end_round).
	state.unused_discards = (state.unused_discards or 0) + (session.discards_left or 0)
	for index = #state.jokers, 1, -1 do
		local key = state.jokers[index]
		local effect = state.joker_effects[key]
		if effect and effect.kind == "sell_value_growth" and effect.self_only then
			state.joker_extra_value = state.joker_extra_value or {}
			state.joker_extra_value[key] = (state.joker_extra_value[key] or 0) + (effect.amount or 3)
		elseif effect and effect.kind == "sell_value_growth" then
			state.sell_value_bonus = (state.sell_value_bonus or 0) + (effect.amount or 1)
		elseif effect and effect.kind == "pvp_discard_food" and state.current_round == "PvP" then
			state.pizza_discards = (state.pizza_discards or 0) + (effect.discards or 2)
			state.pizza_bonus_ante = state.ante + 1
			table.remove(state.jokers, index)
			clear_joker(state, key)
			record_decision(state, { type = "destroy_joker", key = key, reason = "pvp_discard_food",
				ante = state.ante, round = state.current_round })
		end
	end
	local saved = end_of_round_jokers(state, session)   -- group B jokers
	state.rounds_completed = state.rounds_completed + 1
	session.finished = true
	session.result = {
		hands = session.hands,
		score = session.cumulative,
		hands_left = session.hands_left,
		hands_used = session.starting_hands - session.hands_left,
		hands_available = session.starting_hands,
		discards_available = session.starting_discards,
		discards_left = session.discards_left,
		consumables_available = session.starting_consumables,
		consumables_remaining = #(state.consumables or {}),
		target = session.target,
		cleared = not session.target or session.cumulative >= session.target or saved,
		saved = saved or nil,   -- group B jokers: Mr. Bones
	}
	if not session.history_recorded then
		state.round_history[#state.round_history + 1] = {
			ante = state.ante, blind = session.telemetry_name or session.round_name,
			score = session.result.score, target = session.target, cleared = session.result.cleared,
			discards_used = session.starting_discards - session.discards_left,
		}
		session.history_recorded = true
	end
	return session.result
end

-- Advance through any setup discards and exactly one played hand. This keeps a
-- PvP run live: effects received from the opponent can change state before the
-- next call and therefore before the next decision is evaluated.
local function step_round(session)
	if session.finished then return nil, session.result, true end
	local state = session.state
	while can_continue_round(session) do
		session.turn = session.turn + 1
		local resolved_order_cache = {}
		-- choose_turn(args, state): play { type = "play", indices[, joker_order],
		-- result = evaluate(...) } or discard { type = "discard", indices };
		-- action.log fields go into the decision's log entry.
		local action = state.Policy.choose_turn({
			round_name = session.round_name,
			turn = session.turn,
			hand = state.hand,
			discards_left = session.discards_left,
			starting_discards = session.starting_discards,
			starting_hands = session.starting_hands,
			discards_used_this_hand = session.discards_used_this_hand,
			current_score = session.cumulative,
			target = session.target,
			hands_left = session.hands_left,
			draw_pile = state.draw_pile,
			-- evaluate(cards, full_hand[, order]): the score of playing `cards` with
			-- the Joker order `order`, or with the order the joker_order hook picks.
			evaluate = function(cards, full_hand, order)
				local context = joker_context(state, cards, session.hands_left, session.discards_left, full_hand)
				if order == nil then return scored_play(state, cards, context, resolved_order_cache, full_hand) end
				check_joker_order(state, order, "evaluate")
				local result = order_evaluator(state, cards, context, resolved_order_cache)(order)
				result.joker_order = copy_array(order)
				return result
			end,
		}, state)
		if not action then return nil, finish_round(session), true end
		local hand_before = cards_string(state.hand)
		local diagnostic = {
			ante = state.ante,
			round = session.telemetry_name or session.round_name,
			turn = session.turn,
			current_score = session.cumulative,
			required_score = session.target or session.pvp_target,
			pressure = session.target and math.max(0, session.target - session.cumulative)
				or (session.pvp_target and math.max(0, session.pvp_target - session.cumulative)) or "pvp_open_target",
			hands_remaining = session.hands_left,
			discards_remaining = session.discards_left,
			money = state.money,
			hand_contents = hand_before,
		}
		diagnostic.snapshot = compact_snapshot(state, diagnostic)
		if action.type == "discard" and session.discards_left <= 0 then
			error("choose_turn returned a discard with no discards left")
		end
		local full_hand = state.hand
		local selected
		selected, state.hand = state.Cards.remove_indices(state.hand, action.indices)
		for _, card in ipairs(selected) do state.used_cards[#state.used_cards + 1] = card end

		if action.type == "discard" then
			-- Burnt Joker: discards_used <= 0
			if session.discards_left == session.starting_discards then level_first_discard(state, session, selected) end
			session.discards_left = session.discards_left - 1
			session.discards_used_this_hand = session.discards_used_this_hand + 1
			state.discarded_cards = state.discarded_cards + #selected
			update_discard_jokers(state, selected)
			adjust_owned_jokers(state, "discard_decay_xmult", -#selected)
			record_decision(state, with_log({
				type = "discard",
				count = #selected,
				selected = cards_string(selected),
				ante = diagnostic.ante, round = diagnostic.round, turn = diagnostic.turn,
				current_score = diagnostic.current_score, required_score = diagnostic.required_score,
				pressure = diagnostic.pressure, hands_remaining = diagnostic.hands_remaining,
				discards_remaining = diagnostic.discards_remaining,
				hand_contents = diagnostic.hand_contents,
				snapshot = diagnostic.snapshot, money = diagnostic.money,
			}, action.log))
			expire_owned_jokers(state, "discard_decay_xmult")
		else
			session.discards_used_this_hand = 0
			-- The play's Joker order (arranging Jokers is free), then the score of
			-- the played cards with that order, as the rules compute it.
			local order = action.joker_order or (action.result and action.result.joker_order) or state.jokers
			check_joker_order(state, order, "choose_turn")
			local previous_order = copy_array(state.jokers)
			state.jokers = copy_array(order)
			local scored = order_evaluator(state, selected,
				joker_context(state, selected, session.hands_left, session.discards_left, full_hand),
				resolved_order_cache)(state.jokers)
			scored.joker_order = copy_array(state.jokers)
			action.result = scored
			if not same_order(previous_order, state.jokers) then
				record_decision(state, {
					type = "reorder_jokers",
					from = table.concat(previous_order, ","),
					to = table.concat(state.jokers, ","),
					hand = action.result.name,
					ante = state.ante,
					round = session.telemetry_name or session.round_name,
				})
			end
			-- Boss effects when the hand is played
			-- (play_cards_from_highlighted, Blind:press_play): every played card is
			-- played this Ante (The Pillar); The Tooth costs $1 per card; The Hook
			-- discards 2 random held cards before the hand scores.
			for _, card in ipairs(selected) do card.played_this_ante = true end
			if state.boss_blind == "bl_tooth" then state.money = state.money - #selected end
			local hooked = {}
			if state.boss_blind == "bl_hook" then
				local stream = state.rng:fork(table.concat({
					"hook", state.ante, state.round, state.hands_played,
				}, ":"))
				for _ = 1, math.min(2, #state.hand) do
					local card = table.remove(state.hand, stream:integer(1, #state.hand))
					hooked[#hooked + 1] = card
					state.used_cards[#state.used_cards + 1] = card
				end
				if #hooked > 0 then
					state.discarded_cards = state.discarded_cards + #hooked
					update_discard_jokers(state, hooked)
					adjust_owned_jokers(state, "discard_decay_xmult", -#hooked)
					expire_owned_jokers(state, "discard_decay_xmult")
				end
			end
			local leveled = not action.result.debuffed_hand and roll_hand_level_jokers(state, action.result.name)
			local copied = not action.result.debuffed_hand and copy_first_hand_card(state, session, selected)   -- DNA
			if leveled or #hooked > 0 or copied then
				-- The hand scores at its new level (state_events.lua re-reads it),
				-- with the cards really left in hand.
				local rescored = state.Evaluator.evaluate(selected, state.levels, state.jokers,
					joker_context(state, selected, session.hands_left, session.discards_left, state.hand))
				rescored.joker_order = action.result.joker_order
				action.result = rescored
			end
			session.hands_left = session.hands_left - 1
			session.cumulative = session.cumulative + action.result.score
			state.last_hand_played = action.result.name   -- for Blue Seals
			state.hand_usage[action.result.name] = (state.hand_usage[action.result.name] or 0) + 1
			state.round_hand_usage[action.result.name] = (state.round_hand_usage[action.result.name] or 0) + 1
			state.hands_played = state.hands_played + 1
			if not action.result.debuffed_hand then   -- The Psychic
				update_scaling_jokers(state, action.result, selected)
				after_scoring(state, action.result)
				apply_played_hand_income(state, action.result)
			end
			hand_trigger_jokers(state, action.result)   -- group B jokers
			adjust_owned_jokers(state, "decaying_chips", -1)
			adjust_owned_jokers(state, "limited_retrigger", -1)   -- group C jokers: Seltzer (context.after)
			local played = {
				side = "enemy",
				score = score_string(session.cumulative),
				hands_left = session.hands_left,
				hand_name = action.result.name,
				hand_score = action.result.score,
			}
			session.hands[#session.hands + 1] = played
			record_decision(state, with_log({
				type = "play",
				hand = action.result.name,
				cards = #selected, selected = cards_string(selected),
				score = action.result.score,
				ante = diagnostic.ante, round = diagnostic.round, turn = diagnostic.turn,
				current_score = diagnostic.current_score, required_score = diagnostic.required_score,
				pressure = diagnostic.pressure, hands_remaining = diagnostic.hands_remaining,
				discards_remaining = diagnostic.discards_remaining,
				hand_contents = diagnostic.hand_contents,
				snapshot = diagnostic.snapshot, money = diagnostic.money,
			}, action.log))
			expire_owned_jokers(state, "decaying_chips")
			expire_owned_jokers(state, "limited_retrigger")
		end
		-- The game draws nothing after the last hand of a round, so held Gold
		-- cards pay for the cards really left in hand.
		local round_over = action.type ~= "discard" and (session.hands_left <= 0
			or (session.target and session.cumulative >= session.target))
		if not round_over then draw_to_limit(state, current_hand_size(state)) end
		notify(state, "turn")
		if action.type ~= "discard" then
			if not can_continue_round(session) then finish_round(session) end
			return session.hands[#session.hands], session.result, session.finished
		end
	end
	return nil, finish_round(session), true
end

local function play_round(state, target, round_name, telemetry_name)
	local session = begin_round(state, target, round_name, telemetry_name)
	while not session.finished do step_round(session) end
	return session.result
end

-- dependencies.Policy decides for the player (see decide); the policy reads
-- its own settings from the run's options (state.options).
function Simulator.new(options, dependencies)
	options = options or {}
	assert(dependencies.Policy and dependencies.Policy.choose_turn,
		"Simulator.new needs dependencies.Policy, a decision policy (for MultiBots' own: bot/expert.lua Expert.modules)")
	local catalog = options.content_catalog
	if not catalog and dependencies.Content then catalog = dependencies.Content.defaults() end
	local state = {
		Cards = dependencies.Cards,
		Evaluator = dependencies.Evaluator,
		Policy = dependencies.Policy,
		options = options,
		Order = dependencies.Order,
		base_score = Simulator.base_score,
		seed = tostring(options.seed or "MULTBOT"),
		rng = dependencies.PRNG.new(options.seed or "MULTBOT"),
		deck = dependencies.Cards.standard_deck(),
		deck_name = options.deck or "Red Deck",
		the_order = options.the_order == true,
		banned = options.banned_jokers or {},
		joker_pool = options.joker_pool or (catalog and catalog.jokers) or {},
		planet_pool = (catalog and catalog.planets) or (function()
			local out = {}
			for _, hand in ipairs(planet_names) do out[#out + 1] = { key = hand, hand = hand, cost = 3 } end
			return out
		end)(),
		deck_tools = (catalog and catalog.deck_tools) or {},
		pack_pool = (catalog and catalog.packs) or {},
		voucher_pool = (catalog and catalog.vouchers) or {},
		content_catalog = catalog,
		joker_effects = {},
		joker_state = {},
		joker_targets = {},
		joker_editions = {},
		joker_limit = tonumber(options.joker_limit) or 5,
		consumable_limit = tonumber(options.consumable_limit) or 2,
		hands_per_round = tonumber(options.hands_per_round) or 4,
		discards_per_round = tonumber(options.discards_per_round) or 3,
		hand_size_bonus = 0,
		shop_slots = 2,
		interest_cap = 5,
		tarot_rate = 1,
		playing_cards_in_shop = false,
		reroll_discount = 0,
		shop_discount = 0,
		edition_rate = 1,
		no_gold_on_round_loss = options.no_gold_on_round_loss == true,
		gold_on_life_loss = options.gold_on_life_loss ~= false,
		death_on_round_loss = options.death_on_round_loss ~= false,
		stake = tonumber(options.stake) or 1,
		ruleset = options.ruleset or "ruleset_mp_blitz",
		comeback_losses = 0,
		money = 4,
		jokers = {},
		consumables = {},
		consumables_used = 0,
		vouchers = {},
		levels = create_levels(),
		hand_usage = {},
		round_hand_usage = {},
		hands_played = 0,
		rounds_completed = 0,
		discarded_cards = 0,
		planets_used = 0,
		tarots_used = 0,
		cards_added = 0,
		shop_index = 0,
		shop_rerolls = 0,   -- rerolls in the current shop
		ante = 1,
		round = 0,
		decisions = {},
		round_history = {},
		shop_visits = 0,
		times_rerolled = 0,
		reroll_cost_total = 0,
		skips = 0,
		opponent_skips = 0,
		skip_plans = {},
		pending_tag_jokers = {},
		pack_history = {},
		strict_order_content = options.strict_order_content == true,
		legacy_shop = options.legacy_shop == true,   -- see visit_shop
		pending_investment = 0,
		pool_flags = {},
	}
	for _, joker in ipairs(state.joker_pool) do state.joker_effects[joker.key] = joker.effect end
	-- Multiplayer's standard layer bans Justice
	-- (multiplayer layers/standard.lua banned_consumables); live catalogs already
	-- leave it out, the default catalog does not.
	local ruleset_key = tostring(state.ruleset):gsub("^ruleset_mp_", "")
	if ({ blitz = true, traditional = true, ranked = true, smallworld = true, speedlatro = true, chaos = true })[ruleset_key] then
		local tools = {}
		for _, tool in ipairs(state.deck_tools) do
			if tool.key ~= "c_justice" then tools[#tools + 1] = tool end
		end
		state.deck_tools = tools
	end
	state.ghost_deck = tostring(state.deck_name):lower():find("ghost", 1, true) ~= nil or state.deck_name == "b_ghost"
	apply_deck_back(state, state.deck_name)
	-- Blue Stake and above, -1 discard (game.lua start_run).
	if state.stake >= 5 then state.discards_per_round = math.max(0, state.discards_per_round - 1) end
	-- Vouchers and cards a deck starts with (back.lua apply_to_run).
	for _, key in ipairs(state.deck_vouchers or {}) do
		for _, voucher in ipairs(state.voucher_pool or {}) do
			if voucher.key == key then apply_voucher(state, voucher); break end
		end
	end
	for _, key in ipairs(state.deck_consumables or {}) do
		for _, tool in ipairs(state.deck_tools or {}) do
			if tool.key == key then
				local held = copy_map(tool)
				held.type = "deck_tool"
				state.consumables[#state.consumables + 1] = held
				break
			end
		end
	end
	state.starting_deck_size = #state.deck
	notify(state, "new")
	return state
end

Simulator.debt_limit = debt_limit   -- for invariant checks

function Simulator.next_reroll_cost(state, rerolls_this_shop)
	rerolls_this_shop = math.max(0, tonumber(rerolls_this_shop) or 0)
	local free = has_joker_kind(state, "free_shop_reroll")
	if rerolls_this_shop == 0 and free then return 0 end
	-- the free reroll does not raise the price
	-- (calculate_reroll_cost(final_free), button_callbacks.lua reroll_shop).
	local increase = free and rerolls_this_shop - 1 or rerolls_this_shop
	return math.max(0, 5 + increase - (state.reroll_discount or 0))
end

function Simulator.pay_reroll(state, cost)
	cost = tonumber(cost) or 5
	-- debt-aware like a purchase (can_reroll,
	-- functions/button_callbacks.lua:2077: dollars - bankrupt_at >= cost, or free).
	if cost < 0 or not can_pay(state, cost) then return false end
	state.money = state.money - cost
	state.times_rerolled = (state.times_rerolled or 0) + 1
	state.reroll_cost_total = (state.reroll_cost_total or 0) + cost
	state.shop_rerolls = (state.shop_rerolls or 0) + 1   -- rerolls in this shop
	state.shop_reroll_pending = true   -- the next visit_shop is this reroll
	adjust_owned_jokers(state, "reroll_scaling_mult", 1)   -- Flash Card (reroll_shop, not copied)
	record_decision(state, {
		type = "reroll_shop", value = cost, ante = state.ante,
		round = state.current_round or state.round, money = state.money,
	})
	return true
end

function Simulator.set_ante(state, ante)
	state.ante = tonumber(ante) or 1
	if state.pizza_bonus_ante and state.ante > state.pizza_bonus_ante then
		state.pizza_bonus_ante, state.pizza_discards = nil, 0
	end
	notify(state, "set_ante")
end

-- more Tags the headless run applies (tag.lua apply_to_run).
local immediate_tags = {
	tag_skip = true, tag_handy = true, tag_garbage = true, tag_orbital = true,
	tag_juggle = true, tag_top_up = true,
}

local function skip_reward_supported(state, tag)
	if tag == "tag_investment" or tag == "tag_economy" or tag == "tag_negative"
		or tag == "tag_foil" or tag == "tag_holo" or tag == "tag_polychrome" then
		return true
	end
	if immediate_tags[tag] then return true end
	if (tag == "tag_rare" or tag == "tag_uncommon")
		and (not state.strict_order_content or order_tag_jokers(state)) then return true end
	return false
end

-- Hook skip_pair: which Blinds of this Ante to skip (ctx in bot/expert.lua).
-- The Tag rewards below are rules.
function Simulator.plan_skips(state, mode, tags)
	local ante = tonumber(state.ante) or 1
	if state.skip_plans[ante] then return state.skip_plans[ante] end
	local plan = {}
	state.skip_plans[ante] = plan
	if mode == "disabled" then return plan end
	local candidates = {}
	for _, blind in ipairs({ "Small", "Big" }) do
		local tag = tags and tags[blind]
		candidates[blind] = { tag = tag, supported = skip_reward_supported(state, tag) }
	end
	candidates.Small.selected, candidates.Big.selected = decide(state, "skip_pair",
		{ mode = mode or "reactive", ante = ante, small = candidates.Small, big = candidates.Big })
	for _, blind in ipairs({ "Small", "Big" }) do
		local candidate = candidates[blind]
		local tag = candidate.tag
		if candidate.selected then
			plan[blind] = true
			state.skips = state.skips + 1
			record_decision(state, {
				type = "skip_blind", blind = blind, key = tag, ante = ante,
				round = blind, count = state.skips,
			})
			local reward_count = 1 + math.min(1, state.double_tags or 0)
			if reward_count > 1 then state.double_tags = state.double_tags - 1 end
			for reward = 1, reward_count do
				-- a Double Tag's copy rolls its own Orbital hand / Top-up Jokers.
				local copy_suffix = reward > 1 and (":copy" .. reward) or ""
				if tag == "tag_investment" then
					state.pending_investment = (state.pending_investment or 0) + 25
				elseif tag == "tag_economy" then
					state.money = state.money + math.min(40, math.max(0, state.money))
				elseif tag == "tag_skip" then
					state.money = state.money + 5 * state.skips   -- Speed Tag: $5 per skip, this one included
				elseif tag == "tag_handy" then
					state.money = state.money + (state.hands_played or 0)
				elseif tag == "tag_garbage" then
					state.money = state.money + (state.unused_discards or 0)
				elseif tag == "tag_orbital" then
					local hands = { "High Card", "Pair", "Two Pair", "Three of a Kind", "Straight", "Flush",
						"Full House", "Four of a Kind", "Straight Flush" }
					local hand = hands[state.rng:fork("orbital:" .. ante .. ":" .. blind .. copy_suffix):integer(1, #hands)]
					state.levels[hand] = (state.levels[hand] or 1) + 3
				elseif tag == "tag_juggle" then
					state.pending_hand_size = (state.pending_hand_size or 0) + 3   -- next round only
				elseif tag == "tag_top_up" then
					for index = 1, 2 do
						if #state.jokers < state.joker_limit then
							local key, edition = roll_vanilla_joker(state,
								state.rng:fork("top_up:" .. ante .. ":" .. blind .. ":" .. index .. copy_suffix), nil, 1)
							for _, joker in ipairs(state.joker_pool or {}) do
								if joker.key == key and joker_available(state, key) then
									state.jokers[#state.jokers + 1] = key
									initialize_joker(state, key)
									set_joker_edition(state, key, edition)
									break
								end
							end
						end
					end
				elseif (tag == "tag_rare" or tag == "tag_uncommon")
					and (not state.strict_order_content or order_tag_jokers(state)) then
					state.pending_tag_jokers[#state.pending_tag_jokers + 1] = {
						tag = tag, rarity = tag == "tag_rare" and "rare" or "uncommon",
					}
				elseif tag == "tag_negative" or tag == "tag_foil" or tag == "tag_holo"
					or tag == "tag_polychrome" then
					local edition = tag == "tag_negative" and "negative"
						or (tag == "tag_foil" and "foil")
						or (tag == "tag_holo" and "holo") or "polychrome"
					state.pending_tag_jokers[#state.pending_tag_jokers + 1] = {
						tag = tag, edition = edition,
					}
				end
			end
		end
	end
	return plan
end

function Simulator.record_pvp_outcome(state, bot_score, player_score)
	bot_score = tonumber(bot_score) or 0
	player_score = tonumber(player_score) or 0
	state.previous_pvp_score = bot_score
	state.previous_player_score = player_score
	state.previous_pvp_lost = bot_score < player_score
	if state.previous_pvp_lost then
		state.pvp_losses = (state.pvp_losses or 0) + 1
	else
		state.pvp_wins = (state.pvp_wins or 0) + 1
	end
	state.previous_pvp_dominant = bot_score > 0
		and (player_score <= 0 or bot_score >= player_score * 1.5)
	state.upcoming_score_target = Simulator.base_score((tonumber(state.ante) or 1) + 1)
	return state.previous_pvp_dominant
end

function Simulator.play_round(state, target, round_name, telemetry_name)
	return play_round(state, target, round_name, telemetry_name)
end

function Simulator.begin_round(state, target, round_name, telemetry_name)
	return begin_round(state, target, round_name, telemetry_name)
end

function Simulator.step_round(session)
	return step_round(session)
end

function Simulator.finish_round(session)
	return finish_round(session)
end

function Simulator.apply_pvp_effect(state, action)
	if not state or not action then return false end
	if action == "asteroid" then
		local priority = {
			["High Card"] = 1, Pair = 2, ["Two Pair"] = 3, ["Three of a Kind"] = 4,
			Straight = 5, Flush = 6, ["Full House"] = 7, ["Four of a Kind"] = 8,
			["Straight Flush"] = 9,
			["Five of a Kind"] = 10,
		}
		local chosen, level = "High Card", -math.huge
		for hand, value in pairs(state.levels or {}) do
			value = tonumber(value) or 1
			if value > level or (value == level and (priority[hand] or 0) > (priority[chosen] or 0)) then
				chosen, level = hand, value
			end
		end
		state.levels[chosen] = math.max(1, level - 1)
		record_decision(state, {
			type = "opponent_effect", effect = action, hand = chosen,
			value = state.levels[chosen], ante = state.ante, round = state.current_round,
		})
		notify(state, "pvp_effect", action)
		return true
	elseif action == "letsGoGamblingNemesis" then
		state.money = state.money + 10
		record_decision(state, {
			type = "opponent_effect", effect = action, value = 10,
			ante = state.ante, round = state.current_round,
		})
		return true
	elseif action == "soldJoker" then
		state.pending_opponent_sells = (state.pending_opponent_sells or 0) + 1
		record_decision(state, { type = "opponent_effect", effect = action,
			value = state.pending_opponent_sells, ante = state.ante, round = state.current_round })
		return true
	end
	return false
end

function Simulator.visit_shop(state, ordered_keys)
	return visit_shop(state, ordered_keys)
end

-- One shop with its rerolls, for every driver (peer.lua, Simulator.run,
-- training/fitness.lua). The first visit uses `keys` (a live game's keys, or
-- nil for a headless shop). After each visit the shop is rerolled when
-- shop_step chose "reroll" or the reroll_step hook says so, and it is paid.
-- options.reroll_keys(state) -> keys[, error]: a live reroll's keys; without
-- it a live shop cannot be rerolled, while a headless one rerolls with its own
-- keys. options.visit(keys, source): one visit (default Simulator.visit_shop).
-- options.on_reroll_failed(error): a reroll could not be generated or paid.
function Simulator.shop_phase(state, keys, options)
	options = options or {}
	local visit = options.visit or function(visit_keys) return Simulator.visit_shop(state, visit_keys) end
	local headless = keys == nil
	local reroll_keys = options.reroll_keys
	local can_reroll = headless or reroll_keys ~= nil
	state.shop_no_reroll = not can_reroll or nil
	local report = visit(keys, "visit")
	local rerolls = 0
	while can_reroll and rerolls < REROLL_GUARD do
		local cost = Simulator.next_reroll_cost(state, rerolls)
		local wanted = report.reroll_requested
		if not wanted then
			wanted = decide(state, "reroll_step", {
				report = report, cost = cost, rerolls_this_shop = rerolls, headless = headless,
			})
		end
		if not wanted then break end
		local next_keys, reroll_error
		if not headless then next_keys, reroll_error = reroll_keys(state) end
		if (headless or next_keys) and Simulator.pay_reroll(state, cost) then
			rerolls = rerolls + 1
			report = visit(next_keys, "reroll")
		else
			if options.on_reroll_failed then options.on_reroll_failed(reroll_error) end
			break
		end
	end
	state.shop_no_reroll = nil
	return report
end

-- the hand a deck tool draws from its stream (unit tests)
Simulator.tool_hand = tool_hand
Simulator.apply_deck_tool = apply_deck_tool
-- test access to held-consumable use and its can_use rule (unit tests).
function Simulator.apply_consumable(state, consumable, source)
	return apply_consumable(state, consumable, source or "test")
end
function Simulator.consumable_usable(state, consumable)
	return consumable_usable(state, consumable)
end
-- whether a shop offer can be bought and used at once, and whether a Planet is
-- in the pool yet (a secret hand's Planet once that hand was played).
Simulator.buy_and_use_ready = buy_and_use_ready
Simulator.planet_unlocked = planet_unlocked

-- the keys (and _metadata editions) of a headless shop
-- visit, or of a reroll; visit_shop uses it when no live keys are given.
function Simulator.shop_keys(state, reroll)
	return headless_shop_keys(state, reroll)
end

function Simulator.award_blind(state, blind, result)
	if not result then return false end
	local ante = tonumber(state.ante) or 1
	local scaling = Simulator.blind_scaling(state.stake)
	state.upcoming_score_target = blind == "Small" and Simulator.base_score(ante, scaling) * 1.5
		or (blind == "Big" and Simulator.base_score(ante, scaling) * 2)
		or Simulator.base_score(ante + 1, scaling)
	local base = blind == "Boss" and 5 or (blind == "Big" and 4 or 3)
	if blind == "Small" and (tonumber(state.stake) or 1) >= 2 then base = 0 end
	if result.saved then base = 0 end   -- group B jokers: a round Mr. Bones saved pays no Blind reward
	-- Held Gold cards pay at the end of the round (Red Seal and Mime repeat it),
	-- before interest is counted at cash out.
	-- a Blueprint/Brainstorm copying Mime retriggers too, and
	-- a held Blue Seal card creates the Planet of the last hand played, once per
	-- trigger while there is room (end_round in state_events.lua,
	-- Card:get_end_of_round_effect in card.lua).
	local mimes = #joker_slots(state, { held_retrigger = true })
	local gold_income = 0
	for _, card in ipairs(state.hand or {}) do
		if (card.enhancement == "m_gold" or card.seal == "Blue") and not card.debuff then
			for _ = 1, 1 + mimes + (card.seal == "Red" and 1 or 0) do
				if card.enhancement == "m_gold" then gold_income = gold_income + 3 end
				if card.seal == "Blue" then generate_hand_planet(state, state.last_hand_played, "blue_seal") end
			end
		end
	end
	-- the Boss and its debuffs end with the round.
	state.boss_blind = nil
	for _, card in ipairs(state.deck or {}) do card.debuff = nil end
	local interest_base = math.min(state.interest_cap or 5,
		math.floor(math.max(0, state.money + gold_income) / 5))
	local interest = state.no_interest and 0
		or interest_base
	if not state.no_interest then
		for _, key in ipairs(state.jokers or {}) do
			local effect = state.joker_effects[key]
			if effect and effect.kind == "extra_interest" then
				interest = interest + interest_base * (effect.amount or 1)
			end
		end
	end
	-- Multiplayer converts a lost non-PvP Blind into a technical clear after
	-- charging the life, so Boss-clear tag rewards still resolve on that path.
	local investment = blind == "Boss" and (state.pending_investment or 0) or 0
	local joker_income = end_round_joker_income(state, result)
	local life_lost = result.life_lost == true
		or (not result.cleared and state.death_on_round_loss)
	local comeback = 0
	if life_lost and state.gold_on_life_loss then
		state.comeback_losses = (state.comeback_losses or 0) + 1
		if state.ruleset == "ruleset_mp_sandbox" then
			comeback = 3 * math.max(0, (tonumber(state.ante) or 1) - 1)
		elseif state.ruleset == "ruleset_mp_majorleague" then
			comeback = 4 * state.comeback_losses
		else
			comeback = state.stake >= 6 and 2 or 4
		end
	end
	if investment > 0 then state.pending_investment = 0 end
	if not result.cleared then
		record_decision(state, {
			type = "fail_round",
			blind = blind,
			score = result.score,
			target = result.target,
			hands_used = result.hands_used,
			hands_remaining = result.hands_left,
			hands_available = result.hands_available,
			discards_remaining = result.discards_left,
			discards_available = result.discards_available,
			consumables_remaining = result.consumables_remaining,
			consumables_available = result.consumables_available,
			ante = state.ante,
			round = state.round,
		})
		state.money = state.money + (result.hands_left or 0) * (state.money_per_hand or 1)
			+ (result.discards_left or 0) * (state.money_per_discard or 0) + interest
		if not state.no_gold_on_round_loss then state.money = state.money + base end
		state.money = state.money + investment + joker_income + gold_income + comeback
		return false
	end
	-- Green Deck pays $2 per hand and $1 per discard left.
	state.money = state.money + base + (result.hands_left or 0) * (state.money_per_hand or 1)
		+ (result.discards_left or 0) * (state.money_per_discard or 0)
		+ interest + investment + joker_income + gold_income + comeback
	return true
end

function Simulator.snapshot(state)
	local consumables = {}
	for _, consumable in ipairs(state.consumables or {}) do consumables[#consumables + 1] = consumable.key end
	return {
		money = state.money,
		jokers = copy_array(state.jokers),
		joker_editions = copy_map(state.joker_editions),
		levels = copy_map(state.levels),
		deck = copy_deck(state),
		consumables = consumables,
		consumable_limit = state.consumable_limit,
	}
end

function Simulator.export(state, ante_states)
	local consumables = {}
	for _, consumable in ipairs(state.consumables or {}) do consumables[#consumables + 1] = consumable.key end
	return {
		money = state.money,
		jokers = copy_array(state.jokers),
		joker_editions = copy_map(state.joker_editions),
		levels = copy_map(state.levels),
		decisions = state.decisions,
		ante_states = ante_states or {},
		deck = copy_deck(state),
		deck_name = state.deck_name,
		consumables = consumables,
		consumable_limit = state.consumable_limit,
		consumables_used = state.consumables_used,
		the_order = state.the_order,
		skips = state.skips,
	}
end

function Simulator.run(options, dependencies)
	options = options or {}
	local state = Simulator.new(options, dependencies)
	local snapshots = {}
	local ante_states = {}
	for ante = 1, tonumber(options.max_ante) or 16 do
		Simulator.set_ante(state, ante)
		local base = Simulator.base_score(ante)
		local small = Simulator.play_round(state, base, "Small")
		Simulator.award_blind(state, "Small", small)
		Simulator.shop_phase(state)
		local big = Simulator.play_round(state, base * 1.5, "Big")
		Simulator.award_blind(state, "Big", big)
		Simulator.shop_phase(state)
		ante_states[ante] = Simulator.snapshot(state)
		local pvp = Simulator.play_round(state, nil, "Boss", "PvP")
		snapshots[ante] = { hands = pvp.hands }
		state.money = state.money + pvp.hands_left
		Simulator.shop_phase(state)
	end
	return snapshots, Simulator.export(state, ante_states)
end

-- Rules helpers for policies (bot/expert.lua builds on them).
Simulator.rules = {
	has_joker_kind = has_joker_kind,
	joker_details = joker_details,
	joker_sell_value = joker_sell_value,
	joker_available = joker_available,
	consumable_available = consumable_available,
	consumable_sell_value = consumable_sell_value,
	debt_limit = debt_limit,
	pack_spec = pack_spec,
	telescope_planet = telescope_planet,
	decision_stream = decision_stream,
	find_action = find_action,
	find_take = find_take,
	base_score = Simulator.base_score,
	blind_scaling = Simulator.blind_scaling,
	spectral_usable = spectral_usable,
	inferred_rarity = inferred_rarity,
	vanilla_jokers_by_rarity = vanilla_jokers_by_rarity,
	current_hand_size = current_hand_size,
}

return Simulator
