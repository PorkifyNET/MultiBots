-- Buy and Use in the shop (functions/button_callbacks.lua G.FUNCS.can_buy_and_use
-- and buy_from_shop with id 'buy_and_use', card.lua Card:can_use_consumeable):
-- an affordable Tarot, Planet or Spectral that can be used in the shop is
-- bought and used at once, even with full consumable slots.
local base = {
	PRNG = dofile("bot/prng.lua"),
	Cards = dofile("bot/cards.lua"),
	Content = dofile("bot/content.lua"),
	Evaluator = dofile("bot/evaluator.lua"),
	Strategy = dofile("bot/strategy.lua"),
	Policy = dofile("bot/policy.lua"),
	Simulator = dofile("bot/simulator.lua"),
}
base = dofile("bot/expert.lua").modules(base)   -- MultiBots' Expert decides the rest
local Simulator = base.Simulator

local function tool(key)
	for _, entry in ipairs(base.Content.defaults().deck_tools) do
		if entry.key == key then
			local offer = {}
			for field, value in pairs(entry) do offer[field] = value end
			offer.type = "deck_tool"
			return offer
		end
	end
	error("no deck tool " .. key)
end

local function held(key)
	local card = tool(key)
	return card
end

-- An external policy whose shop_step is `step(state, ctx)`.
local function shop_player(step)
	local modules = {}
	for key, value in pairs(base) do modules[key] = value end
	modules.Policy = setmetatable({ shop_step = step }, { __index = base.Policy })
	return modules
end

local function find_action(actions, wanted)
	for index, action in ipairs(actions) do
		local ok = true
		for key, value in pairs(wanted) do if action[key] ~= value then ok = false; break end end
		if ok then return index, action end
	end
	return nil
end

local function new_state(modules, seed, options)
	local state = Simulator.new({ seed = seed, difficulty = "expert", the_order = true }, modules)
	for key, value in pairs(options or {}) do state[key] = value end
	return state
end

---------------------------------------------------------------------------
-- 1. A Planet with full slots: only Buy and Use (or a sale) gets it.
---------------------------------------------------------------------------

local listed
local full = new_state(shop_player(function(_, ctx)
	if listed then return 1 end
	listed = ctx.actions
	return find_action(ctx.actions, { type = "buy_and_use", key = "c_mercury" }) or 1
end), "BUY-USE-FULL", {
	money = 10,
	consumables = { held("c_hanged_man"), held("c_strength") },
})
Simulator.visit_shop(full, { "c_mercury" })
assert(listed, "the shop asked the policy")
for _, action in ipairs(listed) do
	assert(not (action.type == "buy" and action.key == "c_mercury" and not action.sell_consumable),
		"with full slots a plain buy is not listed")
end
local _, use_now = find_action(listed, { type = "buy_and_use", key = "c_mercury" })
assert(use_now and use_now.cost == 3 and use_now.item_type == "planet" and use_now.sell_consumable == nil,
	"Buy and Use is listed for a Planet with full slots")
assert(full.levels.Pair == 2 and full.planets_used == 1, "the Planet levels its hand at once")
assert(full.money == 7, "the Planet is paid, nothing is sold: $" .. tostring(full.money))
assert(#full.consumables == 2 and full.consumables[1].key == "c_hanged_man"
	and full.consumables[2].key == "c_strength", "the held cards stay")
assert(full.last_consumable and full.last_consumable.key == "c_mercury"
	and full.last_consumable.use_now == nil and full.last_consumable.offer_index == nil,
	"The Fool repeats the used Planet")
local bought, used
for _, decision in ipairs(full.decisions) do
	if decision.type == "buy_planet" and decision.key == "c_mercury" then bought = decision.decision_id end
	if decision.type == "use_consumable" and decision.key == "c_mercury" then
		used = decision.decision_id
		assert(decision.source == "buy_and_use", "the use is logged as Buy and Use")
	end
	if decision.type == "shop_decision" and decision.chosen and decision.chosen:match("c_mercury") then
		assert(decision.chosen == "buy_and_use_planet:c_mercury", "chosen: " .. tostring(decision.chosen))
	end
end
assert(bought and used and bought < used, "bought, then used")

---------------------------------------------------------------------------
-- 2. With a free slot the game shows the button too.
---------------------------------------------------------------------------

local free_listed
local free = new_state(shop_player(function(_, ctx)
	free_listed = free_listed or ctx.actions
	return 1
end), "BUY-USE-FREE", { money = 10 })
Simulator.visit_shop(free, { "c_jupiter" })
assert(find_action(free_listed, { type = "buy", key = "c_jupiter" })
	and find_action(free_listed, { type = "buy_and_use", key = "c_jupiter" }),
	"with room both Buy and Buy and Use are listed")

