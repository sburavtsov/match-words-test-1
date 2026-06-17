--[[
event_logger.lua

Structured event logger (BR-M01).

Заменяет print()-логи на типизированные события. Хост-приложение
прикрепляет sink через event_logger.set_sink(fn). Если sink не задан,
события буферизуются в кольцевом буфере (по умолчанию 1024 записи).

API:
  event_logger.set_sink(fn)            -- fn(event_table)
  event_logger.set_context(ctx)        -- session_id, level_id, dict_version, balance_version
  event_logger.log(event_type, payload)
  event_logger.drain() -> {events...}  -- очистить буфер
  event_logger.reset()

Каноничные типы событий (см. BR-M01 §203-210):
  session_start, level_start, level_end,
  move, repair, random_joker, mercy_joker,
  target_spawned, target_collected, deadlock, sanity_check
]]--

local event_logger = {}

local _sink = nil
local _context = {}
local _buffer = {}
local _buffer_limit = 1024

function event_logger.set_sink(fn)
	_sink = fn
end

function event_logger.set_context(ctx)
	_context = ctx or {}
end

function event_logger.merge_context(ctx)
	if not ctx then return end
	for k, v in pairs(ctx) do
		_context[k] = v
	end
end

function event_logger.set_buffer_limit(n)
	_buffer_limit = math.max(16, tonumber(n) or 1024)
end

-- Construct a flat event row, attaching context fields.
local function build_event(event_type, payload)
	local ev = {
		event_type = event_type,
		ts = os.time and os.time() or 0
	}
	for k, v in pairs(_context) do ev[k] = v end
	if payload then
		for k, v in pairs(payload) do ev[k] = v end
	end
	return ev
end

function event_logger.log(event_type, payload)
	local ev = build_event(event_type, payload)
	if _sink then
		_sink(ev)
	else
		_buffer[#_buffer + 1] = ev
		if #_buffer > _buffer_limit then
			table.remove(_buffer, 1)
		end
	end
	return ev
end

function event_logger.drain()
	local out = _buffer
	_buffer = {}
	return out
end

function event_logger.peek()
	return _buffer
end

function event_logger.reset()
	_buffer = {}
	_context = {}
	_sink = nil
end

return event_logger
