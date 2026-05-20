-- Executor capability shim. Centralizes which optional APIs exist on the host
-- exploit so callers don't have to feature-detect inline.

local env = {}

env.executor = (identifyexecutor and select(1, identifyexecutor())) or "unknown"

env.HttpGet = function(url)
    return game:HttpGet(url, true)
end

env.request = (syn and syn.request)
    or (http and http.request)
    or request
    or http_request

env.writefile   = writefile
env.readfile    = readfile
env.appendfile  = appendfile
env.isfile      = isfile
env.delfile     = delfile
env.makefolder  = makefolder
env.isfolder    = isfolder
env.delfolder   = delfolder
env.listfiles   = listfiles

env.hookfunction      = hookfunction
env.hookmetamethod    = hookmetamethod
env.getrawmetatable   = getrawmetatable
env.setreadonly      = setreadonly
env.getconnections    = getconnections
env.firesignal        = firesignal
env.fireclickdetector = fireclickdetector
env.firetouchinterest = firetouchinterest
env.fireproximityprompt = fireproximityprompt
env.getnamecallmethod = getnamecallmethod
env.setnamecallmethod = setnamecallmethod

env.getgenv = getgenv
env.getrenv = getrenv
env.getsenv = getsenv

env.guiParent = function()
    if gethui then
        local ok, gui = pcall(gethui)
        if ok and gui then return gui end
    end
    return game:GetService("CoreGui")
end

env.protectGui = function(inst)
    if syn and syn.protect_gui then pcall(syn.protect_gui, inst) end
    if protect_gui then pcall(protect_gui, inst) end
end

return env
