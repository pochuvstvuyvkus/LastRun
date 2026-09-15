-- Автобус на клиенте (v5): водитель жмёт W — газ, S — тормоз (без руля). Подсказки «Прикрепить: …» на
-- метках слотов (тег LR_BusSlot) видны только тем, у кого есть подходящая деталь в инвентаре; колёса и
-- стены носят руками — их подсказку рисует GrabClient.
-- Колёса и стрелки приборов: серверные детали жёсткие и скрыты локально (LocalTransparencyModifier),
-- а их визуальные копии клиент каждый кадр ставит относительно корня автобуса. В v4 клиент крутил
-- Motor6D.Transform, но сборкой владеет сервер — в Studio стрелки и колёса не двигались.
-- Лестница на крышу держит игрока, пока автобус едет; выхлоп и пыль — по скорости.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Config = require(Shared.Config)
local BusParts = require(Shared.BusParts)

local BusClient = {}
local C
local player = Players.LocalPlayer
local controls = nil
local driving = false
local lastThrottle = 0
local lastSend = 0
local promptAcc = 0

local SLOT_TAG = "LR_BusSlot" -- метка слота (BasePart); подсказка — дочерняя ProximityPrompt
local WHEEL_TAG = "LR_BusWheel" -- шина колеса (BasePart), атрибут Radius
local GAUGE_TAG = "LR_BusGauge" -- стрелка прибора (BasePart), атрибуты Gauge, Angle0, Angle1, RestAngle, PivotShift
local FX_TAG = "LR_BusFx" -- ParticleEmitter, атрибут Fx = "exhaust" | "dust"
local LADDER_TAG = "LR_BusLadder" -- ферма лестницы на крышу
local NO_TURRET = { active = false, heat = 0, overheated = false, level = 0 }
local TAU = math.pi * 2
local DISPLAY_MULT = Config.Bus.SpeedDisplayMult or 1
local MAX_SPEED = Config.Bus.MaxSpeed or 48

local DUST_BY_BIOME = {
	desert = Color3.fromRGB(196, 170, 122),
	snow = Color3.fromRGB(228, 232, 238),
	swamp = Color3.fromRGB(82, 76, 60),
	jungle = Color3.fromRGB(98, 86, 62),
	city = Color3.fromRGB(122, 118, 112),
	wasteland = Color3.fromRGB(142, 120, 92),
}
local DUST_DEFAULT = Color3.fromRGB(120, 108, 92)

local visuals = {} -- [серверная деталь с тегом] = { kind, root, server, copies, rel, ... }
local visFolder = nil
local movedParts, movedCFrames = {}, {}
local emitters = {} -- [ParticleEmitter] = цвет пыли, применённый последним
local stateFolder = nil
local busSpeed = 0 -- studs/сек со знаком (сглаженная)
local fxAcc, scanAcc = 0, 0
local ladderPart = nil -- ферма лестницы (обновляется раз в секунду)

function BusClient.IsDriving()
	return driving
end

-- Совместимость: управляемой башни больше нет
function BusClient.IsGunner()
	return false
end

function BusClient.GetTurretState()
	return NO_TURRET
end

local function anyKey(keys)
	for _, key in ipairs(keys) do
		if UserInputService:IsKeyDown(key) then
			return true
		end
	end
	return false
end

local function numAttr(st, name)
	local v = st and st:GetAttribute(name)
	return type(v) == "number" and v or nil
end

local function hasPartFor(slotType)
	local def = BusParts.Slots[slotType]
	local inv = C and C.State and C.State.Inventory
	if not def or type(inv) ~= "table" then
		return false
	end
	for _, id in ipairs(def.accepts) do
		if (tonumber(inv[id]) or 0) > 0 then
			return true
		end
	end
	return false
end

-- Подсказка на метке слота: только для свободного слота и только если деталь есть в инвентаре
-- (колёса и стены носят руками — их подсказку рисует GrabClient)
local function refreshSlot(marker)
	if typeof(marker) ~= "Instance" or not marker:IsA("BasePart") then
		return
	end
	local prompt = marker:FindFirstChildOfClass("ProximityPrompt")
	local slotType = marker:GetAttribute("SlotType")
	if not prompt or type(slotType) ~= "string" then
		return
	end
	local want = marker:GetAttribute("Free") ~= false and hasPartFor(slotType)
	if prompt.Enabled ~= want then
		prompt.Enabled = want
	end
