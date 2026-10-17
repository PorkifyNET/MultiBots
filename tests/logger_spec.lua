local files = {}
NFS = {
	createDirectory = function() return true end,
	write = function(path, value) files[path] = value; return true end,
	append = function(path, value) files[path] = (files[path] or "") .. value; return true end,
	remove = function(path) files[path] = nil; return true end,
}
SMODS = { Mods = { MultiBots = { path = "C:/MultiBots/", version = "test" } } }

local Logger = dofile("bot/logger.lua")
local path = Logger.start({ difficulty = "expert", seed = "TEST" })
Logger.write("ACTION", { action = "play", score = 123 })
Logger.write("DECISION", { decision_id = 42, action = "play", regret = 30,
	best_utility = 100, snapshot = "hand:A B" })
Logger.write("DECISION", { decision_id = 46, action = "play", regret = 82.1,
	best_utility = 10431.2, snapshot = "hand:C D" })
Logger.write("DECISION", { decision_id = 47, action = "play", score = 100,
	plan_primary = "Pair", ante = 1, round = "Small", jokers = "j_joker" })
Logger.write("DECISION", { decision_id = 48, action = "play", score = 1000,
	plan_primary = "Two Pair", ante = 1, round = "Small", jokers = "j_joker" })
Logger.write("DECISION", { decision_id = 49, action = "play", score = 100,
	plan_primary = "Pair", ante = 1, round = "Big", jokers = "j_joker" })
Logger.write("DECISION", { decision_id = 50, action = "play", score = 100,
	plan_primary = "Pair", plan_secondary = "Two Pair", ante = 1, round = "Boss", jokers = "j_joker" })
Logger.write("DECISION", { decision_id = 51, action = "play", score = 1000,
	plan_primary = "Two Pair", plan_secondary = "Pair", ante = 1, round = "Boss", jokers = "j_joker" })
Logger.write("DECISION", { decision_id = 54, action = "buy_pack", revealed = "c_earth,c_mars,c_pluto,c_unknown",
	modeled = "c_mercury:5.0", supported = "c_earth,c_mars,c_pluto" })
Logger.write("SHOP_DECISION", { decision_id = 43, action = "shop_decision", shop_id = "1:1",
	offered = "j_unknown", supported = "", snapshot = "shop:one" })
Logger.write("SHOP_DECISION", { decision_id = 44, action = "shop_decision", shop_id = "1:2",
	offered = "j_unknown", supported = "", snapshot = "shop:two" })
Logger.write("SHOP_DECISION", { decision_id = 52, action = "shop_decision", shop_id = "1:3",
	offered = "v_unknown", supported = "", snapshot = "shop:three" })
Logger.write("SHOP_DECISION", { decision_id = 53, action = "shop_decision", shop_id = "1:4",
	offered = "v_unknown", supported = "", snapshot = "shop:four" })
Logger.write("BLIND_FAILURE", { decision_id = 45, action = "fail_round", ante = 2, blind = "Big",
	score = 955, target = 1000, hands_remaining = 0, hands_available = 4,
	discards_remaining = 2, discards_available = 3, consumables_remaining = 1,
	consumables_available = 1, snapshot = "failure:state" })
Logger.write("BLIND_FAILURE", { decision_id = 55, action = "fail_round", ante = 3, blind = "Big",
	score = 955, target = 1000, hands_remaining = 0, hands_available = 4,
	discards_remaining = 0, discards_available = 3, consumables_remaining = 1,
	consumables_available = 1, consumables = "c_hermit", snapshot = "failure:economy" })
Logger.write("FINAL_BOT", {
	jokers = "j_wee,j_trousers", joker_details = "j_wee edition=none effect=rank_scaling_chips scaling=80 target_rank=2,j_trousers edition=foil effect=hand_scaling_mult scaling=12 target_hand=Two Pair",
	deck_count = 5, deck = "H-2-m_lucky-none-Red;H-2-m_lucky-none-Red;S-A-none-none-none;S-A-none-none-none;C-K-m_steel-foil-Gold",
})
Logger.write("FINAL_PLAYER", {
	jokers = "j_baron-none-none-none", joker_details = "j_baron encoded=j_baron-none-none-none target_rank=13",
	deck_count = 3, deck = "H-K-m_steel-none-Red;H-K-m_steel-none-Red;C-K-m_steel-none-Red",
})
Logger.write("PLAYER_ACTION", {
	action = "discard", ante = 2, blind = "Big",
	selected = "H-2-none-none-none", hand = "H-2-none-none-none;S-A-none-none-none",
})
Logger.finish("loseGame", { ante = 4 })

