-- Автобус (v5): разбитый ржавый школьный автобус с капотом, едет только вперёд по дороге (газ/тормоз, без руля).
-- Нижняя часть бортов цела, оконная зона спилена рваными краями, от стоек остались обломки — стены (дерево или
-- металл) ставят сами игроки: 8 секций по бортам и задняя. Вход — передняя дверь со складными створками и
-- ступенями внутрь. В депо автобус собирают: 4 колеса + топливо в печь (печь — в конце салона по центру).
-- Детали (shared/BusParts) крепятся к слотам. У каждого слота невидимая метка: тег LR_BusSlot, атрибуты
-- SlotType, SlotIndex, Accepts, Free, CFrame установленной детали (по меткам GRAB рисует призраки).
-- Без колёс автобус лежит на голых ступицах; каждое колесо плавно поднимает свой угол.
-- Колёса и стрелки приборов на сервере жёсткие; вращает их клиент (BusClient) визуальными копиями.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Items = require(Shared.Items)
local Classes = require(Shared.Classes)
local BusParts = require(Shared.BusParts)
local Sounds = require(Shared.Sounds)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local Bus = {
	S = 70,
	D = 0,
	V = 0,
	Psi = 0,
	HP = Config.Bus.MaxHP,
	MaxHP = Config.Bus.MaxHP,
	Fuel = 0,
	FuelMax = Config.Bus.FuelMax,
	Model = nil,
	Root = nil,
	Driver = nil,
	Gunner = nil,
	Throttle = 0,
	Steer = 0,
	Wheels = 0,
	Ready = false,
	Type = "school",
	TypeDef = { id = "school", name = "Школьный автобус", length = 44, width = 12, hp = Config.Bus.MaxHP, beds = 2, fuelMax = Config.Bus.FuelMax },
	Position = Vector3.zero,
	Heading = 0,
	BrokenNotified = false,
	Lift = { 0, 0, 0, 0 }, -- подъём углов колёсами: 0 — угол лежит на ступице, 1 — стоит на колесе
}

local S
local PD
local rng = Random.new()
local rgb = Color3.fromRGB
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local rad = math.rad

-- Палитра: ржавый жёлтый кузов, тёмная рама
local RUST = rgb(176, 116, 38)
local RUST_DARK = rgb(112, 70, 32)
local FRAME = rgb(38, 36, 34)
local STRIPE = rgb(24, 22, 20)
local METAL = rgb(96, 94, 90)
local FLOOR_C = rgb(92, 94, 96)
local AMBER = rgb(255, 196, 96)
local GLASS = rgb(150, 180, 185)

local M = Enum.Material
local WAYPOINT = "LR_Waypoint"
local SLOT_TAG = "LR_BusSlot" -- метки слотов (BasePart)
local GRAB_TAG = "LR_Grabbable" -- переносимые объекты модуля GRAB

-- Геометрия (локальные оси корня: -Z вперёд, пол на y = 0.5, земля на y = -3 при полной высоте)
local HL, HW = 22, 6
local FLOOR, SILL, HEAD, ROOF_BOTTOM, ROOF_TOP = 0.5, 3.5, 7.3, 8.7, 9.1
local WHEEL_Y, WHEEL_R, HUB_R = -0.7, 2.3, 1.0
local FRONT_WHEEL_Z, REAR_WHEEL_Z = -18.2, 13
local CAB_Z = -15 -- лобовая стена кабины, впереди — капот
local DOOR_Z0, DOOR_Z1 = -14.6, -10.4 -- проём передней двери (правый борт)
local PILLARS = { -10.4, -2.35, 5.7, 13.75, 21.8 } -- стойки между секциями стен
local LOW_DROP = WHEEL_R - HUB_R -- угол без колеса опущен на ступицу
local LIFT_TIME = 0.8 -- секунд на подъём угла колесом
local GRAB_RANGE = 14 -- переносимый объект прикрепляется к слоту не дальше

local samples = {} -- точки контура для столкновений: { x, z, where }
local radius = math.sqrt((HL + 0.9) ^ 2 + (HW + 0.4) ^ 2)

local alignPos, alignOri
local furnace -- { body, window, fire, light, smoke, loop, lit, smokeOn }
local driverSeat, repairBox
local headlights = {}
local slots = {} -- slots[slotType][i] = { slot, index, cf, marker, prompt, partId, model }
local turrets = {}
local sirenPart = nil
local stats = { armor = 0, crashMult = 1, ramMult = 1, selfDamageMult = 1, sawDps = 0, turrets = 0, lamps = 0, bunks = 0, alarms = 0, ram = 0 }

local startS = 70
local pendingDamage = 0
local lastCrash = 0
local lastFuelWarn = 0
local lastReadyWarn = 0
local lastHitSound = 0
local lastZoneSlow = 1
local stateAcc, lightAcc, ownerAcc, ramAcc, guideAcc, depotAcc = 0, 0, 0, 0, 0, 0
local guideCache = {} -- [player] = { title, text, target }
local guideActive = false
local attachThrottle = {}

-- Утилиты -------------------------------------------------------------------------------------------

local function yawCF(heading)
	-- LookVector = (sin h, 0, cos h), как у RoadPath
	return CFrame.Angles(0, heading + math.pi, 0)
end

local function classOf(player)
	local d = player and PD.Get(player)
	return d and d.ClassId or nil
end

local function bestTurretMult()
	local mult = 1
	for _, plr in ipairs(Players:GetPlayers()) do
		local c = classOf(plr)
		if c then
			mult = math.max(mult, Classes.Perk(c, "turretMult", 1))
		end
	end
	return mult
end

local function rootOf(player)
	local char = player and player.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function shotParams()
	local exclude = {}
	if Bus.Model then
		table.insert(exclude, Bus.Model)
	end
	for _, name in ipairs({ "Loot", "Effects", "EventsFX", "Placeables" }) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(exclude, f)
		end
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character then
			table.insert(exclude, plr.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	return params
end

local function setWaypoint(part, label, enabled, color, maxDistance)
	if not part or not part.Parent then
		return
	end
	local has = CollectionService:HasTag(part, WAYPOINT)
	if enabled then
		if part:GetAttribute("WaypointLabel") ~= label then
			part:SetAttribute("WaypointLabel", label)
		end
		if color and part:GetAttribute("WaypointColor") ~= color then
			part:SetAttribute("WaypointColor", color)
		end
		if maxDistance and part:GetAttribute("WaypointMaxDistance") ~= maxDistance then
			part:SetAttribute("WaypointMaxDistance", maxDistance)
		end
		if not has then
			CollectionService:AddTag(part, WAYPOINT)
		end
	elseif has then
		CollectionService:RemoveTag(part, WAYPOINT)
	end
end

-- Постройка модели -------------------------------------------------------------------------------------

local function applyProps(p, props)
	if props then
		for k, v in pairs(props) do
			if k == "Shape" then
				p.Shape = Enum.PartType[v]
			else
				p[k] = v
			end
		end
	end
end

-- Деталь, приваренная к корню автобуса (WeldConstraint)
local function add(name, size, localCF, color, material, props, parent)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material or M.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Anchored = false
	p.Massless = true
	p.CollisionGroup = "Bus"
	applyProps(p, props)
	p.CFrame = Bus.Root.CFrame * localCF
	local w = Instance.new("WeldConstraint")
	w.Part0 = Bus.Root
	w.Part1 = p
	w.Parent = p
	p.Parent = parent or Bus.Model
	return p
end

-- Декоративная деталь без столкновений
local function deco(name, size, localCF, color, material, parent, extra)
	local props = { CanCollide = false, CanTouch = false, CanQuery = false }
	if extra then
		for k, v in pairs(extra) do
			props[k] = v
		end
	end
	return add(name, size, localCF, color, material, props, parent)
end

local function addWedge(name, size, localCF, color, material, parent, props)
	local p = Instance.new("WedgePart")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material or M.SmoothPlastic
	p.Anchored = false
	p.Massless = true
	p.CollisionGroup = "Bus"
	applyProps(p, props)
	p.CFrame = Bus.Root.CFrame * localCF
	local w = Instance.new("WeldConstraint")
	w.Part0 = Bus.Root
	w.Part1 = p
	w.Parent = p
	p.Parent = parent or Bus.Model
	return p
end

-- Размеры TrussPart кратны 2
local function addTruss(name, height, localCF, parent)
	local t = Instance.new("TrussPart")
	t.Name = name
	t.Size = V3(2, height, 2)
	t.Color = FRAME
	t.Material = M.Metal
	t.Anchored = false
	t.Massless = true
	t.CollisionGroup = "Bus"
	t.CFrame = Bus.Root.CFrame * localCF
	local w = Instance.new("WeldConstraint")
	w.Part0 = Bus.Root
	w.Part1 = t
	w.Parent = t
	t.Parent = parent or Bus.Model
	return t
end

-- Деталь на обычном Weld (C0 можно менять — поворот турели)
local function addPivot(name, size, c0, color, material, parent)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material or M.Metal
	p.Anchored = false
	p.Massless = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CollisionGroup = "Bus"
	p.CFrame = Bus.Root.CFrame * c0
	local weld = Instance.new("Weld")
	weld.Part0 = Bus.Root
	weld.Part1 = p
	weld.C0 = c0
	weld.Parent = p
	p.Parent = parent or Bus.Model
	return p, weld
end

-- Деталь, приваренная к другой детали
local function addChild(name, size, base, offset, color, material, parent, props)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material or M.Metal
	p.Anchored = false
	p.Massless = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CollisionGroup = "Bus"
	applyProps(p, props)
	p.CFrame = base.CFrame * offset
	local weld = Instance.new("Weld")
	weld.Part0 = base
	weld.Part1 = p
	weld.C0 = offset
	weld.Parent = p
	p.Parent = parent or Bus.Model
	return p
end

local function surfaceText(part, face, text, color, ppu)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = ppu or 30
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextColor3 = color
	label.TextScaled = true
	label.Font = Enum.Font.GothamBlack
	label.Parent = gui
	gui.Parent = part
	return gui
end

local function makePrompt(parent, name, action, object, hold, distance)
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = name
	prompt.ActionText = action
	prompt.ObjectText = object
	prompt.HoldDuration = hold
	prompt.MaxActivationDistance = distance
	prompt.RequiresLineOfSight = false
	prompt.Parent = parent
	return prompt
end

-- Вернуть сетевое владение персонажем игроку после выхода из сиденья
local function returnOwnership(player, character)
	if not player or not character then
		return
	end
	local hrp = character:FindFirstChild("HumanoidRootPart")
	if not hrp then
		return
	end
	task.defer(function()
		pcall(function()
			if not hrp.Parent or not player.Parent or hrp.Anchored then
				return
			end
			local hum = character:FindFirstChildOfClass("Humanoid")
			if hum and hum.SeatPart then
				return
			end
			local root = Bus.Root
			if root then
				for _, part in ipairs(hrp:GetConnectedParts(true)) do
					if part == root then
						return
					end
				end
			end
			hrp:SetNetworkOwner(player)
		end)
	end)
end

local function claimOwnership()
	local root = Bus.Root
	if root and root.Parent then
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
	end
end

-- Звуки и искры ----------------------------------------------------------------------------------------

-- 3D-звук на детали автобуса (один раз): ключ из Sounds, иначе запасной; тишина, если нет обоих
local function playSound(parent, key, fallback)
	if not parent or not parent.Parent then
		return nil
	end
	local snd = Instance.new("Sound")
	snd.Name = "BusSfx"
	snd.RollOffMinDistance = 8
	snd.RollOffMaxDistance = 120
	if not (Sounds.Apply(snd, key) or (fallback ~= nil and Sounds.Apply(snd, fallback))) then
		snd:Destroy()
		return nil
	end
	snd.Looped = false
	snd.Parent = parent
	snd:Play()
	task.delay(6, function()
		snd:Destroy()
	end)
	return snd
end

-- Звук прикрепления: колесо, деревянная или металлическая стена; остальные детали — металл
local ATTACH_SOUND = { bus_wheel = "wheel_attach", plate_wood = "bus_attach_wood", plate_metal = "bus_attach_metal" }

-- Искры (у дерева — щепки) и звук при прикреплении детали: одноразово, не каждый кадр
local function attachFx(part, partId)
	if not part or not part.Parent then
		return
	end
	playSound(part, ATTACH_SOUND[partId] or "bus_attach_metal", "attach")
	local emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	if partId == "plate_wood" then
		emitter.Color = ColorSequence.new(rgb(150, 110, 70), rgb(90, 64, 40))
		emitter.LightEmission = 0
		emitter.Size = NumberSequence.new(0.2, 0.06)
	else
		emitter.Color = ColorSequence.new(rgb(255, 200, 90), rgb(255, 110, 30))
		emitter.LightEmission = 1
		emitter.Size = NumberSequence.new(0.25, 0)
	end
	emitter.Lifetime = NumberRange.new(0.25, 0.6)
	emitter.Speed = NumberRange.new(6, 16)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Acceleration = V3(0, -40, 0)
	emitter.Parent = part
	emitter:Emit(16)
	task.delay(1.5, function()
		emitter:Destroy()
	end)
end

-- Мелкие детали -----------------------------------------------------------------------------------------

local WHEEL_TAG = "LR_BusWheel" -- шина колеса (BasePart): клиент рисует крутящуюся копию
local GAUGE_TAG = "LR_BusGauge" -- стрелка прибора (BasePart): клиент рисует копию под нужным углом
local FX_TAG = "LR_BusFx" -- выхлоп и пыль из-под колёс: клиент включает по скорости
local LADDER_TAG = "LR_BusLadder" -- ферма лестницы на крышу: клиент держит на ней игрока, пока автобус едет
local drng = Random.new(404) -- раскладка декора одинаковая в каждом заезде

local PAL = {
	rust = rgb(128, 68, 30),
	rust2 = rgb(94, 50, 26),
	peel = rgb(206, 150, 64),
	mud = rgb(70, 58, 46),
	chrome = rgb(170, 168, 160),
	rubber = rgb(24, 24, 24),
	rivet = rgb(88, 78, 68),
	cable = rgb(16, 16, 16),
	hazard = rgb(214, 162, 40),
	cream = rgb(214, 204, 174),
	wall = rgb(64, 72, 62),
	upholstery = rgb(70, 42, 30),
	lensOff = rgb(126, 120, 100),
	lampOn = rgb(255, 240, 200),
	roof = { rgb(92, 72, 52), rgb(84, 70, 58), rgb(100, 78, 54) },
	blankets = { rgb(86, 94, 68), rgb(120, 60, 48), rgb(68, 76, 98), rgb(140, 120, 90) },
}

-- Остальные помощники — в таблице (лимит локальных переменных чанка)
local Kit = {
	SMOKE_TEX = "rbxasset://textures/particles/smoke_main.dds",
	AXIS_Y = ANG(0, 0, math.pi / 2),
	AXIS_Z = ANG(0, math.pi / 2, 0),
	FRONT_FACE = CF(0, 0, -21.42) * ANG(0, math.pi / 2, 0), -- нос капота, u = x корня
	BACK_FACE = CF(0, 0, HL + 0.25) * ANG(0, -math.pi / 2, 0), -- u = -x корня
	NOCOLLIDE = { CanCollide = false, CanQuery = false, CanTouch = false },
	bulbs = {}, -- «лампочки» фар: неон, когда фары включены
	lit = nil,
}

-- Мелкая деталь без коллизий и без тени
local function fine(name, size, localCF, color, material, parent, extra)
	local p = deco(name, size, localCF, color, material, parent, extra)
	p.CastShadow = false
	return p
end

-- Цилиндр вдоль оси корня "x" / "y" / "z" (в Roblox цилиндр вытянут по своей оси X)
local function cyl(name, axis, length, diameter, localCF, color, material, parent)
	local rot = axis == "y" and Kit.AXIS_Y or (axis == "z" and Kit.AXIS_Z or CFrame.identity)
	return fine(name, V3(length, diameter, diameter), localCF * rot, color, material, parent, { Shape = "Cylinder" })
end

local function ball(name, d, localCF, color, material, parent)
	return fine(name, V3(d, d, d), localCF, color, material, parent, { Shape = "Ball" })
end

-- Кабель/труба между двумя точками корня
local function cable(name, a, b, diameter, color, parent, material)
	local len = (b - a).Magnitude
	if len < 0.05 then
		return nil
	end
	local cf = CFrame.lookAt((a + b) / 2, b) * ANG(0, math.pi / 2, 0)
	return fine(name, V3(len, diameter, diameter), cf, color or PAL.cable, material or M.SmoothPlastic, parent, { Shape = "Cylinder" })
end

-- Пятно на поверхности (ржавчина, облезлая краска, грязь). face — CFrame с осью X по наружной нормали,
-- (u, v) — координаты на поверхности; tilt — поворот в плоскости
local function stain(face, u, v, w, h, color, parent, lift, tilt, material)
	local cf = face * CF(0.02 + (lift or 0), v, u) * ANG(tilt or drng:NextNumber(-0.5, 0.5), 0, 0)
	return fine("Stain", V3(0.04, h, w), cf, color, material or M.CorrodedMetal, parent)
end

-- Борт: кадр поверхности и знак оси u (u = us * z корня)
function Kit.sideFace(side)
	if side > 0 then
		return CF(HW + 0.5, 0, 0), 1
	end
	return CF(-(HW + 0.5), 0, 0) * ANG(0, math.pi, 0), -1
end

-- Неровное ржавое пятно из наложенных кусков, иногда с подтёком
function Kit.rustBlotch(face, u, v, size, parent)
	local color = drng:NextNumber() < 0.65 and PAL.rust or PAL.rust2
	stain(face, u, v, size * drng:NextNumber(0.8, 1.3), size * drng:NextNumber(0.5, 0.9), color, parent, 0)
	stain(face, u + size * drng:NextNumber(-0.45, 0.45), v + size * drng:NextNumber(-0.3, 0.3), size * drng:NextNumber(0.35, 0.7), size * drng:NextNumber(0.3, 0.6), PAL.rust2, parent, 0.006)
	if drng:NextNumber() < 0.55 then
		local len = size * drng:NextNumber(0.7, 1.4)
		stain(face, u + size * drng:NextNumber(-0.3, 0.3), v - size * 0.35 - len / 2, drng:NextNumber(0.1, 0.22), len, color, parent, 0.003, 0)
	end
end

-- Табличка с текстом
function Kit.sign(name, size, localCF, bg, fg, text, face, parent, ppu)
	local p = fine(name, size, localCF, bg, M.SmoothPlastic, parent)
	surfaceText(p, face, text, fg, ppu)
	return p
end

-- Эмиттер выхлопа/пыли на Attachment корня (эмиттер бьёт по +Y attachment)
function Kit.fxEmitter(kind, localCF, color, size0, size1, life, speed)
	local att = Instance.new("Attachment")
	att.Name = "Fx_" .. kind
	att.CFrame = localCF
	att.Parent = Bus.Root
	local e = Instance.new("ParticleEmitter")
	e.Name = kind == "exhaust" and "ExhaustSmoke" or "WheelDust"
	e.Texture = Kit.SMOKE_TEX
	e.Color = ColorSequence.new(color)
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, size0), NumberSequenceKeypoint.new(1, size1) })
	e.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.55), NumberSequenceKeypoint.new(0.6, 0.75), NumberSequenceKeypoint.new(1, 1) })
	e.Lifetime = NumberRange.new(life * 0.7, life)
	e.Speed = NumberRange.new(speed * 0.6, speed)
	e.SpreadAngle = Vector2.new(18, 18)
	e.Acceleration = V3(0, kind == "exhaust" and 2.5 or 0.8, 0)
	e.Drag = 1.2
	e.RotSpeed = NumberRange.new(-40, 40)
	e.Rotation = NumberRange.new(0, 360)
	e.LightInfluence = 0.8
	e.Rate = 0
	e.Enabled = false
	e:SetAttribute("Fx", kind)
	CollectionService:AddTag(e, FX_TAG)
	e.Parent = att
	return e
