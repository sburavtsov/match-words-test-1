--[[
cell_factory.lua

Фабрика клеток. Под ТЗ упрощена:
- Случайные джокеры на спавне НЕ создаются (см. BR-J01 — random joker
  теперь создаётся отдельным алгоритмом раз в 3 хода).
- Генерация букв делегирована letter_bag + spawn_service (BR-F04, BR-G01).
- Cell_factory остаётся ответственным только за создание объекта-клетки.

API (обратная совместимость с расширением):
  cell = cell_factory.create_cell(board_config, options)
    options:
      char        -- если задан, используется как есть
      is_target
      is_booster
      joker_type  -- если char == JOKER

  cell_factory.is_joker(cell)
  cell_factory.joker_type(cell)
  cell_factory.get_constants()

  -- новые:
  cell_factory.create_letter_cell(letter, opts) -- сахар
  cell_factory.create_joker_cell(joker_type)
  cell_factory.create_booster_cell(booster_char)
]]--

local cell_factory = {}

local CHAR_JOKER = "@"
local JOKER_RANDOM = "random"
local JOKER_MERCY = "mercy"

local BOOSTER_BOMB = "§"
local BOOSTER_LINE = "±"
local BOOSTER_COLOR = "#"

local CONSTANTS = {
	CHAR_JOKER = CHAR_JOKER,
	JOKER_RANDOM = JOKER_RANDOM,
	JOKER_MERCY = JOKER_MERCY,
	BOOSTER_BOMB = BOOSTER_BOMB,
	BOOSTER_LINE = BOOSTER_LINE,
	BOOSTER_COLOR = BOOSTER_COLOR
}

function cell_factory.get_constants()
	return CONSTANTS
end

local function new_cell(char, opts)
	opts = opts or {}
	local is_target = opts.is_target == true
	local is_booster = opts.is_booster == true
	local joker_type = (char == CHAR_JOKER) and opts.joker_type or nil
	return {
		char = char,
		is_target = is_target,
		is_booster = is_booster,
		joker_type = joker_type,
		origin = opts.origin -- метка для repair/random_joker (BR-J01 §137: новые клетки)
	}
end

-- Основной конструктор. char ОБЯЗАТЕЛЕН (старый код передавал nil и просил
-- сгенерировать — теперь это запрещено: используйте spawn_service).
function cell_factory.create_cell(board_config, options)
	options = options or {}
	local char = options.char
	if char == nil then
		error("cell_factory.create_cell: char is required (use spawn_service to generate)")
	end
	return new_cell(char, options)
end

function cell_factory.create_letter_cell(letter, opts)
	return new_cell(letter, opts)
end

function cell_factory.create_target_cell(letter, opts)
	opts = opts or {}
	opts.is_target = true
	return new_cell(letter, opts)
end

function cell_factory.create_joker_cell(joker_type, opts)
	opts = opts or {}
	opts.joker_type = joker_type
	return new_cell(CHAR_JOKER, opts)
end

function cell_factory.create_booster_cell(booster_char, opts)
	opts = opts or {}
	opts.is_booster = true
	return new_cell(booster_char, opts)
end

function cell_factory.is_joker(cell)
	return cell ~= nil and cell.char == CHAR_JOKER
end

function cell_factory.joker_type(cell)
	if not cell_factory.is_joker(cell) then return nil end
	return cell.joker_type
end

function cell_factory.is_ordinary(cell)
	-- Обычная буква: не пустая, не бустер, не джокер, не цель.
	if cell == nil then return false end
	if cell.is_booster then return false end
	if cell.char == CHAR_JOKER then return false end
	if cell.is_target then return false end
	return true
end

return cell_factory
