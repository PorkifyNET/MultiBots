local MOD = SMODS.current_mod

SMODS.Atlas({
    key = "modicon", 
    path = "ModIcon.png", 
    px = 34,
    py = 34,
    atlas_table = "ASSET_ATLAS"
})

local EXPERIMENTAL_MP = MP and MP.PROTOCOL and tonumber(MP.PROTOCOL.VERSION) == 2

if not MP or not MP.UI or (not EXPERIMENTAL_MP and not MP.GHOST) then
	sendErrorMessage("MultiBots requires Balatro Multiplayer 0.5.5 or newer.", "MULTIBOTS")
	return
end

local function load_module(path)
	local chunk, load_error = SMODS.load_file(path, "MultiBots")
	if not chunk then error("Could not load " .. path .. ": " .. tostring(load_error)) end
	local ok, result = pcall(chunk)
	if not ok then error("Could not initialize " .. path .. ": " .. tostring(result)) end
	return result
end

local modules_ok, modules = pcall(function()
	return {
		PRNG = load_module("bot/prng.lua"),
		Weights = load_module("bot/weights.lua"),
		Cards = load_module("bot/cards.lua"),
		Names = load_module("bot/names.lua"),
		Rulesets = load_module("bot/rulesets.lua"),
		Content = load_module("bot/content.lua"),
		Evaluator = load_module("bot/evaluator.lua"),
		Strategy = load_module("bot/strategy.lua"),
		Policy = load_module("bot/policy.lua"),
		Simulator = load_module("bot/simulator.lua"),
		Playback = load_module("bot/playback.lua"),
		Endgame = load_module("bot/endgame.lua"),
		LocalServer = load_module("bot/local_server.lua"),
		Compat = load_module("bot/compat.lua"),
		Logger = load_module("bot/logger.lua"),
		PlayerObserver = load_module("bot/player_observer.lua"),
		Order = load_module("bot/order.lua"),
		Peer = load_module("bot/peer.lua"),
		PeerPool = load_module("bot/peer_pool.lua"),
		SpectatorGuard = load_module("bot/spectator_guard.lua"),
		Status = load_module("bot/status.lua"),
		UI = load_module("bot/ui.lua"),
		Generator = load_module("generator.lua"),
	}
end)
if not modules_ok then
	sendErrorMessage(tostring(modules), "MULTIBOTS")
	return
end

local Generator = modules.Generator
Generator.configure(modules)
modules.Peer.configure(modules)
modules.PeerPool.configure(function()
	local dependencies = {}
	for key, value in pairs(modules) do dependencies[key] = value end
	dependencies.Logger = load_module("bot/logger.lua")
	local peer = load_module("bot/peer.lua")
	peer.configure(dependencies)
	return peer
end)

local ActivePeer = EXPERIMENTAL_MP and modules.PeerPool or modules.Peer

MULTIBOTS = {
	generator = Generator,
	version = MOD.version,
	status = modules.Status,
	ui = modules.UI,
	playback = modules.Playback,
	endgame = modules.Endgame,
	peer = ActivePeer,
	experimental_mp = EXPERIMENTAL_MP,
	content = modules.Content,
	strategy = modules.Strategy,
	names = modules.Names,
	rulesets = modules.Rulesets,
}

function MULTIBOTS.is_active()
	return ActivePeer.is_active() or modules.Status.is_active()
end

modules.Status.configure(MOD.config)
modules.Compat.install()
if not EXPERIMENTAL_MP then
	modules.Playback.install()
	modules.Endgame.install()
	modules.UI.install()