-- not affordable: neither
local poor_listed
local poor = new_state(shop_player(function(_, ctx)
	poor_listed = poor_listed or ctx.actions
	return 1
end), "BUY-USE-POOR", { money = 2 })
Simulator.visit_shop(poor, { "c_jupiter" })
assert(not find_action(poor_listed, { type = "buy_and_use" }), "Buy and Use needs the money")

---------------------------------------------------------------------------
-- 3. What can be used in the shop (Card:can_use_consumeable, SHOP state).
---------------------------------------------------------------------------

local ready = Simulator.buy_and_use_ready
local rules = new_state(base, "BUY-USE-RULES", { money = 10 })
assert(ready(rules, { type = "planet", key = "c_pluto", hand = "High Card" }), "a Planet")
assert(ready(rules, tool("c_hermit")) and ready(rules, tool("c_temperance")), "the money Tarots")
for _, key in ipairs({ "c_strength", "c_hanged_man", "c_star", "c_magician", "c_death", "c_tower" }) do
	assert(not ready(rules, tool(key)), key .. " targets hand cards: not in the shop")
end
for _, key in ipairs({ "c_aura", "c_cryptid", "c_deja_vu", "c_familiar", "c_sigil", "c_ouija", "c_immolate" }) do
	assert(not ready(rules, tool(key)), key .. " needs hand cards: not in the shop")
end
assert(ready(rules, tool("c_emperor")) and ready(rules, tool("c_high_priestess")),
	"The Emperor / High Priestess with a free slot")
rules.consumables = { held("c_hanged_man"), held("c_strength") }
assert(not ready(rules, tool("c_emperor")) and not ready(rules, tool("c_high_priestess")),
	"... but not with full slots (the card itself is not in the slots)")
rules.consumables = {}
assert(not ready(rules, tool("c_fool")), "The Fool needs a last Tarot or Planet")
rules.last_consumable = { type = "planet", key = "c_pluto", hand = "High Card" }
assert(ready(rules, tool("c_fool")), "The Fool with a last card and a free slot")
assert(ready(rules, tool("c_judgement")) and ready(rules, tool("c_wraith")), "a Joker slot is free")
rules.jokers = { "j_joker", "j_jolly", "j_mad", "j_crazy", "j_droll" }
assert(not ready(rules, tool("c_judgement")) and not ready(rules, tool("c_wraith")),
	"no Joker slot: Judgement and Wraith cannot be used")
assert(ready(rules, tool("c_wheel_of_fortune")) and ready(rules, tool("c_hex")),
	"Jokers without an edition: The Wheel of Fortune and Hex")
assert(not ready(rules, tool("c_ankh")), "Ankh needs a free Joker slot")
rules.jokers = { "j_joker" }
assert(ready(rules, tool("c_ankh")), "Ankh with a Joker and a free slot")
rules.joker_editions = { j_joker = "foil" }
assert(not ready(rules, tool("c_wheel_of_fortune")) and not ready(rules, tool("c_hex"))
	and not ready(rules, tool("c_ectoplasm")), "no Joker without an edition")
assert(not ready(rules, { type = "joker", key = "j_joker" }) and not ready(rules, { type = "voucher", key = "v_grabber" }),
	"only consumables")

-- The Hermit is paid first, then doubles the money left (ease_dollars before use_card).
local hermit = new_state(shop_player(function(_, ctx)
	return find_action(ctx.actions, { type = "buy_and_use", key = "c_hermit" }) or 1
end), "BUY-USE-HERMIT", {
	money = 10,
	consumables = { held("c_hanged_man"), held("c_strength") },
})
Simulator.visit_shop(hermit, { "c_hermit" })
assert(hermit.money == 14 and #hermit.consumables == 2 and hermit.tarots_used == 1,
	"The Hermit: $10 - $3, doubled: $" .. tostring(hermit.money))

---------------------------------------------------------------------------
-- 4. The Expert: with full slots it buys and uses a Planet it wants instead of
-- selling a held card.
---------------------------------------------------------------------------

local expert = new_state(base, "BUY-USE-EXPERT", {
	money = 20,
	strategy_open = true,
	consumables = { held("c_temperance"), held("c_temperance") },
})
expert.hand_usage.Pair = 6
Simulator.visit_shop(expert, { "c_mercury" })
assert(expert.levels.Pair == 2, "the Expert takes the Planet")
assert(#expert.consumables == 2, "and keeps both held cards")
assert(expert.money == 17, "for $3: $" .. tostring(expert.money))

print("buy_and_use_spec: ok")
