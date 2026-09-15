-- Шаги, прыжки, приземления и лестница (v5, агент AUDIO; docs/SPEC_v5.md 2.1).
-- Свой персонаж и игроки ближе 60 studs к камере. Материал — Humanoid.FloorMaterial (запасной
-- вариант — луч вниз), темп — от горизонтальной скорости относительно пола (в едущем автобусе нет
-- «шагов на месте»), свои шаги 2D и тише от первого лица, чужие — 3D у ног. Прыжок/приземление
-- (громкость от скорости падения), ladder_climb при лазании. Стандартные звуки бега и прыжка Roblox
-- (RbxCharacterSounds) глушатся, чтобы шаги не двоились. Instance каждый кадр не создаются.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Footsteps = {}
local C
local player = Players.LocalPlayer

local RANGE = 60 -- дальше от камеры чужие шаги не считаем
local MIN_SPEED = 2.5 -- медленнее — стоим
local SPRINT_SPEED = 19.5 -- ходьба 16, бег 16 * 1.45
local FIRST_PERSON_VOLUME = 0.55
local THIRD_PERSON_VOLUME = 0.8
local HT = Enum.HumanoidStateType
local AIR = Enum.Material.Air
local WATER = Enum.Material.Water

local MATERIAL_KEY = {
	Grass = "footstep_grass", LeafyGrass = "footstep_grass",
	Ground = "footstep_dirt", Mud = "footstep_dirt", Pebble = "footstep_dirt",
	Fabric = "footstep_dirt", Carpet = "footstep_dirt", Leather = "footstep_dirt", Rubber = "footstep_dirt",
	Wood = "footstep_wood", WoodPlanks = "footstep_wood", Cardboard = "footstep_wood",
	Metal = "footstep_metal", CorrodedMetal = "footstep_metal", DiamondPlate = "footstep_metal", Foil = "footstep_metal",
	Concrete = "footstep_concrete", Asphalt = "footstep_concrete", Brick = "footstep_concrete",
	Pavement = "footstep_concrete", Cobblestone = "footstep_concrete", Slate = "footstep_concrete",
	Rock = "footstep_concrete", Basalt = "footstep_concrete", Limestone = "footstep_concrete",
	Granite = "footstep_concrete", Marble = "footstep_concrete", CrackedLava = "footstep_concrete",
	Snow = "footstep_snow", Ice = "footstep_snow", Glacier = "footstep_snow",
	Sand = "footstep_sand", Sandstone = "footstep_sand", Salt = "footstep_sand",
}
local DEFAULT_KEY = "footstep_concrete" -- пластик, стекло, неон и прочее

-- свои звуки состояний, при которых шагов нет
local SILENT_LOCAL = {
	[HT.Seated] = true, [HT.Dead] = true, [HT.Swimming] = true, [HT.Physics] = true, [HT.Ragdoll] = true,
	[HT.FallingDown] = true, [HT.PlatformStanding] = true, [HT.GettingUp] = true,
}
-- стандартные звуки RbxCharacterSounds, которые заменяет этот модуль
local DEFAULT_SOUNDS = { Running = true, Climbing = true, Jumping = true, Landing = true }
local FILTER_FOLDERS = { "ClientFX", "Effects", "Zombies", "Loot" }

local tracked = {} -- Player -> состояние
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true
local filterDirty = true
local filterAt = -10
local reportedError = false

local function play(key, where, volume, pitch)
	C.SoundFX.Play(key, where, { volume = volume, pitch = pitch })
end

-- Где звучать: свои — 2D (громкость по виду камеры), чужие — у ног
local function place(st)
	if st.isLocal then
		local cam = workspace.CurrentCamera
		local head = st.head
		local firstPerson = cam ~= nil and head ~= nil and head.Parent ~= nil and (cam.CFrame.Position - head.Position).Magnitude < 2.5
		return nil, firstPerson and FIRST_PERSON_VOLUME or THIRD_PERSON_VOLUME
	end
	return st.feet, 1
end

local function floorKey(st)
	local mat = st.hum.FloorMaterial
	if mat == AIR then
		mat = st.rayMat
	end
	if mat == nil or mat == AIR or mat == WATER then
		return nil
	end
	return MATERIAL_KEY[mat.Name] or DEFAULT_KEY
end

