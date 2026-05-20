-- Tiny disconnectable signal/event.

local Signal = {}
Signal.__index = Signal

function Signal.new()
    return setmetatable({ _listeners = {} }, Signal)
end

function Signal:Connect(fn)
    table.insert(self._listeners, fn)
    local idx = #self._listeners
    return {
        Disconnect = function()
            self._listeners[idx] = nil
        end,
    }
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
