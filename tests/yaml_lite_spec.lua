local YamlLite = dofile("bot/yaml_lite.lua")

local function expect_error(text, fragment, message)
	local ok, err = pcall(YamlLite.parse, text)
	assert(not ok, message .. ": parsing should fail")
	assert(tostring(err):find(fragment, 1, true), message .. ": unexpected error " .. tostring(err))
end

local parsed = YamlLite.parse(table.concat({
	"# full-line comment",
	"",
	"scale: 2   # trailing comment",
	"offset: -3",
	"ratio: 0.25",
	"jokers:   # section comment",
	"  j_joker: 50   # Joker",
	"",
	"  # indented comment",
	"  j_blueprint: 100",
	"  j_cheap: -1.5",
	"tags:",
	"  tag_double: 0",
}, "\r\n"))

assert(parsed.scale == 2, "top-level integers should parse")
assert(parsed.offset == -3, "negative integers should parse")
assert(parsed.ratio == 0.25, "floats should parse")
assert(type(parsed.jokers) == "table", "sections should become tables")
assert(parsed.jokers.j_joker == 50, "trailing comments should be ignored")
assert(parsed.jokers.j_blueprint == 100, "comments and blank lines inside a section should be skipped")
assert(parsed.jokers.j_cheap == -1.5, "negative floats should parse")
assert(parsed.tags.tag_double == 0, "a later section should collect its own keys")
assert(parsed.tag_double == nil and parsed.jokers.tag_double == nil, "section keys should stay in their section")

local lf = YamlLite.parse("a: 1\nb:\n    c: 2\n")
assert(lf.a == 1 and lf.b.c == 2, "LF files and four-space indentation should parse")

assert(YamlLite.load("tests/fixtures/does_not_exist.yaml") == nil, "a missing file should load as nil")

local values = YamlLite.load("bot/card_values.yaml")
assert(values and values.jokers.j_joker == 50, "the shipped card values should parse")

expect_error("a:\n\tb: 1\n", "card_values.yaml line 2: tabs are not allowed", "tab indentation")
expect_error("a: 1\nb: fast\n", "card_values.yaml line 2: value is not a number: b: fast", "non-number value")
expect_error("a:\n  b: 1\n  b: 2\n", "card_values.yaml line 3: duplicate key", "duplicate section key")
expect_error("a: 1\n\na: 2\n", "card_values.yaml line 3: duplicate key", "duplicate top-level key")
expect_error("a:\n  b:\n    c: 1\n", "card_values.yaml line 2: nested sections are not supported", "nested section")
expect_error("a:\n  b: 1\n    c: 1\n", "card_values.yaml line 3: inconsistent indentation", "deeper indentation")
expect_error("  b: 1\n", "card_values.yaml line 1: unexpected indentation", "indentation without a section")
expect_error("just text\n", "card_values.yaml line 1: expected 'key: number'", "missing colon")

local ok, err = pcall(YamlLite.parse, "a: x\n", "custom.yaml")
assert(not ok and tostring(err):find("custom.yaml line 1:", 1, true), "errors should use the given file name")

print("yaml_lite_spec: ok")
