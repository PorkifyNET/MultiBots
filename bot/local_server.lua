local LocalServer = {}

local function player(role, name)
	return { role = role, name = name, ready = false, lobby_ready = false, lives = 4, score = 0, hands = 4, skips = 0 }
end

function LocalServer.new(send_human, send_bot, random_code, random_seed)
	local self = {
		send_human = send_human,
		send_bot = send_bot,
		random_code = random_code,
		random_seed = random_seed,
		host = player("host", "Player~1"),
		bot = player("guest", "MultiBot~2"),
		options = {},
		code = nil,
		gamemode = "attrition",
		in_game = false,
	}
	return setmetatable(self, { __index = LocalServer })
end

function LocalServer:send(role, message)
	if role == "host" then self.send_human(message) else self.send_bot(message) end
end

function LocalServer:broadcast(message)
	self:send("host", message)
	self:send("guest", message)
end

function LocalServer:lobby_info()
	self:send("host", {
		action = "lobbyInfo",
		host = self.host.name,
		hostHash = self.host.mod_hash or "",
		hostCached = true,
		guest = self.bot.name,
		guestHash = self.bot.mod_hash or self.host.mod_hash or "",
		guestCached = true,
		guestReady = self.bot.lobby_ready,
		isHost = true,
	})
	self:send("guest", {
		action = "lobbyInfo",
		host = self.host.name,
		hostHash = self.host.mod_hash or "",
		hostCached = true,
		guest = self.bot.name,
		guestHash = self.bot.mod_hash or self.host.mod_hash or "",
		guestCached = true,
		guestReady = self.bot.lobby_ready,
		isHost = false,
	})
end

local function enemy(self, role)
	return role == "host" and self.bot or self.host
end

local function reset_match_flags(self)
	self.host.ready, self.bot.ready = false, false
	self.host.lobby_ready, self.bot.lobby_ready = false, false
	self.host.score, self.bot.score = 0, 0
	self.host.hands, self.bot.hands = 4, 4
end

function LocalServer:enemy_info(role, source)
	self:send(role, {
		action = "enemyInfo",
		score = tostring(source.score),
		handsLeft = source.hands,
		skips = source.skips,
		lives = source.lives,
	})
end

function LocalServer:lose_life(loser, winner)
	loser.lives = loser.lives - 1
	self:send(loser.role, { action = "playerInfo", lives = loser.lives })
	self:enemy_info(winner.role, loser)
	if loser.lives <= 0 then
		self.in_game = false
		reset_match_flags(self)
		self:send(loser.role, { action = "loseGame" })
		self:send(winner.role, { action = "winGame" })
		return true
	end
	return false
end

function LocalServer:play_hand(role, message)
	local current = role == "host" and self.host or self.bot
	local other = enemy(self, role)
	current.score = tonumber(message.score) or 0
	current.hands = math.floor(tonumber(message.handsLeft) or 0)
	self:enemy_info(other.role, current)
	self:enemy_info(current.role, other)

	local finished = (current.hands <= 0 and current.score < other.score)
		or (other.hands <= 0 and other.score < current.score)
		or (current.hands <= 0 and other.hands <= 0)
	if not finished then return end

	if current.score == other.score then
		self:broadcast({ action = "endPvP", lost = false })
		return
	end
	local winner = current.score > other.score and current or other
	local loser = winner == current and other or current
	if not self:lose_life(loser, winner) then
		self:send(winner.role, { action = "endPvP", lost = false })
		self:send(loser.role, { action = "endPvP", lost = true })
	end
end

function LocalServer:receive(role, message)
	local current = role == "host" and self.host or self.bot
	local other = enemy(self, role)
	local action = message.action
	if action == "username" then
		current.name = message.username or current.name
		current.mod_hash = message.modHash or current.mod_hash
		if self.code then self:lobby_info() end
	elseif action == "version" or action == "keepAliveAck" or action == "syncClient" then
		return
	elseif action == "createLobby" then
		self.code = self.random_code()
		self.gamemode = message.gameMode or "attrition"
		self:send("host", { action = "joinedLobby", code = self.code, type = self.gamemode })
		self:send("guest", { action = "joinedLobby", code = self.code, type = self.gamemode })
		self:lobby_info()
	elseif action == "lobbyInfo" then
		self:lobby_info()
	elseif action == "lobbyOptions" then
		for key, value in pairs(message) do if key ~= "action" then self.options[key] = value end end
		local copy = { action = "lobbyOptions", gamemode = self.gamemode }
		for key, value in pairs(self.options) do copy[key] = value end
		self:send("guest", copy)
	elseif action == "readyLobby" then
		current.lobby_ready = true
		self:lobby_info()
	elseif action == "unreadyLobby" then
		current.lobby_ready = false
		self:lobby_info()
	elseif action == "startGame" and role == "host" then
		local lives = tonumber(self.options.starting_lives) or 4
		local stake = tonumber(message.stake) or tonumber(self.options.stake) or 1
		reset_match_flags(self)
		self.host.skips, self.bot.skips = 0, 0
		self.host.lives, self.bot.lives = lives, lives
		self.in_game = true
		self:broadcast({ action = "startGame", deck = "c_multiplayer_1", seed = self.random_seed(), stake = stake })
		self:broadcast({ action = "playerInfo", lives = lives })
	elseif action == "readyBlind" and self.in_game then
		current.ready = true
		if self.host.ready and self.bot.ready then
			self.host.ready, self.bot.ready = false, false
			self.host.score, self.bot.score = 0, 0
			self.host.hands, self.bot.hands = 4, 4
			self:broadcast({ action = "startBlind", firstPlayer = "host" })
		end
	elseif action == "playHand" and self.in_game then
		self:play_hand(role, message)
	elseif action == "setLocation" then
		self:send(other.role, { action = "enemyLocation", location = message.location or "" })
	elseif action == "skip" then
		current.skips = tonumber(message.skips) or current.skips
		self:enemy_info(other.role, current)
	elseif action == "newRound" then
		return
	elseif action == "failRound" and self.in_game then
		if self.options.death_on_round_loss then self:lose_life(current, other) end
	elseif action == "failTimer" and self.in_game then
		self:lose_life(current, other)
	elseif action == "stopGame" then
		self.in_game = false
		reset_match_flags(self)
		self:broadcast({ action = "stopGame" })
		self:lobby_info()
	elseif action == "leaveLobby" then
		self:send(other.role, { action = "stopGame" })
	elseif action == "getEndGameJokers" or action == "getNemesisDeck" or action == "endGameStatsRequested"
		or action == "receiveEndGameJokers" or action == "receiveNemesisDeck" or action == "nemesisEndGameStats"
		or action == "startAnteTimer" or action == "pauseAnteTimer" or action == "sendPhantom"
		or action == "removePhantom" or action == "asteroid" or action == "soldJoker"
		or action == "spentLastShop" or action == "magnet" or action == "magnetResponse"
		or action == "letsGoGamblingNemesis" or action == "eatPizza" then
		local copy = {}
		for key, value in pairs(message) do copy[key] = value end
		self:send(other.role, copy)
	end
end

return LocalServer
