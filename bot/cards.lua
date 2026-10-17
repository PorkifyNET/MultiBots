local Cards = {}

Cards.suits = { "Spades", "Hearts", "Clubs", "Diamonds" }
Cards.rank_names = {
	[2] = "2", [3] = "3", [4] = "4", [5] = "5", [6] = "6", [7] = "7", [8] = "8",
	[9] = "9", [10] = "10", [11] = "Jack", [12] = "Queen", [13] = "King", [14] = "Ace",
}

function Cards.chips(rank)
	if rank == 14 then return 11 end
	return math.min(rank, 10)
end

function Cards.standard_deck()
	local deck = {}
	for _, suit in ipairs(Cards.suits) do
		for rank = 2, 14 do
			deck[#deck + 1] = {
				id = suit:sub(1, 1) .. tostring(rank),
				suit = suit,
				rank = rank,
				chips = Cards.chips(rank),
			}
		end
	end
	return deck
end

function Cards.copy_deck(source)
	local deck = {}
	for index, card in ipairs(source or {}) do
		local copy = {}
		for key, value in pairs(card) do copy[key] = value end
		deck[index] = copy
	end
	return deck
end

function Cards.refresh(card, suffix)
	card.chips = Cards.chips(card.rank) + (card.perma_bonus or 0)
	card.id = card.suit:sub(1, 1) .. tostring(card.rank) .. (suffix or "")
	return card
end

local function copy_array(source)
	local out = {}
	for i, value in ipairs(source) do out[i] = value end
	return out
end

function Cards.shuffle(source, rng, order_key, the_order)
	local out = copy_array(source)
	-- The previous ordered path sorted structured card IDs by a weak hash. That
	-- preserved same-suit rank runs and effectively stacked Straight Flushes.
	-- Both paths now use a seeded Fisher-Yates permutation; the separate label
	-- keeps The Order's stream deterministic without biasing adjacent cards.
	local label = the_order and "ordered_shuffle:" or "shuffle:"
	local stream = rng:fork(label .. tostring(order_key))
	for i = #out, 2, -1 do
		local j = stream:integer(1, i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

function Cards.remove_indices(cards, indices)
	local selected, kept, lookup = {}, {}, {}
	for _, index in ipairs(indices) do lookup[index] = true end
	for index, card in ipairs(cards) do
		if lookup[index] then selected[#selected + 1] = card else kept[#kept + 1] = card end
	end
	return selected, kept
end

return Cards
