-- VENDORED THIRD-PARTY CODE -- do not hand-edit.
--
-- Ball Reaction 1.8.9 betasync5378, by projectsMy123-hub (MIT).
-- Source: https://github.com/projectsMy123-hub/Dodge-or-die-script
-- Pinned commit: 710136b2885265d8956d326e1fdcfc1483e2eed1 (2026-09-15)
--
-- Predictive auto-dodge for Dodge or Die. Copied VERBATIM from upstream and
-- wrapped in a factory so requiring this module does NOT start it -- the body
-- only runs when games/dodgeordie.lua calls the returned function, which
-- returns { Destroy, Stats, SelfTest }.
--
-- It builds its own Fluent UI (upstream HttpGets dawid-scripts/Fluent at the
-- bottom of the body) rather than Pantheon's -- that panel is where the ~40
-- individual knobs live. Pantheon's row just starts and stops it.
--
-- Why pinned to a SHA and not vendored-by-fetch: a branch URL would let the
-- upstream author swap this code under us. A SHA path is immutable, and having
-- the bytes in-tree means the bundle stays self-contained.
--
-- Re-vendoring: download the raw `script` file at the SHA you want, replace
-- everything below the `return function()` line, bump the header, rebuild.

return function()
-- Ball Reaction 1.8.9 betasync5378 | RightShift: menu/replay | F8: stop
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Input = game:GetService("UserInputService")
local Tags = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Player = Players.LocalPlayer
local PlayerGui = Player:WaitForChild("PlayerGui", 10)
assert(PlayerGui, "PlayerGui no disponible")

local previous = Player:FindFirstChild("BallReactionControl") or PlayerGui:FindFirstChild("BallReactionControl")
local previousAuto = false
if previous and previous:IsA("BindableFunction") then
    local success, previousStats = pcall(function() return previous:Invoke("stats") end)
    if success and type(previousStats) == "table" then previousAuto = previousStats.auto == true end
    pcall(function() previous:Invoke("destroy") end)
end

-- Core
local Config = {
    auto = previousAuto, onlyRound = true,
    horizon = 0.8, margin = 1.0, range = 170,
    walk = true, allStyles = true, hazards = true,
    jump = true, doubleJump = true, lasers = true, centerAvoid = true,
    refine = true, moderateJump = true, lava = true, orient = true, positioning = true,
    normalizeDowned = true, collisionPrediction = true, implicitTargeting = true, hardSafety = true, lavaStability = true,
}
local State = {
    alive = true, balls = {}, hazards = {}, connections = {}, held = {}, lastUsed = {},
    actions = 0, observations = 0, threats = 0, nearest = 0, lastAction = "None",
    status = "Ready", lastError = "", blockedUntil = 0, lastCost = 0,
    lastCharacter = Player.Character, uiClock = 0,
    steering = nil, lastDirection = nil, lastDecisionTime = -100, previousFacing = nil,
    cameraTurnUntil = 0, damageEvents = 0, health = nil, extraMargin = 0,
    hazardCount = 0, effects = "", decisions = {}, downed = false, mobilityChanges = 0,
    lasers = {}, laserCount = 0, jumps = 0, doubles = 0, inputEpoch = 0,
    airSince = nil, airUsed = 1, standingHeight = 3, lastJump = -100,
    arena = nil, center = nil, centerRadius = 12, centerDistance = 0, spawning = 0,
    trace = {}, lastTraceTime = -100, incident = nil, deaths = 0, lastPlaying = false,
    watchedHumanoid = nil, deathConnection = nil,
    lavaBodies = {}, lavaZones = {}, lavaLevel = nil, lavaRise = 0, lavaActive = false,
    lavaGoal = nil, platformClock = -100, lavaGoalLockUntil = -100, lavaLastProgressY = nil,
    lavaLastProgressAt = -100, lavaStalled = false, lavaCandidateCount = 0, lavaTargetRise = 0,
    lavaTargetArea = 0, lavaReturnPlans = 0, targeted = 0, implicitTargeted = 0, anglesTested = 0,
    facing = nil, pendingDash = nil, verifiedDashes = 0, unconfirmedDashes = 0,
    orientedDashes = 0, motionSamples = {}, plansTested = 0, earlyRoundExits = 0,
    groundBraking = 620, airBraking = 145, reversals = 0, planningSamples = {}, planningCycles = 0,
    targetChanges = 0, preparationMoves = 0, lastPreparation = -100, mergedHazards = 0,
    planStages = 1, exitSpace = 0,
    nextBallId = 0,
    completedTurns = 0, stagedMoves = 0,
    predictionConfidence = 1, predictionError = 0, maxUncertainty = 0,
    futureFreedom = 0, largestExitArc = 0, exitClearance = 0, futureThreatDensity = 0, edgeSafety = 0,
    totalPlansEvaluated = 0, planningMs = 0, followupAt = nil, activeMotion = nil, emergencyPlanning = false,
    emergencyReplans = 0, safetyChecks = 0, safetyMs = 0, safetyClock = 0, plannerHz = 30, safetyEligible = false,
    replanRequested = false, lastEmergency = -100, criticalLatch = false, lastCritical = 20,
    emergencyClearance = 20, safetyThreats = {}, safetyTime = 0, stageReplans = 0,
    collisionPredictions = 0, bouncePredictions = 0, hardSafety = false, hardSafetyTrips = 0,
}
local Fluent, Window, StatusText, AutoToggle, DebugStatusText
local Controller = Instance.new("BindableFunction")
Controller.Name = "BallReactionControl"
Controller.Parent = Player
local Cooldowns = {Left = 0.75, Right = 0.75, Forward = 2}
local ZERO = Vector3.zero
local BOUNCE_RESTITUTIONS = {0.35, 0.60, 0.85}

-- Mobility
State.mobility = {
    active = false, reason = "", animationConnection = nil, animationIntent = nil, impulse = nil,
    restoredActions = 0, capturedAnimations = 0, calibrations = 0, entered = 0, lastCalibration = -100,
    profile = {
        lastWalkSpeed = 16, walkSpeed = 16, runSpeed = 16, useJumpPower = true, jumpPower = 50, jumpHeight = 7.2,
        animations = {},
        actions = {Left = {}, Right = {}, Forward = {}, Jump = {}, DoubleJump = {}, Walk = {}, Run = {}},
    },
}

local function connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(State.connections, connection)
    return connection
end

local function noteAnimationIntent(name, ttl)
    State.mobility.animationIntent = {name = name, expires = os.clock() + (ttl or .3)}
end

local function mobilityUnitFlat(v, fallback)
    local flat = Vector3.new(v.X, 0, v.Z)
    return flat.Magnitude > .001 and flat.Unit or fallback
end

local function captureMobilityAnimation(track)
    local character = Player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local animation = track and track.Animation
    local id = animation and animation.AnimationId
    if not humanoid or type(id) ~= "string" or id == "" then return end
    if animation.Name and string.sub(animation.Name, 1, 23) == "BallReactionNormalized_" then return end
    local now = os.clock()
    local intent = State.mobility.animationIntent
    local label
    if intent and now <= intent.expires then
        label = intent.name
        State.mobility.animationIntent = nil
    else
        local state = humanoid:GetState()
        if state == Enum.HumanoidStateType.Jumping or state == Enum.HumanoidStateType.Freefall then
            label = State.airUsed == 1 and "DoubleJump" or "Jump"
        elseif humanoid.MoveDirection.Magnitude > .05 then
            local profile = State.mobility.profile
            label = humanoid.WalkSpeed > math.max(profile.walkSpeed + 1, profile.walkSpeed * 1.12) and "Run" or "Walk"
        end
    end
    if not label then return end
    local entry = State.mobility.profile.animations[label]
    if not entry or (intent and intent.name == label) then
        State.mobility.profile.animations[label] = {
            id = id, name = animation.Name, priority = tostring(track.Priority), length = track.Length,
            looped = track.Looped == true,
        }
        State.mobility.capturedAnimations += 1
    end
end

local function setupMobilityCapture(character)
    if State.mobility.animationConnection then
        State.mobility.animationConnection:Disconnect()
        State.mobility.animationConnection = nil
    end
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local animator = humanoid and (humanoid:FindFirstChildOfClass("Animator") or humanoid:WaitForChild("Animator", 1))
    if not animator then return end
    State.mobility.animationConnection = animator.AnimationPlayed:Connect(function(track)
        pcall(captureMobilityAnimation, track)
    end)
    for _, track in ipairs(animator:GetPlayingAnimationTracks()) do pcall(captureMobilityAnimation, track) end
end

local function captureNormalMobility(character, humanoid, root, now)
    if not character or not humanoid or not root or humanoid.Health <= 0 then return end
    if Tags:HasTag(character, "Downed") or Tags:HasTag(character, "FreezeTagFrozen")
        or Tags:HasTag(character, "HumanShield") or Tags:HasTag(character, "Glued") or root.Anchored then return end
    if now - State.mobility.lastCalibration < .1 then return end
    State.mobility.lastCalibration = now
    local profile = State.mobility.profile
    local speed = math.max(0, humanoid.WalkSpeed)
    profile.lastWalkSpeed = speed
    if State.mobility.calibrations == 0 then
        profile.walkSpeed, profile.runSpeed = speed, speed
    else
        profile.runSpeed = math.max(profile.runSpeed or speed, speed)
        if speed > 0 and speed < (profile.runSpeed or speed) - .5 then profile.walkSpeed = speed end
    end
    profile.useJumpPower = humanoid.UseJumpPower
    profile.jumpPower = humanoid.JumpPower
    profile.jumpHeight = humanoid.JumpHeight
    State.mobility.calibrations += 1
end

local function playMobilityAnimation(label, looped)
    local entry = State.mobility.profile.animations[label]
    if not entry or not entry.id then return nil end
    local character = Player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
    if not animator then return nil end
    local animation = Instance.new("Animation")
    animation.Name = "BallReactionNormalized_" .. label
    animation.AnimationId = entry.id
    local ok, track = pcall(function() return animator:LoadAnimation(animation) end)
    animation:Destroy()
    if not ok or not track then return nil end
    pcall(function()
        track.Looped = looped == true
        track:Play(.04, 1, 1)
    end)
    return track
end

local function stopNormalizedLocomotionAnimation()
    local track = State.mobility.locomotionTrack
    State.mobility.locomotionTrack, State.mobility.locomotionLabel = nil, nil
    if track then pcall(function() track:Stop(.08) end) end
end

local function setNormalizedLocomotionAnimation(label)
    if State.mobility.locomotionLabel == label then return end
    stopNormalizedLocomotionAnimation()
    if label then
        State.mobility.locomotionLabel = label
        State.mobility.locomotionTrack = playMobilityAnimation(label, true)
    end
end

local function activateMobilityNormalizer(character, humanoid)
    if not Config.normalizeDowned or State.mobility.active then return end
    State.mobility.active = true
    State.mobility.reason = "Downed"
    State.mobility.entered += 1
    State.mobility.started = os.clock()
    State.mobility.effectWalkSpeed = humanoid and humanoid.WalkSpeed or nil
    State.mobility.normalWalkSpeed = math.max(1, State.mobility.profile.lastWalkSpeed or State.mobility.profile.walkSpeed or 16)
    State.mobility.impulse = nil
    State.replanRequested, State.blockedUntil = true, 0
end

local function deactivateMobilityNormalizer()
    if not State.mobility.active then return end
    State.mobility.active = false
    State.mobility.reason = ""
    State.mobility.impulse = nil
    stopNormalizedLocomotionAnimation()
    State.replanRequested, State.blockedUntil = true, 0
end

local function startNormalizedImpulse(action, root, now)
    local profile = State.mobility.profile.actions[action.name] or {}
    local peak = profile.peakSpeed or action.speed or (action.name == "Forward" and 120 or 120)
    local braking = profile.braking or ((action.airborne or action.jump) and State.airBraking or State.groundBraking)
    local duration = profile.duration or math.clamp(peak / math.max(1, braking), .14, .32)
    State.mobility.impulse = {
        direction = mobilityUnitFlat(action.direction, -root.CFrame.LookVector), peakSpeed = peak,
        braking = braking, started = now, duration = duration, name = action.name,
    }
    State.mobility.restoredActions += 1
    playMobilityAnimation(action.name, false)
end

local function performNormalizedJump(double)
    local character = Player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid or root.Anchored then return false end
    local profile = State.mobility.profile
    local power = profile.useJumpPower and profile.jumpPower or math.sqrt(2 * math.max(1, workspace.Gravity) * profile.jumpHeight)
    if double then power = math.max(power, 50) end
    local velocity = root.AssemblyLinearVelocity
    root.AssemblyLinearVelocity = Vector3.new(velocity.X, math.max(velocity.Y, power), velocity.Z)
    pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Jumping) end)
    playMobilityAnimation(double and "DoubleJump" or "Jump", false)
    State.lastJump = os.clock(); State.jumps += 1
    if double then State.airUsed = 1; State.doubles += 1 end
    State.mobility.restoredActions += 1
    return true
end

local function manualMoveDirection()
    local camera = workspace.CurrentCamera
    if not camera then return ZERO end
    local x = (Input:IsKeyDown(Enum.KeyCode.D) and 1 or 0) - (Input:IsKeyDown(Enum.KeyCode.A) and 1 or 0)
    local z = (Input:IsKeyDown(Enum.KeyCode.W) and 1 or 0) - (Input:IsKeyDown(Enum.KeyCode.S) and 1 or 0)
    if x == 0 and z == 0 then return ZERO end
    local front = mobilityUnitFlat(camera.CFrame.LookVector, -Vector3.zAxis)
    local right = mobilityUnitFlat(camera.CFrame.RightVector, Vector3.xAxis)
    local direction = right * x + front * z
    return direction.Magnitude > .01 and direction.Unit or ZERO
end

local function mobilityNormalizerTick(now, dt)
    if not State.mobility.active then return end
    local character = Player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not character or not root or not humanoid or humanoid.Health <= 0 or root.Anchored then return end
    if not Tags:HasTag(character, "Downed") then deactivateMobilityNormalizer(); return end
    local impulse = State.mobility.impulse
    if impulse then
        local age = now - impulse.started
        if age <= impulse.duration then
            local speed = math.max(0, impulse.peakSpeed - impulse.braking * age)
            local current = root.AssemblyLinearVelocity
            root.AssemblyLinearVelocity = impulse.direction * speed + Vector3.new(0, current.Y, 0)
            return
        end
        State.mobility.impulse = nil
    end
    local direction = ZERO
    local steering = State.steering
    if Config.auto and steering and now >= steering.start and now <= steering.finish then
        direction = steering.nextDirection and steering.turnAt and now >= steering.turnAt and steering.nextDirection or steering.direction
    else
        direction = manualMoveDirection()
        if direction.Magnitude < .01 and humanoid.MoveDirection.Magnitude > .01 then direction = humanoid.MoveDirection.Unit end
    end
    if direction.Magnitude > .01 then
        local profile = State.mobility.profile
        local running = Input:IsKeyDown(Enum.KeyCode.LeftShift)
        local targetSpeed = running and math.max(State.mobility.normalWalkSpeed or 0, profile.runSpeed or 0)
            or (State.mobility.normalWalkSpeed or profile.lastWalkSpeed or profile.walkSpeed or 16)
        local current = root.AssemblyLinearVelocity
        local flat = Vector3.new(current.X, 0, current.Z)
        local target = direction.Unit * targetSpeed
        local delta = target - flat
        local maxChange = math.max(1, State.groundBraking) * math.max(dt, 1 / 240)
        if delta.Magnitude > maxChange then delta = delta.Unit * maxChange end
        local nextFlat = flat + delta
        root.AssemblyLinearVelocity = Vector3.new(nextFlat.X, current.Y, nextFlat.Z)
        setNormalizedLocomotionAnimation(running and "Run" or "Walk")
    else
        stopNormalizedLocomotionAnimation()
    end
end


-- Replay
State.replay = {
    enabled = true, seconds = 300, sampleHz = 10, capacity = 3005,
    frames = {}, write = 0, count = 0, events = {}, incidents = {}, nextSample = 0,
    recording = true, open = false, playing = false, speed = 1, cursor = 0,
    frozenFrames = nil, frozenEvents = nil, frozenIncidents = nil, startTime = 0, endTime = 0,
    gui = nil, root = nil, viewport = nil, world = nil, camera = nil,
    floor = nil, playerGhost = nil, threats = {}, markerPool = {}, dragging = false,
    recorded = 0, opened = 0, exportCount = 0, lastExport = "", lastExportPath = "", lastRenderedIndex = 1,
    previous = {damage = 0, deaths = 0, emergency = 0, downed = false,
        freeze = false, shield = false, glued = false, mobility = false, action = "",
        state = "", ragdoll = false, anchored = false, hurtLoop = false, health = nil, tagsKey = "", attributesKey = ""},
}

local function replayTimeText(seconds)
    seconds = math.max(0, seconds or 0)
    local minutes = math.floor(seconds / 60)
    local whole = math.floor(seconds % 60)
    local millis = math.floor((seconds - math.floor(seconds)) * 1000 + .5)
    return string.format("%02d:%02d.%03d", minutes, whole, millis)
end

local function replayPushEvent(now, kind, label)
    local events = State.replay.events
    table.insert(events, {t = now, kind = kind, label = label})
    local cutoff = now - State.replay.seconds - 2
    while events[1] and events[1].t < cutoff do table.remove(events, 1) end
end


local function replaySerializableValue(value, depth)
    depth = depth or 0
    if depth > 7 then return "<depth-limit>" end
    local kind = typeof(value)
    if value == nil or kind == "boolean" or kind == "string" then return value end
    if kind == "number" then
        if value ~= value or value == math.huge or value == -math.huge then return tostring(value) end
        return value
    end
    if kind == "Vector3" then return {type = "Vector3", x = value.X, y = value.Y, z = value.Z} end
    if kind == "Vector2" then return {type = "Vector2", x = value.X, y = value.Y} end
    if kind == "CFrame" then return {type = "CFrame", components = {value:GetComponents()}} end
    if kind == "Color3" then return {type = "Color3", r = value.R, g = value.G, b = value.B} end
    if kind == "EnumItem" then return tostring(value) end
    if kind == "Instance" then
        local ok, path = pcall(function() return value:GetFullName() end)
        return {type = "Instance", class = value.ClassName, path = ok and path or value.Name}
    end
    if kind == "table" then
        local result, count = {}, 0
        local limit = depth <= 1 and 5000 or 512
        for key, child in pairs(value) do
            count += 1
            if count > limit then result.__truncated = true; break end
            local safeKey = type(key) == "number" and key or tostring(key)
            result[safeKey] = replaySerializableValue(child, depth + 1)
        end
        return result
    end
    return tostring(value)
end

local function replaySortedTags(character)
    local tags = character and Tags:GetTags(character) or {}
    table.sort(tags)
    return tags, table.concat(tags, "|")
end

local function replayAttributes(instance)
    local result = {}
    if not instance then return result, "" end
    for name, value in pairs(instance:GetAttributes()) do result[name] = replaySerializableValue(value, 0) end
    local names = {}
    for name in pairs(result) do table.insert(names, name) end
    table.sort(names)
    local signature = {}
    for _, name in ipairs(names) do table.insert(signature, name .. "=" .. HttpService:JSONEncode(result[name])) end
    return result, table.concat(signature, "|")
end

local function replayThreatForensics(root)
    local result = {}
    if not root then return result end
    local playerVelocity = root.AssemblyLinearVelocity
    for index, threat in ipairs(State.safetyThreats or {}) do
        local position = threat.position or (threat.frame and threat.frame.Position)
        if not position then continue end
        local delta = position - root.Position
        local distance = delta.Magnitude
        local relativeVelocity = (threat.velocity or ZERO) - playerVelocity
        local closing = distance > .001 and -relativeVelocity:Dot(delta.Unit) or 0
        local radius = threat.radius or 1.5
        table.insert(result, {
            key = threat.id and ("B" .. tostring(threat.id)) or ((threat.hazard or "H") .. ":" .. tostring(index)),
            kind = threat.hazard or "Ball", position = position, velocity = threat.velocity or ZERO,
            relativePosition = delta, relativeVelocity = relativeVelocity, centerDistance = distance,
            surfaceDistance = distance - radius - 1.6, closingSpeed = closing, radius = radius,
            targeted = threat.target and threat.target.localTarget == true or false,
            uncertainty = threat.model and threat.model.uncertaintyGrowth or threat.uncertainty or 0,
        })
    end
    table.sort(result, function(a, b)
        if math.abs(a.surfaceDistance - b.surfaceDistance) > .001 then return a.surfaceDistance < b.surfaceDistance end
        return a.closingSpeed > b.closingSpeed
    end)
    while #result > 12 do table.remove(result) end
    return result
end

