-- Pantheon logging. Prefixed and gated on a debug flag.

local PREFIX = "[Pantheon]"
local DEBUG = false

local log = {}

function log.setDebug(v)
    DEBUG = v and true or false
end

function log.info(...)  print(PREFIX, ...) end
function log.warn(...)  warn(PREFIX, ...)  end
function log.err(...)   warn(PREFIX, "[E]", ...) end

function log.debug(...)
    if DEBUG then print(PREFIX, "[D]", ...) end
end

return log
