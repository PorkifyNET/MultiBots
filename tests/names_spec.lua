local Names = dofile("bot/names.lua")

assert(Names.classic("Expert") == "MultiBot (Expert)", "classic names should retain the existing convention")

local picks = { 2, 3 }
local generated = Names.generate(function() return table.remove(picks, 1) end)
assert(generated == Names.first_words[2] .. Names.second_words[3],
	"generated names should combine one entry from each dictionary")
assert(Names.resolve({ name_mode = "generated", generated_name = "Lucky Joker" }, "Easy") == "Lucky Joker",
	"a generated name should remain stable until explicitly rerolled")
assert(Names.resolve({ name_mode = "custom", custom_name = "  Card~Shark\n" }, "Hard") == "CardShark",
	"custom names should be trimmed and remove protocol/control characters")
assert(Names.resolve({ name_mode = "custom", custom_name = "  " }, "Hard") == "MultiBot (Hard)",
	"an empty custom name should safely fall back to the classic convention")

print("names_spec: ok")