end

local function readThrottle()
	if UserInputService:GetFocusedTextBox() then
		return 0
	end
	local throttle = 0
	if anyKey({ Enum.KeyCode.W, Enum.KeyCode.Up }) then
		throttle = throttle + 1
	end
	if anyKey({ Enum.KeyCode.S, Enum.KeyCode.Down }) then
		throttle = throttle - 1
	end
	if throttle == 0 then
		local okPad, r2, l2 = pcall(function()
			return UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonR2), UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonL2)
		end)
		if okPad then
			throttle = (r2 and 1 or 0) - (l2 and 1 or 0)
		end
	end
	if throttle == 0 and controls then
		local ok, mv = pcall(function()
			return controls:GetMoveVector()
		end)
		if ok and mv and math.abs(mv.Z) > 0.3 then
			throttle = mv.Z < 0 and 1 or -1
		end
	end
	return throttle
end

-- Визуальные копии колёс и стрелок --------------------------------------------------------------------

local function busRootOf(part)
	local model = part:FindFirstAncestor("Bus")
	local root = model and (model:FindFirstChild("BusRoot") or model.PrimaryPart)
	return (root and root:IsA("BasePart")) and root or nil
end

-- Неподвижная копия серверной детали: её CFrame клиент ставит сам
local function copyPart(src)
	local ok, c = pcall(Instance.new, src.ClassName)
	if not ok or typeof(c) ~= "Instance" or not c:IsA("BasePart") then
		c = Instance.new("Part")
	end
	c.Name = src.Name
	c.Size = src.Size
	c.Color = src.Color
	c.Material = src.Material
	c.Transparency = src.Transparency
	c.Reflectance = src.Reflectance
	c.CastShadow = src.CastShadow
	if c:IsA("Part") and src:IsA("Part") then
		c.Shape = src.Shape
	end
	c.Anchored = true
	c.CanCollide = false
	c.CanQuery = false
	c.CanTouch = false
	c.CFrame = src.CFrame
	c.Parent = visFolder
	return c
end

local function releaseVisual(key)
	local v = visuals[key]
	if not v then
		return
	end
	visuals[key] = nil
	for _, c in ipairs(v.copies) do
		c:Destroy()
	end
	for _, p in ipairs(v.server) do
		if p.Parent then
			p.LocalTransparencyModifier = 0
		end
	end
end

-- Колесо: шина с тегом и все детали её модели (смещения жёсткие — читаем один раз)
local function buildWheelVisual(tire)
	local root = busRootOf(tire)
	local model = tire.Parent
	if not root or not model or not model:IsA("Model") then
		return nil
	end
	local r = tire:GetAttribute("Radius")
	local tireCF = tire.CFrame
	local v = {
		kind = "wheel",
		root = root,
		model = model,
		mount = root.CFrame:ToObjectSpace(tireCF),
		radius = (type(r) == "number" and r > 0.1) and r or 2.3,
		spin = 0,
		server = {},
		copies = {},
		rel = {},
	}
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			table.insert(v.server, p)
			table.insert(v.rel, tireCF:ToObjectSpace(p.CFrame))
			table.insert(v.copies, copyPart(p))
			p.LocalTransparencyModifier = 1
		end
	end
	v.count = #v.server
	return v
end

-- Стрелка прибора: кадр циферблата = поза стрелки без поворота
local function buildNeedleVisual(needle)
	local root = busRootOf(needle)
	if not root then
		return nil
	end
	local shift = tonumber(needle:GetAttribute("PivotShift")) or 0
	local rest = tonumber(needle:GetAttribute("RestAngle")) or 0
	local v = {
		kind = "needle",
		root = root,
		gauge = needle:GetAttribute("Gauge"),
		a0 = tonumber(needle:GetAttribute("Angle0")) or rest,
		a1 = tonumber(needle:GetAttribute("Angle1")) or rest,
		angle = rest,
		shift = CFrame.new(0, shift, 0),
		dial = root.CFrame:ToObjectSpace(needle.CFrame) * CFrame.new(0, -shift, 0) * CFrame.Angles(0, 0, -rest),
		server = { needle },
		copies = { copyPart(needle) },
		rel = {},
		count = 1,
	}
	needle.LocalTransparencyModifier = 1
	return v
end

