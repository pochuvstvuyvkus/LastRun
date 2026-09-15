-- Зомби и другие враги: модели из деталей (R6), ИИ, спавн волнами и в зданиях,
-- элита со способностями, гнёзда, мародёры, босс, сложность и награды
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local ZombieDefs = require(Shared.Zombies)
local Difficulty = require(Shared.Difficulty)
local Progression = require(Shared.Progression)
local Upgrades = require(Shared.Upgrades)
local StatusEffects = require(Shared.StatusEffects)
local EventDefs = require(Shared.Events)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local ZS = {}
local S
local folder
local fxFolder
local active = {}
local list = {}
local listDirty = true
local spawners = {}
local extraTargets = {}
local clouds = {}
local rng = Random.new()
local rgb = Color3.fromRGB
local V3 = Vector3.new

local TWO_PI = math.pi * 2
local PURPLE = rgb(200, 120, 255)

ZS.Active = active

-- Стандартные суставы R6
local R6 = {
	RootJoint = { CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0), CFrame.new(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0) },
	Neck = { CFrame.new(0, 1, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0), CFrame.new(0, -0.5, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0) },
	RightShoulder = { CFrame.new(1, 0.5, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0), CFrame.new(-0.5, 0.5, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0) },
	LeftShoulder = { CFrame.new(-1, 0.5, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0), CFrame.new(0.5, 0.5, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0) },
	RightHip = { CFrame.new(1, -1, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0), CFrame.new(0.5, 1, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0) },
	LeftHip = { CFrame.new(-1, -1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0), CFrame.new(-0.5, 1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0) },
}

local HUMAN_SKINS = { rgb(234, 192, 160), rgb(204, 150, 110), rgb(150, 100, 70), rgb(110, 76, 54), rgb(240, 210, 180) }

local function scaleCF(cf, s, xStretch)
	local p = cf.Position
	return CFrame.new(p.X * s * (xStretch or 1), p.Y * s, p.Z * s) * (cf - cf.Position)
end

local function getFxFolder()
	if not fxFolder or not fxFolder.Parent then
		fxFolder = workspace:FindFirstChild("EventsFX")
		if not fxFolder then
			fxFolder = Instance.new("Folder")
			fxFolder.Name = "EventsFX"
			fxFolder.Parent = workspace
		end
	end
	return fxFolder
end

function ZS.Init(services)
	S = services
	folder = workspace:WaitForChild("Zombies")
	getFxFolder()
end

function ZS.List()
	if listDirty then
		list = {}
		for _, z in pairs(active) do
			if not z.dead then
				table.insert(list, z)
			end
		end
		listDirty = false
	end
	return list
end

-- Сложность ------------------------------------------------------------------------------

local scaleCache = nil
local scaleBase = nil
local scaleAt = -math.huge

local function refreshScale()
	local now = os.clock()
	if scaleCache and now - scaleAt < 1 then
		return
	end
	scaleAt = now
	local mode = (S.Run and S.Run.Difficulty) or Net.State():GetAttribute("Difficulty") or "normal"
	local level = 1
	if S.Profile and S.Profile.TeamLevel then
		local ok, v = pcall(S.Profile.TeamLevel)
		if ok and type(v) == "number" then
			level = v
		end
	end
	local km = (S.Bus.S or 0) / Config.StudsPerKm
	scaleCache = Difficulty.Scale(mode, level, km)
	scaleBase = Difficulty.Scale(mode, level, 0)
end

local function getScale()
	refreshScale()
	return scaleCache
end

function ZS.GetScale()
	return getScale()
end

local function bloodMoon()
	return S.Events and S.Events.IsBloodMoon and S.Events.IsBloodMoon() == true
end

-- Множитель числа зомби (желаемое число на дороге, орды станций, гнёзда)
function ZS.CountMult()
	local m = getScale().count
	if bloodMoon() then
		m = m * EventDefs.Tuning.bloodMoonCountMult
	end
	return m
end

-- Плавный рост по маршруту ----------------------------------------------------------------

local function busKm()
	return math.max(0, (S.Bus.S or 0) / Config.StudsPerKm)
end

-- Доля пройденного пути 0..1 (km — необязательно, по умолчанию километр автобуса)
function ZS.Progress(km)
	if type(km) ~= "number" or km ~= km then
		km = busKm()
	end
	return math.clamp(km / math.max(1, Config.RouteKm or 100), 0, 1)
end

-- Множитель размера орд и событий по доле пути: 0.5 у депо → ~0.6 у первой станции → 1.5 у конечной
function ZS.ProgressFactor(km)
	local p = ZS.Progress(km)
	return 0.5 + 0.6 * p + 0.4 * p * p
end

-- Готовый множитель для орд станций/событий: сложность и кровавая луна × доля пути
function ZS.HordeMult(km)
	return ZS.CountMult() * ZS.ProgressFactor(km)
end

local function lerpRange(a, b, p, fallbackLo, fallbackHi)
	local lo0 = type(a) == "table" and tonumber(a[1]) or fallbackLo
	local hi0 = type(a) == "table" and tonumber(a[2]) or fallbackHi
	local lo1 = type(b) == "table" and tonumber(b[1]) or lo0
	local hi1 = type(b) == "table" and tonumber(b[2]) or hi0
	local lo = lo0 + (lo1 - lo0) * p
	local hi = hi0 + (hi1 - hi0) * p
	lo = math.max(1, math.floor(lo + 0.5))
	hi = math.max(lo, math.floor(hi + 0.5))
	return lo, hi
end

