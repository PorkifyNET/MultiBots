local Status = dofile("bot/status.lua")

Status.configure({
	pace = {
		selecting_seconds = 4,
		blind_base_seconds = 8,
		seconds_per_action = 5.5,
		minimum_blind_seconds = 25,
		shop_seconds = 18,
	},
})

local replay = {
	_multibots_state = {
		decisions = {
			{ ante = 2, round = "Small", type = "play" },
			{ ante = 2, round = "Small", type = "discard" },
			{ ante = 2, round = "Small", type = "play" },
			{ ante = 2, round = "Big", type = "discard" },
			{ ante = 2, round = "Big", type = "play" },
			{ ante = 2, round = "Big", type = "play" },
			{ ante = 2, round = "Big", type = "play" },
			{ ante = 2, round = "Big", type = "play" },
		},
	},
}

local timeline, ready_at = Status.build_timeline(replay, 2)
assert(#timeline == 6, "expected selecting, two blinds, two shops, and ready")
assert(timeline[2].duration == 25, "Small Blind should respect the minimum duration")
assert(timeline[4].duration == 35.5, "Big Blind should scale with simulated actions")
assert(ready_at == 100.5, "unexpected PvP-ready timestamp: " .. tostring(ready_at))
assert(ready_at > 90, "bot must not reach PvP on the old six-second schedule")

local first_ante, first_ante_end = Status.build_timeline(replay, 1, 2)
assert(#first_ante == 7, "pre-PvP Ante should include the normal Boss and its shop")
assert(first_ante[6].blind == "Boss" and first_ante[7].type == "loc_shop",
	"Ante 1 should end at the post-Boss shop, not PvP readiness")
assert(first_ante[7].duration == math.huge and first_ante_end > ready_at,
	"bot should wait for the host to advance after its normal Boss shop")

local skipped_small, skipped_ready = Status.build_timeline(replay, 2, 2, { Small = true })
assert(#skipped_small == 4, "skipping Small should remove its Blind and shop phases")
assert(skipped_small[2].blind == "Big" and skipped_small[3].type == "loc_shop"
	and skipped_small[4].type == "loc_ready", "the remaining Big Blind path should stay intact")
assert(skipped_ready == 57.5, "skip timeline should retain selecting, Big, and shop timing")

print("status_spec: ok")
