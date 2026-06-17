--[[
config.lua

Единый источник параметров баланса (под BR-M03 remote config).
Все значения должны быть переопределяемы через config.apply(overrides),
который хост-приложение вызывает после загрузки remote payload.

Все BR-ссылки указаны рядом с полями.
]]--

local utils = require("shared.utils")

local config = {}

local DEFAULTS = {
	-- Сложность ─────────────────────────────────────
	difficulty = 0.6,

	-- BR-V01: размеры пулов словаря.
	pool_a_limit = 3000,
	pool_b_limit = 8000,
	pool_b_recognition_prob = 0.6, -- вероятность что игрок знает Pool B (для симулятора)

	-- BR-V02: модель частот букв (веса DF/LF).
	letter_freq_corpus_min_len = 3,
	letter_freq_corpus_max_len = 5,
	letter_weight_df = 0.7,
	letter_weight_lf = 0.3,

	-- BR-V03: порог редких букв по сложности.
	rare_letter_low_diff_cap = 0.35,
	rare_letter_high_diff_cap = 0.55,
	rare_letter_max_threshold = 0.05,

	-- BR-V04: корпус для расчёта vowel_ratio.
	vowel_ratio_corpus_min_len = 3,
	vowel_ratio_corpus_max_len = 6,

	-- BR-F01: целевое покрытие стартовыми словами.
	starter_coverage_ftue = {min = 0.20, max = 0.30},
	starter_coverage_normal = {min = 0.10, max = 0.20},
	starter_coverage_base = {min = 0.20, max = 0.25},
	starter_min_word_len = 3,
	starter_max_word_len = 4,
	starter_extended_max_len = 5, -- если коротких слов недостаточно
	starter_direction_pref = {vertical = 0.65, horizontal = 0.25, diagonal = 0.10},
	starter_max_attempts = 6,

	-- BR-F04: размер частотного мешка.
	bag_size_multiplier = 100,
	bag_refill_min_fraction = 0.1, -- если мешок ≤ 10% — refill

	-- BR-G01: локальный vowel-control.
	vowel_control_delta = 0.05,

	-- BR-D02: always-on delta-repair.
	repair_delta_radius = 2,
	repair_target_pool = "A",
	repair_target_min_len = 3,
	repair_target_max_len = 4,
	repair_max_letter_replacements = 2,
	repair_protect_word_max_len = 5,

	-- BR-P01: лимит активных целей.
	max_active_targets = 3,
	target_spawn_base_prob = nil, -- вычисляется из difficulty при отсутствии

	-- BR-J01: random joker.
	random_joker_check_period = 3,            -- раз в N ходов
	random_joker_window_width = 3,
	random_joker_freq_threshold_low = 0.040,  -- порог при difficulty 0.0
	random_joker_freq_threshold_high = 0.020, -- порог при difficulty 1.0

	-- BR-J02: mercy joker.
	mercy_joker_base = 3,
	mercy_joker_diff_factor = 10, -- threshold = base + round(diff² × factor)
	mercy_joker_max_word_len = 5,

	-- BR-J03: лимиты джокеров.
	max_random_jokers = 1,
	max_mercy_jokers = 1,
	max_total_jokers = 2,

	-- BR-F02/P02: целевая позиция.
	target_low_diff_center_power = 3, -- (1-norm_dist)^power
	target_high_diff_edge_power = 4,  -- norm_dist^power
	target_low_diff_split = 0.4,

	-- FTUE
	ftue = {
		first_level_completed = false,
		level_id = 1,
		ftue_max_level = 3
	},

	-- Конфигурация поля по умолчанию (можно переопределить per-level).
	board_pattern = {7, 6, 7, 6, 7, 6, 7, 6, 7},

	-- Метаданные версионности.
	balance_version = "1.0",
	dictionary_version = nil,

	-- Когнитивная модель симулятора (P2) — заглушки.
	cognitive = {
		diagonal_blindness = 0.25,
		tunnel_vision_prob = 0.40,
		tunnel_vision_radius = 3,
		impulse_prob = 0.12
	}
}

-- Глубокая копия дефолтов (чтобы apply не портил источник).
local function deep_copy(t)
	if type(t) ~= "table" then return t end
	local out = {}
	for k, v in pairs(t) do out[k] = deep_copy(v) end
	return out
end

local _current = deep_copy(DEFAULTS)

function config.get()
	return _current
end

function config.get_defaults()
	return deep_copy(DEFAULTS)
end

-- Поверхностное слияние overrides поверх текущего конфига.
-- Вложенные таблицы заменяются целиком, не мерджатся, чтобы remote
-- config контролировал группы параметров атомарно (BR-M03 §214-217).
function config.apply(overrides)
	if type(overrides) ~= "table" then return _current end
	for k, v in pairs(overrides) do
		_current[k] = deep_copy(v)
	end
	return _current
end

function config.reset()
	_current = deep_copy(DEFAULTS)
	return _current
end

return config
