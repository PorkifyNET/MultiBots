local Observer = {}

local function encode_card(card)
	if not card then return nil end
	if MP and MP.UTILS and type(MP.UTILS.card_to_string) == "function" then
		local ok, encoded = pcall(MP.UTILS.card_to_string, card)
		if ok and type(encoded) == "string" and encoded ~= "" then return encoded end
	end
	local center = card.config and card.config.center
	return center and center.key or nil
end

local function encoded_cards(cards)
	local values = {}
	for _, card in ipairs(cards or {}) do
		local value = encode_card(card)
		if value then values[#values + 1] = value end
	end
	return table.concat(values, ",")
end

local function event_card(event)
	local config = event and event.config
	local card = config and (config.ref_table or config.card)
	if type(card) == "table" and (card.config or card.base) then return card end
end

local function poker_hand(cards)
	if type(get_poker_hand_info) ~= "function" or #(cards or {}) == 0 then return nil end
	local ok, hand = pcall(get_poker_hand_info, cards)
	if ok and type(hand) == "string" and hand ~= "" then return hand end
end

local function record_action(dependencies, action, event)
	if not dependencies.is_active() then return end
	local loggers = dependencies.get_loggers and dependencies.get_loggers()
		or { dependencies.Logger }
	local available = false
	for _, logger in ipairs(loggers or {}) do
		if logger and logger.path then available = true; break end
	end
	if not available then return end
	local game = G.GAME or {}
	local round = game.current_round or {}
	local hand = G.hand
	local highlighted = hand and hand.highlighted or {}
	local target = event_card(event)
	local values = {
		action = action,
		ante = game.round_resets and game.round_resets.ante,
		blind = game.blind_on_deck,
		score = game.chips,
		hands_left = round.hands_left,
		discards_left = round.discards_left,
		money = game.dollars,
		hand = encoded_cards(hand and hand.cards),
		selected = encoded_cards(highlighted),
		poker_hand = action == "play" and poker_hand(highlighted) or nil,
		target = encode_card(target),
		jokers = encoded_cards(G.jokers and G.jokers.cards),
	}
	for _, logger in ipairs(loggers) do
		if logger and logger.path then logger.write("PLAYER_ACTION", values) end
	end
end

function Observer.install(dependencies)
	local funcs = G and G.FUNCS or {}
	local hooks = {
		play_cards_from_highlighted = "play",
		discard_cards_from_highlighted = "discard",
		buy_from_shop = "buy",
		buy_and_use = "buy_and_use",
		sell_card = "sell",
		use_card = "use",
		reroll_shop = "reroll",
		skip_blind = "skip_blind",
		skip_booster = "skip_pack",
	}
	local installed = 0
	for callback, action in pairs(hooks) do
		local original = funcs[callback]
		if type(original) == "function" then
			funcs[callback] = function(event, ...)
				record_action(dependencies, action, event)
				return original(event, ...)
			end
			installed = installed + 1
		end
	end
	return installed
end

return Observer