end

-- Место колеса i (1 — перед слева, 2 — перед справа, 3 — зад слева, 4 — зад справа): ось цилиндра по X корня
function Kit.wheelCF(i)
	local x = (i % 2 == 1) and -(HW + 0.4) or (HW + 0.4)
	return CF(x, WHEEL_Y, i <= 2 and FRONT_WHEEL_Z or REAR_WHEEL_Z)
end

-- Корпус ------------------------------------------------------------------------------------------------

local WALL_Y0 = FLOOR + 0.9 -- низ поставленной стены (нижняя часть борта закрывает её снаружи)
local REAR_TOP = 2.7 -- кромка целой нижней части задней стенки
-- Кромка целой нижней части борта по секциям (выше — рваные края и обломки стоек)
Kit.SECTION_TOP = { [-1] = { 3.3, 2.9, 2.5, 2.8 }, [1] = { 3.1, 2.6, 2.9, 2.4 } }
Kit.BROKEN = { [-1] = { [3] = true }, [1] = { [2] = true } } -- сломанные стойки (индекс в PILLARS)

-- Отрезок нижней части борта (z0..z1, y0..y1); изнутри — крашеная обшивка
local function sideSegment(name, side, z0, z1, y0, y1, hull)
	if z1 - z0 < 0.05 or y1 - y0 < 0.05 then
		return nil
	end
	local p = add(name, V3(0.5, y1 - y0, z1 - z0), CF(side * (HW + 0.25), (y0 + y1) / 2, (z0 + z1) / 2), RUST, M.CorrodedMetal)
	local ly0, ly1 = math.max(y0, FLOOR), y1 - 0.06
	if hull and ly1 - ly0 > 0.3 then
		fine("Lining", V3(0.06, ly1 - ly0, z1 - z0 - 0.1), CF(side * (HW - 0.03), (ly0 + ly1) / 2, (z0 + z1) / 2), PAL.wall, M.Metal, hull)
	end
	return p
end

-- Рваная кромка спиленного металла: зубцы-клинья разной высоты вдоль оси Z кадра frame
function Kit.jagged(frame, length, top, hull, n, phase)
	local cuts = { -length / 2 }
	for i = 1, n - 1 do
		cuts[i + 1] = -length / 2 + length * (i / n + drng:NextNumber(-0.1, 0.1))
	end
	cuts[n + 1] = length / 2
	for i = 1, n do
		local len = cuts[i + 1] - cuts[i]
		if len > 0.3 then
			local h = drng:NextNumber(0.3, 1.1)
			local turn = (i + phase) % 2 == 0 and ANG(0, math.pi, 0) or CFrame.identity
			addWedge("JaggedEdge", V3(0.5, h, len), frame * CF(0, top + h / 2, (cuts[i] + cuts[i + 1]) / 2) * turn, RUST, M.CorrodedMetal, hull, Kit.NOCOLLIDE)
		end
	end
end

-- Обломок оконной стойки посреди секции
function Kit.stub(side, z, top, hull)
	local h = drng:NextNumber(0.6, 1.5)
	local base = CF(side * (HW + 0.25), top, z) * ANG(drng:NextNumber(-0.16, 0.16), 0, 0)
	deco("PostStub", V3(0.45, h, 0.5), base * CF(0, h / 2, 0), RUST, M.CorrodedMetal, hull)
	addWedge("PostStubCut", V3(0.45, 0.35, 0.5), base * CF(0, h + 0.175, 0) * (side > 0 and CFrame.identity or ANG(0, math.pi, 0)), RUST_DARK, M.CorrodedMetal, hull, Kit.NOCOLLIDE)
end

-- Стойка между секциями стен; broken — верх оторван, от крыши свисает обломок
function Kit.pillar(side, z, y0, y1, hull, broken)
	local x = side * (HW + 0.25)
	if broken then
		local h1 = drng:NextNumber(1.0, 1.8)
		add("PillarStub", V3(0.6, h1, 0.6), CF(x, y0 + h1 / 2, z), RUST, M.CorrodedMetal)
		addWedge("PillarCut", V3(0.6, 0.4, 0.6), CF(x, y0 + h1 + 0.2, z), RUST_DARK, M.CorrodedMetal, hull, Kit.NOCOLLIDE)
		local h2 = drng:NextNumber(1.2, 2.0)
		deco("PillarHang", V3(0.6, h2, 0.6), CF(x, y1 - h2 / 2, z) * ANG(drng:NextNumber(-0.1, 0.1), 0, side * 0.07), RUST, M.CorrodedMetal, hull)
		return
	end
	add("Pillar", V3(0.6, y1 - y0, 0.6), CF(x, (y0 + y1) / 2, z), RUST, M.CorrodedMetal)
end

