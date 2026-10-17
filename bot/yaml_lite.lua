-- A deliberately tiny YAML subset: top-level "key: number" pairs and one level
-- of "section:" blocks holding indented "key: number" pairs. Anything else is
-- rejected with the file name and line number so a typo never passes silently.
local YamlLite = {}

local DEFAULT_NAME = "card_values.yaml"

local function fail(name, line_number, reason, text)
	error(string.format("%s line %d: %s: %s", name, line_number, reason, text), 0)
end

local function strip_comment(line)
	-- A '#' starts a comment at the beginning of the line or after whitespace.
	-- Keys never contain '#', so a '#' glued to a key is reported as a bad key.
	if line:sub(1, 1) == "#" then return "" end
	local position = line:find("%s#")
	if position then return line:sub(1, position - 1) end
	return line
end

local function parse_number(text)
	if not text:match("^%-?%d+$") and not text:match("^%-?%d+%.%d+$") and not text:match("^%-?%.%d+$") then
		return nil
	end
	return tonumber(text)
end

local function parse_pair(name, line_number, body, raw)
	local key, value = body:match("^([%w_%.%-]+):%s+(.-)%s*$")
	if not key then
		key = body:match("^([%w_%.%-]+):%s*$")
		if key then return key, nil end
		fail(name, line_number, "expected 'key: number'", raw)
	end
	local number = parse_number(value)
	if number == nil then fail(name, line_number, "value is not a number", raw) end
	return key, number
end

function YamlLite.parse(text, name)
	name = name or DEFAULT_NAME
	assert(type(text) == "string", "YamlLite.parse expects a string")
	local result = {}
	local section, section_name, section_indent
	local line_number = 0
	-- Normalise CRLF and lone CR so both Windows and Unix files parse alike.
	text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
	if text:sub(-1) ~= "\n" then text = text .. "\n" end
	for raw in text:gmatch("([^\n]*)\n") do
		line_number = line_number + 1
		if raw:find("\t") then fail(name, line_number, "tabs are not allowed", raw) end
		local line = strip_comment(raw):gsub("%s+$", "")
		if line ~= "" then
			local indent = #line:match("^( *)")
			local body = line:sub(indent + 1)
			if indent == 0 then
				local key, value = parse_pair(name, line_number, body, raw)
				if result[key] ~= nil then fail(name, line_number, "duplicate key", raw) end
				if value == nil then
					section, section_name, section_indent = {}, key, nil
					result[key] = section
				else
					section, section_name, section_indent = nil, nil, nil
					result[key] = value
				end
			else
				if not section then fail(name, line_number, "unexpected indentation", raw) end
				section_indent = section_indent or indent
				if indent ~= section_indent then fail(name, line_number, "inconsistent indentation", raw) end
				local key, value = parse_pair(name, line_number, body, raw)
				if value == nil then fail(name, line_number, "nested sections are not supported", raw) end
				if section[key] ~= nil then fail(name, line_number, "duplicate key in " .. section_name, raw) end
				section[key] = value
			end
		end
	end
	return result
end

local function read_file(path)
	-- In game, SMODS exposes nativefs as NFS, which reads absolute mod paths.
	if type(NFS) == "table" and type(NFS.read) == "function" then
		if type(NFS.getInfo) == "function" and not NFS.getInfo(path) then return nil end
		local contents = NFS.read(path)
		if type(contents) == "string" then return contents end
		return nil
	end
	local file = io.open(path, "rb")
	if not file then return nil end
	local contents = file:read("*a")
	file:close()
	return contents
end

function YamlLite.load(path, name)
	local contents = read_file(path)
	if contents == nil then return nil end
	return YamlLite.parse(contents, name or path:match("([^/\\]+)$") or path)
end

return YamlLite
