--[[
board_service.lua

Центральный state-keeper доски (переработка под ТЗ).

Сохраняет публичные имена методов из исходной версии:
  board_service.init(options) -> state
  board_service.apply_gravity(state) -> moved_cells_list
  board_service.normalize_jokers(state)  -- делегирует joker_service
  board_service.spawn_target(state) -> bool
  board_service.count_targets_in_path(state, coords) -> n
  board_service.resolve_word_path(state, coords, tile_len) -> booster_char|nil
  board_service.can_spawn_random_joker(state) -> bool (для обратной совместимости)
  board_service.debug_dump(state) -> string

И добавляет:
  board_service.collect_deltas(state) -> nil   -- инициализирует пустую запись
]]--

local utils = require("shared.utils")
local board_geometry = require("services.board_geometry")
local cell_factory = require("services.cell_factory")
local config = require("services.config")
local dictionary_service = require("services.dictionary_service")
local letter_bag = require("services.letter_bag")
local spawn_service = require("services.spawn_service")
local target_service = require("services.target_service")
local field_initializer = require("services.field_initializer")
local joker_service = require("services.joker_service")
local event_logger = require("services.event_logger")

local board_service = {}

local CK = board_geometry.coord_key
local CONSTANTS = cell_factory.get_constants()

-- ── Инициализация ─────────────────────────────

-- options:
--   pattern, difficulty, dictionary, target_letters, force_ascii_upper,
--   use_random_joker, use_mercy_joker, ftue (bool), level_id,
--   config_overrides  -- частичный override полей config
function board_service.init(options)
	options = options or {}

	-- 1) Применить локальный конфиг.
	if options.config_overrides then config.apply(options.config_overrides) end
	local cfg = config.get()
	if options.difficulty then cfg.difficulty = options.difficulty end

	-- 2) Сформировать board-config.
	local board = {
		pattern = utils.copy_array(options.pattern or cfg.board_pattern),
		num_cols = 0, max_rows = 0,
		difficulty = cfg.difficulty,
		use_random_joker = options.use_random_joker ~= false,
		use_mercy_joker = options.use_mercy_joker ~= false,
		cfg = cfg
	}
	board.num_cols = #board.pattern
	board.max_rows = utils.array_max(board.pattern)

	-- 3) Словарь.
	local dictionary = options.dictionary
	if not dictionary then
		error("board_service.init: options.dictionary is required (use dictionary_service.init first)")
	end

	-- 4) Цели.
	local target_letters = options.target_letters or {"A", "S", "D"}
	local pending = {}
	local target_set = {}
	for i = 1, #target_letters do
		local t = tostring(target_letters[i])
		if options.force_ascii_upper ~= false then t = string.upper(t) end
		if t == "Q" then t = "QU" end
		pending[#pending + 1] = t
		target_set[t] = true
	end

	-- 5) Состояние.
	local state = {
		board = board,
		grid = {},
		neighbors_map = {},
		dictionary = dictionary,
		bag = nil,
		target_letters_set = target_set,

		pending_targets = pending,
		target_goal = #pending,
		targets_collected = 0,
		idle_moves = 0,
		move_count = 0,
		last_repair_cells = {},
		target_anchor_path_set = {}
	}
	for x = 1, board.num_cols do state.grid[x] = {} end

	state.neighbors_map = board_geometry.build_neighbors_map(board)

	-- 6) Подсчёт ячеек и инициализация мешка.
	local cell_count = 0
	for x = 1, board.num_cols do cell_count = cell_count + board.pattern[x] end
	state.bag = letter_bag.create(dictionary, cell_count, board.difficulty, cfg, target_set)

	-- 7) Стартовое поле через field_initializer (BR-F01..F03).
	local ok, info = field_initializer.build(state, dictionary, {
		ftue = options.ftue,
		level_id = options.level_id
	})

	if state.target_anchor_path then
		state.target_anchor_path_set = {}
		for i = 1, #state.target_anchor_path do
			local p = state.target_anchor_path[i]
			state.target_anchor_path_set[CK(p.x, p.y)] = true
		end
	end

	event_logger.log("level_start", {
		level_id = options.level_id,
		difficulty = board.difficulty,
		pattern = table.concat(board.pattern, ","),
		init_ok = ok,
		coverage = info.coverage,
		anchor_word = info.anchor_word,
		dictionary_version = cfg.dictionary_version,
		balance_version = cfg.balance_version
	})

	return state
