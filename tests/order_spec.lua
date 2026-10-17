local Order = dofile("bot/order.lua")

Order.push({ "j_joker", "c_mercury" })
Order.push({ "c_hanged_man" })
local first = Order.take()
local second = Order.take()
assert(first[1] == "j_joker" and first[2] == "c_mercury", "ordered shop must preserve visible card order")
assert(second[1] == "c_hanged_man", "ordered shops must be consumed FIFO")
assert(Order.take() == nil, "empty ordered shop queue should wait instead of inventing offers")
Order.clear()
assert(Order.take() == nil, "clearing an ordered run must remove stale shop snapshots")

local function card(key, edition)
	return { config = { center = { key = key } }, edition = edition }
end

G = {
	STATES = { SHOP = 1, BOOSTER = 2 }, STATE = 1,
	GAME = { round = 4, round_resets = { ante = 2 } },
	shop_jokers = { cards = { card("j_jolly"), card("j_todo_list") } },
}
Order.update(0.1)
Order.update(0.6)
local initial = Order.take()
assert(initial and #initial == 2, "a stable shop should be captured once")

-- Opening a pack changes state and can reconstruct the shop card area. This is
-- still round 4 and must not enqueue the leftover card as a second bot shop.
G.STATE = G.STATES.BOOSTER
Order.update(0.1)
G.STATE = G.STATES.SHOP
G.shop_jokers = { cards = { card("j_todo_list") } }
Order.update(0.1)
Order.update(0.6)
assert(Order.take() == nil, "returning from a booster must not capture stale shop leftovers")

-- Multiplayer does not always increment G.GAME.round between distinct shops
-- (for example when a Blind was skipped). Leaving for ordinary gameplay and
-- entering a rebuilt shop must still unlock a fresh capture.
G.STATE = 3
Order.update(0.1)
G.STATE = G.STATES.SHOP
G.shop_jokers = { cards = { card("j_banner") } }
Order.update(0.1)
Order.update(0.6)
local same_round_shop = Order.take()
assert(same_round_shop and same_round_shop[1] == "j_banner",
	"a real shop transition must capture again even when G.GAME.round is unchanged")

G.GAME.round = 5
G.shop_jokers = { cards = { card("j_half") } }
Order.update(0.1)
Order.update(0.6)
local next_round = Order.take()
assert(next_round and next_round[1] == "j_half", "a new completed round should unlock the next shop capture")

Order.clear()
G.GAME.round = 6
G.shop_jokers = { cards = { card("j_abstract", { negative = true }) } }
Order.update(0.01)
Order.update(0.11)
local edition_snapshot = Order.take()
assert(edition_snapshot[1] == "j_abstract",
	"animation-skip shops should be captured after a tenth of a stable second")
assert(edition_snapshot._metadata[1].edition == "negative",
	"Order snapshots should preserve visible Joker editions for exact tag handling")

Order.clear()
G.GAME.round = 7
G.STATE = G.STATES.SHOP
G.shop_jokers = { cards = { card("j_even_steven") } }
Order.update(0.01)
G.STATE = G.STATES.BOOSTER
Order.update(0.01)
local rushed_snapshot = Order.take()
assert(rushed_snapshot and rushed_snapshot[1] == "j_even_steven",
	"leaving a shop before the debounce expires must flush its last visible Order snapshot")
G = nil

print("order_spec: ok")
