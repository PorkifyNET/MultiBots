local PeerPool = {
	peers = {},
	factory = nil,
	change_callback = nil,
}

local expert_temperatures = { 0.15, 0.30, 0.50, 0.75 }

function PeerPool.configure(factory)
	PeerPool.factory = factory
end

function PeerPool.on_change(callback)
	PeerPool.change_callback = callback
end

local function notify_change(force)
	local count = #PeerPool.peers
	if force or count ~= PeerPool.last_notified_count then
		PeerPool.last_notified_count = count
		local player_ids = {}
		for _, peer in ipairs(PeerPool.peers) do
			if peer.player_id then player_ids[#player_ids + 1] = tostring(peer.player_id) end
		end
		if PeerPool.change_callback then PeerPool.change_callback(count, player_ids) end
	end
end

local function next_name_number(base_name)
	local used = {}
	for _, peer in ipairs(PeerPool.peers) do
		if peer.multibots_base_name == base_name then
			used[peer.multibots_name_number or 1] = true
		end
	end
	local number = 1
	while used[number] do number = number + 1 end
	return number
end

function PeerPool.start(setup, e)
	if not PeerPool.factory then return false, "Bot peer factory is unavailable." end
	local bot_number = (PeerPool.next_bot_number or 0) + 1
	local peer_setup = {}
	for key, value in pairs(setup or {}) do peer_setup[key] = value end
	if peer_setup.difficulty == "expert" and peer_setup.decision_temperature == nil then
		peer_setup.decision_temperature = expert_temperatures[(bot_number - 1) % #expert_temperatures + 1]
	end
	local base_name = tostring(peer_setup.name or "MultiBot")
	local name_number = next_name_number(base_name)
	peer_setup.name = name_number == 1 and base_name or (base_name .. " " .. tostring(name_number))
	if bot_number > 1 then
		peer_setup.bot_blind_col = ((tonumber(peer_setup.bot_blind_col) or 2) + bot_number - 2) % 25 + 1
	end
	local peer = PeerPool.factory()
	local ok, err = peer.start(peer_setup, e)
	if not ok then return false, err end
	peer.multibots_base_name = base_name
	peer.multibots_name_number = name_number
	PeerPool.next_bot_number = bot_number
	PeerPool.peers[#PeerPool.peers + 1] = peer
	PeerPool.lobby_code = MP and MP.LOBBY and MP.LOBBY.code or PeerPool.lobby_code
	notify_change()
	return true, peer
end

function PeerPool.update(dt)
	if PeerPool.lobby_code and (not MP or not MP.LOBBY or MP.LOBBY.code ~= PeerPool.lobby_code) then
		PeerPool.reset(false)
		return
	end
	for index = #PeerPool.peers, 1, -1 do
		local peer = PeerPool.peers[index]
		peer.update(dt)
		if not peer.is_active() then
			table.remove(PeerPool.peers, index)
			notify_change()
		end
	end
	local player_ids = {}
	for _, player in ipairs((MP and MP.LOBBY and MP.LOBBY.players) or {}) do
		player_ids[#player_ids + 1] = tostring(player.id or player.player_id or player.username or "")
	end
	table.sort(player_ids)
	local signature = table.concat(player_ids, "|")
	if signature ~= PeerPool.player_signature then
		PeerPool.player_signature = signature
		notify_change(true)
	end
end

function PeerPool.reset(leave_lobby)
	for _, peer in ipairs(PeerPool.peers) do peer.reset(false) end
	PeerPool.peers = {}
	PeerPool.lobby_code = nil
	PeerPool.next_bot_number = 0
	PeerPool.player_signature = nil
	notify_change()
	if leave_lobby and MP and MP.LOBBY and MP.LOBBY.code
		and MP.ACTIONS and type(MP.ACTIONS.leave_lobby) == "function" then
		MP.ACTIONS.leave_lobby()
	end
end

function PeerPool.is_active()
	for _, peer in ipairs(PeerPool.peers) do
		if peer.is_active() then return true end
	end
	return false
end

function PeerPool.count()
	return #PeerPool.peers
end

function PeerPool.install()
	local update_ref = Game.update
	function Game:update(dt)
		local result = update_ref(self, dt)
		PeerPool.update(dt)
		return result
	end
end

return PeerPool