local function buildSide(side, hull)
	local archY0 = WHEEL_Y + WHEEL_R + 0.3
	local ra0, ra1 = REAR_WHEEL_Z - 2.7, REAR_WHEEL_Z + 2.7
	local lowY0 = -1.4
	local tops = Kit.SECTION_TOP[side]
	local face, us = Kit.sideFace(side)
	local x = side * (HW + 0.25)

	-- кабина: слева пустое окно водителя, справа — стойка у лобовой стены и дальше проём двери
	if side < 0 then
		sideSegment("CabLower", side, CAB_Z, PILLARS[1], lowY0, SILL, hull)
		sideSegment("CabHeader", side, CAB_Z, PILLARS[1] - 0.3, HEAD, ROOF_BOTTOM)
		Kit.pillar(side, CAB_Z + 0.3, SILL, HEAD, hull, false)
		local z0, z1 = CAB_Z + 0.75, PILLARS[1] - 0.45
		local zc, len = (z0 + z1) / 2, z1 - z0
		deco("WindowSill", V3(0.75, 0.3, len), CF(x, SILL + 0.15, zc), FRAME, M.Metal, hull)
		deco("WindowTop", V3(0.7, 0.3, len), CF(x, HEAD - 0.15, zc), FRAME, M.Metal, hull)
		for _, wz in ipairs({ z0 + 0.12, z1 - 0.12 }) do
			deco("WindowSide", V3(0.7, HEAD - SILL, 0.24), CF(x, (SILL + HEAD) / 2, wz), FRAME, M.Metal, hull)
		end
		addWedge("GlassShard", V3(0.08, 1.1, 1.3), CF(x - 0.06, HEAD - 0.85, z0 + 0.9) * ANG(math.pi, 0, 0), GLASS, M.Glass, hull,
			{ Transparency = 0.5, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
		-- знак «СТОП» на штанге у кабины
		local stop = deco("StopSign", V3(0.12, 2.2, 2.2), CF(x - 0.9, 5.0, -12.6), rgb(150, 30, 26), M.SmoothPlastic, hull, { Shape = "Cylinder" })
		surfaceText(stop, Enum.NormalId.Left, "СТОП", rgb(235, 230, 220), 40)
		deco("StopArm", V3(0.2, 0.2, 1.1), CF(x - 0.75, 5.0, -11.4), FRAME, M.Metal, hull)
	else
		add("DoorPostFront", V3(0.5, ROOF_BOTTOM - lowY0, DOOR_Z0 - CAB_Z), CF(x, (lowY0 + ROOF_BOTTOM) / 2, (CAB_Z + DOOR_Z0) / 2), RUST, M.CorrodedMetal)
		sideSegment("DoorHeader", side, DOOR_Z0, DOOR_Z1 - 0.3, HEAD, ROOF_BOTTOM)
	end

	-- секции борта: целая нижняя часть с рваной кромкой и обломком стойки посередине
	for k = 1, 4 do
		local z0, z1 = PILLARS[k], PILLARS[k + 1]
		local b = k == 4 and HL or z1
		local top = tops[k]
		if ra0 < b and ra1 > z0 then
			sideSegment("Lower", side, z0, math.max(z0, ra0), lowY0, top, hull)
			sideSegment("Arch", side, math.max(z0, ra0), math.min(b, ra1), archY0, top, hull)
			sideSegment("Lower", side, math.min(b, ra1), b, lowY0, top, hull)
		else
			sideSegment("Lower", side, z0, b, lowY0, top, hull)
		end
		Kit.jagged(CF(x, 0, (z0 + z1) / 2), z1 - z0 - 0.8, top, hull, 3, k + (side > 0 and 1 or 0))
		Kit.stub(side, (z0 + z1) / 2 + drng:NextNumber(-1.2, 1.2), top, hull)
	end

	-- стойки между секциями (две из них сломаны)
	for k = 1, 5 do
		local y0
		if k == 1 then
			y0 = side < 0 and math.min(SILL, tops[1]) or lowY0
		elseif k == 5 then
			y0 = math.min(tops[4], REAR_TOP)
		else
			y0 = math.min(tops[k - 1], tops[k])
		end
		Kit.pillar(side, PILLARS[k], y0, ROOF_BOTTOM, hull, Kit.BROKEN[side][k])
	end

	-- чёрные полосы: верхняя по всей длине, нижняя разорвана аркой заднего колеса
	local z0 = side > 0 and DOOR_Z1 or CAB_Z
	deco("StripeHigh", V3(0.08, 0.3, HL - z0), CF(side * (HW + 0.53), 2.05, (z0 + HL) / 2), STRIPE, M.Metal, hull)
	for _, sp in ipairs({ { z0, ra0 }, { ra1, HL } }) do
		deco("StripeLow", V3(0.08, 0.26, sp[2] - sp[1]), CF(side * (HW + 0.53), 0.3, (sp[1] + sp[2]) / 2), STRIPE, M.Metal, hull)
	end

	-- арка заднего колеса: резиновый кант, брызговик, грязь
	local tx = side * (HW + 0.56)
	fine("ArchTrim", V3(0.12, 0.3, 5.7), CF(tx, archY0 + 0.1, REAR_WHEEL_Z), PAL.rubber, M.Rubber, hull)
	for _, dz in ipairs({ -2.78, 2.78 }) do
		fine("ArchTrim", V3(0.12, archY0 + 1.25, 0.26), CF(tx, (archY0 - 1.15) / 2, REAR_WHEEL_Z + dz), PAL.rubber, M.Rubber, hull)
	end
	fine("MudFlap", V3(1.3, 1.5, 0.08), CF(side * (HW + 0.4), -2.05, REAR_WHEEL_Z + 2.95), PAL.rubber, M.Rubber, hull)
	stain(face, us * (REAR_WHEEL_Z + 3.7), -0.25, 1.5, 1.5, PAL.mud, hull, 0, drng:NextNumber(-0.2, 0.2), M.Slate)

	-- ржавчина, облезлая краска, габаритные фонари и надпись на борту
	for _, z in ipairs({ -8, -1.5, 6, 12, 19 }) do
		Kit.rustBlotch(face, us * (z + drng:NextNumber(-1.2, 1.2)), drng:NextNumber(-0.6, 1.8), drng:NextNumber(0.7, 1.4), hull)
	end
	stain(face, us * drng:NextNumber(-6, 10), drng:NextNumber(0.4, 2), drng:NextNumber(0.9, 1.6), drng:NextNumber(0.5, 0.9), PAL.peel, hull, 0.002)
	for _, z in ipairs({ -9.5, 20.6 }) do
		fine("MarkerLamp", V3(0.12, 0.3, 0.6), CF(side * (HW + 0.56), 1.2, z), rgb(210, 110, 30), M.Neon, hull)
	end
	local label = fine("SideLabel", V3(0.05, 0.8, 12), CF(side * (HW + 0.54), 1.3, 3), RUST, M.SmoothPlastic, hull, { Transparency = 1 })
	surfaceText(label, side > 0 and Enum.NormalId.Right or Enum.NormalId.Left, "ПОСЛЕДНИЙ  РЕЙС", rgb(34, 26, 20), 40)

	-- зеркало заднего вида на штангах у кабины
	local mx = side * (HW + 1.7)
	cable("MirrorArm", V3(side * (HW + 0.5), 6.4, CAB_Z + 0.4), V3(mx, 5.9, CAB_Z - 0.6), 0.14, FRAME, hull, M.Metal)
	fine("Mirror", V3(0.9, 1.9, 0.3), CF(mx, 5.6, CAB_Z - 0.7), FRAME, M.Metal, hull)
	fine("MirrorGlass", V3(0.74, 1.7, 0.05), CF(mx, 5.6, CAB_Z - 0.87), rgb(150, 170, 176), M.Glass, hull, { Reflectance = 0.3 })
end

-- Пол: рифлёный металл; у передней двери — вырез под ступени
function Kit.floor(hull)
	local stairX = 3.1
	add("Floor", V3(HW * 2, 0.5, HL - DOOR_Z1), CF(0, FLOOR - 0.25, (DOOR_Z1 + HL) / 2), FLOOR_C, M.DiamondPlate)
	add("FloorCab", V3(stairX + HW, 0.5, DOOR_Z1 - CAB_Z), CF((stairX - HW) / 2, FLOOR - 0.25, (CAB_Z + DOOR_Z1) / 2), FLOOR_C, M.DiamondPlate)
	for k = 1, 3 do
		fine("FloorSeam", V3(HW * 2 - 0.6, 0.03, 0.08), CF(0, FLOOR + 0.015, -4 + k * 7), rgb(64, 64, 66), M.Metal, hull)
	end
	for _, side in ipairs({ -1, 1 }) do
		fine("FloorEdge", V3(0.35, 0.04, HL - DOOR_Z1 - 0.6), CF(side * (HW - 0.2), FLOOR + 0.02, (DOOR_Z1 + HL) / 2), PAL.hazard, M.SmoothPlastic, hull)
	end
	fine("StairEdge", V3(0.25, 0.04, DOOR_Z1 - DOOR_Z0), CF(stairX - 0.12, FLOOR + 0.02, (DOOR_Z0 + DOOR_Z1) / 2), PAL.hazard, M.SmoothPlastic, hull)
	fine("AisleMat", V3(2.2, 0.04, 26), CF(0, FLOOR + 0.03, 6), rgb(38, 38, 36), M.Rubber, hull)
end

-- Створка передней двери: жёлтая рама со стеклом, открыта наружу
function Kit.doorLeaf(hingeZ, dir, bottom, h, hull)
	local w = (DOOR_Z1 - DOOR_Z0) / 2 - 0.06
	local base = CF(HW + 0.4, bottom + h / 2, hingeZ) * ANG(0, dir * rad(68), 0) * CF(0, 0, dir * w / 2)
	local yellow = rgb(190, 136, 40)
	local glass = { Transparency = 0.55, Reflectance = 0.06, CastShadow = false }
	for _, dz in ipairs({ -w / 2 + 0.13, w / 2 - 0.13 }) do
		deco("DoorFrame", V3(0.2, h, 0.26), base * CF(0, 0, dz), yellow, M.CorrodedMetal, hull)
	end
	deco("DoorFrame", V3(0.2, 0.3, w), base * CF(0, h / 2 - 0.15, 0), yellow, M.CorrodedMetal, hull)
	deco("DoorFrame", V3(0.2, 0.5, w), base * CF(0, -h / 2 + 0.25, 0), yellow, M.CorrodedMetal, hull)
	local midY = -h / 2 + h * 0.42
	deco("DoorRail", V3(0.2, 0.28, w), base * CF(0, midY, 0), yellow, M.CorrodedMetal, hull)
	local lowH = midY - 0.14 - (-h / 2 + 0.5)
	local upH = (h / 2 - 0.3) - (midY + 0.14)
	deco("DoorGlass", V3(0.06, lowH, w - 0.5), base * CF(0, -h / 2 + 0.5 + lowH / 2, 0), GLASS, M.Glass, hull, glass)
	deco("DoorGlass", V3(0.06, upH, w - 0.5), base * CF(0, midY + 0.14 + upH / 2, 0), GLASS, M.Glass, hull, glass)
	deco("DoorHinge", V3(0.3, 0.4, 0.3), CF(HW + 0.4, bottom + h * 0.8, hingeZ), FRAME, M.Metal, hull)
end

-- Передняя дверь: створки, три ступени внутрь и поручень
function Kit.door(hull)
	local zc = (DOOR_Z0 + DOOR_Z1) / 2
	local width = DOOR_Z1 - DOOR_Z0 - 0.24
	local bottom = -2.15
	for _, s in ipairs({ { 5.1, 6.35, -1.95 }, { 4.1, 5.1, -1.1 }, { 3.1, 4.1, -0.3 } }) do
		add("DoorStep", V3(s[2] - s[1], s[3] - bottom, width), CF((s[1] + s[2]) / 2, (s[3] + bottom) / 2, zc), METAL, M.DiamondPlate)
		fine("StepNose", V3(0.14, 0.07, width), CF(s[2] - 0.07, s[3] + 0.035, zc), PAL.hazard, M.SmoothPlastic, hull)
	end
	add("StepRiser", V3(0.12, FLOOR + 0.3, width), CF(3.04, (FLOOR - 0.3) / 2, zc), METAL, M.DiamondPlate)
	for _, z in ipairs({ DOOR_Z0 + 0.07, DOOR_Z1 - 0.07 }) do
		add("StairWall", V3(3.3, 2.6, 0.14), CF(4.75, -0.85, z), rgb(52, 50, 48), M.Metal)
	end
	cyl("DoorRail", "y", 6.2, 0.16, CF(5.7, 1.2, DOOR_Z1 - 0.45), PAL.chrome, M.Metal, hull)
	local h = (HEAD - 0.1) - (-1.75)
	Kit.doorLeaf(DOOR_Z0, 1, -1.75, h, hull)
	Kit.doorLeaf(DOOR_Z1, -1, -1.75, h, hull)
	fine("EntryLampBase", V3(0.2, 0.26, 1.3), CF(HW + 0.62, HEAD + 0.3, zc), FRAME, M.Metal, hull)
	fine("EntryLamp", V3(0.1, 0.18, 1.1), CF(HW + 0.74, HEAD + 0.22, zc), AMBER, M.Neon, hull)
end

-- Перед: капот с крыльями, решётка, фары, бампер, лобовой проём без стекла
function Kit.front(hull)
	local nose = -21.4
	local SH = 3.6 -- низ проёма лобового стекла
	add("Hood", V3(8.8, 2.3, CAB_Z - (nose + 1.2)), CF(0, 1.35, (CAB_Z + nose + 1.2) / 2), RUST, M.CorrodedMetal)
	add("HoodNose", V3(8.8, 1.6, 1.2), CF(0, 1.0, nose + 0.6), RUST, M.CorrodedMetal)
	addWedge("HoodNoseTop", V3(8.8, 0.7, 1.2), CF(0, 2.15, nose + 0.6), RUST, M.CorrodedMetal, hull, Kit.NOCOLLIDE)
	fine("HoodCrease", V3(0.12, 0.06, 5.0), CF(0, 2.52, -17.7), RUST_DARK, M.CorrodedMetal, hull)
	fine("Grille", V3(4.4, 1.3, 0.1), CF(0, 1.0, nose - 0.02), rgb(26, 26, 26), M.Metal, hull)
	for i = 0, 3 do
		fine("GrilleSlat", V3(4.0, 0.1, 0.08), CF(0, 0.55 + i * 0.3, nose - 0.08), PAL.chrome, M.Metal, hull)
	end
	Kit.sign("Badge", V3(1.2, 0.36, 0.06), CF(0, 2.0, nose - 0.06), PAL.chrome, rgb(28, 28, 28), "Л-404", Enum.NormalId.Front, hull, 60)

	-- крылья над передними колёсами
	for _, s in ipairs({ -1, 1 }) do
		local fx = s * 5.95
		add("FenderTop", V3(2.3, 0.5, 2.6), CF(fx, 2.15, FRONT_WHEEL_Z), RUST, M.CorrodedMetal)
		addWedge("FenderFront", V3(2.3, 1.7, 1.6), CF(fx, 1.05, FRONT_WHEEL_Z - 2.1), RUST, M.CorrodedMetal, hull)
		addWedge("FenderRear", V3(2.3, 1.4, 1.5), CF(fx, 1.2, FRONT_WHEEL_Z + 2.05) * ANG(0, math.pi, 0), RUST, M.CorrodedMetal, hull)
		fine("FenderLiner", V3(2.1, 0.08, 5.2), CF(fx, 1.86, FRONT_WHEEL_Z), PAL.rubber, M.Rubber, hull)
		fine("FenderFlare", V3(0.18, 0.3, 5.4), CF(s * 7.12, 2.0, FRONT_WHEEL_Z), PAL.rubber, M.Rubber, hull)
	end

	-- фары с отражателем и поворотники
	headlights = {}
	Kit.bulbs = {}
	Kit.lit = nil
	for _, s in ipairs({ -1, 1 }) do
		local lcf = CF(s * 3.3, 1.3, nose - 0.08)
		cyl("LampRing", "z", 0.16, 1.15, lcf, PAL.chrome, M.Metal, hull)
		local bulb = ball("Bulb", 0.5, lcf * CF(0, 0, -0.05), PAL.lensOff, M.Glass, hull)
		table.insert(Kit.bulbs, bulb)
		local lens = cyl("Lens", "z", 0.06, 0.95, lcf * CF(0, 0, -0.1), rgb(228, 234, 234), M.Glass, hull)
		lens.Transparency = 0.6
		local spot = Instance.new("SpotLight")
		spot.Face = Enum.NormalId.Front
		spot.Range = 60
		spot.Angle = 70
		spot.Brightness = 4
		spot.Shadows = true
		spot.Enabled = false
		spot.Parent = bulb
		table.insert(headlights, spot)
		fine("TurnSignal", V3(0.5, 0.35, 0.1), CF(s * 4.15, 1.3, nose - 0.04), rgb(200, 120, 20), M.Neon, hull)
	end

	-- бампер с крюками и номером
	add("Bumper", V3(13.2, 1.0, 0.8), CF(0, -0.8, nose - 0.45), FRAME, M.Metal, { CanCollide = false })
	for _, bx in ipairs({ -4.6, -1.8, 1.8, 4.6 }) do
		cyl("BumperBolt", "z", 0.1, 0.24, CF(bx, -0.8, nose - 0.88), PAL.chrome, M.Metal, hull)
	end
	for _, bx in ipairs({ -5.9, 5.9 }) do
		fine("TowHook", V3(0.25, 0.25, 0.7), CF(bx, -1.4, nose - 0.6), FRAME, M.Metal, hull)
	end
	local plate = fine("PlateFront", V3(2.6, 0.6, 0.06), CF(0, -0.72, nose - 0.9), rgb(236, 236, 230), M.SmoothPlastic, hull)
	surfaceText(plate, Enum.NormalId.Front, "К 404 АТ 13", rgb(20, 20, 20), 50)

	-- лобовая стена кабины: проём без стекла, стойки, козырёк с табло
	add("CabFront", V3(12.9, SH + 1.2, 0.5), CF(0, (SH - 1.2) / 2, CAB_Z - 0.25), RUST, M.CorrodedMetal)
	add("CabFrontPost", V3(0.35, HEAD - SH, 0.5), CF(0, (SH + HEAD) / 2, CAB_Z - 0.25), FRAME, M.Metal)
	for _, s in ipairs({ -1, 1 }) do
		add("CabCornerPost", V3(0.6, HEAD - SH, 0.5), CF(s * 6.15, (SH + HEAD) / 2, CAB_Z - 0.25), RUST, M.CorrodedMetal)
	end
	add("CabHeader", V3(12.9, ROOF_BOTTOM - HEAD, 0.5), CF(0, (HEAD + ROOF_BOTTOM) / 2, CAB_Z - 0.25), RUST, M.CorrodedMetal)
	fine("ShieldSeal", V3(11.6, 0.16, 0.1), CF(0, HEAD - 0.08, CAB_Z - 0.52), PAL.rubber, M.Rubber, hull)
	fine("ShieldSeal", V3(11.6, 0.16, 0.1), CF(0, SH + 0.08, CAB_Z - 0.52), PAL.rubber, M.Rubber, hull)
	for _, s in ipairs({ -1, 1 }) do
		addWedge("ShieldShard", V3(0.08, 1.0, 1.6), CF(s * 4.6, HEAD - 0.6, CAB_Z - 0.4) * ANG(math.pi, 0, 0), GLASS, M.Glass, hull,
			{ Transparency = 0.55, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
		-- дворники лежат на полке под проёмом: не мешают обзору водителя
		cable("WiperArm", V3(s * 1.4, SH - 0.2, CAB_Z - 0.58), V3(s * 4.4, SH - 0.05, CAB_Z - 0.58), 0.09, FRAME, hull, M.Metal)
	end
	local routeSign = deco("RouteSign", V3(9.4, 0.9, 0.1), CF(0, (HEAD + ROOF_BOTTOM) / 2, CAB_Z - 0.56), rgb(18, 16, 14), M.SmoothPlastic, hull)
	surfaceText(routeSign, Enum.NormalId.Front, "РЕЙС 404 · " .. Config.FinalName, AMBER)
	for _, cx in ipairs({ -4.6, 4.6 }) do
		fine("CabLamp", V3(0.5, 0.24, 0.1), CF(cx, ROOF_BOTTOM - 0.16, CAB_Z - 0.52), rgb(210, 110, 30), M.Neon, hull)
	end
	for _, u in ipairs({ -3.4, 1.2, 3.8 }) do
		Kit.rustBlotch(Kit.FRONT_FACE, u + drng:NextNumber(-0.4, 0.4), drng:NextNumber(-0.4, 1.6), drng:NextNumber(0.45, 0.9), hull)
	end
end

-- Зад: целая нижняя часть с рваной кромкой, круглые фонари, бампер, номер
function Kit.rear(hull)
	local bz = HL
	local oz = bz + 0.27
	add("RearLower", V3(12.5, REAR_TOP + 1.4, 0.5), CF(0, (REAR_TOP - 1.4) / 2, bz), RUST, M.CorrodedMetal)
	Kit.jagged(CF(0, 0, bz) * ANG(0, math.pi / 2, 0), 11.2, REAR_TOP, hull, 4, 0)
	deco("RearStripe", V3(12.52, 0.3, 0.06), CF(0, 2.05, oz), STRIPE, M.Metal, hull)
	deco("RearStripe", V3(12.52, 0.26, 0.06), CF(0, 0.3, oz), STRIPE, M.Metal, hull)
	for _, s in ipairs({ -1, 1 }) do
		fine("TailHousing", V3(2.6, 1.3, 0.1), CF(s * 3.9, 1.2, oz + 0.02), FRAME, M.Metal, hull)
		for _, dx in ipairs({ -0.62, 0.62 }) do
			cyl("TailLight", "z", 0.14, 0.9, CF(s * 3.9 + dx, 1.2, oz + 0.1), rgb(178, 26, 22), M.Neon, hull)
		end
	end
	add("BumperRear", V3(9.8, 0.9, 0.7), CF(1.5, -0.9, HL + 0.55), FRAME, M.Metal, { CanCollide = false })
	local plate = fine("PlateRear", V3(2.4, 0.56, 0.06), CF(2.0, -0.9, HL + 0.92), rgb(236, 236, 230), M.SmoothPlastic, hull)
	surfaceText(plate, Enum.NormalId.Back, "К 404 АТ 13", rgb(20, 20, 20), 50)
	fine("PlateLamp", V3(0.7, 0.14, 0.16), CF(2.0, -0.5, HL + 0.9), rgb(250, 240, 210), M.Neon, hull)
	cyl("ExhaustTip", "z", 0.5, 0.42, CF(4.8, -1.55, HL + 0.9), rgb(40, 36, 32), M.Metal, hull)
	for _, u in ipairs({ -4.5, -1.2, 3.6 }) do
		Kit.rustBlotch(Kit.BACK_FACE, u + drng:NextNumber(-0.4, 0.4), drng:NextNumber(-0.6, 1.6), drng:NextNumber(0.5, 0.9), hull)
	end
end

-- Лестница на крышу: невидимая ферма для лазания, снаружи — поручни и перекладины
function Kit.ladder(hull)
	local lx, lz = -4.6, HL + 1.55
	local bottom, top = -2.4, ROOF_TOP + 0.5
	local truss = addTruss("RoofLadder", top - bottom, CF(lx, (bottom + top) / 2, lz))
	truss.Transparency = 1
	truss.CastShadow = false
	CollectionService:AddTag(truss, LADDER_TAG)
	-- поручни начинаются выше низа фермы: пока автобус лежит на ступицах, они не уходят в землю
	local railBottom = bottom + 0.8
	for _, dx in ipairs({ -0.8, 0.8 }) do
		cyl("LadderRail", "y", top + 1.1 - railBottom, 0.16, CF(lx + dx, (railBottom + top + 1.1) / 2, lz + 0.2), FRAME, M.Metal, hull)
	end
	local y = railBottom + 0.2
	while y < ROOF_TOP - 0.2 do
		cyl("LadderRung", "x", 1.7, 0.13, CF(lx, y, lz + 0.2), METAL, M.Metal, hull)
		y = y + 0.9
	end
	for _, dx in ipairs({ -0.8, 0.8 }) do
		cable("LadderGrab", V3(lx + dx, top + 1.1, lz + 0.2), V3(lx + dx, ROOF_TOP + 0.4, HL - 0.4), 0.14, FRAME, hull, M.Metal)
	end
	fine("LadderBracket", V3(1.9, 0.2, 1.1), CF(lx, 1.4, lz - 0.45), FRAME, M.Metal, hull)
	fine("LadderBracket", V3(1.9, 0.2, 1.1), CF(lx, 5.6, lz - 0.45), FRAME, M.Metal, hull)
end

-- Крыша: ржавые листы с дырами, рёбра, перила у кормы, люк, антенна
Kit.ROOF_PIECES = {
	{ -6.4, -2.1, -15.4, 8.2 }, { -6.4, -2.1, 10.6, 22.4 }, { -6.4, -5.5, 8.2, 10.6 },
	{ -2.1, 2.1, -15.4, 0.4 }, { -2.1, 2.1, 2.8, 18.3 }, { -2.1, 2.1, 20.1, 22.4 },
	{ 2.1, 6.4, -15.4, -7.6 }, { 2.1, 6.4, -5.4, 22.4 }, { 5.3, 6.4, -7.6, -5.4 },
}

function Kit.roof(hull)
	local h = ROOF_TOP - ROOF_BOTTOM
	for i, r in ipairs(Kit.ROOF_PIECES) do
		add("Roof", V3(r[2] - r[1], h, r[4] - r[3]), CF((r[1] + r[2]) / 2, ROOF_BOTTOM + h / 2, (r[3] + r[4]) / 2), PAL.roof[(i - 1) % 3 + 1], M.CorrodedMetal)
	end
	for _, z in ipairs({ -9, -1.5, 8.5, 16, 21 }) do
		fine("CeilingRib", V3(12.6, 0.18, 0.25), CF(0, ROOF_BOTTOM - 0.09, z), rgb(78, 66, 54), M.Metal, hull)
	end
	for _, side in ipairs({ -1, 1 }) do
		fine("RainGutter", V3(0.22, 0.16, HL * 2 + 0.6), CF(side * (HW + 0.45), ROOF_BOTTOM + 0.06, 3.5), STRIPE, M.Metal, hull)
	end
	-- отогнутые края дыр
	deco("RoofFlap", V3(1.8, 0.09, 1.0), CF(0.4, ROOF_BOTTOM - 0.2, 0.9) * ANG(rad(-38), 0, 0.08), PAL.roof[2], M.CorrodedMetal, hull)
	deco("RoofFlap", V3(1.2, 0.09, 0.9), CF(-4.4, ROOF_BOTTOM - 0.18, 9.0) * ANG(rad(34), 0, -0.1), PAL.roof[1], M.CorrodedMetal, hull)
	deco("RoofFlap", V3(1.0, 0.09, 1.1), CF(3.4, ROOF_TOP + 0.22, -6.2) * ANG(rad(28), 0, 0.12), PAL.roof[3], M.CorrodedMetal, hull)
	local roofFace = CF(0, ROOF_TOP, 0) * ANG(0, 0, math.pi / 2)
	for _, z in ipairs({ -13, -6, 4.5, 12, 17.5 }) do
		Kit.rustBlotch(roofFace, z + drng:NextNumber(-1, 1), drng:NextNumber(-4.5, 4.5), drng:NextNumber(0.8, 1.6), hull)
	end
	-- перила у кормы с проёмом над лестницей
	local railY = ROOF_TOP + 1.1
	add("RoofRail", V3(9.6, 0.2, 0.2), CF(1.4, railY, HL + 0.1), FRAME, M.Metal, { CanQuery = false })
	for _, side in ipairs({ -1, 1 }) do
		add("RoofRail", V3(0.2, 0.2, 13.2), CF(side * 6.2, railY, 15.6), FRAME, M.Metal, { CanQuery = false })
	end
	for _, p in ipairs({ { -6.2, 9.4 }, { -6.2, 22.1 }, { 6.2, 9.4 }, { 6.2, 22.1 }, { -3.2, 22.1 }, { 1.4, 22.1 } }) do
		deco("RoofPost", V3(0.22, 1.1, 0.22), CF(p[1], ROOF_TOP + 0.55, p[2]), FRAME, M.Metal, hull)
	end
	-- люк у лестницы, вентиляция, антенна
	fine("HatchFrame", V3(2.6, 0.14, 2.6), CF(-4.2, ROOF_TOP + 0.07, 19.4), FRAME, M.Metal, hull)
	deco("HatchLid", V3(2.3, 0.12, 2.3), CF(-4.2, ROOF_TOP + 0.55, 18.5) * ANG(rad(-55), 0, 0), rgb(98, 90, 80), M.DiamondPlate, hull)
	for _, p in ipairs({ { 3.6, 4.5 }, { -3.4, -12.5 } }) do
		cyl("VentBase", "y", 0.3, 1.1, CF(p[1], ROOF_TOP + 0.15, p[2]), FRAME, M.Metal, hull)
		cyl("VentCap", "y", 0.14, 1.5, CF(p[1], ROOF_TOP + 0.5, p[2]), rgb(90, 84, 76), M.CorrodedMetal, hull)
	end
	cyl("Antenna", "y", 1.5, 0.08, CF(HW - 0.9, ROOF_TOP + 0.75, -13.5), FRAME, M.Metal, hull)
end

-- Низ: рама, мосты, двигатель под капотом, бак, выхлоп и голые ступицы
function Kit.hub(i, hull)
	local cf = Kit.wheelCF(i)
	local s = cf.X < 0 and -1 or 1
	cyl("HubDrum", "x", 0.7, HUB_R * 2, cf * CF(-s * 0.3, 0, 0), rgb(96, 94, 90), M.Metal, hull)
	cyl("HubDisc", "x", 0.2, 1.6, cf * CF(s * 0.12, 0, 0), rgb(150, 150, 148), M.Metal, hull)
	cyl("HubCap", "x", 0.25, 0.6, cf * CF(s * 0.3, 0, 0), rgb(120, 118, 114), M.Metal, hull)
	for k = 0, 4 do
		local a = k * math.pi * 2 / 5
		cyl("HubStud", "x", 0.3, 0.14, cf * CF(s * 0.3, math.cos(a) * 0.52, math.sin(a) * 0.52), rgb(70, 70, 70), M.Metal, hull)
	end
end

function Kit.under(hull)
	local dark = rgb(34, 32, 30)
	for _, x in ipairs({ -3.2, 3.2 }) do
		fine("ChassisRail", V3(0.5, 0.7, 40), CF(x, -0.95, 0.5), dark, M.Metal, hull)
	end
	for _, z in ipairs({ FRONT_WHEEL_Z, REAR_WHEEL_Z }) do
		cyl("Axle", "x", HW * 2 - 0.6, 0.45, CF(0, WHEEL_Y, z), dark, M.Metal, hull)
		for _, x in ipairs({ -3.2, 3.2 }) do
			fine("LeafSpring", V3(0.45, 0.22, 4.2), CF(x, WHEEL_Y + 0.35, z), rgb(52, 50, 46), M.Metal, hull)
		end
	end
	ball("Differential", 1.3, CF(0, WHEEL_Y, REAR_WHEEL_Z), dark, M.Metal, hull)
	fine("Engine", V3(3.6, 1.6, 4.2), CF(0, -0.6, -18.0), rgb(40, 38, 36), M.Metal, hull)
	cyl("DriveShaft", "z", REAR_WHEEL_Z + 15.8, 0.3, CF(0, -0.95, (REAR_WHEEL_Z - 15.8) / 2), rgb(60, 58, 56), M.Metal, hull)
	fine("FuelTank", V3(1.8, 1.1, 3.6), CF(-3.9, -1.35, 3), rgb(46, 50, 44), M.Metal, hull)
	fine("TankStrap", V3(1.9, 1.2, 0.14), CF(-3.9, -1.35, 3), dark, M.Metal, hull)
	local pipe = rgb(58, 50, 44)
	cable("ExhaustPipe", V3(1.4, -1.45, -16.0), V3(2.6, -1.55, 2), 0.34, pipe, hull, M.CorrodedMetal)
	cyl("Muffler", "z", 3.5, 0.95, CF(2.6, -1.55, 3.75), rgb(62, 54, 46), M.CorrodedMetal, hull)
	cable("ExhaustPipe", V3(2.6, -1.55, 5.5), V3(4.8, -1.55, HL + 0.6), 0.34, pipe, hull, M.CorrodedMetal)
	for i = 1, 4 do
		Kit.hub(i, hull)
	end
end

local function buildBody(startCF)
	local model = Bus.Model

	local root = Instance.new("Part")
	root.Name = "BusRoot"
	root.Size = V3(HW * 2 - 1, 1, HL * 2 - 6)
	root.CFrame = startCF
	root.Color = FLOOR_C
	root.Material = M.DiamondPlate
	root.Transparency = 1
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.CastShadow = false
	root.CollisionGroup = "Bus"
	root.TopSurface = Enum.SurfaceType.Smooth
	root.BottomSurface = Enum.SurfaceType.Smooth
	-- корень сборки всегда эта деталь (колёса и сиденья не должны его перехватить)
	root.RootPriority = 127
	root.Parent = model
	Bus.Root = root
	model.PrimaryPart = root

	local hull = Instance.new("Model")
	hull.Name = "Hull"
	hull.Parent = model

	Kit.floor(hull)
	buildSide(-1, hull)
	buildSide(1, hull)
	Kit.door(hull)
	Kit.front(hull)
	Kit.rear(hull)
	Kit.roof(hull)
	Kit.under(hull)
	Kit.ladder(hull)
end

-- Салон, кабина, печь -------------------------------------------------------------------------------

local ORANGE = rgb(255, 170, 80)
local GREEN = rgb(120, 230, 120)
local GREY = rgb(200, 200, 200)
local RED = rgb(255, 90, 90)
local YELLOW = rgb(255, 220, 90)

local BASE_BEDS = {
	{ cf = CF(-3.9, 1.35, -1.8), stand = V3(3.2, 2.5, 0) },
	{ cf = CF(3.9, 1.35, -2.5), stand = V3(-3.2, 2.5, 0) },
}
-- слоты «Салон» вдоль бортов посередине: место койки (bed) и коробки сигнализации (box)
local CABIN = {
	{ bed = CF(-3.9, 4.6, -1.8), stand = V3(3.2, -0.9, 0), upper = true, box = CF(-(HW - 0.85), 5.9, PILLARS[1]) },
	{ bed = CF(3.9, 4.6, -2.5), stand = V3(-3.2, -0.9, 0), upper = true, box = CF(HW - 0.85, 5.9, PILLARS[3]) },
	{ bed = CF(-3.9, 1.35, 6.9), stand = V3(3.2, 2.5, 0), upper = false, box = CF(-(HW - 0.85), 5.9, PILLARS[4]) },
}
local FUEL_ORDER = { "fuel_barrel", "gas_can", "coal" }

local wasReady = false

local function inDepot()
	return Bus.Root ~= nil and S.Run.Mode ~= "lobby" and S.Run.State == "Depot" and (Bus.S or 0) <= Config.DepotLength
end

local function missingText()
	local parts = {}
	if Bus.Wheels < 4 then
		table.insert(parts, string.format("колёса %d/4", Bus.Wheels))
	end
	if Bus.Fuel <= 0 then
		table.insert(parts, "нет топлива в печи")
	end
	return table.concat(parts, ", ")
end

local function refreshFurnace(force)
	if not furnace or not furnace.body.Parent then
		return
	end
	local lit = Bus.Fuel > 0
	if force or furnace.lit ~= lit then
		furnace.lit = lit
		furnace.fire.Enabled = lit
		furnace.light.Enabled = lit
		furnace.window.Color = lit and rgb(255, 120, 30) or rgb(50, 30, 24)
		furnace.window.Material = lit and M.Neon or M.SmoothPlastic
		if furnace.loop then
			if lit then
				if not furnace.loop.Playing then
					furnace.loop:Play()
				end
			else
				furnace.loop:Stop()
			end
		end
	end
	local smoke = lit and math.abs(Bus.V) > 2
	if force or furnace.smokeOn ~= smoke then
		furnace.smokeOn = smoke
		furnace.smoke.Enabled = smoke
	end
end

local function updateReady()
	Bus.Ready = Bus.Wheels >= 4 and Bus.Fuel > 0
	if Bus.Ready and not wasReady and inDepot() then
		PD.NotifyAll("Автобус собран и заправлен — садитесь за руль!", GREEN)
		Net.Get("Toast"):FireAllClients("АВТОБУС ГОТОВ", "Сядьте за руль: W — газ, S — тормоз", YELLOW)
	end
	wasReady = Bus.Ready
end

-- Койка: матрас, подушка, сбитое одеяло свисает в проход
local function addBed(folder, cf, upper, stand)
	local bed = add("Bunk", V3(3.0, 0.6, 7), cf, rgb(92, 50, 42), M.Fabric, nil, folder)
	deco("Pillow", V3(2.3, 0.35, 1.2), cf * CF(0, 0.45, 2.6), rgb(176, 166, 146), M.Fabric, folder)
	add("BunkFrame", V3(3.2, 0.3, 7.2), cf * CF(0, -0.45, 0), FRAME, M.Metal, nil, folder)
	local aisle = cf.X < 0 and 1 or -1
	local blanket = PAL.blankets[drng:NextInteger(1, #PAL.blankets)]
	fine("Blanket", V3(2.7, 0.1, 3.4), cf * CF(drng:NextNumber(-0.15, 0.15), 0.35, drng:NextNumber(-2.0, -1.0)) * ANG(0, drng:NextNumber(-0.2, 0.2), 0), blanket, M.Fabric, folder)
	fine("BlanketDrape", V3(0.1, 0.75, 2.6), cf * CF(aisle * 1.56, -0.02, -1.5) * ANG(0, 0, aisle * 0.18), blanket, M.Fabric, folder)
	if upper then
		local h = cf.Y - FLOOR
		local px = cf.X < 0 and cf.X + 1.4 or cf.X - 1.4
		for _, dz in ipairs({ -3.4, 3.4 }) do
			deco("BunkPost", V3(0.25, h, 0.25), CF(px, FLOOR + h / 2, cf.Z + dz), FRAME, M.Metal, folder)
		end
		fine("BunkGuard", V3(0.12, 0.12, 6.4), cf * CF(aisle * 1.45, 0.75, 0), METAL, M.Metal, folder)
	end
	S.Sleep.RegisterBed(bed, "bus", stand)
	return bed
end

-- Стрелка прибора: жёсткая деталь; крутящуюся копию рисует клиент (см. BusClient)
function Kit.needle(kind, dcf, len, a0, a1, parent)
	local shift = len * 0.38
	local mount = dcf * CF(0, 0, 0.07)
	local p = fine("Needle", V3(0.05, len, 0.03), mount * ANG(0, 0, a0) * CF(0, shift, 0), rgb(235, 70, 30), M.Neon, parent)
	p:SetAttribute("Gauge", kind)
	p:SetAttribute("Angle0", a0)
	p:SetAttribute("Angle1", a1)
	p:SetAttribute("RestAngle", a0)
	p:SetAttribute("PivotShift", shift)
	CollectionService:AddTag(p, GAUGE_TAG)
	ball("NeedleHub", 0.1, mount * CF(0, 0, 0.015), rgb(20, 20, 20), M.Metal, parent)
	return p
end

-- Приборка: спидометр (0…макс. скорость на 240°) и указатель топлива
function Kit.gauges(panelCF, interior)
	for _, g in ipairs({ { -0.55, 0.78, "speed", rad(120), rad(-120), 9, "КМ/Ч" }, { 0.62, 0.56, "fuel", rad(50), rad(-50), 5, "ТОПЛИВО" } }) do
		local dcf = panelCF * CF(g[1], -0.02, 0.08)
		local r = g[2]
		cyl("GaugeRim", "z", 0.05, r + 0.09, dcf, PAL.chrome, M.Metal, interior)
		cyl("GaugeFace", "z", 0.04, r, dcf * CF(0, 0, 0.02), rgb(226, 214, 180), M.SmoothPlastic, interior)
		for k = 0, g[6] - 1 do
			local a = g[4] + (g[5] - g[4]) * (k / (g[6] - 1))
			fine("GaugeTick", V3(0.03, 0.1, 0.02), dcf * CF(0, 0, 0.045) * ANG(0, 0, a) * CF(0, r * 0.8, 0), rgb(30, 30, 30), M.SmoothPlastic, interior)
		end
		Kit.sign("GaugeLabel", V3(r * 0.9, r * 0.26, 0.02), dcf * CF(0, -r * 0.5, 0.05), rgb(226, 214, 180), rgb(60, 50, 40), g[7], Enum.NormalId.Back, interior, 200)
		Kit.needle(g[3], dcf, r * 0.82, g[4], g[5], interior)
	end
end

-- Место водителя: сиденье с тряпкой, приборка, руль, рация, провода
function Kit.driverDetails(interior)
	local sx, sz = -3.4, -12.4
	fine("SeatCushion", V3(2.0, 0.1, 2.0), CF(sx, 1.63, sz), PAL.upholstery, M.Fabric, interior)
	fine("SeatPiping", V3(2.24, 0.12, 0.12), CF(sx, 1.6, sz - 1.05), rgb(30, 22, 18), M.Fabric, interior)
	fine("Headrest", V3(1.5, 0.7, 0.34), CF(sx, 4.1, sz + 1.15), PAL.upholstery, M.Fabric, interior)
	local rag = rgb(122, 112, 88)
	fine("SeatRag", V3(1.5, 0.1, 0.9), CF(sx + 0.25, 3.8, sz + 1.1) * ANG(0, 0.15, 0), rag, M.Fabric, interior)
	fine("SeatRagHang", V3(1.3, 1.4, 0.08), CF(sx + 0.3, 3.05, sz + 1.42) * ANG(rad(3), 0.12, 0), rag, M.Fabric, interior)
	cyl("DriverPole", "y", ROOF_BOTTOM - FLOOR - 0.1, 0.2, CF(-2.1, (FLOOR + ROOF_BOTTOM) / 2, PILLARS[1] + 0.4), PAL.chrome, M.Metal, interior)

	-- приборка: наклонная панель со спидометром и указателем топлива
	local panelCF = CF(sx, 3.05, CAB_Z + 0.95) * ANG(rad(-30), 0, 0)
	fine("ClusterPanel", V3(2.5, 1.0, 0.14), panelCF, rgb(28, 27, 26), M.Metal, interior)
	fine("ClusterHood", V3(2.6, 0.1, 0.5), panelCF * CF(0, 0.52, 0.16) * ANG(rad(30), 0, 0), rgb(20, 19, 18), M.Metal, interior)
	Kit.gauges(panelCF, interior)
	for i, c in ipairs({ rgb(200, 40, 30), rgb(60, 180, 70), rgb(220, 150, 30) }) do
		fine("WarnLamp", V3(0.14, 0.14, 0.04), panelCF * CF(-0.22 + i * 0.22, 0.38, 0.09), c, M.Neon, interior)
	end

	-- руль: обод из сегментов, три спицы, ступица, колонка (ниже линии взгляда)
	local wcf = CF(sx, 3.2, CAB_Z + 1.75) * ANG(rad(50), 0, 0)
	local R, n = 0.82, 10
	for k = 0, n - 1 do
		local phi = k * 2 * math.pi / n
		fine("WheelRim", V3(2 * R * math.sin(math.pi / n) + 0.06, 0.14, 0.14), wcf * CF(R * math.cos(phi), 0, R * math.sin(phi)) * ANG(0, -(phi + math.pi / 2), 0), rgb(22, 20, 18), M.SmoothPlastic, interior)
	end
	for k = 0, 2 do
		local phi = math.pi / 2 + k * 2 * math.pi / 3
		fine("WheelSpoke", V3(R, 0.08, 0.12), wcf * CF(R / 2 * math.cos(phi), 0, R / 2 * math.sin(phi)) * ANG(0, -phi, 0), rgb(44, 42, 40), M.Metal, interior)
	end
	cyl("WheelHub", "y", 0.14, 0.36, wcf, rgb(30, 28, 26), M.Metal, interior)
	cable("SteeringColumn", (wcf * CF(0, -0.1, 0)).Position, V3(sx, 2.0, CAB_Z + 0.9), 0.22, rgb(34, 32, 30), interior, M.Metal)

	-- козырёк, зеркало салона с оберегом, рация, провода, рычаг
	fine("SunVisor", V3(2.4, 0.08, 1.0), CF(sx, HEAD - 0.25, CAB_Z + 0.55) * ANG(rad(-25), 0, 0), rgb(60, 56, 50), M.Fabric, interior)
	local mpos = V3(-1.0, HEAD - 0.5, CAB_Z + 0.25)
	cable("MirrorStem", mpos, V3(-1.0, HEAD + 0.1, CAB_Z + 0.05), 0.07, FRAME, interior, M.Metal)
	fine("CabinMirror", V3(1.1, 0.34, 0.1), CF(mpos), FRAME, M.Metal, interior)
	fine("CabinMirrorGlass", V3(1.0, 0.26, 0.03), CF(mpos) * CF(0, 0, 0.055), rgb(160, 176, 180), M.Glass, interior, { Reflectance = 0.35 })
	cable("CharmString", mpos + V3(0.25, -0.17, 0.02), mpos + V3(0.25, -0.72, 0.02), 0.025, rgb(150, 30, 26), interior)
	fine("Charm", V3(0.22, 0.28, 0.04), CF(mpos + V3(0.25, -0.86, 0.02)) * ANG(0, 0.3, 0), rgb(160, 120, 60), M.Wood, interior)
	fine("Radio", V3(0.9, 0.3, 0.7), CF(-5.2, 2.45, CAB_Z + 0.9), rgb(30, 30, 28), M.Metal, interior)
	fine("RadioFace", V3(0.7, 0.16, 0.04), CF(-5.2, 2.45, CAB_Z + 1.27), rgb(60, 160, 80), M.Neon, interior)
	for i, c in ipairs({ rgb(170, 30, 26), rgb(210, 170, 40), PAL.cable }) do
		local x = -1.5 + i * 0.22
		cable("DashWire", V3(x, 1.9, CAB_Z + 1.05), V3(x + 0.1, FLOOR + 0.1, CAB_Z + 1.5), 0.05, c, interior)
	end
	cable("GearLever", V3(-1.95, FLOOR, CAB_Z + 3.4), V3(-1.8, 1.9, CAB_Z + 3.2), 0.12, PAL.chrome, interior, M.Metal)
	ball("GearKnob", 0.3, CF(-1.8, 1.95, CAB_Z + 3.2), rgb(20, 20, 20), M.SmoothPlastic, interior)
end

-- Водительское место (слева спереди)
local function buildDriver(interior)
	local sx, sz = -3.4, -12.4
	local seat = Instance.new("Seat")
	seat.Name = "DriverSeat"
	seat.Size = V3(2.2, 1, 2.2)
	seat.Color = rgb(58, 40, 30)
	seat.Material = M.Fabric
	seat.Anchored = false
	seat.Massless = true
	seat.CanTouch = false
	seat.CollisionGroup = "Bus"
	seat.CFrame = Bus.Root.CFrame * CF(sx, 1.1, sz)
	local sw = Instance.new("WeldConstraint")
	sw.Part0 = Bus.Root
	sw.Part1 = seat
	sw.Parent = seat
	seat.Parent = Bus.Model
	driverSeat = seat
	add("SeatBack", V3(2.2, 2.8, 0.4), CF(sx, 2.5, sz + 1.3) * ANG(rad(8), 0, 0), rgb(58, 40, 30), M.Fabric, nil, interior)
	add("Dash", V3(7.6, 2.4, 1.1), CF(-2.2, 1.7, CAB_Z + 0.55), FRAME, M.Metal, nil, interior)
	Kit.driverDetails(interior)

	local prompt = makePrompt(seat, "DrivePrompt", "Сесть за руль", "Автобус", 0.3, 8)
	local lastPlayer, lastChar = nil, nil
	prompt.Triggered:Connect(function(player)
		if seat.Occupant or not PD.IsActive(player) then
			return
		end
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if not hum or not hrp or hum.SeatPart then
			return
		end
		if (hrp.Position - seat.Position).Magnitude > prompt.MaxActivationDistance + 6 then
			return
		end
		seat:Sit(hum)
	end)
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occ = seat.Occupant
		local plr = occ and Players:GetPlayerFromCharacter(occ.Parent) or nil
		if lastPlayer and lastPlayer ~= plr then
			returnOwnership(lastPlayer, lastChar)
		end
		lastPlayer = plr
		lastChar = occ and occ.Parent or nil
		prompt.Enabled = occ == nil
		if occ then
			claimOwnership()
		end
		Bus.Driver = plr
		Bus.Throttle = 0
		Net.State():SetAttribute("DriverName", plr and plr.DisplayName or "")
		if plr then
			if Bus.Ready then
				PD.Notify(plr, "W — газ, S — тормоз, Пробел — встать", GREY)
			else
				PD.Notify(plr, "Автобус не готов: " .. missingText(), ORANGE)
			end
		end
	end)
end

-- Печь: сзади по центру, окошко огня смотрит в салон, труба — через дыру в крыше
local function buildFurnace(interior)
	local z = 18.6
	local front = z - 1.5
	local body = add("Furnace", V3(3.2, 3.4, 3), CF(0, FLOOR + 1.7, z), rgb(46, 44, 42), M.CorrodedMetal, nil, interior)
	deco("FurnaceTop", V3(3.5, 0.3, 3.3), CF(0, FLOOR + 3.55, z), FRAME, M.Metal, interior)
	deco("FurnaceFoot", V3(3.5, 0.3, 3.3), CF(0, FLOOR + 0.15, z), FRAME, M.Metal, interior)
	deco("FireFrame", V3(2.3, 1.7, 0.08), CF(0, FLOOR + 1.45, front - 0.02), FRAME, M.Metal, interior)
	local window = deco("FurnaceWindow", V3(1.8, 1.25, 0.15), CF(0, FLOOR + 1.45, front - 0.08), rgb(255, 120, 30), M.Neon, interior)
	for i = -1, 1 do
		deco("FireBar", V3(0.15, 1.35, 0.12), CF(i * 0.6, FLOOR + 1.45, front - 0.18), STRIPE, M.Metal, interior)
	end
	local fire = Instance.new("Fire")
	fire.Size = 3
	fire.Heat = 3
	fire.Color = rgb(255, 120, 30)
	fire.SecondaryColor = rgb(255, 210, 80)
	fire.Parent = window
	local light = Instance.new("PointLight")
	light.Color = rgb(255, 140, 50)
	light.Range = 14
	light.Brightness = 1.6
	light.Parent = window
	-- труба через дыру в крыше (верх колпака ниже 14 studs над землёй)
	local cz = z + 0.6
	local capY = ROOF_TOP + 1.3
	local pipeLen = capY - (FLOOR + 3.7)
	cyl("Chimney", "y", pipeLen, 0.8, CF(0, FLOOR + 3.7 + pipeLen / 2, cz), FRAME, M.CorrodedMetal, interior)
	local cap = cyl("ChimneyCap", "y", 0.3, 1.2, CF(0, capY + 0.1, cz), STRIPE, M.Metal, interior)
	fine("ChimneyCollar", V3(2.2, 0.1, 1.6), CF(0, ROOF_TOP - 0.05, cz), FRAME, M.Metal, interior)
	cyl("ChimneyBracket", "y", 0.16, 1.0, CF(0, 6.2, cz), STRIPE, M.Metal, interior)
	local smoke = Instance.new("Smoke")
	smoke.Color = rgb(60, 58, 56)
	smoke.Opacity = 0.12
	smoke.RiseVelocity = 4
	smoke.Size = 2
	smoke.Enabled = false
	smoke.Parent = cap
	local sign = deco("FuelSign", V3(2.6, 0.55, 0.08), CF(0, FLOOR + 2.9, front - 0.04), rgb(18, 16, 14), M.SmoothPlastic, interior)
	surfaceText(sign, Enum.NormalId.Front, "ТОПЛИВО", rgb(255, 170, 60))
	for _, dy in ipairs({ 0.45, 3.05 }) do
		for _, dx in ipairs({ -1.3, 1.3 }) do
			ball("Rivet", 0.2, CF(dx, FLOOR + dy, front + 0.02), PAL.rivet, M.Metal, interior)
		end
	end
	cyl("FurnaceHandle", "x", 1.2, 0.14, CF(0, FLOOR + 2.35, front - 0.22), PAL.chrome, M.Metal, interior)
	cyl("PressureGaugeRim", "z", 0.06, 0.7, CF(1.1, FLOOR + 3.0, front - 0.04), PAL.chrome, M.Metal, interior)
	cyl("PressureGauge", "z", 0.08, 0.58, CF(1.1, FLOOR + 3.0, front - 0.1), rgb(214, 204, 172), M.SmoothPlastic, interior)
	fine("GaugeArrow", V3(0.03, 0.24, 0.04), CF(1.05, FLOOR + 3.05, front - 0.15) * ANG(0, 0, 0.7), rgb(180, 30, 20), M.SmoothPlastic, interior)
	fine("AshPlate", V3(2.6, 0.04, 1.8), CF(0, FLOOR + 0.03, front - 1.2) * ANG(0, 0.08, 0), rgb(34, 32, 30), M.Slate, interior)
	for _ = 1, 3 do
		ball("Ash", drng:NextNumber(0.18, 0.3), CF(drng:NextNumber(-1, 1), FLOOR + 0.08, front - drng:NextNumber(0.6, 1.6)), rgb(62, 60, 58), M.Slate, interior)
	end
	deco("CoalBin", V3(2.2, 1, 1.8), CF(-3.4, FLOOR + 0.5, 19.4), FRAME, M.CorrodedMetal, interior)
	for i = 1, 4 do
		deco("CoalLump", V3(0.6, 0.45, 0.6), CF(-4.2 + i * 0.35, FLOOR + 1.05 + (i % 2) * 0.1, 19.4 + (i % 3 - 1) * 0.35) * ANG(0, i, 0.3), rgb(30, 30, 32), M.Slate, interior)
	end
	cable("Poker", V3(-2.4, FLOOR + 1.0, 18.4), V3(-1.8, FLOOR + 2.7, 18.2), 0.08, FRAME, interior, M.Metal)
	-- луп горящей печи (3D): играет, пока есть топливо
	local loop = Instance.new("Sound")
	loop.Name = "FurnaceLoop"
	loop.RollOffMinDistance = 6
	loop.RollOffMaxDistance = 60
	if Sounds.Apply(loop, "furnace_loop") then
		loop.Looped = true
		loop.Parent = body
	else
		loop:Destroy()
		loop = nil
	end
	local prompt = makePrompt(body, "FuelPrompt", "Закинуть топливо", "Печь", 0.3, 9)
	prompt.Triggered:Connect(function(player)
		Bus.RefuelWith(player, nil)
	end)
	furnace = { body = body, window = window, fire = fire, light = light, smoke = smoke, loop = loop, lit = nil, smokeOn = nil }
end

-- Ящик с инструментами и оружием: у левого борта сразу за водителем, проход не перекрывает
function Kit.crate(interior)
	local cx, cz = -4.75, -8.1
	repairBox = add("Toolbox", V3(2.0, 1.5, 3.6), CF(cx, FLOOR + 0.75, cz), rgb(74, 82, 54), M.Metal, nil, interior)
	deco("ToolboxLid", V3(2.1, 0.2, 3.7), CF(cx, FLOOR + 1.6, cz) * ANG(0, 0, rad(-3)), rgb(62, 70, 46), M.Metal, interior)
	for _, dz in ipairs({ -1.2, 1.2 }) do
		fine("ToolboxBand", V3(2.06, 1.52, 0.18), CF(cx, FLOOR + 0.75, cz + dz), FRAME, M.Metal, interior)
	end
	for _, dz in ipairs({ -0.8, 0.8 }) do
		fine("ToolboxLatch", V3(0.1, 0.3, 0.32), CF(cx + 1.03, FLOOR + 1.2, cz + dz), PAL.chrome, M.Metal, interior)
	end
	cable("Wrench", V3(cx - 0.4, FLOOR + 1.78, cz - 1.1), V3(cx + 0.5, FLOOR + 1.8, cz - 0.2), 0.12, PAL.chrome, interior, M.Metal)
	cable("CrowBar", V3(cx - 0.6, FLOOR + 1.8, cz + 1.4), V3(cx + 0.6, FLOOR + 1.82, cz + 0.4), 0.14, rgb(140, 40, 32), interior, M.Metal)
	surfaceText(repairBox, Enum.NormalId.Right, "РЕМОНТ", rgb(240, 235, 225))
	local repairPrompt = makePrompt(repairBox, "RepairPrompt", "Починить автобус", "Ящик с инструментами", 1.2, 9)
	repairPrompt.Triggered:Connect(function(player)
		Bus.RepairWith(player)
	end)
end

-- Салон: круглые жёлтые плафоны, поручни, кожухи арок, огнетушитель, записки
function Kit.cabin(interior)
	for i, z in ipairs({ -12, -5.5, 5.5, 12.5 }) do
		deco("LampCage", V3(0.15, 1.7, 1.7), CF(0, ROOF_BOTTOM - 0.08, z) * ANG(0, 0, rad(90)), FRAME, M.Metal, interior, { Shape = "Cylinder" })
		local lamp = deco("CeilingLamp" .. i, V3(0.3, 1.3, 1.3), CF(0, ROOF_BOTTOM - 0.25, z) * ANG(0, 0, rad(90)), AMBER, M.Neon, interior, { Shape = "Cylinder" })
		local light = Instance.new("PointLight")
		light.Color = rgb(255, 180, 100)
		light.Range = 16
		light.Brightness = 0.8
		light.Shadows = false
		light.Parent = lamp
	end
	for _, x in ipairs({ -2.7, 2.7 }) do
		deco("Handrail", V3(0.15, 0.15, 26), CF(x, ROOF_BOTTOM - 0.8, 5), METAL, M.Metal, interior)
		for k = 0, 3 do
			cable("RailHanger", V3(x, ROOF_BOTTOM - 0.1, -7 + k * 8), V3(x, ROOF_BOTTOM - 0.75, -7 + k * 8), 0.08, METAL, interior, M.Metal)
		end
	end
	for _, p in ipairs({ { -2.45, -9.8 }, { 2.75, -9.9 }, { 2.45, 10.5 } }) do
		cyl("Stanchion", "y", ROOF_BOTTOM - FLOOR - 0.1, 0.2, CF(p[1], (FLOOR + ROOF_BOTTOM) / 2, p[2]), PAL.chrome, M.Metal, interior)
	end
	for _, w in ipairs({ { -1, REAR_WHEEL_Z }, { 1, REAR_WHEEL_Z } }) do
		local x = w[1] * (HW - 0.55)
		fine("WheelWell", V3(1.1, 1.3, 5.2), CF(x, FLOOR + 0.65, w[2]), rgb(56, 54, 52), M.DiamondPlate, interior)
		fine("WheelWellTop", V3(1.14, 0.1, 5.24), CF(x, FLOOR + 1.33, w[2]), FRAME, M.Metal, interior)
	end
	cyl("Extinguisher", "y", 1.1, 0.42, CF(4.95, FLOOR + 1.0, -9.6), rgb(170, 30, 26), M.Metal, interior)
	ball("ExtinguisherTop", 0.3, CF(4.95, FLOOR + 1.62, -9.6), rgb(40, 40, 40), M.Metal, interior)
	Kit.sign("ExitSignInside", V3(2.0, 0.42, 0.08), CF(HW - 0.35, HEAD - 0.4, DOOR_Z1 - 0.2) * ANG(0, rad(-90), 0), rgb(20, 56, 30), rgb(120, 255, 150), "ВЫХОД", Enum.NormalId.Front, interior, 50)
	Kit.sign("Note", V3(0.04, 0.8, 1.05), CF(-(HW - 0.08), 5.6, -6.5) * ANG(0.06, 0, 0), PAL.cream, rgb(40, 30, 24), "НЕ ГЛУШИ\nМОТОР", Enum.NormalId.Right, interior, 60)
	Kit.sign("Note", V3(0.04, 0.7, 0.95), CF(HW - 0.08, 5.6, 3.5) * ANG(-0.08, 0, 0), PAL.cream, rgb(40, 30, 24), "СПИМ ПО\nОЧЕРЕДИ", Enum.NormalId.Left, interior, 60)
end

local function buildInterior()
	local interior = Instance.new("Model")
	interior.Name = "Interior"
	interior.Parent = Bus.Model
	buildDriver(interior)
	buildFurnace(interior)
	Kit.crate(interior)
	Kit.cabin(interior)

	-- базовые койки вдоль бортов посередине
	local beds = Instance.new("Model")
	beds.Name = "Beds"
	beds.Parent = Bus.Model
	for _, b in ipairs(BASE_BEDS) do
		addBed(beds, b.cf, false, b.stand)
	end
end

-- Слоты ------------------------------------------------------------------------------------------------

-- Размеры стены в проёме: ширина между стойками и высота от WALL_Y0 до крыши
function Kit.wallSize(slotType, index)
	if slotType == "rear" then
		return 11.5, ROOF_BOTTOM - WALL_Y0
	end
	local k = (index - 1) % 4 + 1
	return PILLARS[k + 1] - PILLARS[k] - 0.1, ROOF_BOTTOM - WALL_Y0
end

-- CFrame установленной детали. У стен: X — ширина, Y — вверх, Z — наружу; у колёс ось X — ось вращения
local function slotCF(slotType, i)
	if slotType == "wheel" then
		return Kit.wheelCF(i)
	elseif slotType == "side" then
		local side = i <= 4 and -1 or 1
		local k = (i - 1) % 4 + 1
		return CF(side * (HW - 0.32), (WALL_Y0 + ROOF_BOTTOM) / 2, (PILLARS[k] + PILLARS[k + 1]) / 2) * ANG(0, side * math.pi / 2, 0)
	elseif slotType == "rear" then
		return CF(0, (WALL_Y0 + ROOF_BOTTOM) / 2, HL - 0.45)
	elseif slotType == "front" then
		return CF(0, -0.4, -HL - 0.9)
	elseif slotType == "roof" then
		return CF(0, ROOF_TOP, i == 1 and -9 or 9)
	elseif slotType == "lamp" then
		return CF(i == 1 and -(HW - 1.1) or (HW - 1.1), ROOF_TOP, CAB_Z + 1.4)
	elseif slotType == "cabin" then
		return CABIN[i].bed
	end
	return CF()
end

-- Метка слота: невидимая деталь размером с будущую деталь (по ней GRAB рисует призрак).
-- У колеса ось вращения — локальная X метки, у стены тонкая сторона — по нормали (локальная Z)
local function slotSize(slotType, i)
	if slotType == "wheel" then
		return V3(1.5, WHEEL_R * 2, WHEEL_R * 2)
	elseif slotType == "side" or slotType == "rear" then
		local w, h = Kit.wallSize(slotType, i)
		return V3(w, h, 0.3)
	elseif slotType == "front" then
		return V3(HW * 2, 1.4, 1.2)
	elseif slotType == "roof" then
		return V3(3, 2.2, 3)
	elseif slotType == "lamp" then
		return V3(1.4, 1.8, 1.4)
	end
	return V3(3, 0.6, 7)
end

local function createSlot(folder, slotType, i)
	local def = BusParts.Slots[slotType]
	local cf = slotCF(slotType, i)
	local entry = { slot = slotType, index = i, cf = cf, partId = nil }
	local marker = deco("Slot_" .. slotType .. i, slotSize(slotType, i), cf, GREY, M.SmoothPlastic, folder, { Transparency = 1, CastShadow = false })
	marker:SetAttribute("SlotType", slotType)
	marker:SetAttribute("SlotIndex", i)
	marker:SetAttribute("Accepts", table.concat(def.accepts, ","))
	marker:SetAttribute("Free", true)
	CollectionService:AddTag(marker, SLOT_TAG)
	if slotType == "wheel" then
		setWaypoint(marker, "КОЛЕСО", true, nil, 120)
	end
	local action = slotType == "wheel" and "Прикрепить колесо" or ("Прикрепить: " .. def.name)
	local prompt = makePrompt(marker, "AttachPrompt", action, "Автобус", 0.6, slotType == "cabin" and 8 or 10)
	prompt:SetAttribute("SlotType", slotType)
	prompt:SetAttribute("SlotIndex", i)
	prompt.Triggered:Connect(function(player)
		Bus.AttachToSlot(player, slotType, i)
	end)
	entry.marker = marker
	entry.prompt = prompt
	return entry
end

local function buildSlots()
	local folder = Instance.new("Model")
	folder.Name = "Slots"
	folder.Parent = Bus.Model
	local parts = Instance.new("Model")
	parts.Name = "Parts"
	parts.Parent = Bus.Model
	slots = {}
	for _, slotType in ipairs(BusParts.SlotOrder) do
		local def = BusParts.Slots[slotType]
		slots[slotType] = {}
		for i = 1, def.count do
			slots[slotType][i] = createSlot(folder, slotType, i)
		end
	end
end

-- Визуал деталей ---------------------------------------------------------------------------------------

-- Колесо: шина с тегом (её копию крутит клиент), диск и протектор приварены к шине
local function buildWheel(f, cf)
	local o = cf.X < 0 and -1 or 1 -- наружу
	local wheel = add("Wheel", V3(1.5, WHEEL_R * 2, WHEEL_R * 2), cf, rgb(26, 26, 26), M.Rubber, { Shape = "Cylinder", CanCollide = false, CanTouch = false, CanQuery = false }, f)
	wheel:SetAttribute("Radius", WHEEL_R)
	CollectionService:AddTag(wheel, WHEEL_TAG)
	local noShadow = { Shape = "Cylinder", CastShadow = false }
	addChild("Rim", V3(0.08, 3.0, 3.0), wheel, CF(o * 0.78, 0, 0), METAL, M.Metal, f, noShadow)
	addChild("RimDish", V3(0.1, 2.2, 2.2), wheel, CF(o * 0.83, 0, 0), rgb(122, 118, 110), M.Metal, f, noShadow)
	addChild("HubCap", V3(0.24, 0.9, 0.9), wheel, CF(o * 0.93, 0, 0), FRAME, M.Metal, f, noShadow)
	for k = 0, 4 do
		local a = k * math.pi * 2 / 5
		addChild("Lug", V3(0.14, 0.2, 0.2), wheel, CF(o * 0.92, math.cos(a) * 0.62, math.sin(a) * 0.62), rgb(172, 162, 140), M.Metal, f, noShadow)
	end
	for k = 0, 3 do
		local a = k * math.pi / 2 + math.pi / 4
		addChild("RimHole", V3(0.1, 0.38, 0.38), wheel, CF(o * 0.85, math.cos(a) * 1.25, math.sin(a) * 1.25), rgb(16, 16, 16), M.Metal, f, noShadow)
	end
	addChild("Valve", V3(0.08, 0.3, 0.1), wheel, CF(o * 0.84, 1.42, 0.2), rgb(40, 40, 40), M.Metal, f, { CastShadow = false })
	-- светлая метка на боковине: сразу видно, что колесо крутится
	addChild("TireMark", V3(0.04, 0.6, 0.3), wheel, CF(o * 0.76, 1.8, 0), rgb(196, 170, 70), M.SmoothPlastic, f, { CastShadow = false })
	for k = 0, 9 do
		local a = k * math.pi / 5
		addChild("Tread", V3(0.62, 0.12, 0.5), wheel, ANG(a, 0, 0) * CF((k % 2 == 0) and 0.36 or -0.36, WHEEL_R - 0.05, 0), rgb(18, 18, 18), M.Rubber, f, { CastShadow = false })
	end
end

-- Деревянная стена: доски с зазорами, поперечины, раскос и гвозди
function Kit.woodWall(f, cf, w, h)
	local woods = { rgb(120, 86, 54), rgb(104, 74, 46), rgb(132, 96, 60), rgb(96, 70, 44) }
	local n, gap = 6, 0.14
	local ph = (h - gap * (n - 1)) / n
	local battens = w > 9 and { -0.34, 0, 0.34 } or { -0.3, 0.3 }
	for j = 1, n do
		local y = -h / 2 + ph / 2 + (j - 1) * (ph + gap)
		local cut = drng:NextNumber(0, 0.4)
		local dx = (j % 2 == 0) and cut / 2 or -cut / 2
		deco("Plank", V3(w - cut, ph, 0.22), cf * CF(dx, y, 0.03) * ANG(0, 0, drng:NextNumber(-0.025, 0.025)), woods[drng:NextInteger(1, #woods)], M.WoodPlanks, f)
		if j % 2 == 1 then
			for _, bx in ipairs(battens) do
				ball("Nail", 0.16, cf * CF(bx * w + drng:NextNumber(-0.15, 0.15), y, 0.16), rgb(70, 68, 64), M.Metal, f)
			end
		end
	end
	for _, bx in ipairs(battens) do
		deco("Batten", V3(0.75, h - 0.3, 0.12), cf * CF(bx * w, 0, -0.14), rgb(96, 70, 44), M.WoodPlanks, f)
	end
	deco("Brace", V3(0.55, math.sqrt((w * 0.6) ^ 2 + (h - 1) ^ 2), 0.08), cf * CF(0, 0, -0.24) * ANG(0, 0, math.atan2(w * 0.6, h - 1)), rgb(110, 80, 50), M.WoodPlanks, f)
end

-- Металлическая стена: листы с заклёпками, стыковая накладка и рёбра
function Kit.metalWall(f, cf, w, h)
	local n = w > 9 and 3 or 2
	local sw = w / n
	local greys = { rgb(112, 114, 116), rgb(98, 100, 102), rgb(120, 116, 108) }
	for j = 1, n do
		local x = -w / 2 + sw * (j - 0.5)
		deco("Sheet", V3(sw + 0.12, h - 0.1, 0.14), cf * CF(x, drng:NextNumber(-0.05, 0.05), 0.02 + (j % 2) * 0.03) * ANG(0, 0, drng:NextNumber(-0.012, 0.012)), greys[(j - 1) % 3 + 1], j % 2 == 0 and M.DiamondPlate or M.CorrodedMetal, f)
		if j < n then
			fine("SeamStrip", V3(0.3, h - 0.2, 0.06), cf * CF(x + sw / 2, 0, 0.12), rgb(70, 70, 72), M.Metal, f)
			for _, y in ipairs({ -h * 0.35, 0, h * 0.35 }) do
				ball("Rivet", 0.22, cf * CF(x + sw / 2, y, 0.15), rgb(64, 64, 66), M.Metal, f)
			end
		end
	end
	local cnt = w > 9 and 5 or 4
	for _, y in ipairs({ -h / 2 + 0.3, h / 2 - 0.3 }) do
		fine("EdgeRib", V3(w - 0.2, 0.24, 0.06), cf * CF(0, y, 0.12), rgb(80, 80, 82), M.Metal, f)
		for i = 0, cnt - 1 do
			ball("Rivet", 0.2, cf * CF(-w / 2 + 0.5 + (w - 1) * i / (cnt - 1), y, 0.16), rgb(64, 64, 66), M.Metal, f)
		end
	end
	for _ = 1, 2 do
		fine("PlateRust", V3(0.35, drng:NextNumber(1.2, 2.4), 0.04), cf * CF(drng:NextNumber(-w / 3, w / 3), drng:NextNumber(-1, 1), 0.11), PAL.rust2, M.CorrodedMetal, f)
	end
end

-- Стена в проёме: панель во всю высоту; невидимый коллайдер держит зомби и игроков
local function buildWall(f, entry, metal)
	local cf = entry.cf
	local w, h = Kit.wallSize(entry.slot, entry.index)
	local collider = add("WallCollider", V3(w, h, 0.3), cf, metal and rgb(110, 112, 114) or rgb(120, 86, 54), metal and M.Metal or M.WoodPlanks,
		{ Transparency = 1, CastShadow = false, CanTouch = false }, f)
	collider:SetAttribute("BusWall", metal and "metal" or "wood")
	if metal then
		Kit.metalWall(f, cf, w, h)
	else
		Kit.woodWall(f, cf, w, h)
	end
end

local function buildGrill(f, cf, saw)
	local steel = rgb(150, 150, 152)
	deco("GrillBar", V3(HW * 2 + 0.6, 0.6, 0.5), cf, FRAME, M.Metal, f)
	deco("GrillBarTop", V3(HW * 2 + 0.2, 0.4, 0.4), cf * CF(0, 1.2, 0.2), FRAME, M.Metal, f)
	for _, x in ipairs({ -4.5, 0, 4.5 }) do
		fine("GrillBracket", V3(0.4, 1.5, 0.9), cf * CF(x, 0.6, 0.45), rgb(46, 44, 42), M.Metal, f)
		cyl("GrillBolt", "z", 0.1, 0.24, cf * CF(x, 0, -0.28), PAL.chrome, M.Metal, f)
	end
	if saw then
		for _, x in ipairs({ -3.2, 3.2 }) do
			deco("SawBlade", V3(0.25, 4.2, 4.2), cf * CF(x, 0.6, -1.6) * ANG(0, 0, rad(90)), rgb(190, 190, 194), M.Metal, f, { Shape = "Cylinder" })
			deco("SawHub", V3(0.5, 1, 1), cf * CF(x, 0.6, -1.6) * ANG(0, 0, rad(90)), FRAME, M.Metal, f, { Shape = "Cylinder" })
			for k = 0, 7 do
				local a = k * math.pi / 4
				deco("SawTooth", V3(0.4, 0.2, 0.4), cf * CF(x + math.cos(a) * 2.15, 0.6, -1.6 + math.sin(a) * 2.15) * ANG(0, a, 0), steel, M.Metal, f)
			end
		end
	end
	for x = -5, 5, 2 do
		deco("Spike", V3(0.35, 0.35, 2.4), cf * CF(x, 0, -1.3), steel, M.Metal, f)
		deco("SpikeTop", V3(0.3, 0.3, 1.6), cf * CF(x + 1, 1.2, -0.8), steel, M.Metal, f)
	end
end

local function buildTurret(f, cf)
	deco("TurretBase", V3(0.6, 3, 3), cf * CF(0, 0.3, 0) * ANG(0, 0, rad(90)), FRAME, M.Metal, f, { Shape = "Cylinder" })
	for k = 0, 5 do
		local a = k * math.pi / 3
		ball("BaseBolt", 0.2, cf * CF(math.cos(a) * 1.25, 0.62, math.sin(a) * 1.25), PAL.chrome, M.Metal, f)
	end
	local c0 = cf * CF(0, 1.15, 0)
	local head, weld = addPivot("TurretHead", V3(1.9, 1.0, 1.9), c0, rgb(70, 76, 60), M.Metal, f)
	addChild("TurretBarrel", V3(0.3, 0.3, 2.6), head, CF(0, 0.08, -2.1), FRAME, M.Metal, f)
	addChild("TurretCooler", V3(0.5, 0.5, 1.2), head, CF(0, 0.08, -1.3), rgb(50, 52, 46), M.Metal, f)
	addChild("TurretMuzzle", V3(0.42, 0.42, 0.3), head, CF(0, 0.08, -3.35), rgb(30, 30, 30), M.Metal, f)
	addChild("TurretAmmo", V3(0.6, 0.62, 1.0), head, CF(1.15, -0.08, 0.2), rgb(70, 80, 50), M.Metal, f)
	addChild("TurretShield", V3(1.9, 0.7, 0.12), head, CF(0, 0.05, -1.0) * ANG(rad(-12), 0, 0), rgb(62, 66, 54), M.Metal, f)
	addChild("TurretSensor", V3(0.3, 0.25, 0.3), head, CF(-0.6, 0.38, -0.6), rgb(200, 40, 30), M.Neon, f)
	table.insert(turrets, { head = head, weld = weld, baseC0 = c0, acc = rng:NextNumber(0, 0.4) })
end

local function buildLamp(f, cf)
	deco("LampBracket", V3(0.3, 0.8, 0.3), cf * CF(0, 0.4, 0), FRAME, M.Metal, f)
	fine("LampYoke", V3(1.5, 0.14, 0.3), cf * CF(0, 0.74, 0), FRAME, M.Metal, f)
	deco("LampHousing", V3(1.3, 1.0, 1.0), cf * CF(0, 1.2, 0), FRAME, M.Metal, f)
	cyl("LampRing", "z", 0.12, 0.98, cf * CF(0, 1.2, -0.52), PAL.chrome, M.Metal, f)
	local lens = deco("LampLens", V3(0.86, 0.86, 0.12), cf * CF(0, 1.2, -0.56), rgb(255, 245, 210), M.Neon, f)
	fine("LampGrille", V3(0.08, 0.86, 0.06), cf * CF(0, 1.2, -0.64), FRAME, M.Metal, f)
	fine("LampGrille", V3(0.86, 0.08, 0.06), cf * CF(0, 1.2, -0.64), FRAME, M.Metal, f)
	cable("LampCable", (cf * CF(0.3, 0.9, 0.5)).Position, (cf * CF(0.5, 0.05, 1.3)).Position, 0.07, PAL.cable, f)
	local spot = Instance.new("SpotLight")
	spot.Face = Enum.NormalId.Front
	spot.Range = 60
	spot.Angle = 45
	spot.Brightness = 5
	spot.Shadows = false
	spot.Enabled = headlights[1] ~= nil and headlights[1].Enabled or false
	spot.Parent = lens
	table.insert(headlights, spot)
end

local function buildAlarm(f, entry)
	local boxCF = CABIN[entry.index].box
	deco("AlarmBox", V3(0.6, 1, 0.8), boxCF, rgb(170, 34, 30), M.Metal, f)
	deco("AlarmLamp", V3(0.3, 0.25, 0.3), boxCF * CF(0, 0.62, 0), rgb(255, 60, 40), M.Neon, f)
	fine("AlarmGrille", V3(0.06, 0.5, 0.5), boxCF * CF(boxCF.X > 0 and -0.32 or 0.32, -0.12, 0), rgb(40, 40, 40), M.Metal, f)
	cable("AlarmWire", (boxCF * CF(0, 0.5, 0.3)).Position, V3(boxCF.X, ROOF_BOTTOM - 0.1, boxCF.Z + 0.3), 0.06, PAL.cable, f)
	if not sirenPart or not sirenPart.Parent then
		deco("SirenBase", V3(0.8, 0.3, 0.8), CF(1.5, ROOF_TOP + 0.15, CAB_Z + 3), FRAME, M.Metal, f)
		sirenPart = deco("Siren", V3(0.8, 0.8, 0.8), CF(1.5, ROOF_TOP + 0.7, CAB_Z + 3), rgb(220, 40, 30), M.Neon, f, { Shape = "Ball" })
	end
end

local function buildPartVisual(entry, partId)
	local folder = Bus.Model:FindFirstChild("Parts") or Bus.Model
	local f = Instance.new("Model")
	f.Name = "Part_" .. entry.slot .. entry.index
	f.Parent = folder
	entry.model = f
	local cf = entry.cf
	if partId == "bus_wheel" then
		buildWheel(f, cf)
	elseif partId == "plate_wood" or partId == "plate_metal" then
		buildWall(f, entry, partId == "plate_metal")
	elseif partId == "grill_spike" or partId == "grill_saw" then
		buildGrill(f, cf, partId == "grill_saw")
	elseif partId == "turret_auto" then
		buildTurret(f, cf)
	elseif partId == "bus_lamp" then
		buildLamp(f, cf)
	elseif partId == "bunk" then
		local c = CABIN[entry.index]
		addBed(f, c.bed, c.upper, c.stand)
	elseif partId == "alarm_box" then
		buildAlarm(f, entry)
	end
	return f
end

local function recomputeStats()
	local armor, crash, ramMult, selfMult, saw = 0, 1, 1, 1, 0
	local nTurrets, nLamps, nBunks, nAlarms, ram, wheels = 0, 0, 0, 0, 0, 0
	for slotType, list in pairs(slots) do
		for _, e in ipairs(list) do
			local p = e.partId and BusParts.Get(e.partId)
			if p then
				if slotType == "wheel" then
					wheels = wheels + 1
				end
				armor = armor + (p.armor or 0)
				crash = crash * (p.crashMult or 1)
				ramMult = math.max(ramMult, p.ramMult or 1)
				selfMult = math.min(selfMult, p.selfDamageMult or 1)
				saw = math.max(saw, p.sawDps or 0)
				if p.id == "turret_auto" then
					nTurrets = nTurrets + 1
				elseif p.id == "bus_lamp" then
					nLamps = nLamps + 1
				elseif p.id == "bunk" then
					nBunks = nBunks + 1
				elseif p.id == "alarm_box" then
					nAlarms = nAlarms + 1
				elseif p.id == "grill_saw" then
					ram = 3
				elseif p.id == "grill_spike" then
					ram = math.max(ram, 1)
				end
			end
		end
	end
	stats.armor, stats.crashMult, stats.ramMult, stats.selfDamageMult, stats.sawDps = armor, crash, ramMult, selfMult, saw
	stats.turrets, stats.lamps, stats.bunks, stats.alarms, stats.ram = nTurrets, nLamps, nBunks, nAlarms, ram
	local oldMax = Bus.MaxHP
	Bus.MaxHP = Config.Bus.MaxHP + armor
	if Bus.MaxHP > oldMax then
		Bus.HP = Bus.HP + (Bus.MaxHP - oldMax)
		if Bus.HP > 0 then
			Bus.BrokenNotified = false
		end
	end
	Bus.HP = math.min(Bus.HP, Bus.MaxHP)
	Bus.Wheels = wheels
	updateReady()
end

-- Прикрепление ------------------------------------------------------------------------------------------

-- Кто несёт объект (nil — лежит на земле); модуль GRAB может быть ещё заглушкой
local function carrierOf(inst)
	local grab = S.Grab
	if not grab or not grab.GetCarrier then
		return nil
	end
	local ok, carrier = pcall(grab.GetCarrier, inst)
	if ok and typeof(carrier) == "Instance" and carrier:IsA("Player") then
		return carrier
	end
	return nil
end

-- Переносимые объекты нужного вида: { inst, pos, amount, carrier }
local function grabbablesOf(kind)
	local out = {}
	for _, inst in ipairs(CollectionService:GetTagged(GRAB_TAG)) do
		if inst.Parent and (inst:IsA("Model") or inst:IsA("BasePart")) and inst:GetAttribute("GrabKind") == kind then
			local ok, pivot = pcall(inst.GetPivot, inst)
			if ok then
				table.insert(out, { inst = inst, pos = pivot.Position, amount = 1, carrier = carrierOf(inst) })
			end
		end
	end
	return out
end

-- Поставить деталь в слот: визуал, звук, статистика, сообщение всем
local function finishInstall(player, entry, partId)
	entry.partId = partId
	if entry.prompt then
		entry.prompt:Destroy()
		entry.prompt = nil
	end
	if entry.marker then
		setWaypoint(entry.marker, "", false)
		entry.marker:SetAttribute("Free", false)
	end
	local ok, model = pcall(buildPartVisual, entry, partId)
	if not ok then
		warn("[Автобус] не удалось построить деталь " .. tostring(partId) .. ": " .. tostring(model))
	end
	recomputeStats()
	Bus.PublishState()
	attachFx(entry.marker, partId)
	local item = Items.List[partId]
	local msg
	if entry.slot == "wheel" then
		msg = string.format("%s прикрепил(а) колесо (%d/4)", player.DisplayName, Bus.Wheels)
	else
		msg = string.format("%s прикрепил(а) к автобусу: %s", player.DisplayName, item and item.name or partId)
	end
	PD.NotifyAll(msg, GREEN)
	return true, msg
end

-- Деталь из инвентаря (fromHands — снимается сначала из активного слота)
local function installFromInventory(player, entry, partId, fromHands)
	local removed
	if fromHands then
		removed = PD.RemoveItem(player, partId, 1, true)
	else
		removed = PD.RemoveItem(player, partId, 1)
	end
	if not removed then
		local item = Items.List[partId]
		return false, "Нет детали: " .. (item and item.name or partId)
	end
	return finishInstall(player, entry, partId)
end

-- Деталь-объект (в руках у игрока или лежит рядом): объект расходуется
local function installFromObject(player, entry, inst, partId)
	local grab = S.Grab
	if grab and grab.ForceRelease then
		pcall(grab.ForceRelease, inst)
	end
	inst:Destroy()
	return finishInstall(player, entry, partId)
end

-- Прикрепить деталь к слоту (preferId — конкретный предмет, иначе лучший подходящий из инвентаря, а если
-- в инвентаре пусто — переносимый объект в руках или рядом). Возвращает ok, message (уже показано игроку)
function Bus.AttachToSlot(player, slotType, index, preferId, fromHands)
	if not Bus.Root or typeof(player) ~= "Instance" or not player:IsA("Player") then
		return false, nil
	end
	local list = type(slotType) == "string" and slots[slotType]
	local entry = list and type(index) == "number" and list[index]
	if not entry or entry.partId or not PD.IsActive(player) then
		return false, nil
	end
	local now = os.clock()
	if now - (attachThrottle[player] or 0) < 0.4 then
		return false, nil
	end
	attachThrottle[player] = now
	local root = rootOf(player)
	local world = Bus.Root.CFrame * entry.cf
	if not root or (root.Position - world.Position).Magnitude > 16 then
		local msg = "Подойдите ближе к автобусу"
		PD.Notify(player, msg, ORANGE)
		return false, msg
	end
	local def = BusParts.Slots[slotType]
	local chosen = nil
	if type(preferId) == "string" and table.find(def.accepts, preferId) and PD.Count(player, preferId) > 0 then
		chosen = preferId
	else
		fromHands = false
		for i = #def.accepts, 1, -1 do
			local id = def.accepts[i]
			if PD.Count(player, id) > 0 then
				chosen = id
				break
			end
		end
	end
	if chosen then
		local ok, msg = installFromInventory(player, entry, chosen, fromHands == true)
		if not ok and msg then
			PD.Notify(player, msg, ORANGE)
		end
		return ok, msg
	end
	-- колёса и стены носят в руках как предметы мира: берём тот, что игрок несёт или который лежит рядом
	local best, bestDist = nil, math.huge
	for _, id in ipairs(def.accepts) do
		for _, g in ipairs(grabbablesOf(id)) do
			if g.carrier == nil or g.carrier == player then
				local dist = g.carrier == player and 0 or (g.pos - root.Position).Magnitude
				if dist < bestDist then
					best, bestDist = g, dist
				end
			end
		end
	end
	if best and bestDist <= 12 then
		return installFromObject(player, entry, best.inst, best.inst:GetAttribute("GrabKind"))
	end
	local msg
	if slotType == "wheel" then
		msg = "Нужно колесо: колёса лежат в депо — возьмите колесо и поднесите к ступице"
	else
		local names = {}
		for _, id in ipairs(def.accepts) do
			table.insert(names, Items.List[id] and Items.List[id].name or id)
		end
		msg = "Нужна деталь: " .. table.concat(names, " или ")
	end
	PD.Notify(player, msg, ORANGE)
	return false, msg
end

-- Деталь из руки: прикрепить к ближайшему свободному подходящему слоту (не дальше 12 studs).
-- Возвращает ok, message; игрок уже получил уведомление
function Bus.AttachItem(player, itemId)
	local part = type(itemId) == "string" and BusParts.Get(itemId)
	if not part then
		return false, "Это не деталь автобуса"
	end
	if not Bus.Root or typeof(player) ~= "Instance" or not player:IsA("Player") or not PD.IsActive(player) then
		return false, nil
	end
	local root = rootOf(player)
	if not root then
		return false, nil
	end
	if PD.Count(player, itemId) <= 0 then
		local msg = "Нет детали: " .. (Items.List[itemId] and Items.List[itemId].name or itemId)
		PD.Notify(player, msg, ORANGE)
		return false, msg
	end
	local best, bestDist, anyFree = nil, 12, false
	for _, slotType in ipairs(BusParts.SlotsFor(itemId)) do
		for _, e in ipairs(slots[slotType] or {}) do
			if not e.partId then
				anyFree = true
				local dist = (root.Position - (Bus.Root.CFrame * e.cf).Position).Magnitude
				if dist <= bestDist then
					best, bestDist = e, dist
				end
			end
		end
	end
	if not best then
		local def = BusParts.Slots[part.slot]
		local msg = anyFree and ("Подойдите к свободному месту на автобусе: " .. def.name) or ("На автобусе нет свободного места: " .. def.name)
		PD.Notify(player, msg, ORANGE)
		return false, msg
	end
	return Bus.AttachToSlot(player, best.slot, best.index, itemId, true)
end

-- Переносимый объект (колесо, стена) в руках у игрока: прикрепить к ближайшему подходящему слоту.
-- Вызывает GrabService по действию «Прикрепить». Объект расходуется. Возвращает ok, message;
-- сообщение об ошибке показывает GrabService, сами игрока не уведомляем
function Bus.TryAttachGrabbed(player, inst)
	if not Bus.Root or typeof(player) ~= "Instance" or not player:IsA("Player") or not PD.IsActive(player) then
		return false, nil
	end
	if typeof(inst) ~= "Instance" or not inst.Parent or not (inst:IsA("Model") or inst:IsA("BasePart")) then
		return false, nil
	end
	local kind = inst:GetAttribute("GrabKind") or inst:GetAttribute("ItemId")
	local part = type(kind) == "string" and BusParts.Get(kind)
	if not part then
		return false, "Это не деталь автобуса"
	end
	local carrier = carrierOf(inst)
	if carrier ~= nil and carrier ~= player then
		return false, nil
	end
	local now = os.clock()
	if now - (attachThrottle[player] or 0) < 0.4 then
		return false, nil
	end
	attachThrottle[player] = now
	local okPivot, pivot = pcall(inst.GetPivot, inst)
	if not okPivot then
		return false, nil
	end
	local pos = pivot.Position
	local best, bestDist, anyFree = nil, GRAB_RANGE, false
	for _, slotType in ipairs(BusParts.SlotsFor(kind)) do
		for _, e in ipairs(slots[slotType] or {}) do
			if not e.partId then
				anyFree = true
				local dist = (pos - (Bus.Root.CFrame * e.cf).Position).Magnitude
				if dist <= bestDist then
					best, bestDist = e, dist
				end
			end
		end
	end
	if not best then
		local def = BusParts.Slots[part.slot]
		return false, anyFree and ("Поднесите ближе к свободному месту: " .. def.name) or ("На автобусе нет свободного места: " .. def.name)
	end
	return installFromObject(player, best, inst, kind)
end

-- Депо: колёса, уголь, обучение --------------------------------------------------------------------

local function groundY(x, z)
	local exclude = {}
	for _, name in ipairs({ "Loot", "Zombies", "Effects", "Placeables" }) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(exclude, f)
		end
	end
	if Bus.Model then
		table.insert(exclude, Bus.Model)
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character then
			table.insert(exclude, plr.Character)
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	local hit = workspace:Raycast(V3(x, 40, z), V3(0, -80, 0), params)
	return hit and hit.Position.Y or 0
end

-- Запасная точка сбоку от автобуса (со стороны двери)
local function besidePoint(zLocal)
	local world = Bus.Root.CFrame * CF(HW + 5, 0, zLocal)
	local pos = world.Position
	return CF(pos.X, groundY(pos.X, pos.Z), pos.Z) * ANG(0, rng:NextNumber(0, math.pi * 2), 0)
end

local function depotPoints(fnName, count, zStart)
	local list = {}
	local props = S.Props
	local fn = props and props[fnName]
	if type(fn) == "function" then
		local ok, res = pcall(fn)
		if ok and type(res) == "table" then
			for _, cf in ipairs(res) do
				if typeof(cf) == "CFrame" and #list < count then
					table.insert(list, cf)
				end
			end
		end
	end
	local i = 0
	while #list < count do
		table.insert(list, besidePoint(zStart + i * 5.5))
		i = i + 1
	end
	return list
end

local function spawnDepotItems()
	for _, cf in ipairs(depotPoints("DepotWheelSpawns", 4, -12)) do
		S.Loot.SpawnItem("bus_wheel", 1, cf, nil)
	end
	for _, cf in ipairs(depotPoints("DepotFuelSpawns", 2, 10)) do
		S.Loot.SpawnItem("coal", 3, cf, nil)
	end
end

-- Лежащие предметы: переносимые объекты (никто не несёт) и обычная добыча на земле
local function looseItems(itemId)
	local out, seen = {}, {}
	for _, g in ipairs(grabbablesOf(itemId)) do
		seen[g.inst] = true
		if not g.carrier then
			table.insert(out, g)
		end
	end
	local folder = workspace:FindFirstChild("Loot")
	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			if not seen[m] and m:GetAttribute("ItemId") == itemId and not m:GetAttribute("Taken") then
				local pp = m:IsA("Model") and m.PrimaryPart
				if pp then
					table.insert(out, { pos = pp.Position, amount = m:GetAttribute("Amount") or 1 })
				end
			end
		end
	end
	return out
end

local function nearestPos(list, from)
	local best, bestDist = nil, math.huge
	for _, e in ipairs(list) do
		local dist = from and (e.pos - from).Magnitude or 0
		if dist < bestDist then
			best, bestDist = e.pos, dist
		end
	end
	return best
end

-- Колёса потерялись (игрок вышел с колесом): вернуть недостающие к автобусу
local function checkWheelShortfall()
	if Bus.Wheels >= 4 then
		return
	end
	local available = #grabbablesOf("bus_wheel")
	local folder = workspace:FindFirstChild("Loot")
	if folder then
		for _, m in ipairs(folder:GetChildren()) do
			if m:GetAttribute("ItemId") == "bus_wheel" and not m:GetAttribute("Taken") and not CollectionService:HasTag(m, GRAB_TAG) then
				available = available + (m:GetAttribute("Amount") or 1)
			end
		end
	end
	for _, plr in ipairs(Players:GetPlayers()) do
		if PD.Get(plr) then
			available = available + PD.Count(plr, "bus_wheel")
		end
	end
	for i = 1, 4 - Bus.Wheels - available do
		S.Loot.SpawnItem("bus_wheel", 1, besidePoint(-12 + (i - 1) * 5.5), nil)
	end
end

local function setGuide(player, title, text, target)
	local c = guideCache[player]
	if c and c.title == title and c.text == text then
		local same = (c.target == nil and target == nil) or (c.target ~= nil and target ~= nil and (c.target - target).Magnitude < 1)
		if same then
			return
		end
	end
	guideCache[player] = { title = title, text = text, target = target }
	player:SetAttribute("GuideTitle", title)
	player:SetAttribute("GuideText", text)
	player:SetAttribute("GuideTarget", target)
end

local function clearGuides()
	for player in pairs(guideCache) do
		if player.Parent then
			player:SetAttribute("GuideTitle", nil)
			player:SetAttribute("GuideText", nil)
			player:SetAttribute("GuideTarget", nil)
		end
	end
	guideCache = {}
end

local function hasFuel(player)
	for _, id in ipairs(FUEL_ORDER) do
		if PD.Count(player, id) > 0 then
			return true
		end
	end
	return false
end

-- Кто что несёт: [player] = вид переносимого объекта
local function carriedKinds()
	local map = {}
	for _, inst in ipairs(CollectionService:GetTagged(GRAB_TAG)) do
		local kind = inst:GetAttribute("GrabKind")
		if inst.Parent and type(kind) == "string" then
			local carrier = carrierOf(inst)
			if carrier then
				map[carrier] = kind
			end
		end
	end
	return map
end

local function updateGuides()
	if not inDepot() then
		if guideActive then
			guideActive = false
			clearGuides()
		end
		return
	end
	guideActive = true
	local wheelsLying = looseItems("bus_wheel")
	local coalLying = looseItems("coal")
	local carried = carriedKinds()
	for _, plr in ipairs(Players:GetPlayers()) do
		if PD.Get(plr) then
			local root = rootOf(plr)
			local from = root and root.Position
			local text, target
			if Bus.Wheels < 4 then
				text = string.format("Прикрепите все четыре колеса к автобусу (%d/4)", Bus.Wheels)
				if carried[plr] == "bus_wheel" or PD.Count(plr, "bus_wheel") > 0 then
					local free = {}
					for _, e in ipairs(slots.wheel or {}) do
						if not e.partId then
							table.insert(free, { pos = (Bus.Root.CFrame * e.cf).Position })
						end
					end
					target = nearestPos(free, from)
				else
					target = nearestPos(wheelsLying, from)
					if not target then
						text = text .. ". Колёса продаются в магазине и делаются на верстаке"
					end
				end
			elseif Bus.Fuel <= 0 then
				text = "Закиньте топливо в печь автобуса"
				if hasFuel(plr) or #coalLying == 0 then
					target = furnace and furnace.body.Position or nil
				else
					text = "Подберите уголь у депо и закиньте его в печь автобуса"
					target = nearestPos(coalLying, from)
				end
			elseif Bus.Driver == plr then
				text = "W — газ, S — тормоз. Вперёд, к конечной!"
			elseif Bus.Driver then
				text = "Автобус отправляется — займите место в салоне"
			else
				text = "Сядьте за руль и поезжайте"
				target = driverSeat and driverSeat.Position or nil
			end
			setGuide(plr, "Обучение", text, target)
		end
	end
end

local function refreshWaypoints()
	if furnace then
		setWaypoint(furnace.body, "ТОПЛИВО", Bus.Fuel < Bus.FuelMax * 0.25, nil, 80)
	end
	setWaypoint(driverSeat, "ЗА РУЛЬ", Bus.Ready and Bus.Driver == nil, nil, 90)
	setWaypoint(repairBox, "РЕМОНТ", Bus.HP < Bus.MaxHP * 0.6, nil, 80)
end

-- Публичное API -------------------------------------------------------------------------------------

function Bus.Init(services)
	S = services
	PD = S.PlayerData
	Net.Get("DriveInput").OnServerEvent:Connect(function(player, throttle)
		if player ~= Bus.Driver or type(throttle) ~= "number" or throttle ~= throttle then
			return
		end
		Bus.Throttle = math.clamp(throttle, -1, 1)
	end)
	Players.PlayerRemoving:Connect(function(player)
		guideCache[player] = nil
		attachThrottle[player] = nil
	end)
end

function Bus.GetLevel(id)
	if id == "lights" then
		return stats.lamps
	elseif id == "alarm" then
		return stats.alarms > 0 and 1 or 0
	elseif id == "bunks" then
		return stats.bunks
	elseif id == "ram" then
		return stats.ram
	elseif id == "autoturret" then
		return stats.turrets
	end
	return 0
end

function Bus.HasUpgrade(id)
	return Bus.GetLevel(id) > 0
end

function Bus.ApplyUpgrade()
	return false, "Улучшения автобуса заменены деталями: изготовьте деталь и прикрепите её к автобусу"
end

local function computeSamples()
	samples = {}
	local hl, hw = HL + 0.9, HW + 0.4
	for i = 0, 3 do
		local x = -hw + 0.3 + (2 * hw - 0.6) * i / 3
		table.insert(samples, { x, -hl, "front" })
		table.insert(samples, { x, hl, "rear" })
	end
	for i = 1, 10 do
		local z = -hl + 2 * hl * i / 11
		table.insert(samples, { -hw, z, "side" })
		table.insert(samples, { hw, z, "side" })
	end
end

-- Выхлоп и пыль из-под задних колёс: эмиттеры создаются один раз, включает их клиент по скорости
function Kit.effects()
	Kit.fxEmitter("exhaust", CF(4.8, -1.55, HL + 1.2) * ANG(math.pi / 2, 0, 0), rgb(70, 68, 66), 0.6, 3.2, 1.8, 5)
	for _, x in ipairs({ -(HW + 0.4), HW + 0.4 }) do
		Kit.fxEmitter("dust", CF(x, WHEEL_Y - WHEEL_R + 0.3, REAR_WHEEL_Z + 2.4) * ANG(rad(60), 0, 0), rgb(120, 108, 92), 1.0, 5.5, 1.6, 4)
	end
end

function Bus.Build(s0)
	Bus.Destroy()
	if not S.World.Road then
		return
	end
	startS = tonumber(s0) or 70
	Bus.S = startS
	Bus.D = 0
	Bus.V = 0
	Bus.Psi = 0
	Bus.MaxHP = Config.Bus.MaxHP
	Bus.HP = Config.Bus.MaxHP
	Bus.FuelMax = Config.Bus.FuelMax
	Bus.Fuel = 0
	Bus.Wheels = 0
	Bus.Ready = false
	Bus.Throttle = 0
	Bus.Steer = 0
	Bus.Driver = nil
	Bus.BrokenNotified = false
	Bus.Lift = { 0, 0, 0, 0 }
	wasReady = false
	pendingDamage = 0
	lastZoneSlow = 1
	turrets = {}
	headlights = {}
	Kit.bulbs = {}
	Kit.lit = nil
	sirenPart = nil
	drng = Random.new(404)
	stats = { armor = 0, crashMult = 1, ramMult = 1, selfDamageMult = 1, sawDps = 0, turrets = 0, lamps = 0, bunks = 0, alarms = 0, ram = 0 }
	computeSamples()

	local pos, _, _, heading = S.World.Road:Frame(startS)
	Bus.Position = V3(pos.X, 0, pos.Z)
	Bus.Heading = heading
	-- без колёс автобус лежит на ступицах
	local startCF = CF(pos.X, Config.Bus.RideHeight - LOW_DROP, pos.Z) * yawCF(heading)

	local model = Instance.new("Model")
	model.Name = "Bus"
	Bus.Model = model
	buildBody(startCF)
	buildInterior()
	buildSlots()
	Kit.effects()

	local att = Instance.new("Attachment")
	att.Name = "DriveAttachment"
	att.Parent = Bus.Root
	alignPos = Instance.new("AlignPosition")
	alignPos.Mode = Enum.PositionAlignmentMode.OneAttachment
	alignPos.Attachment0 = att
	alignPos.RigidityEnabled = true
	alignPos.Position = startCF.Position
	alignPos.Parent = Bus.Root
	alignOri = Instance.new("AlignOrientation")
	alignOri.Mode = Enum.OrientationAlignmentMode.OneAttachment
	alignOri.Attachment0 = att
	alignOri.RigidityEnabled = true
	alignOri.CFrame = startCF
	alignOri.Parent = Bus.Root

	model.Parent = workspace
	claimOwnership()
	local st = Net.State()
	st:SetAttribute("DriverName", "")
	st:SetAttribute("BusType", Bus.Type)
	st:SetAttribute("OffRoad", false)
	st:SetAttribute("Deviation", 0)
	st:SetAttribute("SteerAngle", 0)
	st:SetAttribute("BusDistToRoad", 0)
	st:SetAttribute("BusDir", 1)
	recomputeStats()
	refreshFurnace(true)
	refreshWaypoints()
	local ok, err = pcall(spawnDepotItems)
	if not ok then
		PD.NotifyAll("Не удалось разложить колёса в депо: " .. tostring(err), RED)
	end
	Bus.PublishState()
end

function Bus.Destroy()
	Bus.Driver = nil
	if Bus.Model then
		Bus.Model:Destroy()
	end
	Bus.Model = nil
	Bus.Root = nil
	alignPos, alignOri = nil, nil
	furnace, driverSeat, repairBox, sirenPart = nil, nil, nil, nil
	headlights = {}
	Kit.bulbs = {}
	Kit.lit = nil
	turrets = {}
	slots = {}
	Bus.V = 0
	Bus.S = 0
	Bus.D = 0
	Bus.Throttle = 0
	Bus.Steer = 0
	Bus.Wheels = 0
	Bus.Ready = false
	Bus.Lift = { 0, 0, 0, 0 }
	wasReady = false
	guideActive = false
	clearGuides()
end

local function localPoint(position)
	return Bus.Root.CFrame:PointToObjectSpace(position)
end

function Bus.IsInside(position)
	if not Bus.Root or typeof(position) ~= "Vector3" then
		return false
	end
	local lp = localPoint(position)
	return math.abs(lp.X) < HW + 0.8 and math.abs(lp.Z) < HL + 1 and lp.Y > -2 and lp.Y < ROOF_TOP + 6
end

function Bus.IsNear(player, r)
	local root = rootOf(player)
	if not root or not Bus.Root then
		return false
	end
	r = tonumber(r) or 0
	local lp = localPoint(root.Position)
	return math.abs(lp.X) < HW + 0.5 + r and math.abs(lp.Z) < HL + r and math.abs(lp.Y) < 20
end

function Bus.IsNearTank(player)
	local root = rootOf(player)
	return root ~= nil and furnace ~= nil and furnace.body.Parent ~= nil and (root.Position - furnace.body.Position).Magnitude < 14
end

function Bus.InHeadlights(position)
	if not Bus.Root or not headlights[1] or not headlights[1].Enabled or typeof(position) ~= "Vector3" then
		return false
	end
	local lp = localPoint(position)
	local ahead = -lp.Z - HL
	return ahead > 0 and ahead < 62 and math.abs(lp.X) < HW + ahead * 0.6 and math.abs(lp.Y) < 25
end

function Bus.GetSpawnCFrame(index)
	if not Bus.Root then
		return nil
	end
	local i = (tonumber(index) or 0) % 7
	return Bus.Root.CFrame * CF(0.3, 3.6, -HL + 12 + i * 3)
end

function Bus.Damage(amount, info)
	if not Bus.Root or type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return
	end
	if S.Run.State == "Victory" then
		return
	end
	Bus.HP = math.max(0, Bus.HP - amount)
	pendingDamage = pendingDamage + amount
	local now = os.clock()
	if amount >= 3 and now - lastHitSound > 0.35 and (not info or info.kind ~= "crash") then
		lastHitSound = now
		playSound(Bus.Root, "hit_bus")
	end
	if Bus.HP <= 0 and not Bus.BrokenNotified then
		Bus.BrokenNotified = true
		PD.NotifyAll("Автобус сломан! Едет еле-еле — почините его у ящика с инструментами", RED)
		Net.Get("Toast"):FireAllClients("АВТОБУС СЛОМАН", "Нужны металлолом, изолента или доски", RED)
	end
end

function Bus.Repair(amount)
	if type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return
	end
	Bus.HP = math.min(Bus.MaxHP, Bus.HP + amount)
	if Bus.HP > 0 then
		Bus.BrokenNotified = false
	end
	if Bus.Root then
		S.Combat.SendNumber(Bus.Root.Position + V3(0, ROOF_TOP + 3, 0), amount, "busheal", nil)
	end
end

function Bus.RepairWith(player)
	if not PD.IsActive(player) or not Bus.Root then
		return
	end
	if not Bus.IsNear(player, 25) then
		PD.Notify(player, "Подойдите к автобусу, чтобы чинить", ORANGE)
		return
	end
	if Bus.HP >= Bus.MaxHP then
		PD.Notify(player, "Автобус в порядке", GREY)
		return
	end
	local d = PD.Get(player)
	local mult = Classes.Perk(d and d.ClassId or "survivor", "repairMult", 1)
	local amount
	if PD.Count(player, "scrap") > 0 and PD.Count(player, "tape") > 0 then
		PD.RemoveItem(player, "scrap", 1)
		PD.RemoveItem(player, "tape", 1)
		amount = 170
	elseif PD.Count(player, "scrap") > 0 then
		PD.RemoveItem(player, "scrap", 1)
		amount = 75
	elseif PD.Count(player, "tape") > 0 then
		PD.RemoveItem(player, "tape", 1)
		amount = 60
	elseif PD.Count(player, "planks") > 0 then
		PD.RemoveItem(player, "planks", 1)
		amount = 45
	else
		PD.Notify(player, "Нужны металлолом, изолента или доски", ORANGE)
		return
	end
	amount = amount * mult
	Bus.Repair(amount)
	PD.Notify(player, string.format("Автобус отремонтирован: +%d", amount), GREEN)
end

local function pickFuel(player, itemId, space)
	if itemId and Items.List[itemId] and Items.List[itemId].fuel and PD.Count(player, itemId) > 0 then
		return itemId
	end
	for _, id in ipairs(FUEL_ORDER) do
		if PD.Count(player, id) > 0 and Items.List[id].fuel <= space + 12 then
			return id
		end
	end
	return nil
end

-- Из подсказки печи — закидывает сколько влезет; из руки (itemId) — один предмет, сначала из руки.
-- Возвращает ok, message (игрок уже получил уведомление)
function Bus.RefuelWith(player, itemId)
	if not PD.IsActive(player) or not Bus.Root then
		return false, nil
	end
	if itemId ~= nil and type(itemId) ~= "string" then
		return false, nil
	end
	if not Bus.IsNearTank(player) then
		local msg = "Подойдите к печи в конце салона"
		PD.Notify(player, msg, ORANGE)
		return false, msg
	end
	if Bus.FuelMax - Bus.Fuel < 2 then
		local msg = "Печь полна"
		PD.Notify(player, msg, GREY)
		return false, msg
	end
	local added, used = 0, {}
	for _ = 1, itemId and 1 or 12 do
		local space = Bus.FuelMax - Bus.Fuel
		if space < 2 then
			break
		end
		local chosen = pickFuel(player, itemId, space)
		local removed = false
		if chosen and chosen == itemId then
			removed = PD.RemoveItem(player, chosen, 1, true)
		elseif chosen then
			removed = PD.RemoveItem(player, chosen, 1)
		end
		if not removed then
			break
		end
		local amount = Items.List[chosen].fuel
		Bus.Fuel = math.min(Bus.FuelMax, Bus.Fuel + amount)
		added = added + amount
		used[chosen] = (used[chosen] or 0) + 1
	end
	if added <= 0 then
		local msg = "Нет топлива: ищите уголь, канистры и бочки"
		PD.Notify(player, msg, RED)
		return false, msg
	end
	local list = {}
	for id, n in pairs(used) do
		table.insert(list, Items.List[id].name .. (n > 1 and (" x" .. n) or ""))
	end
	local msg = string.format("В печь: %s — +%d топлива", table.concat(list, ", "), added)
	PD.Notify(player, msg, YELLOW)
	-- Звук загрузки печи играет клиент по кадру анимации (ViewModel/CharAnimator), иначе он двоится
	updateReady()
	refreshFurnace(false)
	refreshWaypoints()
	Bus.PublishState()
	return true, msg
end

-- Столкновения ---------------------------------------------------------------------------------------

local scanRes = { count = 0, zoneSlow = 1 }
local lastBlockWarn = 0

-- Проверка позы: первое твёрдое и мягкое препятствие, число точек в твёрдых, замедление зон
local function scanPose(pos, heading, countAll)
	local fx, fz = math.sin(heading), math.cos(heading)
	local rx, rz = -fz, fx
	local cx, cz = pos.X, pos.Z
	local obs = S.Obstacles.Query(cx, cz, radius + 2)
	scanRes.hard, scanRes.hardPoint = nil, nil
	scanRes.soft, scanRes.softPoint = nil, nil
	scanRes.count = 0
	scanRes.zoneSlow = 1
	local reach = radius + 1
	for _, ob in ipairs(obs) do
		if ob.zone then
			if S.Obstacles.Hits(ob, cx, cz, 4) then
				scanRes.zoneSlow = math.min(scanRes.zoneSlow, ob.slow or 0.6)
			end
		elseif countAll or not scanRes.hard then
			local dx, dz = (ob.x or cx) - cx, (ob.z or cz) - cz
			local bound = (ob.bound or 0) + reach
			if dx * dx + dz * dz <= bound * bound then
				for _, sp in ipairs(samples) do
					local x, z = sp[1], sp[2]
					local wx = cx + rx * x - fx * z
					local wz = cz + rz * x - fz * z
					if S.Obstacles.Hits(ob, wx, wz, 0.8) then
						if ob.hard then
							scanRes.count = scanRes.count + 1
							if not scanRes.hard then
								scanRes.hard = ob
								scanRes.hardPoint = V3(wx, 0, wz)
							end
							if not countAll then
								break
							end
						else
							if not scanRes.soft then
								scanRes.soft = ob
								scanRes.softPoint = V3(wx, 0, wz)
							end
							break
						end
					end
				end
			end
		end
	end
	return scanRes.hard
end

local function smashSoft(ob, speed)
	S.Obstacles.Remove(ob)
	local model = ob.model
	if not model or not model.Parent then
		return
	end
	local look = Bus.Root.CFrame.LookVector
	local list = {}
	if model:IsA("BasePart") then
		list = { model }
	else
		for _, p in ipairs(model:GetDescendants()) do
			if p:IsA("BasePart") then
				table.insert(list, p)
			end
		end
	end
	for _, p in ipairs(list) do
		p.Anchored = false
		p.CanCollide = true
		p.CanQuery = false
		p.CollisionGroup = "Debris"
		p.AssemblyLinearVelocity = look * math.abs(speed) * 0.9 + V3(rng:NextNumber(-12, 12), rng:NextNumber(12, 28), rng:NextNumber(-12, 12))
		p.AssemblyAngularVelocity = V3(rng:NextNumber(-8, 8), rng:NextNumber(-8, 8), rng:NextNumber(-8, 8))
	end
	task.delay(4, function()
		if model.Parent then
			model:Destroy()
		end
	end)
end

local function shakeRiders(intensity)
	local remote = Net.Get("Shake")
	for _, plr in ipairs(Players:GetPlayers()) do
		local root = rootOf(plr)
		if root and Bus.IsInside(root.Position) then
			remote:FireClient(plr, intensity, 0.4)
		end
	end
end

local function onImpact(hit, hitPoint, speed, driver, driverClass)
	local now = os.clock()
	if driver and now - lastBlockWarn > 3 then
		lastBlockWarn = now
		PD.Notify(driver, hit.gateText or "Путь перекрыт — расчистите дорогу", rgb(255, 200, 120))
	end
	if speed <= 7 or now - lastCrash <= 0.5 then
		return
	end
	lastCrash = now
	if not hit.gate then
		local crashMult = (driverClass and Classes.Perk(driverClass, "crashMult", 1) or 1) * stats.crashMult
		Bus.Damage(speed * Config.Bus.CollisionDamage * crashMult * (hit.damageMult or 1), { kind = "crash" })
		if hitPoint then
			Net.FireNear("Explosion", hitPoint, 400, hitPoint + V3(0, 2, 0), 5, "crash")
		end
	end
	shakeRiders(math.clamp(speed / 35, 0.2, 1))
end

-- Таран и пилы ----------------------------------------------------------------------------------------

local function ramZombies()
	local v = Bus.V
	local sawDps = stats.sawDps
	if math.abs(v) < 5 and sawDps <= 0 then
		return
	end
	local cf = Bus.Root.CFrame
	local now = os.clock()
	local reach = 5 + math.abs(v) * 0.12 + (stats.ram > 0 and 2 or 0)
	local driver = Bus.Driver
	for _, z in ipairs(S.Zombies.List()) do
		if not z.dead and z.root and z.root.Parent then
			local lp = cf:PointToObjectSpace(z.root.Position)
			local zr = z.radius or 1.2
			if math.abs(lp.X) < HW + 1.5 + zr and lp.Y > -7 and lp.Y < 7 then
				-- только снаружи корпуса: забравшихся в салон таран не бьёт
				local front = lp.Z < -HL - 0.5 and lp.Z > -HL - reach - zr
				local rear = lp.Z > HL + 0.5 and lp.Z < HL + 5 + math.abs(v) * 0.12 + zr
				if math.abs(v) > 6 and ((v >= 0 and front) or (v < 0 and rear)) and (z.lastRam or 0) + 0.5 < now then
					z.lastRam = now
					local side = lp.X >= 0 and 0.6 or -0.6
					local dir = cf.LookVector * (v >= 0 and 1 or -1) + cf.RightVector * side
					S.Combat.DamageZombie(z, math.abs(v) * Config.Bus.RamDamage * stats.ramMult, {
						attacker = driver,
						kind = "ram",
						knockDir = dir.Unit,
						knockback = math.abs(v) * 1.7,
						stun = 1,
					})
					local def = z.def or {}
					local heavy = def.heavy or def.elite or def.boss
					Bus.Damage(Config.Bus.RamSelfDamage * stats.selfDamageMult * (heavy and 6 or 1), { kind = "ram" })
					if heavy then
						Bus.V = Bus.V * 0.55
						shakeRiders(0.6)
					end
				elseif front and sawDps > 0 and (z.lastSaw or 0) + 0.3 < now then
					z.lastSaw = now
					S.Combat.DamageZombie(z, sawDps * 0.3, { attacker = driver, kind = "ram" })
				end
			end
		end
	end
end

-- Автотурели ---------------------------------------------------------------------------------------------

local function zombieAt(part)
	local folder = workspace:FindFirstChild("Zombies")
	local model = folder and Util.ModelIn(part, folder)
	return model and S.Zombies.Active[model] or nil
end

local function updateTurrets(dt)
	if #turrets == 0 then
		return
	end
	local def = BusParts.List.turret_auto
	local interval, damage, range = def.interval or 0.45, def.damage or 14, def.range or 90
	local taken = {}
	local params, mult = nil, nil
	for _, t in ipairs(turrets) do
		t.acc = t.acc + dt
		if t.acc >= interval and t.head.Parent then
			t.acc = 0
			local origin = t.head.Position
			local cands = {}
			for _, z in ipairs(S.Zombies.List()) do
				if not z.dead and not taken[z] and z.root and z.root.Parent then
					local dist = (z.root.Position - origin).Magnitude
					if dist <= range then
						table.insert(cands, { z, dist })
					end
				end
			end
			table.sort(cands, function(a, b)
				return a[2] < b[2]
			end)
			params = params or shotParams()
			for i = 1, math.min(3, #cands) do
				local z = cands[i][1]
				local targetPos = (z.torso or z.root).Position
				local dir = targetPos - origin
				local result = workspace:Raycast(origin, dir, params)
				if not result or zombieAt(result.Instance) == z then
					taken[z] = true
					local lp = Bus.Root.CFrame:VectorToObjectSpace(dir)
					t.weld.C0 = t.baseC0 * CFrame.Angles(0, math.atan2(-lp.X, -lp.Z), 0)
					mult = mult or bestTurretMult()
					S.Combat.DamageZombie(z, damage * mult, { kind = "turret", position = targetPos })
					Net.FireNear("Tracer", origin, 400, origin, { targetPos }, "turret")
					break
				end
			end
		end
	end
end

-- Состояние и цикл ---------------------------------------------------------------------------------------

function Bus.PublishState()
	local st = Net.State()
	st:SetAttribute("BusHP", math.floor(Bus.HP + 0.5))
	st:SetAttribute("BusMaxHP", Bus.MaxHP)
	st:SetAttribute("Fuel", Util.Round(Bus.Fuel, 1))
	st:SetAttribute("FuelMax", Bus.FuelMax)
	st:SetAttribute("Speed", math.floor(math.abs(Bus.V) * Config.Bus.SpeedDisplayMult + 0.5))
	st:SetAttribute("BusDir", Bus.V < -0.05 and -1 or 1)
	st:SetAttribute("Km", Util.Round(Bus.S / Config.StudsPerKm, 2))
	st:SetAttribute("BusReady", Bus.Ready)
	st:SetAttribute("BusWheels", Bus.Wheels)
	local list = {}
	for _, id in ipairs({ "lights", "alarm", "bunks", "ram", "autoturret" }) do
		local lvl = Bus.GetLevel(id)
		if lvl > 0 then
			table.insert(list, id .. ":" .. lvl)
		end
	end
	st:SetAttribute("Upgrades", table.concat(list, ","))
end

-- Подвеска: угол без колеса лежит на ступице, поставленное колесо плавно поднимает свой угол
local function suspension(dt)
	local list = slots.wheel
	local lift = Bus.Lift
	for i = 1, 4 do
		local e = list and list[i]
		lift[i] = Util.Approach(lift[i] or 0, (e and e.partId) and 1 or 0, dt / LIFT_TIME)
	end
	local d1, d2 = (1 - lift[1]) * LOW_DROP, (1 - lift[2]) * LOW_DROP
	local d3, d4 = (1 - lift[3]) * LOW_DROP, (1 - lift[4]) * LOW_DROP
	local dropF, dropR = (d1 + d2) / 2, (d3 + d4) / 2
	local dropL, dropRight = (d1 + d3) / 2, (d2 + d4) / 2
	local wheelbase = REAR_WHEEL_Z - FRONT_WHEEL_Z
	local track = (HW + 0.4) * 2
	local pitch = math.asin(math.clamp((dropR - dropF) / wheelbase, -0.25, 0.25))
	local roll = math.asin(math.clamp((dropL - dropRight) / track, -0.35, 0.35))
	return (dropF + dropR) / 2, pitch, roll
end

function Bus.Update(dt)
	local root = Bus.Root
	if not root or not root.Parent or not S.World.Road or not alignPos then
		return
	end
	local cfg = Config.Bus
	local now = os.clock()
	local state = S.Run.State
	local driver = Bus.Driver
	local throttle = 0
	if driver and (state == "Depot" or state == "Driving" or state == "Boss") and PD.IsActive(driver) then
		throttle = Bus.Throttle
	end
	local driverClass = classOf(driver)
	local v = Bus.V

	-- без колёс или топлива — ни газа, ни заднего хода (тормозить можно)
	if not Bus.Ready and (throttle > 0 or (throttle < 0 and v <= 0.5)) then
		if driver and now - lastReadyWarn > 3 then
			lastReadyWarn = now
			if Bus.Wheels >= 4 then
				PD.Notify(driver, "Нет топлива! Закиньте уголь или бензин в печь", RED)
			else
				PD.Notify(driver, "Автобус не готов: " .. missingText(), ORANGE)
			end
		end
		throttle = 0
	end

	-- Скорость: W — газ, S — тормоз / медленный задний ход
	local maxSpeed = cfg.MaxSpeed
	if driverClass then
		maxSpeed = maxSpeed * Classes.Perk(driverClass, "busSpeed", 1)
	end
	if Bus.HP <= 0 then
		maxSpeed = maxSpeed * 0.3
	end
	maxSpeed = maxSpeed * lastZoneSlow
	local reverseMax = math.min(cfg.ReverseSpeed * 0.5, maxSpeed)
	if throttle > 0 then
		if v < 0 then
			v = math.min(0, v + cfg.Brake * dt)
		elseif v < maxSpeed then
			v = math.min(maxSpeed, v + cfg.Accel * throttle * dt * (1 - 0.5 * v / (maxSpeed + 1)))
		end
	elseif throttle < 0 then
		if v > 0 then
			v = math.max(0, v - cfg.Brake * dt)
		elseif v > -reverseMax then
			v = math.max(-reverseMax, v - cfg.Accel * 0.5 * -throttle * dt)
		end
	else
		v = Util.Approach(v, 0, cfg.Coast * dt)
	end
	if v > maxSpeed then
		v = Util.Approach(v, maxSpeed, cfg.Brake * 0.6 * dt)
	elseif v < -reverseMax then
		v = Util.Approach(v, -reverseMax, cfg.Brake * 0.6 * dt)
	end

	-- Движение только вдоль дороги
	local oldS = Bus.S
	local newS = oldS + v * dt
	local minS = math.max(HL + 4, startS - 40)
	local maxS = (tonumber(S.World.FinalS) or math.huge) + 600
	if newS < minS then
		newS = minS
		v = math.max(v, 0)
	elseif newS > maxS then
		newS = maxS
		v = math.min(v, 0)
	end
	if math.abs(newS - oldS) > 1e-5 then
		local pos, _, _, heading = S.World.Road:Frame(newS)
		local hard = scanPose(pos, heading, false)
		lastZoneSlow = scanRes.zoneSlow
		local soft, softPoint = scanRes.soft, scanRes.softPoint
		if hard then
			local hitPoint = scanRes.hardPoint
			local opos, _, _, oh = S.World.Road:Frame(oldS)
			scanPose(opos, oh, true)
			local cur = scanRes.count
			local allowed = false
			-- препятствие появилось на стоящем автобусе — разрешить выехать, если пересечение не растёт
			if cur > 0 then
				scanPose(pos, heading, true)
				allowed = scanRes.count <= cur
			end
			if not allowed then
				onImpact(hard, hitPoint, math.abs(v), driver, driverClass)
				v = (math.abs(v) > 7 and not hard.gate) and -v * 0.15 or 0
				newS = oldS
				soft = nil
			end
		end
		if soft then
			smashSoft(soft, v)
			v = v * (soft.slow or 0.88)
			if softPoint then
				Net.FireNear("Explosion", softPoint, 300, softPoint + V3(0, 2, 0), 3, "crash")
			end
		end
	end

	-- Топливо
	local traveled = math.abs(newS - oldS)
	if traveled > 0 then
		local eff = driverClass and Classes.Perk(driverClass, "fuelEff", 1) or 1
		local before = Bus.Fuel
		Bus.Fuel = math.max(0, Bus.Fuel - traveled * cfg.FuelPerKm / Config.StudsPerKm * eff)
		if before > 0 and Bus.Fuel <= 0 then
			updateReady()
			refreshFurnace(false)
			if now - lastFuelWarn > 5 then
				lastFuelWarn = now
				PD.NotifyAll("Топливо кончилось! Закиньте уголь или бензин в печь", RED)
				Net.Get("Toast"):FireAllClients("НЕТ ТОПЛИВА", "Печь погасла — ищите уголь и канистры", RED)
			end
		end
	end

	Bus.S = newS
	Bus.D = 0
	Bus.Psi = 0
	Bus.V = v
	local pos, _, _, heading = S.World.Road:Frame(newS)
	Bus.Position = V3(pos.X, 0, pos.Z)
	Bus.Heading = heading
	local drop, pitch, roll = suspension(dt)
	local speedFrac = math.clamp(math.abs(v) / cfg.MaxSpeed, 0, 1)
	local cf = CF(pos.X, cfg.RideHeight - drop + math.sin(now * 9) * 0.05 * speedFrac, pos.Z) * yawCF(heading) * ANG(pitch, 0, roll)
	alignPos.Position = cf.Position
	alignOri.CFrame = cf

	ramAcc = ramAcc + dt
	if ramAcc >= 0.1 then
		ramAcc = 0
		ramZombies()
	end
	updateTurrets(dt)

	guideAcc = guideAcc + dt
	if guideAcc >= 0.5 then
		guideAcc = 0
		updateGuides()
		refreshWaypoints()
		refreshFurnace(false)
	end

	depotAcc = depotAcc + dt
	if depotAcc >= 1 then
		depotAcc = 0
		if inDepot() then
			checkWheelShortfall()
		end
	end

	lightAcc = lightAcc + dt
	if lightAcc >= 1 then
		lightAcc = 0
		local on = S.DayNight.NightFactor() > 0.35 or Net.State():GetAttribute("Weather") == "sandstorm"
		for _, spot in ipairs(headlights) do
			if spot.Parent and spot.Enabled ~= on then
				spot.Enabled = on
			end
		end
		if Kit.lit ~= on then
			Kit.lit = on
			for _, bulb in ipairs(Kit.bulbs) do
				if bulb.Parent then
					bulb.Material = on and M.Neon or M.Glass
					bulb.Color = on and PAL.lampOn or PAL.lensOff
				end
			end
		end
	end

	ownerAcc = ownerAcc + dt
	if ownerAcc >= 2 then
		ownerAcc = 0
		claimOwnership()
	end

	stateAcc = stateAcc + dt
	if stateAcc >= 0.1 then
		stateAcc = 0
		Bus.PublishState()
		if pendingDamage >= 1 then
			S.Combat.SendNumber(root.Position + V3(rng:NextNumber(-4, 4), ROOF_TOP + 3, 0), pendingDamage, "bus", nil)
			pendingDamage = 0
		end
	end
end

return Bus