end

-- ── Обратная совместимость: spawn_target ──────

function board_service.spawn_target(state)
	return target_service.try_spawn(state)
end

function board_service.count_targets_in_path(state, move_coords)
	return target_service.count_in_path(state, move_coords)
end

-- ── Гравитация ────────────────────────────────

-- Возвращает список перемещённых клеток (новые координаты) для BR-D01.
function board_service.apply_gravity(state)
	local moved = {}
	for x = 1, state.board.num_cols do
		local col_h = state.board.pattern[x]
		-- Считаем сверху вниз: соберём непустые клетки.
		local stack = {}
		for y = 1, col_h do
			if state.grid[x][y] ~= nil then
				stack[#stack + 1] = {orig_y = y, cell = state.grid[x][y]}
			end
		end
		-- Очистить колонку.
		for y = 1, col_h do state.grid[x][y] = nil end
		-- Уложить снизу.
		for i = 1, #stack do
			local new_y = col_h - i + 1
			-- Сверху массива идут «верхние» клетки — кладём сверху новой колонки,
			-- т.е. порядок stack: верх→низ оригинала. Перевернём:
		end
		-- Правильнее: уложить так, чтобы внизу был самый нижний из stack (макс. orig_y).
		table.sort(stack, function(a, b) return a.orig_y > b.orig_y end)
		for i = 1, #stack do
			local new_y = col_h - i + 1
			state.grid[x][new_y] = stack[i].cell
			if stack[i].orig_y ~= new_y then
				moved[#moved + 1] = {x = x, y = new_y, from_y = stack[i].orig_y}
			end
		end
	end
	return moved
end

-- ── BR-D04 пост-падение fill (через spawn_service) ──

function board_service.fill_after_gravity(state)
	return spawn_service.fill_empty_cells(state)
end

-- ── Уничтожение пути + booster (BR-S02 §176-179) ──

function board_service.resolve_word_path(state, move_coords, tile_len)
	local booster = nil
	if state.board.cfg.enable_boosters then
		if tile_len == 5 then booster = CONSTANTS.BOOSTER_LINE
		elseif tile_len == 6 then booster = CONSTANTS.BOOSTER_BOMB
		elseif tile_len >= 7 then booster = CONSTANTS.BOOSTER_COLOR end
	end

	local removed = {}
	for i = 1, #move_coords do
		local p = move_coords[i]
		if i == #move_coords and booster then
			state.grid[p.x][p.y] = cell_factory.create_booster_cell(booster, {origin = "booster"})
		else
			removed[#removed + 1] = {x = p.x, y = p.y}
			state.grid[p.x][p.y] = nil
		end
	end
	return booster, removed
end

-- ── BR-J03: нормализация джокеров ─────────────

function board_service.normalize_jokers(state)
	joker_service.normalize(state)
end

-- ── Обратная совместимость (старые имена) ────

function board_service.can_spawn_random_joker(state)
	local s = joker_service.stats(state)
	local cfg = state.board.cfg
	return s.total < (cfg.max_total_jokers or 2) and s.random < (cfg.max_random_jokers or 1)
end

-- ── Анализ random joker (BR-J01), вызывается раз в N ходов ──

function board_service.maybe_analyze_random_joker(state)
	local cfg = state.board.cfg
	if not state.board.use_random_joker then return false end
	local period = cfg.random_joker_check_period or 3
	if state.move_count % period ~= 0 then return false end
	return joker_service.analyze_random_joker(state, state.dictionary)
end

-- ── debug_dump ────────────────────────────────

function board_service.debug_dump(state)
	local lines = {}
	for y = 1, state.board.max_rows do
		local row = {}
		for x = 1, state.board.num_cols do
			if y <= state.board.pattern[x] then
				local cell = state.grid[x][y]
				if cell == nil then row[#row + 1] = " . "
				else
					local text = cell.char
					if cell.is_target then text = text .. "*"
					elseif cell.is_booster then text = text .. "$"
					elseif cell.char == CONSTANTS.CHAR_JOKER then
						text = text .. (cell.joker_type == CONSTANTS.JOKER_RANDOM and "R" or "M")
					end
					row[#row + 1] = string.format("%-3s", text)
				end
			else
				row[#row + 1] = "   "
			end
		end
		lines[#lines + 1] = table.concat(row, " ")
	end
	return table.concat(lines, "\n")
end

return board_service
