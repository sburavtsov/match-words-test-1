--[[
move_resolver.lua

Валидация и резолвинг хода.
Реализует строгий порядок BR-D04 §100-110:

  1. Применить действие игрока (удалить буквы, собрать цели, создать бустер).
  2. Обновить idle_moves.
  3. Если достигнут порог mercy-joker — разместить mercy-joker ДО падения.
  4. Выполнить падение (gravity).
  5. Заполнить пустоты новыми буквами через BR-G01/BR-G02 (spawn_service).
  6. Сформировать delta-zone.
  7. Нормализовать лимиты джокеров.
  8. При необходимости разместить новый целевой символ.
  9. Выполнить always-on delta-repair (BR-D02).
 10. Раз в 3 хода — анализ random joker (BR-J01).
 11. Повторно нормализовать лимиты джокеров.

Возврат resolve():
  {
    ok = bool, error?,
    chosen_word, valid_words, tile_len,
    booster_created,
    targets_collected_now, total_targets_collected, targets_remaining,
    mercy_injected, random_joker_injected,
    repair = {...},
    is_win,
    idle_moves, move_count
  }
]]--

local utils = require("shared.utils")
local board_geometry = require("services.board_geometry")
local board_service = require("services.board_service")
local target_service = require("services.target_service")
local delta_repair = require("services.delta_repair")
local joker_service = require("services.joker_service")
local cell_factory = require("services.cell_factory")
local event_logger = require("services.event_logger")

local move_resolver = {}

local CONSTANTS = cell_factory.get_constants()
local CK = board_geometry.coord_key

-- ── Валидация пути ────────────────────────────

local function validate_path_shape(state, move_coords)
	if type(move_coords) ~= "table" or #move_coords == 0 then
		return false, "move_coords is empty"
	end
	local visited = {}
	for i = 1, #move_coords do
		local p = move_coords[i]
		if type(p) ~= "table" or p.x == nil or p.y == nil then
			return false, "bad coordinate at index " .. i
		end
		if not board_geometry.in_field(state.board, p.x, p.y) then
			return false, "out of bounds at " .. i
		end
		local cell = state.grid[p.x][p.y]
		if cell == nil then return false, "empty cell at " .. i end
		if cell.is_booster then return false, "booster at " .. i end
		local key = CK(p.x, p.y)
		if visited[key] then return false, "reused cell at " .. i end
		visited[key] = true
		if i > 1 then
			local prev = move_coords[i - 1]
			if not board_geometry.are_neighbors(state.board, prev.x, prev.y, p.x, p.y) then
				return false, "non-neighbor step " .. (i - 1) .. "→" .. i
			end
		end
	end
	return true
end

-- DFS по пути с подстановкой алфавита в джокеры.
local function enumerate_words(state, dictionary, move_coords)
	local valid_set = {}
	local alphabet = dictionary.alphabet
	local function step(idx, current_word)
		if idx > #move_coords then
			if dictionary.valid_words[current_word] then valid_set[current_word] = true end
			return
		end
		local p = move_coords[idx]
		local cell = state.grid[p.x][p.y]
		if cell.char == CONSTANTS.CHAR_JOKER then
			for a = 1, #alphabet do
				local nw = current_word .. alphabet[a]
				if dictionary.prefixes[nw] then step(idx + 1, nw) end
			end
		else
			local nw = current_word .. cell.char
			if dictionary.prefixes[nw] then step(idx + 1, nw) end
		end
	end
	step(1, "")
	return utils.set_to_sorted_array(valid_set)
end

-- Выбор лучшего слова из валидных — Pool A > B > C, потом длина, потом freq.
local function pick_best_word(dictionary, words)
	local function pool_rank(w)
		local p = dictionary.word_pool[w] or "C"
		if p == "A" then return 1 end
		if p == "B" then return 2 end
		return 3
	end
	table.sort(words, function(a, b)
		local pa, pb = pool_rank(a), pool_rank(b)
		if pa ~= pb then return pa < pb end
		local la, lb = dictionary.word_length[a] or #a, dictionary.word_length[b] or #b
		if la ~= lb then return la > lb end
		local fa = dictionary.word_frequencies[a] or 0
		local fb = dictionary.word_frequencies[b] or 0
		if fa ~= fb then return fa > fb end
		return a < b
	end)
	return words[1]
