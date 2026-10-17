local captured_manifest, captured_args

reset_idol_card = function()
	G.GAME.current_round.idol_card.rank = "Ace"
	G.GAME.current_round.idol_card.suit = "Spades"
end

MP = {
	LOBBY = { config = { stake = 4 } },
	RLOG = { begin_run = function(manifest) captured_manifest = manifest end },
}
G = {
	GAME = { stake = 2 },
	FUNCS = { lobby_start_run = function(_, args) captured_args = args end },
}

local Compat = dofile("bot/compat.lua")
Compat.install()
MP.RLOG.begin_run({ seed = "TEST" })
G.FUNCS.lobby_start_run(nil, { seed = "TEST" })
assert(captured_manifest.stake == 4,
	"a remote startGame without stake must use the lobby's configured stake in the replay manifest")
assert(captured_args.stake == 4,
	"a remote startGame without stake must use the lobby's configured stake when starting the run")

MP.RLOG.begin_run({ stake = 7 })
G.FUNCS.lobby_start_run(nil, { stake = 7 })
assert(captured_manifest.stake == 7 and captured_args.stake == 7,
	"an explicit server stake must remain authoritative")

G.GAME.current_round = { idol_card = nil }
reset_idol_card()
assert(G.GAME.current_round.idol_card.rank == "Ace"
	and G.GAME.current_round.idol_card.suit == "Spades",
	"resetting Idol state after snapshot playback clears it must not crash")

print("compat_spec: ok")
