-- Tiny disconnectable signal/event.

local Signal = {}
Signal.__index = Signal

function Signal.new()
    return setmetatable({ _listeners = {} }, Signal)
end

function Signal:Connect(fn)
    -- Key listeners by a unique connection token, NOT by array index. An
    -- index-based scheme breaks after the first Disconnect: it leaves a nil
    -- hole, and a subsequent table.insert over a holed array has an undefined
    -- position (# can return any border), so listeners can collide or vanish.
    local conn = {}
    self._listeners[conn] = fn
    conn.Disconnect = function()
        self._listeners[conn] = nil
    end
    return conn
end

function Signal:Fire(...)
    for _, fn in pairs(self._listeners) do
        task.spawn(fn, ...)
    end
end

function Signal:DisconnectAll()
    table.clear(self._listeners)
end

return Signal