end

-- ── Главный resolve ──────────────────────────

function move_resolver.resolve(state, move_coords, dictionary)
	dictionary = dictionary or state.dictionary
	if not state then return {ok = false, error = "state is nil"} end
	if not dictionary or not dictionary.valid_words or not dictionary.prefixes then
		return {ok = false, error = "dictionary incomplete"}
	end

	local ok, err = validate_path_shape(state, move_coords)
	if not ok then
		event_logger.log("move_rejected", {reason = err})
		return {ok = false, error = err}
	end

	local valid_words = enumerate_words(state, dictionary, move_coords)
	if #valid_words == 0 then
		event_logger.log("move_rejected", {reason = "no_valid_words"})
		return {ok = false, error = "no valid words for this path"}
	end

	local chosen_word = pick_best_word(dictionary, valid_words)
	local chosen_pool = dictionary.word_pool[chosen_word] or "C"
	local tile_len = #move_coords

	-- 1. Применить действие.
	local targets_collected = target_service.collect_in_path(state, move_coords)
	local booster, removed = board_service.resolve_word_path(state, move_coords, tile_len)
	state.targets_collected = state.targets_collected or 0
	state.move_count = (state.move_count or 0) + 1

	-- targets_collected уже учёл idle_moves в target_service.collect_in_path.

	-- 3. Mercy joker (до падения).
	local mercy_injected = false
	if state.board.use_mercy_joker then
		mercy_injected = joker_service.try_mercy_joker(state, dictionary) or false
	end

	-- 4. Гравитация.
	local moved_cells = board_service.apply_gravity(state)

	-- 5. Заполнить пустоты.
	local new_cells = board_service.fill_after_gravity(state)

	-- 6. Сформировать delta-zone.
	local deltas = {
		removed = removed,
		moved = moved_cells,
		new = new_cells
	}

	-- 7. Нормализация джокеров.
	joker_service.normalize(state)

	-- 8. Целевой спавн.
	local target_spawned, target_info = board_service.spawn_target(state)

	-- 9. Always-on delta-repair.
	state.last_repair_cells = {} -- очистить перед repair
	local repair_result = nil
	if state.board.cfg.repair_target_min_len then
		repair_result = delta_repair.run(state, dictionary, deltas)
	end

	-- 10. Раз в N ходов — random joker.
	local random_injected = board_service.maybe_analyze_random_joker(state) or false

	-- 11. Повторная нормализация джокеров.
	joker_service.normalize(state)

	-- Win check.
	local is_win = (state.targets_collected >= state.target_goal)

	-- Логирование хода (BR-M01 §205).
	event_logger.log("move", {
		word = chosen_word,
		pool = chosen_pool,
		length = tile_len,
		used_jokers = (function()
			for i = 1, #move_coords do
				local p = move_coords[i]
				local c = state.grid[p.x] and state.grid[p.x][p.y]
				if c and c.char == CONSTANTS.CHAR_JOKER then return true end
			end
			return false
		end)(),
		targets_collected_now = targets_collected,
		booster_created = booster,
		mercy_injected = mercy_injected,
		random_joker_injected = random_injected,
		move_count = state.move_count,
		idle_moves = state.idle_moves,
		is_win = is_win
	})

	if is_win then
		event_logger.log("level_end", {
			result = "win",
			move_count = state.move_count,
			targets_collected = state.targets_collected
		})
	end

	return {
		ok = true,
		chosen_word = chosen_word,
		chosen_pool = chosen_pool,
		valid_words = valid_words,
		tile_len = tile_len,
		booster_created = booster,
		targets_collected_now = targets_collected,
		total_targets_collected = state.targets_collected,
		targets_remaining = state.target_goal - state.targets_collected,
		target_spawned = target_spawned and true or false,
		mercy_injected = mercy_injected,
		pity_injected = mercy_injected, -- обратная совместимость
		random_joker_injected = random_injected,
		repair = repair_result,
		is_win = is_win,
		idle_moves = state.idle_moves,
		move_count = state.move_count
	}
end

return move_resolver