local function replayCaptureIncident(now, kind, label, character, root, humanoid)
    character = character or Player.Character
    root = root or (character and character:FindFirstChild("HumanoidRootPart"))
    humanoid = humanoid or (character and character:FindFirstChildOfClass("Humanoid"))
    if not character or not root or not humanoid then return end
    local tags = replaySortedTags(character)
    local attributes = replayAttributes(character)
    local incident = {
        t = now, kind = kind, label = label,
        player = {cframe = root.CFrame, velocity = root.AssemblyLinearVelocity, angularVelocity = root.AssemblyAngularVelocity,
            health = humanoid.Health, state = humanoid:GetState().Name, floorMaterial = tostring(humanoid.FloorMaterial),
            anchored = root.Anchored, walkSpeed = humanoid.WalkSpeed, jumpPower = humanoid.JumpPower,
            moveDirection = humanoid.MoveDirection, autoRotate = humanoid.AutoRotate, platformStand = humanoid.PlatformStand,
            tags = tags, attributes = attributes, hurtLoop = character:GetAttribute("HurtLoopRunning") == true},
        threats = replayThreatForensics(root),
        planner = {action = State.lastAction, clearance = State.currentClearance or 0,
            timeToImpact = State.currentTimeToImpact or math.huge, futureFreedom = State.futureFreedom,
            futureThreatDensity = State.futureThreatDensity, confidence = State.predictionConfidence,
            predictionError = State.predictionError, uncertainty = State.maxUncertainty,
            planningMs = State.planningMs, emergencyReplans = State.emergencyReplans},
        decisions = {},
    }
    for i = math.max(1, #State.decisions - 5), #State.decisions do table.insert(incident.decisions, State.decisions[i]) end
    table.insert(State.replay.incidents, incident)
    local cutoff = now - State.replay.seconds - 2
    while State.replay.incidents[1] and State.replay.incidents[1].t < cutoff do table.remove(State.replay.incidents, 1) end
end

local function replayRemoteCatalog()
    local result = {}
    for _, instance in ipairs(ReplicatedStorage:GetDescendants()) do
        if instance:IsA("RemoteEvent") or instance:IsA("RemoteFunction") then
            table.insert(result, {class = instance.ClassName, path = instance:GetFullName()})
        end
    end
    table.sort(result, function(a, b) return a.path < b.path end)
    return result
end

local function replayAddExplicitDebugEvent(value)
    if type(value) ~= "table" then return {error = "debug_event requiere una tabla"} end
    local kind = tostring(value.kind or "custom")
    local label = tostring(value.label or value.name or kind)
    local now = os.clock()
    replayPushEvent(now, kind, label)
    local event = State.replay.events[#State.replay.events]
    event.data = replaySerializableValue(value.data or value.payload or {}, 0)
    event.source = "explicit-authorized-instrumentation"
    return event
end

local function replayOrderedFrames()
    local replay = State.replay
    local result = {}
    if replay.count == 0 then return result end
    local first = replay.count < replay.capacity and 1 or (replay.write % replay.capacity) + 1
    for offset = 0, replay.count - 1 do
        local index = ((first + offset - 1) % replay.capacity) + 1
        local frame = replay.frames[index]
        if frame then table.insert(result, frame) end
    end
    return result
end

local function replayThreatSnapshot(root)
    local result = {}
    for index, threat in ipairs(State.safetyThreats) do
        local position = threat.position or (threat.frame and threat.frame.Position)
        if position then
            local distance = (position - root.Position).Magnitude
            table.insert(result, {
                key = threat.id and ("B" .. tostring(threat.id)) or ((threat.hazard or "H") .. ":" .. tostring(index)),
                kind = threat.hazard or "Ball", position = position,
                velocity = threat.velocity or ZERO, radius = threat.radius or 1.5,
                targeted = threat.target and threat.target.localTarget == true or false,
                uncertainty = threat.model and threat.model.uncertaintyGrowth or threat.uncertainty or 0,
                frame = threat.frame, halfLength = threat.halfLength, axis = threat.axis,
                distance = distance,
            })
        end
    end
    table.sort(result, function(a, b) return a.distance < b.distance end)
    while #result > 32 do table.remove(result) end
    return result
end

local function replayRecordFrame(now)
    local replay = State.replay
    if not replay.enabled or not replay.recording or now < replay.nextSample then return end
    replay.nextSample = now + 1 / replay.sampleHz
    local character = Player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local camera = workspace.CurrentCamera
    if not character or not root or not humanoid or not camera then return end

    local downed = Tags:HasTag(character, "Downed")
    local freeze = Tags:HasTag(character, "FreezeTagFrozen")
    local shield = Tags:HasTag(character, "HumanShield")
    local glued = Tags:HasTag(character, "Glued")
    local state = humanoid:GetState().Name
    local ragdoll = state == "Ragdoll" or state == "Physics" or state == "FallingDown"
    local hurtLoop = character:GetAttribute("HurtLoopRunning") == true
    local tags, tagsKey = replaySortedTags(character)
    local attributes, attributesKey = replayAttributes(character)
    local arena = State.baseplate
    local frame = {
        t = now, camera = camera.CFrame, focus = camera.Focus, fov = camera.FieldOfView,
        player = root.CFrame, velocity = root.AssemblyLinearVelocity, angularVelocity = root.AssemblyAngularVelocity,
        health = humanoid.Health, state = state, floorMaterial = tostring(humanoid.FloorMaterial),
        walkSpeed = humanoid.WalkSpeed, jumpPower = humanoid.JumpPower, jumpHeight = humanoid.JumpHeight,
        moveDirection = humanoid.MoveDirection, autoRotate = humanoid.AutoRotate, platformStand = humanoid.PlatformStand,
        anchored = root.Anchored, ragdoll = ragdoll, hurtLoop = hurtLoop, tags = tags, attributes = attributes,
        downed = downed, freeze = freeze, shield = shield, glued = glued, mobility = State.mobility.active,
        threats = replayThreatSnapshot(root), threatCount = State.threats, targeted = State.targeted,
        action = State.lastAction, clearance = State.currentClearance or 0,
        impact = State.currentTimeToImpact or math.huge, futureFreedom = State.futureFreedom,
        density = State.futureThreatDensity, confidence = State.predictionConfidence,
        predictionError = State.predictionError, uncertainty = State.maxUncertainty,
        emergency = State.emergencyReplans, plannerMs = State.planningMs,
        implicitTargeted = State.implicitTargeted, collisionPredictions = State.collisionPredictions,
        bouncePredictions = State.bouncePredictions, hardSafety = State.hardSafety,
        lavaActive = State.lavaActive, lavaStalled = State.lavaStalled, lavaLevel = State.lavaLevel,
        lavaTargetRise = State.lavaTargetRise, lavaTargetArea = State.lavaTargetArea, lavaCandidateCount = State.lavaCandidateCount,
        arena = arena and arena:IsA("BasePart") and {cf = arena.CFrame, size = arena.Size} or nil,
        resources = {
            left = math.max(0, (Cooldowns.Left or 0) - (now - (State.lastUsed.Left or -100))),
            right = math.max(0, (Cooldowns.Right or 0) - (now - (State.lastUsed.Right or -100))),
            forward = math.max(0, (Cooldowns.Forward or 0) - (now - (State.lastUsed.Forward or -100))),
            airUsed = State.airUsed,
        },
    }
    replay.write = replay.write % replay.capacity + 1
    replay.frames[replay.write] = frame
    replay.count = math.min(replay.capacity, replay.count + 1)
    replay.recorded += 1

    local previous = replay.previous
    if downed ~= previous.downed then
        replayPushEvent(now, "mobility", downed and "Downed ON" or "Downed OFF")
        if downed then replayCaptureIncident(now, "downed", "Downed ON", character, root, humanoid) end
    end
    if freeze ~= previous.freeze then replayPushEvent(now, "mobility", freeze and "Freeze ON" or "Freeze OFF") end
    if shield ~= previous.shield then replayPushEvent(now, "mobility", shield and "HumanShield ON" or "HumanShield OFF") end
    if glued ~= previous.glued then replayPushEvent(now, "mobility", glued and "Glued ON" or "Glued OFF") end
    if State.mobility.active ~= previous.mobility then
        replayPushEvent(now, "normalizer", State.mobility.active and "Normalizer ON" or "Normalizer OFF")
    end
    if state ~= previous.state then
        replayPushEvent(now, "state", "Humanoid " .. tostring(previous.state ~= "" and previous.state or "?") .. " -> " .. state)
    end
    if ragdoll ~= previous.ragdoll then
        replayPushEvent(now, "ragdoll", ragdoll and "Ragdoll/Physics ON" or "Ragdoll/Physics OFF")
        if ragdoll then replayCaptureIncident(now, "ragdoll", "Ragdoll/Physics ON", character, root, humanoid) end
    end
    if root.Anchored ~= previous.anchored then replayPushEvent(now, "state", root.Anchored and "Root Anchored ON" or "Root Anchored OFF") end
    if hurtLoop ~= previous.hurtLoop then replayPushEvent(now, "state", hurtLoop and "HurtLoopRunning ON" or "HurtLoopRunning OFF") end
    if tagsKey ~= previous.tagsKey then replayPushEvent(now, "tags", "Tags: " .. (tagsKey ~= "" and tagsKey or "<none>")) end
    if attributesKey ~= previous.attributesKey then
        replayPushEvent(now, "attributes", "Character attributes changed")
        State.replay.events[#State.replay.events].data = attributes
    end
    if State.damageEvents > previous.damage then
        replayPushEvent(now, "damage", "Damage +" .. tostring(State.damageEvents - previous.damage))
        replayCaptureIncident(now, "damage", "Damage", character, root, humanoid)
    end
    if State.deaths > previous.deaths then
        replayPushEvent(now, "death", "Death")
        replayCaptureIncident(now, "death", "Death", character, root, humanoid)
    end
    if State.emergencyReplans > previous.emergency then replayPushEvent(now, "emergency", "Emergency replan") end
    if State.lastAction ~= previous.action and State.lastAction ~= "None" then replayPushEvent(now, "action", State.lastAction) end
    previous.damage, previous.deaths, previous.emergency = State.damageEvents, State.deaths, State.emergencyReplans
    previous.downed, previous.freeze, previous.shield, previous.glued = downed, freeze, shield, glued
    previous.mobility, previous.action = State.mobility.active, State.lastAction
    previous.state, previous.ragdoll, previous.anchored, previous.hurtLoop = state, ragdoll, root.Anchored, hurtLoop
    previous.health, previous.tagsKey, previous.attributesKey = humanoid.Health, tagsKey, attributesKey
end

local function replayMakePart(name, parent)
    local part = Instance.new("Part")
    part.Name = name
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.CastShadow = false
    part.Material = Enum.Material.SmoothPlastic
    part.Parent = parent
    return part
end

local function replayButton(parent, text, width)
    local button = Instance.new("TextButton")
    button.Size = UDim2.fromOffset(width or 110, 42)
    button.BackgroundColor3 = Color3.fromRGB(28, 31, 38)
    button.BorderSizePixel = 0
    button.TextColor3 = Color3.fromRGB(235, 238, 245)
    button.Text = text
    button.TextSize = 20
    button.Font = Enum.Font.GothamMedium
    button.AutoButtonColor = true
    button.Parent = parent
    local corner = Instance.new("UICorner"); corner.CornerRadius = UDim.new(0, 7); corner.Parent = button
    return button
end

local function replayLabel(parent, text, size, position, textSize, align)
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = size
    label.Position = position
    label.Text = text
    label.TextColor3 = Color3.fromRGB(230, 233, 240)
    label.TextSize = textSize or 18
    label.Font = Enum.Font.Gotham
    label.TextXAlignment = align or Enum.TextXAlignment.Left
    label.TextYAlignment = Enum.TextYAlignment.Center
    label.Parent = parent
    return label
end

local function replaySetCursorFromX(x)
    local replay = State.replay
    if not replay.timeline or replay.endTime <= replay.startTime then return end
    local left, width = replay.timeline.AbsolutePosition.X, replay.timeline.AbsoluteSize.X
    if width <= 1 then return end
    local alpha = math.clamp((x - left) / width, 0, 1)
    replay.cursor = replay.startTime + (replay.endTime - replay.startTime) * alpha
    replay.playing = false
end

local closeReplay

local function replayCreateGui()
    local replay = State.replay
    if replay.gui and replay.gui.Parent then return end
    local gui = Instance.new("ScreenGui")
    gui.Name = "BallReactionReplayDebugger"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 1000000
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    gui.Enabled = false
    gui.Parent = PlayerGui

    local root = Instance.new("CanvasGroup")
    root.Name = "ReplayRoot"
    root.Size = UDim2.fromScale(1, 1)
    root.BackgroundColor3 = Color3.fromRGB(7, 8, 12)
    root.BorderSizePixel = 0
    root.GroupTransparency = 1
    root.Parent = gui

    local viewport = Instance.new("ViewportFrame")
    viewport.Name = "ReplayViewport"
    viewport.Size = UDim2.fromScale(1, 1)
    viewport.BackgroundColor3 = Color3.fromRGB(8, 10, 15)
    viewport.BorderSizePixel = 0
    viewport.Ambient = Color3.fromRGB(150, 150, 160)
    viewport.LightColor = Color3.fromRGB(255, 255, 255)
    viewport.LightDirection = Vector3.new(-1, -1, -1)
    viewport.Parent = root

    local world = Instance.new("WorldModel")
    world.Name = "ReplayWorld"
    world.Parent = viewport
    local camera = Instance.new("Camera")
    camera.Name = "ReplayCamera"
    camera.Parent = viewport
    viewport.CurrentCamera = camera

    local floor = replayMakePart("ArenaGhost", world)
    floor.Color = Color3.fromRGB(56, 60, 68)
    floor.Transparency = .18
    floor.Size = Vector3.new(80, 1, 80)

    local playerGhost = replayMakePart("PlayerGhost", world)
    playerGhost.Color = Color3.fromRGB(105, 180, 255)
    playerGhost.Transparency = .18
    playerGhost.Size = Vector3.new(2.2, 5, 2.2)

    local title = replayLabel(root, "BALL REACTION 1.8.8 ALPHA  /  REPLAY DEBUGGER", UDim2.new(1, -40, 0, 52), UDim2.fromOffset(20, 12), 24)
    title.Font = Enum.Font.GothamBold
    title.TextStrokeTransparency = .82
    title.ZIndex = 6

    local exit = replayButton(root, "Exit", 96)
    exit.AnchorPoint = Vector2.new(1, 0)
    exit.Position = UDim2.new(1, -20, 0, 16)
    exit.ZIndex = 10

    local bottom = Instance.new("Frame")
    bottom.AnchorPoint = Vector2.new(0, 1)
    bottom.Position = UDim2.fromScale(0, 1)
    bottom.Size = UDim2.new(1, 0, 0, 224)
    bottom.BackgroundColor3 = Color3.fromRGB(10, 12, 17)
    bottom.BackgroundTransparency = .06
    bottom.BorderSizePixel = 0
    bottom.ZIndex = 5
    bottom.Parent = root

    local play = replayButton(bottom, "Pause", 112)
    play.Position = UDim2.fromOffset(22, 18); play.ZIndex = 6
    local speed = replayButton(bottom, "1x", 82)
    speed.Position = UDim2.fromOffset(146, 18); speed.ZIndex = 6
    local time = replayLabel(bottom, "00:00.000 / 00:00.000", UDim2.fromOffset(310, 42), UDim2.fromOffset(244, 18), 20)
    time.Font = Enum.Font.GothamMedium
    time.TextStrokeTransparency = .86
    time.ZIndex = 6

    local timeline = Instance.new("Frame")
    timeline.Name = "Timeline"
    timeline.Active = true
    timeline.Position = UDim2.new(0, 22, 0, 72)
    timeline.Size = UDim2.new(1, -44, 0, 22)
    timeline.BackgroundColor3 = Color3.fromRGB(34, 38, 48)
    timeline.BorderSizePixel = 0
    timeline.ZIndex = 6
    timeline.Parent = bottom
    local tc = Instance.new("UICorner"); tc.CornerRadius = UDim.new(1, 0); tc.Parent = timeline
    local fill = Instance.new("Frame")
    fill.Size = UDim2.fromScale(0, 1)
    fill.BackgroundColor3 = Color3.fromRGB(100, 165, 255)
    fill.BorderSizePixel = 0
    fill.ZIndex = 7
    fill.Parent = timeline
    local fc = Instance.new("UICorner"); fc.CornerRadius = UDim.new(1, 0); fc.Parent = fill
    local knob = Instance.new("Frame")
    knob.AnchorPoint = Vector2.new(.5, .5)
    knob.Position = UDim2.fromScale(0, .5)
    knob.Size = UDim2.fromOffset(14, 34)
    knob.BackgroundColor3 = Color3.fromRGB(240, 244, 255)
    knob.BorderSizePixel = 0
    knob.ZIndex = 9
    knob.Parent = timeline
    local kc = Instance.new("UICorner"); kc.CornerRadius = UDim.new(1, 0); kc.Parent = knob

    local statsLabel = replayLabel(bottom, "No data", UDim2.new(.64, -22, 0, 108), UDim2.fromOffset(22, 106), 18)
    statsLabel.Font = Enum.Font.GothamMedium
    statsLabel.TextStrokeTransparency = .88
    statsLabel.TextYAlignment = Enum.TextYAlignment.Top
    statsLabel.TextWrapped = true
    statsLabel.ZIndex = 6
    local eventLabel = replayLabel(bottom, "Event: -", UDim2.new(.36, -28, 0, 108), UDim2.new(.64, 6, 0, 106), 18)
    eventLabel.Font = Enum.Font.GothamMedium
    eventLabel.TextStrokeTransparency = .88
    eventLabel.TextYAlignment = Enum.TextYAlignment.Top
    eventLabel.TextWrapped = true
    eventLabel.ZIndex = 6

    exit.MouseButton1Click:Connect(function()
        if closeReplay then closeReplay() end
    end)
    play.MouseButton1Click:Connect(function() replay.playing = not replay.playing end)
    speed.MouseButton1Click:Connect(function()
        local values = {.25, .5, 1, 2}
        local nextIndex = 1
        for i, value in ipairs(values) do if math.abs(value - replay.speed) < .01 then nextIndex = i % #values + 1; break end end
        replay.speed = values[nextIndex]
    end)
    timeline.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            replay.dragging = true; replaySetCursorFromX(input.Position.X)
        end
    end)
    connect(Input.InputChanged, function(input)
        if replay.open and replay.dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            replaySetCursorFromX(input.Position.X)
        end
    end)
    connect(Input.InputEnded, function(input)
        if replay.dragging and (input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch) then replay.dragging = false end
    end)

    replay.gui, replay.root, replay.viewport, replay.world, replay.camera = gui, root, viewport, world, camera
    replay.floor, replay.playerGhost = floor, playerGhost
    replay.timeline, replay.timelineFill, replay.timelineKnob = timeline, fill, knob
    replay.playButton, replay.speedButton, replay.timeLabel = play, speed, time
    replay.statsLabel, replay.eventLabel = statsLabel, eventLabel
end

local function replayEnsureThreat(index)
    local replay = State.replay
    local object = replay.threats[index]
    if object and object.Parent then return object end
    object = replayMakePart("ThreatGhost" .. tostring(index), replay.world)
    object.Transparency = .06
    object.Shape = Enum.PartType.Ball
    replay.threats[index] = object
    return object
end

local function replayFindPair(time)
    local frames = State.replay.frozenFrames
    if not frames or #frames == 0 then return nil end
    if time <= frames[1].t then return frames[1], frames[1], 0, 1 end
    if time >= frames[#frames].t then return frames[#frames], frames[#frames], 0, #frames end
    local low, high = 1, #frames - 1
    while low <= high do
        local mid = math.floor((low + high) * .5)
        if frames[mid].t <= time and frames[mid + 1].t >= time then
            local span = math.max(.0001, frames[mid + 1].t - frames[mid].t)
            return frames[mid], frames[mid + 1], math.clamp((time - frames[mid].t) / span, 0, 1), mid
        elseif frames[mid].t < time then low = mid + 1 else high = mid - 1 end
    end
    return frames[1], frames[1], 0, 1
end

local function replayNearestEvent(time)
    local events, best, bestAge = State.replay.frozenEvents or {}, nil, math.huge
    for _, event in ipairs(events) do
        local age = math.abs(event.t - time)
        if age < bestAge then best, bestAge = event, age end
    end
    return bestAge <= 1.25 and best or nil
end

local function replayRender(time)
    local replay = State.replay
    local a, b, alpha = replayFindPair(time)
    if not a then return end
    replay.camera.CFrame = a.camera:Lerp(b.camera, alpha)
    replay.camera.FieldOfView = a.fov + (b.fov - a.fov) * alpha
    replay.playerGhost.CFrame = a.player:Lerp(b.player, alpha)
    replay.playerGhost.Color = a.downed and Color3.fromRGB(255, 175, 90) or Color3.fromRGB(105, 180, 255)
    replay.playerGhost.Transparency = a.freeze and .55 or .18
    local arena = a.arena or b.arena
    if arena then
        replay.floor.CFrame, replay.floor.Size, replay.floor.Transparency = arena.cf, arena.size, .18
    else
        replay.floor.CFrame = CFrame.new(a.player.Position - Vector3.new(0, 3, 0))
        replay.floor.Size = Vector3.new(100, 1, 100)
        replay.floor.Transparency = .45
    end

    local nextThreats = {}
    for _, threat in ipairs(b.threats or {}) do nextThreats[threat.key] = threat end
    local visible = 0
    for index, threat in ipairs(a.threats or {}) do
        visible += 1
        local part = replayEnsureThreat(index)
        local target = nextThreats[threat.key]
        local position = target and threat.position:Lerp(target.position, alpha) or threat.position
        local kind = threat.kind or "Ball"
        if kind == "Laser" and threat.frame then
            part.Shape = Enum.PartType.Block
            part.CFrame = threat.frame
            part.Size = threat.axis == "X" and Vector3.new((threat.halfLength or 20) * 2, 1, 1)
                or Vector3.new(1, 1, (threat.halfLength or 20) * 2)
            part.Color = Color3.fromRGB(255, 85, 105)
        else
            part.Shape = Enum.PartType.Ball
            local size = math.max(.5, (threat.radius or 1.5) * 2)
            part.Size = Vector3.new(size, size, size)
            part.CFrame = CFrame.new(position)
            part.Color = threat.targeted and Color3.fromRGB(255, 90, 90)
                or kind == "Lava" and Color3.fromRGB(255, 135, 55)
                or kind == "Spawn" and Color3.fromRGB(190, 130, 255)
                or Color3.fromRGB(235, 235, 240)
        end
        part.Transparency = threat.targeted and 0 or .16
    end
    for index = visible + 1, #replay.threats do replay.threats[index].Transparency = 1 end

    local span = math.max(.001, replay.endTime - replay.startTime)
    local progress = math.clamp((time - replay.startTime) / span, 0, 1)
    replay.timelineFill.Size = UDim2.fromScale(progress, 1)
    replay.timelineKnob.Position = UDim2.fromScale(progress, .5)
    replay.playButton.Text = replay.playing and "Pause" or "Play"
    replay.speedButton.Text = tostring(replay.speed) .. "x"
    replay.timeLabel.Text = replayTimeText(time - replay.startTime) .. " / " .. replayTimeText(span)
    local impactText = a.impact == math.huge and "∞" or string.format("%.3fs", a.impact)
    replay.statsLabel.Text = string.format(
        "Threats %d | Targets %d | HP %.0f | %s\nClearance %.2f | Impact %s | Freedom %.2f | Density %.2f\nPlan %s | Conf %.2f | Error %.2f | Planner %.2fms",
        a.threatCount or 0, a.targeted or 0, a.health or 0, a.state or "?", a.clearance or 0, impactText,
        a.futureFreedom or 0, a.density or 0, a.action or "-", a.confidence or 0, a.predictionError or 0, a.plannerMs or 0)
    local event = replayNearestEvent(time)
    replay.eventLabel.Text = event and ("Event: " .. event.label .. "\n" .. replayTimeText(event.t - replay.startTime))
        or string.format("States: Downed=%s  Freeze=%s  Shield=%s  Glued=%s\nNormalizer=%s  AirUsed=%s",
            tostring(a.downed), tostring(a.freeze), tostring(a.shield), tostring(a.glued), tostring(a.mobility), tostring(a.resources and a.resources.airUsed))
end

local function replayRefreshMarkers()
    local replay = State.replay
    if not replay.timeline then return end
    for _, marker in ipairs(replay.markerPool) do marker:Destroy() end
    table.clear(replay.markerPool)
    local span = replay.endTime - replay.startTime
    if span <= 0 then return end
    local shown = 0
    for _, event in ipairs(replay.frozenEvents or {}) do
        if event.t >= replay.startTime and event.t <= replay.endTime then
            shown += 1
            if shown > 120 then break end
            local marker = Instance.new("Frame")
            marker.AnchorPoint = Vector2.new(.5, .5)
            marker.Position = UDim2.fromScale((event.t - replay.startTime) / span, .5)
            marker.Size = UDim2.fromOffset(event.kind == "death" and 4 or 2, event.kind == "death" and 18 or 12)
            marker.BorderSizePixel = 0
            marker.BackgroundColor3 = event.kind == "death" and Color3.fromRGB(255, 75, 75)
                or event.kind == "damage" and Color3.fromRGB(255, 155, 70)
                or event.kind == "mobility" and Color3.fromRGB(255, 220, 90)
                or Color3.fromRGB(185, 195, 220)
            marker.ZIndex = 8
            marker.Parent = replay.timeline
            table.insert(replay.markerPool, marker)
        end
    end
end

local function openReplay(secondsBack)
    local replay = State.replay
    local frames = replayOrderedFrames()
    if #frames < 2 then
        if DebugStatusText then DebugStatusText:SetDesc("Replay: not enough samples.") end
        return false
    end
    replayCreateGui()
    replay.frozenFrames = frames
    replay.frozenEvents = table.clone(replay.events)
    replay.frozenIncidents = table.clone(replay.incidents)
    replay.endTime = frames[#frames].t
    replay.startTime = math.max(frames[1].t, replay.endTime - math.clamp(tonumber(secondsBack) or replay.seconds, 1, replay.seconds))
    replay.cursor = replay.startTime
    replay.open, replay.playing = true, true
    replay.opened += 1
    replay.lastRenderedIndex = 1
    replayRefreshMarkers()
    replay.gui.Enabled = true
    replay.root.GroupTransparency = 1
    TweenService:Create(replay.root, TweenInfo.new(.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {GroupTransparency = 0}):Play()
    replayRender(replay.cursor)
    return true
end

closeReplay = function()
    local replay = State.replay
    if not replay.open then return end
    replay.open, replay.playing = false, false
    replay.dragging = false
    if replay.root then
        local tween = TweenService:Create(replay.root, TweenInfo.new(.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {GroupTransparency = 1})
        tween:Play()
        task.delay(.2, function() if replay.gui and replay.gui.Parent and not replay.open then replay.gui.Enabled = false end end)
    end
end

local function clearReplay()
    local replay = State.replay
    replay.frames, replay.events, replay.incidents = {}, {}, {}
    replay.frozenFrames, replay.frozenEvents, replay.frozenIncidents = nil, nil, nil
    replay.write, replay.count, replay.recorded = 0, 0, 0
    replay.nextSample = 0
    replay.startTime, replay.endTime, replay.cursor = 0, 0, 0
    replay.previous = {damage = State.damageEvents, deaths = State.deaths, emergency = State.emergencyReplans,
        downed = State.downed, freeze = false, shield = false, glued = false,
        mobility = State.mobility.active, action = State.lastAction, state = "", ragdoll = false, anchored = false,
        hurtLoop = false, health = nil, tagsKey = "", attributesKey = ""}
end

local function replaySetRecording(enabled)
    State.replay.recording = enabled == true
    if State.replay.recording then State.replay.nextSample = 0 end
    return State.replay.recording
end

local function replayExportDebugTrace()
    local replay = State.replay
    local frames = replay.frozenFrames or replayOrderedFrames()
    local events = replay.frozenEvents or replay.events
    local incidents = replay.frozenIncidents or replay.incidents
    if #frames == 0 then return nil, "No samples to export" end
    local first, last = frames[1], frames[#frames]
    local payload = {
        schema = "BallReactionReplayDebug/v1",
        version = "1.8.9 betasync5378",
        generatedAtUnix = os.time(),
        durationSeconds = last.t - first.t,
        sampleHz = replay.sampleHz,
        frameCount = #frames,
        eventCount = #events,
        incidentCount = #incidents,
        remotesPresent = replayRemoteCatalog(),
        frames = replaySerializableValue(frames, 0),
        events = replaySerializableValue(events, 0),
        incidents = replaySerializableValue(incidents, 0),
    }
    local ok, encoded = pcall(function() return HttpService:JSONEncode(payload) end)
    if not ok then return nil, tostring(encoded) end
    replay.lastExport, replay.exportCount = encoded, replay.exportCount + 1
    local filename = "BallReaction_1.8.9_betasync5378_debug_" .. tostring(os.time()) .. ".json"
    replay.lastExportPath = filename
    local wrote = false
    if type(writefile) == "function" then wrote = pcall(writefile, filename, encoded) end
    if not wrote and type(setclipboard) == "function" then pcall(setclipboard, encoded) end
    return encoded, wrote and filename or nil
end

local function replayTick(now, dt)
    local replay = State.replay
    replayRecordFrame(now)
    if not replay.open or not replay.frozenFrames then return end
    if replay.playing and not replay.dragging then
        replay.cursor += dt * replay.speed
        if replay.cursor >= replay.endTime then replay.cursor = replay.endTime; replay.playing = false end
    end
    replayRender(replay.cursor)
end

local function replaySummaryText()
    local replay = State.replay
    local frames = replayOrderedFrames()
    local span = #frames >= 2 and frames[#frames].t - frames[1].t or 0
    local last = frames[#frames]
    local mode = replay.recording and "RECORDING" or "FROZEN"
    if replay.open then mode ..= " + REPLAY" end
    return string.format("Recording: %s | Buffer %s / 05:00 | Samples %d\nEvents %d | Incidents %d | Exports %d | Threats %d | Targets %d\nLast plan: %s",
        mode, replayTimeText(span), replay.count, #replay.events, #replay.incidents, replay.exportCount,
        last and last.threatCount or 0, last and last.targeted or 0, last and last.action or "-")
end

local function unitFlat(v, fallback)
    local flat = Vector3.new(v.X, 0, v.Z)
    return flat.Magnitude > 0.001 and flat.Unit or fallback
end

local function cap(v, maximum)
    return v.Magnitude > maximum and v.Unit * maximum or v
end

local function restoreFacing()
    local facing = State.facing
    State.facing = nil
    if facing and facing.humanoid.Parent then facing.humanoid.AutoRotate = facing.autoRotate end
end

local function dashLook(direction, name)
    if name == "Forward" then return direction end
    local look = Vector3.new(direction.Z, 0, -direction.X)
    return name == "Left" and -look or look
end

local function faceDash(action, now)
    if not action.orient then return true end
    local character = Player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid or root.Anchored or humanoid.Health <= 0 then return false end
    if State.facing and State.facing.humanoid ~= humanoid then restoreFacing() end
    local autoRotate = State.facing and State.facing.autoRotate or humanoid.AutoRotate
    if State.facing then autoRotate = State.facing.autoRotate end
    local look = dashLook(action.direction, action.name)
    State.facing = {root = root, humanoid = humanoid, autoRotate = autoRotate,
        look = look, finish = now + .14}
    humanoid.AutoRotate = false
    root.CFrame = CFrame.lookAt(root.Position, root.Position + look)
    State.previousFacing = look
    return true
end

local function releaseKeys()
    State.inputEpoch += 1
    for key in pairs(State.held) do pcall(keyrelease, key) end
    table.clear(State.held)
    State.steering = nil
    State.activeMotion, State.followupAt = nil, nil
    State.safetyEligible, State.replanRequested, State.criticalLatch = false, false, false
    State.pendingDash = nil
    restoreFacing()
end

local function cleanup()
    if not State.alive then return end
    State.alive = false
    RunService:UnbindFromRenderStep("BallReactionWorldSteering")
    Config.auto = false
    releaseKeys()
    for _, connection in ipairs(State.connections) do connection:Disconnect() end
    table.clear(State.connections)
    table.clear(State.balls)
    table.clear(State.hazards)
    table.clear(State.lasers)
    table.clear(State.lavaBodies)
    if State.deathConnection then State.deathConnection:Disconnect(); State.deathConnection = nil end
    if State.mobility.animationConnection then State.mobility.animationConnection:Disconnect(); State.mobility.animationConnection = nil end
    stopNormalizedLocomotionAnimation()
    State.mobility.active, State.mobility.impulse = false, nil
    State.replay.recording, State.replay.open, State.replay.playing = false, false, false
    if State.replay.gui then State.replay.gui:Destroy(); State.replay.gui = nil end
    if Fluent and not Fluent.Unloaded then pcall(function() Fluent:Destroy() end) end
    if Controller.Parent then Controller:Destroy() end
end

-- Detection
local function isBall(part)
    if not part:IsA("BasePart") or not part:IsDescendantOf(workspace) then return false end
    local ancestor = part.Parent
    while ancestor and ancestor ~= workspace do
        if ancestor:IsA("Model") and ancestor:FindFirstChildOfClass("Humanoid") then return false end
        ancestor = ancestor.Parent
    end
    local container = part.Parent
    if container and string.lower(container.Name) == "balls" then return true end
    return part:FindFirstChildOfClass("AlignPosition") ~= nil
        and (part:FindFirstChildOfClass("Trail") ~= nil or part:FindFirstChildOfClass("Highlight") ~= nil)
end

local function consider(instance)
    local part = instance:IsA("BasePart") and instance or instance.Parent
    if part and isBall(part) and not State.balls[part] then
        State.nextBallId += 1
        State.balls[part] = {position = part.Position, velocity = part.AssemblyLinearVelocity, time = os.clock(),
            acceleration = ZERO, id = State.nextBallId}
        State.observations += 1
    end
    if part and part:IsA("BasePart") and not State.balls[part] then
        local cursor, name, inCharacter = part, "", false
        for _ = 1, 5 do
            if not cursor or cursor == workspace then break end
            name ..= " " .. string.lower(cursor.Name)
            if cursor:IsA("Model") and cursor:FindFirstChildOfClass("Humanoid") then inCharacter = true end
            cursor = cursor.Parent
        end
        local glue = string.find(name, "glue", 1, true)
        local banana = string.find(name, "banana", 1, true)
        local namedLaser = string.find(name, "laser", 1, true) or string.find(name, "lazer", 1, true)
        local lavaName = string.find(name, "lava", 1, true) or string.find(name, "magma", 1, true)
        if not inCharacter and not part:FindFirstAncestorOfClass("Tool")
            and not part:FindFirstAncestorOfClass("Accessory")
            and (lavaName or Tags:HasTag(part, "Lava") or part.Material.Name == "CrackedLava")
            and not State.lavaBodies[part] then
            State.lavaBodies[part] = {top = part.Position.Y + part.Size.Y * .5, time = os.clock(), rise = 0}
        end
        local elongated = math.max(part.Size.X, part.Size.Z) > 16
            and math.min(part.Size.X, part.Size.Z) < 5 and part.Size.Y < 6
        if not inCharacter and not part:FindFirstAncestorOfClass("Accessory")
            and not part:FindFirstAncestorOfClass("Tool") and (namedLaser or (elongated and part.Material == Enum.Material.Neon))
            and not State.lasers[part] then
            State.lasers[part] = {frame = part.CFrame, time = os.clock(), omega = ZERO,
                velocity = ZERO, named = namedLaser ~= nil}
        end
        if (glue or banana) and not inCharacter and not part:FindFirstAncestorOfClass("Accessory")
            and not part:FindFirstAncestorOfClass("Tool") then
            State.hazards[part] = {kind = glue and "Glue" or "Banana"}
        end
    end
    if instance:IsA("ParticleEmitter") or instance:IsA("Fire") then
        local cursor, names = instance, ""
        for _ = 1, 6 do
            if not cursor or cursor == workspace then break end
            names ..= " " .. string.lower(cursor.Name)
            cursor = cursor.Parent
        end
        if string.find(names, "flame", 1, true) or string.find(names, "fire", 1, true) then
            State.hazards[instance] = {kind = "Fire"}
        end
    end
end

local function rescan()
    for _, instance in ipairs(workspace:GetDescendants()) do
        if instance:IsA("BasePart") or instance:IsA("ParticleEmitter") or instance:IsA("Fire") then consider(instance) end
    end
end

local scanQueue, scanIndex = nil, 1
local function scanSlice()
    if not scanQueue then return end
    local last = math.min(#scanQueue, scanIndex + 95)
    for index = scanIndex, last do
        local instance = scanQueue[index]
        if instance:IsDescendantOf(workspace) and (instance:IsA("BasePart")
            or instance:IsA("ParticleEmitter") or instance:IsA("Fire")) then consider(instance) end
    end
    scanIndex = last + 1
    if scanIndex > #scanQueue then scanQueue = nil end
end

-- Prediction
local function segmentDistance(a, b)
    local delta = b - a
    local t = delta:Dot(delta) > 1e-8 and math.clamp(-a:Dot(delta) / delta:Dot(delta), 0, 1) or 0
    return (a + delta * t).Magnitude
end

local function advanceThreat(ball, position, velocity, goal, t, dt)
    local acceleration = ball.acceleration or ZERO
    local model = ball.model or ball
    if goal and t >= math.max(0, (model.responseDelay or 0) - (ball.targetChangeAge or 100)) then
        local delta = goal - position
        if delta.Magnitude > .01 then
            local desired = delta.Unit * math.max(velocity.Magnitude, model.maxSpeed or ball.maxSpeed or 0)
            acceleration = cap((desired - velocity) * (model.homingStrength or 4), model.maxAcceleration or 160)
            if model.samples and model.samples >= 8 and velocity.Magnitude > 10 and (ball.targetChangeAge or 100) > .4 then
                local along = velocity.Unit * acceleration:Dot(velocity.Unit)
                acceleration = along + cap(acceleration - along, velocity.Magnitude * math.max(.4, (model.turnRate or 2) * 1.5))
            end
        end
    end
    local nextVelocity = cap(velocity + acceleration * dt, math.max(velocity.Magnitude, model.maxSpeed or 0, 300))
    return position + nextVelocity * dt, nextVelocity
end

local function threatWorldParams(root)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local exclude = {}
    if Player.Character then table.insert(exclude, Player.Character) end
    for part in pairs(State.balls) do table.insert(exclude, part) end
    for object in pairs(State.hazards) do table.insert(exclude, object) end
    for part in pairs(State.lasers) do table.insert(exclude, part) end
    for _, player in ipairs(Players:GetPlayers()) do
        if player.Character then table.insert(exclude, player.Character) end
    end
    params.FilterDescendantsInstances = exclude
    params.RespectCanCollide = true
    params.CollisionGroup = root and root.CollisionGroup or "Default"
    return params
end

local function reflectThreatVelocity(velocity, normal, restitution)
    local incoming = velocity:Dot(normal)
    if incoming >= 0 then return velocity end
    local tangent = velocity - normal * incoming
    return tangent * .96 - normal * incoming * restitution
end

local function advanceThreatWorld(ball, position, velocity, goal, t, dt, rayParams, restitution)
    local nextPosition, nextVelocity = advanceThreat(ball, position, velocity, goal, t, dt)
    if not Config.collisionPrediction or not rayParams or ball.hazard then
        return nextPosition, nextVelocity, false
    end
    local delta = nextPosition - position
    if delta.Magnitude < .02 then return nextPosition, nextVelocity, false end
    local ok, hit = pcall(function()
        return workspace:Spherecast(position, math.max(.15, (ball.radius or 1.25) * .92), delta, rayParams)
    end)
    if not ok or not hit then return nextPosition, nextVelocity, false end
    local normal = hit.Normal
    if nextVelocity:Dot(normal) >= 0 then return nextPosition, nextVelocity, false end
    local reflected = reflectThreatVelocity(nextVelocity, normal, restitution or .6)
    local fraction = math.clamp((hit.Distance or 0) / math.max(.001, delta.Magnitude), 0, 1)
    local contact = position + delta.Unit * math.max(0, (hit.Distance or 0) - .025) + normal * .04
    local remaining = dt * (1 - fraction)
    return contact + reflected * remaining, reflected, true
end

local function aggressiveThreat(ball)
    local copy = table.clone(ball)
    local source = ball.model or ball
    local model = table.clone(source)
    model.homingStrength = math.max(5.5, (source.homingStrength or 4) * 1.35)
    model.maxAcceleration = math.max(190, (source.maxAcceleration or 160) * 1.25)
    model.turnRate = math.max(2.5, (source.turnRate or 2) * 1.2)
    model.responseDelay = math.max(.012, (source.responseDelay or .035) * .75)
    copy.model = model
    return copy
end

local function implicitThreatMetrics(position, velocity, rootPosition, rootVelocity, radius)
    local relative = position - rootPosition
    local relativeVelocity = velocity - rootVelocity
    local distance = relative.Magnitude
    if distance < .001 then return math.huge, 0, 0 end
    local closing = -relative.Unit:Dot(relativeVelocity)
    local speed2 = relativeVelocity:Dot(relativeVelocity)
    local closestTime = speed2 > 1e-6 and math.clamp(-relative:Dot(relativeVelocity) / speed2, 0, .75) or .75
    local closest = (relative + relativeVelocity * closestTime).Magnitude - (radius or 1.25)
    return closing, closestTime, closest
end

local function isImplicitThreat(position, velocity, root, radius)
    if not Config.implicitTargeting or not root then return false end
    local distance = (position - root.Position).Magnitude
    if distance > 95 or velocity.Magnitude < 12 then return false end
    local closing, closestTime, closest = implicitThreatMetrics(position, velocity, root.Position, root.AssemblyLinearVelocity, radius)
    return (closing > 28 and closestTime < .65 and closest < math.max(9, (radius or 1.25) + 6))
        or (distance < 22 and closing > 18 and closestTime < .45)
end

local function simulateThreatPath(ball, steps, dt, goalProvider, rayParams, restitution)
    local path = {ball.position}
    local position, velocity = ball.position, ball.velocity
    local bounced = false
    for index = 1, steps do
        local t = index * dt
        local goal = goalProvider and goalProvider(t, index) or nil
        local hit
        position, velocity, hit = advanceThreatWorld(ball, position, velocity, goal, t, dt, rayParams, restitution)
        bounced = bounced or hit
        path[index + 1] = position
    end
    return path, bounced
end

local function learnThreat(data, position, velocity, target, elapsed, now, targetChanged, advertisedSpeed)
    data.samples = data.samples or 0
    data.homingStrength = data.homingStrength or 4
    data.maxAcceleration = data.maxAcceleration or 160
    data.turnRate = data.turnRate or 2
    data.responseDelay = data.responseDelay or .035
    local measuredSpeed = velocity.Magnitude < 350 and velocity.Magnitude or (data.maxSpeed or advertisedSpeed or 60)
    local speedEstimate = math.clamp(math.max(measuredSpeed, advertisedSpeed or 0), 1, 300)
    data.maxSpeed = (data.maxSpeed or speedEstimate) * .85 + speedEstimate * .15
    if targetChanged then
        local interval = now - (data.targetChanged or now - 2)
        data.targetChangeFrequency = (data.targetChangeFrequency or 0) * .8 + math.min(4, 1 / math.max(.1, interval)) * .2
        data.targetChanged, data.awaitingResponse = now, true
    end
    if elapsed >= .012 and elapsed <= .12 and (position - data.position).Magnitude < 65
        and (velocity - data.velocity).Magnitude / elapsed < 900 then
        local alpha = 1 - math.exp(-elapsed / .55)
        local rawAcceleration = (velocity - data.velocity) / elapsed
        local oldAcceleration = data.acceleration or ZERO
        data.acceleration = oldAcceleration:Lerp(cap(rawAcceleration, 320), alpha)
        data.accelerationVariance = (data.accelerationVariance or 0) * (1 - alpha)
            + math.min(200, (rawAcceleration - oldAcceleration).Magnitude) * alpha
        if data.previousSnapshot then
            local old = data.previousSnapshot
            local goal = old.target and (old.target.position + old.target.velocity * elapsed)
            local predicted = advanceThreat(old, data.position, data.velocity, goal, elapsed, elapsed)
            local residual = math.min(8, (predicted - position).Magnitude)
            data.predictionError = (data.predictionError or 0) * (1 - alpha) + residual * alpha
        end
        if target and not targetChanged and now - (data.targetChanged or -100) > data.responseDelay then
            local delta = target.position - data.position
            if delta.Magnitude > 1 then
                local errorVelocity = delta.Unit * data.maxSpeed - data.velocity
                if errorVelocity.Magnitude > 8 and rawAcceleration:Dot(errorVelocity) > 0 then
                    local strength = math.clamp(rawAcceleration:Dot(errorVelocity) / errorVelocity:Dot(errorVelocity), .7, 10)
                    if rawAcceleration.Magnitude < data.maxAcceleration * .85 then
                        data.homingStrength += (strength - data.homingStrength) * alpha
                    end
                    data.maxAcceleration += (math.clamp(rawAcceleration.Magnitude * 1.25, 60, 320) - data.maxAcceleration) * alpha
                    if data.awaitingResponse then
                        local age = now - data.targetChanged
                        if age < .3 then data.responseDelay = data.responseDelay * .8 + math.clamp(age, .015, .2) * .2 end
                        data.awaitingResponse = false
                    end
                end
            end
            if velocity.Magnitude > 10 and data.velocity.Magnitude > 10 then
                local turn = math.acos(math.clamp(velocity.Unit:Dot(data.velocity.Unit), -1, 1)) / elapsed
                data.turnRate = math.max(data.turnRate * (1 - alpha * .15),
                    data.turnRate * (1 - alpha) + math.clamp(turn, .4, 8) * alpha)
            end
        end
        data.samples += 1
    end
    local recent = math.max(0, 1 - (now - (data.targetChanged or -100)) / .45)
    data.predictionConfidence = math.clamp(.94 - recent * .3 - (data.predictionError or 0) * .07
        - (data.accelerationVariance or 0) * .0015 - (data.targetChangeFrequency or 0) * .035, .25, .98)
    data.uncertaintyGrowth = .12 + (1 - data.predictionConfidence) * 1.8
        + (data.predictionError or 0) * .35
end

local function uncertaintyAt(ball, t, divergence)
    if ball.hazard then return ball.uncertainty or 0 end
    local model = ball.model or ball
    local growth = model.uncertaintyGrowth or 0
    return math.min(6, (ball.uncertainty or 0) + growth * t
        + (model.accelerationVariance or 0) * .008 * t * t
        + math.min(1.5, (divergence or 0) * .025) * math.min(1, t)
        + (ball.target and (model.turnRate or 0) * .07 * t * t or 0))
end

local function simulateBalls(balls, rootPosition, horizon, worldParams, rootVelocity)
    local steps = math.max(6, math.ceil(horizon / 0.045))
    local dt = horizon / steps
    rootVelocity = rootVelocity or ZERO
    State.collisionPredictions, State.bouncePredictions = 0, 0
    local collisionUsed = 0
    for _, ball in ipairs(balls) do
        if ball.hazard == "Laser" or ball.hazard == "Lava" then continue end
        ball.linear = {ball.position}
        ball.curve = {ball.position}
        ball.ensemble = {}
        local position, velocity = ball.position, ball.velocity
        local identical = true
        for index = 1, steps do
            local t = index * dt
            local goal = ball.target and (ball.target.position + ball.target.velocity * t)
            position, velocity = advanceThreat(ball, position, velocity, goal, t, dt)
            ball.curve[index + 1] = position
            ball.linear[index + 1] = ball.position + ball.velocity * t
            if (ball.linear[index + 1] - position).Magnitude > .01 then identical = false end
        end
        table.insert(ball.ensemble, {kind = "linear", path = ball.linear})
        if not identical then table.insert(ball.ensemble, {kind = "curve", path = ball.curve}) end

        local urgentCollisionModel = ball.implicitTarget or (ball.target and ball.target.localTarget)
        local collisionAware = Config.collisionPrediction and worldParams and not ball.hazard
            and (ball.distance or (ball.position - rootPosition).Magnitude) < 105 and ball.velocity.Magnitude > 8
            and (urgentCollisionModel or collisionUsed < 8)
        ball.worldParams, ball.collisionAware = collisionAware and worldParams or nil, collisionAware
        if collisionAware then
            collisionUsed += 1
            State.collisionPredictions += 1
            local function officialGoal(t)
                return ball.target and (ball.target.position + ball.target.velocity * t) or nil
            end
            local middle, bounced = simulateThreatPath(ball, steps, dt, officialGoal, worldParams, BOUNCE_RESTITUTIONS[2])
            if bounced then
                State.bouncePredictions += 1
                table.insert(ball.ensemble, {kind = "bounce60", path = middle, bounce = true})
                local low = simulateThreatPath(ball, steps, dt, officialGoal, worldParams, BOUNCE_RESTITUTIONS[1])
                local high = simulateThreatPath(ball, steps, dt, officialGoal, worldParams, BOUNCE_RESTITUTIONS[3])
                table.insert(ball.ensemble, {kind = "bounce35", path = low, bounce = true})
                table.insert(ball.ensemble, {kind = "bounce85", path = high, bounce = true})
                ball.bouncePossible = true
            else
                ball.bouncePossible = false
            end
        end

        if ball.implicitTarget then
            local aggressive = aggressiveThreat(ball)
            local function localGoal(t) return rootPosition + rootVelocity * t end
            local path = simulateThreatPath(aggressive, steps, dt, localGoal, worldParams, .6)
            table.insert(ball.ensemble, {kind = "implicitAggressive", path = path, aggressive = true, bounce = ball.bouncePossible})
        end
        ball.identicalPaths = #ball.ensemble == 1
        ball.predictionSteps, ball.predictionDt = steps, dt
    end
    return steps, dt
end

local function integrateDrive(initial, target, duration, acceleration)
    local difference = target - initial
    local settle = math.max(.025, difference.Magnitude / math.max(1, acceleration))
    local transient = math.min(duration, settle)
    local offset = initial * transient + difference * (.5 * transient * transient / settle)
    offset += target * math.max(0, duration - settle)
    return offset, initial:Lerp(target, math.min(1, duration / settle))
end

local function horizontalOffset(action, t, initialVelocity, delay, firstOnly)
    if action.follow and not firstOnly and t > action.followAt then
        local at = action.followAt
        local offset = horizontalOffset(action, at, initialVelocity, delay, true)
        local previous = horizontalOffset(action, math.max(0, at - .002), initialVelocity, delay, true)
        local nextVelocity = (offset - previous) / math.min(.002, at)
        return offset + horizontalOffset(action.follow, t - at, nextVelocity, .015)
    end
    delay = action.latency or delay
    if action.kind == "dash" and action.jump then delay += 0.06 end
    delay += action.moveDelay or 0
    local before = math.min(t, delay)
    if action.kind == "stay" then
        return initialVelocity * (action.coast and 0.22 * (1 - math.exp(-t / 0.22)) or t)
    end
    local after = math.max(0, t - delay)
    if action.kind == "drift" then
        local untilTail = math.max(0, action.tailAt or math.huge)
        local coast = math.min(t, untilTail)
        local offset, finalVelocity = integrateDrive(initialVelocity, ZERO, coast, action.braking or 620)
        if t > untilTail then
            local tailOffset = integrateDrive(finalVelocity, (action.tail or ZERO) * (action.walkSpeed or 0),
                t - untilTail, action.braking or 620)
            offset += tailOffset
        end
        return offset
    end
    if action.kind == "dash" then
        local braking = action.braking or ((action.airborne or action.jump) and 145 or 620)
        local travelTime = math.min(after, action.speed / braking, action.tail and .25 or math.huge)
        local distance = action.speed * travelTime - braking * travelTime * travelTime * .5
        local offset = initialVelocity * before + action.direction * distance
        if action.tail and after > .25 then
            offset += integrateDrive(action.direction * math.max(0, action.speed - braking * .25),
                action.tail * (action.walkSpeed or 0), after - .25, braking)
        end
        return offset
    end
    local duration = math.min(after, action.duration or .22)
    local firstTime = math.min(duration, action.turnAt or math.huge)
    local acceleration = action.walkBraking or ((action.airborne or action.jump) and 145 or 620)
    local offset, current = integrateDrive(initialVelocity, action.direction * action.speed, firstTime, acceleration)
    if action.nextDirection and duration > firstTime then
        local secondOffset, secondVelocity = integrateDrive(current, action.nextDirection * action.speed, duration - firstTime, acceleration)
        offset += secondOffset
        current = secondVelocity
    end
    if after > duration then offset += integrateDrive(current, ZERO, after - duration, acceleration) end
    return initialVelocity * before + offset
end

local function landingTime(action)
    local f = action.flight
    if not f then return 0 end
    local start, y, speed = 0, 0, f.vy
    if action.jump then
        start = action.latency or .045; y = f.vy * start - f.gravity * start * start * .5; speed = action.jumpPower
    end
    if action.secondAt then
        local elapsed = action.secondAt - start
        y += speed * elapsed - f.gravity * elapsed * elapsed * .5
        start, speed = action.secondAt, action.secondPower
    end
    local discriminant = speed * speed - 2 * f.gravity * (f.floorOffset - y)
    if discriminant < 0 then return math.huge end
    return start + (speed + math.sqrt(discriminant)) / f.gravity
end

local function playerOffset(action, t, initialVelocity, delay)
    delay = action.latency or delay
    local flat = horizontalOffset(action, t, Vector3.new(initialVelocity.X, 0, initialVelocity.Z), delay)
    local flight = action.flight
    if not flight then return flat end
    local g, vy = flight.gravity, flight.vy
    local y = vy * t - g * t * t * 0.5
    if action.jump then
        local before = math.min(t, delay)
        local after = math.max(0, t - delay)
        y = vy * before - g * before * before * 0.5 + action.jumpPower * after - g * after * after * 0.5
    end
    if action.secondAt and t >= action.secondAt then
        local first = math.max(0, action.secondAt - delay)
        local yAtSecond = vy * delay - g * delay * delay * .5 + action.jumpPower * first - g * first * first * .5
        local second = t - action.secondAt
        y = yAtSecond + action.secondPower * second - g * second * second * .5
    end
    if flight.floorOffset > 0 then
        if t >= landingTime(action) then y = flight.floorOffset end
    else y = math.max(flight.floorOffset, y) end
    return flat + Vector3.new(0, y, 0)
end

local function laserEndpoints(laser, t)
    local frame = laser.frame
    local angular = laser.omega.Magnitude
    if angular > 0.01 then
        local turn = CFrame.fromAxisAngle(laser.omega / angular, angular * t)
        frame = CFrame.new(laser.pivot) * turn * CFrame.new(-laser.pivot) * frame
    else frame += laser.velocity * t end
    local axis = laser.axis == "X" and frame.RightVector or frame.LookVector
    return frame.Position - axis * laser.halfLength, frame.Position + axis * laser.halfLength
end

local function laserClearance(laser, point, t, dt, margin)
    local a, b = laserEndpoints(laser, t)
    local sweepPadding = math.min(3, laser.omega.Magnitude * (laser.halfLength + (laser.frame.Position - laser.pivot).Magnitude) * dt * 0.5)
    local horizontal = 1.6 + laser.radius + margin + sweepPadding
    local vertical = 2.6 + laser.halfHeight + margin
    local function scale(v) return Vector3.new(v.X / horizontal, v.Y / vertical, v.Z / horizontal) end
    return segmentDistance(scale(a - point), scale(b - point))
end

local function centerPenalty(action, origin, velocity, horizon, center, radius)
    if not center then return 0 end
    local penalty = 0
    for _, fraction in ipairs({0.25, 0.5, 0.75, 1}) do
        local point = origin + playerOffset(action, horizon * fraction, velocity, .045)
        local delta = point - center
        local distance = Vector3.new(delta.X, 0, delta.Z).Magnitude
        penalty += math.max(0, 1 - distance / radius)^2
    end
    return penalty * 0.3
end

local function lavaClearance(zone, point, t, margin)
    local localPoint = zone.frame:PointToObjectSpace(point)
    local outsideX = math.max(0, math.abs(localPoint.X) - zone.halfX - 1.6)
    local outsideZ = math.max(0, math.abs(localPoint.Z) - zone.halfZ - 1.6)
    local horizontal = math.sqrt(outsideX * outsideX + outsideZ * outsideZ) / (1 + margin)
    local above = (point.Y - zone.standingHeight - zone.level - zone.rise * t) / (.6 + margin)
    return math.max(horizontal, above)
end

local function shouldConsiderJump(clearance, impact, targeted, threats, specialDanger, double, landing)
    if specialDanger then return true end
    if impact ~= math.huge and impact < .22 then return true end
    if impact == math.huge then return false end
    if double then return clearance < 1.35 or impact < math.max(.7, landing + .12) end
    if Config.moderateJump then
        return clearance < 1.05 or (targeted >= 2 and threats >= 4 and clearance < 1.25 and impact < .7)
    end
    return clearance < 1.3 or impact < .4
end

local function preferRoute(score, clearance, bestScore, bestClearance, metrics, bestMetrics)
    local safe, bestSafe = clearance >= 1.05, bestClearance >= 1.05
    if safe ~= bestSafe then return safe end
    if not safe then
        if metrics and bestMetrics then
            local time, bestTime = math.floor(math.min(10, metrics.impact) * 20), math.floor(math.min(10, bestMetrics.impact) * 20)
            if time ~= bestTime then return time > bestTime end
        end
        local bucket, bestBucket = math.floor(clearance * 16), math.floor(bestClearance * 16)
        if bucket ~= bestBucket then return bucket > bestBucket end
        if metrics and bestMetrics then
            local a, b = math.floor(metrics.exposure * 20), math.floor(bestMetrics.exposure * 20)
            if a ~= b then return a < b end
            a, b = math.floor(metrics.futureFreedom * 50), math.floor(bestMetrics.futureFreedom * 50)
            if a ~= b then return a > b end
            a, b = math.floor(metrics.futureThreatDensity * 50), math.floor(bestMetrics.futureThreatDensity * 50)
            if a ~= b then return a < b end
        end
    end
    return score > bestScore
end

local function preparationImproves(clearance, metrics, baseline)
    return clearance >= 1.15 and (metrics.futureFreedom > baseline.futureFreedom + .08
        or (metrics.edgeSafety > baseline.edgeSafety + .18 and metrics.futureFreedom >= baseline.futureFreedom))
end

local function shouldReplace(score, clearance, metrics, baseScore, baseClearance, baseline, emergency)
    if (clearance >= 1.05) ~= (baseClearance >= 1.05) then return clearance >= 1.05 end
    if clearance < 1.05 then return preferRoute(score, clearance, baseScore, baseClearance, metrics, baseline) end
    return score > baseScore + (emergency and .03 or .18)
end

local function planningTelemetry()
    return {predictionConfidence = State.predictionConfidence, predictionError = State.predictionError,
        uncertainty = State.maxUncertainty, emergencyReplans = State.emergencyReplans, safeExitCount = State.exitSpace,
        largestExitArc = State.largestExitArc, futureFreedom = State.futureFreedom, planStages = State.planStages,
        preparationMoves = State.preparationMoves, stagedMoves = State.stagedMoves, completedTurns = State.completedTurns,
        targetChanges = State.targetChanges, mergedHazards = State.mergedHazards, plansEvaluated = State.plansTested,
        totalPlansEvaluated = State.totalPlansEvaluated, planningMs = State.planningMs, safetyMs = State.safetyMs, plannerHz = State.plannerHz,
        emergencyClearance = State.emergencyClearance, futureThreatDensity = State.futureThreatDensity}
end

local function captureIncident(reason)
    if State.incident and State.incident.reason == "Humanoid.Died" and os.clock() - State.incident.t < 3 then return end
    local replicated = game:GetService("ReplicatedStorage"):FindFirstChild("ReplicatedStates")
    local inProgress = replicated and replicated:FindFirstChild("RoundInProgress")
    local left = replicated and replicated:FindFirstChild("PlayersLeftCount")
    State.incident = {reason = reason, t = os.clock(), samples = table.clone(State.trace),
        decisions = table.clone(State.decisions), inProgress = inProgress and inProgress.Value,
        playersLeft = left and left.Value, planning = planningTelemetry()}
    if reason == "Round exit" and inProgress and inProgress.Value and left and left.Value > 1 then
        State.earlyRoundExits += 1
    end
end

local function traceFrame(root, humanoid, balls, now)
    if now - State.lastTraceTime < .1 then return end
    State.lastTraceTime = now
    local nearby = {}
    for _, ball in ipairs(balls) do
        if ball.hazard == nil or ball.hazard == "Spawn" or ball.hazard == "Laser" then
            if #nearby < 16 then table.insert(nearby, {p = tostring(ball.position or ball.frame.Position),
                v = tostring(ball.velocity), radius = ball.radius, kind = ball.hazard or "Ball", id = ball.id,
                targeted = ball.target and ball.target.localTarget or false, uncertainty = uncertaintyAt(ball, 1),
                predictionConfidence = ball.model and ball.model.predictionConfidence,
                predictionError = ball.model and ball.model.predictionError,
                uncertaintyGrowth = ball.model and ball.model.uncertaintyGrowth, targetChangeAge = ball.targetChangeAge}) end
        end
    end
    table.insert(State.trace, {t = now, p = tostring(root.Position), v = tostring(root.AssemblyLinearVelocity),
        health = humanoid.Health, motion = humanoid:GetState().Name, focused = isrbxactive(),
        tags = Tags:GetTags(root.Parent), hurtLoop = root.Parent:GetAttribute("HurtLoopRunning") == true,
        walkSpeed = humanoid.WalkSpeed, jumpPower = humanoid.JumpPower, effects = State.effects,
        auto = Config.auto, status = State.status, lastAction = State.lastAction,
        jumpsUsed = State.airUsed, balls = nearby, frameMs = State.lastCost, planning = planningTelemetry()})
    if #State.trace > 80 then table.remove(State.trace, 1) end
end

local function reversalPenalty(direction, previousDirection, age, imminent)
    if not previousDirection or age > 0.85 then return 0 end
    local opposition = math.max(0, -direction:Dot(previousDirection))
    return opposition * (imminent and 0.12 or 0.6) * (1 - age / 0.85)
end

local function arenaGap(point, base)
    if not base then return 30 end
    local localPoint = base.CFrame:PointToObjectSpace(point)
    return math.min(base.Size.X * .5 - math.abs(localPoint.X), base.Size.Z * .5 - math.abs(localPoint.Z))
end

local function exitOpenings(endpoints, point, terminalVelocity, action)
    action = action or {}
    point, terminalVelocity = point or ZERO, terminalVelocity or ZERO
    local clearances, exits, nearby = {}, {}, {}
    local density = 0
    for _, endpoint in ipairs(endpoints) do
        local approach = segmentDistance(endpoint.position, endpoint.position + endpoint.velocity * .4)
        if endpoint.laser or approach < endpoint.radius + 24 then
            table.insert(nearby, endpoint)
            density += math.clamp(1 - (approach - endpoint.radius) / 18, 0, 1)
        end
    end
    local safeCount = 0
    for index = 0, 15 do
        local angle = index * math.pi / 8
        local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
        local move = integrateDrive(terminalVelocity, direction * (action.walkSpeed or 14), .4, action.walkBraking or 620)
        local clearance = 3
        if arenaGap(point + move, action.arena) < 3 then clearance = 0 end
        for _, endpoint in ipairs(nearby) do
            if endpoint.laser then
                clearance = math.min(clearance, laserClearance(endpoint.laser, point + move, endpoint.time + .4, .4, Config.margin))
                continue
            end
            local function scale(v)
                return Vector3.new(v.X / endpoint.radius, v.Y / endpoint.height, v.Z / endpoint.radius)
            end
            clearance = math.min(clearance, segmentDistance(scale(endpoint.position),
                scale(endpoint.position + endpoint.velocity * .4 - move)))
            if clearance < 1.05 then break end
        end
        exits[index + 1] = clearance >= 1.1
        if exits[index + 1] then safeCount += 1 end
        table.insert(clearances, clearance)
    end
    local run, largest = 0, 0
    for index = 1, 32 do
        run = exits[(index - 1) % 16 + 1] and math.min(16, run + 1) or 0
        largest = math.max(largest, run)
    end
    table.sort(clearances, function(a, b) return a > b end)
    local top = (clearances[1] + clearances[2] + clearances[3] + clearances[4]) / 4
    local edge = math.clamp(arenaGap(point, action.arena) / 16, 0, 1)
    density = math.clamp(density / 6, 0, 1)
    local freedom = safeCount / 16 * .35 + largest / 16 * .25 + top / 3 * .15 + edge * .15 + (1 - density) * .1
    local metrics = {safeExitCount = safeCount, largestExitArc = largest * 22.5, exitClearance = top,
        edgeSafety = edge, futureThreatDensity = density, futureFreedom = freedom}
    return safeCount, freedom * 1.35, metrics
end

local function routeCannotWin(clearance, firstHit, safeIncumbent, incumbent)
    if clearance >= 1.05 then return false end
    if safeIncumbent then return true end
    return incumbent ~= nil and math.floor(math.min(10, firstHit) * 20)
        < math.floor(math.min(10, incumbent.impact) * 20)
end

-- Planning
local function pathScore(action, balls, origin, velocity, steps, dt, margin, safeIncumbent, incumbent)
    local worst, danger, firstHit, exposure, finalClearance = 20, 0, math.huge, 0, 20
    local endpoints = action.checkExit and {} or nil
    local offsets = {ZERO}
    for i = 1, steps do offsets[i + 1] = playerOffset(action, i * dt, velocity, .045) end
    for _, ball in ipairs(balls) do
        if ball.hazard == "Lava" then
            local minimum, last = 20, 20
            for i = 0, steps do
                last = lavaClearance(ball, origin + offsets[i + 1], i * dt, margin)
                minimum = math.min(minimum, last)
                exposure += math.max(0, 1.25 - last)^2 / (steps + 1)
                if last < 1 then firstHit = math.min(firstHit, i * dt) end
            end
            worst = math.min(worst, minimum); finalClearance = math.min(finalClearance, last)
            danger += math.max(0, 1.5 - minimum)^2
            if routeCannotWin(worst, firstHit, safeIncumbent, incumbent) then return -math.huge, firstHit, worst end
            continue
        end
        if ball.hazard == "Laser" then
            local minimum, last = 20, 20
            for i = 0, steps * 2 do
                local t = i * dt * .5
                local point = origin + playerOffset(action, t, velocity, .045)
                last = laserClearance(ball, point, t, dt * .5, margin)
                minimum = math.min(minimum, last)
                exposure += math.max(0, 1.25 - last)^2 / (steps * 2 + 1)
                if last < 1 then firstHit = math.min(firstHit, t) end
            end
            if endpoints then
                local a, b = laserEndpoints(ball, steps * dt)
                local point, segment = origin + offsets[steps + 1], b - a
                local fraction = math.clamp((point - a):Dot(segment) / math.max(.001, segment:Dot(segment)), 0, 1)
                table.insert(endpoints, {laser = ball, time = steps * dt, position = a + segment * fraction - point,
                    velocity = ZERO, radius = ball.radius + 1.6 + margin, height = ball.halfHeight + 2.6 + margin})
            end
            worst = math.min(worst, minimum)
            finalClearance = math.min(finalClearance, last)
            danger += math.max(0, 1.5 - minimum)^2
            if routeCannotWin(worst, firstHit, safeIncumbent, incumbent) then return -math.huge, firstHit, worst end
            continue
        end
        local radius, height = ball.radius + 1.6 + margin, ball.radius + 2.6 + margin
        local function scale(v, uncertainty)
            return Vector3.new(v.X / (radius + uncertainty), v.Y / (height + uncertainty), v.Z / (radius + uncertainty))
        end
        local ballMin = 20
        local pathEntries = {}
        table.insert(pathEntries, {kind = "linear", path = ball.linear})
        if ball.target and ball.target.localTarget then
            local curvedPath = {ball.position}
            local position, ballVelocity = ball.position, ball.velocity
            for index = 1, steps do
                local goal = origin + offsets[index + 1]
                position, ballVelocity = advanceThreat(ball, position, ballVelocity, goal, index * dt, dt)
                curvedPath[index + 1] = position
            end
            table.insert(pathEntries, {kind = "candidateHoming", path = curvedPath})
        elseif not ball.identicalPaths then
            table.insert(pathEntries, {kind = "curve", path = ball.curve})
        end
        for _, entry in ipairs(ball.ensemble or {}) do
            if entry.kind ~= "linear" and entry.kind ~= "curve" then table.insert(pathEntries, entry) end
        end
        local baselineMin, bounceMin = 20, 20
        for _, entry in ipairs(pathEntries) do
            local path = entry.path
            local last = path[1] - origin
            local pathMin = 20
            for i = 1, steps do
                local t = i * dt
                local divergence = (ball.linear[i + 1] - path[i + 1]).Magnitude
                local uncertainty = uncertaintyAt(ball, t, divergence)
                local relative = path[i + 1] - origin - offsets[i + 1]
                local clearance = segmentDistance(scale(last, uncertainty), scale(relative, uncertainty))
                pathMin = math.min(pathMin, clearance)
                ballMin = math.min(ballMin, clearance)
                exposure += math.max(0, 1.25 - clearance)^2 / (steps * math.max(1, #pathEntries))
                if clearance < 1 then firstHit = math.min(firstHit, t) end
                last = relative
            end
            if entry.bounce then bounceMin = math.min(bounceMin, pathMin)
            else baselineMin = math.min(baselineMin, pathMin) end
            local divergence = (ball.linear[steps + 1] - path[steps + 1]).Magnitude
            local uncertainty = uncertaintyAt(ball, steps * dt, divergence)
            finalClearance = math.min(finalClearance, scale(last, uncertainty).Magnitude)
            if endpoints then table.insert(endpoints, {position = path[steps + 1] - origin - offsets[steps + 1],
                velocity = (path[steps + 1] - path[steps]) / dt, radius = radius + uncertainty, height = height + uncertainty}) end
        end
        if bounceMin < baselineMin - .05 then
            action.bounceRisk = true
            action.bounceClearance = math.min(action.bounceClearance or 20, bounceMin)
        end
        action.modelCount = math.max(action.modelCount or 0, #pathEntries)
        worst = math.min(worst, ballMin)
        danger += math.max(0, 1.5 - ballMin)^2
        if routeCannotWin(worst, firstHit, safeIncumbent, incumbent) then return -math.huge, firstHit, worst end
    end
    local timeBonus = firstHit == math.huge and 0.8 or math.min(firstHit, 1.2) * 0.6
    local openings, room = 0, 0
    local metrics = {safeExitCount = 0, largestExitArc = 0, exitClearance = 0, edgeSafety = 1,
        futureThreatDensity = 0, futureFreedom = 0}
    if endpoints then
        openings, room, metrics = exitOpenings(endpoints, origin + offsets[steps + 1],
            (offsets[steps + 1] - offsets[steps]) / dt, action)
    end
    metrics.impact, metrics.exposure = firstHit, exposure
    local immediate = worst >= 1.05 and math.min(worst, 1.6) or worst
    return immediate - danger * 2 + timeBonus - exposure * 0.6 + math.min(3, finalClearance) * 0.1 + room,
        firstHit, worst, openings, metrics
end

local function continuationSeeds(actions, balls, origin, velocity, steps, dt, margin)
    local ranked, selected = {}, {}
    local prefixSteps = math.min(steps, math.max(2, math.ceil(.3 / dt)))
    for _, action in ipairs(actions) do
        if action.follow or action.nextDirection or action.lavaClimb then continue end
        if action.kind ~= "walk" and action.kind ~= "dash" and action.kind ~= "drift" then continue end
        local prefix = table.clone(action)
        prefix.checkExit = false
        local score, _, clearance, _, metrics = pathScore(prefix, balls, origin, velocity, prefixSteps, dt, margin)
        table.insert(ranked, {action = action, score = score, clearance = clearance, metrics = metrics})
    end
    table.sort(ranked, function(a, b) return preferRoute(a.score, a.clearance, b.score, b.clearance, a.metrics, b.metrics) end)
    for _, route in ipairs(ranked) do
        local distinct = true
        for _, chosen in ipairs(selected) do
            if route.action.kind == chosen.kind and route.action.jump == chosen.jump
                and route.action.direction:Dot(chosen.direction) > .93 then distinct = false; break end
        end
        if distinct then table.insert(selected, route.action) end
        if #selected >= 4 then break end
    end
    return selected
end

local function routeTimes(action, horizon, initialVelocity)
    local times = action.flight and {.1 * horizon, .2 * horizon, .3 * horizon, .4 * horizon, .5 * horizon,
        .6 * horizon, .7 * horizon, .8 * horizon, .9 * horizon, horizon} or {.25 * horizon, .6 * horizon, horizon}
    local function add(t)
        if t and t > 0 and t < horizon then table.insert(times, t) end
    end
    local function mark(a, start, initial, depth)
        local finish = math.min(horizon, a.follow and start + a.followAt or horizon)
        local delay = (a.latency or .045) + (a.jump and a.kind == "dash" and .06 or 0) + (a.moveDelay or 0)
        local at = start + delay
        local braking = a.braking or ((a.jump or a.airborne) and 145 or 620)
        local function drive(t, velocity, target, duration, acceleration)
            duration = math.max(0, math.min(duration, finish - t))
            local difference = target - velocity
            local settle = math.max(.025, difference.Magnitude / math.max(1, acceleration))
            add(t); add(t + math.min(duration, settle)); add(t + duration)
            for _, axis in ipairs({"X", "Z"}) do
                if math.abs(difference[axis]) > .0001 then
                    local zero = -velocity[axis] * settle / difference[axis]
                    if zero > 0 and zero < math.min(duration, settle) then add(t + zero) end
                end
            end
            local _, final = integrateDrive(velocity, target, duration, acceleration)
            return final
        end
        add(at)
        if a.kind == "walk" then
            local acceleration = a.walkBraking or ((a.airborne or a.jump) and 145 or 620)
            local duration = math.max(0, math.min(a.duration or .22, finish - at))
            local first = math.min(duration, a.turnAt or math.huge)
            local current = drive(at, initial, a.direction * a.speed, first, acceleration)
            if a.nextDirection and duration > first then
                current = drive(at + first, current, a.nextDirection * a.speed, duration - first, acceleration)
            end
            if at + duration < finish then drive(at + duration, current, ZERO, finish - at - duration, acceleration) end
            add(a.turnAt and at + a.turnAt + .06)
        elseif a.kind == "dash" then
            add(at + math.min(.25, a.speed / braking))
            if a.tail and at + .25 < finish then
                drive(at + .25, a.direction * math.max(0, a.speed - braking * .25),
                    a.tail * (a.walkSpeed or 0), finish - at - .25, braking)
            end
        elseif a.kind == "drift" then
            local coast = math.min(a.tailAt or math.huge, finish - start)
            local current = drive(start, initial, ZERO, coast, braking)
            if start + coast < finish then
                drive(start + coast, current, (a.tail or ZERO) * (a.walkSpeed or 0), finish - start - coast, braking)
            end
        end
        if a.follow and depth < 3 and start + a.followAt < horizon then
            add(start + a.followAt); add(start + a.followAt + .06)
            local t = a.followAt
            local v = (horizontalOffset(a, t, initial, .045, true)
                - horizontalOffset(a, math.max(0, t - .002), initial, .045, true)) / math.min(.002, t)
            mark(a.follow, start + t, v, depth + 1)
        end
    end
    mark(action, 0, initialVelocity or ZERO, 0)
    table.sort(times)
    local unique, last = {}, -1
    for _, t in ipairs(times) do
        if t - last > .0001 then table.insert(unique, t); last = t end
    end
    return unique
end

local function geometryParams(exclude, collisionGroup)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    params.FilterDescendantsInstances = exclude
    params.RespectCanCollide = true
    params.CollisionGroup = collisionGroup
    return params
end

local function environmentClear(action, origin, velocity, steps, dt, rayParams)
    if action.flight and landingTime(action) == math.huge then return false end
    local previousOffset, previousTime = ZERO, 0
    local landedAt = action.flight and landingTime(action) or 0
    for _, t in ipairs(routeTimes(action, steps * dt, velocity)) do
        local offset = playerOffset(action, t, velocity, 0.045)
        local from = origin + previousOffset
        local delta = offset - previousOffset
        if delta.Magnitude > 0.01 then
            local hit = workspace:Blockcast(CFrame.new(from), Vector3.new(2, 3, 2), delta, rayParams)
            if hit then return false end
        end
        if t >= landedAt then
            local pieces = math.max(1, math.ceil(Vector3.new(delta.X, 0, delta.Z).Magnitude / 2))
            for piece = 1, pieces do
                local sampleTime = previousTime + (t - previousTime) * piece / pieces
                if sampleTime < landedAt then continue end
                local point = origin + playerOffset(action, sampleTime, velocity, .045)
                local ground = workspace:Raycast(point + Vector3.new(0, 2, 0), Vector3.new(0, -14, 0), rayParams)
                if not ground or ground.Normal.Y < .35 then return false end
                if action.lavaActive and ground.Position.Y < (action.minimumFloor or (origin.Y - State.standingHeight)) - .6 then return false end
            end
        end
        previousOffset, previousTime = offset, t
    end
    if action.flight then
        local t = landingTime(action)
        local offset = playerOffset(action, t, velocity, .045)
        local ground = workspace:Raycast(origin + offset + Vector3.new(0, 3, 0), Vector3.new(0, -10, 0), rayParams)
        if not ground or ground.Normal.Y < .5 then return false end
        if action.goalPart and ground.Instance ~= action.goalPart then return false end
        if action.lavaActive and ground.Position.Y < (action.minimumFloor or (origin.Y - State.standingHeight)) - .6 then return false end
        if math.abs(ground.Position.Y + action.flight.standingHeight - (origin.Y + offset.Y)) > 3 then return false end
        local position = ground.Position + Vector3.new(0, action.flight.standingHeight, 0)
        if workspace:Blockcast(CFrame.new(position), Vector3.new(2, 3, 2), Vector3.yAxis * .1, rayParams) then return false end
    end
    return true
end

local function keyInfo(action)
    local defaults = {Left = "Q", Right = "E", Forward = "R", WalkFront = "W", WalkBack = "S"}
    local names = {Left = "DodgeLeft", Right = "DodgeRight", Forward = "DodgeFront"}
    local name = defaults[action]
    local keybinds = Player:FindFirstChild("Keybinds")
    local pc = keybinds and keybinds:FindFirstChild("PC")
    local configured = pc and names[action] and pc:FindFirstChild(names[action])
    if configured and configured:IsA("StringValue") then name = configured.Value end
    if not name then return nil, nil end
    local special = {Space = 0x20, LeftShift = 0xA0, RightShift = 0xA1, LeftControl = 0xA2, LeftAlt = 0xA4}
    local vk = #name == 1 and string.byte(string.upper(name)) or special[name]
    return vk, Enum.KeyCode[name]
end

local function impulsesAllowed(character)
    if not character then return false end
    if Tags:HasTag(character, "FreezeTagFrozen") or Tags:HasTag(character, "HumanShield") then return false end
    if Tags:HasTag(character, "Downed") then return State.mobility.active end
    return true
end

local function availableWalkSpeed(character, speed)
    if Tags:HasTag(character, "Glued") then return math.min(speed, 1) end
    if Tags:HasTag(character, "Downed") then
        if State.mobility.active then return State.mobility.normalWalkSpeed or State.mobility.profile.lastWalkSpeed or speed end
        return math.min(speed, 6)
    end
    return speed
end

local function ready(action, now)
    if (action == "Jump" or action == "Left" or action == "Right" or action == "Forward")
        and not impulsesAllowed(Player.Character) then return false end
    if action == "Jump" then return now - State.lastJump > .2 end
    if string.sub(action, 1, 4) == "Move" then return true end
    if now - (State.lastUsed[action] or -100) < (Cooldowns[action] or 0.2) then return false end
    if State.mobility.active then return true end
    local labels = {Left = "PCleft", Right = "PCright", Forward = "PCroll"}
    local gui = PlayerGui:FindFirstChild("PCControlsUI")
    local container = gui and gui:FindFirstChild("PCLabels")
    local label = container and labels[action] and container:FindFirstChild(labels[action])
    local overlay = label and label:FindFirstChild("CooldownOverlay")
    return not (overlay and overlay:IsA("GuiObject") and overlay.Visible and overlay.Size.Y.Scale > 0.02)
end

local function tapKey(key, enum)
    if not key or not enum or State.held[key] or Input:IsKeyDown(enum) then return false end
    State.held[key] = true
    local ok, err = pcall(keypress, key)
    if not ok then State.held[key] = nil; State.lastError = tostring(err); return false end
    local epoch = State.inputEpoch
    task.delay(.045, function()
        if State.inputEpoch == epoch and State.held[key] then
            pcall(keyrelease, key); State.held[key] = nil
        end
    end)
    return true
end

local function markDash(action, root, now)
    State.pendingDash = {root = root, started = now, position = root.Position,
        direction = action.direction, expectedSpeed = action.speed, peakSpeed = 0, alignment = 0,
        name = action.name, airborne = action.airborne or action.jump, oriented = action.orient == true,
        brakingSamples = {}, humanoid = root.Parent:FindFirstChildOfClass("Humanoid")}
    if action.orient then State.orientedDashes += 1 end
end

local function learnedBraking(samples, previous, airborne)
    if #samples < 3 then return previous end
    local sorted = table.clone(samples)
    table.sort(sorted)
    local median = sorted[math.ceil(#sorted * .5)]
    local low, high = airborne and 30 or 150, airborne and 400 or 1600
    if median < low or median > high then return previous end
    return previous * .4 + median * .6
end

local function observeDash(now)
    local sample = State.pendingDash
    if not sample then return end
    if not sample.root.Parent then State.pendingDash = nil; return end
    local velocity = sample.root.AssemblyLinearVelocity
    local flat = Vector3.new(velocity.X, 0, velocity.Z)
    local projection = flat:Dot(sample.direction)
    local h = sample.humanoid
    local consistent = h and (h.FloorMaterial == Enum.Material.Air) == (sample.airborne == true)
        and flat.Magnitude > math.max(18, h.WalkSpeed + 3) and flat.Unit:Dot(sample.direction) > .97
    if consistent and sample.lastVelocity and sample.lastTime then
        local dt = now - sample.lastTime
        local braking = (sample.lastVelocity - projection) / math.max(.001, dt)
        local low, high = sample.airborne and 30 or 150, sample.airborne and 400 or 1600
        if dt >= .003 and dt <= .07 and braking >= low and braking <= high then
            table.insert(sample.brakingSamples, braking)
        end
    end
    sample.lastVelocity = consistent and projection or nil
    sample.lastTime = consistent and now or nil
    if flat.Magnitude > sample.peakSpeed then
        sample.peakSpeed = flat.Magnitude
        sample.alignment = flat.Magnitude > .1 and flat.Unit:Dot(sample.direction) or 0
    end
    if now - sample.started < .14 then return end
    local verified = sample.peakSpeed >= math.max(20, sample.expectedSpeed * .4) and sample.alignment > .85
    if verified then State.verifiedDashes += 1 else State.unconfirmedDashes += 1 end
    if verified then
        if sample.airborne then State.airBraking = learnedBraking(sample.brakingSamples, State.airBraking, true)
        else State.groundBraking = learnedBraking(sample.brakingSamples, State.groundBraking, false) end
        if not State.mobility.active then
            local profile = State.mobility.profile.actions[sample.name]
            if profile then
                local count = (profile.samples or 0) + 1
                local weight = 1 / math.min(6, count)
                local along = math.max(0, (sample.root.Position - sample.position):Dot(sample.direction))
                local braking = sample.airborne and State.airBraking or State.groundBraking
                profile.peakSpeed = profile.peakSpeed and (profile.peakSpeed * (1 - weight) + sample.peakSpeed * weight) or sample.peakSpeed
                profile.distance = profile.distance and (profile.distance * (1 - weight) + along * weight) or along
                profile.duration = profile.duration and (profile.duration * (1 - weight) + (now - sample.started) * weight) or (now - sample.started)
                profile.braking, profile.samples = braking, count
            end
        end
    end
    table.insert(State.motionSamples, {t = sample.started, name = sample.name, verified = verified,
        peak = sample.peakSpeed, alignment = sample.alignment, airborne = sample.airborne == true,
        oriented = sample.oriented, along = (sample.root.Position - sample.position):Dot(sample.direction),
        elapsed = now - sample.started})
    if #State.motionSamples > 20 then table.remove(State.motionSamples, 1) end
    State.pendingDash = nil
end

local function chooseDashKey(direction, front, available)
    local name, best = nil, math.huge
    for _, candidate in ipairs({"Left", "Right", "Forward"}) do
        if available[candidate] then
            local cost = (1 - dashLook(direction, candidate):Dot(front)) * .025
                + (candidate == "Forward" and .08 or 0)
            if cost < best then name, best = candidate, cost end
        end
    end
    return name
end

-- Movement
local function pressAction(action)
    if not isrbxactive() or Input:GetFocusedTextBox() then return false end
    local now = os.clock()
    local character = Player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then return false end
    local normalized = State.mobility.active and Tags:HasTag(character, "Downed")
    if action.kind == "dash" and not ready(action.name, now) then return false end
    if action.jump and not ready("Jump", now) then return false end
    if action.jump then
        if normalized then
            if not performNormalizedJump(action.double == true) then return false end
        else
            noteAnimationIntent(action.double and "DoubleJump" or "Jump", .3)
            if not tapKey(0x20, Enum.KeyCode.Space) then return false end
            State.lastJump = now; State.jumps += 1
            if action.double then State.airUsed = 1; State.doubles += 1 end
        end
    end
    local function trackMotion()
        if action.direction and State.lastDirection and action.direction:Dot(State.lastDirection) < -.5 then State.reversals += 1 end
        State.activeMotion = {action = action, started = now, velocity = root.AssemblyLinearVelocity}
        State.followupAt = action.follow and now + action.followAt or action.secondAt and now + action.secondAt - .05 or nil
    end
    if action.kind == "drift" then
        trackMotion()
        State.steering = nil
        State.blockedUntil = now + .08
        State.lastDirection, State.lastDecisionTime = action.direction, now
        State.actions += 1
        return true
    end
    if action.kind == "walk" then
        trackMotion()
        local delay = (action.moveDelay or 0) + (action.latency or .045)
        State.steering = {direction = action.direction, start = now + delay,
            finish = action.follow and now + action.followAt or now + delay + (action.duration or .22), nextDirection = action.nextDirection,
            turnAt = action.turnAt and now + delay + action.turnAt}
        State.blockedUntil = now + (action.jump and .12 or .09)
        State.lastDirection, State.lastDecisionTime = action.direction, now
        State.actions += 1
        return true
    end
    if normalized and action.kind == "dash" then
        if action.orient and not faceDash(action, now) then return false end
        startNormalizedImpulse(action, root, now)
        State.lastUsed[action.name] = now
        trackMotion()
        State.blockedUntil = now + (action.jump and .2 or .15)
        State.actions += 1
        State.lastDirection, State.lastDecisionTime = action.direction, now
        if action.tail then
            State.steering = {direction = action.tail, start = now + (action.latency or .045) + .25,
                finish = now + (action.horizon or Config.horizon)}
        end
        return true
    end
    local key, enum = keyInfo(action.name)
    if not key or not enum or Input:IsKeyDown(enum) or State.held[key] then return false end
    if action.jump then
        local epoch = State.inputEpoch
        task.delay(.06, function()
            if not State.alive or State.inputEpoch ~= epoch or Player.Character ~= character
                or not Config.auto or not isrbxactive() or Input:GetFocusedTextBox() then return end
            local currentRoot = character and character:FindFirstChild("HumanoidRootPart")
            if not currentRoot then return end
            if not faceDash(action, os.clock()) then return end
            local direction = action.name == "Forward" and currentRoot.CFrame.LookVector
                or currentRoot.CFrame.RightVector * (action.name == "Left" and -1 or 1)
            if unitFlat(direction, action.direction):Dot(action.direction) < .9 then return end
            noteAnimationIntent(action.name, .3)
            if ready(action.name, os.clock()) and tapKey(key, enum) then
                State.lastUsed[action.name] = os.clock()
                markDash(action, currentRoot, os.clock())
            else
                restoreFacing()
                State.activeMotion, State.followupAt = nil, nil
                State.replanRequested, State.blockedUntil = true, 0
            end
        end)
    else
        if not faceDash(action, now) then return false end
        noteAnimationIntent(action.name, .3)
        if not tapKey(key, enum) then restoreFacing(); return false end
        State.lastUsed[action.name] = now
        markDash(action, root, now)
    end
    trackMotion()
    State.blockedUntil = now + (action.jump and .2 or .15)
    State.actions += 1
    State.lastDirection, State.lastDecisionTime = action.direction, now
    if action.tail then
        State.steering = {direction = action.tail, start = now + (action.latency or .045) + .25 + (action.jump and .06 or 0),
            finish = now + (action.horizon or Config.horizon)}
    end
    return true
end

local function performManualNormalizedDash(name)
    if not State.mobility.active then return false end
    local now = os.clock()
    if not ready(name, now) then return false end
    local character = Player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not root or not humanoid or root.Anchored then return false end
    local direction = name == "Forward" and root.CFrame.LookVector
        or root.CFrame.RightVector * (name == "Left" and -1 or 1)
    local profile = State.mobility.profile.actions[name]
    local speed = profile and profile.peakSpeed or (humanoid.FloorMaterial == Enum.Material.Air and 50 or 120)
    local action = {name = name, kind = "dash", direction = unitFlat(direction, Vector3.zAxis), speed = speed,
        airborne = humanoid.FloorMaterial == Enum.Material.Air}
    startNormalizedImpulse(action, root, now)
    State.lastUsed[name] = now
    State.lastDirection, State.lastDecisionTime = action.direction, now
    State.lastAction = "Normalizado: " .. name
    return true
end

local function performManualNormalizedJump()
    if not State.mobility.active or not ready("Jump", os.clock()) then return false end
    local character = Player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if not humanoid then return false end
    local airborne = humanoid.FloorMaterial == Enum.Material.Air
        or humanoid:GetState() == Enum.HumanoidStateType.Freefall or humanoid:GetState() == Enum.HumanoidStateType.Jumping
    local double = airborne and Config.doubleJump and State.airUsed == 0
        and State.airSince and os.clock() - State.airSince >= .175
    return performNormalizedJump(double == true)
end

local function compactHazards(result)
    local compacted = {}
    for index, candidate in ipairs(result) do
        if index > 128 then break end
        local contained = false
        for _, other in ipairs(compacted) do
            if candidate.hazard == other.hazard and (candidate.velocity - other.velocity).Magnitude < .5 then
                local separation = (candidate.position - other.position).Magnitude
                if separation + candidate.radius <= other.radius + .01 then contained = true; break end
            end
        end
        if not contained then table.insert(compacted, candidate) end
    end
    return compacted
end

local function hazardSnapshots(root)
    local result = {}
    if not Config.hazards then State.hazardCount = 0; return result end
    for object, info in pairs(State.hazards) do
        if not object:IsDescendantOf(workspace) then State.hazards[object] = nil; continue end
        if Player.Character and object:IsDescendantOf(Player.Character) then continue end
        if info.kind ~= "Fire" and object:IsA("BasePart") then
            local distance = (object.Position - root.Position).Magnitude
            if distance < 100 then
                table.insert(result, {instance = object, position = object.Position,
                    velocity = object.AssemblyLinearVelocity, acceleration = ZERO,
                    radius = math.max(object.Size.X, object.Size.Z) * 0.5 + 1,
                    distance = distance, hazard = info.kind})
            end
        elseif info.kind == "Fire" and object.Enabled then
            local parent = object.Parent
            local attachment = parent and parent:IsA("Attachment") and parent or nil
            local part = attachment and attachment.Parent or parent
            if not part or not part:IsA("BasePart") then continue end
            if (part.Position - root.Position).Magnitude > 100 then continue end
            local frame = attachment and attachment.WorldCFrame or part.CFrame
            local length = object:IsA("ParticleEmitter") and math.clamp(object.Speed.Max * object.Lifetime.Max, 6, 35) or 6
            local direction = frame.LookVector
            if object:IsA("ParticleEmitter") then
                local normal = Vector3.FromNormalId(object.EmissionDirection)
                direction = frame:VectorToWorldSpace(normal)
            end
            for _, fraction in ipairs({0.2, 0.55, 0.9}) do
                local position = frame.Position + direction * length * fraction
                table.insert(result, {instance = part, position = position,
                    velocity = part.AssemblyLinearVelocity, acceleration = ZERO,
                    radius = 2 + length * 0.12, distance = (position - root.Position).Magnitude, hazard = "Fire"})
            end
        end
    end
    table.sort(result, function(a, b) return a.distance - a.radius < b.distance - b.radius end)
    local compacted = compactHazards(result)
    State.mergedHazards = #result - #compacted
    result = compacted
    while #result > 40 do table.remove(result) end
    State.hazardCount = #result
    return result
end

local function ballSnapshots(root, now)
    local result, nearest = {}, math.huge
    State.spawning = 0
    State.targeted = 0
    State.implicitTargeted = 0
    for part, data in pairs(State.balls) do
        if not part:IsDescendantOf(workspace) then State.balls[part] = nil; continue end
        local position, velocity = part.Position, part.AssemblyLinearVelocity
        local elapsed = now - data.time
        if elapsed > 0.005 then
            local measured = (position - data.position) / elapsed
            if measured.Magnitude < 500 and (velocity.Magnitude < 1 or (measured - velocity).Magnitude < 35) then
                velocity = velocity:Lerp(measured, 0.25)
            end
        end
        local ap = part:FindFirstChildOfClass("AlignPosition")
        data.aligner = ap
        local radius = math.max(part.Size.X, part.Size.Y, part.Size.Z) * 0.5
        local distance = (position - root.Position).Magnitude
        local red = part.Color.R > 0.6 and part.Color.G < 0.4
        if distance > Config.range + radius or (not Config.allStyles and not red) then continue end
        local spawning = part.Anchored and velocity.Magnitude < 1
        if spawning then State.spawning += 1; radius = math.max(radius, 3.5) end
        nearest = math.min(nearest, distance)
        local target
        if not spawning and ap and ap.Attachment1 and ap.Attachment1.Parent and ap.Attachment1.Parent:IsA("BasePart") then
            target = {position = ap.Attachment1.WorldPosition, velocity = cap(ap.Attachment1.Parent.AssemblyLinearVelocity, 180),
                localTarget = ap.Attachment1.Parent == root}
        end
        local implicit = not spawning and isImplicitThreat(position, velocity, root, radius)
        if implicit then data.implicitTargetUntil = now + .35 end
        implicit = not spawning and now <= (data.implicitTargetUntil or -100)
        if (target and target.localTarget) or implicit then State.targeted += 1 end
        if implicit then State.implicitTargeted += 1 end
        local attachment = ap and ap.Attachment1
        local changed = data.targetSeen and data.lastTarget ~= attachment
        if changed then State.targetChanges += 1 end
        learnThreat(data, position, velocity, target, elapsed, now, changed, ap and math.min(ap.MaxVelocity, 300))
        data.position, data.velocity, data.time = position, velocity, now
        data.targetSeen, data.lastTarget = true, attachment
        local uncertainty = data.targetChanged and math.max(0, 1 - (now - data.targetChanged) / .35) * .65 or 0
        local snapshot = {instance = part, position = position, velocity = velocity,
            acceleration = data.acceleration, radius = radius, distance = distance, model = data,
            target = target, implicitTarget = implicit, hazard = spawning and "Spawn" or nil, uncertainty = uncertainty, id = data.id,
            targetChangeAge = now - (data.targetChanged or -100), maxSpeed = data.maxSpeed}
        data.previousSnapshot = snapshot
        table.insert(result, snapshot)
    end
    table.sort(result, function(a, b) return a.distance - a.radius < b.distance - b.radius end)
    State.visibleCount = #result
    while #result > 64 do table.remove(result) end
    State.nearest = nearest == math.huge and 0 or nearest
    local confidence, error, maximum = 0, 0, 0
    for _, ball in ipairs(result) do
        confidence += ball.model.predictionConfidence or 1
        error += ball.model.predictionError or 0
        maximum = math.max(maximum, uncertaintyAt(ball, 1))
    end
    State.predictionConfidence, State.predictionError = confidence / math.max(1, #result), error / math.max(1, #result)
    State.maxUncertainty = maximum
    return result
end

local function laserSnapshots(root, now)
    local result = {}
    for part, data in pairs(State.lasers) do
        if not part:IsDescendantOf(workspace) then State.lasers[part] = nil; continue end
        local frame, elapsed = part.CFrame, now - data.time
        if elapsed > .005 then
            local axis, angle = data.frame:ToObjectSpace(frame):ToAxisAngle()
            local omega = data.frame:VectorToWorldSpace(axis) * (angle / elapsed)
            data.omega = data.omega:Lerp(cap(omega, 8), .45)
            data.velocity = data.velocity:Lerp(cap((frame.Position - data.frame.Position) / elapsed, 250), .45)
        end
        data.frame, data.time = frame, now
        if not Config.lasers or part.Transparency >= .98 then continue end
        if not data.named and data.omega.Magnitude < .05 then continue end
        local halfLength = math.max(part.Size.X, part.Size.Z) * .5
        local distance = math.max(0, (frame.Position - root.Position).Magnitude - halfLength)
        if distance > Config.range or math.abs(frame.Position.Y - root.Position.Y) > 35 then continue end
        local pivot = frame.Position
        if data.omega.Magnitude > .05 then
            local radial = data.omega:Cross(data.velocity) / data.omega:Dot(data.omega)
            if radial.Magnitude <= halfLength * 2 + 15 then pivot += radial end
        end
        table.insert(result, {instance = part, hazard = "Laser", frame = frame, pivot = pivot,
            omega = data.omega, velocity = data.velocity, axis = part.Size.X > part.Size.Z and "X" or "Z",
            halfLength = halfLength, radius = math.min(part.Size.X, part.Size.Z) * .5,
            halfHeight = part.Size.Y * .5, distance = distance})
    end
    table.sort(result, function(a, b) return a.distance < b.distance end)
    while #result > 8 do table.remove(result) end
    State.laserCount = #result
    return result
end

local function updateArena(root)
    local map = workspace:FindFirstChild("CurrentMap")
    if map ~= State.arena then State.arena = map; State.center = nil end
    local base = map and map:FindFirstChild("Baseplate", true)
    if base and base:IsA("BasePart") and math.abs(root.Position.Y - base.Position.Y) < 50 then
        State.baseplate = base
        State.center = base.Position
        State.centerRadius = math.clamp(math.min(base.Size.X, base.Size.Z) * .08, 4, 14)
        State.centerDistance = Vector3.new(root.Position.X - base.Position.X, 0, root.Position.Z - base.Position.Z).Magnitude
    else State.center = nil; State.centerDistance = 0; State.baseplate = nil end
end

local function edgePenalty(action, origin, velocity, horizon, base)
    if not base then return 0 end
    local point = base.CFrame:PointToObjectSpace(origin + playerOffset(action, horizon, velocity, .045))
    local gap = math.min(base.Size.X * .5 - math.abs(point.X), base.Size.Z * .5 - math.abs(point.Z))
    return math.clamp(1 - gap / 12, 0, 2)^2 * .45
end

local function imminentCrossing(balls, origin, velocity)
    for _, ball in ipairs(balls) do
        if not ball.hazard or ball.hazard == "Spawn" then
            local difference = ball.position - origin
            if segmentDistance(difference, difference + (ball.velocity - velocity) * .13) < ball.radius + 3.8 then return true end
        end
    end
    return false
end

local function safetyClearance(balls, origin, velocity, motion)
    local horizon, minimum, cause = .12, 20, nil
    local offsets = {ZERO}
    local action, age, initialVelocity
    if motion then
        action, age, initialVelocity = motion.action, motion.age or 0, motion.velocity
        if action.follow or action.secondAt then
            action = table.clone(action)
            action.follow, action.secondAt = nil, nil -- Future inputs have not been executed.
        end
    end
    local start = action and playerOffset(action, age, initialVelocity, .045) or ZERO
    local feedback = action and cap(velocity - (playerOffset(action, age + .003, initialVelocity, .045) - start) / .003, 60) or ZERO
    for step = 1, 2 do
        local t = step * horizon / 2
        offsets[step + 1] = action and playerOffset(action, age + t, initialVelocity, .045) - start + feedback * math.min(t, .06) or velocity * t
    end
    for _, ball in ipairs(balls) do
        if ball.hazard == "Laser" or ball.hazard == "Lava" then
            for i = 0, 2 do
                local t, point = i * .06, origin + offsets[i + 1]
                local clearance = ball.hazard == "Laser" and laserClearance(ball, point, t, .06, Config.margin)
                    or lavaClearance(ball, point, t, Config.margin)
                if clearance < minimum then minimum, cause = clearance, ball.hazard end
            end
            continue
        end
        local position, ballVelocity = ball.position, ball.velocity
        if (position - origin).Magnitude > (ballVelocity - velocity).Magnitude * horizon + ball.radius + 12 then continue end
        local entries = ball.ensemble or {{kind = "linear", path = {ball.position, ball.position + ball.velocity * .06, ball.position + ball.velocity * .12}}}
        for _, entry in ipairs(entries) do
            local path = entry.path
            local previous = path[1] - origin
            local pathSteps = math.min(#path - 1, ball.predictionSteps or (#path - 1))
            local pathDt = ball.predictionDt or (horizon / math.max(1, pathSteps))
            for step = 1, pathSteps do
                local t = step * pathDt
                if t > horizon + .001 then break end
                local playerOffsetNow = action and playerOffset(action, age + t, initialVelocity, .045) - start
                    + feedback * math.min(t, .06) or velocity * t
                local relative = path[step + 1] - origin - playerOffsetNow
                local uncertainty = uncertaintyAt(ball, t, (ball.linear and ball.linear[step + 1] and (ball.linear[step + 1] - path[step + 1]).Magnitude) or 0)
                local radius, height = ball.radius + 1.6 + Config.margin + uncertainty, ball.radius + 2.6 + Config.margin + uncertainty
                local function scale(v) return Vector3.new(v.X / radius, v.Y / height, v.Z / radius) end
                local clearance = segmentDistance(scale(previous), scale(relative))
                if clearance < minimum then minimum, cause = clearance, ball.id or ball.hazard or "Ball" end
                previous = relative
            end
        end
    end
    return minimum, cause
end

local function needsEmergency(clearance, previous, latched, elapsed)
    return clearance < 1 and elapsed >= .09 and (not latched or clearance < previous - .15)
end

local function emergencyTick(now)
    if not State.alive or not Config.auto or not State.safetyEligible
        or not isrbxactive() or Input:GetFocusedTextBox() then return end
    local character = Player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root or (Config.onlyRound and not Tags:HasTag(character, "Playing")) then return end
    if Tags:HasTag(character, "Downed") ~= State.downed then
        releaseKeys()
        State.replanRequested, State.blockedUntil = true, 0
        return
    end
    local started, snapshots = os.clock(), {}
    for part, data in pairs(State.balls) do
        if not part.Parent then continue end
        local position, velocity = part.Position, part.AssemblyLinearVelocity
        local radius = math.max(part.Size.X, part.Size.Y, part.Size.Z) * .5
        if (position - root.Position).Magnitude > (velocity - root.AssemblyLinearVelocity).Magnitude * .12 + radius + 12 then continue end
        if not Config.allStyles and not (part.Color.R > .6 and part.Color.G < .4) then continue end
        local ap = data.aligner
        local attachment = ap and ap.Parent and ap.Attachment1
        local target
        if attachment and attachment.Parent and attachment.Parent:IsA("BasePart") then
            target = {position = attachment.WorldPosition, velocity = attachment.Parent.AssemblyLinearVelocity,
                localTarget = attachment.Parent == root}
        end
        local implicit = isImplicitThreat(position, velocity, root, radius) or now <= (data.implicitTargetUntil or -100)
        table.insert(snapshots, {position = position, velocity = velocity, acceleration = data.acceleration,
            radius = radius, model = data, target = target, implicitTarget = implicit, id = data.id,
            distance = (position - root.Position).Magnitude,
            targetChangeAge = attachment ~= data.lastTarget and 0 or now - (data.targetChanged or -100),
            uncertainty = attachment ~= data.lastTarget and .65 or 0})
        if #snapshots >= 64 then break end
    end
    for _, threat in ipairs(State.safetyThreats) do
        if threat.hazard and (not threat.instance or threat.instance.Parent) then table.insert(snapshots, threat) end
    end
    local active = State.activeMotion
    local motion = active and {action = active.action, age = now - active.started, velocity = active.velocity}
    local safetyParams = threatWorldParams(root)
    simulateBalls(snapshots, root.Position, .12, safetyParams, root.AssemblyLinearVelocity)
    local clearance, cause = safetyClearance(snapshots, root.Position, root.AssemblyLinearVelocity, motion)
    State.safetyChecks += 1
    State.emergencyClearance = clearance
    if clearance >= 1.2 then State.criticalLatch = false end
    if needsEmergency(clearance, State.lastCritical, State.criticalLatch, now - State.lastEmergency) then
        State.lastEmergency, State.lastCritical, State.criticalLatch = now, clearance, true
        State.emergencyReplans += 1
        State.emergencyCause = cause
        State.replanRequested, State.blockedUntil = true, 0
        State.steering, State.activeMotion, State.followupAt = nil, nil, nil
        State.inputEpoch += 1 -- Also cancels a delayed jump/dash callback.
        for key in pairs(State.held) do pcall(keyrelease, key) end
        table.clear(State.held)
        restoreFacing()
    end
    State.safetyMs = (os.clock() - started) * 1000
end

local function jumpAvailability(humanoid, character, now, airborne)
    if not airborne then
        State.airSince = nil; State.airUsed = 0
    elseif not State.airSince then State.airSince = now end
    local normalized = State.mobility.active and Tags:HasTag(character, "Downed")
    if not Config.jump or now - State.lastJump < .22 or Tags:HasTag(character, "FreezeTagFrozen") then return false, false end
    if not normalized and ((humanoid.UseJumpPower and humanoid.JumpPower <= 0)
        or (not humanoid.UseJumpPower and humanoid.JumpHeight <= 0)
        or not humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping) or Tags:HasTag(character, "Downed")) then return false, false end
    if not airborne then return true, false end
    local freefall = humanoid:GetState() == Enum.HumanoidStateType.Freefall or normalized
    local available = Config.doubleJump and State.airUsed == 0 and freefall
        and now - (State.airSince or now) >= .2
    return available, available
end

-- Lava
local function lavaSnapshots(root, now)
    local result = {}
    for part, data in pairs(State.lavaBodies) do
        if not part:IsDescendantOf(workspace) then State.lavaBodies[part] = nil; continue end
        local top = part.Position.Y + part.Size.Y * .5
        local elapsed = now - data.time
        if elapsed > .02 then data.rise = data.rise * .65 + math.clamp((top - data.top) / elapsed, 0, 12) * .35 end
        if data.rise > .08 then data.risingSeen = true end
        data.top, data.time = top, now
        if not Config.lava or part.Transparency >= .98 or part.CFrame.UpVector.Y < .9 then continue end
        local q = part.CFrame:PointToObjectSpace(root.Position)
        local distance = math.max(0, math.abs(q.X) - part.Size.X * .5, math.abs(q.Z) - part.Size.Z * .5)
        if distance > 120 or top > root.Position.Y + 40 or root.Position.Y - top > 150 then continue end
        table.insert(result, {instance = part, hazard = "Lava", frame = part.CFrame,
            halfX = part.Size.X * .5, halfZ = part.Size.Z * .5, level = top, rise = data.rise,
            standingHeight = State.standingHeight, distance = distance, risingSeen = data.risingSeen})
    end
    table.sort(result, function(a, b) return a.distance < b.distance end)
    while #result > 8 do table.remove(result) end
    State.lavaZones, State.lavaLevel, State.lavaRise = result, nil, 0
    for _, zone in ipairs(result) do
        State.lavaLevel = math.max(State.lavaLevel or -math.huge, zone.level)
        State.lavaRise = math.max(State.lavaRise, zone.rise)
    end
    local states = game:GetService("ReplicatedStorage"):FindFirstChild("ReplicatedStates")
    local mode = states and states:FindFirstChild("Gamemode")
    local modeName = mode and string.lower(tostring(mode.Value)) or ""
    local lavaMode = string.find(modeName, "lava", 1, true) ~= nil or string.find(modeName, "magma", 1, true) ~= nil
    local risingFloor = false
    for _, zone in ipairs(result) do
        if zone.risingSeen and zone.halfX >= 15 and zone.halfZ >= 15 and zone.distance < 10 then risingFloor = true end
    end
    State.lavaActive = #result > 0 and State.arena ~= nil and Tags:HasTag(Player.Character, "Playing") and (lavaMode or risingFloor)
    if not State.lavaActive then
        State.lavaGoal, State.lavaSafeFloor = nil, nil
        State.lavaLastProgressY, State.lavaStalled, State.lavaCandidateCount = nil, false, 0
    end
    return result
end

local function platformTop(part)
    return part.Position.Y + part.Size.Y * .5
end

local function platformArea(part)
    return math.max(0, part.Size.X) * math.max(0, part.Size.Z)
end

local function platformPoint(part, from, inset)
    inset = inset or 1.25
    local p = part.CFrame:PointToObjectSpace(from)
    local hx, hz = math.max(0, part.Size.X * .5 - inset), math.max(0, part.Size.Z * .5 - inset)
    return part.CFrame:PointToWorldSpace(Vector3.new(math.clamp(p.X, -hx, hx), part.Size.Y * .5, math.clamp(p.Z, -hz, hz)))
end

local function platformGap(a, b)
    local dx = math.max(0, math.abs(a.point.X - b.point.X) - a.hx - b.hx)
    local dz = math.max(0, math.abs(a.point.Z - b.point.Z) - a.hz - b.hz)
    return math.sqrt(dx * dx + dz * dz)
end

local function lavaReachEstimate(humanoid, jumpPower, doublePower, doubleAvailable)
    local gravity = math.max(1, workspace.Gravity)
    local firstAir = 2 * jumpPower / gravity
    local secondAir = doubleAvailable and doublePower / gravity * 1.45 or 0
    local airWindow = math.clamp(firstAir + secondAir, .28, 1.45)
    return math.clamp(humanoid.WalkSpeed * airWindow * 1.08 + 3.5, 8, 74)
end

local function highestReachable(nodes, climb, reach)
    local visited, parent, hops, queue = {[1] = true}, {}, {[1] = 0}, {1}
    local baseY, best, bestScore, cursor = nodes[1].point.Y, 1, 0, 1
    while cursor <= #queue do
        local index = queue[cursor]; cursor += 1
        for nextIndex = 2, #nodes do
            if visited[nextIndex] then continue end
            local current, candidate = nodes[index], nodes[nextIndex]
            local rise = candidate.point.Y - current.point.Y
            if rise < -.05 or rise > climb then continue end
            local verticalCost = math.clamp(math.max(0, rise) / math.max(1, climb), 0, .7)
            local edgeReach = reach * (1 - verticalCost * .35)
            if platformGap(current, candidate) > edgeReach then continue end
            visited[nextIndex], parent[nextIndex] = true, index
            hops[nextIndex] = (hops[index] or 0) + 1
            table.insert(queue, nextIndex)
            local totalRise = candidate.point.Y - baseY
            local area = math.max(1, candidate.area or candidate.hx * 2 * candidate.hz * 2)
            local score = totalRise > .25
                and (100 + totalRise * 8 + math.min(area, 900) * .012 - hops[nextIndex] * .35)
                or (math.min(area, 900) * .012 - hops[nextIndex] * .5 - (candidate.distance or 0) * .02)
            if score > bestScore then bestScore, best = score, nextIndex end
        end
    end
    local first = best
    while parent[first] and parent[first] ~= 1 do first = parent[first] end
    return first, best
end

local function updateLavaGoal(root, humanoid, ground, airborne, now)
    if not State.lavaActive then
        State.lavaGoal, State.lavaLastProgressY, State.lavaStalled = nil, nil, false
        return
    end
    if not ground then return end
    local currentPart = ground.Instance
    local currentTop = currentPart:IsA("BasePart") and platformTop(currentPart) or ground.Position.Y
    if not State.lavaLastProgressY then
        State.lavaLastProgressY, State.lavaLastProgressAt = currentTop, now
    elseif currentTop > State.lavaLastProgressY + 1.15 then
        State.lavaLastProgressY, State.lavaLastProgressAt, State.lavaStalled = currentTop, now, false
    elseif not airborne and now - State.lavaLastProgressAt > 1.5 then
        State.lavaStalled = true
    end
    if State.lavaGoal and State.lavaGoal.part and not State.lavaGoal.part:IsDescendantOf(workspace) then State.lavaGoal = nil end
    if State.lavaGoal and State.lavaGoal.part == currentPart then
        State.lavaGoal, State.lavaGoalLockUntil = nil, -100
        State.lavaLastProgressY, State.lavaLastProgressAt, State.lavaStalled = currentTop, now, false
    end
    if State.lavaGoal and airborne then return end
    if State.lavaGoal and now < State.lavaGoalLockUntil and not State.lavaStalled then return end
    if now - State.platformClock < (State.lavaStalled and .15 or .35) then return end
    State.platformClock = now
    local map = State.arena
    if not map then return end
    local gravity = math.max(1, workspace.Gravity)
    local jumpPower = humanoid.UseJumpPower and humanoid.JumpPower or math.sqrt(2 * gravity * humanoid.JumpHeight)
    local doublePower = 50
    local singleHeight = jumpPower * jumpPower / (2 * gravity)
    local doubleHeight = Config.doubleJump and doublePower * doublePower / (2 * gravity) or 0
    local climb = math.max(1, singleHeight + doubleHeight - .65)
    local reach = lavaReachEstimate(humanoid, jumpPower, doublePower, Config.doubleJump)
    local nodes = {{part = currentPart, point = ground.Position, hx = 0, hz = 0, distance = 0, area = 0}}
    if currentPart:IsA("BasePart") then
        nodes[1].point = currentPart.Position + Vector3.new(0, currentPart.Size.Y * .5, 0)
        nodes[1].hx, nodes[1].hz, nodes[1].area = currentPart.Size.X * .5, currentPart.Size.Z * .5, platformArea(currentPart)
    end
    local candidates = {}
    local minWidth = State.lavaStalled and 3.5 or 4.25
    local maxDistance = State.lavaStalled and 170 or 140
    for _, part in ipairs(map:GetDescendants()) do
        if not part:IsA("BasePart") or not part.CanCollide or not part.Anchored or part.CFrame.UpVector.Y <= .97
            or part == currentPart or State.lavaBodies[part] or part.Size.X < minWidth or part.Size.Z < minWidth then continue end
        local top = platformTop(part)
        if top < currentTop - .05 or top <= (State.lavaLevel or -math.huge) + 1.15 or top > currentTop + climb * 6 then continue end
        local landing = platformPoint(part, root.Position)
        local flatDistance = Vector3.new(landing.X - root.Position.X, 0, landing.Z - root.Position.Z).Magnitude
        if flatDistance > maxDistance then continue end
        table.insert(candidates, {part = part, point = part.Position + Vector3.new(0, part.Size.Y * .5, 0),
            hx = part.Size.X * .5, hz = part.Size.Z * .5, distance = flatDistance, area = platformArea(part), rise = top - currentTop})
    end
    table.sort(candidates, function(a, b)
        if math.abs(a.rise - b.rise) > 1 then return a.rise > b.rise end
        if math.abs(a.area - b.area) > 8 then return a.area > b.area end
        return a.distance < b.distance
    end)
    State.lavaCandidateCount = #candidates
    for index = 1, math.min(80, #candidates) do table.insert(nodes, candidates[index]) end
    local first, best = highestReachable(nodes, climb, reach)
    local node = nodes[first]
    if first == 1 or not node or not node.part or not node.part:IsA("BasePart") then State.lavaGoal = nil; return end
    local bestNode = nodes[best]
    State.lavaGoal = {part = node.part, point = platformPoint(node.part, root.Position), highest = bestNode.point.Y, climb = true,
        rise = node.point.Y - currentTop, area = platformArea(node.part), finalArea = platformArea(bestNode.part), stalledRecovery = State.lavaStalled}
    State.lavaTargetRise, State.lavaTargetArea = State.lavaGoal.rise, State.lavaGoal.area
    State.lavaGoalLockUntil = now + (State.lavaStalled and .55 or 1.25)
end

local function lavaRoutePenalty(action, origin, velocity, horizon)
    if not State.lavaActive or not State.lavaGoal then return 0 end
    local goal = State.lavaGoal
    local point = origin + playerOffset(action, horizon, velocity, .045)
    local target = platformPoint(goal.part, point)
    local distance = Vector3.new(point.X - target.X, 0, point.Z - target.Z).Magnitude
    local distancePenalty = math.min(5, distance * .08)
    local riseBonus = math.clamp(math.max(0, goal.rise or 0) * .18, 0, 4)
    local areaBonus = math.clamp(math.sqrt(math.max(1, goal.area or 1)) * .08, 0, 2.2)
    local exactTargetBonus = action.goalPart == goal.part and 1.25 or 0
    return distancePenalty - riseBonus - areaBonus - exactTargetBonus
end

local function makePlatformJump(goal, origin, flight, jumpPower, doublePower, walkSpeed, doubleAvailable)
    local target = platformPoint(goal.part, origin)
    local delta = Vector3.new(target.X - origin.X, 0, target.Z - origin.Z)
    local distance = delta.Magnitude
    local plan = {name = "Jump", kind = "walk", direction = unitFlat(delta, ZERO), speed = walkSpeed,
        jump = true, jumpPower = jumpPower, flight = table.clone(flight), goalPart = goal.part, lavaClimb = true}
    plan.flight.floorOffset = target.Y + flight.standingHeight - origin.Y
    if landingTime(plan) == math.huge then
        if not doubleAvailable then return nil end
        plan.secondAt, plan.secondPower = .32, doublePower
        if landingTime(plan) == math.huge then return nil end
    end
    local requiredRise = math.max(0, target.Y + 1.35 - origin.Y)
    local discriminant = jumpPower * jumpPower - 2 * flight.gravity * requiredRise
    if discriminant >= 0 then plan.moveDelay = math.max(0, (jumpPower - math.sqrt(discriminant)) / flight.gravity - .06)
    elseif plan.secondAt then plan.moveDelay = math.max(.12, plan.secondAt + .04)
    else return nil end
    local available = landingTime(plan) - .045 - plan.moveDelay
    if distance > walkSpeed * math.max(0, available) and doubleAvailable and not plan.secondAt then
        plan.secondAt, plan.secondPower = .32, doublePower
        available = landingTime(plan) - .045 - plan.moveDelay
    end
    if distance > walkSpeed * math.max(0, available) or available <= .05 then return nil end
    plan.duration = distance / math.max(.1, walkSpeed)
    plan.horizon = math.max(.8, landingTime(plan) + .15)
    return plan
end

local function makePlatformContinuation(goal, origin, flight, walkSpeed)
    local target = platformPoint(goal.part, origin)
    local delta = Vector3.new(target.X - origin.X, 0, target.Z - origin.Z)
    local plan = {name = "MoveLavaLanding", kind = "walk", direction = unitFlat(delta, ZERO), speed = walkSpeed,
        flight = table.clone(flight), goalPart = goal.part, lavaClimb = true}
    plan.flight.floorOffset = target.Y + flight.standingHeight - origin.Y
    local available = landingTime(plan) - .045
    if available <= .02 or available == math.huge or delta.Magnitude > walkSpeed * available then return nil end
    plan.duration = delta.Magnitude / math.max(.1, walkSpeed)
    plan.horizon = math.max(.8, landingTime(plan) + .15)
    return plan
end

local function makePillarReturnActions(ground, origin, flight, jumpPower, walkSpeed, horizon)
    local result = {}
    if not ground or not ground.Instance or not ground.Instance:IsA("BasePart") then return result end
    local part = ground.Instance
    local top = platformTop(part)
    if top <= (State.lavaLevel or -math.huge) + 1.1 then return result end
    local baseFlight = table.clone(flight)
    baseFlight.floorOffset = top + flight.standingHeight - origin.Y
    local probe = {flight = baseFlight, jump = true, jumpPower = jumpPower}
    local airTime = landingTime(probe)
    if airTime == math.huge or airTime < .25 then return result end
    local duration = math.max(.45, math.min(horizon, airTime + .1))
    local turnAt = math.clamp(airTime * .34, .14, .30)
    for index = 0, 7 do
        local angle = index * math.pi / 4
        local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
        table.insert(result, {name = "LavaReturn" .. index, kind = "walk", direction = direction, nextDirection = -direction,
            turnAt = turnAt, speed = walkSpeed, duration = duration, jump = true, jumpPower = jumpPower, flight = table.clone(baseFlight),
            goalPart = part, lavaActive = true, minimumFloor = top, lavaReturn = true, walkBraking = State.airBraking})
    end
    return result
end


-- Engine
local function tickEngine()
    local now = os.clock()
    State.searchStarted, State.safetyEligible = nil, false
    local character = Player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if character ~= State.lastCharacter then
        if State.lastCharacter and State.lastPlaying then captureIncident("Character changed during round") end
        releaseKeys(); deactivateMobilityNormalizer(); State.lastCharacter = character
        table.clear(State.lastUsed)
        State.lastDirection = nil; State.previousFacing = nil; State.health = nil
        State.airSince = nil; State.airUsed = 1; State.lastJump = -100
        State.groundBraking, State.airBraking = 620, 145
        setupMobilityCapture(character)
    end
    if humanoid and State.health and humanoid.Health < State.health then
        State.damageEvents += 1
        State.extraMargin = math.min(1.5, State.extraMargin + .25)
    end
    if humanoid then State.health = humanoid.Health end
    if not root or not humanoid or humanoid.Health <= 0 then
        releaseKeys(); State.status = "Waiting for character"; return
    end
    if humanoid ~= State.watchedHumanoid then
        if State.deathConnection then State.deathConnection:Disconnect() end
        State.watchedHumanoid = humanoid
        State.deathConnection = humanoid.Died:Connect(function()
            State.deaths += 1; captureIncident("Humanoid.Died")
        end)
    end
    local playing = Tags:HasTag(character, "Playing")
    if State.lastPlaying and not playing then captureIncident("Round exit") end
    State.lastPlaying = playing
    updateArena(root)
    captureNormalMobility(character, humanoid, root, now)
    local balls = ballSnapshots(root, now)
    State.threats = #balls
    for _, hazard in ipairs(hazardSnapshots(root)) do table.insert(balls, hazard) end
    for _, laser in ipairs(laserSnapshots(root, now)) do table.insert(balls, laser) end
    for _, lava in ipairs(lavaSnapshots(root, now)) do table.insert(balls, lava) end
    State.safetyThreats, State.safetyTime = balls, now
    local downed = Tags:HasTag(character, "Downed")
    if downed ~= State.downed then
        releaseKeys()
        State.downed, State.mobilityChanges = downed, State.mobilityChanges + 1
        if downed then activateMobilityNormalizer(character, humanoid) else deactivateMobilityNormalizer() end
        State.blockedUntil, State.replanRequested = 0, true
    elseif downed and Config.normalizeDowned and not State.mobility.active then
        activateMobilityNormalizer(character, humanoid)
    end
    State.effects = downed and (State.mobility.active and "Downed: normalizer active" or "Downed: limited mobility")
        or Tags:HasTag(character, "Glued") and "Glued: reduced speed"
        or character:GetAttribute("HurtLoopRunning") == true and "HurtLoopRunning" or ""
    traceFrame(root, humanoid, balls, now)
    local motionState = humanoid:GetState()
    local airborne = humanoid.FloorMaterial == Enum.Material.Air
        or motionState == Enum.HumanoidStateType.Jumping or motionState == Enum.HumanoidStateType.Freefall
        or motionState == Enum.HumanoidStateType.FallingDown
    local canJump, double = jumpAvailability(humanoid, character, now, airborne)
    if not Config.auto then State.status = "Auto dodge off"; return end
    if Config.onlyRound and not Tags:HasTag(character, "Playing") then State.status = "Waiting for round"; releaseKeys(); return end
    local ragdolled = motionState == Enum.HumanoidStateType.Physics or motionState == Enum.HumanoidStateType.Ragdoll
    if Tags:HasTag(character, "HumanShield")
        or Tags:HasTag(character, "FreezeTagFrozen") or root.Anchored or (ragdolled and not State.mobility.active) then
        State.status = "Movement unavailable"; releaseKeys(); return
    end
    if not isrbxactive() or Input:GetFocusedTextBox() then
        State.status = "Paused: focus Roblox and close text input"; releaseKeys(); return
    end
    State.safetyEligible = true
    local center = Config.centerAvoid and not State.lavaActive and Tags:HasTag(character, "Playing") and State.center or nil
    local nearCenter = center and State.centerDistance < State.centerRadius
    if #balls == 0 and not nearCenter and not State.activeMotion then State.status = "No nearby threats"; return end
    if now < State.blockedUntil and (now - State.lastDecisionTime < .06
        or not imminentCrossing(balls, root.Position, root.AssemblyLinearVelocity)) then return end
    local upgrades = Player:FindFirstChild("Upgrades")
    local dashes = upgrades and upgrades:FindFirstChild("Dashes")
    local amount = dashes and tonumber(dashes.Value) or 0
    local effective = math.min(amount, 60) + math.max(0, amount - 60) * .5
    local airSpeed, speed = 50 + effective, (airborne and 50 or 120) + effective
    if Tags:HasTag(character, "Shrunk") and not airborne then speed *= .6 end
    local right = unitFlat(root.CFrame.RightVector, Vector3.xAxis)
    local front = unitFlat(root.CFrame.LookVector, -Vector3.zAxis)
    if State.previousFacing and front:Dot(State.previousFacing) < .94 then State.cameraTurnUntil = now + .12 end
    State.previousFacing = front
    local walkSpeed = availableWalkSpeed(character, humanoid.WalkSpeed)
    local velocity = root.AssemblyLinearVelocity
    local flatVelocity = Vector3.new(velocity.X, 0, velocity.Z)
    local exclude = {character}
    for part in pairs(State.balls) do table.insert(exclude, part) end
    for object in pairs(State.hazards) do table.insert(exclude, object) end
    for part in pairs(State.lasers) do table.insert(exclude, part) end
    for part in pairs(State.lavaBodies) do table.insert(exclude, part) end
    for _, p in ipairs(Players:GetPlayers()) do if p.Character then table.insert(exclude, p.Character) end end
    local params = geometryParams(exclude, root.CollisionGroup)
    local bounceParams = threatWorldParams(root)
    local ground = workspace:Raycast(root.Position, Vector3.new(0, -45, 0), params)
    if ground and not airborne then State.standingHeight = math.clamp(root.Position.Y - ground.Position.Y, 1.5, 5) end
    if ground and not airborne and State.lavaActive then State.lavaSafeFloor = ground.Position.Y end
    updateLavaGoal(root, humanoid, ground, airborne, now)
    local lavaClimb = State.lavaActive and State.lavaGoal and State.lavaGoal.climb
    local flight = {gravity = math.max(1, workspace.Gravity), vy = airborne and velocity.Y or 0,
        floorOffset = ground and math.min(0, ground.Position.Y + State.standingHeight - root.Position.Y) or -30,
        standingHeight = State.standingHeight}
    local horizon = math.min(1.35, Config.horizon + math.min(.5, math.max(0, State.threats - 1) * .07))
    local jumpUpgrade = upgrades and upgrades:FindFirstChild("Jump")
    local jumpAmount = jumpUpgrade and tonumber(jumpUpgrade.Value) or 0
    local jumpEffective = math.min(jumpAmount, 60) + math.max(0, jumpAmount - 60) * .5
    local jumpPower = double and (50 + jumpEffective / 3)
        or (humanoid.UseJumpPower and humanoid.JumpPower or math.sqrt(2 * flight.gravity * humanoid.JumpHeight))
    local platformPlan, platformContinuation
    if lavaClimb and airborne then
        platformContinuation = makePlatformContinuation(State.lavaGoal, root.Position, flight, walkSpeed)
        if platformContinuation then horizon = math.max(horizon, math.min(2, platformContinuation.horizon)) end
    end
    if lavaClimb and canJump then
        platformPlan = makePlatformJump(State.lavaGoal, root.Position, flight, jumpPower, 50 + jumpEffective / 3,
            walkSpeed, not airborne and Config.doubleJump)
        if platformPlan then
            platformPlan.double = double
            horizon = math.max(horizon, math.min(2, platformPlan.horizon))
        elseif not airborne then
            State.lavaGoal, State.lavaGoalLockUntil = nil, -100
            State.lavaStalled, State.platformClock = true, -100
            lavaClimb = false
        end
    end
    if canJump then
        horizon = math.max(horizon, math.min(1.6, landingTime({flight = flight, jump = true, jumpPower = jumpPower}) + .12))
    elseif airborne then horizon = math.max(horizon, math.min(1.6, landingTime({flight = flight}) + .1)) end
    State.searchStarted = os.clock()
    local steps, dt = simulateBalls(balls, root.Position, horizon, bounceParams, flatVelocity)
    State.maxUncertainty = 0
    for _, ball in ipairs(balls) do
        if not ball.hazard then
            local divergence = (ball.linear[steps + 1] - ball.curve[steps + 1]).Magnitude
            for _, entry in ipairs(ball.ensemble or {}) do
                if entry.path and entry.path[steps + 1] then
                    divergence = math.max(divergence, (ball.linear[steps + 1] - entry.path[steps + 1]).Magnitude)
                end
            end
            State.maxUncertainty = math.max(State.maxUncertainty, uncertaintyAt(ball, horizon, divergence))
        end
    end
    local stay = {kind = "stay", coast = not airborne and humanoid.MoveDirection.Magnitude < .1, flight = airborne and flight or nil}
    if State.steering and now >= State.steering.start and now < State.steering.finish then
        local steering = State.steering
        local turned = steering.turnAt and now >= steering.turnAt
        stay = {kind = "walk", direction = turned and steering.nextDirection or steering.direction, speed = walkSpeed,
            duration = steering.finish - now, flight = airborne and flight or nil, latency = 0,
            nextDirection = not turned and steering.nextDirection or nil,
            turnAt = not turned and steering.turnAt and steering.turnAt - now or nil}
    elseif flatVelocity.Magnitude > walkSpeed + 3 then
        stay = {kind = "drift", braking = airborne and State.airBraking or State.groundBraking,
            flight = airborne and flight or nil, tail = State.steering and State.steering.direction,
            tailAt = State.steering and math.max(0, State.steering.start - now), walkSpeed = walkSpeed}
    end
    stay.walkBraking = airborne and State.airBraking or State.groundBraking
    local prepare = Config.positioning and Config.walk and State.targeted > 0
        and not airborne and not State.lavaActive and now - State.lastPreparation > .65
    local checkExit = Config.positioning and not State.lavaActive
        and (State.targeted > 0 or State.threats >= 4)
    stay.checkExit, stay.arena, stay.walkSpeed = checkExit, State.baseplate, walkSpeed
    local margin = Config.margin + State.extraMargin + (now < State.cameraTurnUntil and .35 or 0)
    local baseScore, impact, baseClearance, _, baseMetrics = pathScore(stay, balls, root.Position, flatVelocity, steps, dt, margin)
    State.hardSafety = Config.hardSafety and impact ~= math.huge and impact < .22
        and (State.predictionConfidence < .72 or State.maxUncertainty > 2 or State.implicitTargeted > 0 or State.bouncePredictions > 0)
    if State.hardSafety then
        State.hardSafetyTrips += 1
        margin += .4
        baseScore, impact, baseClearance, _, baseMetrics = pathScore(stay, balls, root.Position, flatVelocity, steps, dt, margin)
    end
    State.currentClearance, State.currentTimeToImpact = baseClearance, impact
    baseScore -= centerPenalty(stay, root.Position, flatVelocity, horizon, center, State.centerRadius)
    baseScore -= lavaRoutePenalty(stay, root.Position, flatVelocity, horizon)
    if Config.positioning and not State.lavaActive then
        baseScore -= edgePenalty(stay, root.Position, flatVelocity, horizon, State.baseplate)
    end
    if not environmentClear(stay, root.Position, flatVelocity, steps, dt, params) then
        baseScore, baseClearance, impact, baseMetrics.impact = -math.huge, 0, 0, 0
    end
    if impact == math.huge and not nearCenter and not lavaClimb and not prepare then State.status = "Paths clear"; return end
    local actions = {
        {name = "Left", kind = "dash", direction = -right, speed = speed, tail = -right, walkSpeed = walkSpeed},
        {name = "Right", kind = "dash", direction = right, speed = speed, tail = right, walkSpeed = walkSpeed},
        {name = "Forward", kind = "dash", direction = front, speed = speed, tail = front, walkSpeed = walkSpeed},
    }
    local available = {Left = ready("Left", now), Right = ready("Right", now), Forward = ready("Forward", now)}
    if Config.walk or Config.orient then
        local count = Config.refine and 16 or 8
        for index = 0, count - 1 do
            local angle = index * math.pi * 2 / count
            local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
            if Config.walk then table.insert(actions, {name = "Move" .. index, kind = "walk",
                angle = angle, direction = direction, speed = walkSpeed, duration = .3}) end
            if Config.orient then
                local name = chooseDashKey(direction, front, available)
                if name then table.insert(actions, {name = name, kind = "dash", orient = true,
                    angle = angle, direction = direction, speed = speed, tail = direction, walkSpeed = walkSpeed}) end
            end
        end
    end
    if lavaClimb and Config.walk then
        local goalPoint = platformPoint(State.lavaGoal.part, root.Position)
        table.insert(actions, {name = "MoveLava", kind = "walk", direction = unitFlat(goalPoint - root.Position, ZERO),
            speed = walkSpeed, duration = .3})
    end
    local best, bestScore, bestClearance, bestMetrics = nil, -math.huge, -math.huge, nil
    local walkResults, allWalkResults, countedAngles, evaluatedAngles = {}, {}, {}, {}
    State.anglesTested, State.plansTested = 0, 0
    local function evaluate(action)
        action.horizon, action.airborne = horizon, airborne
        action.walkBraking = airborne and State.airBraking or State.groundBraking
        action.checkExit, action.arena = checkExit, State.baseplate
        action.walkSpeed = walkSpeed
        if action.kind == "dash" then
            action.latency = .015
            action.braking = (airborne or action.jump) and State.airBraking or State.groundBraking
        end
        action.lavaActive = State.lavaActive
        action.minimumFloor = State.lavaSafeFloor
        if not action.goalPart then action.flight = (airborne or action.jump) and flight or nil end
        if not ready(action.name, now) then return end
        if action.kind == "dash" and State.pendingDash and now - State.pendingDash.started < .14 then return end
        if action.kind == "dash" and impact == math.huge then return end
        if action.kind == "dash" and not action.orient and now < State.cameraTurnUntil and impact > .15 then return end
        if action.kind == "dash" and not Config.walk then action.tail = nil end
        if action.angle then
            local angleKey = math.floor((action.angle % (math.pi * 2)) * 10000 + .5)
            local family = action.kind .. ":" .. tostring(angleKey)
            if not action.jump and evaluatedAngles[family] then return end
            if not action.jump then evaluatedAngles[family] = true end
            if not countedAngles[angleKey] then countedAngles[angleKey] = true; State.anglesTested += 1 end
        end
        State.plansTested += 1
        State.totalPlansEvaluated += 1
        local score, predictedImpact, clearance, openings, metrics = pathScore(action, balls, root.Position, flatVelocity, steps, dt, margin, bestClearance >= 1.05, bestMetrics)
        if not metrics then return end
        if State.hardSafety then
            local robustFloor = action.bounceRisk and 1.12 or 1.06
            if clearance < robustFloor and bestClearance >= robustFloor then return end
            if predictedImpact ~= math.huge and predictedImpact < .16 and bestClearance >= 1 then return end
        end
        action.openings, action.metrics, action.predictedImpact = openings, metrics, predictedImpact
        score -= reversalPenalty(action.direction, State.lastDirection, now - State.lastDecisionTime, impact < .16)
        if State.lastDirection and now - State.lastDecisionTime < .4 then
            score -= math.max(0, 1 - action.direction:Dot(State.lastDirection)) * .08
        end
        score -= centerPenalty(action, root.Position, flatVelocity, horizon, center, State.centerRadius)
        score -= lavaRoutePenalty(action, root.Position, flatVelocity, horizon)
        if Config.positioning and not State.lavaActive then
            score -= edgePenalty(action, root.Position, flatVelocity, horizon, State.baseplate)
        end
        if action.kind == "dash" and impact > .35 then score -= .35 end
        if action.jump then score -= double and .06 or (Config.moderateJump and .22 or .1) end
        if action.kind == "walk" then score -= .01 end
        if action.angle and not action.jump then table.insert(allWalkResults, {action = action, score = score, clearance = clearance, metrics = metrics}) end
        local competitive = preferRoute(score, clearance, bestScore, bestClearance, metrics, bestMetrics)
        if (competitive or (action.angle and not action.jump))
            and environmentClear(action, root.Position, flatVelocity, steps, dt, params) then
            if action.angle and not action.jump then table.insert(walkResults, {action = action, score = score, clearance = clearance, metrics = metrics}) end
            if not competitive then return end
            best, bestScore, bestClearance, bestMetrics = action, score, clearance, metrics
        end
    end
    for _, action in ipairs(actions) do evaluate(action) end
    if Config.refine and (Config.walk or Config.orient) then
        table.sort(walkResults, function(a, b) return preferRoute(a.score, a.clearance, b.score, b.clearance, a.metrics, b.metrics) end)
        table.sort(allWalkResults, function(a, b) return preferRoute(a.score, a.clearance, b.score, b.clearance, a.metrics, b.metrics) end)
        local seeds = {}
        local source = #walkResults > 0 and walkResults or allWalkResults
        for index = 1, math.min(3, #source) do seeds[index] = source[index].action end
        if #allWalkResults > 0 then table.insert(seeds, allWalkResults[1].action) end
        for _, seed in ipairs(seeds) do
            local angle = seed.angle
            for _, step in ipairs({math.pi / 16, math.pi / 32, math.pi / 64}) do
                for _, sign in ipairs({-1, 1}) do
                    local refined = angle + sign * step
                    local candidate = table.clone(seed)
                    candidate.angle = refined
                    candidate.direction = Vector3.new(math.cos(refined), 0, math.sin(refined))
                    if candidate.kind == "dash" then
                        candidate.name = chooseDashKey(candidate.direction, front, available)
                        candidate.tail = candidate.direction
                    end
                    evaluate(candidate)
                end
                if best and best.angle and best.kind == seed.kind then angle = best.angle end
            end
        end
    end
    if Config.walk and (State.threats >= 2 or State.hazardCount > 0) then
        table.sort(walkResults, function(a, b) return preferRoute(a.score, a.clearance, b.score, b.clearance, a.metrics, b.metrics) end)
        local tested = 0
        for _, route in ipairs(table.clone(walkResults)) do
            if route.action.kind ~= "dash" then continue end
            for _, sign in ipairs({-1, 0, 1}) do
                local candidate = table.clone(route.action)
                candidate.angle = nil
                candidate.tail = Vector3.new(-candidate.direction.Z, 0, candidate.direction.X) * sign
                evaluate(candidate)
            end
            tested += 1
            if tested >= 2 then break end
        end
    end
    if canJump and shouldConsiderJump(bestClearance, impact, State.targeted, State.threats,
        lavaClimb or (State.laserCount > 0 and impact < .75), double, landingTime(stay)) then
        local vertical = {name = "Jump", kind = "walk", direction = unitFlat(flatVelocity, ZERO),
            speed = math.min(walkSpeed, flatVelocity.Magnitude), duration = horizon, jump = true, jumpPower = jumpPower, double = double}
        evaluate(vertical)
        local jumpActions = table.clone(actions)
        if best and best.angle then table.insert(jumpActions, best) end
        for _, action in ipairs(jumpActions) do
            local jumping = table.clone(action)
            jumping.jump, jumping.jumpPower, jumping.double = true, jumpPower, double
            jumping.duration = horizon
            if jumping.kind == "dash" then jumping.speed = airSpeed end
            evaluate(jumping)
        end
    end
    local lavaBeam = lavaClimb and (State.lavaStalled or State.threats >= 2 or State.implicitTargeted > 0)
    if Config.positioning and Config.walk and (not lavaClimb or lavaBeam)
        and (prepare or State.threats >= 2 or State.lavaStalled or State.implicitTargeted > 0) then
        local beamActions = {}
        for _, action in ipairs(actions) do
            if ready(action.name, now) and (action.kind ~= "dash" or not State.pendingDash) then table.insert(beamActions, action) end
        end
        if best and best.jump then table.insert(beamActions, table.clone(best)) end
        if flatVelocity.Magnitude > walkSpeed + 3 then
            table.insert(beamActions, {name = "MoveDrift", kind = "drift", direction = unitFlat(flatVelocity, front),
                braking = airborne and State.airBraking or State.groundBraking, flight = airborne and flight or nil})
        end
        local seeds = continuationSeeds(beamActions, balls, root.Position, flatVelocity, steps, dt, margin)
        for _, seed in ipairs(seeds) do
            for _, turn in ipairs({0, math.pi / 4, -math.pi / 4, math.pi / 2, -math.pi / 2, math.pi}) do
                local candidate = table.clone(seed)
                candidate.angle = nil
                local direction = CFrame.Angles(0, turn, 0):VectorToWorldSpace(seed.direction)
                if seed.kind == "walk" then
                    candidate.name, candidate.duration, candidate.turnAt = "MovePrepared", horizon, .3
                    candidate.nextDirection = direction
                elseif seed.kind == "dash" then candidate.tail = direction
                else
                    candidate.followAt = .24
                    candidate.follow = {kind = "walk", direction = direction, speed = walkSpeed, duration = horizon, walkBraking = seed.braking}
                end
                evaluate(candidate)
            end
            if not prepare or impact < math.huge then
                local futureKeys = table.clone(available)
                if seed.kind == "dash" then futureKeys[seed.name] = false end
                for _, turn in ipairs({math.pi / 2, -math.pi / 2}) do
                    local direction = CFrame.Angles(0, turn, 0):VectorToWorldSpace(seed.direction)
                    local key = Config.orient and chooseDashKey(direction, front, futureKeys)
                    if not key then continue end
                    local candidate = table.clone(seed)
                    candidate.angle, candidate.followAt = nil, .28
                    candidate.follow = {kind = "dash", direction = direction, speed = (airborne or seed.jump) and airSpeed or speed,
                        braking = (airborne or seed.jump) and State.airBraking or State.groundBraking,
                        tail = direction, walkSpeed = walkSpeed, latency = .015, name = key}
                    evaluate(candidate)
                end
            end
            if seed.jump and not airborne and Config.doubleJump then
                local candidate = table.clone(seed)
                candidate.angle = nil
                candidate.secondAt, candidate.secondPower = math.max(.45, jumpPower / flight.gravity + .18), 50 + jumpEffective / 3
                if candidate.secondAt < horizon - .2 then evaluate(candidate) end
            end
        end
        if best and best.nextDirection then
            local seed = table.clone(best)
            for _, turnAt in ipairs({.2, .45}) do
                local candidate = table.clone(seed); candidate.turnAt = turnAt; evaluate(candidate)
            end
        end
    end
    if State.lavaActive and ground and not airborne and canJump
        and (State.targeted > 0 or State.threats >= 2 or State.lavaStalled or State.implicitTargeted > 0) then
        for _, candidate in ipairs(makePillarReturnActions(ground, root.Position, flight, jumpPower, walkSpeed, horizon)) do
            State.lavaReturnPlans += 1
            evaluate(candidate)
        end
    end
    if platformContinuation then evaluate(platformContinuation) end
    if platformPlan then evaluate(platformPlan) end
    local preparing = impact == math.huge and prepare and not nearCenter and not lavaClimb
    local replace = best and shouldReplace(bestScore, bestClearance, bestMetrics, baseScore, baseClearance, baseMetrics, State.emergencyPlanning)
    if preparing and best then replace = replace and preparationImproves(bestClearance, bestMetrics, baseMetrics) end
    if best and replace then
        local key, enum = keyInfo(best.name)
        local label = best.kind ~= "dash" and "Reposition" or (enum and enum.Name or best.name)
        if best.name == "Jump" then label = "Vertical" end
        if best.lavaClimb then label = "Climb Platform" end
        if best.lavaReturn then label = "Pillar Return" end
        if impact == math.huge and prepare and not nearCenter then label = "Prepare Exit" end
        if best.jump then label = (best.double and "Double Jump + " or "Jump + ") .. label end
        State.lastAction = label
        if best.kind == "dash" and not key then State.status = "Unsupported input"; return end
        if pressAction(best) then
            State.currentClearance, State.currentTimeToImpact = bestClearance, best.predictedImpact
            State.planStages, State.exitSpace = (best.nextDirection or best.follow or best.secondAt or best.tail) and 2 or 1, best.openings or 0
            State.futureFreedom, State.largestExitArc = bestMetrics.futureFreedom, bestMetrics.largestExitArc
            State.exitClearance, State.edgeSafety = bestMetrics.exitClearance, bestMetrics.edgeSafety
            State.futureThreatDensity = bestMetrics.futureThreatDensity
            if State.planStages == 2 then State.stagedMoves += 1 end
            if impact == math.huge and prepare then State.preparationMoves += 1; State.lastPreparation = now end
            State.status = (bestClearance >= 1.05 and "Dodging: " or "No clear route: ") .. label
            table.insert(State.decisions, {t = now, action = label, threats = #balls, impact = impact,
                clearance = bestClearance, jump = best.jump == true, double = best.double == true,
                oriented = best.orient == true, direction = tostring(best.direction), tail = best.tail and tostring(best.tail),
                predictedImpact = best.predictedImpact, futureFreedom = bestMetrics.futureFreedom,
                safeExitCount = bestMetrics.safeExitCount, largestExitArc = bestMetrics.largestExitArc,
                planStages = State.planStages, continuation = best.follow and best.follow.kind,
                plansEvaluated = State.plansTested, predictionConfidence = State.predictionConfidence,
                implicitTargeted = State.implicitTargeted, bounceRisk = best.bounceRisk == true,
                hardSafety = State.hardSafety, lavaStalled = State.lavaStalled})
            if #State.decisions > 20 then table.remove(State.decisions, 1) end
        end
    else State.status = impact < math.huge and "Threat: no better route" or "Holding position" end
end


-- Tests
local function selfTest(includeWorld)
    local function ball(position, velocity)
        return {position = position, velocity = velocity, acceleration = ZERO, radius = 1.25}
    end
    local stay = {kind = "stay"}
    local left = {kind = "dash", direction = -Vector3.xAxis, speed = 120}
    local right = {kind = "dash", direction = Vector3.xAxis, speed = 120}
    local tests = {}
    local approaching = {ball(Vector3.new(0, 0, -25), Vector3.new(0, 0, 80))}
    local n, dt = simulateBalls(approaching, ZERO, 0.55)
    local baseline, impact = pathScore(stay, approaching, ZERO, ZERO, n, dt, 0.7)
    local dodge = pathScore(left, approaching, ZERO, ZERO, n, dt, 0.7)
    tests.approachingDetected = impact < math.huge
    tests.lateralImproves = dodge > baseline
    local receding = {ball(Vector3.new(0, 0, -25), Vector3.new(0, 0, -80))}
    n, dt = simulateBalls(receding, ZERO, 0.55)
    local _, awayImpact = pathScore(stay, receding, ZERO, ZERO, n, dt, 0.7)
    tests.recedingIgnored = awayImpact == math.huge
    local multiple = {ball(Vector3.new(0, 0, -25), Vector3.new(0, 0, 80)), ball(Vector3.new(-13, 0, -25), Vector3.new(0, 0, 80))}
    n, dt = simulateBalls(multiple, ZERO, 0.55)
    local ls = pathScore(left, multiple, ZERO, ZERO, n, dt, 0.7)
    local rs = pathScore(right, multiple, ZERO, ZERO, n, dt, 0.7)
    tests.multiballAvoidsBlockedSide = rs > ls
    local stablePrediction = {uncertaintyGrowth = .15, predictionConfidence = .95}
    local unstablePrediction = {uncertaintyGrowth = 1.4, accelerationVariance = 80, predictionError = 1.2}
    tests.uncertaintyGrowsWithHorizon = uncertaintyAt(unstablePrediction, 1) > uncertaintyAt(unstablePrediction, .1) + 1
    tests.stableBallHasNarrowerCorridor = uncertaintyAt(stablePrediction, 1) < uncertaintyAt(unstablePrediction, 1)
    local learner: any = {position = ZERO, velocity = Vector3.zAxis * 60, acceleration = ZERO}
    learnThreat(learner, Vector3.zAxis * 3, Vector3.zAxis * 60, nil, .05, 10, false, 60)
    local confident = learner.predictionConfidence
    learnThreat(learner, Vector3.zAxis * 3, Vector3.zAxis * 60, nil, .05, 10.1, true, 60)
    tests.targetChangeReducesConfidence = learner.predictionConfidence < confident
    local countBefore = learner.samples
    learnThreat(learner, Vector3.xAxis * 500, Vector3.xAxis * 900, nil, .05, 10.2, false, 60)
    tests.lagSpikeExcludedFromLearning = learner.samples == countBefore
    local mild = {acceleration = ZERO, maxSpeed = 60, homingStrength = 1, maxAcceleration = 80}
    local aggressive = {acceleration = ZERO, maxSpeed = 60, homingStrength = 7, maxAcceleration = 240}
    local mildPoint = advanceThreat(mild, ZERO, Vector3.zAxis * 60, Vector3.xAxis * 30, .2, .2)
    local aggressivePoint = advanceThreat(aggressive, ZERO, Vector3.zAxis * 60, Vector3.xAxis * 30, .2, .2)
    tests.learnedHomingChangesPrediction = aggressivePoint.X > mildPoint.X + 2
    tests.criticalImpactAlwaysUnlocksJump = shouldConsiderJump(2, .13, 0, 1, false, false, .5)
    local closing, closestTime, closest = implicitThreatMetrics(Vector3.new(0, 0, -30), Vector3.new(0, 0, 100), ZERO, ZERO, 1.25)
    tests.implicitConvergenceDetected = closing > 90 and closestTime < .4 and closest < 1
    tests.bounceReflectionTurnsVerticalVelocity = reflectThreatVelocity(Vector3.new(0, -40, 0), Vector3.yAxis, .6).Y > 20
    tests.sweptFastCrossing = segmentDistance(Vector3.new(-10, 0, 0), Vector3.new(10, 0, 0)) < 0.01
    local overhead = {ball(Vector3.new(0, 30, -25), Vector3.new(0, 0, 80))}
    n, dt = simulateBalls(overhead, ZERO, 0.55)
    local _, overheadImpact = pathScore(stay, overhead, ZERO, ZERO, n, dt, 0.7)
    tests.overheadIgnored = overheadImpact == math.huge
    tests.reversalDiscouraged = reversalPenalty(Vector3.xAxis, -Vector3.xAxis, 0.2, false)
        > reversalPenalty(Vector3.xAxis, Vector3.xAxis, 0.2, false)
    tests.emergencyCanReverse = reversalPenalty(Vector3.xAxis, -Vector3.xAxis, 0.2, true)
        < reversalPenalty(Vector3.xAxis, -Vector3.xAxis, 0.2, false)
    local trap = {ball(Vector3.new(8, -2, 0), ZERO)}
    trap[1].radius = 3
    n, dt = simulateBalls(trap, ZERO, 0.8)
    local toward = pathScore(right, trap, ZERO, ZERO, n, dt, 0.7)
    local away = pathScore(left, trap, ZERO, ZERO, n, dt, 0.7)
    tests.trapRouteAvoided = away > toward
    local savedUsed = table.clone(State.lastUsed)
    local testNow = os.clock()
    State.lastUsed.Left, State.lastUsed.Right, State.lastUsed.Forward = testNow, testNow, testNow
    tests.dashCooldownsRespected = not ready("Left", testNow) and not ready("Right", testNow) and not ready("Forward", testNow)
    tests.walkAvailableDuringCooldown = ready("Move0", testNow)
    State.lastUsed = savedUsed
    local dense = {
        ball(Vector3.new(0, 0, -25), Vector3.new(0, 0, 80)),
        ball(Vector3.new(-12, 0, -20), Vector3.new(0, 0, 55)),
        ball(Vector3.new(-20, 0, 6), Vector3.new(15, 0, -5)),
        ball(Vector3.new(0, 25, 0), ZERO),
        ball(Vector3.new(20, 0, 25), Vector3.new(0, 0, 50)),
    }
    n, dt = simulateBalls(dense, ZERO, 1.1)
    tests.fiveBallsChooseOpenSide = pathScore(right, dense, ZERO, ZERO, n, dt, 0.7)
        > pathScore(left, dense, ZERO, ZERO, n, dt, 0.7)
    local grazing = {ball(Vector3.new(6, 0, -20), Vector3.new(0, 0, 80))}
    n, dt = simulateBalls(grazing, ZERO, .6)
    local _, smallImpact = pathScore(stay, grazing, ZERO, ZERO, n, dt, .7)
    grazing[1].radius = 5
    local _, largeImpact = pathScore(stay, grazing, ZERO, ZERO, n, dt, .7)
    tests.largeBallGrazingDetected = smallImpact == math.huge and largeImpact < math.huge
    local fullImpulse = playerOffset(right, .8, ZERO, 0).Magnitude
    tests.groundImpulseMatchesObservedRange = fullImpulse >= 11 and fullImpulse <= 12.5
    local measuredGround = {kind = "dash", direction = Vector3.xAxis, speed = 121}
    local measuredAir = {kind = "dash", direction = Vector3.xAxis, speed = 51, airborne = true}
    tests.groundBrakingMatchesInputTrace = math.abs(playerOffset(measuredGround, .14, ZERO, 0).X - 10.886) < .4
    tests.airBrakingMatchesInputTrace = math.abs(playerOffset(measuredAir, .14, ZERO, 0).X - 5.873) < .4
    tests.airImpulseNotLimitedToSixStuds = playerOffset(measuredAir, .5, ZERO, 0).X > 8.5
    local reverseOffset = integrateDrive(Vector3.xAxis * 50, -Vector3.xAxis * 14, .1, 145)
    tests.reversalKeepsExistingMomentum = reverseOffset.X > 3
    local stopped = integrateDrive(Vector3.xAxis * 120, ZERO, 1, 620)
    tests.coastingUsesMeasuredBraking = math.abs(stopped.X - 120 * 120 / 1240) < .01
    local staged = {kind = "walk", direction = Vector3.xAxis, nextDirection = Vector3.zAxis,
        turnAt = .3, speed = 14, duration = 1, walkBraking = 620}
    tests.twoStageStartsWithFirstLeg = math.abs(playerOffset(staged, .2, ZERO, 0).Z) < .001
    tests.twoStageTurnsAfterFirstLeg = playerOffset(staged, .7, ZERO, 0).Z > 4
    local stagesReversed = table.clone(staged)
    stagesReversed.nextDirection = -Vector3.xAxis
    tests.secondLegRespectsInertia = playerOffset(stagesReversed, .31, ZERO, 0).X > playerOffset(stagesReversed, .3, ZERO, 0).X
    tests.urgentCrossingDetected = imminentCrossing({ball(Vector3.new(20, 0, 0), Vector3.new(-200, 0, 0))}, ZERO, ZERO)
    tests.urgentRecedingIgnored = not imminentCrossing({ball(Vector3.new(20, 0, 0), Vector3.new(200, 0, 0))}, ZERO, ZERO)
    local duplicates = {{hazard = "Fire", position = ZERO, velocity = ZERO, radius = 5},
        {hazard = "Fire", position = ZERO, velocity = ZERO, radius = 5},
        {hazard = "Fire", position = Vector3.xAxis * 20, velocity = ZERO, radius = 5},
        {hazard = "Glue", position = ZERO, velocity = ZERO, radius = 5}}
    tests.containedFireZonesMerge = #compactHazards(duplicates) == 3
    local openOneSide = exitOpenings({{position = -Vector3.xAxis * 8, velocity = Vector3.xAxis * 8, radius = 3.8, height = 4.8}})
    local surround = {}
    for i = 0, 7 do
        local d = Vector3.new(math.cos(i * math.pi / 4), 0, math.sin(i * math.pi / 4))
        table.insert(surround, {position = d * 6, velocity = -d * 10, radius = 3.8, height = 4.8})
    end
    tests.futureExitSpaceDistinguishesEncirclement = openOneSide > exitOpenings(surround)
    local _, _, openMetrics = exitOpenings({})
    local _, _, trappedMetrics = exitOpenings(surround)
    tests.futureFreedomUsesSixteenExits = openMetrics.safeExitCount == 16 and openMetrics.largestExitArc == 360
    tests.convergenceReducesFreedom = trappedMetrics.futureFreedom < openMetrics.futureFreedom - .3
    tests.encirclementHasGreaterFutureDensity = trappedMetrics.futureThreatDensity > openMetrics.futureThreatDensity
    local blockedArena = {CFrame = CFrame.new(), Size = Vector3.new(20, 1, 20)}
    local _, _, edgeMetrics = exitOpenings({}, Vector3.xAxis * 8, ZERO, {arena = blockedArena})
    tests.arenaEdgeRemovesExits = edgeMetrics.safeExitCount < 16 and edgeMetrics.edgeSafety < openMetrics.edgeSafety
    local unsafeSoon = {impact = .12, exposure = .3, futureFreedom = .8, futureThreatDensity = .1}
    local unsafeLater = {impact = .55, exposure = .4, futureFreedom = .5, futureThreatDensity = .3}
    tests.unsafeRouteBuysTimeBeforeClearance = preferRoute(-1, .87, 2, .91, unsafeLater, unsafeSoon)
    tests.unsafeTimeCannotDisplaceSafeRoute = not preferRoute(100, .87, -5, 1.1, unsafeLater, unsafeSoon)
    tests.unsafeComparatorIsAsymmetric = not preferRoute(2, .91, -1, .87, unsafeSoon, unsafeLater)
    local rankedUnsafe = {{s = 3, c = .91, m = unsafeSoon}, {s = 1, c = .87, m = unsafeLater},
        {s = 4, c = .89, m = unsafeLater}}
    table.sort(rankedUnsafe, function(a, b) return preferRoute(a.s, a.c, b.s, b.c, a.m, b.m) end)
    tests.unsafeComparatorSortsConsistently = rankedUnsafe[1].m == unsafeLater and rankedUnsafe[3].m == unsafeSoon
    tests.preparationRequiresRealImprovement = not preparationImproves(1.4, openMetrics, openMetrics)
        and preparationImproves(1.25, openMetrics, trappedMetrics)
    tests.continuityRejectsTinyScoreOscillation = not shouldReplace(2.1, 1.3, openMetrics, 2, 1.4, trappedMetrics, false)
    tests.continuityEscapesUnsafeCurrentRoute = shouldReplace(-4, 1.1, openMetrics, 20, .9, trappedMetrics, false)
    local comboFollow = {kind = "walk", direction = Vector3.zAxis, speed = 14, duration = .3,
        followAt = .28, follow = {kind = "dash", direction = Vector3.xAxis, speed = 120, latency = .015}}
    local crossfire = {
        {position = Vector3.new(-1.6274452209472656, 0, -65.63128662109375), velocity = Vector3.new(7.503993034362793, 0, 56.929481506347656), radius = 1.25, acceleration = ZERO, maxSpeed = 57.42190751228044, target = {position = ZERO, velocity = ZERO, localTarget = true}},
        {position = Vector3.new(-39.827117919921875, 0, 21.82379150390625), velocity = Vector3.new(93.13087463378906, 0, -35.59729766845703), radius = 1.25, acceleration = ZERO, maxSpeed = 99.70219235437324, target = {position = ZERO, velocity = ZERO, localTarget = true}},
        {position = Vector3.new(-41.940826416015625, 0, 10.220752716064453), velocity = Vector3.new(73.7582778930664, 0, -26.118270874023438), radius = 1.25, acceleration = ZERO, maxSpeed = 78.24607379474378, target = {position = ZERO, velocity = ZERO, localTarget = true}},
        {position = Vector3.new(-30.190950393676758, 0, -26.525976181030273), velocity = Vector3.new(47.13383865356445, 0, 37.56959533691406), radius = 1.25, acceleration = ZERO, maxSpeed = 60.27498123472034},
        {position = Vector3.new(-19.063751220703125, 0, -20.686508178710938), velocity = Vector3.new(48.468082427978516, 0, 44.24934005737305), radius = 2.5, acceleration = ZERO, maxSpeed = 65.62895027263674},
        {position = Vector3.new(9.37173080444336, 0, -11.408193588256836), velocity = Vector3.new(-50.54923629760742, 0, 47.42089080810547), radius = 1.25, acceleration = ZERO, maxSpeed = 69.31064659599866},
        {position = Vector3.new(-124.02400207519531, 0, 64.07028198242188), velocity = Vector3.new(84.70729064941406, 0, -43.99553298950195), radius = 1.25, acceleration = ZERO, maxSpeed = 95.4512038754479},
    }
    local escapePlan = {kind = "dash", direction = Vector3.new(0.9238795042037964, 0, 0.3826834261417389), speed = 120, braking = 620,
        latency = .015, walkSpeed = 14, tail = Vector3.new(0.9238795042037964, 0, 0.3826834261417389), followAt = .28,
        follow = {kind = "dash", direction = Vector3.new(-0.3826834559440613, 0, 0.9238795042037964), speed = 120, braking = 620,
            latency = .015, walkSpeed = 14, tail = Vector3.new(-0.3826834559440613, 0, 0.9238795042037964)}}
    local firstOnly = table.clone(escapePlan); firstOnly.follow = nil
    local cn, cdt = simulateBalls(crossfire, ZERO, 1.25)
    local _, _, singleClearance = pathScore(firstOnly, crossfire, ZERO, ZERO, cn, cdt, 1)
    local _, _, plannedClearance = pathScore(escapePlan, crossfire, ZERO, ZERO, cn, cdt, 1)
    tests.sevenBallCrossfireNeedsContinuation = singleClearance < 1.05 and plannedClearance >= 1.05
    tests.multipleHomingAnglesUsePlayerRoute = plannedClearance > singleClearance + .2
    tests.futureDashDoesNotOccurInFirstLeg = math.abs(playerOffset(comboFollow, .2, ZERO, .045).X) < .001
    local boundaries = routeTimes(comboFollow, 1.25)
    tests.geometryChecksContinuationBoundary = table.find(boundaries, comboFollow.followAt) ~= nil
        and table.find(boundaries, comboFollow.followAt + .06) ~= nil
    tests.walkThenDashUsesSharedPhysics = playerOffset(comboFollow, .5, ZERO, .045).X > 10
    local tailTurn = {kind = "dash", direction = Vector3.xAxis, speed = 50, braking = 145,
        tail = -Vector3.xAxis, walkSpeed = 14}
    tests.dashTailReversalKeepsMomentum = playerOffset(tailTurn, .26, ZERO, 0).X > playerOffset(tailTurn, .25, ZERO, 0).X
    local originallyClear = {ball(Vector3.new(18, 0, 0), Vector3.new(100, 0, 0))}
    local changedTrajectory = {ball(Vector3.new(18, 0, 0), Vector3.new(-140, 0, 0))}
    tests.safeTrajectoryCanBecomeCritical = safetyClearance(originallyClear, ZERO, ZERO) > 1.2
        and safetyClearance(changedTrajectory, ZERO, ZERO) < 1
    tests.pruningRejectsEarlierUnavoidableImpact = routeCannotWin(.8, .12, false, {impact = .55})
    tests.pruningPreservesPotentiallySafeRoute = not routeCannotWin(1.1, .12, false, {impact = .55})
    tests.pruningPreservesLaterImpactRoute = not routeCannotWin(.8, .6, false, {impact = .55})
    tests.pruningPreservesEqualTimeDifferentClearance = not routeCannotWin(.8, .55, false, {impact = .55})
    local unexpectedSideBall = {ball(Vector3.new(0, 0, 13), Vector3.new(0, 0, -100))}
    local expectedWalk = {kind = "walk", direction = Vector3.xAxis, speed = 14, duration = 1, latency = 0}
    local normalSafety = safetyClearance(unexpectedSideBall, ZERO, Vector3.xAxis * 14,
        {action = expectedWalk, age = .2, velocity = ZERO})
    local stoppedSafety = safetyClearance(unexpectedSideBall, ZERO, ZERO,
        {action = expectedWalk, age = .2, velocity = ZERO})
    tests.emergencyUsesObservedSlowdown = stoppedSafety < normalSafety
    tests.emergencyRequestsReplan = needsEmergency(safetyClearance(changedTrajectory, ZERO, ZERO), 20, false, 1)
    tests.emergencyKeepsStablePlan = not needsEmergency(safetyClearance(originallyClear, ZERO, ZERO), 20, false, 1)
    tests.emergencyDoesNotRepeatedlyReplanSameRisk = not needsEmergency(.8, .8, true, .2)
    tests.emergencyRespondsToWorseningRisk = needsEmergency(.5, .8, true, .2)
    tests.emergencyCannotAssumeFutureDashExecuted = safetyClearance(changedTrajectory, ZERO, ZERO,
        {action = comboFollow, age = .2, velocity = ZERO}) < 1
    for _, count in ipairs({1, 3, 5, 7}) do
        local converging = {}
        for i = 1, count do
            local angle = i * math.pi * 2 / count
            local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
            table.insert(converging, ball(direction * 15, -direction * 100))
        end
        tests["emergencyConvergence" .. count .. "Balls"] = safetyClearance(converging, ZERO, ZERO) < 1
        local hn, hdt = simulateBalls(converging, ZERO, .75)
        local _, first, clearance = pathScore(stay, converging, ZERO, ZERO, hn, hdt, .7)
        tests["predictionConvergence" .. count .. "Balls"] = first < .2 and clearance < 1
    end


    tests.brakingLearnsFromConsistentMotion = learnedBraking({1000, 1005, 995, 1001}, 620, false) > 840
    tests.brakingRejectsWallCollisionSpike = learnedBraking({5000, 5100, 5200}, 620, false) == 620
    tests.brakingIgnoresInsufficientSamples = learnedBraking({1000, 1000}, 620, false) == 620
    local shortDash = table.clone(measuredGround)
    shortDash.braking = 1100
    tests.brakingAdaptsTravelDistance = playerOffset(shortDash, .3, ZERO, 0).X < 7
    local homing = {ball(Vector3.new(8, 0, -20), Vector3.new(0, 0, 50))}
    homing[1].target = {position = ZERO, velocity = ZERO, localTarget = true}
    homing[1].maxSpeed = 80
    n, dt = simulateBalls(homing, ZERO, 1.05)
    local _, homingImpact = pathScore(stay, homing, ZERO, ZERO, n, dt, 0.7)
    tests.curvingThreatDetected = homingImpact < math.huge
    local flight = {gravity = 100, vy = 0, floorOffset = 0, standingHeight = 3}
    local jumping = {kind = "walk", direction = ZERO, speed = 0, duration = 1,
        jump = true, jumpPower = 35, flight = flight}
    local laser = {hazard = "Laser", frame = CFrame.new(0, -2, 0), pivot = Vector3.new(0, -2, 0),
        omega = Vector3.yAxis, velocity = ZERO, halfLength = 45, radius = .45, halfHeight = .3, axis = "X"}
    local laserOrigin = Vector3.new(20, 0, -10)
    local laserSteps, laserDt = simulateBalls({laser}, laserOrigin, .95)
    local groundScore, laserImpact = pathScore(stay, {laser}, laserOrigin, ZERO, laserSteps, laserDt, .6)
    local jumpScore, jumpImpact = pathScore(jumping, {laser}, laserOrigin, ZERO, laserSteps, laserDt, .6)
    local _, _, laserExits = exitOpenings({{laser = laser, time = 0, position = ZERO, velocity = ZERO,
        radius = 3, height = 3}}, Vector3.new(20, 0, 0), ZERO)
    tests.futureFreedomIncludesRotatingLaser = laserExits.safeExitCount < 16
    tests.rotatingLaserApproachDetected = laserImpact > .1 and laserImpact < .7
    tests.jumpClearsRotatingLaser = jumpScore > groundScore and jumpImpact == math.huge
    local stationary = table.clone(laser)
    stationary.omega = ZERO
    local _, stillImpact = pathScore(stay, {stationary}, laserOrigin, ZERO, laserSteps, laserDt, .6)
    tests.stationaryDistantLaserIgnored = stillImpact == math.huge
    local combo = {kind = "dash", direction = Vector3.xAxis, speed = 50, jump = true, jumpPower = 35,
        flight = flight, airborne = true}
    local comboPoint = playerOffset(combo, .3, ZERO, .045)
    tests.jumpDashHasVerticalAndLateralMotion = comboPoint.X > 1 and comboPoint.Y > 4
    local air = {kind = "stay", flight = {gravity = 100, vy = -15, floorOffset = -5, standingHeight = 3}}
    local lift = table.clone(jumping)
    lift.flight = air.flight; lift.jumpPower = 50
    tests.doubleJumpReversesDescent = playerOffset(lift, .2, ZERO, .045).Y > playerOffset(air, .2, ZERO, .045).Y + 5
    local boxed = {ball(Vector3.new(0, 0, -25), Vector3.new(0, 0, 80)),
        ball(Vector3.new(-5, -2, 0), ZERO), ball(Vector3.new(5, -2, 0), ZERO)}
    boxed[2].radius, boxed[3].radius = 2, 2
    n, dt = simulateBalls(boxed, ZERO, .95)
    local escapeJumpScore = pathScore(jumping, boxed, ZERO, ZERO, n, dt, .7)
    tests.jumpEscapesBallBetweenTraps = escapeJumpScore > pathScore(left, boxed, ZERO, ZERO, n, dt, .7)
        and escapeJumpScore > pathScore(right, boxed, ZERO, ZERO, n, dt, .7)
    local awayCenter = {kind = "walk", direction = Vector3.xAxis, speed = 14, duration = .3}
    local intoCenter = {kind = "walk", direction = -Vector3.xAxis, speed = 14, duration = .3}
    tests.centerPrefersOutward = centerPenalty(awayCenter, Vector3.new(4, 0, 0), ZERO, .8, ZERO, 12)
        < centerPenalty(intoCenter, Vector3.new(4, 0, 0), ZERO, .8, ZERO, 12)
    tests.centerDoesNotPenalizeOutside = centerPenalty(awayCenter, Vector3.new(30, 0, 0), ZERO, .8, ZERO, 12) == 0
    tests.safeRouteBeatsRiskyHigherScore = preferRoute(-5, 1.1, 10, .8)
    tests.riskyRouteCannotDisplaceSafeRoute = not preferRoute(10, .8, -5, 1.1)
    local savedModeration = Config.moderateJump
    Config.moderateJump = true
    tests.moderationKeepsSafeGroundRoute = not shouldConsiderJump(1.4, .3, 1, 1, false, false, .6)
    tests.moderationAllowsTrappedEscape = shouldConsiderJump(.7, .3, 1, 1, false, false, .6)
    tests.doubleJumpConsideredDuringCrowd = shouldConsiderJump(.8, 1.1, 3, 6, false, true, .5)
    tests.doubleJumpNotWastedWithoutThreat = not shouldConsiderJump(2, math.huge, 0, 0, false, true, .5)
    tests.lethalNearMissOutweighsAggregateScore = preferRoute(-10, .95, 5, .5)
    for _, name in ipairs({"Left", "Right", "Forward"}) do
        for index = 0, 7 do
            local angle = index * math.pi / 4 + math.pi / 16
            local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
            local frame = CFrame.lookAt(Vector3.new(7, 3, -2), Vector3.new(7, 3, -2) + dashLook(direction, name))
            local resulting = name == "Forward" and frame.LookVector or frame.RightVector * (name == "Left" and -1 or 1)
            tests["oriented" .. name .. index] = resulting:Dot(direction) > .999
        end
    end
    tests.orientedCooldownFallback = chooseDashKey(Vector3.xAxis, -Vector3.zAxis, {Forward = true}) == "Forward"
    tests.orientedCooldownExhaustion = chooseDashKey(Vector3.xAxis, -Vector3.zAxis, {}) == nil
    tests.orientedPreservesForwardWhenLateralReady = chooseDashKey(-Vector3.zAxis, -Vector3.zAxis, {Left = true, Forward = true}) == "Left"
    tests.moderationAllowsSpecialHazard = shouldConsiderJump(1.4, .5, 0, 0, true, false, .6)
    Config.moderateJump = savedModeration
    local lava = {hazard = "Lava", frame = CFrame.new(), halfX = 40, halfZ = 40,
        level = 0, rise = 1.5, standingHeight = 3}
    tests.lavaAtFeetDetected = lavaClearance(lava, Vector3.new(0, 3, 0), 0, .6) < 1
    tests.risingLavaAnticipated = lavaClearance(lava, Vector3.new(0, 5, 0), 0, .6) > 1
        and lavaClearance(lava, Vector3.new(0, 5, 0), 1, .6) < 1
    tests.outsideLavaFootprintSafe = lavaClearance(lava, Vector3.new(60, 3, 0), 0, .6) > 1
    local nodes = {{point = Vector3.new(0, 0, 0), hx = 3, hz = 3},
        {point = Vector3.new(9, 6, 0), hx = 3, hz = 3},
        {point = Vector3.new(18, 12, 0), hx = 3, hz = 3},
        {point = Vector3.new(8, 70, 0), hx = 3, hz = 3}}
    local firstStep, destination = highestReachable(nodes, 7, 5)
    tests.highestAccessibleUsesIntermediate = firstStep == 2 and destination == 3
    local raised = table.clone(jumping)
    raised.flight = table.clone(flight); raised.flight.floorOffset = 4
    tests.raisedLandingDoesNotTeleport = playerOffset(raised, 0, ZERO, .045).Y == 0
    tests.raisedLandingReachesHeight = math.abs(playerOffset(raised, landingTime(raised) + .02, ZERO, .045).Y - 4) < .01
    raised.flight.floorOffset = 14
    tests.unreachableSingleJumpRejected = landingTime(raised) == math.huge
    raised.secondAt, raised.secondPower = .32, 50
    tests.plannedDoubleReachesHigherPlatform = landingTime(raised) < 2
    local savedAir, savedUsedAir, savedLastJump = State.airSince, State.airUsed, State.lastJump
    local savedJump, savedDouble = Config.jump, Config.doubleJump
    local dummy = Instance.new("Model")
    local eligibilityOK = pcall(function()
        local h = {UseJumpPower = true, JumpPower = 35, GetStateEnabled = function() return true end,
            GetState = function() return Enum.HumanoidStateType.Freefall end}
        Config.jump, Config.doubleJump = true, true
        State.airSince, State.airUsed, State.lastJump = testNow - .25, 0, -100
        tests.doubleJumpAvailableAfterDelay = jumpAvailability(h, dummy, testNow, true)
        State.airSince = testNow - .1
        tests.doubleJumpNotTooEarly = not jumpAvailability(h, dummy, testNow, true)
        State.airSince, State.airUsed = testNow - .25, 1
        tests.doubleJumpNotRepeated = not jumpAvailability(h, dummy, testNow, true)
        State.airUsed, Config.doubleJump = 0, false
        tests.doubleJumpToggleRespected = not jumpAvailability(h, dummy, testNow, true)
        local savedNormalizer = State.mobility.active
        State.mobility.active = false
        Tags:AddTag(dummy, "Downed")
        Config.doubleJump = true
        tests.downedDisablesDoubleJump = not jumpAvailability(h, dummy, testNow, true)
        tests.downedDisablesImpulses = not impulsesAllowed(dummy)
        tests.downedRetainsSlowWalk = availableWalkSpeed(dummy, 14) == 6
            and horizontalOffset({kind = "walk", direction = Vector3.xAxis, speed = availableWalkSpeed(dummy, 14),
                duration = .3}, .3, ZERO, .045).X > 1
        State.mobility.active = true
        tests.alphaNormalizerRestoresImpulses = impulsesAllowed(dummy)
        tests.alphaNormalizerRestoresWalkProfile = availableWalkSpeed(dummy, 14) > 6
        tests.alphaNormalizerRestoresJump = jumpAvailability(h, dummy, testNow, true)
        Tags:AddTag(dummy, "Glued")
        tests.glueOverridesDownedSpeed = availableWalkSpeed(dummy, 14) == 1
        State.mobility.active = false
        Tags:RemoveTag(dummy, "Downed"); Tags:RemoveTag(dummy, "Glued")
        tests.mobilityRecoveryRestoresResources = impulsesAllowed(dummy) and availableWalkSpeed(dummy, 14) == 14
        State.mobility.active = savedNormalizer
    end)
    dummy:Destroy()
    State.airSince, State.airUsed, State.lastJump = savedAir, savedUsedAir, savedLastJump
    Config.jump, Config.doubleJump = savedJump, savedDouble
    tests.jumpEligibilityChecked = eligibilityOK
    if includeWorld then
        local fixtures = Instance.new("Folder")
        fixtures.Name = "BallReactionVerification"
        fixtures.Parent = workspace
        local made = {}
        local function makePart(name, size, position)
            local part = Instance.new("Part")
            part.Name, part.Size, part.Position = name, size, position
            part.Anchored = true
            part.CanTouch = false
            part.Transparency = 1
            part.Parent = fixtures
            table.insert(made, part)
            return part
        end
        local success, failure = pcall(function()
            local origin = Vector3.new(0, 15000, 0)
            makePart("Floor", Vector3.new(64, 1, 64), origin - Vector3.new(0, 3.5, 0))
            local params = RaycastParams.new()
            params.FilterType = Enum.RaycastFilterType.Include
            params.FilterDescendantsInstances = {fixtures}
            params.RespectCanCollide = true
            local walk = {kind = "walk", direction = Vector3.xAxis, speed = 14, duration = 0.22}
            tests.floorRouteAccepted = environmentClear(walk, origin, ZERO, 20, 0.04, params)
            local groupFixture = fixtures:FindFirstChild("Floor")
            local playerRoot = Player.Character and Player.Character:FindFirstChild("HumanoidRootPart")
            local group = playerRoot and playerRoot.CollisionGroup or "Default"
            local groupParams = geometryParams({fixtures}, group)
            groupParams.FilterType = Enum.RaycastFilterType.Include
            tests.geometryCopiesPlayerCollisionGroup = groupParams.CollisionGroup == group
            local physics = game:GetService("PhysicsService")
            for _, registered in ipairs(physics:GetRegisteredCollisionGroups()) do
                if not physics:CollisionGroupsAreCollidable("Default", registered.name)
                    and physics:CollisionGroupsAreCollidable(group, registered.name) then
                    groupFixture.CollisionGroup = registered.name
                    tests.proFloorHiddenFromDefaultReproduced = not environmentClear(walk, origin, ZERO, 20, .04, params)
                    tests.proFloorVisibleToPlayerAccepted = environmentClear(walk, origin, ZERO, 20, .04, groupParams)
                    groupFixture.CollisionGroup = "Default"
                    break
                end
            end
            local wall = makePart("Wall", Vector3.new(0.5, 8, 8), origin + Vector3.new(2.5, 0, 0))
            tests.wallRouteRejected = not environmentClear(walk, origin, ZERO, 20, 0.04, params)
            wall:Destroy()
            tests.edgeRouteRejected = not environmentClear(walk, origin + Vector3.new(31, 0, 0), ZERO, 20, 0.04, params)
            local outAndBack = {kind = "dash", direction = Vector3.xAxis, speed = 120, braking = 620,
                latency = .015, tail = Vector3.xAxis, walkSpeed = 14, followAt = .22,
                follow = {kind = "dash", direction = -Vector3.xAxis, speed = 120, braking = 620,
                    latency = .015, tail = -Vector3.xAxis, walkSpeed = 14}}
            tests.stageCannotLeaveFloorAndReturnBetweenSamples = not environmentClear(outAndBack,
                origin + Vector3.xAxis * 25, ZERO, 40, .04, params)

            local inertiaReturn = {kind = "walk", direction = Vector3.xAxis, speed = 14, duration = 1.25,
                turnAt = .3, nextDirection = Vector3.new(1, 0, 1).Unit}
            tests.inertialWalkCannotLeaveFloorAndReturn = not environmentClear(inertiaReturn,
                origin + Vector3.new(-29.23883, 0, 4.6133), Vector3.new(-49.78027, 0, 49.78032), 28, 1.25 / 28, params)
            local stageExtrema = routeTimes(outAndBack, 1.6, ZERO)
            local impulseBoundary = .22 + .015 + 120 / 620
            local foundBoundary = false
            for _, t in ipairs(stageExtrema) do if math.abs(t - impulseBoundary) < .001 then foundBoundary = true end end
            tests.continuationImpulseBrakingBoundaryChecked = foundBoundary
            local floor = fixtures:FindFirstChild("Floor")
            floor.CanQuery = false; floor.CanCollide = false
            local leftFloor = makePart("LeftFloor", Vector3.new(22, 1, 64), origin + Vector3.new(-21, -3.5, 0))
            local rightFloor = makePart("RightFloor", Vector3.new(38, 1, 64), origin + Vector3.new(13, -3.5, 0))
            local gapDash = {kind = "dash", direction = Vector3.xAxis, speed = 120, braking = 620, latency = .015}
            tests.groundHoleBetweenSamplesRejected = not environmentClear(gapDash,
                origin - Vector3.xAxis * 14, ZERO, 20, .04, params)
            leftFloor:Destroy(); rightFloor:Destroy(); floor.CanCollide = true; floor.CanQuery = true
            local afterLanding = table.clone(jumping)
            afterLanding.duration, afterLanding.speed, afterLanding.direction = 2, 14, Vector3.xAxis
            tests.floorRequiredAfterLanding = not environmentClear(afterLanding,
                origin + Vector3.xAxis * 22, ZERO, 40, .04, params)
            tests.jumpLandingAccepted = environmentClear(jumping, origin, ZERO, 24, .04, params)
            local ceiling = makePart("LowCeiling", Vector3.new(20, .5, 20), origin + Vector3.new(0, 4.5, 0))
            tests.jumpLowCeilingRejected = not environmentClear(jumping, origin, ZERO, 24, .04, params)
            ceiling:Destroy()
            local jumpAway = table.clone(jumping)
            jumpAway.direction, jumpAway.speed = Vector3.xAxis, 14
            tests.jumpOffEdgeRejected = not environmentClear(jumpAway, origin + Vector3.new(31, 0, 0), ZERO, 24, .04, params)
            local angle = math.rad(11.25)
            local normal = Vector3.new(-math.sin(angle), 0, math.cos(angle))
            local wallA = makePart("AngledWallA", Vector3.new(50, 6, .5), origin + normal * 1.8)
            local wallB = makePart("AngledWallB", Vector3.new(50, 6, .5), origin - normal * 1.8)
            wallA.CFrame = CFrame.new(wallA.Position) * CFrame.Angles(0, -angle, 0)
            wallB.CFrame = CFrame.new(wallB.Position) * CFrame.Angles(0, -angle, 0)
            local fineWalk = {kind = "walk", direction = Vector3.new(math.cos(angle), 0, math.sin(angle)), speed = 14, duration = .3}
            local coarseWalk = {kind = "walk", direction = Vector3.xAxis, speed = 14, duration = .3}
            tests.intermediateAngleFitsNarrowPassage = environmentClear(fineWalk, origin, ZERO, 20, .04, params)
                and not environmentClear(coarseWalk, origin, ZERO, 20, .04, params)
            wallA:Destroy(); wallB:Destroy()
            local floorParams = RaycastParams.new()
            floorParams.FilterType = Enum.RaycastFilterType.Include
            floorParams.FilterDescendantsInstances = {fixtures}
            floorParams.RespectCanCollide = true
            local bounceBall = {position = origin, velocity = Vector3.new(0, -40, 0), acceleration = ZERO, radius = 1.25}
            local _, reflectedVelocity, bounced = advanceThreatWorld(bounceBall, bounceBall.position, bounceBall.velocity, nil, .1, .1, floorParams, .6)
            tests.floorBouncePredicted = bounced and reflectedVelocity.Y > 0
            local platform = makePart("UpperPlatform", Vector3.new(10, 5, 10), origin + Vector3.new(10, -.5, 0))
            local tiny = makePart("TinyPlatform", Vector3.new(5.5, 1, 5.5), origin + Vector3.new(0, -2.5, 18))
            local tinyPoint = platformPoint(tiny, tiny.Position + Vector3.new(10, 0, 0))
            tests.lavaPlatformInsetExpanded = math.abs(tiny.CFrame:PointToObjectSpace(tinyPoint).X) > .9
            local fakeHumanoid = {WalkSpeed = 14}
            tests.lavaReachUsesAirTime = lavaReachEstimate(fakeHumanoid, 35, 50, true) > 11.2
            local plan = makePlatformJump({part = platform}, origin, flight, 35, 50, 14, true)
            tests.accessiblePlatformJumpPlanned = plan ~= nil and landingTime(plan) < 2
            if plan then tests.platformJumpPathClear = environmentClear(plan, origin, ZERO, 40, .04, params) end
            local descending = {gravity = 100, vy = -5, floorOffset = -8, standingHeight = 3}
            local continuation = makePlatformContinuation({part = platform}, origin + Vector3.new(8, 9, 0), descending, 14)
            tests.lavaLandingContinuesWithoutExtraJump = continuation ~= nil and not continuation.jump
            tiny:Destroy(); platform:Destroy()
            local lavaPart = makePart("RisingLava", Vector3.new(20, 1, 20), origin - Vector3.new(0, 4, 0))
            consider(lavaPart)
            tests.lavaPartIdentified = State.lavaBodies[lavaPart] ~= nil
            State.lavaBodies[lavaPart] = nil
            local banana = makePart("BananaModel", Vector3.one, origin)
            consider(banana)
            tests.bananaIdentified = State.hazards[banana] ~= nil
            local glue = makePart("GlueTrap", Vector3.one, origin)
            consider(glue)
            tests.glueIdentified = State.hazards[glue] ~= nil
            local variant = makePart("GenericPart", Vector3.one * 2.5, origin)
            variant.Shape = Enum.PartType.Ball
            variant.Color = Color3.new(0, 0, 1)
            local align = Instance.new("AlignPosition")
            align.Parent = variant
            local trail = Instance.new("Trail")
            trail.Parent = variant
            consider(variant)
            tests.genericNonRedBallIdentified = State.balls[variant] ~= nil
            local pending = ballSnapshots({Position = origin + Vector3.new(8, 0, 0)}, os.clock())
            local pendingSeen = false
            for _, snapshot in ipairs(pending) do
                if snapshot.instance == variant and snapshot.hazard == "Spawn" then pendingSeen = true end
            end
            tests.anchoredSpawningBallIncluded = pendingSeen
            local emitter = Instance.new("ParticleEmitter")
            emitter.Name = "FlamethrowerFire"
            emitter.Enabled = false
            emitter.Parent = glue
            consider(emitter)
            tests.fireEmitterIdentified = State.hazards[emitter] ~= nil
            State.hazards[emitter] = nil
            local laserPart = makePart("RotatingLaser", Vector3.new(50, .5, .5), origin)
            consider(laserPart)
            tests.namedLaserIdentified = State.lasers[laserPart] ~= nil
            State.lasers[laserPart] = nil
        end)
        for _, instance in ipairs(made) do State.balls[instance] = nil; State.hazards[instance] = nil end
        fixtures:Destroy()
        tests.fixtureCleanup = workspace:FindFirstChild("BallReactionVerification") == nil
        if not success then tests.worldFixtureError = false; State.lastError = tostring(failure) end
    end
    local passed, total = 0, 0
    for _, value in pairs(tests) do total += 1; if value then passed += 1 end end
    return {passed = passed, total = total, tests = tests}
end

local function stats()
    local held = 0
    for _ in pairs(State.held) do held += 1 end
    local costs = table.clone(State.planningSamples); table.sort(costs)
    local now, character = os.clock(), Player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    return {version = "1.8.9 betasync5378", status = State.status, auto = Config.auto,
        balls = State.threats, candidates = State.visibleCount or 0,
        observations = State.observations, nearest = State.nearest, actions = State.actions,
        lastAction = State.lastAction, error = State.lastError, frameMs = State.lastCost,
        heldKeys = held, alive = State.alive, hazards = State.hazardCount, effects = State.effects,
        reversals = State.reversals, mobilityChanges = State.mobilityChanges, downed = State.downed,
        mobilityNormalizer = {enabled = Config.normalizeDowned, active = State.mobility.active, reason = State.mobility.reason,
            restoredActions = State.mobility.restoredActions, capturedAnimations = State.mobility.capturedAnimations,
            calibrations = State.mobility.calibrations, entered = State.mobility.entered,
            normalWalkSpeed = State.mobility.normalWalkSpeed or State.mobility.profile.lastWalkSpeed,
            profile = State.mobility.profile},
        replay = {enabled = State.replay.enabled, recording = State.replay.recording, open = State.replay.open,
            frames = State.replay.count, events = #State.replay.events, incidents = #State.replay.incidents,
            recorded = State.replay.recorded, opened = State.replay.opened, exports = State.replay.exportCount,
            lastExportPath = State.replay.lastExportPath, seconds = State.replay.seconds, sampleHz = State.replay.sampleHz},
        p95PlanningMs = costs[math.max(1, math.ceil(#costs * .95))] or 0, planningCycles = State.planningCycles,
        clearance = State.currentClearance or 0, timeToImpact = State.currentTimeToImpact or math.huge,
        resources = {Left = ready("Left", now), Right = ready("Right", now), Forward = ready("Forward", now),
            impulsesAllowed = impulsesAllowed(character), airJumpUsed = State.airUsed,
            walkSpeed = humanoid and availableWalkSpeed(character, humanoid.WalkSpeed) or 0,
            jumpPower = humanoid and humanoid.JumpPower or 0, jumpEnabled = Config.jump, doubleJumpEnabled = Config.doubleJump},
        damageEvents = State.damageEvents, extraMargin = State.extraMargin,
        recentDecisions = State.decisions,
        steering = State.steering ~= nil, onlyRound = Config.onlyRound,
        lasers = State.laserCount, jumps = State.jumps, doubleJumps = State.doubles,
        jumpEnabled = Config.jump, doubleJumpEnabled = Config.doubleJump, centerAvoid = Config.centerAvoid,
        airJumpUsed = State.airUsed, spawning = State.spawning,
        deathsObserved = State.deaths, incident = State.incident and {reason = State.incident.reason, t = State.incident.t},
        targeted = State.targeted, implicitTargeted = State.implicitTargeted, anglesTested = State.anglesTested, refine = Config.refine, moderateJump = Config.moderateJump,
        collisionPredictions = State.collisionPredictions, bouncePredictions = State.bouncePredictions,
        hardSafety = State.hardSafety, hardSafetyTrips = State.hardSafetyTrips,
        orientedDashes = State.orientedDashes, orient = Config.orient, facingLocked = State.facing ~= nil,
        verifiedDashes = State.verifiedDashes, unconfirmedDashes = State.unconfirmedDashes,
        motionSamples = State.motionSamples, plansTested = State.plansTested,
        earlyRoundExits = State.earlyRoundExits,
        groundBraking = State.groundBraking, airBraking = State.airBraking,
        positioning = Config.positioning, preparationMoves = State.preparationMoves, planStages = State.planStages,
        targetChanges = State.targetChanges, mergedHazards = State.mergedHazards, futureOpenings = State.exitSpace,
        completedTurns = State.completedTurns, stagedMoves = State.stagedMoves,
        predictionConfidence = State.predictionConfidence, predictionError = State.predictionError,
        uncertainty = State.maxUncertainty, emergencyReplans = State.emergencyReplans, safetyChecks = State.safetyChecks,
        safetyMs = State.safetyMs, plannerHz = State.plannerHz, emergencyClearance = State.emergencyClearance, stageReplans = State.stageReplans,
        safeExitCount = State.exitSpace, largestExitArc = State.largestExitArc,
        exitClearance = State.exitClearance, futureFreedom = State.futureFreedom, edgeSafety = State.edgeSafety,
        futureThreatDensity = State.futureThreatDensity, totalPlansEvaluated = State.totalPlansEvaluated, planningMs = State.planningMs,
        lavaActive = State.lavaActive, lavaLevel = State.lavaLevel, lavaRise = State.lavaRise, lavaStalled = State.lavaStalled,
        lavaCandidateCount = State.lavaCandidateCount, lavaTargetRise = State.lavaTargetRise, lavaTargetArea = State.lavaTargetArea,
        lavaReturnPlans = State.lavaReturnPlans,
        lavaGoal = State.lavaGoal and {position = tostring(State.lavaGoal.point), highest = State.lavaGoal.highest, climb = State.lavaGoal.climb,
            rise = State.lavaGoal.rise, area = State.lavaGoal.area, stalledRecovery = State.lavaGoal.stalledRecovery},
        center = State.center and tostring(State.center), centerDistance = State.centerDistance, centerRadius = State.centerRadius,
        lastDirection = State.lastDirection and tostring(State.lastDirection)}
end

-- UI
local function buildUI()
    Fluent = loadstring(game:HttpGet("https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua"))()
    Window = Fluent:CreateWindow({
        Title = "Ball Reaction 1.8.9 betasync5378",
        SubTitle = "",
        TabWidth = 120,
        Size = UDim2.fromOffset(560, 430),
        Acrylic = true,
        Theme = "Dark",
        MinimizeKey = Enum.KeyCode.RightShift,
    })

    local main = Window:AddTab({Title = "Main", Icon = "shield"})
    local settings = Window:AddTab({Title = "Settings", Icon = "settings"})
    local debugTab = Window:AddTab({Title = "Debug", Icon = "bug"})

    StatusText = main:AddParagraph({Title = "Status", Content = "Ready"})
    AutoToggle = main:AddToggle("AutoDodge", {
        Title = "Auto Dodge",
        Default = Config.auto,
        Callback = function(value)
            Config.auto = value
            if not value then releaseKeys() end
        end,
    })
    main:AddParagraph({Title = "Keys", Content = "RightShift: menu/replay | F8: stop"})

    settings:AddSlider("Horizon", {
        Title = "Prediction Horizon",
        Default = Config.horizon,
        Min = 0.2,
        Max = 0.9,
        Rounding = 2,
        Callback = function(value) Config.horizon = value end,
    })
    settings:AddSlider("Margin", {
        Title = "Safety Margin",
        Default = Config.margin,
        Min = 0.1,
        Max = 3,
        Rounding = 1,
        Callback = function(value) Config.margin = value end,
    })
    settings:AddSlider("Range", {
        Title = "Detection Range",
        Default = Config.range,
        Min = 40,
        Max = 300,
        Rounding = 0,
        Callback = function(value) Config.range = value end,
    })
    settings:AddToggle("Jump", {
        Title = "Jump",
        Default = Config.jump,
        Callback = function(value) Config.jump = value; releaseKeys() end,
    })
    settings:AddToggle("DoubleJump", {
        Title = "Double Jump",
        Default = Config.doubleJump,
        Callback = function(value) Config.doubleJump = value end,
    })
    settings:AddToggle("Lava", {
        Title = "Lava Navigation",
        Default = Config.lava,
        Callback = function(value) Config.lava = value end,
    })
    settings:AddToggle("Lasers", {
        Title = "Laser Prediction",
        Default = Config.lasers,
        Callback = function(value) Config.lasers = value end,
    })
    settings:AddToggle("Round", {
        Title = "Round Only",
        Default = Config.onlyRound,
        Callback = function(value) Config.onlyRound = value end,
    })

    DebugStatusText = debugTab:AddParagraph({Title = "Recorder", Content = replaySummaryText()})
    debugTab:AddToggle("FreezeRecording", {
        Title = "Freeze Recording",
        Default = false,
        Callback = function(value) replaySetRecording(not value) end,
    })
    debugTab:AddButton({Title = "Replay 5 Minutes", Callback = function() openReplay(300) end})
    debugTab:AddButton({
        Title = "Export Trace",
        Callback = function()
            local encoded, path = replayExportDebugTrace()
            if DebugStatusText then
                DebugStatusText:SetDesc(encoded and ("Exported: " .. (path or "returned by controller"))
                    or ("Export failed: " .. tostring(path)))
            end
        end,
    })
    debugTab:AddButton({Title = "Clear Recording", Callback = clearReplay})

    Window:SelectTab(1)
end

local ok, err = pcall(buildUI)
if not ok then cleanup(); error("Failed to initialize Fluent: " .. tostring(err)) end

Controller.OnInvoke = function(command, value)
    if command == "stats" then return stats() end
    if command == "incident" then return State.incident or {reason = "No incident recorded"} end
    if command == "trace" then
        local result = {}
        local count = math.clamp(tonumber(value) or 10, 1, 80)
        for index = math.max(1, #State.trace - count + 1), #State.trace do table.insert(result, State.trace[index]) end
        return result
    end
    if command == "replay" then return openReplay(tonumber(value) or 300) end
    if command == "replay_close" then closeReplay(); return true end
    if command == "replay_clear" then clearReplay(); return true end
    if command == "replay_recording" then return replaySetRecording(value == true) end
    if command == "replay_export" then return replayExportDebugTrace() end
    if command == "debug_event" then return replayAddExplicitDebugEvent(value) end
    if command == "selftest" then return selfTest(value == true) end
    if command == "option" and type(value) == "table" then
        local allowed = {Round = true, Jump = true, DoubleJump = true, Lasers = true, Lava = true}
        if allowed[value.name] and type(value.value) == "boolean" then
            Fluent.Options[value.name]:SetValue(value.value)
            return stats()
        end
        return {error = "Unsupported option"}
    end
    if command == "destroy" then cleanup(); return true end
    if command == "auto" then AutoToggle:SetValue(value == true); return stats() end
    if command == "stop" then AutoToggle:SetValue(false); releaseKeys(); return stats() end
    return {error = "Unknown command"}
end

-- Runtime
connect(workspace.DescendantAdded, function(instance) consider(instance) end)
connect(workspace.DescendantRemoving, function(instance)
    State.balls[instance] = nil; State.hazards[instance] = nil; State.lasers[instance] = nil; State.lavaBodies[instance] = nil
end)
connect(Input.JumpRequest, function()
    local character = Player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if State.mobility.active and character and Tags:HasTag(character, "Downed") then
        performManualNormalizedJump()
        return
    end
    if humanoid then
        local airborne = humanoid:GetState() == Enum.HumanoidStateType.Freefall
        noteAnimationIntent(airborne and "DoubleJump" or "Jump", .3)
        if airborne and State.airSince and os.clock() - State.airSince >= .175 then State.airUsed = 1 end
    end
end)
connect(Input.InputBegan, function(input, processed)
    if State.replay.open and input.KeyCode == Enum.KeyCode.RightShift and not Input:GetFocusedTextBox() then
        closeReplay(); return
    end
    if input.KeyCode == Enum.KeyCode.F8 and not Input:GetFocusedTextBox() then
        AutoToggle:SetValue(false); releaseKeys()
    elseif not processed then
        local watched = {W = true, A = true, S = true, D = true, Q = true, E = true, R = true, Space = true, LeftShift = true}
        if watched[input.KeyCode.Name] then
            replayPushEvent(os.clock(), "input", "KeyDown " .. input.KeyCode.Name)
            local event = State.replay.events[#State.replay.events]
            event.data = {downed = State.downed, action = State.lastAction}
        end
        for _, name in ipairs({"Left", "Right", "Forward"}) do
            local vk, key = keyInfo(name)
            if input.KeyCode == key and not State.held[vk] then
                if State.mobility.active and Player.Character and Tags:HasTag(Player.Character, "Downed") then
                    performManualNormalizedDash(name)
                else
                    noteAnimationIntent(name, .3)
                    State.lastUsed[name] = os.clock()
                    local character = Player.Character
                    local root = character and character:FindFirstChild("HumanoidRootPart")
                    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                    if root and humanoid then
                        local direction = name == "Forward" and root.CFrame.LookVector
                            or root.CFrame.RightVector * (name == "Left" and -1 or 1)
                        markDash({name = name, direction = unitFlat(direction, Vector3.zAxis), speed = 120,
                            airborne = humanoid.FloorMaterial == Enum.Material.Air}, root, os.clock())
                    end
                end
            end
        end
    end
end)
connect(Input.InputEnded, function(input, processed)
    if processed then return end
    local watched = {W = true, A = true, S = true, D = true, Q = true, E = true, R = true, Space = true, LeftShift = true}
    if watched[input.KeyCode.Name] then replayPushEvent(os.clock(), "input", "KeyUp " .. input.KeyCode.Name) end
end)
connect(Input.WindowFocusReleased, releaseKeys)
RunService:BindToRenderStep("BallReactionWorldSteering", Enum.RenderPriority.Character.Value + 1, function(renderDt)
    local now = os.clock()
    State.safetyClock += renderDt
    if State.safetyClock >= 1 / 60 then
        State.safetyClock %= 1 / 60
        local success, failure = pcall(emergencyTick, now)
        if not success then State.lastError = tostring(failure); Config.auto = false; releaseKeys(); warn("Ball Reaction safety: " .. tostring(failure)) end
    end
    observeDash(now)
    mobilityNormalizerTick(now, renderDt)
    replayTick(now, renderDt)
    local facing = State.facing
    if facing then
        if not State.alive or now >= facing.finish or not Config.auto
            or not facing.root.Parent or facing.humanoid.Health <= 0 or not isrbxactive() or Input:GetFocusedTextBox() then
            restoreFacing()
        else facing.root.CFrame = CFrame.lookAt(facing.root.Position, facing.root.Position + facing.look) end
    end
    local steering = State.steering
    if not State.alive or not steering then return end
    if not Config.auto or not isrbxactive() or Input:GetFocusedTextBox() then
        State.steering = nil; return
    end
    if now > steering.finish then State.steering = nil; State.activeMotion = nil; return end
    if now < steering.start then return end
    local character = Player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local direction = steering.direction
    if steering.nextDirection and steering.turnAt and now >= steering.turnAt then
        direction = steering.nextDirection
        if not steering.turned then
            steering.turned = true
            State.completedTurns += 1
            State.lastDirection, State.lastDecisionTime = direction, now
        end
    end
    if humanoid and humanoid.Health > 0 then humanoid:Move(direction, false) end
end)
setupMobilityCapture(Player.Character)
rescan()
local accumulator, scanClock = 0, 0
connect(RunService.Heartbeat, function(dt)
    if not State.alive then return end
    if Fluent.Unloaded then cleanup(); return end
    accumulator += dt; scanClock += dt; State.uiClock += dt
    if State.followupAt and os.clock() >= State.followupAt then
        State.followupAt = nil
        State.replanRequested, State.blockedUntil = true, 0
        State.stageReplans += 1
    end
    State.plannerHz = State.planningMs > 12 and 20 or 30
    local plannerInterval = 1 / State.plannerHz
    if accumulator < plannerInterval and not State.replanRequested then return end
    accumulator %= plannerInterval
    State.emergencyPlanning, State.replanRequested = State.replanRequested, false
    local started = os.clock()
    local success, failure = pcall(function()
        if scanClock > 5 and not scanQueue then
            scanClock = 0; scanQueue = workspace:GetDescendants(); scanIndex = 1
        end
        scanSlice()
        tickEngine()
        if State.uiClock >= 0.3 then
            State.uiClock = 0
            StatusText:SetDesc(string.format("%s\nThreats %d | Hazards %d | Nearest %.1f\nAction %s | Moves %d | Damage %d\n%s\nLasers %d | Jumps %d | Doubles %d",
                State.status, State.threats, State.hazardCount, State.nearest, State.lastAction, State.actions,
                State.damageEvents, State.effects, State.laserCount, State.jumps, State.doubles))
            if DebugStatusText then DebugStatusText:SetDesc(replaySummaryText()) end
        end
    end)
    State.lastCost = (os.clock() - started) * 1000
    if State.searchStarted then
        State.planningMs = (os.clock() - State.searchStarted) * 1000
        State.planningCycles += 1
        table.insert(State.planningSamples, State.planningMs)
        if #State.planningSamples > 256 then table.remove(State.planningSamples, 1) end
    end
    if not success then
        State.lastError = tostring(failure); State.status = "Error: auto dodge paused"
        Config.auto = false; releaseKeys()
        warn("Ball Reaction: " .. tostring(failure))
        AutoToggle:SetValue(false)
    end
end)

print("Ball Reaction 1.8.9 betasync5378 ready.")
return {Destroy = cleanup, Stats = stats, SelfTest = selfTest}
end