assert(path and path:match("logs/multibots%-"),
	"compact bot logs should be written to the mod's logs directory")
assert(files[path]:match("MULTIBOTS_LOG v2") and files[path]:match("ACTION") and files[path]:match("SUMMARY")
	and files[path]:match("END"),
	"compact bot logs should include their header, decisions, and terminal result")
assert(files[path]:match("unsupported_unique=3") and files[path]:match("unsupported_encounters=4"),
	"v2 summaries should count repeated persistent vouchers once")
assert(not files[path]:match("MP_RLOG"), "compact bot logs must omit the verbose Multiplayer replay stream")
assert(not files[path]:match("snapshot="), "full replay snapshots must not remain in normal decision lines")
assert(files[path]:match("decision_id=42") and files[path]:match("snapshot_id=42"),
	"normal decision lines should reference their decision-keyed snapshot")
local snapshot_path = path:gsub("%.log$", ".snapshots.log")
assert(files[snapshot_path] and files[snapshot_path]:match("MULTIBOTS_SNAPSHOTS v1")
	and files[snapshot_path]:match("snapshot=hand:A%%20B") and files[snapshot_path]:match("snapshot_id=42"),
	"full replay state should be stored in the separate snapshot sidecar")
local report_path = path:gsub("%.log$", ".report.txt")
assert(files[report_path] and files[report_path]:match("MATCH QUALITY REPORT")
	and files[report_path]:match("Player%-win review:")
	and files[report_path]:match("Observed player actions:")
	and files[report_path]:match("discard: 1")
	and files[report_path]:match("Weight areas to review")
	and files[report_path]:match("Action counts cannot estimate numeric weight changes")
	and files[report_path]:match("Run the trainer to measure candidate values")
	and files[report_path]:match("Ante 2 Big discard: selected=H%-2%-none%-none%-none")
	and files[report_path]:match("no direction inferred")
	and files[report_path]:match("Decision 42 had regret 30%.0%%")
	and not files[report_path]:match("Decision 46 had regret")
	and files[report_path]:match("High%-regret threshold: 25%.0%%")
	and files[report_path]:match("Decision 48 followed a plan change with 10%.0x score variance")
	and not files[report_path]:match("Decision 49 followed a plan change")
	and not files[report_path]:match("Decision 51 followed a plan change")
	and files[report_path]:match("near miss <5%%")
	and files[report_path]:match("unused discards=2")
	and files[report_path]:match("suspicious resource conservation")
	and not files[report_path]:match("Ante 3 Big.-unused consumables")
	and not files[report_path]:match("Ante 3 Big.-suspicious resource conservation")
	and files[report_path]:match("Unsupported objects: 3 unique, 4 encounters")
	and files[report_path]:match("c_unknown: 1")
	and not files[report_path]:match("c_earth:")
	and not files[report_path]:match("c_mars:")
	and not files[report_path]:match("c_pluto:")
	and files[report_path]:match("Bot final build:")
	and files[report_path]:match("j_wee edition=none effect=rank_scaling_chips scaling=80 target_rank=2")
	and files[report_path]:match("H%-2%-m_lucky%-none%-Red: 2")
	and files[report_path]:match("Player final build:")
	and files[report_path]:match("H%-K%-m_steel%-none%-Red: 2")
	and files[report_path]:match("No crashes or invalid actions"),
	"finishing a v2 log should automatically create a compact match report")
for file_path in pairs(files) do
	assert(not file_path:match("multibots%-debug"), "normal strategy logging should not create a technical debug log")
end

local bot_win_path = Logger.start({ difficulty = "expert", seed = "TEST" })
Logger.finish("winGame", { ante = 4 })
local bot_win_report_path = bot_win_path:gsub("%.log$", ".report.txt")
assert(files[bot_win_report_path] == nil,
	"bot wins should not create a strategy report")

SMODS = nil
assert(Logger.start({}) == nil, "logging should remain disabled when the mod is unavailable")
assert(Logger.finish("stopGame", { deck = 0, jokers = "" }) == nil,
	"finishing without a started logger should not render a report")

print("logger_spec: ok")