end
modules.Status.install()
modules.Order.install()
ActivePeer.install()
local observed_player_callbacks = modules.PlayerObserver.install({
	Logger = modules.Logger,
	is_active = function() return MULTIBOTS.is_active() end,
	get_loggers = function()
		if ActivePeer ~= modules.PeerPool then return { modules.Logger } end
		local loggers = {}
		for _, peer in ipairs(modules.PeerPool.peers) do
			if peer.is_active() and peer.dependencies and peer.dependencies.Logger then
				loggers[#loggers + 1] = peer.dependencies.Logger
			end
		end
		return loggers
	end,
})
if observed_player_callbacks == 0 then
	sendWarnMessage("Player action observer found no game callbacks; player-win action review will be incomplete.", "MULTIBOTS")
end

local difficulty_labels = { "Easy", "Normal", "Hard", "Expert" }
local name_mode_order = { "classic", "generated", "custom" }
local name_mode_labels = { "Classic", "Two-word", "Custom" }
local pace_order = { "relaxed", "standard", "quick" }
local pace_labels = { "Relaxed", "Standard", "Quick" }
local skip_mode_order = {
	"disabled", "reactive", "negative_only", "aggressive",
	"unforgivable", "unlimited_unforgivable",
}
local skip_mode_labels = {
	"Disabled", "Reactive", "Negative Skips Only", "Aggressive",
	"Unforgivable", "Unlimited Unforgivable",
}
local skip_mode_descriptions = {
	disabled = "Never skips a Blind.",
	reactive = "Uses cash, Joker needs, tags, and its previous PvP lead to decide.",
	negative_only = "Skips only for a Negative or Double Tag, after meeting safety limits.",
	aggressive = "Uses Reactive reasoning with a much higher chance to take a skip.",
	unforgivable = "Always skips after meeting certain conditions.",
	unlimited_unforgivable = "Skips every Blind with reckless abandon.",
}
local pace_presets = {
	relaxed = {
		selecting_seconds = 6, blind_base_seconds = 10, seconds_per_action = 7,
		minimum_blind_seconds = 38, shop_seconds = 26,
	},
	standard = {
		selecting_seconds = 4, blind_base_seconds = 8, seconds_per_action = 5.5,
		minimum_blind_seconds = 25, shop_seconds = 18,
	},
	quick = {
		selecting_seconds = 2, blind_base_seconds = 6, seconds_per_action = 4,
		minimum_blind_seconds = 18, shop_seconds = 10,
	},
}

local tabbed_setup_definition
local setup_active_tab = "profile"
local how_selected_topic = "chips"
local how_selected_mode = "info"

local function list_index(items, value, fallback)
	for index, item in ipairs(items) do if item == value then return index end end
	return fallback or 1
end

local function save_setup()
	if SMODS.save_mod_config then pcall(SMODS.save_mod_config, MOD) end
end

local function normalize_setup()
	MOD.config.last_difficulty = Generator.difficulties[MOD.config.last_difficulty]
		and MOD.config.last_difficulty or "normal"
	MOD.config.name_mode = name_mode_order[list_index(name_mode_order, MOD.config.name_mode, 1)]
	MOD.config.pace_preset = pace_order[list_index(pace_order, MOD.config.pace_preset, 2)]
	MOD.config.bot_blind_col = math.max(1, math.min(25, tonumber(MOD.config.bot_blind_col) or 2))
	MOD.config.behavior = MOD.config.behavior or {}
	MOD.config.strategy_weights = MOD.config.strategy_weights or {
		enabled = false, name = "defaults", values = {},
	}
	MOD.config.strategy_weights.values = MOD.config.strategy_weights.values or {}
	if MOD.config.behavior.timer_player == nil then MOD.config.behavior.timer_player = true end
	if not skip_mode_descriptions[MOD.config.behavior.skip_mode] then
		MOD.config.behavior.skip_mode = MOD.config.behavior.skip_blinds == false and "disabled" or "reactive"
	end
	MOD.config.custom_name = modules.Names.sanitize(MOD.config.custom_name or "MultiBot")
	if modules.Names.sanitize(MOD.config.generated_name) == "" then
		MOD.config.generated_name = modules.Names.generate()
	end
end

local function active_strategy_weights()
	local profile = MOD.config.strategy_weights or {}
	if profile.enabled ~= true then return nil, "defaults" end
	if next(profile.values or {}) == nil then
		sendWarnMessage("Trained strategy profile is enabled but empty; using defaults", "MULTIBOTS")
		return nil, "defaults-empty-profile"
	end
	local values, errors = modules.Weights.validate(profile.values)
	if not values then
		sendWarnMessage("Trained strategy profile is invalid; using defaults: "
			.. table.concat(errors or {}, "; "), "MULTIBOTS")
		return nil, "defaults-invalid-profile"
	end
	return values, modules.Names.sanitize(profile.name or "trained")
end

local function update_name_preview()
	normalize_setup()
	local difficulty = Generator.difficulties[MOD.config.last_difficulty]
	MOD.config.bot_name_preview = modules.Names.resolve(MOD.config, difficulty and difficulty.name or "Normal")
	return MOD.config.bot_name_preview
end

local function apply_pace(preset)
	local selected = pace_presets[preset] or pace_presets.standard
	MOD.config.pace = MOD.config.pace or {}
	for key, value in pairs(selected) do MOD.config.pace[key] = value end
end

local function selected_practice_ruleset()
	return (MP.SP and MP.SP.ruleset) or (MP.LOBBY and MP.LOBBY.config and MP.LOBBY.config.ruleset)
end

local function bot_ruleset_allowed(ruleset)
	ruleset = ruleset or selected_practice_ruleset()
	local registered = type(ruleset) == "string" and MP.Rulesets and MP.Rulesets[ruleset] or nil
	return modules.Rulesets.allows_bot(registered or ruleset)
end

local function experimental_lobby_allowed()
	if not EXPERIMENTAL_MP then return true end
	local lobby = MP.LOBBY or {}
	local lobby_type = lobby.lobby_type
	local gamemode = lobby.config and lobby.config.gamemode
	local access_mode = MP.DOMAIN and MP.DOMAIN.LOBBY and MP.DOMAIN.LOBBY.get_creation_access_mode
		and MP.DOMAIN.LOBBY.get_creation_access_mode() or "private"
	return lobby.is_host and lobby.code and not lobby.match_in_progress
		and bot_ruleset_allowed(lobby.config and lobby.config.ruleset)
		and access_mode == "private"
		and (lobby_type == "ffa" or lobby_type == "1v1")
		and (gamemode == nil or gamemode == "gamemode_mp_attrition")
end

local function experimental_bot_support_status()
	if not EXPERIMENTAL_MP then return true, "Bots supported" end
	local lobby_domain = MP.DOMAIN and MP.DOMAIN.LOBBY or {}
	local ruleset = lobby_domain.get_creation_ruleset and lobby_domain.get_creation_ruleset()
		or (MP.LOBBY and MP.LOBBY.config and MP.LOBBY.config.ruleset)
	local access_mode = lobby_domain.get_creation_access_mode and lobby_domain.get_creation_access_mode() or "private"
	local gamemode = lobby_domain.get_creation_gamemode and lobby_domain.get_creation_gamemode()
		or (MP.LOBBY and MP.LOBBY.config and MP.LOBBY.config.gamemode)
	if not bot_ruleset_allowed(ruleset) then return false, "No bots: matchmaking ruleset" end
	if access_mode ~= "private" then return false, "No bots: lobby must be Private" end
	if gamemode ~= "gamemode_mp_attrition" then return false, "No bots: Attrition only" end
	return true, "Bots supported"
end

MULTIBOTS.bot_support_status = experimental_bot_support_status

local function reject_matchmaking_bot()
	sendWarnMessage("Player vs Bot is unavailable for matchmaking rulesets.", "MULTIBOTS")
end

function MULTIBOTS.start(setup, e)
	if not bot_ruleset_allowed() then
		reject_matchmaking_bot()
		return false, "This ruleset does not support bots."
	end
	if not experimental_lobby_allowed() then
		return false, "Bots require a private host-controlled Attrition or FFA lobby before the match starts."
	end
	setup = type(setup) == "table" and setup or { difficulty = setup }
	local difficulty_key = Generator.difficulties[setup.difficulty] and setup.difficulty or "normal"
	MOD.config.last_difficulty = difficulty_key
	MOD.config.name_mode = setup.name_mode or MOD.config.name_mode
	MOD.config.pace_preset = setup.pace or MOD.config.pace_preset
	apply_pace(MOD.config.pace_preset)
	local difficulty = Generator.difficulties[difficulty_key]
	local name = modules.Names.resolve({
		name_mode = MOD.config.name_mode,
		generated_name = MOD.config.generated_name,
		custom_name = MOD.config.custom_name,
	}, difficulty.name)
	MOD.config.bot_name_preview = name
	save_setup()
	local strategy_weights, strategy_weight_profile = active_strategy_weights()
	local ok, start_error = ActivePeer.start({
		difficulty = difficulty_key,
		name = name,
		name_mode = MOD.config.name_mode,
		pace = MOD.config.pace_preset,
		bot_blind_col = MOD.config.bot_blind_col,
		strategy_weights = strategy_weights,
		strategy_weight_profile = strategy_weight_profile,
		behavior = {
			timer_player = MOD.config.behavior.timer_player,
			skip_mode = MOD.config.behavior.skip_mode,
		},
	}, e)
	if ok == false then sendWarnMessage(tostring(start_error), "MULTIBOTS") end
	return ok, start_error
end

function G.FUNCS.multibots_setup_back(e)
	if EXPERIMENTAL_MP then
		G.FUNCS.exit_overlay_menu()
	else
		G.FUNCS.overlay_menu({ definition = G.UIDEF.ruleset_selection_tabs("practice") })
	end
end

function G.FUNCS.multibots_setup_difficulty(args)
	MOD.config.last_difficulty = Generator.difficulty_order[args.to_key] or "normal"
	update_name_preview()
	save_setup()
end

function G.FUNCS.multibots_setup_name_mode(args)
	MOD.config.name_mode = name_mode_order[args.to_key] or "classic"
	update_name_preview()
	save_setup()
end

function G.FUNCS.multibots_setup_pace(args)
	MOD.config.pace_preset = pace_order[args.to_key] or "standard"
	save_setup()
end

function G.FUNCS.multibots_setup_colour(args)
	MOD.config.bot_blind_col = math.max(1, math.min(25, tonumber(args.to_key) or 2))
	save_setup()
end

function G.FUNCS.multibots_randomize_identity()
	local previous = MOD.config.generated_name
	for _ = 1, 4 do
		MOD.config.generated_name = modules.Names.generate()
		if MOD.config.generated_name ~= previous then break end
	end
	MOD.config.name_mode = "generated"
	local previous_colour = MOD.config.bot_blind_col
	for _ = 1, 4 do
		MOD.config.bot_blind_col = math.random(25)
		if MOD.config.bot_blind_col ~= previous_colour then break end
	end
	update_name_preview()
	save_setup()
	if tabbed_setup_definition then
		setup_active_tab = "profile"
		G.FUNCS.overlay_menu({ definition = tabbed_setup_definition() })
	end
end

function G.FUNCS.multibots_start_setup(e)
	local ok = MULTIBOTS.start({
		difficulty = MOD.config.last_difficulty,
		name_mode = MOD.config.name_mode,
		pace = MOD.config.pace_preset,
		bot_blind_col = MOD.config.bot_blind_col,
		behavior = {
			timer_player = MOD.config.behavior.timer_player,
			skip_mode = MOD.config.behavior.skip_mode,
		},
	}, e)
	if EXPERIMENTAL_MP and ok ~= false then G.FUNCS.exit_overlay_menu() end
end

local function setup_label(text, colour)
	return {
		n = G.UIT.T,
		config = { text = text, scale = 0.36, colour = colour or G.C.UI.TEXT_LIGHT, shadow = true },
	}
end

local function setup_row(nodes, padding)
	return {
		n = G.UIT.R,
		config = { align = "cm", padding = padding or 0.06 },
		nodes = nodes,
	}
end

local function isolated_name_input()
	return {
		n = G.UIT.O,
		config = {
			id = "multibots_custom_name_container",
			align = "cm",
			object = UIBox({
				definition = {
					n = G.UIT.ROOT,
					config = { align = "cm", colour = G.C.CLEAR },
					nodes = {
						setup_row({
							create_text_input({
								id = "multibots_custom_name", w = 3.6, max_length = 22,
								prompt_text = "Enter a bot name", ref_table = MOD.config,
								ref_value = "custom_name", extended_corpus = true, keyboard_offset = -2,
								callback = function()
									MOD.config.custom_name = modules.Names.sanitize(MOD.config.custom_name)
									update_name_preview()
									save_setup()
								end,
							}),
						}, 0),
					},
				},
				config = { offset = { x = 0, y = 0 }, type = "cm" },
			}),
		},
	}
end

local function setup_definition()
	update_name_preview()
	return create_UIBox_generic_options({
		back_func = "multibots_setup_back",
		contents = {
			{
				n = G.UIT.C,
				config = { align = "cm", padding = 0.16, minw = 7.2, r = 0.1, colour = G.C.BLACK },
				nodes = {
					setup_row({ setup_label("BOT OPPONENT", G.C.PURPLE) }, 0.08),
					setup_row({ setup_label("Lobby name", G.C.UI.TEXT_INACTIVE) }, 0.02),
					setup_row({
						{
							n = G.UIT.T,
							config = {
								ref_table = MOD.config, ref_value = "bot_name_preview",
								text = MOD.config.bot_name_preview, scale = 0.5,
								colour = G.C.ORANGE, shadow = true, maxw = 6.2,
							},
						},
					}, 0.08),
					setup_row({
						create_option_cycle({
							id = "multibots_difficulty", label = "Difficulty", options = difficulty_labels,
							current_option = list_index(Generator.difficulty_order, MOD.config.last_difficulty, 2),
							opt_callback = "multibots_setup_difficulty", w = 5.8, scale = 0.7,
						}),
					}),
					setup_row({
						create_option_cycle({
							id = "multibots_name_mode", label = "Name style", options = name_mode_labels,
							current_option = list_index(name_mode_order, MOD.config.name_mode, 1),
							opt_callback = "multibots_setup_name_mode", w = 5.8, scale = 0.7,
						}),
					}),
					setup_row({
						setup_label("Custom name"),
						isolated_name_input(),
					}, 0.08),
					setup_row({
						create_option_cycle({
							id = "multibots_pace", label = "Presentation pace", options = pace_labels,
							current_option = list_index(pace_order, MOD.config.pace_preset, 2),
							opt_callback = "multibots_setup_pace", w = 5.8, scale = 0.7,
						}),
					}),
					setup_row({
						UIBox_button({
							button = "open_multibots_advanced", label = { "Advanced Difficulty & Behavior..." },
							minw = 5.8, minh = 0.65, scale = 0.3, colour = G.C.BLUE,
						}),
					}, 0.04),
					setup_row({
						UIBox_button({
							button = "multibots_randomize_identity", label = { "Randomize Name & Color" },
							minw = 2.7, minh = 0.7, scale = 0.34, colour = G.C.BLUE,
						}),
						UIBox_button({
							id = "multibots_start", button = "multibots_start_setup",
							label = { "Start Match" }, minw = 2.7, minh = 0.7,
							scale = 0.38, colour = G.C.GREEN,
						}),
					}, 0.1),
				},
			},
		},
	})
end

local function advanced_metric(label, value)
	return {
		n = G.UIT.C,
		config = { align = "cm", minw = 3.5, padding = 0.03 },
		nodes = {
			setup_row({
				{ n = G.UIT.T, config = { text = label, scale = 0.3, maxw = 3.2, colour = G.C.UI.TEXT_INACTIVE } },
			}, 0),
			setup_row({
				{ n = G.UIT.T, config = { text = value, scale = 0.34, maxw = 3.2, colour = G.C.ORANGE, shadow = true } },
			}, 0),
		},
	}
end

local function advanced_hint(text)
	return {
		n = G.UIT.T,
		config = { text = text, scale = 0.28, maxw = 7.2, colour = G.C.UI.TEXT_INACTIVE },
	}
end

local function advanced_definition()
	normalize_setup()
	local difficulty = Generator.difficulties[MOD.config.last_difficulty] or Generator.difficulties.normal
	local profile = modules.Policy.profiles[MOD.config.last_difficulty] or modules.Policy.profiles.normal
	local function percent(value) return string.format("%.0f%%", (tonumber(value) or 0) * 100) end
	local skip_description = skip_mode_descriptions[MOD.config.behavior.skip_mode]
	if MOD.config.behavior.skip_mode == "reactive" or MOD.config.behavior.skip_mode == "aggressive" then
		skip_description = skip_description .. " Base appetite at " .. difficulty.name
			.. ": " .. percent(profile.skip_chance) .. "."
	end
	return create_UIBox_generic_options({
		back_func = "multibots_advanced_back",
		contents = {
			{
				n = G.UIT.C,
				config = { align = "cm", padding = 0.16, minw = 8.0, r = 0.1, colour = G.C.BLACK },
				nodes = {
					setup_row({ setup_label("ADVANCED BOT SETTINGS", G.C.PURPLE) }, 0.08),
					setup_row({
						create_option_cycle({
							id = "multibots_advanced_difficulty", label = "Difficulty", options = difficulty_labels,
							current_option = list_index(Generator.difficulty_order, MOD.config.last_difficulty, 2),
							opt_callback = "multibots_advanced_difficulty", w = 5.8, scale = 0.65,
						}),
					}, 0.02),
					setup_row({
						{
							n = G.UIT.T,
							config = {
								text = difficulty.name .. ": " .. difficulty.tldr,
								scale = 0.36, maxw = 7.2, colour = G.C.ORANGE, shadow = true,
							},
						},
					}, 0.04),
					setup_row({
						{
							n = G.UIT.T,
							config = {
								text = difficulty.description, scale = 0.3,
								colour = G.C.UI.TEXT_LIGHT, maxw = 7.2,
							},
						},
					}, 0.05),
					setup_row({ setup_label("Decision model", G.C.BLUE) }, 0.06),
					setup_row({
						advanced_metric("Hand mistake chance", percent(profile.mistake_rate)),
						advanced_metric("Shop mistake chance", percent(profile.shop_mistake_rate)),
					}, 0.02),
					setup_row({
						advanced_metric("Discard candidates", tostring(profile.discard_candidates)),
						advanced_metric("Look-ahead rollouts", tostring(profile.rollouts)),
					}, 0.02),
					setup_row({
						advanced_metric("Mistake candidate pool", percent(profile.play_pool)),
						advanced_metric("Discard threshold", tostring(profile.discard_strength)),
					}, 0.02),
					setup_row({
						advanced_hint("Mistakes choose lower-rated valid actions; look-ahead samples future draws."),
					}, 0.04),
					setup_row({ setup_label("Behavior", G.C.BLUE) }, 0.06),
					setup_row({
						create_toggle({
							id = "multibots_timer_player", label = "Timer player when ready first",
							ref_table = MOD.config.behavior, ref_value = "timer_player",
							w = 4.8, label_scale = 0.32,
							callback = function() save_setup() end,
						}),
					}, 0.02),
					setup_row({
						advanced_hint("Uses the lobby timer length and skip-time adjustments."),
					}, 0.01),
					setup_row({
						create_option_cycle({
							id = "multibots_skip_mode", label = "Blind skipping", options = skip_mode_labels,
							current_option = list_index(skip_mode_order, MOD.config.behavior.skip_mode, 2),
							opt_callback = "multibots_skip_mode", w = 6.4, scale = 0.55,
						}),
					}, 0.02),
					setup_row({
						advanced_hint(skip_description),
					}, 0.01),
				},
			},
		},
	})
end

local function profile_tab_definition()
	update_name_preview()
	local colours = {}
	for index = 1, 25 do
		colours[index] = localize({
			type = "name_text", key = MP.UTILS.blind_col_numtokey(index), set = "Blind",
		})
	end
	return {
		n = G.UIT.C,
		config = { align = "cm", padding = 0.14, minw = 7.6, minh = 6.0, r = 0.1, colour = G.C.BLACK },
		nodes = {
			setup_row({ setup_label("BOT PROFILE", G.C.PURPLE) }, 0.08),
			setup_row({ setup_label("Lobby name", G.C.UI.TEXT_INACTIVE) }, 0.02),
			setup_row({ { n = G.UIT.T, config = {
				ref_table = MOD.config, ref_value = "bot_name_preview", text = MOD.config.bot_name_preview,
				scale = 0.5, colour = G.C.ORANGE, shadow = true, maxw = 6.4,
			} } }, 0.08),
			setup_row({ create_option_cycle({
				id = "multibots_name_mode", label = "Name style", options = name_mode_labels,
				current_option = list_index(name_mode_order, MOD.config.name_mode, 1),
				opt_callback = "multibots_setup_name_mode", w = 5.9, scale = 0.65,
			}) }),
			setup_row({ setup_label("Custom name"), isolated_name_input() }, 0.08),
			setup_row({ create_option_cycle({
				id = "multibots_colour", label = "Blind colour", options = colours,
				current_option = MOD.config.bot_blind_col,
				opt_callback = "multibots_setup_colour", w = 5.9, scale = 0.55,
			}) }),
			setup_row({ UIBox_button({
				button = "multibots_randomize_identity", label = { "Randomize Name & Color" },
				minw = 5.9, minh = 0.7, scale = 0.34, colour = G.C.BLUE,
			}) }, 0.08),
		},
	}
end

local function brain_tab_definition()
	local difficulty = Generator.difficulties[MOD.config.last_difficulty] or Generator.difficulties.normal
	return {
		n = G.UIT.C,
		config = { align = "cm", padding = 0.14, minw = 7.6, minh = 6.0, r = 0.1, colour = G.C.BLACK },
		nodes = {
			setup_row({ setup_label("BOT BRAIN", G.C.PURPLE) }, 0.08),
			setup_row({ create_option_cycle({
				id = "multibots_difficulty", label = "Difficulty", options = difficulty_labels,
				current_option = list_index(Generator.difficulty_order, MOD.config.last_difficulty, 2),
				opt_callback = "multibots_setup_difficulty", w = 5.9, scale = 0.65,
			}) }),
			setup_row({ { n = G.UIT.T, config = {
				text = difficulty.name .. ": " .. difficulty.tldr,
				scale = 0.34, maxw = 6.8, colour = G.C.ORANGE, shadow = true,
			} } }, 0.05),
			setup_row({ create_option_cycle({
				id = "multibots_pace", label = "Presentation pace", options = pace_labels,
				current_option = list_index(pace_order, MOD.config.pace_preset, 2),
				opt_callback = "multibots_setup_pace", w = 5.9, scale = 0.62,
			}) }),
			setup_row({ create_toggle({
				id = "multibots_timer_player", label = "Timer player when ready first",
				ref_table = MOD.config.behavior, ref_value = "timer_player",
				w = 4.9, label_scale = 0.32, callback = function() save_setup() end,
			}) }, 0.03),
			setup_row({ create_option_cycle({
				id = "multibots_skip_mode", label = "Blind skipping", options = skip_mode_labels,
				current_option = list_index(skip_mode_order, MOD.config.behavior.skip_mode, 2),
				opt_callback = "multibots_skip_mode_setup", w = 6.3, scale = 0.5,
			}) }),
			setup_row({ UIBox_button({
				button = "open_multibots_advanced", label = { "Detailed Difficulty Breakdown..." },
				minw = 5.9, minh = 0.65, scale = 0.3, colour = G.C.BLUE,
			}) }, 0.06),
		},
	}
end

local how_topics = {
	chips = { label = "Chips", group = "Scoring", stats = { { "Partial", "Joker Support" }, { "Full", "Consumable Support" }, { "N/A", "Voucher Support" }, { "Full", "Enhancement Support" }, { "Partial", "Other Support" } },
		summary = "Chips form the first half of every score calculation.", lines = {
			"The bot adds the hand's base Chips, its Planet level, and every scoring card's rank value.",
			"Bonus cards, Foil editions, and supported Joker effects add to the same Chip total.",
			"Hand selection values both immediate Chips and scaling effects such as Runner or Wee Joker.",
			"Final score is Chips multiplied by Mult after all supported XMult effects are applied.",
	} },
	mult = { label = "Mult", group = "Scoring", stats = { { "Partial", "Joker Support" }, { "Full", "Consumable Support" }, { "N/A", "Voucher Support" }, { "Full", "Enhancement Support" }, { "Partial", "Other Support" } },
		summary = "Mult combines the hand base, card bonuses, and Joker engines.", lines = {
			"Planet levels raise a hand's base Mult before scoring-card and Joker effects are counted.",
			"Mult cards, Holographic editions, and supported flat or conditional Jokers add together.",
			"Scaling Jokers retain state between rounds, so the bot must actually satisfy their conditions.",
			"The strategy compares Mult reliability with the deck's ability to produce the required hand or cards.",
	} },
	xmult = { label = "XMult", group = "Scoring", stats = { { "Partial", "Joker Support" }, { "Full", "Consumable Support" }, { "No", "Voucher Support" }, { "Full", "Enhancement Support" }, { "Partial", "Other Support" } },
		summary = "XMult is applied after additive Chips and Mult are assembled.", lines = {
			"Glass scoring cards, held Steel cards, and Polychrome cards or Jokers multiply the result.",
			"Supported conditional XMult checks hands, suits, ranks, enhancements, timing, and Joker layout.",
			"The bot discounts powerful XMult whose activation condition its current deck cannot meet reliably.",
			"Blueprint and Brainstorm copy supported neighboring Joker adapters rather than inventing effects.",
	} },
	economy = { label = "Economy", group = "Run", stat_break = 5, stats = { { "Minimal", "Joker Support" }, { "Partial", "Consumable Support" }, { "Partial", "Voucher Support" }, { "Partial", "Enhancement Support" }, { "Partial", "Other Support" }, { "$25", "Interest cap" }, { "$5", "Interest step" }, { "$4", "Comeback" } },
		summary = "Money is persistent future shop power, not a disposable score modifier.", lines = {
			"Payouts include Blind rewards, unused hands, interest, card income, tags, and enabled comeback gold.",
			"The bot protects an interest reserve, but can break it for survival or a high-impact purchase.",
			"It can sell a weaker Joker for a meaningful upgrade without repeatedly churning a working build.",
			"A failed non-PvP Blind still follows Multiplayer's technical-clear payout and costs one life.",
	} },
	tarots = { label = "Tarots", group = "Run", stats = { { "Minimal", "Joker Support" }, { "Full", "Consumable Support" }, { "Partial", "Voucher Support" }, { "Full", "Enhancement Support" }, { "No", "Other Support" } },
		summary = "Tarots are evaluated as permanent deck changes or immediate economy.", lines = {
			"Supported effects remove, convert, enhance, rank-shift, suit-fix, add editions, or grant money.",
			"Targets are selected from the actual persistent deck according to the bot's current hand plan.",
			"Suit conversion and removal improve draw density instead of merely changing deck-inspection data.",
			"Under The Order, shop Tarots and Arcana contents come from the bot's private queues.",
	} },
	planets = { label = "Planets", group = "Run", stats = { { "Minimal", "Joker Support" }, { "Partial", "Consumable Support" }, { "Partial", "Voucher Support" }, { "Full", "Enhancement Support" }, { "No", "Other Support" } },
		summary = "All nine standard poker hands have persistent Planet levels.", lines = {
			"Using a Planet immediately updates the matching hand's Chips and Mult for future evaluations.",
			"The strategy prefers Planets that reinforce its chosen build and discounts infeasible hand types.",
			"Constellation observes real Planet purchases and scales its stored XMult accordingly.",
			"Loose Planets and Celestial contents use the bot's private queue and advance only when opened.",
	} },
	spectrals = { label = "Spectrals", group = "Run", stats = { { "No", "Joker Support" }, { "Minimal", "Consumable Support" }, { "Partial", "Voucher Support" }, { "No", "Enhancement Support" }, { "No", "Other Support" } },
		summary = "Spectral support focuses on effects the headless deck can reproduce exactly.", lines = {
			"Current adapters cover selected card destruction, duplication, edition, and seal effects.",
			"Each change is applied to real deck cards and survives into later draws and deck inspection.",
			"The policy prices destructive effects against deck quality rather than treating them as free value.",
			"Unsupported or hidden Spectrals are excluded instead of receiving an invented approximation.",
	} },
	playing_blinds = { label = "Playing Blinds", group = "Rounds", stats = { { "Full", "Simulation" }, { "-1", "Life per round lost" } },
		summary = "Small, Big, and Boss Blinds are played as complete separate rounds.", lines = {
			"The bot draws, evaluates plays, discards, scores hands, pays out, and visits the following shop.",
			"Blind targets use the run's Ante and round; a failure costs one life without ending the run immediately.",
			"Every failed round can cost a life, so losses are not capped at one per Ante.",
			"Its location updates only represent phases the persistent simulation has genuinely reached.",
	} },
	pvp_blinds = { label = "PvP Blinds", group = "Rounds", stats = { { "Equal Player Hands", "Hands left" }, { "Highest Score", "PvP Blind Win Condition" } },
		summary = "PvP hands are paced against the player instead of dumped in one tick.", lines = {
			"The bot may play freely only while it has more remaining hands than the player.",
			"Otherwise it waits for the player to spend a hand, then responds with at most one of its own.",
			"Its score comes from the same deck, levels, Jokers, and strategy used during normal Blinds.",
			"The previous PvP result also informs whether Reactive skipping may safely pressure the player.",
	} },
	skipping_blinds = { label = "Skipping Blinds", group = "Rounds", stats = { { "8", "Supported Tags" } },
		summary = "Skipping follows the selected behavior profile and the visible Blind tag.", lines = {
			"Supported Tags: Investment, Economy, Negative, Foil, Holographic, Polychrome, Rare, and Uncommon.",
			"Reactive weighs cash, Joker needs, tag value, safety limits, and the previous PvP performance.",
			"Negative-only, Aggressive, Unforgivable, and Unlimited modes progressively relax restraint.",
			"A skip forfeits that Blind and its shop, then applies the modeled tag reward to the run.",
			"Every skipped Blind adds the lobby Timer Increment when the bot later timers the player.",
	} },
}

local how_topic_order = {
	"chips", "mult", "xmult", "economy", "tarots", "planets", "spectrals",
	"playing_blinds", "pvp_blinds", "skipping_blinds",
}

local joker_topic_effects = {
	chips = {
		hand_chips = true, discard_chips = true, rank_chips = true, rank_chips_mult = true,
		face_chips = true, money_chips = true, deck_remaining_chips = true,
		straight_scaling_chips = true, four_card_scaling_chips = true, decaying_chips = true,
		suit_chips = true, flat_chips = true, stone_count_chips = true, rank_scaling_chips = true,
		played_card_chip_growth = true, round_stone_card = true, discard_suit_scaling_chips = true,

	},
	mult = {
		flat_mult = true, suit_mult = true, hand_mult = true, card_count_mult = true,
		joker_count_mult = true, no_discard_mult = true, rank_mult = true, rank_chips_mult = true,
		face_mult = true, hand_usage_mult = true, held_rank_mult = true, held_lowest_rank_mult = true,
		missing_deck_mult = true, hand_scaling_mult = true, bus_scaling_mult = true,
		green_scaling_mult = true, suit_card_mult = true, other_joker_sell_mult = true, money_step_mult = true,
		skipped_pack_scaling_mult = true, sacrifice_scaling_mult = true, opponent_sale_mult = true,
		reroll_scaling_mult = true,
	},
	xmult = {
		first_face_xmult = true, last_hand_xmult = true, repeat_hand_xmult = true, 
		held_suit_xmult = true, planet_scaling_xmult = true, deck_add_scaling_xmult = true,
		rarity_xmult = true, hand_xmult = true, enhancement_count_xmult = true, flat_xmult = true,
		held_rank_xmult = true, empty_slot_xmult = true, enhanced_threshold_xmult = true,
		scoring_suits_xmult = true, mixed_suit_xmult = true, periodic_xmult = true,
		discard_decay_xmult = true, non_pvp_xmult = true, chance_suit_xmult = true,
		rotating_suit_xmult = true, blind_scaling_xmult = true, face_destroy_xmult = true, discard_rank_xmult = true, 
		rotating_card_xmult = true, lucky_scaling_xmult = true, skip_scaling_xmult = true, sell_scaling_xmult = true,
		glass_shatter_xmult = true, rank_xmult = true, enhancement_steal_xmult = true, discard_count_xmult = true,
	},
	economy = {
		played_hand_money = true, deck_rank_money = true, round_money = true, hand_money = true, discard_money = true,
		hand_scaling_money = true, discard_scaling_money = true, rank_scaling_money = true, decaying_money = true, suit_money = true, flat_money = true, discard_face_money = true,
		debt_limit = true, free_shop_reroll = true, scoring_face_money = true, sell_value_growth = true,
		scoring_enhancement_money = true, held_face_money = true, extra_interest = true, single_discard_destroy = true, 
		discard_rank_money = true, boss_scaling_money = true, unique_planet_money = true,
	},
	tarots = { tarot_scaling_mult = true, round_tarot_generation = true, pack_tarot_chance = true, straight_ace_tarot = true, },
	planets = { planet_scaling_xmult = true, chance_hand_level = true, free_planets = true, first_discard_level = true, unique_planet_money = true, },
	spectrals = { straight_flush_spectral = true, first_six_spectral = true, },
	playing_blinds = {
		copy_joker = true, round_resources = true, decaying_hand_size = true,
		all_played_score = true, all_faces = true, round_joker_generation = true,
		retrigger_scoring = true, rank_retrigger = true, face_retrigger = true, held_retrigger = true,
		round_tarot_generation = true, face_retrigger = true, straight_gaps = true,
		round_stone_card = true, double_tag_on_sell = true, four_card_hands = true,
		pvp_discard_food = true, double_probabilities = true, sell_disable_boss = true,
		boss_trigger_money = true, prevent_death = true, limited_retrigger = true,
		first_hand_single_copy = true, first_scoring_retrigger = true,
	},
}

local enhancement_topics = {
	chips = { "m_bonus", "m_stone" },
	mult = { "m_mult", "m_lucky" },
	xmult = { "m_glass", "m_steel" },
	economy = { "m_gold", "m_lucky" },
	tarots = { "m_bonus", "m_mult", "m_lucky", "m_glass", "m_steel", "m_gold", "m_wild", "m_stone" },
	playing_blinds = {  },
}

local voucher_topics = {
	economy = { v_grabber = true, v_seed_money = true, v_money_tree = true, v_clearance_sale = true, v_liquidation = true,
	v_overstock_norm = true, v_overstock_plus = true, v_hone = true, v_magic_trick = true, },
	tarots = { v_crystal_ball = true, v_tarot_mechant = true, shop_end_negative_consumable = true, },
	planets = { v_crystal_ball = true, v_planet_merchant = true, v_telescope = true, shop_end_negative_consumable = true, },
	spectrals = { v_crystal_ball = true, v_omen_globe = true, shop_end_negative_consumable = true, },
	playing_blinds = { v_grabber = true, v_paint_brush = true, v_wasteful = true, v_blank = true, disable_boss = true, },
}

local supported_skip_tags = {
	{ key = "tag_investment", label = "Investment Tag" },
	{ key = "tag_economy", label = "Economy Tag" },
	{ key = "tag_negative", label = "Negative Tag" },
	{ key = "tag_foil", label = "Foil Tag" },
	{ key = "tag_holo", label = "Holographic Tag" },
	{ key = "tag_polychrome", label = "Polychrome Tag" },
	{ key = "tag_rare", label = "Rare Tag" },
	{ key = "tag_uncommon", label = "Uncommon Tag" },
}

local function supported_card_ids(catalog, kind, topic_key)
	local ids, seen = {}, {}
	local function add(key)
		if key and not seen[key] and G.P_CENTERS and G.P_CENTERS[key] then
			seen[key] = true
			ids[#ids + 1] = key
		end
	end
	if kind == "jokers" then
		local allowed = joker_topic_effects[topic_key] or {}
		for _, item in ipairs(catalog.jokers or {}) do
			local effect_kind = item.effect and item.effect.kind
			if allowed[effect_kind] or (topic_key == "pvp_blinds" and ((item.multiplayer 
			and not (item.effect.kind == "non_pvp_xmult")) 
			)) 
			then add(item.key) end
			if allowed[effect_kind] or (topic_key == "skipping_blinds" and item.effect and item.effect.kind == "double_tag_on_sell") then add(item.key) end
			if allowed[effect_kind] or (topic_key == "skipping_blinds" and item.effect and item.effect.kind == "skip_scaling_xmult") then add(item.key) end
		end
	elseif kind == "consumables" then
		if topic_key == "planets" then
			for _, item in ipairs(catalog.planets or {}) do add(item.key) end
		end
		for _, item in ipairs(catalog.deck_tools or {}) do
			if topic_key == "tarots" and item.set == "Tarot" then add(item.key) end
			if topic_key == "spectrals" and item.set == "Spectral" then add(item.key) end
			if topic_key == "economy" and item.effect == "money" then add(item.key) end
		end
	elseif kind == "enhancements" then
		for _, key in ipairs(enhancement_topics[topic_key] or {}) do add(key) end
	elseif kind == "vouchers" then
		local allowed = voucher_topics[topic_key] or {}
		for _, item in ipairs(catalog.vouchers or {}) do if allowed[item.key] then add(item.key) end end
	elseif kind == "other" then
		for _, key in ipairs(catalog.packs or {}) do
			if modules.Content.pack_topic(key) == topic_key then add(key) end
		end
	end
	table.sort(ids)
	return ids
end

local function supported_cards_definition(label, ids)
	local rows = {}
	if #ids > 0 then
		local row_count = math.max(1, math.ceil(#ids / 8))
		local cards_per_row = math.ceil(#ids / row_count)
		local card_size = math.max(0.38, math.min(0.68, 6.15 / (cards_per_row * G.CARD_W)))
		for row_index = 1, row_count do
			local area = CardArea(0, 0, 6.4, 3.65 / row_count, {
				card_limit = nil, type = "title_2", view_deck = true, highlight_limit = 0,
				card_w = G.CARD_W * card_size,
			})
			for index = row_index, #ids, row_count do
				area:emplace(Card(0, 0, G.CARD_W * card_size, G.CARD_H * card_size,
					nil, G.P_CENTERS[ids[index]], { bypass_discovery_center = true, bypass_discovery_ui = true }))
			end
			rows[#rows + 1] = { n = G.UIT.R, config = { align = "cm" }, nodes = {
				{ n = G.UIT.O, config = { object = area } },
			} }
		end
	else
		rows[1] = setup_row({ setup_label("No registered cards in this category.", G.C.UI.TEXT_INACTIVE) })
	end
	rows[#rows + 1] = setup_row({ { n = G.UIT.T, config = {
		text = string.format("%d supported %s", #ids, label), scale = 0.28, colour = G.C.UI.TEXT_INACTIVE,
	} } }, 0.02)
	return { n = G.UIT.ROOT, config = { align = "cm", colour = G.C.CLEAR }, nodes = { {
		n = G.UIT.C, config = { align = "cm", minw = 6.65, minh = 4.15 }, nodes = rows,
	} } }
end

local function supported_tags_definition(tags)
	local rows, visible = {}, {}
	for _, tag in ipairs(tags) do
		if G.P_TAGS and G.P_TAGS[tag.key] then visible[#visible + 1] = tag end
	end
	for index = 1, #visible, 4 do
		local nodes = {}
		for offset = 0, 3 do
			local tag_spec = visible[index + offset]
			if tag_spec then
				local tag_ui = Tag(tag_spec.key, true):generate_UI(0.78)
				nodes[#nodes + 1] = {
					n = G.UIT.C,
					config = { align = "cm", minw = 1.35, minh = 1.15, padding = 0.08 },
					nodes = { tag_ui },
				}
			end
		end
		rows[#rows + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.04 }, nodes = nodes }
	end
	rows[#rows + 1] = setup_row({ { n = G.UIT.T, config = {
		text = "Rare and Uncommon require non-strict content order.",
		scale = 0.25, colour = G.C.UI.TEXT_INACTIVE,
	} } }, 0.02)
	rows[#rows + 1] = setup_row({ { n = G.UIT.T, config = {
		text = string.format("%d supported Tags", #visible),
		scale = 0.28, colour = G.C.UI.TEXT_INACTIVE,
	} } }, 0.02)
	return { n = G.UIT.ROOT, config = { align = "cm", colour = G.C.CLEAR }, nodes = { {
		n = G.UIT.C, config = { align = "cm", minw = 6.65, minh = 4.15 }, nodes = rows,
	} } }
