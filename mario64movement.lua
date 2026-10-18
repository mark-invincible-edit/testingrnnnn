--!nonstrict
--[[
	SUPER MARIO 64 CHARACTER CONTROLLER  (single self-contained LocalScript)
	Runs from ANY client-side location. It never touches the `script` object.

	Controls (rebindable in CONFIG):
		Space / A ............ Jump (chain 3 jumps while running for the triple jump)
		Left Ctrl / C / L2 ... Crouch (hold). Also: Dive, Ground Pound at apex, drop from ledge.
		Q / R2 ............... Ground Pound (anytime in the air)
		Run + Ctrl ........... Crouch slide -> press Jump while sliding for a Long Jump

	NOTE ON NETWORKING: the client owns its own character's physics, so changing
	Workspace.Gravity, Humanoid properties and HumanoidRootPart velocity here only
	affects the local player's simulation (and replicates through normal physics ownership).
	Sounds, the shadow and the smoke particles are created on the client, so only YOU see/hear them.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
while not player do
	Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
	player = Players.LocalPlayer
end

-- Shared table used to stop duplicate copies of this script from fighting each other.
local env = (type(getgenv) == "function" and getgenv()) or _G
if type(env.SM64_Cleanup) == "function" then
	pcall(env.SM64_Cleanup) -- tear down any previous copy before starting
end

local ORIGINAL_GRAVITY = Workspace.Gravity
local controllerCounter = 0

--==============================================================================
-- 1. PHYSICS & STATE CONFIGURATION
--==============================================================================
local CONFIG = {
	----------------------------------------------------------------------------
	-- World physics.
	-- Rising phase uses GRAVITY directly. Peak height of a jump = v^2 / (2 * g).
	-- Falling phase is accelerated by FALL_GRAVITY_MULTIPLIER, so Mario floats up
	-- and drops heavily (SM64 feel):  effective fall gravity = 120 * 1.6 = 192.
	----------------------------------------------------------------------------
	GRAVITY = 120,                    -- studs/s^2 (Roblox default is 196.2)
	FALL_GRAVITY_MULTIPLIER = 1.6,    -- extra pull while descending
	LONG_JUMP_FALL_MULTIPLIER = 1.0,  -- long jumps stay floaty so they travel far
	MAX_FALL_SPEED = 130,             -- terminal velocity (studs/s)

	----------------------------------------------------------------------------
	-- Ground movement
	----------------------------------------------------------------------------
	RUN_SPEED = 22,                   -- Humanoid.WalkSpeed while standing/running
	CROUCH_SPEED = 6,                 -- Humanoid.WalkSpeed while crouching
	COYOTE_TIME = 0.1,                -- seconds of "no floor" before we count as airborne

	----------------------------------------------------------------------------
	-- Air control (SM64: facing is locked in the air and steering is tiny).
	-- Horizontal velocity is preserved from takeoff. The stick only adds a small
	-- acceleration, and total speed can never exceed max(takeoff speed, DRIFT_MAX_SPEED).
	-- Set AIR_DRIFT_ACCEL = 0 for a completely locked trajectory.
	----------------------------------------------------------------------------
	AIR_DRIFT_ACCEL = 6,              -- studs/s^2 of stick influence (6 over 0.7 s ~ 4 studs/s)
	AIR_DRIFT_MAX_SPEED = 8,          -- speed cap for standing jumps (so you can drift a bit)

	----------------------------------------------------------------------------
	-- Jump chain. Humanoid.JumpPower = launch speed v (studs/s).
	-- With g = 120: apex heights = 46^2/240 = 8.8, 52^2/240 = 11.3, 68^2/240 = 19.3 studs
	-- (a ratio of about 1 : 1.3 : 2.2, close to SM64's single/double/triple jump).
	----------------------------------------------------------------------------
	JUMP_POWERS = { 46, 52, 68 },
	JUMP_FORWARD_BOOST = { 0, 3, 7 }, -- extra forward speed added on jump 1/2/3 (studs/s)
	-- SM64 gives ~5 frames (0.17 s at 30 fps) after landing to continue the chain.
	-- Roblox runs at 60 fps with input latency, so we allow a slightly wider window.
	TRIPLE_JUMP_WINDOW = 1,        -- max seconds between landing and the next jump
	TRIPLE_JUMP_MIN_SPEED = 1,       -- must still be running (>= ~55% of RUN_SPEED)
	JUMP_BUFFER_TIME = 0.15,          -- pressing Jump this soon BEFORE landing still counts

	----------------------------------------------------------------------------
	-- Crouch slide & long jump
	----------------------------------------------------------------------------
	SLIDE_MIN_SPEED = 14,             -- pressing crouch while faster than this starts a slide
	SLIDE_FRICTION = 16,              -- studs/s^2 lost while sliding (22 -> 11 takes ~0.7 s)
	SLIDE_END_SPEED = 6,              -- slide ends (becomes a crouch) below this speed
	LONG_JUMP_MIN_SPEED = 11,         -- slide must still be at least this fast to long-jump
	LONG_JUMP_POWER = 40,             -- low, flat arc: apex = 40^2 / 240 = 6.7 studs
	LONG_JUMP_SPEED_MULT = 2.0,       -- horizontal launch speed = slide speed * this ...
	LONG_JUMP_MIN_OUT = 28,           -- ... clamped to this range
	LONG_JUMP_MAX_OUT = 44,
	LONG_JUMP_LAND_SPEED_KEEP = 0.6,  -- fraction of speed kept if you land holding crouch

	----------------------------------------------------------------------------
	-- Dive
	----------------------------------------------------------------------------
	DIVE_BOOST = 14,                  -- dive speed = current flat speed + this ...
	DIVE_MIN_SPEED = 28,              -- ... clamped to this range
	DIVE_MAX_SPEED = 44,
	DIVE_UP_VELOCITY = 14,            -- small upward pop so the dive arcs instead of dropping
	BELLY_SLIDE_MIN_SPEED = 8,        -- landing a dive faster than this starts a belly slide
	BELLY_SLIDE_KEEP = 0.9,           -- fraction of dive speed kept on landing
	BELLY_SLIDE_FRICTION = 26,        -- belly slides stop faster than crouch slides

	----------------------------------------------------------------------------
	-- Ground pound
	----------------------------------------------------------------------------
	GROUND_POUND_APEX_WINDOW = 12,    -- crouch while |vertical speed| <= this (studs/s) = apex.
	-- With g = 120 that is a ~0.2 s window around the peak.
	GROUND_POUND_HOVER_TIME = 0.35,   -- spin-in-place time before slamming
	GROUND_POUND_SPEED = 110,         -- downward slam speed
	GROUND_POUND_RECOVERY = 0.4,      -- frozen time after impact
	GROUND_POUND_SHAKE_TIME = 0.25,   -- camera shake duration on impact
	GROUND_POUND_SHAKE_MAGNITUDE = 0.6,

	----------------------------------------------------------------------------
	-- Ledge grab (all heights measured relative to HumanoidRootPart)
	----------------------------------------------------------------------------
	LEDGE_REACH = 2.8,                -- how far in front we look for a wall
	LEDGE_WALL_RAY_HEIGHT = 0.3,      -- height of the "is there a wall?" ray
	LEDGE_MIN_TOP = 0.6,              -- lowest ledge top we can grab (above HRP)
	LEDGE_MAX_TOP = 3.4,              -- highest ledge top we can grab (above HRP)
	LEDGE_MIN_FALL_SPEED = 2,         -- must be falling at least this fast to grab
	LEDGE_HANG_DEPTH = 2.3,           -- HRP hangs this far BELOW the ledge top (tune to your anim)
	LEDGE_HANG_DISTANCE = 1.15,       -- HRP hangs this far OUT from the wall face
	LEDGE_JUMP_HEIGHT = 6.4,          -- rise of the pull-up: v = sqrt(2 * g * h)
	LEDGE_CLEAR_HEIGHT = 3.2,         -- once HRP is this far above the top, push forward
	LEDGE_FORWARD_SPEED = 12,         -- forward speed once we've cleared the lip
	LEDGE_REGRAB_COOLDOWN = 0.6,      -- seconds before a ledge can be grabbed again

	----------------------------------------------------------------------------
	-- Locomotion animation overrides (Idle / Walk / Run / Jump / Fall / Land).
	-- IDs go in LOCOMOTION_ANIMATION_IDS below.
	----------------------------------------------------------------------------
	WALK_RUN_THRESHOLD = 13,          -- horizontal speed below this plays Walk, above plays Run
	LOCO_MIN_ANIM_SPEED = 0.6,        -- Walk/Run playback speed is scaled by real speed,
	LOCO_MAX_ANIM_SPEED = 1.8,        --   clamped to this range
	LAND_ANIM_TIME = 0.25,            -- how long the Land animation owns the body (if it has no length)
	-- false: your animations play at higher priority than Roblox's defaults, and anything you
	--        leave unset falls back to the default animation.
	-- true:  Roblox's "Animate" script is turned off completely. Only YOUR animations play,
	--        so states without an animation show no animation at all.
	DISABLE_DEFAULT_ANIMATE = false,

	----------------------------------------------------------------------------
	-- Drop shadow (flat cylinder that snaps to the nearest surface below you)
	----------------------------------------------------------------------------
	SHADOW_ENABLED = true,
	SHADOW_SIZE = 3.4,                -- diameter in studs when standing on the ground
	SHADOW_THICKNESS = 0.08,
	SHADOW_COLOR = Color3.new(0, 0, 0),
	SHADOW_MAX_DISTANCE = 300,        -- how far below you the shadow can be found
	SHADOW_FADE_DISTANCE = 60,        -- height (above ground) at which the shadow is smallest/faintest
	SHADOW_MIN_SCALE = 0.45,          -- smallest size multiplier (at SHADOW_FADE_DISTANCE)
	SHADOW_NEAR_TRANSPARENCY = 0.35,  -- transparency when on the ground
	SHADOW_FAR_TRANSPARENCY = 0.8,    -- transparency at SHADOW_FADE_DISTANCE

	----------------------------------------------------------------------------
	-- Smoke / dust VFX (ParticleEmitters at your feet).
	-- Set any count or rate to 0 to turn that single effect off.
	----------------------------------------------------------------------------
	VFX_ENABLED = true,
	VFX_TEXTURE = "rbxasset://textures/particles/smoke_main.dds", -- swap in your own smoke texture id
	VFX_COLOR = Color3.fromRGB(220, 220, 220), -- base smoke colour
	VFX_FLOOR_TINT = 0.5,             -- 0 = always VFX_COLOR, 1 = fully tinted by the floor's colour
	VFX_SCALE = 1,                    -- multiplies every particle's size
	VFX_DUST_MIN_SPEED = 3,           -- no footstep dust below this ground speed
	VFX_RUN_DUST_RATE = 16,           -- footstep dust particles/second at full run speed
	VFX_SLIDE_RATE = 40,              -- crouch-slide smoke particles/second (at run speed)
	VFX_BELLY_SLIDE_RATE = 60,        -- belly-slide smoke particles/second (at run speed)
	VFX_JUMP_PUFF = { 3, 5, 12 },     -- puff size on jump 1 / 2 / 3
	VFX_LONG_JUMP_PUFF = 10,
	VFX_DIVE_PUFF = 6,
	VFX_LAND_MIN_FALL_SPEED = 16,     -- landings slower than this make no puff
	VFX_LAND_PUFF_MIN = 3,            -- landing puff = fall speed / 8, clamped to this range
	VFX_LAND_PUFF_MAX = 14,
	VFX_GROUND_POUND_SHOCKWAVE = 36,  -- particles in the ground pound shockwave ring

	----------------------------------------------------------------------------
	-- Input (arrays so you can bind several keys / gamepad buttons)
	----------------------------------------------------------------------------
	CROUCH_KEYS = { Enum.KeyCode.LeftControl, Enum.KeyCode.C, Enum.KeyCode.ButtonL2 },
	GROUND_POUND_KEYS = { Enum.KeyCode.Q, Enum.KeyCode.ButtonR2 },

	ANIM_FADE = 0.1,                  -- animation fade time (seconds)
	SOUND_DEFAULT_VOLUME = 1,
}

-- Movement state machine ------------------------------------------------------
local STATE = {
	Idle = "Idle",
	Running = "Running",
	Crouching = "Crouching",
	Sliding = "Sliding",              -- crouch slide OR belly slide (see slideKind)
	Airborne = "Airborne",            -- normal jump / fall (single, double, triple)
	LongJumping = "LongJumping",
	Diving = "Diving",
	GroundPoundSpin = "GroundPoundSpin",
	GroundPoundFall = "GroundPoundFall",
	GroundPoundLand = "GroundPoundLand",
	LedgeGrabbing = "LedgeGrabbing",
	LedgeClimbing = "LedgeClimbing",
}

local GROUND_STATES = { [STATE.Idle] = true, [STATE.Running] = true, [STATE.Crouching] = true }
-- States where touching the floor means "we landed" and should be handled.
local AIR_STATES = {
	[STATE.Airborne] = true, [STATE.LongJumping] = true,
	[STATE.Diving] = true, [STATE.GroundPoundFall] = true,
}
-- States where the player's stick input is ignored (we zero Humanoid:Move) and the Humanoid
-- must not auto-rotate the character. This is what locks your facing in the air and stops
-- moves from overlapping (e.g. no diving while ledge grabbing).
local LOCKED_STATES = {
	[STATE.Airborne] = true,
	[STATE.Diving] = true, [STATE.LongJumping] = true,
	[STATE.GroundPoundSpin] = true, [STATE.GroundPoundFall] = true, [STATE.GroundPoundLand] = true,
	[STATE.LedgeGrabbing] = true, [STATE.LedgeClimbing] = true,
}

--==============================================================================
-- 2. ANIMATION ID CONFIGURATION
-- Leave an id as "rbxassetid://0" to skip it: the move still works, it just has no animation.
--==============================================================================

-- Special-move animations (highest priority: they override everything else while they play)
local ANIMATION_IDS = {
	Crouch = "rbxassetid://109602961761132",     --✅
	LedgeGrab = "rbxassetid://138857478857008",  --✅
	Dive = "rbxassetid://80551120256872",        --✅
	TripleJump1 = "rbxassetid://117513983410171", --✅
	TripleJump2 = "rbxassetid://117513983410171", --✅
	TripleJump3 = "rbxassetid://117513983410171", --✅
	-- Additional animations for the extended moveset:
	Slide = "rbxassetid://125545085077300",           --✅
	LongJump = "rbxassetid://117513983410171",        --✅
	GroundPound = "rbxassetid://89294343295121",     --✅
	GroundPoundLand = "rbxassetid://89294343295121", --✅
	LedgeClimb = "rbxassetid://117513983410171",      --✅
}

-- Locomotion animations. These REPLACE Roblox's default idle/walk/run/jump/fall.
-- They play at Action priority (above Roblox's Core/Idle/Movement), below the special moves.
local LOCOMOTION_ANIMATION_IDS = {
	Idle = "rbxassetid://70490046101876",
	Walk = "rbxassetid://79081744770812",
	Run = "rbxassetid://117830374930403",
	Jump = "rbxassetid://117513983410171",            -- rising part of a jump with no TripleJumpN animation for it
	Fall = "rbxassetid://102933665532878",            -- falling (also used for dive/long jump/ground pound if they have no animation)
	Land = "rbxassetid://102933665532878",            -- brief one-shot when you land and stand still
}

-- Which animations should loop while their state lasts.
local ANIMATION_LOOPED = {
	Crouch = true, CrouchWalk = true, LedgeGrab = true, Slide = true,
	GroundPound = true, Dive = true, LongJump = true,
}
local LOCOMOTION_LOOPED = {
	Idle = true, Walk = true, Run = true, Fall = true, -- Jump and Land play once
}

-- Walk/Run playback speed = real horizontal speed / this number (so 1x at the listed speed).
-- Match these to how fast your animation's legs actually move.
local LOCOMOTION_REFERENCE_SPEED = {
	Walk = 10,
	Run = 22,
}

-- Which animation each state plays (Sliding is resolved dynamically: Slide vs Crouch).
local STATE_ANIMATION = {
	[STATE.Crouching] = "Crouch",
	[STATE.Diving] = "Dive",
	[STATE.LongJumping] = "LongJump",
	[STATE.GroundPoundSpin] = "GroundPound",
	[STATE.GroundPoundFall] = "GroundPound",
	[STATE.GroundPoundLand] = "GroundPoundLand",
	[STATE.LedgeGrabbing] = "LedgeGrab",
	[STATE.LedgeClimbing] = "LedgeClimb",
}

--==============================================================================
-- 2b. SOUND EFFECT CONFIGURATION
-- Paste your own sound IDs. Leave "rbxassetid://0" to skip a sound.
--==============================================================================
local SOUND_IDS = {
	Jump1 = "rbxassetid://139258029857671",             -- first jump   ("Wah!")
	Jump2 = "rbxassetid://111885629373760",             -- second jump  ("Yah!")
	Jump3 = "rbxassetid://124652944831766",             -- triple jump  ("Yahoo!")
	LongJump = "rbxassetid://124652944831766",          -- long jump    ("Wahoo!")
	Dive = "rbxassetid://0",
	Land = "rbxassetid://85581268010045",              -- normal landing
	Crouch = "rbxassetid://0",
	Slide = "rbxassetid://0",             -- belly slide (loops until the slide ends)
	GroundPoundSpin = "rbxassetid://94984771567868",
	GroundPoundImpact = "rbxassetid://79293088671119",
	LedgeGrab = "rbxassetid://0",
	LedgeClimb = "rbxassetid://0",        -- pulling up onto the ledge
}

-- Optional per-sound tweaks: Volume, PlaybackSpeed, Looped.
local SOUND_SETTINGS = {
	Slide = { Looped = true, Volume = 0.7 },
	Land = { Volume = 0.8 },
}

-- Sound played when ENTERING a state (jump sounds and Land are played explicitly).
local STATE_SOUND = {
	[STATE.Crouching] = "Crouch",
	[STATE.Diving] = "Dive",
	[STATE.LongJumping] = "LongJump",
	[STATE.GroundPoundSpin] = "GroundPoundSpin",
	[STATE.GroundPoundLand] = "GroundPoundImpact",
	[STATE.LedgeGrabbing] = "LedgeGrab",
	[STATE.LedgeClimbing] = "LedgeClimb",
}

local function isConfiguredId(id)
	if type(id) ~= "string" then return false end
	local digits = id:match("%d+")
	return digits ~= nil and tonumber(digits) ~= 0
end

--==============================================================================
-- Stick input (used only for the tiny air drift). Reads the default ControlModule so
-- keyboard, gamepad and mobile thumbstick all work. Falls back to Humanoid.MoveDirection.
--==============================================================================
local controlsModule = nil
local controlsTried = false

local function loadControls()
	if controlsTried then return controlsModule end
	controlsTried = true
	pcall(function()
		local playerScripts = player:WaitForChild("PlayerScripts", 10)
		local playerModule = playerScripts and playerScripts:WaitForChild("PlayerModule", 10)
		if playerModule then
			controlsModule = require(playerModule):GetControls()
		end
	end)
	return controlsModule
end
task.spawn(loadControls) -- preload so we never yield inside a frame loop

--==============================================================================
-- 3. CONTROLLER (one instance per character, fully cleaned up on death)
--==============================================================================
local function createController(character)
	local humanoid = character:WaitForChild("Humanoid", 10)
	local hrp = character:WaitForChild("HumanoidRootPart", 10)
	if not humanoid or not hrp then return nil end

	local animator = humanoid:FindFirstChildOfClass("Animator") or humanoid:WaitForChild("Animator", 5)
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	controllerCounter += 1
	local RENDER_NAME = "SM64_Move_" .. controllerCounter
	local ACTION_CROUCH = "SM64_Crouch"
	local ACTION_POUND = "SM64_GroundPound"

	local connections = {}
	local destroyed = false
	local destroy -- forward declaration

	local function connect(signal, callback)
		local c = signal:Connect(callback)
		table.insert(connections, c)
		return c
	end

	-- Runtime state ------------------------------------------------------------
	local state = STATE.Idle
	local stateEnteredAt = os.clock()
	local crouchHeld = false
	local offGroundTime = 0
	local airFromJump = false          -- true when airborne because of a jump (not a walk-off)
	local lastJumpRequest = -math.huge -- for the jump buffer

	local chainCount = 0               -- 0..2 = how many jumps of the chain are done
	local lastLandTime = -math.huge
	local planKind = "Chain"           -- what the NEXT jump will be: Chain / Plain / Long
	local planIndex = 1

	local airVel = nil                 -- horizontal velocity carried through a normal jump
	local airSpeedCap = 0
	local maxFallSpeed = 0             -- fastest downward speed this fall (for the landing puff)

	local slideKind = "Crouch"         -- "Crouch" or "Belly"
	local slideDir = Vector3.new(0, 0, -1)
	local slideSpeed = 0
	local diveDir = Vector3.new(0, 0, -1)
	local diveSpeed = 0
	local longDir = Vector3.new(0, 0, -1)
	local longSpeed = 0

	local ledgeInfo = nil
	local ledgeCooldownUntil = 0

	local shakeUntil = 0
	local shaking = false

	local crouchAnimName = nil         -- which of Crouch / CrouchWalk is currently chosen
	local landAnimUntil = 0            -- Land animation owns the body until this time

	-- Raycast setup -----------------------------------------------------------
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { character }
	rayParams.RespectCanCollide = true
	rayParams.IgnoreWater = true

	-- Distance from the HumanoidRootPart centre down to the soles of the feet.
	local function getStandOffset()
		if humanoid.RigType == Enum.HumanoidRigType.R6 then
			return 3
		end
		return humanoid.HipHeight + hrp.Size.Y / 2
	end

	-- Apply physics / humanoid configuration -----------------------------------
	Workspace.Gravity = CONFIG.GRAVITY
	humanoid.UseJumpPower = true
	humanoid.WalkSpeed = CONFIG.RUN_SPEED
	humanoid.JumpPower = CONFIG.JUMP_POWERS[1]
	humanoid.AutoRotate = true

	----------------------------------------------------------------------------
	-- Animations: build Animation instances from the ID tables and load them
	----------------------------------------------------------------------------
	local tracks = {}                  -- special-move tracks (Action4)
	local locoTracks = {}              -- locomotion tracks (Action)
	local animationInstances = {}
	local currentTrack = nil           -- the special-move track currently owning the body
	local currentLoco = nil            -- name of the locomotion animation currently chosen
	local currentLocoTrack = nil

	local function loadTrack(name, id, priority, looped)
		local animation = Instance.new("Animation")
		animation.Name = "SM64_" .. name
		animation.AnimationId = id
		table.insert(animationInstances, animation)

		local ok, track = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if ok and track then
			track.Priority = priority
			track.Looped = looped == true
			return track
		end
		warn(("[SM64] Could not load animation '%s' (%s)"):format(name, tostring(id)))
		return nil
	end

	for name, id in pairs(ANIMATION_IDS) do
		if isConfiguredId(id) then
			-- Action4 beats the default Animate script AND our own locomotion animations.
			tracks[name] = loadTrack(name, id, Enum.AnimationPriority.Action4, ANIMATION_LOOPED[name])
		end
	end

	for name, id in pairs(LOCOMOTION_ANIMATION_IDS) do
		if isConfiguredId(id) then
			-- Action beats Roblox's Core / Idle / Movement animations.
			locoTracks[name] = loadTrack("Loco_" .. name, id, Enum.AnimationPriority.Action, LOCOMOTION_LOOPED[name])
		end
	end

	-- Optionally turn Roblox's default "Animate" script off so only our animations play.
	local animateScript = character:FindFirstChild("Animate")
	local function silenceDefaultAnimations()
		if not CONFIG.DISABLE_DEFAULT_ANIMATE then return end
		if animateScript and animateScript.Parent then
			pcall(function() animateScript.Enabled = false end)
			pcall(function() animateScript.Disabled = true end)
		end
		local ours = {}
		for _, t in pairs(tracks) do ours[t] = true end
		for _, t in pairs(locoTracks) do ours[t] = true end
		for _, t in ipairs(animator:GetPlayingAnimationTracks()) do
			if not ours[t] then t:Stop(0) end
		end
	end
	silenceDefaultAnimations()
	task.delay(0.3, function()
		if not destroyed then silenceDefaultAnimations() end
	end)

	-- Special-move animation layer ------------------------------------------------
	local function playAnim(name)
		local track = tracks[name]
		if currentTrack and currentTrack ~= track then
			currentTrack:Stop(CONFIG.ANIM_FADE)
		end
		currentTrack = nil
		if track then
			track:Play(CONFIG.ANIM_FADE)
			currentTrack = track
		end
	end

	local function stopAnim()
		if currentTrack then
			currentTrack:Stop(CONFIG.ANIM_FADE)
			currentTrack = nil
		end
	end

	-- Locomotion animation layer ----------------------------------------------------
	local function setLocomotion(name, speed)
		if name ~= currentLoco then
			if currentLocoTrack then
				currentLocoTrack:Stop(CONFIG.ANIM_FADE)
			end
			currentLoco = name
			currentLocoTrack = name and locoTracks[name] or nil
			if currentLocoTrack then
				currentLocoTrack:Play(CONFIG.ANIM_FADE)
			end
		end

		-- Scale Walk/Run playback with the real speed so the feet don't slide.
		local reference = name and LOCOMOTION_REFERENCE_SPEED[name]
		if currentLocoTrack and reference then
			currentLocoTrack:AdjustSpeed(math.clamp(speed / reference,
				CONFIG.LOCO_MIN_ANIM_SPEED, CONFIG.LOCO_MAX_ANIM_SPEED))
		end
	end

	local function desiredLocomotion(now, speed, vel)
		-- A special-move animation (dive, crouch, triple jump...) owns the body while it plays.
		if currentTrack and currentTrack.IsPlaying then return nil end

		if state == STATE.Idle then
			if now < landAnimUntil and locoTracks.Land then return "Land" end
			return "Idle"
		elseif state == STATE.Running then
			return (speed < CONFIG.WALK_RUN_THRESHOLD) and "Walk" or "Run"
		elseif state == STATE.Crouching then
			-- Only reached when no Crouch / CrouchWalk animation is provided.
			return (speed > 1.5) and "Walk" or "Idle"
		elseif state == STATE.Airborne then
			return (vel.Y > 0) and "Jump" or "Fall"
		elseif state == STATE.Diving or state == STATE.LongJumping
			or state == STATE.GroundPoundSpin or state == STATE.GroundPoundFall then
			return "Fall" -- fallback pose when those moves have no animation of their own
		end
		return nil
	end

	local function updateLocomotion(now, speed, vel)
		setLocomotion(desiredLocomotion(now, speed, vel), speed)
	end

	local function landAnimDuration()
		local track = locoTracks.Land
		if track and track.Length > 0 then return track.Length end
		return CONFIG.LAND_ANIM_TIME
	end

	----------------------------------------------------------------------------
	-- Sounds: build Sound instances from SOUND_IDS (parented to the root part so they are 3D)
	----------------------------------------------------------------------------
	local sounds = {}

	for name, id in pairs(SOUND_IDS) do
		if isConfiguredId(id) then
			local settings = SOUND_SETTINGS[name] or {}
			local sound = Instance.new("Sound")
			sound.Name = "SM64_" .. name
			sound.SoundId = id
			sound.Volume = settings.Volume or CONFIG.SOUND_DEFAULT_VOLUME
			sound.PlaybackSpeed = settings.PlaybackSpeed or 1
			sound.Looped = settings.Looped == true
			sound.RollOffMaxDistance = 120
			sound.Parent = hrp
			sounds[name] = sound
		end
	end

	local function playSound(name)
		local sound = sounds[name]
		if sound then
			sound.TimePosition = 0
			sound:Play()
		end
	end

	local function stopSound(name)
		local sound = sounds[name]
		if sound then sound:Stop() end
	end

	----------------------------------------------------------------------------
	-- Drop shadow: a flat cylinder that snaps to the nearest surface under the character
	----------------------------------------------------------------------------
	local shadow = nil
	local shadowRayParams = nil

	if CONFIG.SHADOW_ENABLED then
		shadow = Instance.new("Part")
		shadow.Name = "SM64_Shadow"
		shadow.Shape = Enum.PartType.Cylinder -- a Cylinder's axis runs along its X axis
		shadow.Anchored = true
		shadow.CanCollide = false
		shadow.CanQuery = false
		shadow.CanTouch = false
		shadow.CastShadow = false
		shadow.Material = Enum.Material.SmoothPlastic
		shadow.Color = CONFIG.SHADOW_COLOR
		shadow.Transparency = 1
		shadow.Size = Vector3.new(CONFIG.SHADOW_THICKNESS, CONFIG.SHADOW_SIZE, CONFIG.SHADOW_SIZE)
		shadow.Parent = Workspace.CurrentCamera or Workspace

		shadowRayParams = RaycastParams.new()
		shadowRayParams.FilterType = Enum.RaycastFilterType.Exclude
		shadowRayParams.FilterDescendantsInstances = { character, shadow }
		shadowRayParams.RespectCanCollide = true
		shadowRayParams.IgnoreWater = true
	end

	local function updateShadow()
		if not shadow then return end

		local origin = hrp.Position
		local result = Workspace:Raycast(origin, Vector3.new(0, -CONFIG.SHADOW_MAX_DISTANCE, 0), shadowRayParams)
		if not result then
			shadow.Transparency = 1
			return
		end

		-- Height of the character's feet above the surface.
		local feetHeight = math.max(0, (origin.Y - result.Position.Y) - getStandOffset())
		local t = math.clamp(feetHeight / CONFIG.SHADOW_FADE_DISTANCE, 0, 1)

		-- Higher up = smaller and fainter, like the SM64 blob shadow.
		local diameter = CONFIG.SHADOW_SIZE * (1 - t * (1 - CONFIG.SHADOW_MIN_SCALE))
		shadow.Size = Vector3.new(CONFIG.SHADOW_THICKNESS, diameter, diameter)
		shadow.Transparency = CONFIG.SHADOW_NEAR_TRANSPARENCY
			+ (CONFIG.SHADOW_FAR_TRANSPARENCY - CONFIG.SHADOW_NEAR_TRANSPARENCY) * t

		-- Lay the cylinder flat on the surface: its X axis (the disc's normal) = surface normal.
		local normal = result.Normal
		local tangent = normal:Cross(Vector3.xAxis)
		if tangent.Magnitude < 0.1 then
			tangent = normal:Cross(Vector3.zAxis)
		end
		shadow.CFrame = CFrame.fromMatrix(result.Position + normal * 0.05, normal, tangent.Unit)
	end

	----------------------------------------------------------------------------
	-- Smoke / dust VFX: four ParticleEmitters on an attachment at the character's feet.
	--   dust  = footstep dust while walking/running (continuous)
	--   slide = smoke trail streaming out BEHIND you while sliding (continuous)
	--   puff  = one-shot burst for jumps, dives and landings
	--   shock = one-shot ring burst for the ground pound
	-- All particles are LockedToPart = false so they stay in the world as you move on.
	----------------------------------------------------------------------------
	local feetAttachment = nil
	local dustEmitter, slideEmitter, puffEmitter, shockEmitter = nil, nil, nil, nil
	local vfxEmitters = {}
	local lastTintSample = -math.huge

	local function scaledSize(startSize, endSize)
		local s = CONFIG.VFX_SCALE
		return NumberSequence.new({
			NumberSequenceKeypoint.new(0, startSize * s),
			NumberSequenceKeypoint.new(1, endSize * s),
		})
	end

	local function makeEmitter(props)
		local emitter = Instance.new("ParticleEmitter")
		emitter.Texture = CONFIG.VFX_TEXTURE
		emitter.Color = ColorSequence.new(CONFIG.VFX_COLOR)
		emitter.LightEmission = 0
		emitter.LockedToPart = false
		emitter.Rotation = NumberRange.new(0, 360)
		emitter.RotSpeed = NumberRange.new(-70, 70)
		emitter.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.55),
			NumberSequenceKeypoint.new(0.5, 0.7),
			NumberSequenceKeypoint.new(1, 1),
		})
		emitter.Rate = 0
		emitter.Enabled = false
		for key, value in pairs(props) do
			emitter[key] = value
		end
		emitter.Parent = feetAttachment
		table.insert(vfxEmitters, emitter)
		return emitter
	end

	if CONFIG.VFX_ENABLED then
		feetAttachment = Instance.new("Attachment")
		feetAttachment.Name = "SM64_Feet"
		feetAttachment.Position = Vector3.new(0, -getStandOffset() + 0.15, 0)
		feetAttachment.Parent = hrp

		dustEmitter = makeEmitter({
			Lifetime = NumberRange.new(0.35, 0.6),
			Speed = NumberRange.new(1, 3),
			SpreadAngle = Vector2.new(35, 35),
			Size = scaledSize(0.5, 1.8),
			Acceleration = Vector3.new(0, 2, 0),
			Drag = 2,
		})
		slideEmitter = makeEmitter({
			Lifetime = NumberRange.new(0.5, 0.9),
			Speed = NumberRange.new(3, 7),
			SpreadAngle = Vector2.new(22, 22),
			Size = scaledSize(0.9, 3.2),
			Acceleration = Vector3.new(0, 3, 0),
			Drag = 3,
			EmissionDirection = Enum.NormalId.Back, -- the character faces -Z, so Back = behind you
		})
		puffEmitter = makeEmitter({
			Lifetime = NumberRange.new(0.4, 0.7),
			Speed = NumberRange.new(6, 10),
			SpreadAngle = Vector2.new(85, 85), -- nearly flat cone: the puff spreads out along the floor
			Size = scaledSize(1.2, 3.5),
			Acceleration = Vector3.new(0, 1.5, 0),
			Drag = 4,
		})
		shockEmitter = makeEmitter({
			Lifetime = NumberRange.new(0.6, 0.95),
			Speed = NumberRange.new(18, 26),
			SpreadAngle = Vector2.new(88, 88),
			Size = scaledSize(2, 7),
			Acceleration = Vector3.new(0, 1, 0),
			Drag = 5,
		})
	end

	-- Tint the smoke with the colour of the surface underfoot (dirt dust on dirt, pale on stone).
	local function sampleFloorColor()
		if not feetAttachment then return end
		lastTintSample = os.clock()

		local result = Workspace:Raycast(hrp.Position, Vector3.new(0, -(getStandOffset() + 4), 0), rayParams)
		if not result then return end

		local floorColor = nil
		if result.Instance:IsA("Terrain") then
			floorColor = Workspace.Terrain:GetMaterialColor(result.Material)
		elseif result.Instance:IsA("BasePart") then
			floorColor = result.Instance.Color
		end
		if not floorColor then return end

		floorColor = floorColor:Lerp(Color3.new(1, 1, 1), 0.35) -- keep dust light even on dark floors
		local sequence = ColorSequence.new(CONFIG.VFX_COLOR:Lerp(floorColor, CONFIG.VFX_FLOOR_TINT))
		for _, emitter in ipairs(vfxEmitters) do
			emitter.Color = sequence
		end
	end

	local function emitBurst(emitter, count)
		if not emitter or not count or count <= 0 then return end
		sampleFloorColor()
		emitter:Emit(count)
	end

	local function setEmitterRate(emitter, rate)
		if not emitter then return end
		emitter.Rate = rate
		local on = rate > 0
		if emitter.Enabled ~= on then
			emitter.Enabled = on
		end
	end

	-- Continuous effects (footstep dust, slide smoke). Called every Heartbeat.
	local function updateVfx(now, speed, onGround)
		if not feetAttachment then return end

		if onGround and now - lastTintSample > 0.15 then
			sampleFloorColor()
		end

		local dustRate = 0
		if onGround and (state == STATE.Running or state == STATE.Crouching)
			and speed > CONFIG.VFX_DUST_MIN_SPEED then
			dustRate = CONFIG.VFX_RUN_DUST_RATE * math.clamp(speed / CONFIG.RUN_SPEED, 0, 1)
			if state == STATE.Crouching then
				dustRate *= 0.5 -- crouch-walking kicks up less dust
			end
		end
		setEmitterRate(dustEmitter, dustRate)

		local slideRate = 0
		if onGround and state == STATE.Sliding then
			local base = (slideKind == "Belly") and CONFIG.VFX_BELLY_SLIDE_RATE or CONFIG.VFX_SLIDE_RATE
			-- Smoke fades out as the slide slows down.
			slideRate = base * math.clamp(slideSpeed / CONFIG.RUN_SPEED, 0.2, 1.5)
		end
		setEmitterRate(slideEmitter, slideRate)
	end

	----------------------------------------------------------------------------
	-- State transitions
	----------------------------------------------------------------------------
	local function setState(newState)
		if state == newState then return end
		local oldState = state
		state = newState
		stateEnteredAt = os.clock()
		airVel = nil -- air momentum is re-captured the first frame of each air state
		crouchAnimName = nil

		-- Locked states steer the character themselves, so the Humanoid must not auto-rotate.
		humanoid.AutoRotate = not LOCKED_STATES[newState]

		-- Special-move animation
		local animName = STATE_ANIMATION[newState]
		if newState == STATE.Sliding then
			animName = (slideKind == "Belly") and "Slide" or "Crouch"
		end
		if animName then
			playAnim(animName)
		else
			stopAnim()
		end

		-- Sound
		if oldState == STATE.Sliding then
			stopSound("Slide")
		end
		if newState == STATE.Sliding then
			if slideKind == "Belly" then
				playSound("Slide")
			elseif oldState ~= STATE.Crouching then
				playSound("Crouch")
			end
		elseif STATE_SOUND[newState] and not (newState == STATE.Crouching and oldState == STATE.Sliding) then
			playSound(STATE_SOUND[newState])
		end
	end

	local function startSlide(kind, direction, speedValue)
		slideKind = kind
		slideDir = direction
		slideSpeed = speedValue
		chainCount = 0 -- sliding breaks the triple-jump chain
		setState(STATE.Sliding)
	end

	local function endSlide()
		setState(crouchHeld and STATE.Crouching or STATE.Idle)
	end

	----------------------------------------------------------------------------
	-- Jump planning.
	-- Humanoid applies JumpPower the instant it jumps, so we must set JumpPower BEFORE the
	-- jump happens. Every frame we pre-compute what the next jump would be and write the
	-- matching power. The Jumping state event later reads the same plan.
	----------------------------------------------------------------------------
	local function updateJumpPlan(onGround, speed, now)
		-- Chain expires if we waited too long after landing or lost our running momentum.
		if onGround and chainCount > 0 then
			if (now - lastLandTime) > CONFIG.TRIPLE_JUMP_WINDOW or speed < CONFIG.TRIPLE_JUMP_MIN_SPEED then
				chainCount = 0
			end
		end

		local power
		if onGround and state == STATE.Sliding and slideKind == "Crouch"
			and crouchHeld and slideSpeed >= CONFIG.LONG_JUMP_MIN_SPEED then
			planKind = "Long"
			power = CONFIG.LONG_JUMP_POWER
		elseif state == STATE.Crouching or state == STATE.Sliding then
			planKind = "Plain" -- crouched/belly-slide hop: ordinary jump, chain reset
			power = CONFIG.JUMP_POWERS[1]
		else
			-- While airborne we optimistically assume the next landing continues the chain,
			-- so an instant re-jump (holding Space) already has the right power.
			planKind = "Chain"
			planIndex = math.clamp(chainCount + 1, 1, 3)
			power = CONFIG.JUMP_POWERS[planIndex]
		end

		if humanoid.JumpPower ~= power then
			humanoid.JumpPower = power
		end
	end

	----------------------------------------------------------------------------
	-- Moves
	----------------------------------------------------------------------------
	local function flatUnit(v, fallback)
		local flat = Vector3.new(v.X, 0, v.Z)
		if flat.Magnitude < 0.05 then return fallback end
		return flat.Unit
	end

	local function facing()
		return flatUnit(hrp.CFrame.LookVector, Vector3.new(0, 0, -1))
	end

	-- Camera-relative stick direction on the XZ plane (length 0..1).
	local function getMoveInput()
		local controls = loadControls()
		local camera = Workspace.CurrentCamera
		if controls and camera then
			local mv = controls:GetMoveVector() -- x = right, z = back (forward is -1)
			if mv.Magnitude > 0.01 then
				local look = flatUnit(camera.CFrame.LookVector, Vector3.new(0, 0, -1))
				local right = flatUnit(camera.CFrame.RightVector, Vector3.new(1, 0, 0))
				local dir = look * -mv.Z + right * mv.X
				if dir.Magnitude > 1 then dir = dir.Unit end
				return dir
			end
			return Vector3.zero
		end
		return humanoid.MoveDirection
	end

	local function doLongJump()
		chainCount = 0
		longDir = slideDir
		-- Launch speed scales with how fast the slide still is (SM64: 1.5x forward velocity).
		longSpeed = math.clamp(slideSpeed * CONFIG.LONG_JUMP_SPEED_MULT,
			CONFIG.LONG_JUMP_MIN_OUT, CONFIG.LONG_JUMP_MAX_OUT)
		setState(STATE.LongJumping)
		emitBurst(puffEmitter, CONFIG.VFX_LONG_JUMP_PUFF)
		-- Horizontal speed is held constant each frame in the Heartbeat (no air drag),
		-- vertical is Humanoid's JumpPower launch + our reduced fall multiplier.
	end

	local function onJumped()
		-- Humanoid entered Jumping. Ignore if a special move already owns the character.
		if not (GROUND_STATES[state] or state == STATE.Sliding) then return end

		if planKind == "Long" then
			doLongJump()
			airFromJump = true
			return
		end

		local index = (planKind == "Chain") and planIndex or 0
		-- After jump 1 or 2 remember our place; after the triple (3) or a plain hop, reset.
		chainCount = (index == 1 or index == 2) and index or 0

		setState(STATE.Airborne)
		airFromJump = true

		playSound("Jump" .. math.max(index, 1))
		emitBurst(puffEmitter, CONFIG.VFX_JUMP_PUFF[math.max(index, 1)])

		if index > 0 then
			playAnim("TripleJump" .. index)
			local boost = CONFIG.JUMP_FORWARD_BOOST[index]
			if boost and boost > 0 then
				-- Impulse = mass * delta-velocity. Adds forward speed without touching the
				-- vertical launch velocity the Humanoid is applying this same frame.
				local vel = hrp.AssemblyLinearVelocity
				local dir = flatUnit(vel, facing())
				hrp:ApplyImpulse(dir * boost * hrp.AssemblyMass)
			end
		end
	end

	local function startDive()
		local vel = hrp.AssemblyLinearVelocity
		local flatSpeed = Vector3.new(vel.X, 0, vel.Z).Magnitude
		diveDir = facing()
		-- Dive speed = current speed + a boost, clamped. Example: running at 22 -> 36 studs/s.
		diveSpeed = math.clamp(flatSpeed + CONFIG.DIVE_BOOST, CONFIG.DIVE_MIN_SPEED, CONFIG.DIVE_MAX_SPEED)
		chainCount = 0
		setState(STATE.Diving)
		emitBurst(puffEmitter, CONFIG.VFX_DIVE_PUFF)
		-- Snap yaw to the dive direction (pitch is left to your Dive animation).
		hrp.CFrame = CFrame.lookAt(hrp.Position, hrp.Position + diveDir)
		hrp.AssemblyLinearVelocity = Vector3.new(diveDir.X * diveSpeed, CONFIG.DIVE_UP_VELOCITY, diveDir.Z * diveSpeed)
	end

	local function startGroundPound()
		chainCount = 0
		setState(STATE.GroundPoundSpin)
		hrp.AssemblyLinearVelocity = Vector3.zero
	end

	----------------------------------------------------------------------------
	-- Ledge grabbing
	--   1. Ray forward at hip height  -> is there a wall?
	--   2. Ray forward above the max grab height -> must be CLEAR, else it's a tall wall, not a ledge
	--   3. Ray straight down just inside the wall edge -> finds the ledge's top surface
	-- Hang position = ledge top - HANG_DEPTH, pushed HANG_DISTANCE out from the wall.
	----------------------------------------------------------------------------
	local function findLedge(vel)
		if vel.Y > -CONFIG.LEDGE_MIN_FALL_SPEED then return nil end -- only while falling

		local forward = facing()
		local origin = hrp.Position
		local reach = forward * CONFIG.LEDGE_REACH

		local wall = Workspace:Raycast(origin + Vector3.new(0, CONFIG.LEDGE_WALL_RAY_HEIGHT, 0), reach, rayParams)
		if not wall or math.abs(wall.Normal.Y) > 0.3 then return nil end

		local wallNormal = Vector3.new(wall.Normal.X, 0, wall.Normal.Z)
		if wallNormal.Magnitude < 0.05 then return nil end
		wallNormal = wallNormal.Unit
		if forward:Dot(-wallNormal) < 0.5 then return nil end -- must be facing the wall

		local scanTop = CONFIG.LEDGE_MAX_TOP + 0.7
		if Workspace:Raycast(origin + Vector3.new(0, scanTop, 0), reach, rayParams) then
			return nil -- wall continues above grab height
		end

		local downOrigin = Vector3.new(wall.Position.X, origin.Y + scanTop, wall.Position.Z) - wallNormal * 0.4
		local down = Workspace:Raycast(downOrigin, Vector3.new(0, -(scanTop - CONFIG.LEDGE_MIN_TOP), 0), rayParams)
		if not down or down.Normal.Y < 0.7 then return nil end

		local top = down.Position.Y
		local hangPos = Vector3.new(wall.Position.X, top - CONFIG.LEDGE_HANG_DEPTH, wall.Position.Z)
			+ wallNormal * CONFIG.LEDGE_HANG_DISTANCE

		return {
			cf = CFrame.lookAt(hangPos, hangPos - wallNormal), -- face the wall
			normal = wallNormal,
			top = top,
		}
	end

	local function grabLedge(info)
		ledgeInfo = info
		chainCount = 0
		setState(STATE.LedgeGrabbing)
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
		hrp.CFrame = info.cf
		-- Anchoring our own root part freezes the whole character in place locally.
		hrp.Anchored = true
	end

	local function releaseLedge()
		if not ledgeInfo then return end
		hrp.Anchored = false
		ledgeCooldownUntil = os.clock() + CONFIG.LEDGE_REGRAB_COOLDOWN
		setState(STATE.Airborne)
		airFromJump = false
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		hrp.AssemblyLinearVelocity = ledgeInfo.normal * 4 -- tiny push away from the wall
	end

	local function ledgeJump()
		if not ledgeInfo then return end
		if os.clock() - stateEnteredAt < 0.15 then return end -- stops held-Space instant climb
		hrp.Anchored = false
		ledgeCooldownUntil = os.clock() + CONFIG.LEDGE_REGRAB_COOLDOWN
		setState(STATE.LedgeClimbing)
		humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		-- Kinematics: to rise h studs under gravity g we need v = sqrt(2 * g * h).
		-- g=120, h=6.4 -> v ~ 39 studs/s straight up (no forward motion until we clear the lip).
		local v = math.sqrt(2 * Workspace.Gravity * CONFIG.LEDGE_JUMP_HEIGHT)
		hrp.AssemblyLinearVelocity = Vector3.new(0, v, 0)
	end

	----------------------------------------------------------------------------
	-- Landing
	----------------------------------------------------------------------------
	-- If Jump was pressed just before touching down, jump again right away.
	local function applyJumpBuffer(now, speed)
		if now - lastJumpRequest > CONFIG.JUMP_BUFFER_TIME then return end
		if GROUND_STATES[state] or state == STATE.Sliding then
			updateJumpPlan(true, speed, now) -- make sure JumpPower matches the new state first
			humanoid.Jump = true
		end
	end

	local function handleLanding(now, speed, flatVel)
		local previous = state
		lastLandTime = now
		landAnimUntil = now + landAnimDuration()

		local fallSpeed = maxFallSpeed
		maxFallSpeed = 0

		if previous == STATE.GroundPoundFall then
			hrp.AssemblyLinearVelocity = Vector3.zero
			shakeUntil = now + CONFIG.GROUND_POUND_SHAKE_TIME
			setState(STATE.GroundPoundLand)
			emitBurst(shockEmitter, CONFIG.VFX_GROUND_POUND_SHOCKWAVE)
			emitBurst(puffEmitter, CONFIG.VFX_LAND_PUFF_MAX)

		elseif previous == STATE.Diving then
			chainCount = 0
			local keep = diveSpeed * CONFIG.BELLY_SLIDE_KEEP
			if keep >= CONFIG.BELLY_SLIDE_MIN_SPEED then
				startSlide("Belly", diveDir, keep)
			else
				setState(STATE.Idle)
				playSound("Land")
			end

		elseif previous == STATE.LongJumping then
			chainCount = 0
			playSound("Land")
			local keep = longSpeed * CONFIG.LONG_JUMP_LAND_SPEED_KEEP
			if crouchHeld and keep >= CONFIG.SLIDE_MIN_SPEED then
				startSlide("Crouch", longDir, keep) -- keep crouching: chain into another long jump
			else
				setState(STATE.Idle)
			end

		else -- normal Airborne landing
			playSound("Land")
			if crouchHeld and speed >= CONFIG.SLIDE_MIN_SPEED then
				startSlide("Crouch", flatVel.Unit, speed)
			else
				setState(STATE.Idle)
			end
		end

		-- Landing puff: bigger for harder landings, none for tiny hops.
		if previous ~= STATE.GroundPoundFall and fallSpeed >= CONFIG.VFX_LAND_MIN_FALL_SPEED then
			local count = math.clamp(math.floor(fallSpeed / 8), CONFIG.VFX_LAND_PUFF_MIN, CONFIG.VFX_LAND_PUFF_MAX)
			emitBurst(puffEmitter, count)
		end

		applyJumpBuffer(now, speed)
	end

	-- The Humanoid's own Landed event. This catches landings that last only a frame or two
	-- (e.g. holding Space), which polling FloorMaterial once per frame can miss.
	local function onHumanoidLanded()
		if destroyed or not AIR_STATES[state] then return end
		local now = os.clock()
		if now - stateEnteredAt <= 0.05 then return end
		local vel = hrp.AssemblyLinearVelocity
		local flatVel = Vector3.new(vel.X, 0, vel.Z)
		handleLanding(now, flatVel.Magnitude, flatVel)
	end

	----------------------------------------------------------------------------
	-- Input handlers
	----------------------------------------------------------------------------
	local function onCrouchPressed()
		if destroyed or humanoid.Health <= 0 then return end
		local vel = hrp.AssemblyLinearVelocity
		local flatVel = Vector3.new(vel.X, 0, vel.Z)

		if GROUND_STATES[state] then
			-- Fast enough? -> crouch slide (needed for the long jump). Otherwise the Heartbeat
			-- moves us into Crouching because crouchHeld is now true.
			if flatVel.Magnitude >= CONFIG.SLIDE_MIN_SPEED then
				startSlide("Crouch", flatVel.Unit, flatVel.Magnitude)
			end

		elseif state == STATE.Airborne or state == STATE.LongJumping then
			-- Apex check: near the top of a jump |vy| is tiny, so crouch = ground pound there,
			-- and a dive anywhere else in the air.
			local nearApex = state == STATE.Airborne and airFromJump
				and math.abs(vel.Y) <= CONFIG.GROUND_POUND_APEX_WINDOW
				and (os.clock() - stateEnteredAt) > 0.1
			if nearApex then
				startGroundPound()
			else
				startDive()
			end

		elseif state == STATE.LedgeGrabbing then
			releaseLedge() -- crouch while hanging = let go
		end
		-- Every other state (Diving, Sliding, ground pound, climbing...) ignores the press: debounce.
	end

	local function onCrouchReleased()
		if state == STATE.Sliding and slideKind == "Crouch" then
			endSlide()
		end
		-- Crouching -> standing is handled by the Heartbeat because crouchHeld is now false.
	end

	local function onGroundPoundPressed()
		if destroyed or humanoid.Health <= 0 then return end
		if state == STATE.Airborne or state == STATE.LongJumping then
			startGroundPound()
		end
	end

	ContextActionService:BindAction(ACTION_CROUCH, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			crouchHeld = true
			onCrouchPressed()
		else -- End or Cancel
			crouchHeld = false
			onCrouchReleased()
		end
		return Enum.ContextActionResult.Sink
	end, true, table.unpack(CONFIG.CROUCH_KEYS))
	ContextActionService:SetTitle(ACTION_CROUCH, "Crouch")

	ContextActionService:BindAction(ACTION_POUND, function(_, inputState)
		if inputState == Enum.UserInputState.Begin then
			onGroundPoundPressed()
		end
		return Enum.ContextActionResult.Sink
	end, false, table.unpack(CONFIG.GROUND_POUND_KEYS))

	connect(UserInputService.JumpRequest, function()
		lastJumpRequest = os.clock()
		if state == STATE.LedgeGrabbing then
			ledgeJump()
		end
	end)

	connect(humanoid.StateChanged, function(_, newHumanoidState)
		if newHumanoidState == Enum.HumanoidStateType.Jumping then
			onJumped()
		elseif newHumanoidState == Enum.HumanoidStateType.Landed then
			onHumanoidLanded()
		end
	end)

	----------------------------------------------------------------------------
	-- Render step: runs just AFTER the default ControlModule (priority Input) so our
	-- Humanoid:Move() call wins. This is what locks stick input during air/special moves
	-- and drives the slide direction.
	----------------------------------------------------------------------------
	RunService:BindToRenderStep(RENDER_NAME, Enum.RenderPriority.Input.Value + 1, function()
		if destroyed then return end
		if state == STATE.Sliding then
			humanoid:Move(slideDir, false)
		elseif LOCKED_STATES[state] then
			humanoid:Move(Vector3.zero, false)
		end
	end)

	connect(RunService.RenderStepped, updateShadow)

	----------------------------------------------------------------------------
	-- Main physics loop
	----------------------------------------------------------------------------
	local function fallMultiplier()
		if state == STATE.LongJumping then return CONFIG.LONG_JUMP_FALL_MULTIPLIER end
		if state == STATE.Airborne or state == STATE.Diving then return CONFIG.FALL_GRAVITY_MULTIPLIER end
		return 1
	end

	connect(RunService.Heartbeat, function(dt)
		if destroyed or humanoid.Health <= 0 then return end

		local now = os.clock()
		local vel = hrp.AssemblyLinearVelocity
		local flatVel = Vector3.new(vel.X, 0, vel.Z)
		local speed = flatVel.Magnitude
		local newVel = vel

		-- Ground pound camera shake
		if now < shakeUntil then
			local k = (shakeUntil - now) / CONFIG.GROUND_POUND_SHAKE_TIME
			local m = CONFIG.GROUND_POUND_SHAKE_MAGNITUDE * k
			humanoid.CameraOffset = Vector3.new((math.random() - 0.5) * 2 * m, (math.random() - 0.5) * 2 * m, 0)
			shaking = true
		elseif shaking then
			humanoid.CameraOffset = Vector3.zero
			shaking = false
		end

		-- While hanging we are anchored: nothing to simulate.
		if state == STATE.LedgeGrabbing then
			updateLocomotion(now, 0, vel)
			updateVfx(now, 0, false)
			return
		end

		local onGround = humanoid.FloorMaterial ~= Enum.Material.Air

		-- Landing / leaving the ground --------------------------------------------
		if AIR_STATES[state] then
			-- vel.Y < 8 stops the first frames of a jump (floor sensor still lagging) from
			-- being mistaken for a landing. (The Landed event handles the fast cases.)
			if onGround and vel.Y < 8 and (now - stateEnteredAt) > 0.05 then
				handleLanding(now, speed, flatVel)
			end
		elseif GROUND_STATES[state] or state == STATE.Sliding then
			if onGround then
				offGroundTime = 0
			else
				offGroundTime += dt
				if offGroundTime > CONFIG.COYOTE_TIME then
					offGroundTime = 0
					setState(STATE.Airborne) -- walked/slid off an edge
					airFromJump = false
				end
			end
		end

		-- Heavy falling: extra downward acceleration = g * (multiplier - 1) -----------
		if not onGround and newVel.Y < 0 then
			local mult = fallMultiplier()
			if mult ~= 1 then
				newVel = Vector3.new(newVel.X, newVel.Y - Workspace.Gravity * (mult - 1) * dt, newVel.Z)
			end
			if state == STATE.Airborne or state == STATE.Diving or state == STATE.LongJumping then
				newVel = Vector3.new(newVel.X, math.max(newVel.Y, -CONFIG.MAX_FALL_SPEED), newVel.Z)
			end
		end

		-- Per-state behaviour ----------------------------------------------------------
		if GROUND_STATES[state] then
			local want
			if crouchHeld then
				want = STATE.Crouching
			elseif speed > 1.5 then
				want = STATE.Running
			else
				want = STATE.Idle
			end
			setState(want)
			humanoid.WalkSpeed = (state == STATE.Crouching) and CONFIG.CROUCH_SPEED or CONFIG.RUN_SPEED

			-- Crouch vs CrouchWalk (CrouchWalk only if you provided that animation)
			if state == STATE.Crouching then
				local wantAnim = (speed > 1.5 and tracks.CrouchWalk) and "CrouchWalk" or "Crouch"
				if crouchAnimName ~= wantAnim then
					crouchAnimName = wantAnim
					playAnim(wantAnim)
				end
			end

		elseif state == STATE.Sliding then
			local friction = (slideKind == "Belly") and CONFIG.BELLY_SLIDE_FRICTION or CONFIG.SLIDE_FRICTION
			slideSpeed -= friction * dt -- constant deceleration: v(t) = v0 - friction * t
			local hitWall = (now - stateEnteredAt) > 0.2 and speed < slideSpeed * 0.3
			if slideSpeed <= CONFIG.SLIDE_END_SPEED or hitWall then
				endSlide()
			else
				humanoid.WalkSpeed = slideSpeed -- keeps Humanoid's own ground controller from fighting us
				newVel = Vector3.new(slideDir.X * slideSpeed, newVel.Y, slideDir.Z * slideSpeed)
			end

		elseif state == STATE.Airborne then
			if now >= ledgeCooldownUntil then
				local info = findLedge(vel)
				if info then
					grabLedge(info)
					return
				end
			end

			-- SM64 air physics: facing is locked (AutoRotate off + zeroed Move) and the takeoff
			-- velocity is carried through the whole jump. The stick only nudges it slightly.
			if not airVel then
				airVel = flatVel
				airSpeedCap = math.max(speed, CONFIG.AIR_DRIFT_MAX_SPEED)
			end
			if speed < airVel.Magnitude * 0.5 then
				airVel = flatVel -- we bumped into something: adopt the real (slower) velocity
			end
			if CONFIG.AIR_DRIFT_ACCEL > 0 then
				local input = getMoveInput()
				if input.Magnitude > 0.1 then
					airVel += input * CONFIG.AIR_DRIFT_ACCEL * dt
					if airVel.Magnitude > airSpeedCap then
						airVel = airVel.Unit * airSpeedCap
					end
				end
			end
			newVel = Vector3.new(airVel.X, newVel.Y, airVel.Z)

		elseif state == STATE.LongJumping then
			-- No air drag: horizontal speed is pinned to the launch speed for the whole jump.
			newVel = Vector3.new(longDir.X * longSpeed, newVel.Y, longDir.Z * longSpeed)

		elseif state == STATE.Diving then
			newVel = Vector3.new(diveDir.X * diveSpeed, newVel.Y, diveDir.Z * diveSpeed)

		elseif state == STATE.GroundPoundSpin then
			newVel = Vector3.zero -- hover: cancels gravity completely
			if (now - stateEnteredAt) >= CONFIG.GROUND_POUND_HOVER_TIME then
				setState(STATE.GroundPoundFall)
			end

		elseif state == STATE.GroundPoundFall then
			newVel = Vector3.new(0, -CONFIG.GROUND_POUND_SPEED, 0)

		elseif state == STATE.GroundPoundLand then
			humanoid.WalkSpeed = 0
			humanoid.JumpPower = 0
			if (now - stateEnteredAt) >= CONFIG.GROUND_POUND_RECOVERY then
				setState(STATE.Idle)
			end

		elseif state == STATE.LedgeClimbing then
			-- Rise straight up hugging the wall, then shove forward once above the lip.
			newVel = Vector3.new(0, newVel.Y, 0)
			local cleared = ledgeInfo and hrp.Position.Y >= ledgeInfo.top + CONFIG.LEDGE_CLEAR_HEIGHT
			if cleared or (now - stateEnteredAt) > 1 then
				if ledgeInfo then
					local push = -ledgeInfo.normal * CONFIG.LEDGE_FORWARD_SPEED
					newVel = Vector3.new(push.X, newVel.Y, push.Z)
				end
				setState(STATE.Airborne)
				airFromJump = true
			end
		end

		-- Pre-load the JumpPower for whatever the next jump will be --------------------
		if GROUND_STATES[state] or state == STATE.Sliding or AIR_STATES[state] then
			if state ~= STATE.GroundPoundFall then
				updateJumpPlan(onGround, speed, now)
			end
		end

		-- Idle / Walk / Run / Jump / Fall / Land overrides ------------------------------
		updateLocomotion(now, speed, vel)

		-- Footstep dust and slide smoke --------------------------------------------------
		updateVfx(now, speed, onGround)

		-- Remember the hardest downward speed of this fall for the landing puff.
		if AIR_STATES[state] then
			maxFallSpeed = math.max(maxFallSpeed, -vel.Y)
		end

		if newVel ~= vel then
			hrp.AssemblyLinearVelocity = newVel
		end
	end)

	----------------------------------------------------------------------------
	-- Cleanup (death, respawn, character removal, re-execution)
	----------------------------------------------------------------------------
	destroy = function()
		if destroyed then return end
		destroyed = true

		for _, c in ipairs(connections) do
			c:Disconnect()
		end
		table.clear(connections)

		pcall(function() RunService:UnbindFromRenderStep(RENDER_NAME) end)
		pcall(function() ContextActionService:UnbindAction(ACTION_CROUCH) end)
		pcall(function() ContextActionService:UnbindAction(ACTION_POUND) end)

		for _, track in pairs(tracks) do
			pcall(function()
				track:Stop(0)
				track:Destroy()
			end)
		end
		table.clear(tracks)
		for _, track in pairs(locoTracks) do
			pcall(function()
				track:Stop(0)
				track:Destroy()
			end)
		end
		table.clear(locoTracks)
		for _, animation in ipairs(animationInstances) do
			animation:Destroy()
		end
		table.clear(animationInstances)
		currentTrack = nil
		currentLocoTrack = nil
		currentLoco = nil

		-- Give the default Animate script back if we turned it off.
		if CONFIG.DISABLE_DEFAULT_ANIMATE and animateScript and animateScript.Parent then
			pcall(function() animateScript.Enabled = true end)
			pcall(function() animateScript.Disabled = false end)
		end

		for _, sound in pairs(sounds) do
			pcall(function()
				sound:Stop()
				sound:Destroy()
			end)
		end
		table.clear(sounds)

		if shadow then
			shadow:Destroy()
			shadow = nil
		end

		if feetAttachment then
			feetAttachment:Destroy() -- also removes the particle emitters parented to it
			feetAttachment = nil
		end
		table.clear(vfxEmitters)

		if hrp and hrp.Parent then
			hrp.Anchored = false
		end
		if humanoid and humanoid.Parent then
			humanoid.AutoRotate = true
			humanoid.CameraOffset = Vector3.zero
		end

		Workspace.Gravity = ORIGINAL_GRAVITY
		ledgeInfo = nil
	end

	connect(humanoid.Died, destroy)
	connect(character.AncestryChanged, function(_, parent)
		if not parent then destroy() end
	end)

	return { Destroy = destroy }
end

--==============================================================================
-- 4. CHARACTER LIFECYCLE (location-independent)
--==============================================================================
local activeController = nil
local characterConnection = nil
local shuttingDown = false

local function attach(character)
	if shuttingDown then return end

	if activeController then
		activeController.Destroy()
		activeController = nil
	end

	local ok, result = pcall(createController, character)
	if not ok then
		warn("[SM64] Failed to start controller: " .. tostring(result))
		return
	end
	local controller = result
	if not controller then return end

	-- The character may have been replaced (or the script shut down) while we were waiting.
	if shuttingDown or player.Character ~= character then
		controller.Destroy()
		return
	end

	activeController = controller
	print("[SM64] Controller active")
end

-- Called when this script is run again, so copies never stack up.
env.SM64_Cleanup = function()
	shuttingDown = true
	if characterConnection then
		characterConnection:Disconnect()
		characterConnection = nil
	end
	if activeController then
		activeController.Destroy()
		activeController = nil
	end
	env.SM64_Cleanup = nil
end

characterConnection = player.CharacterAdded:Connect(attach)
if player.Character then
	task.spawn(attach, player.Character)
end