local function stepSound(st, speed)
	local key = floorKey(st)
	if not key then
		return
	end
	st.side = not st.side
	local volume = speed >= SPRINT_SPEED and 1 or math.clamp(0.45 + speed / 32, 0.5, 0.9)
	local where, mult = place(st)
	play(key, where, volume * mult, st.side and 1.03 or 0.97)
end

local function jumpSound(st)
	local where, mult = place(st)
	play("jump", where, mult)
end

local function landSound(st, now)
	local airTime = now - st.airT
	local fall = -st.minVy
	st.grounded = true
	st.phase = 0.5
	if airTime < 0.15 and fall < 14 then
		return -- ступенька, бордюр
	end
	local k = math.clamp((fall - 10) / 50, 0, 1)
	local where, mult = place(st)
	play("land", where, (0.35 + 0.65 * k) * mult, 1.05 - 0.2 * k)
	local key = floorKey(st)
	if key then
		play(key, where, (0.6 + 0.5 * k) * mult, 0.9)
	end
end

local function muteDefault(st, child)
	if child:IsA("Sound") and DEFAULT_SOUNDS[child.Name] then
		child.Volume = 0
		child.SoundId = ""
		table.insert(st.conns, child:GetPropertyChangedSignal("Volume"):Connect(function()
			if child.Volume ~= 0 then
				child.Volume = 0
			end
		end))
	end
end

local function muteDefaults(st, part)
	for _, child in ipairs(part:GetChildren()) do
		muteDefault(st, child)
	end
	table.insert(st.conns, part.ChildAdded:Connect(function(child)
		muteDefault(st, child)
	end))
end

local function onLocalState(st, new)
	local now = os.clock()
	if new == HT.Jumping then
		if st.grounded then
			st.grounded = false
			st.airT = now
			st.minVy = 0
			jumpSound(st)
		end
	elseif new == HT.Freefall then
		if st.grounded then
			st.grounded = false
			st.airT = now
			st.minVy = 0
		end
	elseif new == HT.Landed or new == HT.Running or new == HT.RunningNoPhysics then
		if not st.grounded and st.hum then
			landSound(st, now)
		end
	elseif new == HT.Climbing or new == HT.Seated or new == HT.Swimming then
		st.grounded = true
	end
end

local function unbind(st)
	for _, conn in ipairs(st.conns) do
		conn:Disconnect()
	end
	table.clear(st.conns)
	st.char, st.hum, st.root, st.head = nil, nil, nil, nil
	filterDirty = true
end

local function bind(st, char)
	unbind(st)
	st.char = char
	filterDirty = true
	task.spawn(function()
		local hum = char:WaitForChild("Humanoid", 10)
		local root = char:WaitForChild("HumanoidRootPart", 10)
		if st.char ~= char or not hum or not root or not hum:IsA("Humanoid") or not root:IsA("BasePart") then
			return
		end
		st.hum, st.root = hum, root
		st.head = char:FindFirstChild("Head")
		st.grounded, st.phase, st.climbPhase = true, 0.6, 0.7
		muteDefaults(st, root)
		if st.head and st.head:IsA("BasePart") then
			muteDefaults(st, st.head)
		end
		if st.isLocal then
			table.insert(st.conns, hum.StateChanged:Connect(function(_, new)
				onLocalState(st, new)
			end))
		end
	end)
end

local function track(plr)
	if tracked[plr] then
		return
	end
	local st = {
		plr = plr, isLocal = plr == player, conns = {}, phase = 0.6, climbPhase = 0.7, side = false,
		grounded = true, airT = 0, minVy = 0, feet = nil, rayMat = nil,
	}
	tracked[plr] = st
	st.charConn = plr.CharacterAdded:Connect(function(char)
		bind(st, char)
	end)
	st.removeConn = plr.CharacterRemoving:Connect(function()
		unbind(st)
	end)
	if plr.Character then
		bind(st, plr.Character)
	end
end

local function untrack(plr)
	local st = tracked[plr]
	if not st then
		return
	end
	unbind(st)
	st.charConn:Disconnect()
	st.removeConn:Disconnect()
	tracked[plr] = nil
end