local function track(inst, builder)
	if visuals[inst] or typeof(inst) ~= "Instance" or not inst:IsA("BasePart") or not inst:IsDescendantOf(workspace) then
		return
	end
	local ok, v = pcall(builder, inst)
	if ok and v then
		visuals[inst] = v
	end
end

-- Раз в секунду: убрать пропавшее, подхватить новое, снова спрятать серверные детали
local function scanVisuals()
	for key, v in pairs(visuals) do
		local alive = key.Parent ~= nil and v.root.Parent ~= nil and key:IsDescendantOf(workspace)
		if alive and v.kind == "wheel" then
			local n = 0
			for _, d in ipairs(v.model:GetDescendants()) do
				if d:IsA("BasePart") then
					n = n + 1
				end
			end
			alive = n == v.count
		end
		if alive then
			for _, p in ipairs(v.server) do
				if p.Parent and p.LocalTransparencyModifier < 1 then
					p.LocalTransparencyModifier = 1
				end
			end
		else
			releaseVisual(key)
		end
	end
	for _, tire in ipairs(CollectionService:GetTagged(WHEEL_TAG)) do
		track(tire, buildWheelVisual)
	end
	for _, needle in ipairs(CollectionService:GetTagged(GAUGE_TAG)) do
		track(needle, buildNeedleVisual)
	end
	if not ladderPart or not ladderPart.Parent then
		ladderPart = CollectionService:GetTagged(LADDER_TAG)[1]
	end
end