end

local function how_mode_control()
	return setup_row({ create_option_cycle({
		id = "multibots_how_mode", options = { "Info", "Supported Cards" },
		current_option = how_selected_mode == "support" and 2 or 1,
		opt_callback = "multibots_how_mode", w = 5.5, scale = 0.52,
	}) }, 0.02)
end

local function how_supported_definition(catalog, topic_key)
	local categories = {
		{ key = "jokers", label = "Jokers" },
		{ key = "consumables", label = "Consumables" },
		{ key = "vouchers", label = "Vouchers" },
		{ key = "enhancements", label = "Enhanced Cards" },
		{ key = "other", label = "Other" },
	}
	local tabs = {}
	for index, category in ipairs(categories) do
		local label = category.label
		local ids = supported_card_ids(catalog, category.key, topic_key)
		local definition
		if topic_key == "skipping_blinds" and category.key == "other" then
			definition = function() return supported_tags_definition(supported_skip_tags) end
		else
			definition = function() return supported_cards_definition(label, ids) end
		end
		tabs[#tabs + 1] = {
			label = label, chosen = index == 1,
			tab_definition_function = definition,
		}
	end
	return {
		n = G.UIT.C, config = { align = "cm", minw = 6.7, minh = 5.0 }, nodes = {
			create_tabs({
				tabs = tabs, tab_h = 4.1, tab_w = 6.7, padding = 0,
				scale = 0.5, text_scale = 0.28, no_shoulders = true, no_loop = true,
			}),
			how_mode_control(),
		},
	}