local function refreshFilter(now)
	if not filterDirty and now - filterAt < 2 then
		return
	end
	filterDirty = false
	filterAt = now
	local list = {}
	local cam = workspace.CurrentCamera
	if cam then
		table.insert(list, cam)
	end
	for _, st in pairs(tracked) do
		if st.char then
			table.insert(list, st.char)
		end
	end
	for _, name in ipairs(FILTER_FOLDERS) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(list, f)
		end
	end
	rayParams.FilterDescendantsInstances = list
end

local function resetMotion(st)
	st.phase = 0.6
	st.climbPhase = 0.7
end

local function updateOne(st, dt, camPos, now)
	local hum, root = st.hum, st.root
	if not hum or not root or root.Parent == nil or hum.Health <= 0 then
		return
	end
	if not st.isLocal and (camPos == nil or (root.Position - camPos).Magnitude > RANGE) then
		resetMotion(st)
		st.grounded = true
		return
	end
	local plr = st.plr
	local state = hum:GetState()
	if hum.SeatPart or hum.PlatformStand or state == HT.Dead or plr:GetAttribute("Downed") == true or plr:GetAttribute("Sleeping") == true then
		resetMotion(st)
		return
	end
	if st.isLocal and SILENT_LOCAL[state] then
		resetMotion(st)
		return
	end

	-- луч вниз: точка у ног, материал, скорость пола (автобус), есть ли опора
	local toGround = hum.RigType == Enum.HumanoidRigType.R15 and (hum.HipHeight + root.Size.Y * 0.5) or (root.Size.Y * 0.5 + 2)
	local origin = root.Position
	local hit = workspace:Raycast(origin, Vector3.new(0, -(toGround + 2.5), 0), rayParams)
	local vel = root.AssemblyLinearVelocity
	if hit then
		st.feet = hit.Position
		st.rayMat = hit.Material
		if hit.Instance and hit.Instance:IsA("BasePart") then
			vel = vel - hit.Instance:GetVelocityAtPosition(hit.Position)
		end
	else
		st.feet = origin - Vector3.new(0, toGround, 0)
		st.rayMat = nil
	end

	-- чужие: прыжок/приземление по опоре под ногами (состояние Humanoid у чужих ненадёжно)
	if not st.isLocal and state ~= HT.Climbing then
		local onGround = hit ~= nil and origin.Y - hit.Position.Y <= toGround + 0.9
		if st.grounded and not onGround then
			st.grounded = false
			st.airT = now
			st.minVy = 0
			if vel.Y > 10 then
				jumpSound(st)
			end
		elseif not st.grounded and onGround then
			landSound(st, now)
		end
	end
	if not st.grounded then
		st.minVy = math.min(st.minVy, vel.Y)
		st.phase = 0.6
		return
	end

	-- лестница
	if state == HT.Climbing then
		st.phase = 0.6
		local vy = math.abs(vel.Y)
		if vy > 1.5 then
			st.climbPhase = st.climbPhase + vy * dt / 2.4
			if st.climbPhase >= 1 then
				st.climbPhase = st.climbPhase % 1
				local where, mult = place(st)
				play("ladder_climb", where, mult, st.side and 1.04 or 0.96)
				st.side = not st.side
			end
		else
			st.climbPhase = 0.7
		end
		return
	end
	st.climbPhase = 0.7

	-- шаги: фаза шага растёт с пройденным расстоянием, длина шага чуть больше на бегу
	local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
	local moving = speed > MIN_SPEED and (not st.isLocal or hum.MoveDirection.Magnitude > 0.05)
	if not moving then
		st.phase = 0.6
		return
	end
	st.phase = st.phase + speed * dt / (4.9 + speed * 0.1)
	if st.phase >= 1 then
		st.phase = st.phase % 1
		stepSound(st, speed)
	end
end

function Footsteps.Init(c)
	C = c
	if not (C and C.SoundFX) then
		return
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		track(plr)
	end
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(untrack)
	RunService.Heartbeat:Connect(function(dt)
		local now = os.clock()
		refreshFilter(now)
		local cam = workspace.CurrentCamera
		local camPos = cam and cam.CFrame.Position
		for _, st in pairs(tracked) do
			local ok, err = pcall(updateOne, st, math.min(dt, 0.1), camPos, now)
			if not ok and not reportedError then
				reportedError = true
				warn("[Footsteps] " .. tostring(err))
			end
		end
	end)
end

return Footsteps