-- Каждый кадр: колёса крутятся по скорости, стрелки идут к своим значениям
local function stepVisuals(dt, st)
	if next(visuals) == nil then
		return
	end
	local fuel, fuelMax = numAttr(st, "Fuel"), numAttr(st, "FuelMax")
	local fuelFrac = (fuel and fuelMax and fuelMax > 0) and math.clamp(fuel / fuelMax, 0, 1) or 0
	local speedFrac = math.clamp(math.abs(busSpeed) / MAX_SPEED, 0, 1)
	local k = math.min(1, dt * 6)
	local n = 0
	for key, v in pairs(visuals) do
		if key.Parent and v.root.Parent then
			local rootCF = v.root.CFrame
			if v.kind == "wheel" then
				v.spin = (v.spin - busSpeed / v.radius * dt) % TAU
				local tireCF = rootCF * v.mount * CFrame.Angles(v.spin, 0, 0)
				for i, c in ipairs(v.copies) do
					n = n + 1
					movedParts[n] = c
					movedCFrames[n] = tireCF * v.rel[i]
				end
			else
				local want = v.a0 + (v.a1 - v.a0) * (v.gauge == "fuel" and fuelFrac or speedFrac)
				v.angle = v.angle + (want - v.angle) * k
				n = n + 1
				movedParts[n] = v.copies[1]
				movedCFrames[n] = rootCF * v.dial * CFrame.Angles(0, 0, v.angle) * v.shift
			end
		end
	end
	for i = #movedParts, n + 1, -1 do
		movedParts[i] = nil
		movedCFrames[i] = nil
	end
	if n > 0 then
		workspace:BulkMoveTo(movedParts, movedCFrames, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Выхлоп и пыль: включаются по скорости, несколько раз в секунду
local function stepEmitters(dt, st)
	fxAcc = fxAcc + dt
	if fxAcc < 0.15 or next(emitters) == nil then
		return
	end
	fxAcc = 0
	local driverName = st and st:GetAttribute("DriverName")
	local engineOn = type(driverName) == "string" and driverName ~= ""
	local hasFuel = (numAttr(st, "Fuel") or 0) > 0
	local kmh = math.abs(busSpeed) * DISPLAY_MULT
	local biome = st and st:GetAttribute("BiomeId")
	local dustColor = DUST_BY_BIOME[biome] or DUST_DEFAULT
	for e, applied in pairs(emitters) do
		if e.Parent then
			local kind = e:GetAttribute("Fx")
			local rate = 0
			if kind == "exhaust" then
				if hasFuel and (engineOn or kmh > 1) then
					rate = 3 + kmh * 0.3
				end
			elseif kind == "dust" then
				if kmh > 8 then
					rate = kmh * 0.35
				end
				if applied ~= dustColor then
					emitters[e] = dustColor
					e.Color = ColorSequence.new(dustColor)
				end
			end
			local on = rate > 0.5
			if e.Enabled ~= on then
				e.Enabled = on
			end
			if on and math.abs(e.Rate - rate) > 1 then
				e.Rate = rate
			end
		else
			emitters[e] = nil
		end
	end
end

-- Лестница на крышу: пока игрок лезет, он едет вместе с автобусом и держится оси лестницы
local function ladderAssist()
	if math.abs(busSpeed) < 1 then
		return
	end
	local ladder = ladderPart
	if not ladder or not ladder.Parent then
		return
	end
	local root = busRootOf(ladder)
	if not root then
		return
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not hrp or hum.Health <= 0 or hum:GetState() ~= Enum.HumanoidStateType.Climbing then
		return
	end
	local lcf = ladder.CFrame
	local lp = lcf:PointToObjectSpace(hrp.Position)
	if math.abs(lp.X) > 2.5 or math.abs(lp.Z) > 3.5 or math.abs(lp.Y) > ladder.Size.Y / 2 + 3 then
		return
	end
	local busVel = root.CFrame.LookVector * busSpeed
	local lateral = lcf.RightVector * (-lp.X * 4)
	local v = hrp.AssemblyLinearVelocity
	hrp.AssemblyLinearVelocity = Vector3.new(busVel.X + lateral.X, v.Y, busVel.Z + lateral.Z)
end

local function onRender(dt)
	stateFolder = stateFolder or ReplicatedStorage:FindFirstChild("GameState")
	local st = stateFolder

	local target = (numAttr(st, "Speed") or 0) / DISPLAY_MULT
	if st and st:GetAttribute("BusDir") == -1 then
		target = -target
	end
	busSpeed = busSpeed + (target - busSpeed) * math.min(1, dt * 6)
	if target == 0 and math.abs(busSpeed) < 0.05 then
		busSpeed = 0
	end

	stepVisuals(dt, st)
	stepEmitters(dt, st)

	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local seat = hum and hum.Health > 0 and hum.SeatPart
	local now = os.clock()
	if seat and seat.Name == "DriverSeat" then
		driving = true
		local throttle = readThrottle()
		if throttle ~= lastThrottle or now - lastSend > 0.5 then
			lastThrottle, lastSend = throttle, now
			Net.Get("DriveInput"):FireServer(throttle, 0)
		end
	elseif driving then
		driving = false
		lastThrottle = 0
		Net.Get("DriveInput"):FireServer(0, 0)
	end

	promptAcc = promptAcc + dt
	if promptAcc >= 0.5 then
		promptAcc = 0
		for _, marker in ipairs(CollectionService:GetTagged(SLOT_TAG)) do
			refreshSlot(marker)
		end
	end

	scanAcc = scanAcc + dt
	if scanAcc >= 1 then
		scanAcc = 0
		scanVisuals()
	end
end

function BusClient.Init(c)
	C = c
	visFolder = Instance.new("Folder")
	visFolder.Name = "BusVisuals"
	visFolder.Parent = workspace

	task.spawn(function()
		local ok, module = pcall(function()
			return require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule", 10))
		end)
		if ok and module then
			controls = module:GetControls()
		end
	end)

	CollectionService:GetInstanceAddedSignal(SLOT_TAG):Connect(refreshSlot)
	for _, marker in ipairs(CollectionService:GetTagged(SLOT_TAG)) do
		refreshSlot(marker)
	end

	for _, tag in ipairs({ WHEEL_TAG, GAUGE_TAG }) do
		local builder = tag == WHEEL_TAG and buildWheelVisual or buildNeedleVisual
		CollectionService:GetInstanceAddedSignal(tag):Connect(function(inst)
			-- ждём, пока доедут остальные детали модели
			task.delay(0.15, function()
				track(inst, builder)
			end)
		end)
		CollectionService:GetInstanceRemovedSignal(tag):Connect(releaseVisual)
	end

	CollectionService:GetInstanceAddedSignal(FX_TAG):Connect(function(inst)
		if inst:IsA("ParticleEmitter") and emitters[inst] == nil then
			emitters[inst] = false
		end
	end)
	CollectionService:GetInstanceRemovedSignal(FX_TAG):Connect(function(inst)
		emitters[inst] = nil
	end)
	for _, e in ipairs(CollectionService:GetTagged(FX_TAG)) do
		if e:IsA("ParticleEmitter") then
			emitters[e] = false
		end
	end

	scanVisuals()
	RunService.RenderStepped:Connect(onRender)
	RunService.Heartbeat:Connect(ladderAssist)
end

return BusClient
