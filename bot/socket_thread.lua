return [[
local host, port, incoming_name, outgoing_name = ...
require("love.timer")
local json = require("json")
local socket = require("socket")
local incoming = love.thread.getChannel(incoming_name)
local outgoing = love.thread.getChannel(outgoing_name)

local client = socket.tcp()
client:settimeout(8)
local ok, err = client:connect(host, port)
if not ok then
	incoming:push(json.encode({ action = "multibotsTransportError", message = tostring(err) }))
	return
end
client:setoption("tcp-nodelay", true)
client:settimeout(0.05)
incoming:push(json.encode({ action = "multibotsTransportConnected" }))

local buffer = ""
while true do
	local message = outgoing:pop()
	while message do
		if message == "__MULTIBOTS_CLOSE__" then client:close(); return end
		local sent, send_err = client:send(message .. "\n")
		if not sent then
			incoming:push(json.encode({ action = "multibotsTransportError", message = tostring(send_err) }))
			client:close()
			return
		end
		message = outgoing:pop()
	end

	local data, receive_err, partial = client:receive("*l")
	if data then
		incoming:push(buffer .. data)
		buffer = ""
	elseif partial and partial ~= "" then
		buffer = buffer .. partial
	end
	if receive_err == "closed" then
		incoming:push(json.encode({ action = "multibotsTransportError", message = "connection closed" }))
		return
	end
	love.timer.sleep(0.01)
end
]]
