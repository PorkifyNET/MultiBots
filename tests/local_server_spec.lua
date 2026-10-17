local LocalServer = dofile("bot/local_server.lua")

local human_messages, bot_messages = {}, {}
local server = LocalServer.new(
	function(message) human_messages[#human_messages + 1] = message end,
	function(message) bot_messages[#bot_messages + 1] = message end,
	function() return "BOTAA" end,
	function() return "BOTSEED1" end
)

server:receive("host", { action = "username", username = "Human~1", modHash = "same" })
server:receive("guest", { action = "username", username = "MultiBot~2", modHash = "same" })
server:receive("host", { action = "createLobby", gameMode = "attrition" })
assert(server.code == "BOTAA", "embedded server should create a lobby")
assert(human_messages[#human_messages].action == "lobbyInfo", "host should receive lobby info")

server:receive("guest", { action = "readyLobby" })
assert(server.bot.lobby_ready, "bot should be ready in the lobby")
server:receive("host", { action = "lobbyOptions", starting_lives = 2, death_on_round_loss = true })
server:receive("host", { action = "startGame" })
assert(server.host.lives == 2 and server.bot.lives == 2, "lobby starting lives should apply")
assert(not server.bot.lobby_ready, "starting a match must consume the bot's lobby readiness")
local start_message
for _, message in ipairs(bot_messages) do
	if message.action == "startGame" then start_message = message end
end
assert(start_message and start_message.stake == 1,
	"embedded startGame must include a stake for Multiplayer's replay manifest")

server:receive("guest", { action = "failRound" })
assert(server.bot.lives == 1, "a bot that fails a non-PvP blind should lose a life")

server:receive("host", { action = "readyBlind" })
server:receive("guest", { action = "readyBlind" })
assert(human_messages[#human_messages].action == "startBlind", "both ready players should start PvP")

server:receive("host", { action = "playHand", score = "100", handsLeft = 0 })
server:receive("guest", { action = "playHand", score = "200", handsLeft = 0 })
assert(server.host.lives == 1, "PvP loser should lose one life")
assert(human_messages[#human_messages].action == "endPvP" and human_messages[#human_messages].lost,
	"losing player should receive the normal endPvP message")

server:receive("guest", { action = "failRound" })
assert(not server.in_game and bot_messages[#bot_messages].action == "loseGame",
	"a terminal life loss must stop the embedded match and notify the bot")
local terminal_messages = #bot_messages
server:receive("guest", { action = "failRound" })
assert(#bot_messages == terminal_messages, "terminal matches must ignore later queued Blind failures")

server:receive("host", { action = "getNemesisDeck" })
assert(bot_messages[#bot_messages].action == "getNemesisDeck", "end-game requests should relay to the bot")

server:receive("host", { action = "stopGame" })
assert(not server.in_game and not server.bot.lobby_ready,
	"returning to the embedded lobby must reset match and lobby-ready state")
server:receive("guest", { action = "readyLobby" })
assert(server.bot.lobby_ready, "the embedded bot must be able to ready for a rematch")
server:receive("host", { action = "startGame" })
local starts = 0
for _, message in ipairs(bot_messages) do
	if message.action == "startGame" then starts = starts + 1 end
end
assert(starts == 2 and server.in_game,
	"the embedded lobby must start a second match without being recreated")

print("local_server_spec: ok")