end

local function wrapped_text_rows(text_value, scale, colour, shadow, max_chars, padding)
	local rows, line, line_length = {}, {}, 0
	local function flush()
		if #line == 0 then return end
		rows[#rows + 1] = {
			n = G.UIT.R, config = { align = "cl", padding = padding or 0.025 }, nodes = {
				{ n = G.UIT.T, config = {
					text = table.concat(line, " "), scale = scale, colour = colour, shadow = shadow,
				} },
			},
		}
		line, line_length = {}, 0
	end
	for word in tostring(text_value):gmatch("%S+") do
		local added = #word + (#line > 0 and 1 or 0)
		if line_length > 0 and line_length + added > max_chars then flush() end
		line[#line + 1] = word
		line_length = line_length + added
	end
	flush()
	return rows
end

local function support_stat_colour(value, label)
	if not tostring(label):find("Support", 1, true) then return G.C.GREEN end
	local colours = {
		Full = G.C.GREEN,
		Partial = G.C.YELLOW or G.C.ORANGE,
		Minimal = G.C.ORANGE,
		No = G.C.RED,
		["N/A"] = G.C.UI.TEXT_INACTIVE,
	}
	return colours[value] or G.C.UI.TEXT_LIGHT
end

local function how_info_definition(topic)
	local stat_rows = { {} }
	for index, stat in ipairs(topic.stats) do
		if topic.stat_break and index == topic.stat_break + 1 then stat_rows[#stat_rows + 1] = {} end
		local row = stat_rows[#stat_rows]
		row[#row + 1] = {
			n = G.UIT.C,
			config = { align = "cm", minw = 1.85, minh = 0.9, padding = 0.05, r = 0.08, colour = G.C.GREY },
			nodes = {
				{ n = G.UIT.R, config = { align = "cm" }, nodes = {
					{ n = G.UIT.T, config = { text = stat[1], scale = 0.35,
						colour = support_stat_colour(stat[1], stat[2]), shadow = true } },
				} },
				{ n = G.UIT.R, config = { align = "cm" }, nodes = {
					{ n = G.UIT.T, config = { text = stat[2], scale = 0.21, colour = G.C.UI.WHITE, shadow = true } },
				} },
			},
		}
	end
	local stats = {}
	for _, row in ipairs(stat_rows) do
		stats[#stats + 1] = { n = G.UIT.R, config = { align = "cm", padding = 0.025 }, nodes = row }
	end
	local lines = wrapped_text_rows(topic.summary, 0.34, G.C.ORANGE, true, 58, 0.055)
	for _, text_value in ipairs(topic.lines) do
		local wrapped = wrapped_text_rows(text_value, 0.285, G.C.UI.TEXT_LIGHT, false, 66, 0.025)
		for _, row in ipairs(wrapped) do lines[#lines + 1] = row end
	end
	return {
		n = G.UIT.C, config = { align = "cm", minw = 6.7, minh = 5.0, padding = 0.06 }, nodes = {
			{ n = G.UIT.R, config = { align = "cm", padding = 0.025 }, nodes = {
				{ n = G.UIT.C, config = { align = "cm" }, nodes = stats },
			} },
			{ n = G.UIT.R, config = { align = "cm" }, nodes = {
				{ n = G.UIT.C, config = { align = "cl", minw = 6.35, minh = 3.05,
					padding = 0.06 }, nodes = lines },
			} },
			how_mode_control(),
		},
	}
end

local function how_it_works_tab_definition()
	local topic = how_topics[how_selected_topic] or how_topics.chips
	local catalog = modules.Content.defaults()
	if G.P_CENTER_POOLS then
		local ok, runtime_catalog = pcall(modules.Content.build, G.P_CENTER_POOLS, G.P_CENTERS or {}, {})
		if ok and runtime_catalog then catalog = runtime_catalog end
	end
	local left_nodes = { setup_row({ setup_label("HOW IT WORKS", G.C.BLUE) }, 0.04) }
	local last_group
	for _, key in ipairs(how_topic_order) do
		local item = how_topics[key]
		if item.group ~= last_group then
			left_nodes[#left_nodes + 1] = setup_row({ setup_label(item.group, G.C.UI.TEXT_INACTIVE) }, 0.015)
			last_group = item.group
		end
		left_nodes[#left_nodes + 1] = setup_row({ UIBox_button({
			id = "multibots_how_" .. key, button = "multibots_how_topic", label = { item.label },
			ref_table = { topic = key }, choice = true, chosen = key == how_selected_topic and "vert" or false,
			minw = 2.75, minh = 0.48, scale = 0.28, colour = G.C.RED,
		}) }, 0.01)
	end
	local detail = how_selected_mode == "support"
		and how_supported_definition(catalog, how_selected_topic) or how_info_definition(topic)
	return {
		n = G.UIT.R,
		config = { align = "cm", padding = 0.05, minw = 9.85, minh = 6.25, colour = G.C.CLEAR },
		nodes = {
			{ n = G.UIT.C, config = { align = "tm", padding = 0.06, minw = 3.0, minh = 6.2 }, nodes = left_nodes },
			{ n = G.UIT.C, config = { align = "cm", padding = 0.08, minw = 6.75, minh = 6.2,
				r = 0.1, colour = G.C.BLACK }, nodes = {
				detail,
			} },
		},
	}
end

tabbed_setup_definition = function()
	update_name_preview()
	return create_UIBox_generic_options({
		back_func = "multibots_setup_back",
		contents = {
			create_tabs({
				tabs = {
					{ label = "Profile", chosen = setup_active_tab == "profile", tab_definition_function = function()
						return { n = G.UIT.ROOT, config = { align = "cm", colour = G.C.CLEAR },
							nodes = { profile_tab_definition() } }
					end },
					{ label = "Brain", chosen = setup_active_tab == "brain", tab_definition_function = function()
						return { n = G.UIT.ROOT, config = { align = "cm", colour = G.C.CLEAR },
							nodes = { brain_tab_definition() } }
					end },
					{ label = "How It Works", chosen = setup_active_tab == "how", tab_definition_function = function()
						return { n = G.UIT.ROOT, config = { align = "cm", colour = G.C.CLEAR },
							nodes = { how_it_works_tab_definition() } }
					end },
				},
				tab_h = 6.35, tab_w = 10.1, padding = 0, snap_to_nav = true,
			}),
			setup_row({ UIBox_button({
				id = "multibots_start", button = "multibots_start_setup",
				label = { EXPERIMENTAL_MP and "Add Bot to Lobby" or "Start Bot Match" }, minw = 6.3, minh = 0.75,
				scale = 0.4, colour = G.C.GREEN,
			}) }, 0.08),
		},
	})
end

function G.FUNCS.multibots_how_topic(e)
	local key = e and e.config and e.config.ref_table and e.config.ref_table.topic
	if not how_topics[key] then return end
	how_selected_topic = key
	setup_active_tab = "how"
	G.FUNCS.overlay_menu({ definition = tabbed_setup_definition() })
end

function G.FUNCS.multibots_how_mode(args)
	how_selected_mode = args and args.to_key == 2 and "support" or "info"
	setup_active_tab = "how"
	G.FUNCS.overlay_menu({ definition = tabbed_setup_definition() })
end

function G.FUNCS.multibots_how_mode_button(e)
	local mode = e and e.config and e.config.ref_table and e.config.ref_table.mode
	if mode ~= "info" and mode ~= "support" then return end
	how_selected_mode = mode
	setup_active_tab = "how"
	G.FUNCS.overlay_menu({ definition = tabbed_setup_definition() })
end

function G.FUNCS.multibots_advanced_difficulty(args)
	G.FUNCS.multibots_setup_difficulty(args)
	G.FUNCS.overlay_menu({ definition = advanced_definition() })
end

function G.FUNCS.multibots_skip_mode(args)
	MOD.config.behavior.skip_mode = skip_mode_order[args.to_key] or "reactive"
	save_setup()
	G.FUNCS.overlay_menu({ definition = advanced_definition() })
end

function G.FUNCS.multibots_skip_mode_setup(args)
	MOD.config.behavior.skip_mode = skip_mode_order[args.to_key] or "reactive"
	save_setup()
end

function G.FUNCS.open_multibots_advanced()
	G.FUNCS.overlay_menu({ definition = advanced_definition() })
end

function G.FUNCS.multibots_advanced_back()
	setup_active_tab = "brain"
	G.FUNCS.overlay_menu({ definition = tabbed_setup_definition() })
end

function G.FUNCS.open_multibots_setup(e)
	if not bot_ruleset_allowed() then
		reject_matchmaking_bot()
		return
	end
	if not experimental_lobby_allowed() then
		sendWarnMessage("Bots require a private host-controlled Attrition or FFA lobby before the match starts.", "MULTIBOTS")
		return
	end
	setup_active_tab = "profile"
	G.FUNCS.overlay_menu({ definition = tabbed_setup_definition() })
end

if EXPERIMENTAL_MP then
	local function insert_after_button(node, button_name, additions)
		if type(node) ~= "table" then return false end
		local nodes = node.nodes
		if type(nodes) == "table" then
			local last_index = 0
			for index in pairs(nodes) do
				if type(index) == "number" and index > last_index then last_index = index end
			end
			for index = 1, last_index do
				local child = nodes[index]
				if type(child) == "table" then
					if child.config and child.config.button == button_name then
						for offset, addition in ipairs(additions) do table.insert(nodes, index + offset, addition) end
						return true
					end
					if insert_after_button(child, button_name, additions) then return true end
				end
			end
		end
		return false
	end

	local create_lobby_menu_ref = G.UIDEF.create_UIBox_lobby_menu
	if type(create_lobby_menu_ref) == "function" then
		function G.UIDEF.create_UIBox_lobby_menu(...)
			local definition = create_lobby_menu_ref(...)
			if experimental_lobby_allowed() then
				insert_after_button(definition, "view_players_list", {
					MP.UI.create_spacer(),
					UIBox_button({
						id = "multibots_add_lobby_bot", button = "open_multibots_setup",
						label = { "Add Bot" }, colour = G.C.PURPLE,
						minw = 2.0, minh = 1.35, scale = 0.42, col = true,
					}),
				})
			end
			return definition
		end
		MP.UI.create_UIBox_lobby_menu = G.UIDEF.create_UIBox_lobby_menu
	end

	local lobby_bot_state = { count = 0, lobby_code = nil, ids = {} }
	local function set_lobby_bot_count(count, lobby_code, refresh, player_ids)
		count = math.max(0, math.floor(tonumber(count) or 0))
		lobby_bot_state.count = count
		lobby_bot_state.lobby_code = lobby_code
		if type(player_ids) == "table" then
			lobby_bot_state.ids = {}
			for _, player_id in ipairs(player_ids) do lobby_bot_state.ids[tostring(player_id)] = true end
		end
		if MP.LOBBY then MP.LOBBY.multibots_bot_ids = lobby_bot_state.ids end
		if MP.UI then MP.UI.lobby_warning_cache = nil end
		if refresh and MP.UI and MP.UI.request_lobby_main_menu_refresh then
			MP.UI.request_lobby_main_menu_refresh()
		end
	end

	local function hide_bot_spectator_screen()
		local screen = G and G.multibots_bot_spectator_screen
		if screen then
			screen:remove()
			G.multibots_bot_spectator_screen = nil
			G.multibots_bot_spectator_target_id = nil
		end
	end

	local function show_bot_spectator_screen(target_id)
		if G.multibots_bot_spectator_screen
			and G.multibots_bot_spectator_target_id == target_id then return end
		hide_bot_spectator_screen()
		if not (UIBox and G.ROOM and G.ROOM.T and G.ROOM_ATTACH) then
			sendWarnMessage("Could not display the bot spectator placeholder.", "MULTIBOTS")
			return
		end
		G.multibots_bot_spectator_screen = UIBox({
			definition = {
				n = G.UIT.ROOT,
				config = {
					align = "cm",
					minw = G.ROOM.T.w,
					minh = G.ROOM.T.h,
					colour = G.C.CLEAR,
				},
				nodes = {
					{
						n = G.UIT.R,
						config = { align = "cm" },
						nodes = {
							{
								n = G.UIT.T,
								config = {
									text = "Spectating bots is currently unavailable.",
									scale = 0.55,
									colour = G.C.UI.TEXT_LIGHT,
									shadow = true,
								},
							},
						},
					},
				},
			},
			config = {
				align = "cm",
				major = G.ROOM_ATTACH,
				bond = "Weak",
			},
		})
		G.multibots_bot_spectator_target_id = target_id
		if MP.UI.bring_spectator_bars_to_front then MP.UI.bring_spectator_bars_to_front() end
	end

	modules.SpectatorGuard.install(
		MP.SPECTATOR,
		function()
			if lobby_bot_state.lobby_code ~= (MP.LOBBY and MP.LOBBY.code) then return {} end
			return lobby_bot_state.ids
		end,
		show_bot_spectator_screen,
		hide_bot_spectator_screen
	)

	if type(MP.register_mod_action) == "function" then
		MP.register_mod_action("lobby_bot_count", function(action)
			local code = action and action.lobbyCode
			if MP.LOBBY and MP.LOBBY.code and code == MP.LOBBY.code then
				set_lobby_bot_count(action.count, code, true, action.botIds)
			end
		end, "MultiBots")
	end

	modules.PeerPool.on_change(function(count, player_ids)
		local code = MP.LOBBY and MP.LOBBY.code
		set_lobby_bot_count(count, code, false, player_ids)
		if code and MP.ACTIONS and type(MP.ACTIONS.modded) == "function" then
			MP.ACTIONS.modded("MultiBots", "lobby_bot_count", {
				count = count, lobbyCode = code, botIds = player_ids,
			})
		end
	end)

	local create_name_lane_ref = MP.UI.ROW_LAYOUT and MP.UI.ROW_LAYOUT.create_name_lane
	if type(create_name_lane_ref) == "function" then
		function MP.UI.ROW_LAYOUT.create_name_lane(model)
			local lane = create_name_lane_ref(model)
			if lobby_bot_state.ids[tostring(model and model.id)] and lane and lane.nodes then
				local name_node = lane.nodes[1]
				if name_node and name_node.config then name_node.config.maxw = 2.9 end
				lane.nodes[#lane.nodes + 1] = { n = G.UIT.B, config = { w = 0.08, h = 0.01 } }
				lane.nodes[#lane.nodes + 1] = MP.UI.ROW_LAYOUT.create_row_chip("BOT", G.C.PURPLE, 0.72, 0.3)
			end
			return lane
		end
	end

	local get_sorted_players_ref = MP.UI.get_sorted_players
	if type(get_sorted_players_ref) == "function" then
		function MP.UI.get_sorted_players(...)
			local players = get_sorted_players_ref(...)
			for _, player in ipairs(players or {}) do
				if lobby_bot_state.ids[tostring(player.id)]
					and not tostring(player.username or ""):find("%[BOT%]", 1) then
					player.username = tostring(player.username or "Guest") .. " [BOT]"
				end
			end
			return players
		end
	end

	local row_view_model = MP.UI.PLAYER_ROW_VIEW_MODEL
	local build_player_surface_model_ref = row_view_model
		and row_view_model.build_lobby_player_surface_model
	if type(build_player_surface_model_ref) == "function" then
		row_view_model.build_lobby_player_surface_model = function(player, ...)
			local model = build_player_surface_model_ref(player, ...)
			if model and lobby_bot_state.ids[tostring(model.id)] then
				model.can_make_host = false
				model.show_make_host_button = false
				model.make_host_action = nil
			end
			return model
		end
	end

	local make_player_host_ref = G.FUNCS.make_player_host
	if type(make_player_host_ref) == "function" then
		G.FUNCS.make_player_host = function(e)
			local player_id = e and e.config and e.config.id
				and string.match(e.config.id, "(.+)_make_host")
			if player_id and lobby_bot_state.ids[tostring(player_id)] then return end
			return make_player_host_ref(e)
		end
	end

	local get_lobby_warnings_ref = MP.UI.get_lobby_warnings
	if type(get_lobby_warnings_ref) == "function" then
		function MP.UI.get_lobby_warnings(...)
			local original = get_lobby_warnings_ref(...)
			if lobby_bot_state.count < 1 or lobby_bot_state.lobby_code ~= (MP.LOBBY and MP.LOBBY.code) then
				return original
			end
			local warnings = {}
			for _, warning in ipairs(original or {}) do warnings[#warnings + 1] = warning end
			if #warnings == 1 and tostring(warnings[1][1] or ""):match("^%s*$") then warnings = {} end
			local noun = lobby_bot_state.count == 1 and "bot is" or "bots are"
			warnings[#warnings + 1] = {
				tostring(lobby_bot_state.count) .. " " .. noun .. " active in this lobby (host-controlled).",
				G.C.ORANGE, 0.3,
			}
			return warnings
		end
	end

	local function bot_support_definition()
		local supported, text = experimental_bot_support_status()
		return {
			n = G.UIT.ROOT,
			config = { align = "cm", colour = G.C.CLEAR },
			nodes = {
				{ n = G.UIT.R, config = { align = "cm", minw = 3.8, minh = 0.55, r = 0.08,
					colour = supported and G.C.DARK_EDITION or G.C.L_BLACK, outline = 1,
					outline_colour = supported and G.C.GREEN or G.C.RED }, nodes = {
					{ n = G.UIT.T, config = { text = text, scale = 0.3,
						colour = supported and G.C.GREEN or G.C.RED } },
				} },
			},
		}
	end

	local main_lobby_options_ref = MP.UI.Main_Lobby_Options
	if type(main_lobby_options_ref) == "function" then
		function MP.UI.Main_Lobby_Options(...)
			local definition = main_lobby_options_ref(...)
			local columns = definition and definition.nodes
			local left = columns and columns[1]
			if left and left.config and left.config.minw == 4 and left.nodes then
				left.nodes[#left.nodes + 1] = { n = G.UIT.O, config = {
					id = "multibots_bot_support", object = UIBox({ definition = bot_support_definition(), config = { align = "cm" } }),
				} }
			end
			return definition
		end
	end

	local function refresh_bot_support()
		local overlay = G.OVERLAY_MENU
		local status = overlay and overlay.get_UIE_by_ID and overlay:get_UIE_by_ID("multibots_bot_support")
		if status and MP.UI.UTILS and MP.UI.UTILS.replace_config_object then
			MP.UI.UTILS.replace_config_object(status, UIBox({
				definition = bot_support_definition(), config = { align = "cm", parent = status },
			}), { recalculate_target = overlay })
		end
	end

	for _, callback_name in ipairs({ "change_ruleset_selection", "change_gamemode_selection", "change_lobby_access_mode" }) do
		local callback_ref = G.FUNCS[callback_name]
		if type(callback_ref) == "function" then
			G.FUNCS[callback_name] = function(...)
				local result = callback_ref(...)
				refresh_bot_support()
				return result
			end
		end
	end
end

-- Add one entry beside Multiplayer's Practice Options and Play buttons. The
-- selected practice ruleset becomes the ruleset for a bot-filled MP lobby.
local build_action_row_ref = MP.UI.build_action_row
if type(build_action_row_ref) == "function" then
function MP.UI.build_action_row(ruleset, mode)
	local row = build_action_row_ref(ruleset, mode)
	if mode == "practice" and bot_ruleset_allowed(ruleset) then
		table.insert(row.nodes, 2, {
			n = G.UIT.C,
			config = { align = "cm", padding = 0.05 },
			nodes = {
				UIBox_button({
					id = "multibots_button",
					button = "open_multibots_setup",
					label = { "Play vs Bot" },
					minw = 3.2,
					minh = 0.8,
					scale = 0.4,
					colour = G.C.PURPLE,
				}),
			},
		})
		-- Multiplayer sizes this row for two buttons (3.5 + 5 units). Once
		-- the bot action is present, give all three equal widths so the row
		-- remains inside the fixed 11-unit ruleset panel.
		for _, column in ipairs(row.nodes) do
			local button = column.nodes and column.nodes[1]
			local face = button and button.nodes and button.nodes[1]
			for _, label_row in ipairs((face and face.nodes) or {}) do
				if label_row.config then
					label_row.config.minw = 3.2
					label_row.config.maxw = 3.0
				end
			end
		end
	end
	return row
end
end

sendInfoMessage("MultiBots " .. tostring(MOD.version) .. " loaded", "MULTIBOTS")