-- Желаемое число бродячих зомби (SPEC v4 2.6) и потолок
function ZS.DesiredRoaming(km, night, biome, nPlayers)
	local cz = Config.Zombies
	km = type(km) == "number" and math.max(0, km) or busKm()
	nPlayers = math.max(1, nPlayers or #Players:GetPlayers())
	local spawnMult = (type(biome) == "table" and type(biome.spawnMult) == "number") and biome.spawnMult or 1
	local countMult = ZS.CountMult()
	local base = (cz.StartDesired or 1.5) + (cz.PerKm or 0.2) * km + (cz.PerKm2 or 0) * km * km
	local desired = base * spawnMult * countMult * (1 + 0.35 * (nPlayers - 1))
	if night then
		desired = desired * 1.5
	end
	local cap = (cz.MaxActive + cz.PerPlayerExtra * (nPlayers - 1)) * math.clamp(countMult, 1, 1.6)
	return math.min(desired, cap), cap
end

-- Размер группы бродячих по доле пути: GroupStart → GroupLate
function ZS.GroupRange(km)
	return lerpRange(Config.Zombies.GroupStart, Config.Zombies.GroupLate, ZS.Progress(km), 1, 2)
end

-- Зомби в зданиях по доле пути: POICountStart → POICountLate
function ZS.POIRange(km)
	return lerpRange(Config.Zombies.POICountStart, Config.Zombies.POICountLate, ZS.Progress(km), 1, 2)
end

-- Безопасные точки спавна ----------------------------------------------------------------

-- Точка внутри автобуса или вплотную к нему (ревизия №9)
local function busBlocks(x, z, pad)
	local busRoot = S.Bus.Root
	if not busRoot or not busRoot.Parent then
		return false
	end
	pad = pad or 3
	local y = busRoot.Position.Y
	local lp = busRoot.CFrame:PointToObjectSpace(V3(x, y, z))
	local td = S.Bus.TypeDef
	local halfW = ((td and td.width) or 12) / 2 + pad
	local halfL = ((td and td.length) or 44) / 2 + pad
	if math.abs(lp.X) < halfW and math.abs(lp.Z) < halfL then
		return true
	end
	return S.Bus.IsInside(V3(x, y + 2, z))
end

local function isSpotFree(x, z, pad)
	if S.Obstacles.IsBlocked(x, z, pad or 2.5) then
		return false
	end
	if busBlocks(x, z, 3) then
		return false
	end
	-- не за граничными стенами (страховка WorldGen всё равно удалила бы такого зомби)
	local world = S.World
	if world and world.Road and world.IsInsideBounds then
		local ok, inside = pcall(world.IsInsideBounds, V3(x, 0, z), S.Bus.S)
		if ok and inside == false then
			return false
		end
	end
	return true
end

function ZS.IsSpotFree(position, pad)
	if typeof(position) ~= "Vector3" then
		return false
	end
	return isSpotFree(position.X, position.Z, pad)
end

-- Случайная свободная точка в кольце вокруг center (y = 0) или nil
function ZS.FindSpawnPoint(center, minR, maxR, tries, pad)
	if typeof(center) ~= "Vector3" then
		return nil
	end
	minR = minR or 0
	maxR = math.max(minR, maxR or minR)
	for _ = 1, tries or 8 do
		local a = rng:NextNumber(0, TWO_PI)
		local r = rng:NextNumber(minR, maxR)
		local x = center.X + math.cos(a) * r
		local z = center.Z + math.sin(a) * r
		if isSpotFree(x, z, pad) then
			return V3(x, 0, z)
		end
	end
	return nil
end

-- Модели ---------------------------------------------------------------------------------

local function limb(model, name, size, color, collide)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = collide
	p.CollisionGroup = "Zombies"
	p.Parent = model
	return p
end

local function attach(model, basePart, size, offset, color, material, shape)
	local p = Instance.new("Part")
	p.Name = "Detail"
	p.Size = size
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.CollisionGroup = "Zombies"
	if shape then
		p.Shape = shape
	end
	p.CFrame = basePart.CFrame * offset
	p.Parent = model
	local w = Instance.new("WeldConstraint")
	w.Part0 = basePart
	w.Part1 = p
	w.Parent = p
	return p
end

-- xStretch0/xStretch1 — растяжение смещения по X для C0 (ширина торса) и C1 (толщина конечности)
local function motor(parent, name, part0, part1, pair, s, xStretch0, xStretch1)
	local m = Instance.new("Motor6D")
	m.Name = name
	m.Part0 = part0
	m.Part1 = part1
	m.C0 = scaleCF(pair[1], s, xStretch0)
	m.C1 = scaleCF(pair[2], s, xStretch1)
	m.Parent = parent
	return m
end

local function makeHumanoid(model, def, hp)
	local hum = Instance.new("Humanoid")
	hum.BreakJointsOnDeath = false -- поза смерти рисуется на клиенте (ZombieAnim)
	hum.RigType = Enum.HumanoidRigType.R6
	hum.MaxHealth = hp
	hum.Health = hp
	hum.WalkSpeed = def.speed
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	hum.RequiresNeck = false
	hum.Parent = model
	return hum
end

-- Внешность: палитры, телосложения, слои одежды ------------------------------------------

local DIRT = rgb(66, 56, 44)
local PALE = rgb(182, 184, 170)
local EYE_DAY = rgb(186, 182, 150) -- мутные глаза днём; ночью клиент (ZombieAnim) включает слабое свечение
local BONE = rgb(206, 196, 172)
local WOUNDS = { rgb(74, 16, 16), rgb(92, 24, 20), rgb(58, 20, 18), rgb(70, 34, 26) }
local SHIRTS = { rgb(120, 112, 98), rgb(86, 98, 116), rgb(104, 54, 50), rgb(78, 84, 70), rgb(158, 154, 144), rgb(64, 64, 68), rgb(118, 96, 62), rgb(70, 86, 96) }
local JACKETS = { rgb(58, 50, 42), rgb(46, 52, 62), rgb(76, 80, 62), rgb(40, 40, 42), rgb(98, 80, 58) }
local PANTS = { rgb(58, 66, 84), rgb(92, 84, 66), rgb(46, 46, 50), rgb(70, 58, 46), rgb(84, 88, 92) }
local SHOES = { rgb(30, 26, 24), rgb(58, 44, 34), rgb(96, 94, 90), rgb(40, 40, 44) }
local HAIRS = { rgb(38, 30, 24), rgb(20, 18, 18), rgb(104, 98, 90), rgb(120, 98, 64), rgb(80, 50, 34) }

local M = Enum.Material
local BALL = Enum.PartType.Ball
local CYL = Enum.PartType.Cylinder

local function rot(x, y, z)
	return CFrame.Angles(math.rad(x or 0), math.rad(y or 0), math.rad(z or 0))
end

local function shade(c, k)
	return Color3.new(math.clamp(c.R * k, 0, 1), math.clamp(c.G * k, 0, 1), math.clamp(c.B * k, 0, 1))
end

local function grime(c, a)
	return c:Lerp(DIRT, a or rng:NextNumber(0.12, 0.3))
end

local function pick(list)
	return list[rng:NextInteger(1, #list)]
end

local function chance(p)
	return rng:NextNumber() < p
end

-- Деталь внешности в осях детали base; размеры и смещения — в единицах роста (× s)
local function detailer(model, s)
	return function(base, size, x, y, z, color, material, rotation, shape)
		local cf = CFrame.new(x * s, y * s, z * s)
		if rotation then
			cf = cf * rotation
		end
		local p = attach(model, base, size * s, cf, color, material, shape)
		-- мелкие детали без теней
		p.CastShadow = size.X * size.Y * size.Z * s * s * s > 1.6
		return p
	end
end

-- Бледная кожа с оттенком биома и разложения
local function zombieSkin(biome)
	local base = (biome and biome.skin and biome.skin.skin) or rgb(140, 150, 130)
	local c = base:Lerp(PALE, rng:NextNumber(0.28, 0.45))
	if chance(0.5) then
		c = c:Lerp(rgb(128, 142, 112), rng:NextNumber(0, 0.2))
	else
		c = c:Lerp(rgb(140, 132, 150), rng:NextNumber(0, 0.18))
	end
	return shade(c, rng:NextNumber(0.9, 1.06))
end

-- Телосложение: ширина торса, толщина конечностей, рост; походка (для ZombieAnim)
local function chooseBuild(def)
	local id = def.id
	local b = { tw = 1, depth = 1, arm = 1, leg = 1, size = 1, head = 1.25, gait = "shamble", speed = 1 }
	if def.fat then
		b.tw, b.depth = 1.45, 1.8
	end
	if def.boss or def.elite or def.stationary then
		b.gait = def.boss and "boss" or "heavy"
		return b
	end
	if def.human then
		b.size = rng:NextNumber(0.96, 1.04)
		b.gait = "human"
		return b
	end
	if id == "runner" then
		b.tw, b.depth, b.arm, b.leg = 0.84, 0.85, 0.8, 0.84
		b.size = rng:NextNumber(0.94, 1.06)
		b.gait = "run"
	elseif id == "brute" then
		b.tw, b.depth, b.arm, b.leg = 1.18, 1.2, 1.22, 1.12
		b.size = rng:NextNumber(0.96, 1.05)
		b.gait = "heavy"
	elseif id == "bloater" then
		b.arm, b.leg = 1.1, 1.08
		b.size = rng:NextNumber(0.95, 1.05)
		b.gait = "waddle"
	elseif id == "crawler" then
		b.tw, b.arm, b.leg = 0.9, 0.86, 0.86
		b.size = rng:NextNumber(0.92, 1.06)
		b.gait = "crawl"
	else
		local r = rng:NextNumber()
		if r < 0.3 then
			b.tw, b.depth, b.arm, b.leg = 0.86, 0.88, 0.82, 0.86
			b.size = rng:NextNumber(0.94, 1.08)
		elseif r < 0.55 then
			b.tw, b.depth, b.arm, b.leg = 1.14, 1.12, 1.08, 1.06
			b.size = rng:NextNumber(0.92, 1.02)
		elseif r < 0.7 then
			b.tw, b.arm, b.leg = 0.95, 0.92, 0.94
			b.size = rng:NextNumber(1.05, 1.12)
		else
			b.size = rng:NextNumber(0.92, 1.06)
		end
		b.head = rng:NextNumber(1.2, 1.28)
		local g = rng:NextNumber()
		if g < 0.25 then
			b.gait, b.speed = "drag", 0.82
		elseif g < 0.45 then
			b.gait, b.speed = "limp", 0.9
		else
			b.speed = rng:NextNumber(0.92, 1.06)
		end
	end
	return b
end

-- Лицо: запавшие глазницы, глаза (свечение ночью — на клиенте), рот, иногда отвисшая челюсть
local function dressFace(D, head, skin, glow, human)
	local socket = shade(skin, 0.42)
	for _, side in ipairs({ -1, 1 }) do
		local y = 0.1 + rng:NextNumber(-0.04, 0.04)
		if not human then
			D(head, V3(0.34, 0.24, 0.05), 0.27 * side, y, -0.6, socket)
		end
		local eye = D(head, V3(0.15, 0.1, 0.05), 0.27 * side, y, -0.628, human and rgb(28, 24, 22) or EYE_DAY)
		if not human then
			eye.Name = "Eye"
			eye:SetAttribute("Glow", glow)
		end
	end
	if human then
		return
	end
	D(head, V3(0.5, 0.13, 0.05), rng:NextNumber(-0.06, 0.06), -0.3, -0.632, rgb(40, 16, 16))
	if chance(0.55) then
		D(head, V3(0.42, 0.06, 0.04), 0, -0.25, -0.648, rgb(196, 184, 150))
	end
	if chance(0.3) then
		D(head, V3(0.5, 0.18, 0.4), 0, -0.52, -0.3, shade(skin, 0.85), nil, rot(22, 0, rng:NextNumber(-8, 8)))
	end
	if chance(0.35) then
		local side = chance(0.5) and -1 or 1
		D(head, V3(0.06, 0.34, 0.4), 0.62 * side, rng:NextNumber(-0.1, 0.25), rng:NextNumber(-0.2, 0.2), pick(WOUNDS))
	end
end

-- Волосы: лысина, короткие, растрёпанные, остатки по бокам, клочья
local function dressHair(D, head, hat)
	local hair = pick(HAIRS):Lerp(rgb(120, 118, 112), rng:NextNumber(0, 0.35))
	local r = rng:NextNumber()
	if r < 0.22 then
		return "bald"
	elseif r < 0.52 then
		if not hat then
			D(head, V3(0.26, 1.3, 1.3), 0, 0.52, 0.02, hair, M.Fabric, rot(0, 0, 90), CYL)
		end
		D(head, V3(1.24, 0.52, 0.14), 0, 0.18, 0.58, hair, M.Fabric)
	elseif r < 0.72 then
		if not hat then
			D(head, V3(0.32, 1.34, 1.34), 0.03, 0.5, 0.04, hair, M.Fabric, rot(0, 0, 90 + rng:NextNumber(-6, 6)), CYL)
		end
		D(head, V3(1.26, 1.0, 0.18), 0, -0.02, 0.6, hair, M.Fabric, rot(rng:NextNumber(-6, 4), 0, 0))
		D(head, V3(0.14, 0.72, 0.8), 0.64 * (chance(0.5) and -1 or 1), 0.1, 0.1, hair, M.Fabric)
	elseif r < 0.88 then
		D(head, V3(1.26, 0.42, 0.14), 0, 0.08, 0.58, hair, M.Fabric)
		D(head, V3(0.12, 0.36, 0.8), -0.64, 0.1, 0.12, hair, M.Fabric)
		D(head, V3(0.12, 0.36, 0.8), 0.64, 0.1, 0.12, hair, M.Fabric)
	elseif not hat then
		for _ = 1, 3 do
			D(head, V3(0.38, 0.18, 0.38), rng:NextNumber(-0.35, 0.35), 0.56, rng:NextNumber(-0.3, 0.35), hair, M.Fabric, rot(0, rng:NextNumber(0, 90), rng:NextNumber(-12, 12)))
		end
	end
	return "hair"
end

-- Одежда слоями, раны, обувь. Торс: x ∈ ±tw, y ∈ ±1, z ∈ ±td/2 (перёд — -Z)
local function dressBody(c)
	local D, def, b = c.D, c.def, c.build
	local torso, head, la, ra, ll, rl = c.torso, c.head, c.la, c.ra, c.ll, c.rl
	local skin, shirt, pants = c.skin, c.shirt, c.pants
	local tw, td, aw, lw = b.tw, b.depth, b.arm, b.leg
	local id = def.id
	local front, back = -td / 2, td / 2

	-- шея
	D(torso, V3(0.6, 0.34, 0.6), 0, 1.04, 0, shade(skin, 0.92))

	local bare = id == "brute"
	local tank = id == "runner"
	local jacket = not bare and not tank and not def.fat and id ~= "crawler" and chance(0.35)
	local jacketColor = grime(pick(JACKETS))
	local off = jacket and 0.11 or 0.03 -- насколько поверхность одежды впереди торса

	if jacket then
		D(torso, V3(2 * tw + 0.12, 1.96, td + 0.12), 0, -0.02, 0, jacketColor, M.Fabric)
		D(torso, V3(0.62 * tw, 1.9, 0.06), rng:NextNumber(-0.08, 0.08), -0.04, front - 0.07, shirt, M.Fabric)
		if chance(0.5) then
			D(torso, V3(0.6, 0.5, 0.05), rng:NextNumber(-0.5, 0.5), rng:NextNumber(-0.4, 0.5), back + 0.08, shirt, M.Fabric, rot(0, 0, rng:NextNumber(-30, 30)))
		end
	elseif tank then
		-- майка: голые плечи
		D(torso, V3(0.5, 0.5, td + 0.02), -(tw - 0.25), 0.74, 0, skin)
		D(torso, V3(0.5, 0.5, td + 0.02), tw - 0.25, 0.74, 0, skin)
	end

	if not bare then
		-- дыры в одежде: видна кожа
		for _ = 1, rng:NextInteger(1, 2) do
			local onFront = chance(0.65)
			local x = jacket and rng:NextNumber(-0.18, 0.18) or rng:NextNumber(-0.55, 0.55) * tw
			D(torso, V3(rng:NextNumber(0.3, 0.6), rng:NextNumber(0.26, 0.5), 0.05), x, rng:NextNumber(-0.6, 0.5), onFront and (front - off - 0.01) or (back + off + 0.01), shade(skin, 0.9), nil, rot(0, 0, rng:NextNumber(-25, 25)))
		end
		-- рваный подол
		for i = 1, 2 do
			local x = (i == 1 and -1 or 1) * rng:NextNumber(0.2, 0.7) * tw
			D(torso, V3(rng:NextNumber(0.45, 0.75), rng:NextNumber(0.28, 0.46), 0.1), x, -1.12, front - off, jacket and jacketColor or shirt, M.Fabric, rot(rng:NextNumber(-10, 5), 0, rng:NextNumber(-18, 18)))
		end
		if not jacket and not def.fat and chance(0.6) then
			D(torso, V3(2 * tw + 0.06, 0.2, td + 0.06), 0, -0.9, 0, rgb(34, 28, 24), M.Leather)
			D(torso, V3(0.24, 0.16, 0.05), rng:NextNumber(-0.1, 0.1), -0.9, front - 0.06, rgb(120, 116, 104), M.Metal)
		end
	end

	-- рукава: короткие, длинные или без рукавов
	local sleeve = 0
	if jacket then
		sleeve = 1.55
	elseif not bare and not tank then
		sleeve = pick({ 0.7, 0.7, 1.3, 1.55 })
	end
	if sleeve > 0 then
		local col = jacket and jacketColor or shirt
		for _, arm in ipairs({ la, ra }) do
			local len = sleeve * rng:NextNumber(0.85, 1.05)
			D(arm, V3(aw + 0.06, len, aw + 0.06), 0, 1 - len / 2 + 0.02, 0, col, M.Fabric)
			if chance(0.6) then
				D(arm, V3(0.35, 0.28, 0.08), rng:NextNumber(-0.15, 0.15) * aw, 1 - len - 0.08, -aw / 2 - 0.04, col, M.Fabric, rot(0, 0, rng:NextNumber(-25, 25)))
			end
		end
	end

	-- раны на торсе (пропитанная кровью ткань)
	for _ = 1, rng:NextInteger(1, 2) do
		local onFront = chance(0.6)
		D(torso, V3(rng:NextNumber(0.35, 0.8), rng:NextNumber(0.3, 0.7), 0.05), rng:NextNumber(-0.6, 0.6) * tw, rng:NextNumber(-0.7, 0.6), onFront and (front - off - 0.02) or (back + off + 0.02), pick(WOUNDS), nil, rot(0, 0, rng:NextNumber(-40, 40)))
	end
	-- рёбра наружу
	if chance(tank and 0.4 or 0.15) then
		local side = chance(0.5) and -1 or 1
		local x = side * 0.45 * tw
		D(torso, V3(0.72, 0.66, 0.05), x, 0.1, front - off - 0.03, rgb(52, 14, 14))
		for i = 0, 2 do
			D(torso, V3(0.6, 0.07, 0.05), x, 0.3 - i * 0.2, front - off - 0.06, BONE, nil, rot(0, 0, side * 8))
		end
	end

	-- штаны, порванные штанины, обувь или босые ноги
	for _, leg in ipairs({ ll, rl }) do
		if id == "crawler" or chance(tank and 0.7 or 0.25) then
			local h = rng:NextNumber(0.55, 0.9)
			D(leg, V3(lw + 0.02, h, lw + 0.02), 0, -0.58 + h / 2, 0, shade(skin, 0.94))
			D(leg, V3(lw + 0.06, 0.18, lw + 0.06), 0, -0.58 + h + 0.04, 0, pants, M.Fabric, rot(rng:NextNumber(-10, 10), 0, rng:NextNumber(-10, 10)))
		elseif chance(0.35) then
			D(leg, V3(0.46, 0.34, 0.05), rng:NextNumber(-0.1, 0.1), -0.1, -lw / 2 - 0.02, shade(skin, 0.92))
		end
		if chance(0.25) then
			D(leg, V3(0.5, 0.5, 0.05), 0, 0.4, chance(0.5) and (-lw / 2 - 0.03) or (lw / 2 + 0.03), pick(WOUNDS))
		end
		if chance(0.82) then
			D(leg, V3(lw + 0.08, 0.42, lw + 0.3), 0, -0.8, -0.12, c.shoe, M.Leather)
			if chance(0.5) then
				D(leg, V3(lw + 0.1, 0.1, lw + 0.34), 0, -0.97, -0.12, shade(c.shoe, 0.6), M.Rubber)
			end
		else
			D(leg, V3(lw + 0.02, 0.28, lw + 0.24), 0, -0.86, -0.1, shade(skin, 0.8))
		end
	end

	-- грязные/окровавленные кисти, рваные раны на руках
	for _, arm in ipairs({ la, ra }) do
		if chance(0.55) then
			D(arm, V3(aw + 0.04, 0.36, aw + 0.04), 0, -0.84, 0, shade(skin:Lerp(rgb(70, 30, 26), 0.35), 0.8))
		end
		if chance(0.35) then
			D(arm, V3(0.05, rng:NextNumber(0.3, 0.6), 0.4), (chance(0.5) and -1 or 1) * (aw / 2 + 0.02), rng:NextNumber(-0.6, 0.3), 0, pick(WOUNDS))
		end
		if tank then
			D(arm, V3(0.1, 0.28, 0.1), -0.22 * aw, -1.08, -0.2 * aw, BONE, nil, rot(-15, 0, 0))
			D(arm, V3(0.1, 0.28, 0.1), 0.22 * aw, -1.08, -0.2 * aw, BONE, nil, rot(-15, 0, 0))
		end
	end

	if id == "brute" then
		-- голый торс, комбинезон на лямках, ржавый наплечник, цепь, огромные кулаки
		D(torso, V3(2 * tw + 0.24, 0.7, td + 0.26), 0, 0.72, 0, rgb(60, 60, 64), M.CorrodedMetal)
		for _, sx in ipairs({ -1, 1 }) do
			D(torso, V3(0.3, 1.5, 0.06), sx * 0.5 * tw, -0.15, front - 0.03, pants, M.Fabric)
			D(torso, V3(0.3, 1.5, 0.06), sx * 0.5 * tw, -0.15, back + 0.03, pants, M.Fabric)
		end
		D(torso, V3(1.3 * tw, 0.9, 0.08), 0, -0.52, front - 0.05, pants, M.Fabric)
		D(torso, V3(0.08, 0.7, 0.05), 0.3, 0.05, front - 0.03, rgb(70, 30, 30), nil, rot(0, 0, 35))
		for i = 0, 3 do
			D(torso, V3(0.16, 0.3, 0.3), -0.7 * tw + i * 0.45 * tw, 0.25 - i * 0.26, front - 0.12, rgb(90, 80, 70), M.CorrodedMetal, rot(0, 90, 40))
		end
		for _, arm in ipairs({ la, ra }) do
			D(arm, V3(aw + 0.3, 0.6, aw + 0.3), 0, -0.9, 0, shade(skin, 0.85))
		end
	elseif id == "spitter" then
		-- раздутый зоб и потёки кислоты
		D(head, V3(0.9, 0.6, 0.8), 0, -0.55, -0.2, rgb(150, 170, 70), M.SmoothPlastic, nil, BALL)
		D(head, V3(0.12, 0.35, 0.12), 0.1, -0.85, -0.55, rgb(170, 200, 80), M.Glass)
		D(torso, V3(0.5, 0.6, 0.05), -0.2, 0.5, front - off - 0.03, rgb(120, 150, 50))
	elseif id == "bloater" then
		-- огромное брюхо с нарывами, натянутая рубашка
		local belly = skin:Lerp(rgb(150, 170, 90), 0.5)
		D(torso, V3(2.6, 2.4, 2.2), 0, -0.1, -0.2, belly, M.SmoothPlastic, nil, BALL)
		for _ = 1, 4 do
			local a = rng:NextNumber(-1.1, 1.1)
			local k = rng:NextNumber(0.7, 1.3)
			D(torso, V3(0.4 * k, 0.4 * k, 0.4 * k), math.sin(a) * 1.12, rng:NextNumber(-0.7, 0.5), -0.2 - math.cos(a) * 1.02, rgb(196, 190, 90), M.SmoothPlastic, nil, BALL)
		end
		D(torso, V3(2 * tw + 0.1, 0.6, td + 0.1), 0, 0.72, 0, shirt, M.Fabric)
		D(torso, V3(0.05, 0.8, 0.6), 0.85, -0.2, -1.2, rgb(110, 40, 50), nil, rot(0, 50, 20))
	elseif id == "crawler" then
		D(torso, V3(2 * tw + 0.02, 0.4, td + 0.02), 0, -0.85, 0, rgb(70, 22, 20))
	end
end

-- Аксессуары биома (бандана, кепка, шапка, каска, лианы, тина)
local function dressExtra(c, extra, wear)
	local D, head, torso, la = c.D, c.head, c.torso, c.la
	local tw, td = c.build.tw, c.build.depth
	if extra == "bandana" and wear then
		local col = pick({ rgb(150, 40, 36), rgb(60, 70, 110), rgb(120, 100, 70) })
		D(head, V3(0.36, 1.3, 1.3), 0, -0.22, 0, col, M.Fabric, rot(0, 0, 90), CYL)
		D(head, V3(0.5, 0.4, 0.1), 0, -0.52, -0.58, col, M.Fabric, rot(15, 0, 0))
	elseif extra == "cap" and wear then
		local col = pick({ rgb(40, 60, 140), rgb(130, 40, 40), rgb(50, 50, 52) })
		D(head, V3(0.36, 1.32, 1.32), 0, 0.5, 0, col, M.Fabric, rot(0, 0, 90), CYL)
		D(head, V3(1.0, 0.1, 0.62), 0, 0.38, -0.84, col, M.Fabric, rot(-8, 0, 0))
	elseif extra == "beanie" and wear then
		local col = pick({ rgb(150, 40, 40), rgb(50, 60, 80), rgb(90, 90, 86) })
		D(head, V3(0.6, 1.34, 1.34), 0, 0.46, 0, col, M.Fabric, rot(0, 0, 90), CYL)
		D(head, V3(0.4, 0.4, 0.4), 0, 0.86, 0, rgb(230, 230, 226), M.Fabric, nil, BALL)
	elseif extra == "helmet" and wear then
		D(head, V3(0.5, 1.44, 1.44), 0, 0.52, 0, rgb(70, 80, 60), M.Metal, rot(0, 0, 90), CYL)
		D(head, V3(0.08, 1.6, 1.6), 0, 0.3, 0, rgb(60, 70, 52), M.Metal, rot(0, 0, 90), CYL)
		D(head, V3(0.08, 0.5, 0.06), 0.45, -0.1, -0.58, rgb(50, 40, 30), M.Leather)
	elseif extra == "vines" then
		D(torso, V3(2 * tw + 0.14, 0.25, td + 0.14), 0, 0.3, 0, rgb(50, 110, 40), M.Grass, rot(0, 0, 25))
		if wear then
			D(la, V3(c.build.arm + 0.1, 0.25, c.build.arm + 0.1), 0, -0.4, 0, rgb(50, 110, 40), M.Grass)
			D(head, V3(0.45, 0.45, 0.45), 0.5, 0.5, 0, rgb(170, 60, 140), M.SmoothPlastic, nil, BALL)
		end
	elseif extra == "algae" then
		D(torso, V3(2 * tw + 0.16, 0.8, td + 0.16), 0, -0.6, 0, rgb(60, 88, 50), M.Grass)
		if wear then
			D(head, V3(0.9, 0.12, 0.9), 0.1, 0.62, 0, rgb(60, 88, 50), M.Grass)
		end
	end
end

-- Уникальная внешность элиты, босса и мародёров
local function decorate(c)
	local D, def, b = c.D, c.def, c.build
	local head, torso, la, ra, ll, rl = c.head, c.torso, c.la, c.ra, c.ll, c.rl
	local tw, td = b.tw, b.depth
	local front, back = -td / 2, td / 2
	local id = def.id
	local skinColor = c.skin
	if id == "sand_giant" then
		D(torso, V3(2.3 * tw, 0.6, 1.2), 0, 0.9, 0, rgb(170, 130, 80), M.Sand)
		D(head, V3(0.4, 1.4, 1.4), 0, 0.42, 0, rgb(200, 170, 110), M.Fabric, rot(0, 0, 90), CYL)
		D(head, V3(0.36, 1.34, 1.34), 0, -0.26, 0, rgb(176, 146, 98), M.Fabric, rot(0, 0, 90), CYL)
		D(head, V3(0.35, 0.9, 0.1), 0.2, 0.05, 0.68, rgb(200, 170, 110), M.Fabric, rot(8, 0, 6))
		D(ra, V3(1.3, 1.3, 1.3), 0, -1.1, 0, rgb(150, 124, 90), M.Slate, nil, BALL)
		D(la, V3(1.08, 0.5, 1.08), 0, -0.8, 0, rgb(160, 130, 90), M.Fabric)
		D(torso, V3(2 * tw + 0.1, 2.4, 0.12), 0, -0.3, back + 0.08, rgb(150, 112, 70), M.Fabric)
		for i = -1, 1 do
			D(torso, V3(0.6, 0.6, 0.1), i * 0.65, -1.7, back + 0.1, rgb(140, 104, 66), M.Fabric, rot(0, 0, i * 12))
		end
		for i = -2, 2 do
			D(torso, V3(0.16, 0.3, 0.12), i * 0.28, 0.55 - math.abs(i) * 0.09, front - 0.08, BONE, nil, rot(0, 0, i * 14))
		end
		D(ll, V3(1.05, 0.8, 1.05), 0, -0.5, 0, rgb(168, 138, 96), M.Sandstone)
		D(rl, V3(1.05, 0.7, 1.05), 0, 0.3, 0, rgb(168, 138, 96), M.Sandstone)
	elseif id == "riot_brute" then
		D(head, V3(1.5, 1.1, 1.5), 0, 0.2, 0, rgb(30, 32, 40), M.Metal)
		D(head, V3(1.2, 0.35, 0.1), 0, 0.1, -0.76, rgb(80, 140, 200), M.Glass)
		D(torso, V3(2.2 * tw, 1.8, 1.25), 0, 0, 0, rgb(40, 44, 54), M.Metal)
		local shield = D(la, V3(0.25, 3.2, 2.2), -0.2, -0.4, -0.9, rgb(160, 180, 200), M.Glass, rot(0, 90, 0))
		shield.Name = "Shield"
		shield.Transparency = 0.25
		D(la, V3(0.1, 0.5, 1.6), -0.35, 0.4, -0.9, rgb(250, 250, 250), M.SmoothPlastic, rot(0, 90, 0))
		D(la, V3(0.3, 0.16, 2.3), -0.2, 1.2, -0.9, rgb(50, 54, 60), M.Metal, rot(0, 90, 0))
		D(la, V3(0.3, 0.16, 2.3), -0.2, -2.0, -0.9, rgb(50, 54, 60), M.Metal, rot(0, 90, 0))
		for _, arm in ipairs({ la, ra }) do
			D(arm, V3(1.25, 0.45, 1.25), 0, 0.85, 0, rgb(34, 36, 44), M.Metal)
		end
		for _, leg in ipairs({ ll, rl }) do
			D(leg, V3(1.05, 0.45, 0.25), 0, -0.15, -0.55, rgb(34, 36, 44), M.Metal)
			D(leg, V3(1.1, 0.5, 1.35), 0, -0.78, -0.12, rgb(22, 22, 24), M.Leather)
		end
		D(ra, V3(1.8, 0.2, 0.2), 0, -1.05, -0.9, rgb(24, 24, 26), M.Metal, rot(0, 90, 0), CYL)
	elseif id == "jungle_giant" then
		D(torso, V3(2.2 * tw, 0.4, 1.2), 0, 0.4, 0, rgb(50, 120, 40), M.Grass, rot(0, 0, 30))
		D(head, V3(0.4, 1.2, 0.4), 0.5, 0.9, 0, rgb(90, 70, 40), M.Wood, rot(0, 0, -20))
		D(head, V3(0.4, 1.2, 0.4), -0.5, 0.9, 0, rgb(90, 70, 40), M.Wood, rot(0, 0, 20))
		D(head, V3(0.25, 1.2, 1.2), 0, 0.5, 0, rgb(56, 96, 44), M.Grass, rot(0, 0, 90), CYL)
		D(la, V3(1.15, 0.4, 1.15), 0, -0.3, 0, rgb(50, 120, 40), M.Grass)
		D(ra, V3(1.15, 0.4, 1.15), 0, 0.2, 0, rgb(50, 120, 40), M.Grass)
		D(torso, V3(0.8, 0.7, 0.12), -0.45 * tw, 0.3, front - 0.06, rgb(80, 62, 40), M.Wood, rot(0, 0, 8))
		D(torso, V3(0.8, 0.7, 0.12), 0.45 * tw, -0.35, front - 0.06, rgb(74, 58, 38), M.Wood, rot(0, 0, -10))
		for _, p in ipairs({ { -0.8, 0.95, 0.2 }, { 0.7, 0.9, 0.4 }, { 0.1, 0.5, 0.56 } }) do
			D(torso, V3(0.3, 0.3, 0.3), p[1] * tw, p[2], p[3], rgb(90, 200, 170), M.Neon, nil, BALL)
		end
		D(torso, V3(0.12, 1.6, 0.12), -0.6, -1.4, back, rgb(46, 100, 36), M.Grass, rot(0, 0, 6))
		D(ra, V3(0.12, 1.4, 0.12), 0.3, -1.4, 0.2, rgb(46, 100, 36), M.Grass, rot(8, 0, 0))
	elseif id == "swamp_hag" then
		D(head, V3(1.4, 1.6, 1.3), 0, -0.1, 0.25, rgb(30, 40, 30), M.Fabric)
		D(torso, V3(2.1 * tw, 2.6, 1.15), 0, -0.6, 0, rgb(50, 66, 52), M.Fabric)
		D(torso, V3(0.8, 0.8, 0.8), 0.4, 0.4, -0.55, rgb(120, 230, 60), M.Neon, nil, BALL)
		for i = -1, 1 do
			D(head, V3(0.1, 1.1, 0.06), i * 0.35, -0.35, -0.66, rgb(22, 30, 24), M.Fabric, rot(0, 0, i * 6))
			D(torso, V3(0.5, 0.7, 0.1), i * 0.7 * tw, -2.1, i == 0 and 0.5 or -0.5, rgb(44, 58, 46), M.Fabric, rot(0, 0, i * 14))
		end
		for _, arm in ipairs({ la, ra }) do
			D(arm, V3(0.1, 0.4, 0.1), -0.25, -1.15, -0.25, BONE, nil, rot(-20, 0, 0))
			D(arm, V3(0.1, 0.4, 0.1), 0.25, -1.15, -0.25, BONE, nil, rot(-20, 0, 0))
		end
		D(la, V3(1.08, 0.3, 1.08), 0, 0.2, 0, rgb(60, 88, 50), M.Grass)
		D(ra, V3(1.08, 0.3, 1.08), 0, -0.3, 0, rgb(60, 88, 50), M.Grass)
	elseif id == "yeti" then
		D(torso, V3(2.4 * tw, 2.3, 1.5), 0, 0, 0, rgb(236, 242, 250), M.Snow)
		D(head, V3(1.4, 1.2, 1.4), 0, 0.15, 0.05, rgb(236, 242, 250), M.Snow)
		D(head, V3(0.25, 0.5, 0.2), 0.35, -0.35, -0.7, rgb(250, 250, 250), M.SmoothPlastic)
		D(head, V3(0.25, 0.5, 0.2), -0.35, -0.35, -0.7, rgb(250, 250, 250), M.SmoothPlastic)
		for _, sx in ipairs({ -1, 1 }) do
			D(torso, V3(1.2, 1, 1.2), sx * tw, 0.95, 0, rgb(230, 236, 246), M.Snow, nil, BALL)
			D(head, V3(0.25, 0.8, 0.25), sx * 0.55, 0.78, 0.1, rgb(190, 180, 160), M.SmoothPlastic, rot(0, 0, -sx * 35))
			D(head, V3(0.18, 0.5, 0.18), sx * 0.9, 1.15, 0.1, rgb(170, 160, 140), M.SmoothPlastic, rot(0, 0, -sx * 70))
		end
		for i, arm in ipairs({ la, ra }) do
			D(arm, V3(0.12, 0.5, 0.12), 0.3, -0.35 - i * 0.1, 0.4, rgb(180, 220, 250), M.Ice)
			D(arm, V3(1.1, 0.5, 1.1), 0, -0.85, 0, rgb(200, 226, 246), M.Ice)
		end
		for _, leg in ipairs({ ll, rl }) do
			D(leg, V3(1.2, 1.4, 1.2), 0, 0.2, 0, rgb(226, 232, 242), M.Snow)
		end
	elseif id == "mutant" then
		D(torso, V3(1.4, 1.4, 1.4), 0.7, 0.9, 0.2, skinColor:Lerp(rgb(220, 90, 110), 0.4), M.SmoothPlastic, nil, BALL)
		D(ra, V3(1.4, 2.4, 1.4), 0, -0.2, 0, skinColor:Lerp(rgb(80, 30, 40), 0.3), M.SmoothPlastic)
		D(torso, V3(0.3, 0.9, 0.3), -0.5, 1.1, 0.4, rgb(240, 230, 210), M.SmoothPlastic, rot(-30, 0, 0))
		D(torso, V3(0.3, 0.9, 0.3), 0.1, 1.2, 0.5, rgb(240, 230, 210), M.SmoothPlastic, rot(-30, 0, 0))
		for i = 0, 2 do
			D(torso, V3(0.2, 0.35, 0.2), 0, 0.5 - i * 0.5, back + 0.08, BONE, nil, rot(-30, 0, 0))
			D(ra, V3(0.12, 0.9, 0.3), (i - 1) * 0.35, -1.55, -0.3, BONE, nil, rot(-25, 0, 0))
		end
		D(torso, V3(0.32, 0.32, 0.32), -0.5, -0.3, front - 0.1, rgb(230, 90, 120), M.Neon, nil, BALL)
		D(torso, V3(0.24, 0.24, 0.24), 0.6, -0.6, front - 0.08, rgb(230, 90, 120), M.Neon, nil, BALL)
		D(la, V3(0.06, 1.2, 0.6), -0.52, -0.2, 0, rgb(140, 50, 50))
	elseif id == "raider" then
		D(head, V3(1.3, 0.45, 1.3), 0, -0.25, 0, rgb(150, 30, 30), M.Fabric)
		D(head, V3(1.35, 0.35, 1.35), 0, 0.5, 0, rgb(60, 60, 50), M.Fabric)
		D(head, V3(1.0, 0.18, 0.1), 0, 0.3, -0.66, rgb(200, 120, 40), M.Glass)
		D(torso, V3(2.1, 1.7, 1.15), 0, 0.1, 0, rgb(70, 76, 50), M.Fabric)
		D(torso, V3(2.15, 0.3, 1.2), 0, -0.8, 0, rgb(50, 40, 30), M.Leather)
		D(torso, V3(1.4, 1.4, 0.6), 0, 0, 0.9, rgb(74, 80, 56), M.Fabric)
		D(torso, V3(1.42, 0.3, 0.62), 0, 0.62, 0.92, rgb(60, 64, 44), M.Fabric)
		D(torso, V3(0.35, 0.3, 0.2), -0.55, -0.8, -0.66, rgb(60, 50, 36), M.Leather)
		D(torso, V3(0.35, 0.3, 0.2), 0.55, -0.8, -0.66, rgb(60, 50, 36), M.Leather)
		for _, arm in ipairs({ la, ra }) do
			D(arm, V3(1.05, 0.4, 1.05), 0, -0.84, 0, rgb(34, 30, 28), M.Leather)
		end
		for _, leg in ipairs({ ll, rl }) do
			D(leg, V3(1.1, 0.5, 1.3), 0, -0.78, -0.1, rgb(30, 26, 24), M.Leather)
		end
		local gun = D(ra, V3(0.35, 0.45, 2.6), 0, -1.05, -1.0, rgb(45, 45, 50), M.Metal)
		gun.Name = "Gun"
		D(ra, V3(0.2, 0.2, 1.2), 0, -0.95, -2.8, rgb(30, 30, 34), M.Metal)
		D(ra, V3(0.3, 0.8, 0.35), 0, -1.5, -0.4, rgb(90, 60, 40), M.Wood)
	elseif def.boss then
		-- кондуктор: форма, фуражка с кокардой, сумка с ремнём, компостер
		D(torso, V3(2 * tw + 0.12, 1.96, td + 0.12), 0, -0.02, 0, rgb(34, 42, 76), M.Fabric)
		for i = 0, 2 do
			D(torso, V3(0.16, 0.16, 0.06), 0.18, 0.55 - i * 0.5, front - 0.08, rgb(200, 170, 70), M.Metal)
		end
		D(torso, V3(0.24, 0.9, 0.05), -0.12, 0.35, front - 0.08, rgb(120, 30, 30), M.Fabric)
		D(torso, V3(0.2, 2.6, 0.06), 0, 0, front - 0.09, rgb(70, 50, 34), M.Leather, rot(0, 0, 40))
		for _, arm in ipairs({ la, ra }) do
			D(arm, V3(1.06, 1.5, 1.06), 0, 0.27, 0, rgb(34, 42, 76), M.Fabric)
			D(arm, V3(0.9, 0.12, 0.6), 0, 1.04, 0, rgb(200, 170, 70), M.Metal)
		end
		D(head, V3(2.1, 0.35, 1.9), 0, 0.7, -0.1, rgb(30, 36, 70))
		D(head, V3(1.6, 0.4, 1.5), 0, 0.95, 0, rgb(30, 36, 70))
		D(head, V3(0.4, 0.3, 0.1), 0, 0.95, -0.76, rgb(230, 190, 60), M.Neon)
		D(torso, V3(1, 1, 0.5), 0.9, -0.6, -0.7, rgb(90, 60, 40), M.Leather)
		D(torso, V3(0.3, 0.5, 0.2), -0.8, -0.8, -0.62, rgb(110, 110, 116), M.Metal)
	end
	if def.elite then
		-- светящийся знак элиты на груди (перед бронёй и мехом)
		D(torso, V3(0.5, 0.5, 0.1), 0, 0.4, front - (id == "yeti" and 0.32 or 0.2), PURPLE, M.Neon)
	end
end

local function buildRig(def, biome, hp, elite)
	local b = chooseBuild(def)
	local s = (def.scale or 1) * b.size
	local bskin = biome.skin or {}
	local skinColor = zombieSkin(biome)
	local shirt = grime(chance(0.45) and (bskin.shirt or pick(SHIRTS)) or pick(SHIRTS))
	local pants = grime(chance(0.4) and (bskin.pants or pick(PANTS)) or pick(PANTS))
	local glow = rgb(170, 36, 28)
	if def.boss then
		skinColor, shirt, pants = rgb(110, 120, 100), rgb(40, 50, 90), rgb(30, 30, 40)
		glow = rgb(230, 170, 40)
	elseif def.colors then
		skinColor = def.colors.skin or skinColor
		shirt = def.colors.shirt or shirt
		pants = def.colors.pants or pants
		glow = def.id == "yeti" and rgb(90, 190, 255) or rgb(170, 100, 230)
	elseif def.human then
		skinColor = HUMAN_SKINS[rng:NextInteger(1, #HUMAN_SKINS)]
		shirt, pants = rgb(60, 56, 50), rgb(70, 74, 56)
	elseif def.id == "bloater" then
		skinColor = skinColor:Lerp(rgb(140, 160, 90), 0.6)
	elseif def.id == "spitter" then
		skinColor = skinColor:Lerp(rgb(120, 170, 80), 0.55)
		glow = rgb(140, 190, 40)
	elseif def.id == "brute" then
		skinColor = skinColor:Lerp(rgb(90, 70, 70), 0.4)
		shirt = skinColor
	end
	if elite and not def.elite and not def.boss then
		skinColor = skinColor:Lerp(rgb(150, 90, 170), 0.35)
		glow = rgb(170, 100, 230)
	end

	local model = Instance.new("Model")
	model.Name = def.name
	local tw, td, aw, lw = b.tw, b.depth, b.arm, b.leg
	local hipW = math.min(tw, 1.15)
	local root = limb(model, "HumanoidRootPart", V3(2, 2, 1) * s, skinColor, false)
	root.Transparency = 1
	local torso = limb(model, "Torso", V3(2 * tw, 2, td) * s, shirt, true)
	local head = limb(model, "Head", V3(2, 1, 1) * s, skinColor, true)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Head
	mesh.Scale = V3(b.head, b.head, b.head)
	mesh.Parent = head
	local la = limb(model, "Left Arm", V3(aw, 2, aw) * s, skinColor, false)
	local ra = limb(model, "Right Arm", V3(aw, 2, aw) * s, skinColor, false)
	local ll = limb(model, "Left Leg", V3(lw, 2, lw) * s, pants, false)
	local rl = limb(model, "Right Leg", V3(lw, 2, lw) * s, pants, false)

	root.CFrame = CFrame.new(0, 200, 0)
	torso.CFrame = root.CFrame
	head.CFrame = root.CFrame * CFrame.new(0, 1.5 * s, 0)
	la.CFrame = root.CFrame * CFrame.new(-(tw + aw / 2) * s, 0, 0)
	ra.CFrame = root.CFrame * CFrame.new((tw + aw / 2) * s, 0, 0)
	ll.CFrame = root.CFrame * CFrame.new(-(hipW - lw / 2) * s, -2 * s, 0)
	rl.CFrame = root.CFrame * CFrame.new((hipW - lw / 2) * s, -2 * s, 0)

	motor(root, "RootJoint", root, torso, R6.RootJoint, s)
	motor(torso, "Neck", torso, head, R6.Neck, s)
	motor(torso, "Right Shoulder", torso, ra, R6.RightShoulder, s, tw, aw)
	motor(torso, "Left Shoulder", torso, la, R6.LeftShoulder, s, tw, aw)
	motor(torso, "Right Hip", torso, rl, R6.RightHip, s, hipW, lw)
	motor(torso, "Left Hip", torso, ll, R6.LeftHip, s, hipW, lw)

	local D = detailer(model, s)
	local c = {
		D = D, def = def, build = b, model = model,
		head = head, torso = torso, la = la, ra = ra, ll = ll, rl = rl,
		skin = skinColor, shirt = shirt, pants = pants, shoe = grime(pick(SHOES), 0.2),
	}
	dressFace(D, head, skinColor, glow, def.human == true)
	if def.boss or def.elite or def.human then
		decorate(c)
	else
		local extra = bskin.extra
		local isHat = extra == "cap" or extra == "beanie" or extra == "helmet"
		local wear = chance(0.55)
		dressHair(D, head, isHat and wear)
		dressBody(c)
		dressExtra(c, extra, wear)
		if elite then
			D(ra, V3(aw + 0.1, 0.25, aw + 0.1), 0, 0.35, 0, PURPLE, M.Neon)
		end
	end

	model:SetAttribute("Gait", b.gait)
	if b.gait == "drag" or b.gait == "limp" then
		model:SetAttribute("DragSide", chance(0.5) and 1 or -1)
	end
	model:SetAttribute("Hunch", rng:NextNumber(0, 1))

	local hum = makeHumanoid(model, def, hp)
	model.PrimaryPart = root
	return model, hum, root, head, torso, s, b
end

-- Гнездо: неподвижная пульсирующая масса (все детали закреплены)
local function buildNest(def, biome, hp)
	local model = Instance.new("Model")
	model.Name = def.name
	local base = CFrame.new(0, 200, 0)
	local flesh = rgb(120, 60, 70):Lerp(biome.ground or rgb(100, 100, 100), 0.2)
	local function part(name, size, cf, color, material, shape, collide)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.Color = color
		p.Material = material or Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Anchored = true
		p.CanCollide = collide == true
		p.CanTouch = false
		p.CollisionGroup = "Zombies"
		if shape then
			p.Shape = shape
		end
		p.CFrame = base * cf
		p.Parent = model
		return p
	end
	local root = part("HumanoidRootPart", V3(4, 4, 4), CFrame.new(), flesh, nil, nil, false)
	root.Transparency = 1
	root.CanQuery = false
	-- без столкновений: не мешает автобусу физически (урон по нему — лучами оружия, CanQuery)
	local torso = part("Torso", V3(9, 9, 9), CFrame.new(0, -0.5, 0), flesh, Enum.Material.SmoothPlastic, Enum.PartType.Ball, false)
	local head = part("Head", V3(4.5, 4.5, 4.5), CFrame.new(0, 3.6, 0), rgb(170, 60, 120), Enum.Material.Neon, Enum.PartType.Ball, false)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Scale = V3(1, 1, 1)
	mesh.Parent = head
	for i = 1, 6 do
		local a = (i / 6) * TWO_PI
		local cf = CFrame.new(math.cos(a) * 4.8, -2.8, math.sin(a) * 4.8) * CFrame.Angles(0, -a, math.rad(35))
		local d = part("Detail", V3(1.2, 6, 1.2), cf, flesh:Lerp(rgb(40, 20, 25), 0.35), Enum.Material.SmoothPlastic, nil, false)
		d.CanQuery = false
	end
	for i = 1, 4 do
		local a = (i / 4) * TWO_PI + 0.4
		local d = part("Detail", V3(1.6, 1.6, 1.6), CFrame.new(math.cos(a) * 3.2, 1.8, math.sin(a) * 3.2), rgb(230, 200, 90), Enum.Material.Neon, Enum.PartType.Ball, false)
		d.CanQuery = false
	end
	local light = Instance.new("PointLight")
	light.Color = rgb(220, 80, 160)
	light.Range = 18
	light.Brightness = 1.5
	light.Parent = head
	local hum = makeHumanoid(model, def, hp)
	hum.WalkSpeed = 0
	hum.JumpPower = 0
	model.PrimaryPart = root
	return model, hum, root, head, torso
end

-- Спавн ----------------------------------------------------------------------------------

local function releaseMinion(z)
	local parent = z.minionOf
	if parent then
		parent.childCount = math.max(0, (parent.childCount or 0) - 1)
		z.minionOf = nil
	end
end

local shieldMult

--[[ opts:
	biome, home (Vector3), aggro, tag, hpMult, elite (bool), onDeath(z, info), noDespawn,
	дополнительно: speedMult, onRemoved(z) (вызывается при Zombies.Remove), minionOf (z родителя),
	name (отображаемое имя модели)
]]
function ZS.Spawn(typeId, position, opts)
	opts = opts or {}
	local def = ZombieDefs.Types[typeId]
	if not def or typeof(position) ~= "Vector3" then
		return nil
	end
	local busS = S.Bus.S or 0
	local biome = opts.biome or S.World.BiomeAtS(busS)
	local sc = getScale()
	local nPlayers = math.max(1, #Players:GetPlayers())
	local elite = def.elite == true or opts.elite == true
	local hpMult = type(opts.hpMult) == "number" and opts.hpMult or 1
	local hp = def.hp * sc.hp * hpMult
	if def.boss then
		-- босс не зависит от километров, только от сложности, уровня и числа игроков
		hp = def.hp * (1 + 0.6 * (nPlayers - 1)) * scaleBase.hp * hpMult
	elseif elite then
		hp = hp * (1 + 0.45 * (nPlayers - 1))
		if not def.elite then
			hp = hp * 3
		end
	end
	hp = math.max(1, math.floor(hp + 0.5))

	local model, hum, root, head, torso, rigScale, build
	if def.stationary then
		model, hum, root, head, torso = buildNest(def, biome, hp)
	else
		model, hum, root, head, torso, rigScale, build = buildRig(def, biome, hp, elite)
	end
	local s = rigScale or def.scale or 1
	local height = def.stationary and 3.5 or (3 * s + 0.2)
	model:PivotTo(CFrame.new(position + V3(0, height, 0)) * CFrame.Angles(0, rng:NextNumber(0, TWO_PI), 0))
	model:SetAttribute("ZType", typeId)
	if type(opts.name) == "string" and opts.name ~= "" then
		model.Name = opts.name
	end
	if elite then
		model:SetAttribute("Elite", true)
	end
	model.Parent = folder
	if not def.stationary then
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
	end
	for _, st in ipairs({ Enum.HumanoidStateType.Climbing, Enum.HumanoidStateType.Swimming, Enum.HumanoidStateType.Seated, Enum.HumanoidStateType.Flying }) do
		hum:SetStateEnabled(st, false)
	end

	local dmgMult = sc.damage
	if biome.special and biome.special.damageMult then
		dmgMult = dmgMult * biome.special.damageMult
	end
	if elite and not def.elite then
		dmgMult = dmgMult * 1.5
	end

	local now = os.clock()
	local z = {
		model = model,
		humanoid = hum,
		root = root,
		head = head,
		torso = torso,
		def = def,
		typeId = typeId,
		biome = biome,
		dmgMult = dmgMult,
		radius = def.stationary and 4.5 or 1.2 * s,
		nextAttack = 0,
		nextThink = 0,
		nextRanged = now + rng:NextNumber(0.5, 2),
		nextAbility = now + rng:NextNumber(2.5, 4.5),
		nextSpawn = now + rng:NextNumber(1, 3),
		stunUntil = 0,
		lastPos = position,
		spawnPos = position,
		stuckTime = 0,
		home = typeof(opts.home) == "Vector3" and opts.home or nil,
		aggro = opts.aggro == true,
		tag = opts.tag,
		elite = elite,
		noDespawn = opts.noDespawn == true,
		onDeath = type(opts.onDeath) == "function" and opts.onDeath or nil,
		onRemoved = type(opts.onRemoved) == "function" and opts.onRemoved or nil,
		speedMult = type(opts.speedMult) == "number" and opts.speedMult or nil,
		spawnTime = now,
		scale = s,
		gaitSpeed = build and build.speed or nil,
		nextSlam = now + 5,
		nextCharge = now + 9,
		summoned = 0,
		childCount = 0,
		lastHurt = 0,
	}
	if type(opts.minionOf) == "table" and not opts.minionOf.dead then
		z.minionOf = opts.minionOf
		opts.minionOf.childCount = (opts.minionOf.childCount or 0) + 1
	end

	if def.shield then
		-- Щит: CombatService может вызвать z.damageFilter до применения урона.
		-- Если не вызвал — возвращаем часть здоровья после попадания спереди.
		z.damageFilter = function(zz, amount, info)
			if type(amount) ~= "number" then
				return amount
			end
			zz.filteredInfo = info
			return amount * shieldMult(zz, info)
		end
		z.lastHealth = hp
		hum.HealthChanged:Connect(function(h)
			if z.dead then
				return
			end
			local prev = z.lastHealth or h
			z.lastHealth = h
			if h >= prev or h <= 0 then
				return
			end
			local info = z.lastInfo
			if info and info ~= z.filteredInfo then
				z.filteredInfo = info
				local mult = shieldMult(z, info)
				if mult < 1 then
					local restored = math.min(hum.MaxHealth, h + (prev - h) * (1 - mult))
					z.lastHealth = restored
					hum.Health = restored
				end
			end
		end)
	end

	hum.Died:Connect(function()
		ZS.OnKilled(z)
	end)
	active[model] = z
	listDirty = true
	return z
end

-- Группа зомби вокруг точки (с проверкой препятствий и автобуса). types: id, взвешенный список или nil (зомби биома)
function ZS.SpawnGroup(types, center, count, minR, maxR, opts)
	local out = {}
	if typeof(center) ~= "Vector3" or type(count) ~= "number" then
		return out
	end
	opts = opts or {}
	local biome = opts.biome or S.World.BiomeAtS(S.Bus.S or 0)
	for _ = 1, math.floor(count) do
		local p = ZS.FindSpawnPoint(center, minR or 0, maxR or 12, 6, 2.5)
		if p then
			local typeId = types
			if type(types) == "table" then
				typeId = Util.Weighted(rng, types)
			elseif types == nil then
				typeId = Util.Weighted(rng, biome.zombies)
			end
			local spawnOpts = {}
			for k, v in pairs(opts) do
				spawnOpts[k] = v
			end
			spawnOpts.biome = biome
			local z = ZS.Spawn(typeId, p, spawnOpts)
			if z then
				table.insert(out, z)
			end
		end
	end
	return out
end

local function spawnMinion(parent, typeId, minR, maxR, extra)
	local p = ZS.FindSpawnPoint(parent.root.Position, minR, maxR, 6, 2.5)
	if not p then
		return nil
	end
	local opts = { biome = parent.biome, aggro = true, minionOf = parent }
	if extra then
		for k, v in pairs(extra) do
			opts[k] = v
		end
	end
	local child = ZS.Spawn(typeId, p, opts)
	if child then
		Net.FireNear("Explosion", p, 300, p + V3(0, 0.3, 0), 4, "slam")
	end
	return child
end

-- Смерть и удаление ----------------------------------------------------------------------

local function isPlayer(v)
	return typeof(v) == "Instance" and v:IsA("Player") and v.Parent ~= nil
end

local function model_name(z)
	return (z.model and z.model.Name ~= "" and z.model.Name) or z.def.name
end

function ZS.Remove(z)
	if not z or z.dead then
		return
	end
	z.dead = true
	active[z.model] = nil
	listDirty = true
	releaseMinion(z)
	if z.onRemoved then
		task.spawn(function()
			local ok, err = pcall(z.onRemoved, z)
			if not ok then
				warn("[Zombies] onRemoved: " .. tostring(err))
			end
		end)
	end
	z.model:Destroy()
end

-- сколько секунд после последнего удара игрок считается убийцей
local KILL_CREDIT_WINDOW = 5

function ZS.OnKilled(z)
	if z.dead then
		return
	end
	z.dead = true
	active[z.model] = nil
	listDirty = true
	releaseMinion(z)
	local info = z.lastInfo or {}
	-- забег окончен (победа добивает всех зомби) — никаких наград и уведомлений
	local runEnded = S.Run.State == "Victory" or S.Run.State == "Failed"
	-- самоподрыв раздутого — не заслуга последнего, кто его поцарапал
	local selfDestruct = z.exploded == true
	-- принудительная смерть (зачистка станции и т.п.) спустя долгое время после удара — без убийцы
	local recentHit = z.lastInfo ~= nil and (z.lastInfo ~= z.creditInfo or os.clock() - (z.lastHitAt or -math.huge) < KILL_CREDIT_WINDOW)
	local killer = (not runEnded and not selfDestruct and recentHit and isPlayer(info.attacker)) and info.attacker or nil
	local def = z.def
	local sc = getScale()
	local rewardMult = sc.reward
	local blood = bloodMoon()
	if blood then
		rewardMult = rewardMult * EventDefs.Tuning.bloodMoonRewardMult
	end
	local pos = z.root.Position

	if killer then
		local d = S.PlayerData.Get(killer)
		if d then
			S.PlayerData.AddMoney(killer, def.reward * rewardMult)
			d.Kills = d.Kills + 1
			killer:SetAttribute("Kills", d.Kills)
			if not def.boss and not z.elite then
				S.Profile.AddXP(killer, def.reward * Progression.XP.killPerReward * (blood and 2 or 1), "kill")
			end
		end
	end
	if not runEnded then
		S.Run.AddKill()
	end

	if z.elite and not def.boss and not runEnded then
		-- опыт элиты: убийце и всем, кто был рядом
		for _, plr in ipairs(Players:GetPlayers()) do
			local r = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
			if plr == killer or (r and (r.Position - pos).Magnitude < 150 and S.PlayerData.Get(plr)) then
				S.Profile.AddXP(plr, Progression.XP.elite * (blood and 2 or 1), "elite")
			end
		end
		local who = killer and killer.DisplayName or "Команда"
		S.PlayerData.NotifyAll(who .. " одолел(а) элиту: " .. model_name(z), PURPLE)
		local spots = {}
		for i = 1, 4 do
			local a = (i / 4) * TWO_PI
			table.insert(spots, CFrame.new(V3(pos.X + math.cos(a) * 3, 0.1, pos.Z + math.sin(a) * 3)))
		end
		S.Loot.SpawnFromTable("elite", spots, rng, workspace:FindFirstChild("Loot"))
	end

	if def.explode and not z.exploded then
		z.exploded = true
		task.defer(function()
			S.Combat.Explode(pos, def.explode.radius, def.explode.damage * z.dmgMult, { kind = "bloater", hurtPlayers = true, attacker = killer, source = z })
		end)
	end

	local model = z.model
	for _, p in ipairs(model:GetDescendants()) do
		if p:IsA("BasePart") then
			p.CollisionGroup = "Debris"
			p.CanQuery = false
		end
	end
	if z.deathImpulse and not def.stationary then
		pcall(function()
			z.root:ApplyImpulse((z.deathImpulse + V3(0, 15, 0)) * z.root.AssemblyMass)
		end)
	end
	if z.fireFx then
		z.fireFx:Destroy()
		z.fireFx = nil
	end
	Net.FireNear("Explosion", pos, 300, pos, 3 * (def.scale or 1) * (def.stationary and 3 or 1), "blood")
	if def.stationary then
		Net.FireNear("Explosion", pos, 400, pos, 9, "bloater")
		if not runEnded then
			S.PlayerData.NotifyAll("Гнездо уничтожено!", rgb(255, 200, 120))
		end
	end
	task.delay(def.stationary and 1.5 or 5, function()
		if model.Parent then
			model:Destroy()
		end
	end)

	if def.boss then
		if not runEnded then
			for _, plr in ipairs(Players:GetPlayers()) do
				if S.PlayerData.Get(plr) then
					S.Profile.AddXP(plr, Progression.XP.boss, "boss")
				end
			end
		end
		S.Stations.OnBossKilled(z)
	elseif def.human and not runEnded then
		-- после конца забега лут с добитых зомби не выпадает
		if rng:NextNumber() < 0.45 then
			S.Loot.SpawnItem(rng:NextNumber() < 0.7 and "ammo_light" or "ammo_shell", 1, CFrame.new(V3(pos.X, 0.1, pos.Z)), workspace:FindFirstChild("Loot"))
		end
	elseif not runEnded and not def.human and not z.tag and not z.minionOf and not z.elite and rng:NextNumber() < 0.07 then
		S.Loot.SpawnFromTable("roadside", { CFrame.new(V3(pos.X, 0.1, pos.Z)) }, rng, workspace:FindFirstChild("Loot"))
	end

	if z.onDeath then
		task.spawn(function()
			local ok, err = pcall(z.onDeath, z, info)
			if not ok then
				warn("[Zombies] onDeath: " .. tostring(err))
			end
		end)
	end
end

function ZS.Stun(z, t)
	if not z or z.dead or type(t) ~= "number" then
		return
	end
	if z.def.boss then
		t = t * 0.1
	elseif z.elite then
		t = t * 0.3
	elseif z.def.heavy then
		t = t * 0.4
	end
	z.stunUntil = math.max(z.stunUntil, os.clock() + t)
end

function ZS.Knockback(z, dir, force, stun)
	if not z or z.dead or typeof(dir) ~= "Vector3" or type(force) ~= "number" then
		return
	end
	if z.def.stationary then
		return
	end
	local resist = 1
	if z.def.boss then
		resist = 0.05
	elseif z.elite then
		resist = 0.15
	elseif z.def.heavy then
		resist = 0.3
	end
	local flat = Util.Flat(dir)
	if flat.Magnitude < 0.01 then
		flat = V3(0, 0, 1)
	end
	local strength = force * resist
	pcall(function()
		z.root:ApplyImpulse((flat.Unit * strength + V3(0, strength * 0.35, 0)) * z.root.AssemblyMass)
	end)
	if strength > 40 then
		z.humanoid.PlatformStand = true
		z.ragdollUntil = os.clock() + 0.9
		z.charge = nil
	end
	if stun then
		ZS.Stun(z, stun)
	end
end

-- Зомби в радиусе бегут к источнику шума
function ZS.Alert(position, radius)
	if typeof(position) ~= "Vector3" or type(radius) ~= "number" then
		return
	end
	for _, z in ipairs(ZS.List()) do
		if not z.dead and not z.def.stationary and (z.root.Position - position).Magnitude <= radius then
			z.aggro = true
			z.nextThink = 0
			z.alertPos = position
		end
	end
end

-- Один зомби бежит к точке и не возвращается домой
function ZS.AlertTo(z, position)
	if type(z) ~= "table" or z.dead or typeof(position) ~= "Vector3" then
		return
	end
	z.aggro = true
	z.home = nil
	z.nextThink = 0
	z.alertPos = position
end

function ZS.CountTag(tag)
	local n = 0
	for _, z in pairs(active) do
		if not z.dead and z.tag == tag then
			n = n + 1
		end
	end
	return n
end

local function clearClouds()
	for part in pairs(clouds) do
		if part.Parent then
			part:Destroy()
		end
	end
	clouds = {}
end

function ZS.ClearAll()
	for _, z in pairs(active) do
		z.dead = true
		if z.model then
			z.model:Destroy()
		end
	end
	for k in pairs(active) do
		active[k] = nil
	end
	listDirty = true
	spawners = {}
	extraTargets = {}
	clearClouds()
	for _, child in ipairs(folder:GetChildren()) do
		child:Destroy()
	end
end

-- key — стабильный ключ места (память чанков против фарма)
function ZS.AddSpawner(chunkId, position, count, biome, key)
	if typeof(position) ~= "Vector3" then
		return
	end
	if key ~= nil and S.World.IsSpawnerUsed and S.World.IsSpawnerUsed(key) then
		return
	end
	local lst = spawners[chunkId]
	if not lst then
		lst = {}
		spawners[chunkId] = lst
	end
	-- км места: по чанку (s0 = chunkId * ChunkLength), иначе — километр автобуса
	local km = type(chunkId) == "number" and (chunkId + 0.5) * Config.ChunkLength / Config.StudsPerKm or busKm()
	table.insert(lst, { pos = position, count = count or 2, biome = biome or S.World.BiomeAtS(S.Bus.S or 0), key = key, km = math.max(0, km) })
end

function ZS.ClearChunk(chunkId)
	spawners[chunkId] = nil
end

-- Дополнительные цели (выжившие, обороняемые объекты) ------------------------------------

function ZS.AddTarget(entity)
	if type(entity) ~= "table" or typeof(entity.root) ~= "Instance" or not entity.root:IsA("BasePart") then
		return false
	end
	for _, e in ipairs(extraTargets) do
		if e == entity then
			return true
		end
	end
	table.insert(extraTargets, entity)
	return true
end

function ZS.RemoveTarget(entity)
	for i = #extraTargets, 1, -1 do
		if extraTargets[i] == entity then
			table.remove(extraTargets, i)
		end
	end
	for _, z in pairs(active) do
		if z.target and z.target.entity == entity then
			z.target = nil
			z.nextThink = 0
		end
	end
end

local function gatherTargets()
	local out = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		local d = S.PlayerData.Get(plr)
		local char = plr.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if d and not d.Dead and hum and hum.Health > 0 and root then
			table.insert(out, {
				player = plr,
				root = root,
				sleeping = S.Sleep.IsSleeping(plr),
				downed = d.Downed,
				inBus = S.Bus.IsInside(root.Position),
				radius = 1.5,
				priority = 1,
			})
		end
	end
	for i = #extraTargets, 1, -1 do
		local e = extraTargets[i]
		local root = e.root
		if not root or not root.Parent then
			table.remove(extraTargets, i)
		else
			table.insert(out, {
				entity = e,
				root = root,
				inBus = S.Bus.IsInside(root.Position),
				radius = type(e.radius) == "number" and e.radius or 2,
				priority = type(e.priority) == "number" and math.max(0.1, e.priority) or 1,
			})
		end
	end
	return out
end

local function damageTarget(t, amount, z, knock)
	if t.player then
		S.Combat.DamagePlayer(t.player, amount, { zombie = z, kind = "zombie", knock = knock, biomeEffect = not z.def.human })
	elseif t.entity and type(t.entity.onDamage) == "function" then
		local ok, err = pcall(t.entity.onDamage, amount, z)
		if not ok then
			warn("[Zombies] onDamage: " .. tostring(err))
		end
	end
end

local function damageEntitiesNear(position, radius, amount, z)
	for _, e in ipairs(extraTargets) do
		local root = e.root
		if root and root.Parent and type(e.onDamage) == "function" and (root.Position - position).Magnitude <= radius + (e.radius or 2) then
			local ok, err = pcall(e.onDamage, amount, z)
			if not ok then
				warn("[Zombies] onDamage: " .. tostring(err))
			end
		end
	end
end

-- Помощники боя --------------------------------------------------------------------------

local function flatUnit(v, fallback)
	local f = Util.Flat(v)
	if f.Magnitude < 0.05 then
		return fallback or V3(0, 0, 1)
	end
	return f.Unit
end

-- Угол атаки против щита: 1 = полный урон
shieldMult = function(z, info)
	local sh = z.def.shield
	if not sh or z.dead or type(info) ~= "table" then
		return 1
	end
	if info.kind == "fire" or info.kind == "poison" or os.clock() < z.stunUntil or z.ragdollUntil then
		return 1
	end
	local pos = z.root.Position
	local toSource
	if typeof(info.knockDir) == "Vector3" and info.knockDir.Magnitude > 0.01 then
		toSource = -info.knockDir
	elseif isPlayer(info.attacker) then
		local r = info.attacker.Character and info.attacker.Character:FindFirstChild("HumanoidRootPart")
		if r then
			toSource = r.Position - pos
		end
	end
	if not toSource and typeof(info.position) == "Vector3" then
		toSource = info.position - pos
	end
	if not toSource then
		return 1
	end
	local f = Util.Flat(toSource)
	if f.Magnitude < 0.05 then
		return 1
	end
	if f.Unit:Dot(flatUnit(z.root.CFrame.LookVector)) >= sh.dot then
		return sh.mult
	end
	return 1
end

-- Скорость для навесного броска в точку
local function ballistic(origin, aimPos, speed, gravity)
	local delta = aimPos - origin
	local flat = Util.Flat(delta)
	local fm = flat.Magnitude
	local flightTime = math.max(fm / speed, 0.05)
	local vy = delta.Y / flightTime + 0.5 * gravity * flightTime
	local dir = fm > 0.1 and flat.Unit or V3(0, 0, 1)
	return dir * speed + V3(0, vy, 0), flightTime
end

local function spreadDir(dir, degrees)
	if not degrees or degrees <= 0 then
		return dir
	end
	local cf = CFrame.lookAt(Vector3.zero, dir)
	cf = cf * CFrame.Angles(math.rad(rng:NextNumber(-degrees, degrees)), math.rad(rng:NextNumber(-degrees, degrees)), 0)
	return cf.LookVector
end

local function groundAt(p)
	return V3(p.X, 0.3, p.Z)
end

local function impactBlast(position, radius, damage, kind, z)
	local p = V3(position.X, math.max(position.Y, 0.5), position.Z)
	if p.Y > 60 then
		return
	end
	S.Combat.Explode(p, radius, damage, { kind = kind, hurtPlayers = true, hurtZombies = false, busMult = 0.5, source = z })
	damageEntitiesNear(p, radius, damage * 0.7, z)
end

-- Ядовитое облако (утопленница)
local function poisonCloud(position, ab, dmgMult, z)
	if position.Y < -20 then
		return
	end
	local center = V3(position.X, 0, position.Z)
	local radius = ab.radius
	local disc = Instance.new("Part")
	disc.Name = "PoisonCloud"
	disc.Shape = Enum.PartType.Cylinder
	disc.Size = V3(0.4, radius * 2, radius * 2)
	disc.CFrame = CFrame.new(center + V3(0, 0.25, 0)) * CFrame.Angles(0, 0, math.rad(90))
	disc.Color = rgb(110, 200, 60)
	disc.Material = Enum.Material.Neon
	disc.Transparency = 0.65
	disc.Anchored = true
	disc.CanCollide = false
	disc.CanQuery = false
	disc.CanTouch = false
	disc.CastShadow = false
	local dome = Instance.new("Part")
	dome.Name = "Dome"
	dome.Shape = Enum.PartType.Ball
	dome.Size = V3(radius * 1.6, radius * 1.6, radius * 1.6)
	dome.CFrame = CFrame.new(center + V3(0, 1, 0))
	dome.Color = rgb(120, 190, 70)
	dome.Material = Enum.Material.SmoothPlastic
	dome.Transparency = 0.82
	dome.Anchored = true
	dome.CanCollide = false
	dome.CanQuery = false
	dome.CanTouch = false
	dome.CastShadow = false
	dome.Parent = disc
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = "rbxasset://textures/particles/smoke_main.dds"
	emitter.Color = ColorSequence.new(rgb(130, 210, 70))
	emitter.Size = NumberSequence.new(5)
	emitter.Transparency = NumberSequence.new(0.7)
	emitter.Lifetime = NumberRange.new(1.5, 2.5)
	emitter.Rate = 14
	emitter.Speed = NumberRange.new(1, 3)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.LightEmission = 0.2
	emitter.Parent = dome
	disc.Parent = getFxFolder()
	clouds[disc] = true

	task.spawn(function()
		local elapsed = 0
		local touched = {}
		while elapsed < ab.duration and disc.Parent do
			task.wait(0.5)
			elapsed = elapsed + 0.5
			for _, plr in ipairs(Players:GetPlayers()) do
				local r = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
				if r and Util.FlatDist(r.Position, center) <= radius and math.abs(r.Position.Y - center.Y) < 10 then
					local first = not touched[plr]
					touched[plr] = true
					S.Combat.DamagePlayer(plr, ab.dps * 0.5 * dmgMult, { kind = "poison", silent = not first })
					S.PlayerData.AddEffect(plr, "Poison", ab.effectTime)
					if first then
						S.PlayerData.Notify(plr, "Ядовитое облако! Выйдите из него", rgb(150, 230, 90))
					end
				end
			end
			damageEntitiesNear(center, radius, ab.dps * 0.5 * dmgMult, z)
		end
		clouds[disc] = nil
		if disc.Parent then
			disc:Destroy()
		end
	end)
end

local function busHull(busRoot, pos, z)
	local lp = busRoot.CFrame:PointToObjectSpace(pos)
	local td = S.Bus.TypeDef
	local halfW = ((td and td.width) or 12) / 2 + 3
	local halfL = ((td and td.length) or 44) / 2 + 3
	return math.abs(lp.X) < halfW + z.radius and math.abs(lp.Z) < halfL + z.radius and lp.Y < 14
end

-- Рывок/таран: наносит урон всем, кого задел
local function startCharge(z, targetPos, speed, duration, damage, knock)
	local pos = z.root.Position
	local dir = flatUnit(targetPos - pos, flatUnit(z.root.CFrame.LookVector))
	z.charge = { untilT = os.clock() + duration, damage = damage, knock = knock, hit = {}, dir = dir }
	z.humanoid.WalkSpeed = speed
	z.humanoid:MoveTo(pos + dir * (speed * duration + 10))
	z.model:SetAttribute("Attack", os.clock())
end

local function updateCharge(z, targets, busRoot)
	local c = z.charge
	local pos = z.root.Position
	for _, t in ipairs(targets) do
		if not c.hit[t.root] and (t.root.Position - pos).Magnitude < z.radius + t.radius + 4 then
			c.hit[t.root] = true
			local knock = flatUnit(t.root.Position - pos, c.dir) * c.knock + V3(0, 30, 0)
			damageTarget(t, c.damage * z.dmgMult, z, knock)
		end
	end
	if busRoot and not c.hitBus and busHull(busRoot, pos, z) then
		c.hitBus = true
		S.Bus.Damage(z.def.busDamage * z.dmgMult, { zombie = z })
	end
end

-- Способности элиты ----------------------------------------------------------------------

local function eliteThink(z, now, t, dist, step)
	local ab = z.def.ability
	if not ab then
		return false
	end
	local hum = z.humanoid
	local pos = z.root.Position
	local s = z.def.scale or 1

	-- отметка последнего попадания (для регенерации)
	if z.lastInfo ~= z.seenInfo then
		z.seenInfo = z.lastInfo
		z.lastHurt = now
	end
	if ab.regen and now - z.lastHurt > 4 and hum.Health < hum.MaxHealth then
		hum.Health = math.min(hum.MaxHealth, hum.Health + hum.MaxHealth * ab.regen * step)
	end

	if not t then
		return false
	end
	local kind = ab.kind

	if kind == "boulder" then
		if now >= z.nextAbility and dist >= ab.minRange and dist <= ab.range then
			z.nextAbility = now + ab.cooldown * rng:NextNumber(0.9, 1.2)
			z.model:SetAttribute("Throw", now)
			hum:MoveTo(pos)
			z.stunUntil = now + 0.95
			local target = t
			task.delay(0.6, function()
				if z.dead or not target.root.Parent then
					return
				end
				local p0 = z.root.Position
				local tp = target.root.Position
				local origin = p0 + V3(0, 3.2 * s, 0) + flatUnit(tp - p0) * 2 * s
				local vel, ft = ballistic(origin, tp, ab.speed, ab.gravity)
				local lead = Util.Flat(target.root.AssemblyLinearVelocity) * ft * 0.5
				local aim = groundAt(tp + lead)
				vel = ballistic(origin, aim, ab.speed, ab.gravity)
				local dmg = ab.damage * z.dmgMult
				S.Projectiles.Fire({
					kind = "boulder",
					origin = origin,
					velocity = vel,
					gravity = ab.gravity,
					zombieOwner = z,
					damage = 0,
					hitsPlayers = false,
					hitsZombies = false,
					maxTime = 5,
					onImpact = function(hitPos)
						impactBlast(hitPos, ab.radius, dmg, "slam", z)
					end,
				})
			end)
			return true
		end
	elseif kind == "bash" or kind == "dash" then
		if now >= z.nextAbility and dist >= ab.minRange and dist <= ab.range and not t.inBus then
			z.nextAbility = now + ab.cooldown * rng:NextNumber(0.9, 1.2)
			z.model:SetAttribute("Dash", now)
			local windup = ab.windup or 0.35
			hum:MoveTo(pos)
			z.stunUntil = now + windup
			local target = t
			task.delay(windup, function()
				if z.dead or not target.root.Parent or z.ragdollUntil then
					return
				end
				startCharge(z, target.root.Position, ab.speed, ab.duration, ab.damage, ab.knock)
			end)
			return true
		end
	elseif kind == "summon" then
		local maxAlive = math.floor(ab.maxAlive * math.min(1.5, ZS.CountMult()) + 0.5)
		if now >= z.nextAbility and dist <= ab.range and z.childCount < maxAlive then
			z.nextAbility = now + ab.cooldown * rng:NextNumber(0.9, 1.2)
			z.model:SetAttribute("Summon", now)
			hum:MoveTo(pos)
			z.stunUntil = now + 1.3
			Net.FireNear("Explosion", pos, 500, groundAt(pos), 16, "telegraph")
			local n = math.min(ab.count + (#Players:GetPlayers() - 1), maxAlive - z.childCount)
			task.delay(0.9, function()
				if z.dead then
					return
				end
				for _ = 1, n do
					spawnMinion(z, ab.zombie, 6, 16)
				end
			end)
			return true
		end
	elseif kind == "poison" then
		if now >= z.nextAbility and dist <= ab.range and dist > 6 then
			z.nextAbility = now + ab.cooldown * rng:NextNumber(0.9, 1.2)
			z.model:SetAttribute("Cast", now)
			local target = t
			local dmgMult = z.dmgMult
			task.delay(0.5, function()
				if z.dead or not target.root.Parent then
					return
				end
				local origin = z.head.Position + V3(0, 1.5, 0)
				local tp = target.root.Position
				local lead = Util.Flat(target.root.AssemblyLinearVelocity) * 0.6
				local vel = ballistic(origin, groundAt(tp + lead), ab.speed, ab.gravity)
				S.Projectiles.Fire({
					kind = "acid",
					origin = origin,
					velocity = vel,
					gravity = ab.gravity,
					zombieOwner = z,
					damage = 0,
					hitsPlayers = false,
					hitsZombies = false,
					maxTime = 4,
					onImpact = function(hitPos)
						poisonCloud(hitPos, ab, dmgMult, z)
					end,
				})
			end)
		end
		-- держит дистанцию, но отбивается вблизи
		if ab.keep and dist < ab.keep and dist > z.def.range + t.radius + 1.5 and not t.inBus then
			hum:MoveTo(pos - flatUnit(t.root.Position - pos) * 10)
			return true
		end
	elseif kind == "roar" then
		if now >= z.nextAbility and dist <= ab.range then
			z.nextAbility = now + ab.cooldown * rng:NextNumber(0.9, 1.2)
			z.model:SetAttribute("Roar", now)
			hum:MoveTo(pos)
			z.stunUntil = now + 1.4
			Net.FireNear("Explosion", pos, 500, groundAt(pos), ab.radius, "telegraph")
			local dmgMult = z.dmgMult
			task.delay(0.8, function()
				if z.dead then
					return
				end
				local p = z.root.Position
				Net.FireNear("Explosion", p, 500, groundAt(p), ab.radius, "slam")
				local effect = StatusEffects.List[ab.effect] and ab.effect or ab.fallbackEffect
				for _, plr in ipairs(Players:GetPlayers()) do
					local r = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
					if r and (r.Position - p).Magnitude <= ab.radius then
						local knock = flatUnit(r.Position - p) * 35 + V3(0, 15, 0)
						-- рёв сам накладывает свой эффект ниже, эффект биома не нужен
						S.Combat.DamagePlayer(plr, ab.damage * dmgMult, { zombie = z, kind = "zombie", knock = knock, biomeEffect = false })
						if effect then
							S.PlayerData.AddEffect(plr, effect, ab.effectTime)
						end
						S.PlayerData.Notify(plr, "Рёв великана оглушил вас!", rgb(170, 220, 255))
					end
				end
				damageEntitiesNear(p, ab.radius, ab.damage * dmgMult, z)
			end)
			return true
		end
	end
	return false
end

-- Босс «Кондуктор»: удар о землю, рывок, призыв пассажиров
local function bossThink(z, now, t, dist)
	local pos = z.root.Position
	local hum = z.humanoid
	local hpFrac = hum.Health / hum.MaxHealth
	local marks = { 0.66, 0.33 }
	if z.summoned < #marks and hpFrac <= marks[z.summoned + 1] then
		z.summoned = z.summoned + 1
		S.PlayerData.NotifyAll("Кондуктор: «Пассажиры, на выход!»", rgb(255, 200, 80))
		local n = math.floor((5 + z.summoned * 2) * math.min(1.5, ZS.CountMult()) + 0.5)
		for i = 1, n do
			-- миньоны только в свободных точках и не в автобусе/терминале (ревизия №9)
			spawnMinion(z, i % 3 == 0 and "runner" or "walker", 10, 22, { tag = "boss" })
		end
	end
	if t and now >= z.nextSlam and dist < 26 then
		z.nextSlam = now + 7
		z.model:SetAttribute("Slam", now)
		Net.FireNear("Explosion", pos, 500, groundAt(pos), 22, "telegraph")
		hum:MoveTo(pos)
		z.stunUntil = now + 1.3
		local dmgMult = scaleBase and scaleBase.damage or 1
		task.delay(1.1, function()
			if not z.dead then
				local p = z.root.Position
				S.Combat.Explode(V3(p.X, 1, p.Z), 22, 40 * dmgMult, { kind = "slam", hurtPlayers = true, hurtZombies = false, busMult = 0.3 })
				damageEntitiesNear(p, 22, 30 * dmgMult, z)
			end
		end)
		return true
	end
	if t and now >= z.nextCharge and dist > 25 and dist < 120 then
		z.nextCharge = now + 11
		startCharge(z, t.root.Position + flatUnit(t.root.Position - pos) * 20, 48, 1.4, 28, 70)
		return true
	end
	return false
end

-- Мародёр: стреляет очередями, если видит цель
local losParams = RaycastParams.new()
losParams.FilterType = Enum.RaycastFilterType.Exclude
losParams.IgnoreWater = true

local function hasLineOfSight(z, t)
	local origin = z.head.Position
	local target = t.root.Position
	local exclude = { folder, getFxFolder() }
	for _, name in ipairs({ "Loot", "Effects", "Placeables" }) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(exclude, f)
		end
	end
	losParams.FilterDescendantsInstances = exclude
	local result = workspace:Raycast(origin, target - origin, losParams)
	if not result then
		return true
	end
	local hit = result.Instance
	local targetModel = t.player and t.player.Character or t.root.Parent
	if targetModel and hit:IsDescendantOf(targetModel) then
		return true
	end
	if t.inBus and S.Bus.Model and hit:IsDescendantOf(S.Bus.Model) then
		return true
	end
	return false
end

local function shootBurst(z, t, r)
	z.model:SetAttribute("Attack", os.clock())
	local target = t
	task.spawn(function()
		local burst = r.burst or 1
		for i = 1, burst do
			if z.dead or not target.root.Parent or os.clock() < z.stunUntil then
				return
			end
			local s = z.def.scale or 1
			local origin = (z.root.CFrame * CFrame.new(0.9 * s, 0.5 * s, -2.2 * s)).Position
			local tp = target.root.Position
			local lead = Util.Flat(target.root.AssemblyLinearVelocity) * ((tp - origin).Magnitude / r.speed) * 0.5
			local delta = tp + lead - origin
			if delta.Magnitude < 0.5 then
				return
			end
			local dir = spreadDir(delta.Unit, r.spread)
			local entity = target.entity
			S.Projectiles.Fire({
				kind = r.kind or "bullet",
				origin = origin,
				velocity = dir * r.speed,
				gravity = 0,
				zombieOwner = z,
				damage = r.damage * z.dmgMult,
				hitsPlayers = true,
				hitsZombies = false,
				maxTime = r.range / r.speed + 0.6,
				onImpact = entity and function(hitPos)
					if entity.root and entity.root.Parent and (entity.root.Position - hitPos).Magnitude <= (entity.radius or 2) + 2.5 then
						local ok, err = pcall(entity.onDamage, r.damage * z.dmgMult, z)
						if not ok then
							warn("[Zombies] onDamage: " .. tostring(err))
						end
					end
				end or nil,
			})
			-- вспышку и звук выстрела клиент рисует сам при старте снаряда kind="bullet"
			if i < burst then
				task.wait(0.14)
			end
		end
	end)
end

-- Гнездо: рождает зомби, пока рядом игроки
local function nestThink(z, now, targets)
	local sp = z.def.spawn
	if not sp or now < z.nextSpawn then
		return
	end
	local mult = ZS.CountMult()
	z.nextSpawn = now + sp.interval * rng:NextNumber(0.85, 1.15) / math.clamp(math.sqrt(mult), 0.7, 1.5)
	local pos = z.root.Position
	local near = false
	for _, t in ipairs(targets) do
		if t.player and (t.root.Position - pos).Magnitude < sp.activateRadius then
			near = true
			break
		end
	end
	if not near and not z.aggro then
		return
	end
	local maxAlive = math.floor(sp.maxAlive * math.min(1.8, mult) + 0.5)
	local n = math.min(sp.perWave, maxAlive - z.childCount)
	if n <= 0 then
		return
	end
	z.model:SetAttribute("Attack", now)
	for _ = 1, n do
		spawnMinion(z, Util.Weighted(rng, sp.types), 6, 12, { tag = z.tag, home = pos, aggro = near, biome = z.biome })
	end
end

local function lightsSlow()
	local level = 0
	if S.Bus.GetLevel then
		level = S.Bus.GetLevel("lights") or 0
	elseif S.Bus.HasUpgrade("lights") then
		level = 1
	end
	return Upgrades.Value("lights", "slow", level, 0)
end

local function think(z, step, now, ctx)
	local hum, root = z.humanoid, z.root
	if not root.Parent or hum.Health <= 0 then
		return
	end
	local def = z.def
	local pos = root.Position
	local targets = ctx.targets
	local busRoot = ctx.busRoot

	-- время последнего попадания (награда за убийство только недавнему обидчику)
	if z.lastInfo ~= z.creditInfo then
		z.creditInfo = z.lastInfo
		z.lastHitAt = now
	end

	if pos.Y < -30 then
		if z.noDespawn or z.elite or def.boss or def.stationary then
			z.model:PivotTo(CFrame.new(z.spawnPos + V3(0, 4 * (def.scale or 1), 0)))
			return
		end
		ZS.Remove(z)
		return
	end

	if not (def.boss or z.tag or z.noDespawn or def.stationary) then
		local nearest = math.huge
		for _, t in ipairs(targets) do
			if t.player then
				local dd = (t.root.Position - pos).Magnitude
				if dd < nearest then
					nearest = dd
				end
			end
		end
		if busRoot then
			nearest = math.min(nearest, (busRoot.Position - pos).Magnitude)
		end
		if nearest > Config.Zombies.DespawnDistance then
			ZS.Remove(z)
			return
		end
	end

	if z.ragdollUntil then
		if now >= z.ragdollUntil then
			z.ragdollUntil = nil
			hum.PlatformStand = false
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		else
			return
		end
	end

	if z.burnUntil and now < z.burnUntil then
		z.burnTick = (z.burnTick or 0) + step
		if z.burnTick >= 0.5 then
			z.burnTick = 0
			S.Combat.DamageZombie(z, 4, { kind = "fire", attacker = z.burnAttacker })
			if z.dead then
				return
			end
		end
		if not z.fireFx then
			z.fireFx = Instance.new("Fire")
			z.fireFx.Size = 3 * (def.scale or 1)
			z.fireFx.Parent = z.torso
		end
	elseif z.fireFx then
		z.fireFx:Destroy()
		z.fireFx = nil
	end

	if def.stationary then
		nestThink(z, now, targets)
		return
	end

	if now < z.stunUntil then
		hum:MoveTo(pos)
		return
	end

	if z.charge then
		if now >= z.charge.untilT then
			z.charge = nil
		else
			updateCharge(z, targets, busRoot)
			return
		end
	end

	local speedMult = ctx.night and Config.Zombies.NightSpeedMult or 1
	if ctx.blood then
		speedMult = speedMult * EventDefs.Tuning.bloodMoonSpeedMult
	end
	if z.speedMult then
		speedMult = speedMult * z.speedMult
	end
	if ctx.night and ctx.lightsSlow > 0 and S.Bus.InHeadlights(pos) then
		speedMult = speedMult * (1 - ctx.lightsSlow)
	end
	if z.gaitSpeed then
		-- волочащие ногу медленнее, у остальных — небольшой разброс
		speedMult = speedMult * z.gaitSpeed
	end
	if z.typeId == "runner" and z.target then
		-- бегун: рывки и короткие передышки (в среднем чуть быстрее базовой скорости)
		if now >= (z.restEnd or 0) then
			z.burstEnd = now + rng:NextNumber(0.9, 1.5)
			z.restEnd = z.burstEnd + rng:NextNumber(0.6, 1.2)
			z.model:SetAttribute("Burst", now)
		end
		speedMult = speedMult * (now < (z.burstEnd or 0) and 1.32 or 0.72)
	end
	hum.WalkSpeed = def.speed * speedMult

	if now >= z.nextThink then
		z.nextThink = now + 0.35 + rng:NextNumber() * 0.25
		local aggroRange = ctx.night and Config.Zombies.NightAggroRange or Config.Zombies.AggroRange
		if z.home and not z.aggro then
			aggroRange = 55
			if def.ranged then
				aggroRange = math.max(aggroRange, def.ranged.range + 10)
			end
		elseif z.aggro then
			aggroRange = aggroRange * 1.8
		end
		if ctx.blood then
			aggroRange = aggroRange * 1.25
		end
		local best, bestScore = nil, math.huge
		for _, t in ipairs(targets) do
			local dd = (t.root.Position - pos).Magnitude
			if dd <= aggroRange then
				local score = dd / (t.priority or 1)
				if t.sleeping then
					score = score * 0.6 -- спящих чуют издалека
				end
				if t.downed then
					score = score * 1.5
				end
				if score < bestScore then
					best, bestScore = t, score
				end
			end
		end
		z.target = best
		if best then
			z.aggro = true
		end
	end

	local t = z.target
	if t and not t.root.Parent then
		t = nil
		z.target = nil
	end
	local dist = t and (t.root.Position - pos).Magnitude or math.huge

	if def.boss and bossThink(z, now, t, dist) then
		return
	end
	if def.ability and eliteThink(z, now, t, dist, step) then
		return
	end

	if not t then
		if z.alertPos then
			hum:MoveTo(z.alertPos)
			if (z.alertPos - pos).Magnitude < 8 then
				z.alertPos = nil
			end
		elseif z.home then
			if now >= (z.nextWander or 0) then
				z.nextWander = now + rng:NextNumber(2, 5)
				hum.WalkSpeed = def.speed * 0.35
				hum:MoveTo(z.home + V3(rng:NextNumber(-10, 10), 0, rng:NextNumber(-10, 10)))
			end
		elseif busRoot and (busRoot.Position - pos).Magnitude < 250 then
			hum:MoveTo(busRoot.Position)
		end
		return
	end

	local tpos = t.root.Position

	-- Цель внутри едущего автобуса — бьём по корпусу
	if busRoot and not def.human then
		-- снаружи автобуса нельзя достать находящихся внутри сквозь стену: только корпус
		-- (зомби, пролезший внутрь через дверь, бьёт пассажиров обычной атакой ниже)
		if t.inBus and busHull(busRoot, pos, z) and not S.Bus.IsInside(pos) then
			hum:MoveTo(busRoot.Position)
			if now >= z.nextAttack then
				z.nextAttack = now + def.cooldown
				z.model:SetAttribute("Attack", now)
				S.Bus.Damage(def.busDamage * z.dmgMult, { zombie = z })
			end
			return
		end
	end

	-- Дальняя атака: плевальщик (кислота) и мародёр (пули)
	local r = def.ranged
	if r then
		if dist <= r.range and dist > 8 and now >= z.nextRanged then
			if (r.kind or "acid") == "bullet" then
				if hasLineOfSight(z, t) then
					z.nextRanged = now + r.cooldown * rng:NextNumber(0.85, 1.25)
					shootBurst(z, t, r)
				else
					z.nextRanged = now + 0.6
					z.flankUntil = now + 1.5
				end
			else
				z.nextRanged = now + r.cooldown
				z.model:SetAttribute("Attack", now)
				local origin = z.head.Position + flatUnit(tpos - pos) * 1.5
				local gravity = r.gravity or 30
				local lead = t.root.AssemblyLinearVelocity * (dist / r.speed) * 0.6
				local vel = ballistic(origin, tpos + lead, r.speed, gravity)
				local entity = t.entity
				S.Projectiles.Fire({
					kind = r.kind or "acid",
					origin = origin,
					velocity = vel,
					gravity = gravity,
					zombieOwner = z,
					damage = r.damage * z.dmgMult,
					hitsPlayers = true,
					hitsZombies = false,
					maxTime = 3,
					onImpact = entity and function(hitPos)
						if entity.root and entity.root.Parent and (entity.root.Position - hitPos).Magnitude <= (entity.radius or 2) + 3 then
							pcall(entity.onDamage, r.damage * z.dmgMult, z)
						end
					end or nil,
				})
			end
		end
		local flanking = z.flankUntil and now < z.flankUntil
		if not flanking then
			if dist < r.keep then
				hum:MoveTo(pos - flatUnit(tpos - pos) * 10)
				return
			elseif dist <= r.range * 0.8 then
				if def.human then
					if now >= (z.nextStrafe or 0) then
						z.nextStrafe = now + rng:NextNumber(1.2, 2.6)
						local side = flatUnit(tpos - pos):Cross(Vector3.yAxis)
						hum:MoveTo(pos + side * rng:NextNumber(-12, 12))
					end
				else
					hum:MoveTo(pos)
				end
				return
			end
		end
	end

	-- Раздутый взрывается рядом с игроком
	local ex = def.explode
	if ex then
		if not z.fuseAt and dist <= ex.trigger then
			z.fuseAt = now + ex.fuse
			z.model:SetAttribute("Fuse", now)
		end
		if z.fuseAt and now >= z.fuseAt then
			z.exploded = true
			S.Combat.Explode(pos, ex.radius, ex.damage * z.dmgMult, { kind = "bloater", hurtPlayers = true, source = z })
			damageEntitiesNear(pos, ex.radius, ex.damage * z.dmgMult, z)
			hum.Health = 0
			return
		end
	end

	hum:MoveTo(tpos)

	local moved = (pos - z.lastPos).Magnitude
	z.lastPos = pos
	local stuck = false
	if dist > def.range + 2 and moved < 0.15 then
		z.stuckTime = z.stuckTime + step
		if z.stuckTime > 0.8 then
			z.stuckTime = 0
			hum.Jump = true
			stuck = true
		end
	else
		z.stuckTime = 0
	end

	local s = def.scale or 1
	-- Укрепления игроков на пути: бьём баррикаду
	if dist > def.range + t.radius and (stuck or now >= (z.nextPlaceCheck or 0)) then
		z.nextPlaceCheck = now + 0.6
		local placeable = S.Workbench.FindPlaceableNear(pos, stuck and 5 + 2 * s or 3 + 2 * s)
		if type(placeable) == "table" and type(placeable.Damage) == "function" then
			if typeof(placeable.position) == "Vector3" then
				hum:MoveTo(placeable.position)
			end
			z.placeUntil = now + 1.5
			z.placeable = placeable
		end
	end
	if z.placeable and z.placeUntil and now < z.placeUntil then
		if now >= z.nextAttack then
			z.nextAttack = now + def.cooldown
			z.model:SetAttribute("Attack", now)
			local placeable = z.placeable
			local amount = math.max(def.damage, def.busDamage or 0) * z.dmgMult * 1.5
			local ok, err = pcall(placeable.Damage, amount)
			if not ok then
				warn("[Zombies] placeable.Damage: " .. tostring(err))
				z.placeable = nil
			end
		end
		return
	end
	z.placeable = nil

	if dist <= def.range + t.radius and math.abs(tpos.Y - pos.Y) < 5 * s + 2 and now >= z.nextAttack and not (t.inBus and not S.Bus.IsInside(pos)) then
		z.nextAttack = now + def.cooldown
		z.model:SetAttribute("Attack", now)
		local target = t
		task.delay(0.28, function()
			if z.dead or not target.root.Parent then
				return
			end
			-- цель в автобусе, а зомби снаружи: сквозь стену не бьём
			if S.Bus.IsInside(target.root.Position) and not S.Bus.IsInside(z.root.Position) then
				return
			end
			local d2 = (target.root.Position - z.root.Position).Magnitude
			if d2 <= def.range + target.radius + 2 then
				local knock = nil
				if def.knockback then
					local dir = Util.Flat(target.root.Position - z.root.Position)
					if dir.Magnitude > 0.1 then
						knock = dir.Unit * def.knockback + V3(0, 20, 0)
					end
				end
				damageTarget(target, def.damage * z.dmgMult, z, knock)
			end
		end)
	end
end

local function countRoaming()
	local n = 0
	for _, z in pairs(active) do
		if not z.dead and not z.home and not z.tag and not z.minionOf and not z.def.stationary and not z.def.human and not z.elite then
			n = n + 1
		end
	end
	return n
end

local function roamingEliteAlive()
	for _, z in pairs(active) do
		if not z.dead and z.elite and not z.tag and not z.noDespawn then
			return true
		end
	end
	return false
end

local nextRoamingElite = 0

-- Опасные типы в начале пути встречаются реже: вес растёт с долей пути до полного к ~40 км
local RAMP_TYPES = { brute = 0.2, bloater = 0.35, spitter = 0.45, runner = 0.6 }

local function pickRoamingType(biome, progress)
	local list = biome.zombies
	local k = math.clamp(progress * 2.5, 0, 1)
	local weighted = {}
	for i, e in ipairs(list) do
		local base = RAMP_TYPES[e[1]]
		local w = e[2]
		if base then
			w = w * (base + (1 - base) * k)
		end
		weighted[i] = { e[1], w }
	end
	return Util.Weighted(rng, weighted) or "walker"
end

function ZS.SpawnTick(night)
	local state = S.Run.State
	if state ~= "Driving" then
		return
	end
	local busRoot = S.Bus.Root
	if not busRoot then
		return
	end
	local busS = S.Bus.S or 0
	-- первые SpawnGraceKm км после депо — без случайных зомби
	if busS < Config.DepotLength + (Config.Zombies.SpawnGraceKm or 1.2) * Config.StudsPerKm then
		return
	end
	if S.Stations.IsNearStation(busS, 260) then
		return
	end
	local biome = S.World.BiomeAtS(busS)
	local nPlayers = math.max(1, #Players:GetPlayers())
	local countMult = ZS.CountMult()
	local km = busS / Config.StudsPerKm
	local desired = ZS.DesiredRoaming(km, night, biome, nPlayers)
	local allowed = math.max(1, math.floor(desired + 0.5))
	local current = countRoaming()
	if current >= allowed then
		return
	end
	local busCF = busRoot.CFrame
	local speed = S.Bus.V or 0
	local moving = speed > 10
	local gLo, gHi = ZS.GroupRange(km)
	local group = math.min(rng:NextInteger(gLo, gHi), allowed - current)
	local progress = ZS.Progress(km)
	local baseAngle
	if moving and rng:NextNumber() < 0.75 then
		baseAngle = rng:NextNumber(-1.0, 1.0)
	else
		baseAngle = rng:NextNumber(0, TWO_PI)
	end
	local dist = rng:NextNumber(Config.Zombies.SpawnMin, Config.Zombies.SpawnMax) + (moving and speed * 1.5 or 0)
	local dir = (busCF * CFrame.Angles(0, baseAngle, 0)).LookVector
	local flatDir = Util.Flat(dir)
	if flatDir.Magnitude < 0.1 then
		return
	end
	local center = Util.Flat(busCF.Position) + flatDir.Unit * dist
	for _ = 1, group do
		local p = center + V3(rng:NextNumber(-8, 8), 0, rng:NextNumber(-8, 8))
		if isSpotFree(p.X, p.Z, 3) then
			local typeId = pickRoamingType(biome, progress)
			if night and rng:NextNumber() < 0.1 + 0.15 * progress then
				typeId = "runner"
			end
			ZS.Spawn(typeId, p, { biome = biome })
		end
	end

	-- Редкая бродячая элита биома (чаще к концу маршрута)
	local now = os.clock()
	if km > 8 and now >= nextRoamingElite and rng:NextNumber() < 0.015 * countMult * ZS.ProgressFactor(km) then
		nextRoamingElite = now + 360
		local eliteId = ZombieDefs.BiomeElite[biome.id]
		local eliteDef = eliteId and ZombieDefs.Types[eliteId]
		if eliteDef and not roamingEliteAlive() and isSpotFree(center.X, center.Z, 4) then
			if ZS.Spawn(eliteId, center, { biome = biome }) then
				S.PlayerData.NotifyAll("Где-то рядом бродит элита: " .. eliteDef.name .. "!", PURPLE)
			end
		end
	end
end

local thinkAcc = 0
local spawnAcc = 0
local poiAcc = 0
local threatAcc = 0
local lastThreat = nil

function ZS.Update(dt)
	thinkAcc = thinkAcc + dt
	if thinkAcc < 1 / Config.Zombies.UpdateRate then
		return
	end
	local step = thinkAcc
	thinkAcc = 0
	local now = os.clock()
	local night = S.DayNight.IsNight()
	local targets = gatherTargets()
	local busRoot = S.Bus.Root
	if busRoot and not busRoot.Parent then
		busRoot = nil
	end
	local ctx = {
		targets = targets,
		night = night,
		busRoot = busRoot,
		blood = bloodMoon(),
		lightsSlow = night and busRoot and lightsSlow() or 0,
	}

	threatAcc = threatAcc + step
	if threatAcc >= 1 then
		threatAcc = 0
		local threat = getScale().threat
		if threat ~= lastThreat then
			lastThreat = threat
			Net.State():SetAttribute("ThreatLevel", threat)
		end
	end

	local current = ZS.List()
	for i = 1, #current do
		local z = current[i]
		if not z.dead then
			think(z, step, now, ctx)
		end
	end

	spawnAcc = spawnAcc + step
	if spawnAcc >= Config.Zombies.SpawnInterval then
		spawnAcc = 0
		ZS.SpawnTick(night)
	end

	poiAcc = poiAcc + step
	if poiAcc >= 0.8 then
		poiAcc = 0
		local poiAlive = 0
		for _, z in ipairs(ZS.List()) do
			if not z.dead then
				poiAlive = poiAlive + 1
			end
		end
		local cz = Config.Zombies
		for _, lst in pairs(spawners) do
			for i = #lst, 1, -1 do
				local sp = lst[i]
				for _, t in ipairs(targets) do
					if t.player and Util.FlatDist(t.root.Position, sp.pos) < cz.POIActivateRadius then
						local progress = ZS.Progress(sp.km)
						-- v5: общий потолок живых зомби (растёт с долей пути) — здание подождёт, пока станет тише
						local capStart, capLate = cz.AliveCapStart or 12, cz.AliveCapLate or 38
						if poiAlive >= capStart + (capLate - capStart) * progress then
							break
						end
						-- v5: зомби есть не в каждом здании — шанс растёт от POIChanceStart к POIChanceLate
						local chanceStart, chanceLate = cz.POIChanceStart or 1, cz.POIChanceLate or 1
						local count = 0
						if rng:NextNumber() < chanceStart + (chanceLate - chanceStart) * progress then
							-- число зомби в здании: POICountStart → POICountLate по доле пути (× сложность)
							local lo, hi = ZS.POIRange(sp.km)
							count = math.max(1, math.floor(rng:NextInteger(lo, hi) * ZS.CountMult() + 0.5))
						end
						poiAlive = poiAlive + count
						for _ = 1, count do
							local p = sp.pos + V3(rng:NextNumber(-6, 6), 0, rng:NextNumber(-6, 6))
							if not busBlocks(p.X, p.Z, 2) then
								ZS.Spawn(pickRoamingType(sp.biome, progress), p, { biome = sp.biome, home = sp.pos })
							end
						end
						if sp.key ~= nil and S.World.MarkSpawnerUsed then
							S.World.MarkSpawnerUsed(sp.key)
						end
						table.remove(lst, i)
						break
					end
				end
			end
		end
	end
end

return ZS
