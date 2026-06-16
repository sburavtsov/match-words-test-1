--[[
cell_factory.lua

Responsible for generating individual cells and characters.
Depends on board config (difficulty, power_factor, weights).
No board state, just cell creation.

Usage:
local cell = cell_factory.create_cell(board_config, {
	char = "A",
	is_target = true,
	allow_joker = false
})
]]--

local utils = require("shared.utils")

local cell_factory = {}

-- ──────────────────────────────────────────────────
-- Constants
-- ──────────────────────────────────────────────────

local CHAR_JOKER = "!"
local JOKER_RANDOM = "random"
local JOKER_PITY = "pity"

-- ──────────────────────────────────────────────────
-- Character generation
-- ──────────────────────────────────────────────────

function cell_factory.generate_regular_char(board_config)
	local power_factor = 1.0 - (board_config.difficulty * 0.85)

	local category
	if math.random() < 0.35 then
		category = board_config.bg_weights.vowels
	else
		category = board_config.bg_weights.consonants
	end

	local letters = category.letters
	local raw_weights = category.weights
	local final_weights = {}

	for i = 1, #raw_weights do
		final_weights[i] = raw_weights[i] ^ power_factor
	end

	local char = utils.weighted_choice(letters, final_weights)

	if char == "Q" then
		return "QU"
	end

	return char
end

function cell_factory.generate_char(board_config, can_spawn_random)
	if board_config.use_random_joker
	and can_spawn_random
	and math.random() < board_config.current_joker_chance then
		return CHAR_JOKER, JOKER_RANDOM
	end

	return cell_factory.generate_regular_char(board_config), nil
end

-- ──────────────────────────────────────────────────
-- Cell creation
-- ──────────────────────────────────────────────────

function cell_factory.create_cell(board_config, options)
	options = options or {}

	local char = options.char
	local joker_type = options.joker_type
	local is_target = options.is_target == true
	local is_booster = options.is_booster == true
	local allow_joker = options.allow_joker ~= false

	if char == nil then
		char, joker_type = cell_factory.generate_char(board_config, allow_joker)
	elseif char ~= CHAR_JOKER then
		joker_type = nil
	end

	return {
		char = char,
		is_target = is_target,
		is_booster = is_booster,
		joker_type = (char == CHAR_JOKER) and joker_type or nil
	}
end

-- ──────────────────────────────────────────────────
-- Joker detection helpers
-- ──────────────────────────────────────────────────

function cell_factory.is_joker(cell)
	return cell ~= nil and cell.char == CHAR_JOKER
end

function cell_factory.joker_type(cell)
	if not cell_factory.is_joker(cell) then
		return nil
	end
	return cell.joker_type
end

-- ──────────────────────────────────────────────────
-- Expose constants for other modules
-- ──────────────────────────────────────────────────

function cell_factory.get_constants()
	return {
		CHAR_JOKER = CHAR_JOKER,
		BOOSTER_BOMB = "Ю",
		BOOSTER_LINE = "⚡",
		BOOSTER_COLOR = "§",
		JOKER_RANDOM = JOKER_RANDOM,
		JOKER_PITY = JOKER_PITY
	}
end

return cell_factory