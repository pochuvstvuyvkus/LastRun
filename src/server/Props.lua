-- Наполнение мира в мрачном стиле: земля и дорога, стены границ, депо-городок, здания с деталями,
-- сосны, мусор на дороге (таранится), редкие разбиваемые завалы. Модели из Toolbox — через AssetLibrary.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Net = require(Shared.Net)
local AssetLibrary = require(script.Parent:WaitForChild("AssetLibrary"))

local Props = {}
local S

local rgb = Color3.fromRGB
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local rad = math.rad
local M = Enum.Material
local CYL = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball
local NIGHT_TAG = "LR_NightLight"
-- Счётчик созданных деталей чанка (учитывает и добычу, и модели из библиотеки): чанк держит бюджет
-- ≤ 500 деталей вместе со станцией, необязательный декор упрощается или пропускается
local CHUNK_BUDGET = 476
local STATION_BUDGET = 330 -- в чанке со станцией её постройки добавятся сверху
local made = 0

local SPK = Config.StudsPerKm
local RHW = Config.RoadHalfWidth
local HW = Config.Bounds.HalfWidth
local WT = Config.Bounds.WallThickness

-- Зона депо: до DEPOT_END обычный декор биома не ставится (там свой лес, забор и тоннель)
local DEPOT_END = 640

-- Палитра
local C = {
	brick = rgb(92, 52, 42),
	brickDark = rgb(66, 40, 34),
	tile = rgb(128, 130, 126),
	tileSeam = rgb(70, 72, 70),
	concrete = rgb(104, 104, 100),
	concreteDark = rgb(74, 74, 72),
	rust = rgb(150, 90, 40),
	rustDark = rgb(96, 60, 34),
	metal = rgb(70, 72, 76),
	metalDark = rgb(40, 42, 46),
	glass = rgb(24, 30, 36),
	asphalt = rgb(44, 44, 46),
	curb = rgb(112, 112, 108),
	pine = rgb(30, 42, 34),
	pineLight = rgb(40, 54, 42),
	bark = rgb(48, 38, 32),
	wood = rgb(92, 72, 52),
	neonGreen = rgb(80, 255, 120),
	neonOrange = rgb(255, 160, 60),
	neonYellow = rgb(255, 210, 90),
	-- дерево, листва, снег, заборы
	barkPale = rgb(126, 116, 100),
	barkBurnt = rgb(26, 24, 22),
	leaf = rgb(52, 76, 42),
	leafDark = rgb(34, 54, 32),
	leafDry = rgb(112, 102, 62),
	birch = rgb(198, 194, 182),
	snow = rgb(228, 234, 242),
	plaster = rgb(148, 140, 126),
	fenceWood = rgb(96, 78, 58),
	fencePaint = rgb(176, 170, 152),
	mesh = rgb(132, 136, 138),
}
Props.Colors = C

function Props.Init(services)
	S = services
end

-- Базовые детали --------------------------------------------------------------------
local function mk(parent, size, cf, color, material, extra)
	local p = Instance.new("Part")
	made = made + 1
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or M.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CollisionGroup = "World"
	if extra then
		for k, v in pairs(extra) do
			p[k] = v
		end
	end
	p.Parent = parent
	return p
end

local function noCollide(p)
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	return p
end

local function deco(parent, size, cf, color, material, extra)
	return noCollide(mk(parent, size, cf, color, material, extra))
end

local function mkShape(parent, shape, size, cf, color, material, collide)
	local p = Instance.new("Part")
	made = made + 1
	p.Shape = shape
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or M.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CollisionGroup = "World"
	if collide == false then
		noCollide(p)
	end
	p.Parent = parent
	return p
end

-- вертикальный цилиндр с центром в cf
local function vcyl(parent, height, diameter, cf, color, material, collide)
	return mkShape(parent, CYL, V3(height, diameter, diameter), cf * ANG(0, 0, rad(90)), color, material, collide)
end

-- цилиндр вдоль локальной X
local function hcyl(parent, length, diameter, cf, color, material, collide)
	return mkShape(parent, CYL, V3(length, diameter, diameter), cf, color, material, collide)
end

local function ball(parent, diameter, cf, color, material, collide)
	return mkShape(parent, BALL, V3(diameter, diameter, diameter), cf, color, material, collide)
end

-- Клин: скат смотрит вперёд (−Z), вертикальная грань сзади (+Z)
local function wedge(parent, size, cf, color, material, collide)
	local p = Instance.new("WedgePart")
	made = made + 1
	p.Anchored = true
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or M.SmoothPlastic
	p.CollisionGroup = "World"
	if collide == false then
		noCollide(p)
	end
	p.Parent = parent
	return p
end

-- Треугольная призма: основание width (по локальной Z), высота height, толщина thick (по X); низ в cf
local function prism(parent, cf, width, height, thick, color, material, collide)
	local half = width / 2
	wedge(parent, V3(thick, height, half), cf * CF(0, height / 2, -half / 2), color, material, collide)
	wedge(parent, V3(thick, height, half), cf * CF(0, height / 2, half / 2) * ANG(0, math.pi, 0), color, material, collide)
end

local function model(parent, name)
	local m = Instance.new("Model")
	m.Name = name
	m.Parent = parent
	return m
end

local function lightAt(part, range, brightness, color, shadows)
	local l = Instance.new("PointLight")
	l.Range = range
	l.Brightness = brightness
	l.Color = color or rgb(255, 225, 180)
	l.Shadows = shadows == true
	l.Parent = part
	return l
end

-- Ночной свет: лампа (Neon + свет) днём гаснет, DayNight включает её ночью. Тег ставится после настройки.
local function nightLamp(part, offColor, offMaterial)
	if offColor then
		part:SetAttribute("NightOffColor", offColor)
	end
	if offMaterial then
		part:SetAttribute("NightOffMaterial", offMaterial)
	end
	CollectionService:AddTag(part, NIGHT_TAG)
	return part
end

-- Провод с провисом между точками мира a и b (Beam без текстуры; крепления — в детали holder)
local function wire(holder, a, b, sag, color, width)
	local flat = V3(b.X - a.X, 0, b.Z - a.Z)
	if flat.Magnitude < 0.1 then
		flat = V3(1, 0, 0)
	end
	local down = holder.CFrame:VectorToObjectSpace(V3(0, -1, 0))
	local side = holder.CFrame:VectorToObjectSpace(flat.Unit)
	local function att(p)
		local at = Instance.new("Attachment")
		at.CFrame = CFrame.fromMatrix(holder.CFrame:PointToObjectSpace(p), down, side)
		at.Parent = holder
		return at
	end
	local beam = Instance.new("Beam")
	beam.Attachment0 = att(a)
	beam.Attachment1 = att(b)
	beam.CurveSize0 = sag / 0.75
	beam.CurveSize1 = -sag / 0.75
	beam.Width0 = width or 0.09
	beam.Width1 = width or 0.09
	beam.Color = ColorSequence.new(color or rgb(26, 26, 28))
	beam.Transparency = NumberSequence.new(0)
	beam.Segments = 10
	beam.FaceCamera = true
	beam.LightInfluence = 1
	beam.Parent = holder
	return beam
end

-- Бюджет деталей чанка: хватит ли места ещё на need деталей
local function budget(c, need)
	if not c or not c.startMade then
		return true
	end
	return (made - c.startMade) + (need or 0) <= (c.budget or CHUNK_BUDGET)
end

-- То же, но с запасом: reserve деталей оставляем следующим этапам (растительности, мелочи)
local function afford(c, need, reserve)
	return budget(c, (need or 0) + (reserve or 0))
end

-- Детали, созданные не через mk (добыча LootService, модели из библиотеки): считаем по факту
local function countParts(inst)
	local n = 0
	if inst then
		if inst:IsA("BasePart") then
			n = 1
		end
		for _, d in ipairs(inst:GetDescendants()) do
			if d:IsA("BasePart") then
				n = n + 1
			end
		end
	end
	return n
end

-- Вызов чужой функции (добыча), которая складывает детали в parent: их тоже записываем в бюджет
local function counted(parent, fn, ...)
	local before = countParts(parent)
	local result = fn(...)
	made = made + math.max(0, countParts(parent) - before)
	return result
end

-- Лестница-ферма (лазается игроком); размер по высоте кратен 2
local function truss(parent, cf, height, color)
	local t = Instance.new("TrussPart")
	made = made + 1
	t.Anchored = true
	t.Size = V3(2, math.max(2, math.floor((height or 6) / 2 + 0.5) * 2), 2)
	t.CFrame = cf * CF(0, t.Size.Y / 2, 0)
	t.Color = color or C.metal
	t.Material = M.Metal
	t.CollisionGroup = "World"
	t.Parent = parent
	return t
end

-- Надпись на грани детали. glow — неон (не зависит от освещения, светится через bloom)
local function signText(part, text, color, face, glow, font)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face or Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 25
	gui.LightInfluence = glow and 0 or 1
	if glow then
		gui.Brightness = 2.5
	end
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = font or Enum.Font.GothamBlack
	label.TextColor3 = color
	label.Text = text
	if glow then
		label.TextStrokeColor3 = color:Lerp(rgb(255, 255, 255), 0.35)
		label.TextStrokeTransparency = 0.55
	end
	label.Parent = gui
	gui.Parent = part
	return gui
end

-- Сетка швов (плитка) на грани детали: cols × rows линий
local function seamGrid(part, face, cols, rows, color, transparency)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face or Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 8
	gui.LightInfluence = 1
	for i = 1, cols - 1 do
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.BackgroundColor3 = color
		f.BackgroundTransparency = transparency or 0.25
		f.AnchorPoint = Vector2.new(0.5, 0)
		f.Position = UDim2.fromScale(i / cols, 0)
		f.Size = UDim2.new(0, 1, 1, 0)
		f.Parent = gui
	end
	for j = 1, rows - 1 do
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.BackgroundColor3 = color
		f.BackgroundTransparency = transparency or 0.25
		f.AnchorPoint = Vector2.new(0, 0.5)
		f.Position = UDim2.fromScale(0, j / rows)
		f.Size = UDim2.new(1, 0, 0, 1)
		f.Parent = gui
	end
	gui.Parent = part
	return gui
end

-- Окна верхних этажей рисуются на фасаде (без лишних деталей):
-- ряды rows × cols, у каждого окна тёмное стекло, светлая рама и перекрестье
local function windowGui(part, face, cols, rows, frameColor, litChance, rng)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face or Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 6
	gui.LightInfluence = 1
	for r = 1, rows do
		for col = 1, cols do
			local w = Instance.new("Frame")
			w.AnchorPoint = Vector2.new(0.5, 0.5)
			w.Position = UDim2.fromScale((col - 0.5) / cols, (r - 0.5) / rows)
			w.Size = UDim2.fromScale(0.5 / cols, 0.55 / rows)
			local lit = rng and litChance and rng:NextNumber() < litChance
			w.BackgroundColor3 = lit and rgb(150, 120, 70) or rgb(20, 24, 30)
			w.BorderSizePixel = 2
			w.BorderColor3 = frameColor
			w.Parent = gui
			local v = Instance.new("Frame")
			v.BorderSizePixel = 0
			v.BackgroundColor3 = frameColor
			v.AnchorPoint = Vector2.new(0.5, 0)
			v.Position = UDim2.fromScale(0.5, 0)
			v.Size = UDim2.new(0, 2, 1, 0)
			v.Parent = w
			local h = Instance.new("Frame")
			h.BorderSizePixel = 0
			h.BackgroundColor3 = frameColor
			h.AnchorPoint = Vector2.new(0, 0.5)
			h.Position = UDim2.fromScale(0, 0.4)
			h.Size = UDim2.new(1, 0, 0, 2)
			h.Parent = w
		end
	end
	gui.Parent = part
	return gui
end

-- Светящиеся ночью окна поверх нарисованных: отдельный SurfaceGui с тегом LR_NightLight
local function nightWindows(part, face, cols, rows, chance, rng)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face or Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 6
	gui.LightInfluence = 0
	gui.Brightness = 1.3
	gui.ZOffset = 1
	gui.MaxDistance = 700
	local any = false
	for r = 1, rows do
		for col = 1, cols do
			if rng:NextNumber() < chance then
				any = true
				local w = Instance.new("Frame")
				w.AnchorPoint = Vector2.new(0.5, 0.5)
				w.Position = UDim2.fromScale((col - 0.5) / cols, (r - 0.5) / rows)
				w.Size = UDim2.fromScale(0.44 / cols, 0.5 / rows)
				w.BorderSizePixel = 0
				w.BackgroundColor3 = rng:NextNumber() < 0.75 and rgb(255, 196, 120) or rgb(170, 200, 255)
				w.BackgroundTransparency = rng:NextNumber(0.05, 0.35)
				w.Parent = gui
			end
		end
	end
	if not any then
		gui:Destroy()
		return nil
	end
	CollectionService:AddTag(gui, NIGHT_TAG)
	gui.Parent = part
	return gui
end

local GRAFFITI = { "ВЫХОДА НЕТ", "БЕГИ", "МЫ ЗДЕСЬ БЫЛИ", "ЖИВЫЕ ВНУТРИ?", "КАРАНТИН", "НЕ ШУМИ" }
local GRAFFITI_COLORS = { rgb(190, 40, 34), rgb(230, 226, 214), rgb(90, 170, 90), rgb(240, 180, 60) }

-- Метка объекта в мире (рисует клиент D)
local function waypoint(inst, label, color, maxDistance)
	if not inst then
		return
	end
	inst:SetAttribute("WaypointLabel", label)
	if color then
		inst:SetAttribute("WaypointColor", color)
	end
	inst:SetAttribute("WaypointMaxDistance", maxDistance or 90)
	CollectionService:AddTag(inst, "LR_Waypoint")
end

-- Неоновая трубка-контур: наклонный параллелограмм w × h, наклон skew (studs), в плоскости XY cf
local function neonOutline(parent, cf, w, h, skew, color, thick)
	thick = thick or 0.22
	local list = {}
	table.insert(list, deco(parent, V3(w, thick, thick), cf * CF(skew / 2, h / 2, 0), color, M.Neon))
	table.insert(list, deco(parent, V3(w, thick, thick), cf * CF(-skew / 2, -h / 2, 0), color, M.Neon))
	local sideLen = math.sqrt(h * h + skew * skew)
	local ang = math.atan2(skew, h)
	for _, x in ipairs({ -w / 2, w / 2 }) do
		table.insert(list, deco(parent, V3(thick, sideLen, thick), cf * CF(x, 0, 0) * ANG(0, 0, -ang), color, M.Neon))
	end
	return list
end

-- Координаты дороги ------------------------------------------------------------------
local function roadCF(s, d, yaw)
	local pos, tangent, right = S.World.Road:Frame(s)
	local p = pos + right * (d or 0)
	local cf = CFrame.lookAt(p, p + tangent)
	if yaw then
		cf = cf * ANG(0, yaw, 0)
	end
	return cf
end

-- CFrame в точке (s, d), передом (−Z) к дороге
local function facingRoad(s, d)
	local road = S.World.Road
	local pos = road:ToWorld(s, d)
	local target = road:ToWorld(s, 0)
	if math.abs(d) < 0.5 then
		return roadCF(s, 0)
	end
	return CFrame.lookAt(pos, V3(target.X, pos.Y, target.Z))
end

local function finalS()
	return S.World.FinalS or (Config.RouteKm * SPK)
end

-- Депо, станции и конечная — там обычный декор не ставим
local function reserved(s, margin)
	margin = margin or 0
	if s < DEPOT_END + margin then
		return true
	end
	for _, st in ipairs(Config.Stations) do
		if math.abs(s - st.km * SPK) < 180 + margin then
			return true
		end
	end
	return s > finalS() - 230 - margin
end

local function randSide(rng)
	return rng:NextNumber() < 0.5 and -1 or 1
end

-- Стабильные ключи и сиды по позиции: содержимое здания не зависит от порядка генерации
local function hashSeed(text)
	local h = (tonumber(S.World.Seed) or 1) % 999983 + 7
	for i = 1, #text do
		h = (h * 131 + string.byte(text, i)) % 2147483629
	end
	return h
end

local function posKey(prefix, pos)
	return prefix .. math.floor(pos.X + 0.5) .. "_" .. math.floor(pos.Z + 0.5)
end

-- Размещение объектов в чанке --------------------------------------------------------
local function footprint(cf, hx, hz)
	local look = cf.LookVector
	local fx, fz = look.X, look.Z
	local len = math.sqrt(fx * fx + fz * fz)
	if len < 0.01 then
		fx, fz, len = 0, -1, 1
	end
	return { x = cf.X, z = cf.Z, fx = fx / len, fz = fz / len, hx = hx, hz = hz }
end

local function overlaps(a, b, pad)
	pad = pad or 0
	local dx, dz = b.x - a.x, b.z - a.z
	local reach = a.hx + a.hz + b.hx + b.hz + pad
	if dx * dx + dz * dz > reach * reach then
		return false
	end
	local axes = { a.fx, a.fz, -a.fz, a.fx, b.fx, b.fz, -b.fz, b.fx }
	for i = 1, 7, 2 do
		local ux, uz = axes[i], axes[i + 1]
		local dist = math.abs(dx * ux + dz * uz)
		local pa = a.hz * math.abs(a.fx * ux + a.fz * uz) + a.hx * math.abs(a.fz * ux - a.fx * uz)
		local pb = b.hz * math.abs(b.fx * ux + b.fz * uz) + b.hx * math.abs(b.fz * ux - b.fx * uz)
		if dist >= pa + pb + pad then
			return false
		end
	end
	return true
end

-- Протяжённость площадки поперёк дороги в точке s
local function lateral(fp, s)
	local _, _, r = S.World.Road:Frame(s)
	local rx, rz = -fp.fz, fp.fx
	return fp.hx * math.abs(rx * r.X + rz * r.Z) + fp.hz * math.abs(fp.fx * r.X + fp.fz * r.Z)
end

-- Крупный объект целиком внутри своего чанка и внутри границ (детерминированно, без соседей)
local CORNERS = { { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
local function insideChunk(c, fp, sHint)
	local road = S.World.Road
	local rx, rz = -fp.fz, fp.fx
	for _, k in ipairs(CORNERS) do
		local px = fp.x + rx * fp.hx * k[1] + fp.fx * fp.hz * k[2]
		local pz = fp.z + rz * fp.hx * k[1] + fp.fz * fp.hz * k[2]
		local s, d = road:Project(V3(px, 0, pz), sHint, 320)
		if s < c.s0 + 0.5 or s > c.s1 - 0.5 or math.abs(d) > HW - 6 then
			return false
		end
	end
	return true
end

-- Проверка и занятие места.
-- opts: s, d — центр площадки; road — может стоять на асфальте; loose — без проверки пересечений;
-- noClaim — не занимать место; pad; depot — разрешено в зоне депо
local function tryPlace(c, cf, hx, hz, opts)
	local s, d = opts.s, opts.d
	if not opts.depot and reserved(s) then
		return nil
	end
	local fp = footprint(cf, hx, hz)
	local lat = lateral(fp, s)
	if not opts.road and math.abs(d) - lat < RHW + 1.5 then
		return nil
	end
	if math.abs(d) + lat > HW - 4 then
		return nil
	end
	if (hx >= 5 or hz >= 5) and not insideChunk(c, fp, s) then
		return nil
	end
	if S.World.IsReserved(V3(fp.x, 0, fp.z), math.max(hx, hz)) then
		return nil
	end
	if not opts.loose then
		for _, o in ipairs(c.occ) do
			if overlaps(o, fp, opts.pad) then
				return nil
			end
		end
	end
	if not opts.noClaim then
		table.insert(c.occ, fp)
	end
	return fp
end

-- Небольшой объект радиуса r в точке (s, d)
local function spot(c, s, d, r, yaw, opts)
	local cf = roadCF(s, d, yaw)
	local o = { s = s, d = d }
	if opts then
		for k, v in pairs(opts) do
			o[k] = v
		end
	end
	if tryPlace(c, cf, r, r, o) then
		return cf
	end
	return nil
end

-- Препятствия (для проверок спавна зомби/добычи; автобус касается только того, что на дороге)
local function circle(c, cf, r, hard, m, extra)
	local ob = extra or {}
	ob.hard = hard
	ob.model = m
	return S.Obstacles.AddCircle(c.ci, cf.X, cf.Z, r, ob)
end

local function box(c, cf, hx, hz, hard, m, extra)
	local ob = extra or {}
	ob.hard = hard
	ob.model = m
	return S.Obstacles.AddBox(c.ci, cf, hx, hz, ob)
end

local function addSpawner(c, pos, count, key)
	if S.World.IsSpawnerUsed(key) then
		return
	end
	S.Zombies.AddSpawner(c.ci, pos, count, c.biome, key)
end

local function zombieCount(c, rng)
	return rng:NextInteger(2, 4) + math.floor(((c.s0 or 0) / SPK) / 35)
end

-- Полосы на земле вдоль дороги (тротуары, улицы), следующие изгибам
local function strip(parent, sA, sB, d, width, color, material, y, thick, collide)
	local road = S.World.Road
	local pieces = math.max(1, math.ceil((sB - sA) / 40))
	local step = (sB - sA) / pieces
	thick = thick or 0.1
	for i = 0, pieces - 1 do
		local a = sA + i * step
		local _, _, _, ha = road:Frame(a)
		local _, _, _, hb = road:Frame(a + step)
		local len = step + (math.abs(d) + width / 2) * math.abs(hb - ha) + 0.2
		local cf = roadCF(a + step / 2, d) * CF(0, (y or 0.06) - thick / 2 + (i % 2) * 0.005, 0)
		if collide then
			mk(parent, V3(width, thick, len), cf, color, material)
		else
			deco(parent, V3(width, thick, len), cf, color, material)
		end
	end
end

-- Модель из библиотеки (если есть), иначе nil. Детали модели идут в бюджет чанка.
local function fromLibrary(category, cf, rng, parent, variant)
	if variant and AssetLibrary.HasVariant(category, variant) then
		local m, r = AssetLibrary.Spawn(category, cf, rng, parent, variant)
		if m then
			made = made + countParts(m)
			return m, r
		end
	end
	if AssetLibrary.Has(category) then
		local m, r = AssetLibrary.Spawn(category, cf, rng, parent)
		if m then
			made = made + countParts(m)
			return m, r
		end
	end
	return nil
end

-- Объекты ------------------------------------------------------------------------------------

-- Деревья ---------------------------------------------------------------------------------------
-- Уровень детализации по удалению от дороги: 3 — у обочины, 2 — средний план, 1 — дальний (в тумане)
local function lodFor(d)
	local ad = math.abs(d or 0)
	if ad < 82 then
		return 3
	elseif ad < 165 then
		return 2
	end
	return 1
end

-- Сужающийся ствол из двух сегментов с лёгким изломом и наклоном.
-- Возвращает frameAt(y) — система координат ствола на высоте y (учитывает наклон).
local function trunkOf(parent, cf, h, dia, color, rng, lod, lean, material)
	local base = cf * CF(0, -0.35, 0) * ANG(0, rng:NextNumber(0, math.pi * 2), 0) * ANG(lean or 0, 0, 0)
	local mat = material or M.Wood
	if lod >= 2 then
		local h1 = h * rng:NextNumber(0.45, 0.6)
		vcyl(parent, h1 + 0.4, dia, base * CF(0, h1 / 2, 0), color, mat)
		local upper = base * CF(0, h1, 0) * ANG(rng:NextNumber(-0.04, 0.04), 0, rng:NextNumber(-0.04, 0.04))
		vcyl(parent, h - h1 + 0.3, dia * 0.66, upper * CF(0, (h - h1) / 2, 0), color, mat)
		return function(y)
			if y <= h1 then
				return base * CF(0, y, 0)
			end
			return upper * CF(0, y - h1, 0)
		end
	end
	vcyl(parent, h + 0.4, dia * 0.82, base * CF(0, h / 2, 0), color, mat)
	return function(y)
		return base * CF(0, y, 0)
	end
end

-- Хвойное дерево: ярусы-«юбки» из клиньев (толстый край у ствола, тонкий опущенный наружу),
-- у каждого яруса свой поворот и неровный наклон. o: lod, snow, burnt, sparse (высокая голая), dense (ель).
local function pineTree(parent, cf, h, rng, o)
	o = o or {}
	local lod = o.lod or 3
	local m = model(parent, o.name or "Pine")
	local dia = math.max(0.55, h * (o.sparse and 0.021 or 0.026))
	local bark = o.burnt and C.barkBurnt or (o.bark or C.bark)
	local frameAt = trunkOf(m, cf, h * 0.95, dia, bark, rng, lod, rng:NextNumber(0, o.sparse and 0.03 or 0.05))
	local tiers = 2
	if lod == 3 then
		tiers = o.sparse and rng:NextInteger(6, 7) or rng:NextInteger(5, 6)
	elseif lod == 2 then
		tiers = 4
	end
	if o.burnt then
		tiers = math.max(2, tiers - 2)
	end
	local y0 = h * (o.dense and 0.14 or (o.sparse and rng:NextNumber(0.48, 0.6) or (o.burnt and 0.5 or rng:NextNumber(0.26, 0.36))))
	local span = h * 0.95 - y0
	local reach0 = h * (o.sparse and rng:NextNumber(0.1, 0.14) or rng:NextNumber(0.17, 0.22)) * (o.dense and 1.2 or 1)
	local leaf = o.burnt and rgb(34, 32, 30) or C.pine:Lerp(C.pineLight, rng:NextNumber())
	local yaw0 = rng:NextNumber(0, math.pi * 2)
	for i = 0, tiers - 1 do
		local f = tiers > 1 and i / (tiers - 1) or 0
		local y = y0 + span * f
		local reach = reach0 * (1 - 0.72 * f) * rng:NextNumber(0.85, 1.12)
		local thick = reach * (o.sparse and 0.5 or 0.68) + 0.35
		local wedges = (lod == 3 and i < 2 and not o.sparse and not o.burnt) and 3 or 2
		local color = leaf:Lerp(rgb(0, 0, 0), rng:NextNumber(0, 0.12))
		if o.snow then
			color = color:Lerp(C.snow, 0.1 + 0.28 * f)
		end
		local tier = frameAt(y) * ANG(0, yaw0 + i * 2.39, 0) * ANG(rng:NextNumber(-0.08, 0.08), 0, rng:NextNumber(-0.08, 0.08))
		for kk = 0, wedges - 1 do
			local a = kk * (math.pi * 2 / wedges) + rng:NextNumber(-0.22, 0.22)
			local len = reach * rng:NextNumber(0.82, 1.1)
			local width = len * (wedges == 3 and 1.05 or 0.8)
			local droop = -rng:NextNumber(0.1, 0.3)
			local wcf = tier * ANG(0, a, 0) * ANG(droop, 0, 0) * CF(0, thick * 0.15, -len / 2)
			local p = wedge(m, V3(width, thick, len), wcf, color, M.Grass, false)
			p.CastShadow = i < 2 and lod >= 2
			if o.snow and lod == 3 and i < 2 and kk == 0 then
				-- снежная шапка поверх ската яруса
				local cl, ct = len * 0.78, thick * 0.78
				local cap = wedge(m, V3(width * 0.84, ct, cl), wcf * CF(0, thick / 2 + 0.2 - ct / 2, len / 2 - cl / 2), C.snow, M.Snow, false)
				cap.CastShadow = false
			end
		end
	end
	return m, dia / 2 + 0.4
end

-- Совместимость с v4: opts.detail 1 — дальняя сосна, 2 — ближняя
local function pine(parent, cf, h, rng, opts)
	opts = opts or {}
	local lib, libR = fromLibrary("Trees", cf, rng, parent, opts.snow and "snow" or nil)
	if lib then
		return lib, math.max(1, (libR or 4) * 0.18)
	end
	return pineTree(parent, cf, h, rng, {
		lod = opts.lod or (opts.detail == 2 and 3 or 1),
		snow = opts.snow,
		burnt = opts.burnt,
		sparse = opts.sparse,
		dense = opts.dense,
	})
end
Props.Pine = pine

-- Сухое дерево: изогнутый ствол, ветки с развилками, иногда снег на ветках или мох.
-- o: lod, bark, snow, moss, crooked, upright (ветки вверх), broken (сломанная верхушка)
local function deadTreeOf(parent, cf, h, rng, o)
	o = o or {}
	local lod = o.lod or 3
	local m = model(parent, "DeadTree")
	local bark = o.bark or rgb(46, 42, 36)
	local dia = math.max(0.8, h * 0.075)
	local frameAt = trunkOf(m, cf, h, dia, bark, rng, lod, rng:NextNumber(0.02, o.crooked and 0.16 or 0.08))
	local n = (lod == 3 and rng:NextInteger(4, 5)) or (lod == 2 and 3) or 2
	local up = o.upright and 0.9 or 0.5
	for i = 1, n do
		local y = math.min(h * 0.9, h * (0.42 + 0.12 * i) * rng:NextNumber(0.92, 1.05))
		local len = h * rng:NextNumber(0.16, 0.3)
		local t = math.max(0.22, dia * 0.3)
		local branch = frameAt(y) * ANG(0, rng:NextNumber(0, math.pi * 2), 0) * ANG(rng:NextNumber(0.2, 0.8) * up + 0.15, 0, 0)
		local p = deco(m, V3(t, t, len), branch * CF(0, 0, -len / 2), bark, M.Wood, { CastShadow = lod == 3 and i <= 2 })
		if lod == 3 and i <= 2 then
			local len2 = len * rng:NextNumber(0.4, 0.6)
			deco(m, V3(t * 0.7, t * 0.7, len2), branch * CF(0, 0, -len + len2 * 0.2) * ANG(rng:NextNumber(0.2, 0.6), rng:NextNumber(-0.8, 0.8), 0) * CF(0, 0, -len2 / 2), bark, M.Wood, { CastShadow = false })
		end
		if o.snow and lod == 3 and i <= 2 then
			deco(m, V3(t * 1.3, 0.2, len * 0.8), p.CFrame * CF(0, t * 0.6, 0), C.snow, M.Snow, { CastShadow = false })
		elseif o.moss and lod >= 2 and i <= 2 then
			local ml = rng:NextNumber(2.5, 5)
			deco(m, V3(0.14, ml, 1.5), branch * CF(0, -ml / 2, -len * 0.6), rgb(98, 110, 86), M.Grass, { CastShadow = false })
		end
	end
	if o.broken then
		for k = 0, 1 do
			wedge(m, V3(dia * 0.5, h * 0.09, dia * 0.7), frameAt(h) * ANG(0, k * math.pi + rng:NextNumber(-0.4, 0.4), 0) * CF(0, h * 0.045 - 0.2, -dia * 0.25), bark, M.Wood, false)
		end
	end
	return m, dia / 2 + 0.5
end

local BROADLEAF_GREENS = { rgb(58, 82, 44), rgb(46, 70, 38), rgb(72, 92, 48), rgb(52, 76, 50) }

-- Лиственное дерево: ствол с ветками и несколько перекрывающихся крон разных оттенков.
-- o: lod, shape ("round"|"poplar"|"acacia"|"scrub"|"willow"|"birch"), palette, bark, vines, dry
local function broadleafTree(parent, cf, h, rng, o)
	o = o or {}
	local lod = o.lod or 3
	local shape = o.shape or "round"
	local m = model(parent, o.name or "Tree")
	local bark = o.bark or rgb(62, 50, 38)
	local dia = math.max(0.8, h * (shape == "poplar" and 0.05 or 0.085))
	local frameAt = trunkOf(m, cf, h * (shape == "poplar" and 0.9 or 0.62), dia, bark, rng, lod, rng:NextNumber(0, shape == "poplar" and 0.02 or 0.06))
	local palette = o.palette or BROADLEAF_GREENS
	local mat = o.dry and M.Grass or M.LeafyGrass
	local function leafColor()
		local base = palette[rng:NextInteger(1, #palette)]
		return base:Lerp(rng:NextNumber() < 0.5 and rgb(0, 0, 0) or rgb(190, 200, 140), rng:NextNumber(0, 0.18))
	end
	if shape == "acacia" then
		-- зонтичная крона на развилке
		local r = h * 0.42
		if lod >= 2 then
			for _, sx in ipairs({ 0.4, 2.6 }) do
				local limb = h * 0.42
				deco(m, V3(dia * 0.5, dia * 0.5, limb), frameAt(h * 0.5) * ANG(0, sx, 0) * ANG(rng:NextNumber(0.7, 1.05), 0, 0) * CF(0, 0, -limb / 2), bark, M.Wood, { CastShadow = false })
			end
		end
		for i = 1, (lod == 3 and 3) or (lod == 2 and 2) or 1 do
			local sz = r * rng:NextNumber(0.7, 1)
			local p = deco(m, V3(sz * 2, sz * 0.4, sz * 1.5), frameAt(h * 0.8) * CF(rng:NextNumber(-r * 0.4, r * 0.4), rng:NextNumber(-1, 1.5), rng:NextNumber(-r * 0.3, r * 0.3)) * ANG(rng:NextNumber(-0.12, 0.12), rng:NextNumber(0, math.pi), rng:NextNumber(-0.1, 0.1)), leafColor(), mat)
			p.CastShadow = i == 1 and lod >= 2
		end
		return m, dia / 2 + 0.5
	end
	local clusters = {}
	if shape == "poplar" then
		local n = (lod == 3 and 5) or (lod == 2 and 3) or 2
		local r = h * 0.15
		for i = 1, n do
			local f = (i - 1) / math.max(1, n - 1)
			clusters[i] = { x = rng:NextNumber(-0.6, 0.6), y = h * (0.42 + 0.52 * f), z = rng:NextNumber(-0.6, 0.6), r = r * (1 - 0.4 * f) * rng:NextNumber(0.9, 1.1) }
		end
	else
		local n = (lod == 3 and rng:NextInteger(5, 7)) or (lod == 2 and 4) or 2
		local r = h * (shape == "scrub" and 0.36 or (shape == "birch" and 0.2 or 0.28))
		local cy = h * (shape == "scrub" and 0.5 or 0.76)
		clusters[1] = { x = 0, y = cy, z = 0, r = r * 1.1 }
		for i = 2, n do
			local a = rng:NextNumber(0, math.pi * 2)
			local dist = r * rng:NextNumber(0.5, 0.95)
			clusters[i] = { x = math.cos(a) * dist, y = cy + rng:NextNumber(-r * 0.5, r * 0.55), z = math.sin(a) * dist, r = r * rng:NextNumber(0.5, 0.8) }
		end
	end
	for i, cl in ipairs(clusters) do
		local p = ball(m, cl.r * 2, frameAt(cl.y) * CF(cl.x, 0, cl.z), leafColor(), mat, false)
		p.CastShadow = i == 1 and lod >= 2
	end
	if lod == 3 and shape ~= "poplar" and shape ~= "scrub" then
		for i = 2, math.min(#clusters, 4) do
			local from = frameAt(h * 0.5).Position
			local to = (frameAt(clusters[i].y) * CF(clusters[i].x, 0, clusters[i].z)).Position
			local len = (to - from).Magnitude
			if len > 1.5 then
				deco(m, V3(dia * 0.3, dia * 0.3, len), CFrame.lookAt(from, to) * CF(0, 0, -len / 2), bark, M.Wood, { CastShadow = false })
			end
		end
	end
	if shape == "willow" and lod >= 2 then
		local n = lod == 3 and 5 or 3
		for i = 1, n do
			local a = (i / n) * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
			local len = h * rng:NextNumber(0.28, 0.44)
			deco(m, V3(2.3, len, 0.5), frameAt(h * 0.72) * CF(math.cos(a) * h * 0.26, -len / 2, math.sin(a) * h * 0.26) * ANG(0, a, 0), leafColor():Lerp(rgb(120, 130, 80), 0.25), M.Grass, { CastShadow = false })
		end
	end
	if o.vines and lod >= 2 then
		for _ = 1, lod == 3 and 2 or 1 do
			local len = rng:NextNumber(5, 11)
			deco(m, V3(0.16, len, 0.16), frameAt(h * 0.7) * CF(rng:NextNumber(-3.5, 3.5), -len / 2, rng:NextNumber(-3.5, 3.5)), rgb(46, 74, 38), M.Grass, { CastShadow = false })
		end
	end
	return m, dia / 2 + 0.5
end

-- Пальма: изогнутый ствол из сегментов и листья-клинья (в плане — треугольные), сухие листья свисают
local function palmTree(parent, cf, h, rng, o)
	o = o or {}
	local lod = o.lod or 3
	local m = model(parent, "Palm")
	local bark = o.bark or rgb(104, 88, 62)
	local segs = (lod == 3 and 3) or (lod == 2 and 2) or 1
	local bend = rng:NextNumber(0.05, 0.16)
	local dia = math.max(0.9, h * 0.045)
	local segLen = h / segs
	local frame = cf * CF(0, -0.3, 0) * ANG(0, rng:NextNumber(0, math.pi * 2), 0)
	for i = 1, segs do
		frame = frame * ANG(bend * (i == 1 and 0.5 or 1), 0, 0)
		vcyl(m, segLen + 0.3, dia * (1 - 0.14 * (i - 1)), frame * CF(0, segLen / 2, 0), bark:Lerp(rgb(0, 0, 0), (i - 1) * 0.07), M.Wood)
		frame = frame * CF(0, segLen, 0)
	end
	if lod >= 2 then
		ball(m, dia * 1.5, frame * CF(0, -0.2, 0), bark:Lerp(rgb(0, 0, 0), 0.25), M.Wood, false)
	end
	local green = o.dry and rgb(122, 112, 66) or rgb(58, 96, 44)
	local fronds = (lod == 3 and rng:NextInteger(7, 8)) or (lod == 2 and 6) or 4
	for i = 1, fronds do
		local a = (i / fronds) * math.pi * 2 + rng:NextNumber(-0.25, 0.25)
		local len = h * rng:NextNumber(0.26, 0.38)
		local dead = o.dry and rng:NextNumber() < 0.3
		local droop = dead and rng:NextNumber(1.05, 1.35) or rng:NextNumber(0.25, 0.7)
		local color = dead and rgb(104, 82, 50) or green:Lerp(rgb(0, 0, 0), rng:NextNumber(0, 0.16))
		local p = wedge(m, V3(0.22, len * rng:NextNumber(0.24, 0.32), len), frame * ANG(0, a, 0) * ANG(-droop, 0, 0) * CF(0, 0, -len / 2) * ANG(0, 0, math.pi / 2), color, M.Grass, false)
		p.CastShadow = false
	end
	return m, dia / 2 + 0.6
end

-- Тропический великан: корни-подпорки, высокий ствол, плоские ярусы кроны, лианы
local function giantTree(parent, cf, h, rng, o)
	o = o or {}
	local lod = o.lod or 3
	local m = model(parent, "Tree")
	local bark = rgb(74, 62, 48)
	local dia = math.max(1.8, h * 0.075)
	local frameAt = trunkOf(m, cf, h * 0.82, dia, bark, rng, lod, rng:NextNumber(0, 0.03))
	if lod == 3 then
		for i = 1, 3 do
			local rootH = h * rng:NextNumber(0.12, 0.18)
			local rootL = dia * rng:NextNumber(1.1, 1.6)
			wedge(m, V3(0.7, rootH, rootL), cf * ANG(0, i * 2.1 + rng:NextNumber(-0.3, 0.3), 0) * CF(0, rootH / 2 - 0.3, -(dia / 2 + rootL / 2 - 0.4)), bark, M.Wood, false)
		end
	end
	local green = o.palette or { rgb(38, 66, 34), rgb(50, 78, 40), rgb(30, 56, 30) }
	local r = h * 0.3
	for i = 1, (lod == 3 and 3) or (lod == 2 and 2) or 1 do
		local sz = r * rng:NextNumber(0.75, 1.05)
		local p = deco(m, V3(sz * 2, sz * 0.45, sz * 1.6), frameAt(h * 0.86) * CF(rng:NextNumber(-r * 0.3, r * 0.3), (i - 1) * r * 0.22, rng:NextNumber(-r * 0.3, r * 0.3)) * ANG(rng:NextNumber(-0.1, 0.1), rng:NextNumber(0, math.pi), rng:NextNumber(-0.1, 0.1)), green[rng:NextInteger(1, #green)], M.LeafyGrass)
		p.CastShadow = i == 1 and lod >= 2
	end
	if lod >= 2 then
		ball(m, r * 1.3, frameAt(h * 0.86) * CF(0, r * 0.2, 0), green[rng:NextInteger(1, #green)], M.LeafyGrass, false).CastShadow = false
	end
	if lod == 3 then
		for _ = 1, 2 do
			local len = rng:NextNumber(6, 13)
			deco(m, V3(0.18, len, 0.18), frameAt(h * 0.86) * CF(rng:NextNumber(-r, r), -len / 2 - 1, rng:NextNumber(-r * 0.6, r * 0.6)), rgb(46, 74, 38), M.Grass, { CastShadow = false })
		end
	end
	return m, dia / 2 + 0.8
end

-- Банановая пальма: короткий стебель и крупные листья веером
local function bananaPlant(parent, cf, h, rng, o)
	o = o or {}
	local lod = o.lod or 3
	local m = model(parent, "Banana")
	local stem = h * 0.55
	vcyl(m, stem, 0.8, cf * CF(0, stem / 2, 0), rgb(88, 96, 62), M.Grass)
	for i = 1, (lod == 3 and 6) or (lod == 2 and 4) or 3 do
		local a = (i / 6) * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
		local len = h * rng:NextNumber(0.5, 0.75)
		local p = wedge(m, V3(0.16, h * rng:NextNumber(0.24, 0.34), len), cf * CF(0, stem, 0) * ANG(0, a, 0) * ANG(rng:NextNumber(-0.5, 0.45), 0, 0) * CF(0, 0, -len / 2) * ANG(0, 0, math.pi / 2), rgb(56, 92, 44):Lerp(rgb(0, 0, 0), rng:NextNumber(0, 0.2)), M.Grass, false)
		p.CastShadow = false
	end
	return m, 0.8
end

-- Кипарис болот: расширенное основание, «колени» у корней, узкая крона
local function cypressTree(parent, cf, h, rng, o)
	o = o or {}
	local lod = o.lod or 3
	local m = model(parent, "Cypress")
	local bark = rgb(88, 74, 58)
	local dia = math.max(1, h * 0.06)
	local frameAt = trunkOf(m, cf, h * 0.8, dia, bark, rng, lod, rng:NextNumber(0, 0.03))
	if lod == 3 then
		for i = 1, 3 do
			local rootH = h * 0.1
			wedge(m, V3(0.6, rootH, dia * 1.1), cf * ANG(0, i * 2.2 + rng:NextNumber(-0.4, 0.4), 0) * CF(0, rootH / 2 - 0.2, -dia), bark, M.Wood, false)
		end
		for i = 1, 2 do
			local a = i * 2.9 + rng:NextNumber(-0.5, 0.5)
			local kh = rng:NextNumber(0.8, 1.6)
			vcyl(m, kh, 0.5, cf * CF(math.cos(a) * dia * 1.7, kh / 2 - 0.1, math.sin(a) * dia * 1.7), bark, M.Wood, false)
		end
	end
	local n = (lod == 3 and 4) or (lod == 2 and 3) or 2
	for i = 1, n do
		local f = (i - 1) / math.max(1, n - 1)
		local p = ball(m, h * 0.32 * (1 - 0.5 * f), frameAt(h * (0.62 + 0.3 * f)) * CF(rng:NextNumber(-0.8, 0.8), 0, rng:NextNumber(-0.8, 0.8)), rgb(64, 78, 48):Lerp(rgb(0, 0, 0), rng:NextNumber(0, 0.18)), M.LeafyGrass, false)
		p.CastShadow = i == 1 and lod >= 2
	end
	if o.moss and lod == 3 then
		for _ = 1, 2 do
			local len = rng:NextNumber(3, 6)
			deco(m, V3(0.14, len, 1.4), frameAt(h * 0.7) * CF(rng:NextNumber(-2, 2), -len / 2, rng:NextNumber(-2, 2)), rgb(104, 112, 86), M.Grass, { CastShadow = false })
		end
	end
	return m, dia / 2 + 0.6
end

-- Обломок ствола со сколами
local function snagTree(parent, cf, h, rng, o)
	o = o or {}
	local lod = o.lod or 3
	local m = model(parent, "Snag")
	local bark = o.bark or rgb(52, 46, 40)
	local dia = math.max(0.9, h * 0.12)
	local base = cf * CF(0, -0.3, 0) * ANG(0, rng:NextNumber(0, math.pi * 2), 0) * ANG(rng:NextNumber(0.03, 0.14), 0, 0)
	vcyl(m, h, dia, base * CF(0, h / 2, 0), bark, M.Wood)
	for k = 0, (lod == 3 and 1 or 0) do
		wedge(m, V3(dia * 0.55, h * 0.12, dia * 0.8), base * CF(0, h, 0) * ANG(0, k * math.pi + rng:NextNumber(-0.4, 0.4), 0) * CF(0, h * 0.06 - 0.2, -dia * 0.25), bark, M.Wood, false)
	end
	if lod >= 2 then
		local len = h * rng:NextNumber(0.2, 0.35)
		deco(m, V3(dia * 0.3, dia * 0.3, len), base * CF(0, h * 0.62, 0) * ANG(0, rng:NextNumber(0, math.pi * 2), 0) * ANG(rng:NextNumber(0.3, 0.7), 0, 0) * CF(0, 0, -len / 2), bark, M.Wood, { CastShadow = false })
	end
	return m, dia / 2 + 0.4
end

-- Совместимость с v4
local function deadTree(parent, cf, rng)
	return deadTreeOf(parent, cf, rng:NextNumber(12, 24), rng, { lod = 3 })
end

local JUNGLE_GREENS = { rgb(38, 70, 36), rgb(52, 88, 42), rgb(30, 58, 32) }

-- Архетипы деревьев: h — диапазон высоты, reach — вылет кроны (доля h), low — нижняя кромка кроны (доля h),
-- cost — деталей по уровню детализации (1 — дальний, 3 — ближний)
local TREES = {
	pine = { h = { 40, 64 }, reach = 0.24, low = 0.26, cost = { 5, 10, 18 },
		build = function(p, cf, h, rng, lod) return pineTree(p, cf, h, rng, { lod = lod }) end },
	pine_tall = { h = { 56, 84 }, reach = 0.15, low = 0.48, cost = { 5, 10, 16 },
		build = function(p, cf, h, rng, lod) return pineTree(p, cf, h, rng, { lod = lod, sparse = true }) end },
	pine_dense = { h = { 26, 44 }, reach = 0.3, low = 0.14, cost = { 5, 10, 18 },
		build = function(p, cf, h, rng, lod) return pineTree(p, cf, h, rng, { lod = lod, dense = true }) end },
	pine_snow = { h = { 40, 66 }, reach = 0.24, low = 0.26, cost = { 5, 10, 20 },
		build = function(p, cf, h, rng, lod) return pineTree(p, cf, h, rng, { lod = lod, snow = true }) end },
	pine_tall_snow = { h = { 52, 78 }, reach = 0.15, low = 0.48, cost = { 5, 10, 18 },
		build = function(p, cf, h, rng, lod) return pineTree(p, cf, h, rng, { lod = lod, sparse = true, snow = true }) end },
	spruce_frost = { h = { 24, 40 }, reach = 0.3, low = 0.14, cost = { 5, 10, 20 },
		build = function(p, cf, h, rng, lod) return pineTree(p, cf, h, rng, { lod = lod, dense = true, snow = true }) end },
	pine_burnt = { h = { 22, 40 }, reach = 0.15, low = 0.5, cost = { 5, 9, 11 },
		build = function(p, cf, h, rng, lod) return pineTree(p, cf, h, rng, { lod = lod, burnt = true }) end },
	pine_swamp = { h = { 34, 56 }, reach = 0.15, low = 0.48, cost = { 5, 10, 16 },
		build = function(p, cf, h, rng, lod) return pineTree(p, cf, h, rng, { lod = lod, sparse = true, bark = rgb(56, 52, 44) }) end },
	linden = { h = { 18, 28 }, reach = 0.34, low = 0.42, cost = { 3, 5, 12 },
		build = function(p, cf, h, rng, lod) return broadleafTree(p, cf, h, rng, { lod = lod }) end },
	poplar = { h = { 22, 34 }, reach = 0.18, low = 0.4, cost = { 3, 4, 6 },
		build = function(p, cf, h, rng, lod) return broadleafTree(p, cf, h, rng, { lod = lod, shape = "poplar" }) end },
	birch = { h = { 16, 26 }, reach = 0.26, low = 0.45, cost = { 3, 4, 10 },
		build = function(p, cf, h, rng, lod)
			return broadleafTree(p, cf, h, rng, { lod = lod, shape = "birch", bark = C.birch, palette = { rgb(96, 120, 60), rgb(112, 132, 68), rgb(84, 108, 54) } })
		end },
	birch_bare = { h = { 14, 22 }, reach = 0.3, low = 0.45, cost = { 3, 4, 9 },
		build = function(p, cf, h, rng, lod) return deadTreeOf(p, cf, h, rng, { lod = lod, bark = C.birch, snow = true, upright = true }) end },
	acacia = { h = { 12, 18 }, reach = 0.48, low = 0.62, cost = { 2, 5, 7 },
		build = function(p, cf, h, rng, lod)
			return broadleafTree(p, cf, h, rng, { lod = lod, shape = "acacia", dry = true, bark = rgb(84, 72, 54), palette = { rgb(96, 104, 62), rgb(80, 92, 54), rgb(110, 114, 70) } })
		end },
	juniper = { h = { 7, 11 }, reach = 0.42, low = 0.22, cost = { 3, 4, 6 },
		build = function(p, cf, h, rng, lod)
			return broadleafTree(p, cf, h, rng, { lod = lod, shape = "scrub", dry = true, palette = { rgb(72, 84, 52), rgb(88, 94, 58) } })
		end },
	palm = { h = { 20, 32 }, reach = 0.36, low = 0.75, cost = { 5, 8, 13 },
		build = function(p, cf, h, rng, lod) return palmTree(p, cf, h, rng, { lod = lod }) end },
	palm_dry = { h = { 14, 24 }, reach = 0.36, low = 0.7, cost = { 5, 8, 13 },
		build = function(p, cf, h, rng, lod) return palmTree(p, cf, h, rng, { lod = lod, dry = true }) end },
	giant = { h = { 34, 52 }, reach = 0.36, low = 0.7, cost = { 3, 5, 14 },
		build = function(p, cf, h, rng, lod) return giantTree(p, cf, h, rng, { lod = lod }) end },
	jungle_broad = { h = { 18, 32 }, reach = 0.34, low = 0.45, cost = { 3, 6, 13 },
		build = function(p, cf, h, rng, lod) return broadleafTree(p, cf, h, rng, { lod = lod, vines = true, palette = JUNGLE_GREENS }) end },
	banana = { h = { 5, 9 }, reach = 0.8, low = 0.5, cost = { 4, 5, 7 },
		build = function(p, cf, h, rng, lod) return bananaPlant(p, cf, h, rng, { lod = lod }) end },
	dead = { h = { 12, 24 }, reach = 0.3, low = 0.45, cost = { 3, 4, 10 },
		build = function(p, cf, h, rng, lod) return deadTreeOf(p, cf, h, rng, { lod = lod }) end },
	dead_pale = { h = { 10, 18 }, reach = 0.3, low = 0.45, cost = { 3, 4, 10 },
		build = function(p, cf, h, rng, lod) return deadTreeOf(p, cf, h, rng, { lod = lod, bark = C.barkPale, crooked = true }) end },
	dead_black = { h = { 12, 22 }, reach = 0.3, low = 0.45, cost = { 3, 4, 10 },
		build = function(p, cf, h, rng, lod) return deadTreeOf(p, cf, h, rng, { lod = lod, bark = C.barkBurnt, broken = true }) end },
	dead_swamp = { h = { 14, 26 }, reach = 0.3, low = 0.45, cost = { 3, 5, 12 },
		build = function(p, cf, h, rng, lod) return deadTreeOf(p, cf, h, rng, { lod = lod, bark = rgb(58, 56, 46), moss = true, crooked = true }) end },
	dead_moss = { h = { 14, 24 }, reach = 0.3, low = 0.45, cost = { 3, 5, 12 },
		build = function(p, cf, h, rng, lod) return deadTreeOf(p, cf, h, rng, { lod = lod, bark = rgb(60, 54, 44), moss = true }) end },
	poplar_dead = { h = { 18, 30 }, reach = 0.22, low = 0.45, cost = { 3, 4, 10 },
		build = function(p, cf, h, rng, lod) return deadTreeOf(p, cf, h, rng, { lod = lod, bark = rgb(60, 56, 50), upright = true }) end },
	willow = { h = { 16, 24 }, reach = 0.36, low = 0.35, cost = { 3, 7, 12 },
		build = function(p, cf, h, rng, lod)
			return broadleafTree(p, cf, h, rng, { lod = lod, shape = "willow", palette = { rgb(76, 92, 52), rgb(62, 82, 46) } })
		end },
	cypress = { h = { 24, 38 }, reach = 0.2, low = 0.55, cost = { 3, 4, 10 },
		build = function(p, cf, h, rng, lod) return cypressTree(p, cf, h, rng, { lod = lod, moss = true }) end },
	snag = { h = { 6, 14 }, reach = 0.2, low = 0.5, cost = { 2, 3, 4 },
		build = function(p, cf, h, rng, lod) return snagTree(p, cf, h, rng, { lod = lod }) end },
	charred = { h = { 14, 22 }, reach = 0.3, low = 0.5, cost = { 3, 5, 11 },
		build = function(p, cf, h, rng, lod)
			return broadleafTree(p, cf, h, rng, { lod = lod, dry = true, bark = C.barkBurnt, palette = { rgb(56, 50, 40), rgb(70, 62, 46) } })
		end },
}

-- 4–6 архетипов на биом
local TREE_SETS = {
	depot = { { "pine_tall", 6 }, { "pine", 3 }, { "pine_dense", 2 } },
	desert = { { "dead_pale", 3 }, { "acacia", 3 }, { "juniper", 3 }, { "palm_dry", 2 }, { "pine_burnt", 2 } },
	city = { { "poplar", 3 }, { "linden", 2 }, { "birch", 2 }, { "dead", 2 } },
	jungle = { { "jungle_broad", 4 }, { "palm", 3 }, { "giant", 2 }, { "banana", 2 }, { "dead_moss", 1 } },
	swamp = { { "dead_swamp", 4 }, { "cypress", 3 }, { "willow", 2 }, { "pine_swamp", 2 }, { "snag", 1 } },
	snow = { { "pine_snow", 5 }, { "spruce_frost", 3 }, { "pine_tall_snow", 2 }, { "birch_bare", 2 } },
	wasteland = { { "dead_black", 3 }, { "pine_burnt", 3 }, { "snag", 2 }, { "charred", 2 }, { "poplar_dead", 1 } },
}

-- Дерево архетипа kind в точке (s, d). Все случайные величины бросаются до проверок бюджета и места,
-- поэтому набор деревьев в чанке не зависит от того, сколько деталей осталось.
-- opts: lod, scale, depot, reserve, variant
local function placeTree(c, kind, s, d, opts)
	opts = opts or {}
	local rng = c.rng
	local seed = rng:NextInteger(1, 1073741823)
	local yaw = rng:NextNumber(0, math.pi * 2)
	local hRoll = rng:NextNumber()
	local spec = TREES[kind]
	if not spec then
		return nil
	end
	local h = (spec.h[1] + (spec.h[2] - spec.h[1]) * hRoll) * (opts.scale or 1)
	local lod = opts.lod or lodFor(d)
	if not afford(c, spec.cost[lod], opts.reserve) then
		lod = 1
		if not afford(c, spec.cost[1], opts.reserve) then
			return nil
		end
	end
	-- крона не должна нависать над дорогой ниже 16 studs
	local dd = d
	if h * spec.low < 17 then
		local minD = RHW + 1 + spec.reach * h
		if math.abs(dd) < minD then
			dd = dd < 0 and -minD or minD
		end
	end
	local cf = spot(c, s, dd, 1.8, yaw, opts.depot and { depot = true } or nil)
	if not cf then
		return nil
	end
	local lib, libR = fromLibrary("Trees", cf, rng, c.folder, kind)
	if lib then
		circle(c, cf, math.max(1, (libR or 4) * 0.2), true, lib, { kind = "tree" })
		return lib
	end
	local m, r = spec.build(c.folder, cf, h, Random.new(seed), lod)
	circle(c, cf, r or 1.2, true, m, { kind = "tree" })
	return m
end

-- Случайный архетип биома (бросок до проверок бюджета)
local function biomeTree(c, biomeId)
	return Util.Weighted(c.rng, TREE_SETS[biomeId or "desert"] or TREE_SETS.desert)
end

-- Подрост и мелкая растительность ----------------------------------------------------------------
-- Куст: 2–3 утопленных в землю шара
-- Общая таблица констант и сборщиков депо: обходит лимит Luau в 200 local на файл
local CONST = {}

local function bush(parent, cf, rng, color, size)
	local m = model(parent, "Bush")
	size = size or rng:NextNumber(2.5, 5)
	for i = 1, rng:NextInteger(2, 3) do
		local sz = size * rng:NextNumber(0.55, 1)
		local p = ball(m, sz, cf * CF(rng:NextNumber(-size * 0.35, size * 0.35), sz * 0.18, rng:NextNumber(-size * 0.35, size * 0.35)), color:Lerp(rgb(0, 0, 0), rng:NextNumber(0, 0.18) + (i - 1) * 0.05), M.Grass, false)
		p.CastShadow = false
	end
	return m
end

-- Пучок травы: три клиновидные травинки веером
local function grassTuft(parent, cf, rng, color)
	local h = rng:NextNumber(1, 2.2)
	local yaw = rng:NextNumber(0, math.pi * 2)
	for k = 0, 2 do
		local blade = wedge(parent, V3(0.08, h * rng:NextNumber(0.7, 1), rng:NextNumber(0.5, 0.9)), cf * ANG(0, yaw + k * 2.1, 0) * CF(0, h * 0.42, 0.25) * ANG(rng:NextNumber(-0.25, 0.1), 0, 0), color:Lerp(rgb(0, 0, 0), rng:NextNumber(0, 0.25)), M.Grass, false)
		blade.CastShadow = false
	end
end

-- Папоротник: три вайи, приподнятые от центра
local function fern(parent, cf, rng, color)
	local yaw = rng:NextNumber(0, math.pi * 2)
	for k = 0, 2 do
		local len = rng:NextNumber(1.8, 2.8)
		local frond = wedge(parent, V3(1, 0.12, len), cf * ANG(0, yaw + k * 2.1, 0) * CF(0, 0.35, 0) * ANG(rad(rng:NextNumber(14, 30)), 0, 0) * CF(0, 0, -len / 2), color:Lerp(rgb(0, 0, 0), rng:NextNumber(0, 0.2)), M.Grass, false)
		frond.CastShadow = false
	end
end

-- Камыш с початками
local function reeds(parent, cf, rng)
	for k = 1, 4 do
		local h = rng:NextNumber(3, 5.5)
		local p = cf * CF(rng:NextNumber(-1.2, 1.2), 0, rng:NextNumber(-1.2, 1.2)) * ANG(rng:NextNumber(-0.12, 0.12), 0, rng:NextNumber(-0.12, 0.12))
		deco(parent, V3(0.12, h, 0.12), p * CF(0, h / 2, 0), rgb(96, 104, 64), M.Grass, { CastShadow = false })
		if k <= 2 then
			deco(parent, V3(0.3, 0.9, 0.3), p * CF(0, h + 0.2, 0), rgb(84, 58, 38), M.Fabric, { CastShadow = false })
		end
	end
end

local function cactus(parent, cf, rng)
	local m = model(parent, "Cactus")
	local h = rng:NextNumber(5, 10)
	local green = rgb(78, 104, 64):Lerp(rgb(100, 112, 72), rng:NextNumber())
	vcyl(m, h, 1.3, cf * CF(0, h / 2, 0), green, M.Grass)
	ball(m, 1.3, cf * CF(0, h, 0), green, M.Grass, false)
	for k = 1, rng:NextInteger(0, 2) do
		local side = k == 1 and 1 or -1
		local ay = h * rng:NextNumber(0.35, 0.6)
		local out = rng:NextNumber(1.4, 2)
		local up = rng:NextNumber(1.5, 3)
		deco(m, V3(out, 0.8, 0.8), cf * CF(side * out / 2, ay, 0), green, M.Grass)
		vcyl(m, up, 0.8, cf * CF(side * out, ay + up / 2 - 0.3, 0), green, M.Grass, false)
	end
	return m, 0.8
end

local function stump(parent, cf, rng, snow)
	local m = model(parent, "Stump")
	local dia = rng:NextNumber(1.4, 2.6)
	local h = rng:NextNumber(0.8, 1.8)
	vcyl(m, h, dia, cf * CF(0, h / 2, 0), C.bark, M.Wood)
	deco(m, V3(0.06, dia * 0.86, dia * 0.86), cf * CF(0, h + 0.02, 0) * ANG(0, 0, rad(90)), snow and rgb(228, 234, 242) or rgb(150, 120, 84), snow and M.Snow or M.Wood, { Shape = CYL, CastShadow = false })
	return m, dia / 2
end

local function fallenLog(parent, cf, rng, snow)
	local m = model(parent, "FallenLog")
	local len = rng:NextNumber(8, 12)
	local dia = rng:NextNumber(1.2, 2)
	hcyl(m, len, dia, cf * CF(0, dia * 0.45, 0) * ANG(0, 0, rng:NextNumber(-0.05, 0.05)), rgb(58, 46, 36), M.Wood)
	if snow then
		deco(m, V3(len * 0.9, 0.3, dia * 0.7), cf * CF(0, dia * 0.95, 0), rgb(228, 234, 242), M.Snow, { CastShadow = false })
	else
		deco(m, V3(0.4, 2.2, 0.4), cf * CF(len * 0.25, dia, 0) * ANG(0, 0, rad(35)), rgb(58, 46, 36), M.Wood, { CastShadow = false })
	end
	return m
end

-- Молодая ёлка: ствол и два скрещённых яруса
local function youngPine(parent, cf, rng, snow)
	local m = model(parent, "YoungPine")
	local h = rng:NextNumber(7, 13)
	vcyl(m, h * 0.5, 0.35, cf * CF(0, h * 0.25, 0), C.bark, M.Wood, false)
	local color = C.pine:Lerp(C.pineLight, rng:NextNumber())
	if snow then
		color = color:Lerp(rgb(226, 232, 240), 0.3)
	end
	local yaw = rng:NextNumber(0, math.pi)
	for k = 0, 1 do
		prism(m, cf * CF(0, h * 0.18, 0) * ANG(0, yaw + k * math.pi / 2, 0), h * 0.45, h * 0.82, 0.35, color, M.Grass, false)
	end
	return m, 0.5
end

local function rock(parent, cf, size, color, material, rng)
	local lib, libR = fromLibrary("Rocks", cf, rng, parent)
	if lib then
		return lib, libR
	end
	local m = model(parent, "Rock")
	mk(m, V3(size, size * 0.62, size * 0.85), cf * CF(0, size * 0.2, 0) * ANG(rng:NextNumber(-0.3, 0.3), 0, rng:NextNumber(-0.3, 0.3)), color, material)
	if size > 5 then
		mk(m, V3(size * 0.6, size * 0.5, size * 0.6), cf * CF(size * 0.35, size * 0.14, size * 0.2) * ANG(0.4, 0.7, 0.2), color:Lerp(rgb(0, 0, 0), 0.15), material)
	end
	return m, size * 0.45
end

local function crate(parent, cf, size, military)
	local color = military and rgb(62, 70, 50) or rgb(104, 80, 56)
	local p = mk(parent, V3(size, size, size), cf * CF(0, size / 2, 0), color, military and M.Metal or M.WoodPlanks)
	deco(parent, V3(size + 0.06, 0.22, size + 0.06), cf * CF(0, size * 0.82, 0), color:Lerp(rgb(0, 0, 0), 0.35), M.Metal)
	deco(parent, V3(size + 0.06, 0.22, size + 0.06), cf * CF(0, size * 0.18, 0), color:Lerp(rgb(0, 0, 0), 0.35), M.Metal)
	return p
end

local function barrel(parent, cf, color)
	local p = vcyl(parent, 3, 2, cf * CF(0, 1.5, 0), color or C.rustDark, M.CorrodedMetal)
	deco(parent, V3(0.12, 2.1, 2.1), cf * CF(0, 2.2, 0) * ANG(0, 0, rad(90)), rgb(40, 36, 32), M.Metal)
	return p
end

-- Лежащая покрышка (или стопка)
local function tires(parent, cf, count, rng)
	local first
	for i = 1, count do
		local tcf = cf * CF(rng:NextNumber(-0.25, 0.25), 0.55 + (i - 1) * 1.1, rng:NextNumber(-0.25, 0.25)) * ANG(rng:NextNumber(-0.05, 0.05), rng:NextNumber(0, 6), 0)
		local t = mkShape(parent, CYL, V3(1.1, 3.6, 3.6), tcf * ANG(0, 0, rad(90)), rgb(24, 24, 26), M.Rubber)
		deco(parent, V3(1.14, 1.8, 1.8), tcf * ANG(0, 0, rad(90)), rgb(10, 10, 12), M.Rubber, { Shape = CYL })
		first = first or t
	end
	return first
end

CONST.CAR_COLORS = { rgb(96, 44, 38), rgb(52, 64, 84), rgb(130, 128, 120), rgb(58, 74, 58), rgb(120, 100, 60), rgb(70, 70, 74) }

local function carWreck(parent, cf, rng, color)
	local lib = fromLibrary("Vehicles", cf, rng, parent)
	if lib then
		return lib
	end
	local m = model(parent, "Wreck")
	color = color or CONST.CAR_COLORS[rng:NextInteger(1, #CONST.CAR_COLORS)]
	local burnt = rng:NextNumber() < 0.2
	local body = burnt and rgb(40, 34, 30) or color:Lerp(C.rust, rng:NextNumber(0.25, 0.5))
	local metal = rgb(62, 62, 64)
	cf = cf * ANG(0, 0, rng:NextNumber(-0.04, 0.04))
	-- кузов и салон
	mk(m, V3(6, 1.8, 12.4), cf * CF(0, 1.85, 0), body, M.CorrodedMetal)
	mk(m, V3(5.5, 1.7, 5.8), cf * CF(0, 3.6, 0.8), burnt and rgb(30, 28, 26) or color:Lerp(rgb(20, 20, 20), 0.25), M.Metal)
	deco(m, V3(6.1, 0.35, 12.5), cf * CF(0, 1.05, 0), rgb(30, 28, 26), M.Metal, { CastShadow = false })
	-- стёкла: лобовое и заднее наклонные, боковые (часть выбита)
	if not burnt then
		deco(m, V3(5.1, 1.75, 0.12), cf * CF(0, 3.55, -2.25) * ANG(rad(-28), 0, 0), C.glass, M.Glass, { Transparency = 0.25, Reflectance = 0.15, CastShadow = false })
		deco(m, V3(5.1, 1.4, 0.12), cf * CF(0, 3.55, 3.8) * ANG(rad(24), 0, 0), C.glass, M.Glass, { Transparency = 0.3, CastShadow = false })
		for _, x in ipairs({ -2.78, 2.78 }) do
			if rng:NextNumber() < 0.6 then
				deco(m, V3(0.08, 1.15, 4.8), cf * CF(x, 3.65, 0.8), C.glass, M.Glass, { Transparency = 0.3, CastShadow = false })
			end
		end
	end
	-- бамперы, фары, задние фонари
	deco(m, V3(6.2, 0.6, 0.5), cf * CF(0, 1.3, -6.35), metal, M.Metal, { CastShadow = false })
	deco(m, V3(6.2, 0.6, 0.5), cf * CF(0, 1.3, 6.35), metal, M.Metal, { CastShadow = false })
	for _, x in ipairs({ -2.1, 2.1 }) do
		deco(m, V3(1.1, 0.55, 0.12), cf * CF(x, 2.2, -6.22), rgb(176, 172, 150), M.Glass, { CastShadow = false })
		deco(m, V3(1, 0.5, 0.12), cf * CF(x, 2.2, 6.22), rgb(110, 26, 22), M.Glass, { CastShadow = false })
	end
	-- колёса с дисками: часть снята, часть спущена
	for _, x in ipairs({ -2.85, 2.85 }) do
		for _, z in ipairs({ -3.9, 3.9 }) do
			local r = rng:NextNumber()
			if r < 0.8 then
				local wcf = cf * CF(x, 1.15 - (r < 0.2 and 0.35 or 0), z)
				mkShape(m, CYL, V3(1, 2.3, 2.3), wcf, rgb(22, 22, 24), M.Rubber, false)
				deco(m, V3(1.04, 1.1, 1.1), wcf, rgb(112, 110, 104), M.Metal, { Shape = CYL, CastShadow = false })
			end
		end
	end
	-- ржавое пятно, иногда открытая дверь или поднятый капот
	deco(m, V3(2.4, 0.08, 2.8), cf * CF(rng:NextNumber(-1.5, 1.5), 2.78, rng:NextNumber(-5, -3)), C.rustDark, M.CorrodedMetal, { CastShadow = false })
	local roll = rng:NextNumber()
	if roll < 0.25 then
		local side = randSide(rng)
		deco(m, V3(0.2, 2.5, 3.4), cf * CF(side * 3.05, 2.6, -2.3) * ANG(0, side * rad(55), 0) * CF(0, 0, 1.7), body, M.CorrodedMetal)
	elseif roll < 0.45 then
		deco(m, V3(5.6, 0.18, 3.6), cf * CF(0, 2.8, -2.9) * ANG(rad(50), 0, 0) * CF(0, 0, -1.8), body, M.CorrodedMetal)
	end
	return m
end

local function streetLamp(parent, cf, armSign, rng)
	local lib = fromLibrary("Lamps", cf, rng, parent)
	if lib then
		return lib
	end
	local m = model(parent, "StreetLamp")
	mk(m, V3(1.3, 1, 1.3), cf * CF(0, 0.5, 0), C.metalDark, M.Metal)
	vcyl(m, 19, 0.42, cf * CF(0, 9.5, 0), C.metal, M.Metal)
	deco(m, V3(3.9, 0.22, 0.22), cf * CF(armSign * 1.85, 18.7, 0) * ANG(0, 0, armSign * rad(-5)), C.metal, M.Metal, { CastShadow = false })
	deco(m, V3(0.16, 1.9, 0.16), cf * CF(armSign * 0.75, 18.05, 0) * ANG(0, 0, armSign * rad(-42)), C.metal, M.Metal, { CastShadow = false })
	deco(m, V3(2, 0.5, 1.05), cf * CF(armSign * 3.7, 18.95, 0), C.metalDark, M.Metal)
	local lamp = deco(m, V3(1.5, 0.14, 0.72), cf * CF(armSign * 3.7, 18.64, 0), rgb(255, 214, 160), M.Neon, { CastShadow = false })
	local spot = Instance.new("SpotLight")
	spot.Face = Enum.NormalId.Bottom
	spot.Angle = 115
	spot.Range = 46
	spot.Brightness = 1.9
	spot.Color = rgb(255, 204, 150)
	spot.Shadows = false
	spot.Parent = lamp
	nightLamp(lamp, rgb(128, 124, 112), "Glass")
	return m
end

-- Колючая проволока-спираль вдоль локальной X от cf на длину length (Beam без текстуры)
local function barbedCoil(parent, cf, length, radius, pitch)
	local anchor = deco(parent, V3(math.max(0.2, length), 0.1, 0.1), cf * CF(length / 2, 0, 0), C.metal, M.Metal, { Transparency = 1, CastShadow = false })
	anchor.Name = "BarbedWire"
	local loops = math.max(1, math.floor(length / pitch))
	local stepX = length / loops
	local color = ColorSequence.new(rgb(72, 70, 66))
	local function att(x, y, axisZ)
		local a = Instance.new("Attachment")
		a.CFrame = CFrame.fromMatrix(V3(x - length / 2, y, 0), V3(0, 0, axisZ), V3(0, 1, 0))
		a.Parent = anchor
		return a
	end
	local function beam(a0, a1, curve)
		local b = Instance.new("Beam")
		b.Attachment0 = a0
		b.Attachment1 = a1
		b.CurveSize0 = curve
		b.CurveSize1 = curve
		b.Width0 = 0.07
		b.Width1 = 0.07
		b.Color = color
		b.Segments = 8
		b.FaceCamera = true
		b.LightInfluence = 1
		b.Parent = anchor
	end
	local curve = radius * 1.33
	local prevBottom = att(0, -radius, 1)
	for i = 0, loops - 1 do
		local top = att((i + 0.5) * stepX, radius, -1)
		local bottom = att((i + 1) * stepX, -radius, 1)
		beam(prevBottom, top, curve)
		beam(top, bottom, curve)
		prevBottom = bottom
	end
	return anchor
end
Props.BarbedCoil = barbedCoil

-- Заборы ----------------------------------------------------------------------------------------
-- Забор строится вдоль локальной X от cf на длину length; лицевая сторона — −Z.
-- o: height, broken (доля проломов), lean (доля покосившихся столбов), gap = {от, до} (проход),
-- coil (колючая спираль сверху), collide (по умолчанию true), color, snow, spacing

-- Ромбическая сетка на полотне: рисуется кадрами SurfaceGui, деталей не тратит
local function meshGui(part, face, w, h, spacing, color, transparency, thickness, pps, maxDistance)
	local px = pps or 14
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = px
	gui.LightInfluence = 1
	gui.ClipsDescendants = true
	gui.MaxDistance = maxDistance or 190
	for dir = -1, 1, 2 do
		local k = -h + spacing * 0.5
		while k < w do
			local u0 = math.max(0, k)
			local u1 = math.min(w, k + h)
			if u1 - u0 > 0.15 then
				local uc = (u0 + u1) / 2
				local f = Instance.new("Frame")
				f.BorderSizePixel = 0
				f.BackgroundColor3 = color
				f.BackgroundTransparency = transparency or 0.1
				f.AnchorPoint = Vector2.new(0.5, 0.5)
				f.Position = UDim2.fromScale((dir == 1 and uc or (w - uc)) / w, (uc - k) / h)
				f.Size = UDim2.fromOffset(math.max(2, math.floor((u1 - u0) * 1.4142 * px + 0.5)), thickness or 2)
				f.Rotation = dir * 45
				f.Parent = gui
			end
			k = k + spacing
		end
	end
	gui.Parent = part
	return gui
end

-- Вертикальные полосы на грани: гофра профлиста или щели между досками
local function stripeGui(part, face, w, step, color, transparency, thickness)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 10
	gui.LightInfluence = 1
	gui.ClipsDescendants = true
	gui.MaxDistance = 220
	local n = math.max(2, math.floor(w / step))
	for i = 1, n - 1 do
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.BackgroundColor3 = color
		f.BackgroundTransparency = transparency or 0.5
		f.AnchorPoint = Vector2.new(0.5, 0)
		f.Position = UDim2.fromScale(i / n, 0)
		f.Size = UDim2.new(0, thickness or 3, 1, 0)
		f.Parent = gui
	end
	gui.Parent = part
	return gui
end

-- Пересекается ли участок [a, b] с проходом (воротами)
local function fenceGap(o, a, b)
	local g = o.gap
	return g ~= nil and b > g[1] and a < g[2]
end

local function leanCF(rng, chance, amount)
	if rng:NextNumber() < (chance or 0) then
		return ANG(rng:NextNumber(-amount, amount), 0, rng:NextNumber(-amount * 0.4, amount * 0.4))
	end
	return ANG(rng:NextNumber(-0.02, 0.02), 0, 0)
end

-- Колючая спираль по верху, с учётом прохода
local function fenceCoil(m, cf, length, h, o)
	if not o.coil then
		return
	end
	if o.gap then
		if o.gap[1] > 1 then
			barbedCoil(m, cf * CF(0, h, 0), o.gap[1], 0.85, 1.25)
		end
		if length - o.gap[2] > 1 then
			barbedCoil(m, cf * CF(o.gap[2], h, 0), length - o.gap[2], 0.85, 1.25)
		end
	else
		barbedCoil(m, cf * CF(0, h, 0), length, 0.85, 1.25)
	end
end

-- Сетка-рабица: столбы, верхняя труба, полотно с ромбами, местами сорванное
local function chainRun(m, cf, length, o, rng)
	local h = o.height or 9
	local spacing = o.spacing or 1.3
	local panels = math.max(1, math.ceil(length / 10))
	local pw = length / panels
	local postColor = o.postColor or rgb(78, 80, 82)
	local lib = AssetLibrary.Has("Fences")
	for i = 0, panels do
		local x = i * pw
		if not fenceGap(o, x - 0.5, x + 0.5) then
			vcyl(m, h + 1.3, 0.34, cf * CF(x, 0, 0) * leanCF(rng, o.lean, 0.1) * CF(0, (h + 1.3) / 2, 0), postColor, M.Metal)
		end
	end
	for i = 0, panels - 1 do
		local x0, x1 = i * pw, (i + 1) * pw
		local xc = (x0 + x1) / 2
		if not fenceGap(o, x0, x1) then
			if lib then
				AssetLibrary.Spawn("Fences", cf * CF(xc, 0, 0), rng, m)
			else
				hcyl(m, pw + 0.1, 0.22, cf * CF(xc, h + 0.35, 0), postColor, M.Metal, false)
				if rng:NextNumber() < (o.broken or 0) then
					-- сорванное полотно висит наискось
					local p = mk(m, V3(pw * 0.92, h * 0.85, 0.08), cf * CF(xc, 0.3, 0) * ANG(rad(-62) + rng:NextNumber(-0.2, 0.2), 0, 0) * CF(0, h * 0.42, 0), C.mesh, M.Metal,
						{ Transparency = 0.82, CastShadow = false, CanQuery = false, CanCollide = false })
					meshGui(p, Enum.NormalId.Front, pw * 0.92, h * 0.85, spacing, C.mesh, 0.1)
				else
					local p = mk(m, V3(pw, h - 0.4, 0.08), cf * CF(xc, (h - 0.4) / 2 + 0.25, 0), C.mesh, M.Metal,
						{ Transparency = 0.84, CastShadow = false, CanQuery = false, CanCollide = o.collide ~= false })
					meshGui(p, Enum.NormalId.Front, pw, h - 0.4, spacing, C.mesh, 0.1)
					meshGui(p, Enum.NormalId.Back, pw, h - 0.4, spacing, C.mesh, 0.1)
				end
			end
		end
	end
	fenceCoil(m, cf, length, h + 1.1, o)
end

-- Бетонные плиты с ромбическим рельефом и колючкой сверху
local function concreteRun(m, cf, length, o, rng)
	local h = o.height or 8
	local panels = math.max(1, math.floor(length / 10 + 0.5))
	local pw = length / panels
	local base = o.color or rgb(122, 120, 112)
	for i = 0, panels do
		local x = i * pw
		if not fenceGap(o, x - 0.6, x + 0.6) then
			mk(m, V3(0.9, h + 0.8, 0.9), cf * CF(x, 0, 0) * leanCF(rng, o.lean, 0.07) * CF(0, (h + 0.8) / 2, 0), base:Lerp(rgb(0, 0, 0), 0.14), M.Concrete)
		end
	end
	for i = 0, panels - 1 do
		local x0, x1 = i * pw, (i + 1) * pw
		local xc = (x0 + x1) / 2
		if not fenceGap(o, x0, x1) then
			local roll = rng:NextNumber()
			local color = base:Lerp(rgb(78, 76, 70), rng:NextNumber(0, 0.35))
			if roll < (o.broken or 0) * 0.5 then
				-- плита выпала: обломки у основания
				mk(m, V3(pw * 0.5, 0.7, 2.2), cf * CF(xc, 0.35, -1.5) * ANG(0, rng:NextNumber(-0.3, 0.3), rng:NextNumber(-0.12, 0.12)), color, M.Concrete)
			elseif roll < (o.broken or 0) then
				-- плита завалилась наружу
				mk(m, V3(pw - 0.2, h, 0.5), cf * CF(xc, 0, 0) * ANG(-rad(rng:NextNumber(16, 34)), 0, 0) * CF(0, h / 2, 0), color, M.Concrete)
			else
				local p = mk(m, V3(pw - 0.1, h, 0.5), cf * CF(xc, h / 2 + rng:NextNumber(-0.1, 0.1), 0), color, M.Concrete)
				meshGui(p, Enum.NormalId.Front, pw - 0.1, h, 2.6, color:Lerp(rgb(0, 0, 0), 0.45), 0.72, 4, 8, 240)
				if rng:NextNumber() < 0.16 then
					local spray = signText(p, GRAFFITI[rng:NextInteger(1, #GRAFFITI)], GRAFFITI_COLORS[rng:NextInteger(1, #GRAFFITI_COLORS)], Enum.NormalId.Front, false, Enum.Font.GothamBlack)
					spray.LightInfluence = 1
					local label = spray:FindFirstChildOfClass("TextLabel")
					if label then
						label.Size = UDim2.fromScale(0.82, 0.3)
						label.Position = UDim2.fromScale(0.09, 0.42)
						label.Rotation = rng:NextNumber(-5, 5)
						label.TextTransparency = 0.2
					end
				end
			end
		end
	end
	fenceCoil(m, cf, length, h + 1.1, o)
end

-- Профлист: столбы, прожилины и листы с гофрой, часть погнута или сорвана
CONST.SHEET_COLORS = { rgb(122, 76, 46), rgb(96, 104, 96), rgb(72, 92, 110), rgb(148, 144, 134), rgb(104, 60, 40), rgb(86, 98, 72) }

local function sheetRun(m, cf, length, o, rng)
	local h = o.height or 7.5
	local postColor = rgb(58, 56, 54)
	local posts = math.max(1, math.ceil(length / 8))
	local pstep = length / posts
	for i = 0, posts do
		local x = i * pstep
		if not fenceGap(o, x - 0.4, x + 0.4) then
			mk(m, V3(0.5, h + 0.4, 0.5), cf * CF(x, 0, 0.42) * leanCF(rng, o.lean, 0.09) * CF(0, (h + 0.4) / 2 - 0.2, 0), postColor, M.Metal)
		end
	end
	for i = 0, posts - 1 do
		local x0, x1 = i * pstep, (i + 1) * pstep
		if not fenceGap(o, x0, x1) then
			for _, y in ipairs({ 1.4, h - 1.2 }) do
				deco(m, V3(pstep, 0.32, 0.28), cf * CF((x0 + x1) / 2, y, 0.3), postColor, M.Metal, { CastShadow = false })
			end
		end
	end
	local n = math.max(1, math.floor(length / 4 + 0.5))
	local sw = length / n
	for i = 0, n - 1 do
		local x0 = i * sw
		if not fenceGap(o, x0, x0 + sw) and rng:NextNumber() >= (o.broken or 0) then
			local color = CONST.SHEET_COLORS[rng:NextInteger(1, #CONST.SHEET_COLORS)]:Lerp(C.rust, rng:NextNumber(0, 0.4))
			local bend = rng:NextNumber() < 0.12 and rng:NextNumber(-0.3, 0.3) or 0
			local sh = h + rng:NextNumber(-0.4, 0.3)
			local p = mk(m, V3(sw + 0.12, sh, 0.14), cf * CF(x0, 0, 0) * ANG(0, bend, 0) * CF(sw / 2, sh / 2 + 0.1, 0), color, rng:NextNumber() < 0.6 and M.CorrodedMetal or M.Metal)
			stripeGui(p, Enum.NormalId.Front, sw, 0.62, color:Lerp(rgb(0, 0, 0), 0.5), 0.55)
		end
	end
	fenceCoil(m, cf, length, h + 0.9, o)
end

-- Дощатый забор: столбы, прожилины и группы досок с щелями; местами доски выломаны
local function plankRun(m, cf, length, o, rng)
	local h = o.height or 6.5
	local wood = o.color or C.fenceWood
	local posts = math.max(1, math.ceil(length / 7))
	local pstep = length / posts
	for i = 0, posts do
		local x = i * pstep
		if not fenceGap(o, x - 0.4, x + 0.4) then
			mk(m, V3(0.55, h + 0.7, 0.55), cf * CF(x, 0, 0.35) * leanCF(rng, o.lean, 0.13) * CF(0, (h + 0.7) / 2 - 0.3, 0), wood:Lerp(rgb(0, 0, 0), 0.3), M.Wood)
		end
	end
	for i = 0, posts - 1 do
		local x0, x1 = i * pstep, (i + 1) * pstep
		if fenceGap(o, x0, x1) then
			continue
		end
		for _, y in ipairs({ 1.3, h - 1.1 }) do
			deco(m, V3(pstep, 0.42, 0.26), cf * CF((x0 + x1) / 2, y, 0.26), wood:Lerp(rgb(0, 0, 0), 0.22), M.Wood, { CastShadow = false })
		end
		local broken = rng:NextNumber() < (o.broken or 0)
		local groups = broken and 1 or rng:NextInteger(1, 2)
		local cursor = x0 + 0.1
		local avail = pstep - 0.2 - (broken and pstep * rng:NextNumber(0.35, 0.6) or 0)
		for g = 1, groups do
			local gw = groups == 1 and avail or (avail - 0.5) * (g == 1 and rng:NextNumber(0.35, 0.65) or 1)
			gw = math.min(gw, x1 - 0.1 - cursor)
			if gw > 0.6 then
				local ph = h + rng:NextNumber(-0.35, 0.25)
				local color = wood:Lerp(rgb(126, 120, 108), rng:NextNumber(0, 0.4))
				local p = mk(m, V3(gw, ph, 0.24), cf * CF(cursor + gw / 2, ph / 2 + 0.05, 0), color, M.WoodPlanks,
					{ CanCollide = o.collide ~= false, CastShadow = false })
				stripeGui(p, Enum.NormalId.Front, gw, 0.8, rgb(38, 32, 26), 0.35)
				stripeGui(p, Enum.NormalId.Back, gw, 0.8, rgb(38, 32, 26), 0.45)
				if o.snow then
					deco(m, V3(gw, 0.22, 0.34), cf * CF(cursor + gw / 2, ph + 0.12, 0), C.snow, M.Snow, { CastShadow = false })
				end
				cursor = cursor + gw + rng:NextNumber(0.35, 0.8)
			end
		end
		if broken and rng:NextNumber() < 0.6 then
			-- выломанная доска лежит рядом
			deco(m, V3(rng:NextNumber(2, 4), 0.22, 0.6), cf * CF(x0 + pstep * 0.6, 0.12, -rng:NextNumber(0.8, 2.2)) * ANG(0, rng:NextNumber(-1, 1), 0), wood, M.WoodPlanks, { CastShadow = false })
		end
	end
end

-- Облезлый штакетник: редкие столбы, две прожилины, штакетины разной высоты, часть выломана
local function picketRun(m, cf, length, o, rng)
	local h = o.height or 4
	local paint = o.color or C.fencePaint
	local metal = o.metal
	local posts = math.max(1, math.ceil(length / 8))
	local pstep = length / posts
	for i = 0, posts do
		local x = i * pstep
		if not fenceGap(o, x - 0.35, x + 0.35) then
			mk(m, V3(0.5, h + 0.9, 0.5), cf * CF(x, 0, 0.2) * leanCF(rng, o.lean, 0.12) * CF(0, (h + 0.9) / 2 - 0.3, 0),
				metal and rgb(52, 50, 48) or paint:Lerp(rgb(64, 58, 48), 0.55), metal and M.Metal or M.Wood)
		end
	end
	for i = 0, posts - 1 do
		local x0, x1 = i * pstep, (i + 1) * pstep
		if not fenceGap(o, x0, x1) then
			for _, y in ipairs({ 0.9, h - 0.7 }) do
				deco(m, V3(pstep, 0.28, 0.2), cf * CF((x0 + x1) / 2, y, 0.18), metal and rgb(48, 46, 44) or paint:Lerp(rgb(64, 58, 48), 0.45), metal and M.Metal or M.Wood, { CastShadow = false })
			end
		end
	end
	local step = o.spacing or 1.3
	local n = math.max(1, math.floor(length / step))
	step = length / n
	for i = 0, n - 1 do
		local x = i * step + step / 2
		if not fenceGap(o, x - 0.3, x + 0.3) and rng:NextNumber() >= (o.broken or 0) * 0.6 then
			local ph = h + rng:NextNumber(-0.3, 0.25)
			if rng:NextNumber() < (o.broken or 0) * 0.5 then
				ph = ph * rng:NextNumber(0.45, 0.7)
			end
			local color = metal and rgb(56, 54, 52):Lerp(C.rust, rng:NextNumber(0, 0.45))
				or paint:Lerp(rgb(96, 88, 74), rng:NextNumber(0.1, 0.65))
			mk(m, V3(metal and 0.24 or 0.48, ph, metal and 0.24 or 0.16), cf * CF(x, 0, 0) * ANG(rng:NextNumber(-0.03, 0.03), 0, rng:NextNumber(-0.05, 0.05) + (rng:NextNumber() < (o.lean or 0) * 0.5 and rng:NextNumber(-0.2, 0.2) or 0)) * CF(0, ph / 2, 0),
				color, metal and M.Metal or M.Wood, { CastShadow = false })
		end
	end
end

-- Жерди на столбах (пастбище, поля)
local function railRun(m, cf, length, o, rng)
	local h = o.height or 4.5
	local wood = o.color or rgb(92, 76, 58)
	local posts = math.max(1, math.ceil(length / 9))
	local pstep = length / posts
	for i = 0, posts do
		local x = i * pstep
		if not fenceGap(o, x - 0.4, x + 0.4) then
			mk(m, V3(0.6, h + 0.6, 0.6), cf * CF(x, 0, 0) * leanCF(rng, o.lean or 0.25, 0.16) * CF(0, (h + 0.6) / 2 - 0.3, 0), wood:Lerp(rgb(0, 0, 0), 0.25), M.Wood)
		end
	end
	for i = 0, posts - 1 do
		local x0, x1 = i * pstep, (i + 1) * pstep
		if not fenceGap(o, x0, x1) then
			for j, y in ipairs({ h * 0.45, h * 0.86 }) do
				local roll = rng:NextNumber()
				if roll >= (o.broken or 0) * 0.5 then
					local fallen = roll < (o.broken or 0)
					local color = wood:Lerp(rgb(128, 120, 104), rng:NextNumber(0, 0.35))
					if fallen and j == 2 then
						deco(m, V3(pstep, 0.34, 0.3), cf * CF((x0 + x1) / 2, y * 0.4, 0.3) * ANG(0, 0, rng:NextNumber(0.25, 0.5)), color, M.Wood, { CastShadow = false })
					else
						mk(m, V3(pstep + 0.5, 0.34, 0.3), cf * CF((x0 + x1) / 2, y + rng:NextNumber(-0.08, 0.08), 0) * ANG(rng:NextNumber(-0.02, 0.02), 0, rng:NextNumber(-0.02, 0.02)), color, M.Wood,
							{ CanCollide = o.collide ~= false, CastShadow = false })
					end
				end
			end
			if o.snow then
				deco(m, V3(pstep, 0.18, 0.4), cf * CF((x0 + x1) / 2, h * 0.86 + 0.24, 0), C.snow, M.Snow, { CastShadow = false })
			end
		end
	end
end

CONST.FENCES = {
	chain = { build = chainRun, name = "ChainFence", per = 0.32, extra = 4 },
	concrete = { build = concreteRun, name = "ConcreteFence", per = 0.24, extra = 4 },
	sheet = { build = sheetRun, name = "SheetFence", per = 0.42, extra = 4 },
	plank = { build = plankRun, name = "PlankFence", per = 0.48, extra = 3 },
	picket = { build = picketRun, name = "PicketFence", per = 0.95, extra = 3 },
	iron = { build = picketRun, name = "IronFence", per = 0.95, extra = 3 },
	rail = { build = railRun, name = "RailFence", per = 0.36, extra = 2 },
}

-- Сколько деталей займёт забор (оценка сверху, для бюджета чанка)
local function fenceCost(style, length)
	local f = CONST.FENCES[style] or CONST.FENCES.plank
	return math.ceil(length * f.per) + f.extra
end

-- Забор стиля style вдоль локальной X от cf
local function fenceRun(parent, cf, length, style, rng, o)
	o = o or {}
	local f = CONST.FENCES[style] or CONST.FENCES.plank
	if style == "iron" then
		o.metal = true
		o.height = o.height or 5.5
		o.spacing = o.spacing or 1.6
	end
	local m = model(parent, f.name)
	f.build(m, cf, length, o, rng or Random.new(math.floor(math.abs(cf.X) * 13 + math.abs(cf.Z) * 7) % 1000003 + 11))
	return m
end
Props.FenceRun = fenceRun

-- Совместимость с v4: рабица
local function chainFence(parent, cf, length, opts)
	return fenceRun(parent, cf, length, "chain", nil, opts or {})
end
Props.ChainFence = chainFence

-- Сторожевая вышка: ноги с раскосами, площадка с перилами, навес, прожектор и лестница.
-- opts: simple (меньше раскосов и без стоек навеса), light (прожектор, по умолчанию да)
local function watchtower(parent, cf, height, rng, opts)
	opts = opts or {}
	rng = rng or Random.new(7)
	local m = model(parent, "Watchtower")
	height = height or 22
	local half = 3.2
	local span = half * 2
	local steel = rgb(58, 60, 62)
	for _, x in ipairs({ -half, half }) do
		for _, z in ipairs({ -half, half }) do
			mk(m, V3(0.6, height, 0.6), cf * CF(x, height / 2, z), steel, M.Metal)
		end
	end
	-- раскосы крест-накрест на каждой грани и обвязка посередине
	local levels = opts.simple and { 0.3 } or { 0.26, 0.68 }
	for face = 0, 3 do
		local fcf = cf * ANG(0, face * math.pi / 2, 0) * CF(0, 0, -half)
		for _, lv in ipairs(levels) do
			local segH = height * (lv > 0.5 and 0.36 or 0.44)
			local braceLen = math.sqrt(span * span + segH * segH)
			for sgn = -1, 1, 2 do
				deco(m, V3(braceLen, 0.28, 0.28), fcf * CF(0, height * lv, 0) * ANG(0, 0, sgn * math.atan2(segH, span)), steel, M.Metal, { CastShadow = false })
			end
		end
		deco(m, V3(span, 0.34, 0.34), fcf * CF(0, height * 0.52, 0), steel, M.Metal, { CastShadow = false })
	end
	-- площадка с перилами
	local deck = mk(m, V3(span + 1.8, 0.5, span + 1.8), cf * CF(0, height, 0), rgb(64, 64, 62), M.DiamondPlate)
	deck.Name = "Deck"
	local rr = (span + 1.8) / 2 - 0.2
	for _, corner in ipairs({ { -rr, -rr }, { rr, -rr }, { -rr, rr }, { rr, rr } }) do
		deco(m, V3(0.26, 3.4, 0.26), cf * CF(corner[1], height + 1.95, corner[2]), steel, M.Metal, { CastShadow = false })
	end
	for face = 0, 3 do
		local fcf = cf * ANG(0, face * math.pi / 2, 0) * CF(0, 0, -rr)
		for _, y in ipairs({ 1.6, 3.2 }) do
			hcyl(m, rr * 2, 0.2, fcf * CF(0, height + y, 0), steel, M.Metal, false)
		end
	end
	-- навес
	local postH = 4.4
	if not opts.simple then
		for _, corner in ipairs({ { -rr + 0.4, -rr + 0.4 }, { rr - 0.4, -rr + 0.4 }, { -rr + 0.4, rr - 0.4 }, { rr - 0.4, rr - 0.4 } }) do
			deco(m, V3(0.3, postH, 0.3), cf * CF(corner[1], height + 0.25 + postH / 2, corner[2]), steel, M.Metal, { CastShadow = false })
		end
	end
	local roof = mk(m, V3(span + 3, 0.4, span + 3), cf * CF(0, height + postH + 0.6, 0) * ANG(rad(5), 0, 0), rgb(52, 54, 52), M.CorrodedMetal)
	roof.CastShadow = true
	-- лестница с поручнями
	truss(m, cf * CF(0, 0, half + 1), height, steel)
	for _, x in ipairs({ -1.2, 1.2 }) do
		deco(m, V3(0.16, height, 0.16), cf * CF(x, height / 2, half + 1.9), steel, M.Metal, { CastShadow = false })
	end
	if opts.light ~= false then
		local lampCF = cf * CF(half - 0.4, height + 3.4, -half + 0.4) * ANG(rad(-25), rad(rng:NextNumber(-40, 40)), 0)
		deco(m, V3(1.2, 1.2, 1.6), lampCF, C.metalDark, M.Metal)
		local lens = deco(m, V3(1, 1, 0.1), lampCF * CF(0, 0, -0.85), rgb(255, 240, 210), M.Neon)
		local spot = Instance.new("SpotLight")
		spot.Face = Enum.NormalId.Front
		spot.Range = 55
		spot.Angle = 40
		spot.Brightness = 2
		spot.Color = rgb(255, 236, 200)
		spot.Parent = lens
		nightLamp(lens, rgb(150, 146, 136), "Glass")
	end
	return m
end
Props.Watchtower = watchtower

-- Камуфляжная палатка (двускатная), cf — центр на земле, длина вдоль локальной Z
local function camoTent(parent, cf, rng, w, len)
	local m = model(parent, "CamoTent")
	w = w or 10
	len = len or 14
	local h = w * 0.55
	local slope = math.sqrt((w / 2) ^ 2 + h * h)
	local ang = math.atan2(h, w / 2)
	local base = rgb(70, 80, 56)
	local patches = { rgb(46, 54, 38), rgb(96, 92, 66), rgb(34, 38, 30), rgb(84, 100, 64) }
	for _, sgn in ipairs({ -1, 1 }) do
		local panelCF = cf * CF(sgn * w / 4, h / 2, 0) * ANG(0, 0, -sgn * ang)
		mk(m, V3(slope, 0.2, len), panelCF, base, M.Fabric)
		for _ = 1, 4 do
			deco(m, V3(rng:NextNumber(1.5, slope * 0.5), 0.05, rng:NextNumber(2, 5)), panelCF * CF(rng:NextNumber(-slope * 0.3, slope * 0.3), 0.12, rng:NextNumber(-len * 0.38, len * 0.38)) * ANG(0, rng:NextNumber(-0.6, 0.6), 0), patches[rng:NextInteger(1, #patches)], M.Fabric)
		end
	end
	-- торцы: задний закрыт, передний с тёмным входом
	prism(m, cf * CF(0, 0, len / 2 - 0.1) * ANG(0, rad(90), 0), w, h, 0.15, base:Lerp(rgb(0, 0, 0), 0.15), M.Fabric)
	prism(m, cf * CF(0, 0, -len / 2 + 0.1) * ANG(0, rad(90), 0), w * 0.45, h * 0.45, 0.15, rgb(18, 20, 16), M.Fabric, false)
	return m
end
Props.CamoTent = camoTent

-- Бетонный блок-отбойник
local function jersey(parent, cf, len)
	local m = model(parent, "Barrier")
	mk(m, V3(2.4, 1.2, len), cf * CF(0, 0.6, 0), C.concrete, M.Concrete)
	prism(m, cf * CF(0, 1.2, 0) * ANG(0, rad(90), 0), 2.2, 1.8, len, C.concrete, M.Concrete)
	deco(m, V3(2.45, 0.3, len * 0.3), cf * CF(0, 1.0, len * 0.2), rgb(170, 150, 60), M.Concrete)
	return m
end

function Props.MakeNPC(parent, cf, shirt, name)
	local m = model(parent, "NPC")
	local skin = rgb(206, 170, 140)
	local torso = mk(m, V3(2, 2, 1), cf * CF(0, 3, 0), shirt)
	local head = mk(m, V3(2, 1, 1), cf * CF(0, 4.5, 0), skin)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Head
	mesh.Scale = V3(1.25, 1.25, 1.25)
	mesh.Parent = head
	mk(m, V3(1, 2, 1), cf * CF(-1.5, 3, 0), shirt:Lerp(rgb(0, 0, 0), 0.2))
	mk(m, V3(1, 2, 1), cf * CF(1.5, 3, 0), shirt:Lerp(rgb(0, 0, 0), 0.2))
	mk(m, V3(1, 2, 1), cf * CF(-0.5, 1, 0), rgb(46, 46, 52))
	mk(m, V3(1, 2, 1), cf * CF(0.5, 1, 0), rgb(46, 46, 52))
	deco(m, V3(2.1, 1.6, 0.2), cf * CF(0, 2.8, -0.55), rgb(120, 110, 90), M.Fabric)
	deco(m, V3(1.4, 0.4, 1.4), cf * CF(0, 5.15, 0), rgb(50, 54, 46), M.Fabric)
	deco(m, V3(0.25, 0.25, 0.1), cf * CF(-0.3, 4.6, -0.6), rgb(20, 20, 20))
	deco(m, V3(0.25, 0.25, 0.1), cf * CF(0.3, 4.6, -0.6), rgb(20, 20, 20))
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(200, 40)
	bb.StudsOffset = V3(0, 2.2, 0)
	bb.MaxDistance = 70
	bb.Adornee = head
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = name
	label.TextColor3 = rgb(255, 230, 150)
	label.TextStrokeTransparency = 0.3
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = bb
	bb.Parent = head
	return torso
end

-- Здания --------------------------------------------------------------------------------
-- fpFront/fpBack/fpSide — насколько пристройки выходят за стены (для проверки места)
local Kinds = {
	gas_station = { w = 18, d = 14, h = 9, wall = rgb(150, 150, 146), wallMat = M.Concrete, roof = rgb(96, 40, 36), loot = "gas_station", shelves = 1, sign = "ТОПЛИВО", signColor = C.neonYellow, extra = "canopy", fpFront = 18.5, fpSide = 5, fpBack = 6, grates = true,
		roofStyle = "flat", awning = true, boarded = 0.3, tank = 0.25, blade = true, yard = { style = "sheet", back = 4, side = 3.5, height = 7, broken = 0.3 } },
	motel = { w = 30, d = 12, h = 9, wall = rgb(120, 82, 62), wallMat = M.Brick, roof = rgb(64, 50, 44), loot = "motel", beds = 2, sign = "МОТЕЛЬ", signColor = rgb(255, 110, 150), fpFront = 5.5,
		roofStyle = "flat", porch = "walkway", boarded = 0.35, tank = 0.2 },
	ranch = { w = 20, d = 16, h = 10, wall = rgb(96, 72, 52), wallMat = M.WoodPlanks, roof = rgb(60, 48, 40), loot = "ranch", beds = 1, shelves = 1, extra = "farm", fpFront = 10.5, fpBack = 10.5, fpSide = 8.5,
		roofStyle = "gable", porch = "wood", boarded = 0.25, yard = { style = "rail", front = 8, back = 7.5, side = 6.5, gate = true, broken = 0.25 } },
	store = { w = 26, d = 20, h = 12, wall = C.tile, wallMat = M.Concrete, tiled = true, roof = rgb(60, 60, 62), loot = "store", shelves = 3, sign = "ПРОДУКТЫ", signColor = rgb(110, 210, 255), safe = 0.12, grates = true,
		roofStyle = "flat", awning = true, boarded = 0.15, tank = 0.5, blade = true },
	pharmacy = { w = 18, d = 16, h = 10, wall = rgb(150, 154, 150), wallMat = M.Concrete, tiled = true, roof = rgb(56, 70, 60), loot = "pharmacy", shelves = 2, sign = "АПТЕКА", signColor = C.neonGreen, extra = "cross",
		roofStyle = "flat", awning = true, boarded = 0.2, tank = 0.3, blade = true },
	police = { w = 26, d = 18, h = 11, wall = rgb(78, 88, 104), wallMat = M.Concrete, roof = rgb(40, 44, 54), loot = "police", shelves = 2, sign = "ПОЛИЦИЯ", signColor = rgb(110, 160, 255), safe = 0.25, extra = "policecar", fpFront = 12.5, fpSide = 11.5, fpBack = 5, grates = true, wire = true,
		roofStyle = "flat", tank = 0.4, yard = { style = "chain", side = 9, back = 3, height = 8, coil = true } },
	apartment = { w = 24, d = 18, h = 28, wall = C.brick, wallMat = M.Brick, roof = rgb(50, 46, 46), loot = "apartment", beds = 2, shelves = 1, floors = true, safe = 0.12, fpSide = 5,
		roofStyle = "flat", tank = 0.6, fireEscape = true, balconies = true, boarded = 0.2 },
	stilt_hut = { w = 14, d = 12, h = 8, wall = rgb(90, 72, 50), wallMat = M.WoodPlanks, roof = rgb(70, 80, 50), roofMat = M.Grass, loot = "stilt_hut", beds = 1, stilts = true, fpFront = 5, fpBack = 3,
		roofStyle = "gable", porch = "deck", boarded = 0.2 },
	crypt = { w = 12, d = 14, h = 10, wall = rgb(92, 94, 90), wallMat = M.Cobblestone, roof = rgb(66, 66, 64), roofMat = M.Slate, loot = "crypt", shelves = 1, safe = 0.3, extra = "graves", fpFront = 15.5, fpSide = 13.5,
		roofStyle = "gable", yard = { style = "iron", front = 13, side = 11, back = 2, gate = true, broken = 0.2 } },
	boathouse = { w = 16, d = 12, h = 8, wall = rgb(74, 62, 50), wallMat = M.WoodPlanks, roof = rgb(50, 44, 38), roofMat = M.CorrodedMetal, loot = "boathouse", shelves = 1, extra = "pier", fpBack = 21.5, fpSide = 6.5,
		roofStyle = "gable", boarded = 0.4, yard = { style = "plank", side = 4.5, height = 6, broken = 0.5 } },
	cabin = { w = 16, d = 14, h = 9, wall = rgb(84, 62, 44), wallMat = M.Wood, roof = rgb(228, 234, 242), roofMat = M.Snow, loot = "cabin", beds = 1, shelves = 1, safe = 0.12, extra = "chimney", fpFront = 8, fpSide = 7, fpBack = 6.5,
		roofStyle = "gable", porch = "wood", yard = { style = "plank", front = 6, side = 5, back = 4.5, gate = true, snow = true, broken = 0.3, height = 6 } },
	weather_station = { w = 12, d = 10, h = 8, wall = rgb(150, 152, 150), wallMat = M.Concrete, roof = rgb(100, 44, 40), loot = "weather_station", shelves = 1, extra = "mast", fpSide = 7.5, fpFront = 6, fpBack = 6,
		roofStyle = "flat", tank = 0.2, yard = { style = "chain", front = 5, back = 5, side = 6, gate = true, height = 8 } },
	bunker = { w = 20, d = 16, h = 7, wall = rgb(92, 94, 88), wallMat = M.Concrete, roof = rgb(72, 74, 70), loot = "bunker", shelves = 2, safe = 0.3, extra = "sandbags", fpFront = 6.5, fpSide = 7, fpBack = 7, wire = true,
		roofStyle = "flat", yard = { style = "concrete", side = 5, back = 5, height = 7, coil = true, broken = 0.25 } },
	camp = { open = "camp", d = 20, r = 14 },
	temple = { open = "temple", d = 34, r = 20.5 },
	military_wreck = { open = "military", d = 20, r = 16 },
}
Props.Kinds = Kinds

-- hx, hz, смещение центра площадки по локальной Z (плюс — от дороги)
local function kindFootprint(k)
	if k.open then
		return k.r, k.r, 0
	end
	local front = k.d / 2 + (k.fpFront or 2)
	local back = k.d / 2 + (k.fpBack or 2)
	local side = k.w / 2 + (k.fpSide or 2)
	return side, (front + back) / 2, (back - front) / 2
end

-- Фасады ------------------------------------------------------------------------------------------
-- Переплёт окна рисуется кадрами на стекле (деталей не тратит)
local function mullionGui(pane, color)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 12
	gui.LightInfluence = 1
	gui.ClipsDescendants = true
	gui.MaxDistance = 260
	for _, bar in ipairs({ { 0.5, 0.5, 0, 1 }, { 0.5, 0.36, 1, 0 } }) do
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.BackgroundColor3 = color
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(bar[1], bar[2])
		f.Size = UDim2.new(bar[3], bar[3] == 0 and 3 or 0, bar[4], bar[4] == 0 and 3 or 0)
		f.Parent = gui
	end
	gui.Parent = pane
	return gui
end

-- Перекладины (лестницы, решётки ограждений) на грани детали
local function rungGui(part, face, height, step, color)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 10
	gui.LightInfluence = 1
	gui.ClipsDescendants = true
	gui.MaxDistance = 220
	local n = math.max(2, math.floor(height / step))
	for i = 1, n - 1 do
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.BackgroundColor3 = color
		f.AnchorPoint = Vector2.new(0, 0.5)
		f.Position = UDim2.fromScale(0, i / n)
		f.Size = UDim2.new(1, 0, 0, 3)
		f.Parent = gui
	end
	for _, px in ipairs({ 0.08, 0.92 }) do
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.BackgroundColor3 = color
		f.AnchorPoint = Vector2.new(0.5, 0)
		f.Position = UDim2.fromScale(px, 0)
		f.Size = UDim2.new(0, 4, 1, 0)
		f.Parent = gui
	end
	gui.Parent = part
	return gui
end

-- Окно: наличник, стекло с переплётом, подоконник и перемычка.
-- style: "glass" | "lit" | "boarded" | "grate"; cf — центр окна на плоскости стены, −Z наружу
local function window2(parent, cf, ww, wh, style, rng, trim)
	local frameColor = trim or rgb(54, 54, 56)
	deco(parent, V3(ww + 0.7, wh + 0.7, 0.25), cf * CF(0, 0, -0.12), frameColor, M.Metal)
	if style == "boarded" then
		deco(parent, V3(ww, wh, 0.2), cf * CF(0, 0, -0.2), rgb(16, 16, 18), M.SmoothPlastic, { CastShadow = false })
		local n = rng and rng:NextInteger(2, 3) or 3
		for i = 1, n do
			local t = (i - 0.5) / n - 0.5
			deco(parent, V3(ww + 0.9, wh * 0.26, 0.16), cf * CF(rng and rng:NextNumber(-0.3, 0.3) or 0, t * wh, -0.34) * ANG(0, 0, rng and rng:NextNumber(-0.16, 0.16) or 0.1),
				rgb(104, 84, 60):Lerp(rgb(70, 58, 44), i * 0.2), M.WoodPlanks, { CastShadow = false })
		end
	else
		local pane
		if style == "lit" then
			-- ночью окно светится тёплым светом, днём это тёмное стекло
			pane = deco(parent, V3(ww, wh, 0.25), cf * CF(0, 0, -0.2), rgb(255, 190, 120), M.Neon, { Transparency = 0.25, CastShadow = false })
			pane:SetAttribute("NightOffTransparency", 0.15)
			nightLamp(pane, C.glass, "Glass")
		else
			pane = deco(parent, V3(ww, wh, 0.25), cf * CF(0, 0, -0.2), C.glass, M.Glass, { Transparency = 0.15, Reflectance = 0.05 })
		end
		mullionGui(pane, frameColor:Lerp(rgb(200, 200, 192), 0.35))
		if style == "grate" then
			for i = -1, 1 do
				deco(parent, V3(0.15, wh + 0.4, 0.15), cf * CF(i * ww / 3, 0, -0.45), rgb(40, 40, 42), M.Metal, { CastShadow = false })
			end
			deco(parent, V3(ww + 0.4, 0.15, 0.15), cf * CF(0, 0, -0.45), rgb(40, 40, 42), M.Metal, { CastShadow = false })
		end
	end
	deco(parent, V3(ww + 1, 0.3, 0.7), cf * CF(0, -wh / 2 - 0.45, -0.3), C.concreteDark, M.Concrete)
	deco(parent, V3(ww + 1, 0.4, 0.5), cf * CF(0, wh / 2 + 0.5, -0.22), C.concreteDark, M.Concrete, { CastShadow = false })
end

-- Совместимость с v4
local function realWindow(parent, cf, ww, wh, grate, lit)
	window2(parent, cf, ww, wh, lit and "lit" or (grate and "grate" or "glass"), nil, nil)
end

-- Кондиционер на стене (−Z наружу)
local function acUnit(parent, cf)
	deco(parent, V3(2.6, 1.8, 1.4), cf * CF(0, 0, -0.7), rgb(170, 170, 164), M.Metal)
	deco(parent, V3(1.5, 1.5, 0.1), cf * CF(-0.4, 0, -1.42), rgb(60, 60, 60), M.DiamondPlate, { CastShadow = false })
	deco(parent, V3(2.1, 0.22, 0.5), cf * CF(0, -1.05, -0.5), rgb(70, 70, 72), M.Metal, { CastShadow = false })
end

-- Цоколь: выступающая полоса по низу фасада и боков (проём двери не перекрываем)
local function plinthOf(parent, base, w, dd, doorW, color)
	local segW = (w - doorW) / 2
	for _, sx in ipairs({ -1, 1 }) do
		deco(parent, V3(segW + 0.3, 1.2, 0.5), base * CF(sx * (doorW / 2 + segW / 2), 0.6, -dd / 2 - 0.12), color, M.Concrete, { CastShadow = false })
		deco(parent, V3(0.5, 1.2, dd + 0.3), base * CF(sx * (w / 2 + 0.1), 0.6, 0), color, M.Concrete, { CastShadow = false })
	end
end

-- Карниз по верху стен
local function corniceOf(parent, base, w, dd, h, color)
	deco(parent, V3(w + 0.8, 0.5, 0.6), base * CF(0, h - 0.55, -dd / 2 - 0.28), color, M.Concrete, { CastShadow = false })
	deco(parent, V3(w + 1.5, 0.55, 1.1), base * CF(0, h - 0.05, -dd / 2 - 0.5), color, M.Concrete)
	for _, sx in ipairs({ -1, 1 }) do
		deco(parent, V3(0.9, 0.55, dd + 1.1), base * CF(sx * (w / 2 + 0.35), h - 0.05, 0), color, M.Concrete, { CastShadow = false })
	end
end

-- Дверной проём: наличники, перемычка, приоткрытая створка и козырёк
local function doorway(parent, base, dd, doorW, doorH, k, rng, awning)
	local z = -dd / 2
	local trim = (k.wall or C.concrete):Lerp(rgb(20, 20, 20), 0.4)
	for _, sx in ipairs({ -1, 1 }) do
		deco(parent, V3(0.45, doorH + 0.4, 0.5), base * CF(sx * (doorW / 2 + 0.22), (doorH + 0.4) / 2, z - 0.2), trim, M.Concrete, { CastShadow = false })
	end
	deco(parent, V3(doorW + 1.3, 0.55, 0.6), base * CF(0, doorH + 0.3, z - 0.2), trim, M.Concrete, { CastShadow = false })
	deco(parent, V3(doorW - 0.4, doorH - 0.3, 0.2), base * CF(-doorW / 2 + 0.2, (doorH - 0.3) / 2, z + 0.4) * ANG(0, rad(78), 0) * CF((doorW - 0.4) / 2, 0, 0),
		rgb(58, 46, 36), M.Wood, { CastShadow = false })
	if awning then
		local aw = doorW + 2.6
		mk(parent, V3(aw, 0.3, 2.4), base * CF(0, doorH + 1.3, z - 1.2) * ANG(rad(12), 0, 0), k.awningColor or rgb(96, 46, 40), M.Metal)
		for _, sx in ipairs({ -1, 1 }) do
			deco(parent, V3(0.2, 0.2, 2.6), base * CF(sx * (aw / 2 - 0.4), doorH + 0.6, z - 1.1) * ANG(rad(-38), 0, 0), C.metalDark, M.Metal, { CastShadow = false })
		end
	end
end

-- Скатная крыша со свесом: два ската, фронтоны, конёк, иногда труба
local function gableRoof(parent, base, w, dd, h, k, rng)
	local pitch = rad(30)
	local ov = 1.6
	local halfD = dd / 2 + ov
	local rise = halfD * math.tan(pitch)
	local slope = halfD / math.cos(pitch)
	local color = k.roof or rgb(60, 48, 40)
	local mat = k.roofMat or M.RoofShingles
	for _, sz in ipairs({ -1, 1 }) do
		mk(parent, V3(w + ov * 2, 0.45, slope), base * CF(0, h + 0.4 + rise / 2, sz * halfD / 2) * ANG(-sz * pitch, 0, 0), color, mat)
	end
	for _, sx in ipairs({ -1, 1 }) do
		prism(parent, base * CF(sx * (w / 2 - 0.3), h + 0.5, 0), dd, rise, 0.7, k.wall or C.concrete, k.wallMat or M.Concrete, false)
	end
	deco(parent, V3(w + ov * 2 + 0.3, 0.45, 0.9), base * CF(0, h + 0.5 + rise, 0), color:Lerp(rgb(0, 0, 0), 0.25), mat)
	if rng:NextNumber() < 0.5 then
		local ch = mk(parent, V3(2.2, rise + 2.4, 2.2), base * CF(rng:NextNumber(-w / 3, w / 3), h + (rise + 2.4) / 2 + 0.4, dd / 5), rgb(90, 56, 48), M.Brick)
		deco(parent, V3(2.6, 0.4, 2.6), ch.CFrame * CF(0, (rise + 2.4) / 2 + 0.2, 0), rgb(70, 44, 38), M.Brick, { CastShadow = false })
	end
end

-- Плоская крыша: парапет, люк, вентиляция, кондиционеры и бак с водой
local function flatRoof(parent, base, w, dd, h, k, rng, can)
	local color = (k.wall or C.concrete):Lerp(rgb(20, 20, 20), 0.25)
	if can(4) then
		for _, sz in ipairs({ -1, 1 }) do
			deco(parent, V3(w + 0.8, 1.2, 0.5), base * CF(0, h + 1.4, sz * (dd / 2 - 0.05)), color, k.wallMat or M.Concrete)
		end
		for _, sx in ipairs({ -1, 1 }) do
			deco(parent, V3(0.5, 1.2, dd + 0.8), base * CF(sx * (w / 2 - 0.05), h + 1.4, 0), color, k.wallMat or M.Concrete, { CastShadow = false })
		end
	end
	if can(2) then
		deco(parent, V3(2.4, 0.7, 2.4), base * CF(rng:NextNumber(-w / 5, w / 5), h + 1.15, rng:NextNumber(0, dd / 4)), rgb(78, 80, 78), M.DiamondPlate, { CastShadow = false })
		vcyl(parent, 2.2, 1, base * CF(rng:NextNumber(-w / 3, w / 3), h + 1.9, rng:NextNumber(-dd / 4, 0)), rgb(92, 94, 92), M.Metal, false)
	end
	if can(3) then
		local acf = base * CF(rng:NextNumber(-w / 3, w / 3), h + 1.9, rng:NextNumber(-dd / 4, dd / 4)) * ANG(0, rng:NextNumber(0, math.pi), 0)
		deco(parent, V3(3.2, 2, 2.6), acf, rgb(150, 150, 146), M.Metal)
		deco(parent, V3(2.2, 0.16, 2.2), acf * CF(0, 1.05, 0), rgb(60, 60, 62), M.DiamondPlate, { CastShadow = false })
		deco(parent, V3(3.3, 0.3, 2.7), acf * CF(0, -1.05, 0), rgb(70, 70, 72), M.Metal, { CastShadow = false })
	end
	if k.tank and rng:NextNumber() < k.tank and can(3) then
		local tcf = base * CF(rng:NextNumber(-w / 4, w / 4), h + 0.9, rng:NextNumber(-dd / 4, dd / 4))
		deco(parent, V3(4.4, 1.4, 4.4), tcf * CF(0, 0.7, 0), rgb(72, 70, 66), M.Metal)
		vcyl(parent, 4.2, 4.2, tcf * CF(0, 3.5, 0), rgb(92, 76, 58), M.Wood)
		vcyl(parent, 0.4, 4.4, tcf * CF(0, 5.7, 0), rgb(70, 72, 70), M.Metal, false)
	end
end

-- Крыльцо с навесом и ступенями (−Z — к дороге)
local function porchOf(parent, base, dd, doorW, doorH, k, rng)
	local deckW = doorW + 6
	local deckZ = -dd / 2 - 2.6
	mk(parent, V3(deckW, 0.6, 5), base * CF(0, 0.7, deckZ), rgb(104, 84, 60), M.WoodPlanks)
	mk(parent, V3(deckW - 1.4, 0.35, 1.2), base * CF(0, 0.32, deckZ - 2.9), rgb(96, 78, 56), M.WoodPlanks)
	for _, sx in ipairs({ -1, 1 }) do
		mk(parent, V3(0.45, doorH + 0.8, 0.45), base * CF(sx * (deckW / 2 - 0.5), (doorH + 0.8) / 2 + 1, deckZ - 2.2), rgb(96, 78, 56), M.Wood)
		deco(parent, V3(0.3, 1.1, 4.6), base * CF(sx * (deckW / 2 - 0.5), 2, deckZ), rgb(96, 78, 56), M.Wood, { CastShadow = false })
	end
	mk(parent, V3(deckW + 1.2, 0.4, 6), base * CF(0, doorH + 2, deckZ - 0.6) * ANG(rad(10), 0, 0), k.roof or rgb(60, 48, 40), k.roofMat or M.RoofShingles)
	if rng:NextNumber() < 0.5 then
		deco(parent, V3(1.6, 1.6, 1.6), base * CF(deckW / 2 - 2, 1.6, deckZ + 1), rgb(96, 84, 60), M.Wood, { CastShadow = false })
	end
end

-- Балкон с решётчатым ограждением
local function balconyOf(parent, cf, bw, color)
	mk(parent, V3(bw, 0.35, 2.6), cf * CF(0, 0, -1.3), C.concrete, M.Concrete)
	local rail = deco(parent, V3(bw, 1.7, 0.16), cf * CF(0, 0.95, -2.55), color, M.Metal, { CastShadow = false })
	stripeGui(rail, Enum.NormalId.Front, bw, 0.55, color:Lerp(rgb(0, 0, 0), 0.5), 0.25, 4)
	for _, sx in ipairs({ -1, 1 }) do
		deco(parent, V3(0.16, 1.7, 2.6), cf * CF(sx * (bw / 2 - 0.08), 0.95, -1.3), color, M.Metal, { CastShadow = false })
	end
end

-- Пожарная лестница на боковой стене (наружу по −X): площадки, марши и лестница вниз
local function fireEscapeOf(parent, base, w, dd, h, floorY, floorH)
	local steel = rgb(58, 56, 54)
	local x = -w / 2
	local y = floorY
	local dir = 1
	local n = 0
	while y < h - 3 and n < 4 do
		mk(parent, V3(3.2, 0.3, 7), base * CF(x - 1.6, y, dd * 0.1), steel, M.DiamondPlate)
		deco(parent, V3(0.16, 2.2, 7), base * CF(x - 3.1, y + 1.2, dd * 0.1), steel, M.Metal, { CastShadow = false })
		if y + floorH < h - 3 then
			local run = 5.4
			mk(parent, V3(1.6, 0.25, math.sqrt(run * run + floorH * floorH)), base * CF(x - 1.6, y + floorH / 2, dd * 0.1 + dir * (3.5 - run / 2)) * ANG(dir * math.atan2(floorH, run), 0, 0), steel, M.DiamondPlate)
		end
		y = y + floorH
		dir = -dir
		n = n + 1
	end
	local ladder = deco(parent, V3(0.12, floorY - 2.4, 2.2), base * CF(x - 2.4, (floorY - 2.4) / 2 + 2.2, dd * 0.1 + 2.6), steel, M.Metal, { Transparency = 1, CastShadow = false })
	rungGui(ladder, Enum.NormalId.Left, floorY - 2.4, 1.1, steel)
	rungGui(ladder, Enum.NormalId.Right, floorY - 2.4, 1.1, steel)
end

-- Водосток: труба с отводом сверху и сливом внизу
local function drainpipe(parent, cf, h, color)
	vcyl(parent, h - 1.2, 0.45, cf * CF(0, (h - 1.2) / 2 + 0.6, 0), color, M.Metal, false)
	deco(parent, V3(0.7, 0.5, 0.9), cf * CF(0, h - 0.5, 0.2), color, M.Metal, { CastShadow = false })
	deco(parent, V3(0.5, 0.6, 0.7), cf * CF(0, 0.5, -0.25) * ANG(rad(25), 0, 0), color, M.Metal, { CastShadow = false })
end

-- Вывеска-«флаг» перпендикулярно фасаду
CONST.SHOP_SIGNS = { "ХЛЕБ", "ОПТИКА", "РЕМОНТ", "ПРОДУКТЫ", "БАР", "ШИНЫ", "ЛОМБАРД", "СВЯЗЬ", "АРЕНДА", "ОБУВЬ" }

local function bladeSign(parent, cf, text, color)
	deco(parent, V3(0.24, 0.24, 1.4), cf * CF(0, 1.1, -0.7), C.metalDark, M.Metal, { CastShadow = false })
	local board = deco(parent, V3(0.2, 2, 3.6), cf * CF(0, 0, -2.2), rgb(26, 26, 28), M.Metal)
	signText(board, text, color, Enum.NormalId.Right, true, Enum.Font.GothamBold)
	signText(board, text, color, Enum.NormalId.Left, true, Enum.Font.GothamBold)
	lightAt(board, 9, 0.5, color)
end

-- Забор участка вокруг здания: фасадный (с калиткой), боковые и задний
local function yardFence(c, parent, base, k, rng, can)
	local y = k.yard
	if not y then
		return
	end
	local w, dd = k.w, k.d
	local front, back, side = y.front or 0, y.back or 0, y.side or 0
	local zF, zB = -dd / 2 - front, dd / 2 + back
	local wide = w + side * 2
	local runs = {}
	if front > 0 then
		runs[1] = { cf = base * CF(-(w / 2 + side), 0, zF), len = wide, gate = y.gate }
	end
	if back > 0 then
		runs[#runs + 1] = { cf = base * CF(w / 2 + side, 0, zB) * ANG(0, math.pi, 0), len = wide }
	end
	if side > 0 then
		runs[#runs + 1] = { cf = base * CF(-(w / 2 + side), 0, zB) * ANG(0, rad(90), 0), len = zB - zF }
		runs[#runs + 1] = { cf = base * CF(w / 2 + side, 0, zF) * ANG(0, rad(-90), 0), len = zB - zF }
	end
	for _, r in ipairs(runs) do
		if r.len > 4 and can(fenceCost(y.style, r.len)) then
			local o = { height = y.height, broken = y.broken or 0.15, lean = y.lean or 0.25, coil = y.coil, snow = y.snow }
			if r.gate then
				o.gap = { r.len / 2 - 2.75, r.len / 2 + 2.75 }
			end
			fenceRun(parent, r.cf, r.len, y.style, rng, o)
			box(c, r.cf * CF(r.len / 2, 0, 0), r.len / 2, 0.9, true, nil, { kind = "fence" })
		end
	end
end

local extras = {}

extras.canopy = function(c, m, base, k)
	local z = -k.d / 2 - 10
	for _, x in ipairs({ -9, 9 }) do
		for _, dz in ipairs({ -5, 5 }) do
			vcyl(m, 13, 1, base * CF(x, 6.5, z + dz), rgb(120, 120, 118), M.Metal)
		end
	end
	mk(m, V3(24, 1.2, 16), base * CF(0, 13.5, z), rgb(120, 44, 38), M.Metal)
	deco(m, V3(24.2, 0.5, 16.2), base * CF(0, 12.9, z), rgb(160, 160, 150), M.Metal)
	lightAt(deco(m, V3(2, 0.2, 2), base * CF(0, 12.6, z), rgb(255, 240, 210), M.Neon), 30, 1.2)
	for _, x in ipairs({ -3.5, 3.5 }) do
		local pump = mk(m, V3(1.6, 3.6, 2.2), base * CF(x, 1.8, z), rgb(120, 46, 38), M.Metal)
		deco(m, V3(1.2, 0.8, 0.1), pump.CFrame * CF(0, 0.8, -1.12), rgb(20, 20, 20), M.Glass)
	end
	box(c, base * CF(0, 0, z), 12.5, 8.5, true, nil, { kind = "building" })
end

-- Хозяйство ранчо: стог сена, поилка и бочка (сам забор участка ставит yardFence)
extras.farm = function(_, m, base, k, rng)
	mk(m, V3(3.4, 3, 5), base * CF(k.w / 2 + 3.5, 1.5, 3.5) * ANG(0, rng:NextNumber(-0.3, 0.3), 0), rgb(150, 130, 80), M.Grass)
	deco(m, V3(1.6, 1.4, 5), base * CF(-k.w / 2 - 3, 0.7, 1), rgb(96, 78, 56), M.WoodPlanks)
	deco(m, V3(1.2, 1, 4.4), base * CF(-k.w / 2 - 3, 1.05, 1), rgb(48, 56, 52), M.Slate, { CastShadow = false })
	barrel(m, base * CF(k.w / 2 + 2, 0, -k.d / 2 + 2), rgb(84, 64, 44))
end

extras.cross = function(_, m, base, k)
	local p = base * CF(k.w / 2 - 2, k.h - 1, -k.d / 2 - 0.6)
	deco(m, V3(3, 0.9, 0.3), p, C.neonGreen, M.Neon)
	deco(m, V3(0.9, 3, 0.3), p, C.neonGreen, M.Neon)
end

extras.policecar = function(c, m, base, k, rng)
	local cf = base * CF(k.w / 2 + 5, 0, -k.d / 2 - 6) * ANG(0, rad(70), 0)
	local car = carWreck(m, cf, rng, rgb(180, 180, 184))
	deco(car, V3(1.2, 0.4, 0.8), cf * CF(-0.8, 4.7, 0.8), rgb(150, 30, 30), M.Glass)
	deco(car, V3(1.2, 0.4, 0.8), cf * CF(0.8, 4.7, 0.8), rgb(30, 50, 150), M.Glass)
	box(c, cf, 3.3, 6.3, true, car)
end

extras.graves = function(c, m, base, k, rng)
	for _ = 1, 6 do
		local g = model(m, "Grave")
		local cf = base * CF(rng:NextNumber(-18, 18), 0, -k.d / 2 - rng:NextNumber(3, 14)) * ANG(0, rng:NextNumber(-0.3, 0.3), rng:NextNumber(-0.1, 0.1))
		if rng:NextNumber() < 0.5 then
			mk(g, V3(2.2, 3, 0.6), cf * CF(0, 1.5, 0), rgb(100, 100, 96), M.Slate)
		else
			mk(g, V3(0.5, 4, 0.5), cf * CF(0, 2, 0), rgb(56, 48, 40), M.Wood)
			mk(g, V3(2.4, 0.5, 0.5), cf * CF(0, 3, 0), rgb(56, 48, 40), M.Wood)
		end
		circle(c, cf, 1.2, false, g)
	end
	mk(m, V3(0.8, 3, 0.8), base * CF(0, k.h + 1.5, 0), rgb(80, 80, 80), M.Slate)
	mk(m, V3(2.6, 0.7, 0.8), base * CF(0, k.h + 2.2, 0), rgb(80, 80, 80), M.Slate)
end

extras.pier = function(c, m, base, k)
	deco(m, V3(26, 0.3, 20), base * CF(0, 0.1, k.d / 2 + 11), rgb(36, 46, 42), M.Glass, { Transparency = 0.2 })
	local plank = mk(m, V3(4, 0.6, 14), base * CF(-4, 0.9, k.d / 2 + 8), rgb(84, 68, 52), M.WoodPlanks)
	box(c, plank.CFrame, 2, 7, false, plank)
end

extras.chimney = function(_, m, base, k)
	local ch = mk(m, V3(2.5, 6, 2.5), base * CF(k.w / 2 - 3, k.h + 2.5, 2), rgb(90, 56, 48), M.Brick)
	local smoke = Instance.new("Smoke")
	smoke.Size = 3
	smoke.RiseVelocity = 4
	smoke.Opacity = 0.12
	smoke.Color = rgb(120, 120, 120)
	smoke.Parent = ch
end

extras.mast = function(c, m, base, k)
	local mast = vcyl(m, 30, 1.2, base * CF(k.w / 2 + 5, 15, 0), rgb(120, 120, 120), M.Metal)
	circle(c, mast.CFrame, 1.2, true, nil)
	local beacon = ball(m, 1, base * CF(k.w / 2 + 5, 30.5, 0), rgb(255, 50, 40), M.Neon, false)
	lightAt(beacon, 16, 1.5, rgb(255, 60, 60))
end

extras.sandbags = function(_, m, base, k)
	for i = -3, 3 do
		deco(m, V3(2.6, 1.2, 1.4), base * CF(i * 2.7, 0.6, -k.d / 2 - 5), rgb(120, 110, 84), M.Fabric)
		deco(m, V3(2.6, 1.2, 1.4), base * CF(i * 2.7 + 1.3, 1.8, -k.d / 2 - 5), rgb(110, 100, 76), M.Fabric)
	end
end

local function shell(c, kind, cf, k)
	local key = posKey("b", cf.Position)
	local rng = Random.new(hashSeed(key))
	local m = model(c.folder, kind)
	local w, dd, h = k.w, k.d, k.h
	local base = cf
	local reserve = c.buildReserve or 0
	local function can(need)
		return afford(c, need, reserve)
	end
	local wallMat = k.wallMat or M.SmoothPlastic
	local wallColor = k.wall
	local trimColor = wallColor:Lerp(rgb(20, 20, 20), 0.35)
	local doorW, doorH = 5, 7
	local segW = (w - doorW) / 2
	local gable = k.roofStyle == "gable"
	-- сваи и лестница на них
	if k.stilts then
		base = cf * CF(0, 6, 0)
		for _, x in ipairs({ -w / 2 + 1, w / 2 - 1 }) do
			for _, z in ipairs({ -dd / 2 + 1, dd / 2 - 1 }) do
				vcyl(m, 6, 1, cf * CF(x, 3, z), rgb(70, 58, 44), M.Wood)
			end
		end
		truss(m, cf * CF(w / 2 - 1.2, 0, -dd / 2 - 1.4), 6, rgb(70, 58, 44))
	end
	-- коробка
	mk(m, V3(w, 0.4, dd), base * CF(0, 0.2, 0), k.floorColor or rgb(76, 72, 66), k.floorMat or (k.wallMat == M.WoodPlanks and M.WoodPlanks or M.Concrete))
	mk(m, V3(w, h, 0.8), base * CF(0, h / 2, dd / 2 - 0.4), wallColor, wallMat)
	local left = mk(m, V3(0.8, h, dd), base * CF(-w / 2 + 0.4, h / 2, 0), wallColor, wallMat)
	mk(m, V3(0.8, h, dd), base * CF(w / 2 - 0.4, h / 2, 0), wallColor, wallMat)
	local fronts = {}
	for _, sx in ipairs({ -1, 1 }) do
		table.insert(fronts, mk(m, V3(segW, h, 0.8), base * CF(sx * (doorW / 2 + segW / 2), h / 2, -dd / 2 + 0.4), wallColor, wallMat))
	end
	if h > doorH then
		mk(m, V3(doorW, h - doorH, 0.8), base * CF(0, doorH + (h - doorH) / 2, -dd / 2 + 0.4), wallColor, wallMat)
	end
	if k.tiled then
		for _, p in ipairs(fronts) do
			seamGrid(p, Enum.NormalId.Front, math.max(2, math.floor(segW / 1.4)), math.max(2, math.floor(h / 1.4)), C.tileSeam, 0.3)
		end
	end
	left.Name = "Wall"
	-- потолочная лампа и настенный фонарь у входа (горят ночью)
	local ceilingY = k.floors and 9.6 or (h - 0.3)
	lightAt(deco(m, V3(3, 0.2, 0.5), base * CF(0, ceilingY, 0), rgb(255, 236, 200), M.Neon), math.max(w, dd) + 2, 0.6)
	local sconce = deco(m, V3(0.6, 0.8, 0.5), base * CF(doorW / 2 + 1, doorH - 1, -dd / 2 - 0.3), rgb(255, 214, 160), M.Neon, { CastShadow = false })
	local sconceLight = Instance.new("PointLight")
	sconceLight.Range = 16
	sconceLight.Brightness = 1.1
	sconceLight.Color = rgb(255, 204, 150)
	sconceLight.Parent = sconce
	nightLamp(sconce, rgb(110, 106, 96), "Glass")
	-- окна первого этажа: рамы с подоконниками и переплётом, часть заколочена, часть светится ночью
	local function windowStyle()
		if k.boarded and rng:NextNumber() < k.boarded then
			return "boarded"
		end
		if rng:NextNumber() < 0.3 then
			return "lit"
		end
		return k.grates and "grate" or "glass"
	end
	for _, sx in ipairs({ -1, 1 }) do
		window2(m, base * CF(sx * (doorW / 2 + segW / 2), 4.2, -dd / 2), math.min(segW * 0.55, 5), 2.8, windowStyle(), rng, trimColor)
		window2(m, base * CF(sx * w / 2, 4.2, 0) * ANG(0, -sx * rad(90), 0), math.min(dd * 0.4, 5), 2.8, windowStyle(), rng, trimColor)
	end
	-- верхние этажи: окна рисуются на накладке фасада, к ним — подоконники и балконы
	local upperH, upperRows, upperCols = 0, 0, 0
	if k.floors then
		mk(m, V3(w - 1.6, 0.6, dd - 1.6), base * CF(0, 10, 0), rgb(70, 66, 60), M.Concrete)
		upperH = h - 11
		upperRows = math.max(1, math.floor(upperH / 6))
		upperCols = math.max(2, math.floor(w / 6))
		local over = deco(m, V3(w - 1, upperH, 0.05), base * CF(0, 11 + upperH / 2, -dd / 2 - 0.03), wallColor, wallMat)
		windowGui(over, Enum.NormalId.Front, upperCols, upperRows, rgb(110, 104, 96), 0.03, rng)
		nightWindows(over, Enum.NormalId.Front, upperCols, upperRows, 0.22, rng)
		local side = deco(m, V3(0.05, upperH, dd - 1), base * CF(-w / 2 - 0.03, 11 + upperH / 2, 0), wallColor, wallMat)
		windowGui(side, Enum.NormalId.Left, math.max(2, math.floor(dd / 6)), upperRows, rgb(110, 104, 96), 0.03, rng)
		nightWindows(side, Enum.NormalId.Left, math.max(2, math.floor(dd / 6)), upperRows, 0.18, rng)
		for y = 11, h - 4, 6 do
			deco(m, V3(w + 0.4, 0.4, 0.5), base * CF(0, y, -dd / 2 - 0.2), wallColor:Lerp(rgb(30, 30, 30), 0.3), M.Concrete)
		end
	end
	-- крыша: скатная со свесом или плоская с парапетом
	mk(m, V3(w + 0.6, 0.8, dd + 0.6), base * CF(0, h + 0.4, 0), k.roof, gable and M.Concrete or (k.roofMat or M.Concrete))
	if gable then
		gableRoof(m, base, w, dd, h, k, rng)
	else
		deco(m, V3(w + 1.4, 0.7, 1.2), base * CF(0, h - 0.2, -dd / 2 - 0.3), k.roof:Lerp(rgb(20, 20, 20), 0.2), M.Concrete)
		if not k.stilts then
			flatRoof(m, base, w, dd, h, k, rng, can)
		end
		if rng:NextNumber() < 0.45 and can(2) then
			local ax = base * CF(rng:NextNumber(-w / 3, w / 3), h + 0.8, dd / 4)
			deco(m, V3(0.18, 6, 0.18), ax * CF(0, 3, 0), rgb(70, 70, 72), M.Metal, { CastShadow = false })
			deco(m, V3(3, 0.14, 0.14), ax * CF(0, 5, 0) * ANG(0, rng:NextNumber(0, 3), 0), rgb(70, 70, 72), M.Metal, { CastShadow = false })
		end
	end
	-- граффити на боковой стене
	if rng:NextNumber() < 0.35 then
		local spray = signText(left, GRAFFITI[rng:NextInteger(1, #GRAFFITI)], GRAFFITI_COLORS[rng:NextInteger(1, #GRAFFITI_COLORS)], Enum.NormalId.Left, false, Enum.Font.GothamBlack)
		spray.LightInfluence = 1
		local label = spray:FindFirstChildOfClass("TextLabel")
		if label then
			label.Size = UDim2.fromScale(0.8, 0.22)
			label.Position = UDim2.fromScale(0.1, 0.62)
			label.Rotation = rng:NextNumber(-7, 7)
			label.TextTransparency = 0.15
		end
	end
	if k.wire then
		barbedCoil(m, base * CF(-w / 2, h + 2.4, -dd / 2 + 0.05), w, 0.7, 1.4)
	end
	if k.sign then
		local len = utf8.len(k.sign) or #k.sign
		local board = mk(m, V3(math.max(7, len * 1.5), 2.2, 0.35), base * CF(0, math.min(h - 1.6, doorH + 1.6), -dd / 2 - 0.3), rgb(24, 24, 26), M.Metal)
		signText(board, k.sign, k.signColor, Enum.NormalId.Front, true)
		lightAt(board, 10, 0.6, k.signColor)
	end
	box(c, cf, w / 2 + 0.6 + (k.fireEscape and 3 or 0), dd / 2 + 0.6 + (k.stilts and 2.6 or 0), true, nil, { kind = "building" })

	-- Полки, койки и места для добычи
	local spots = {}
	for i = 1, (k.shelves or 0) do
		local zz = dd / 2 - 1.6 - (i - 1) * 4.5
		if zz > -dd / 2 + 3 then
			mk(m, V3(w - 5, 0.3, 1.6), base * CF(0.5, 3, zz), rgb(84, 70, 54), M.Wood)
			deco(m, V3(0.3, 3, 1.4), base * CF(-w / 2 + 3.2, 1.5, zz), rgb(64, 54, 44), M.Metal)
			deco(m, V3(0.3, 3, 1.4), base * CF(w / 2 - 2.2, 1.5, zz), rgb(64, 54, 44), M.Metal)
			for j = 1, 3 do
				table.insert(spots, base * CF(-w / 2 + 3 + (j - 0.5) * (w - 6) / 3, 3.15, zz))
			end
		end
	end
	for _ = 1, 3 do
		table.insert(spots, base * CF(rng:NextNumber(-w / 2 + 2.5, w / 2 - 2.5), 0.4, rng:NextNumber(-dd / 2 + 3, dd / 2 - 3.5)))
	end
	for i = 1, math.min(k.beds or 0, 2) do
		local side = i == 1 and -1 or 1
		local bedCF = base * CF(side * (w / 2 - 2.6), 0.8, -dd / 2 + 4.5)
		local bed = mk(m, V3(3.2, 0.8, 7), bedCF, rgb(90, 60, 50), M.Fabric)
		deco(m, V3(2.4, 0.4, 1.2), bed.CFrame * CF(0, 0.55, 2.6), rgb(170, 166, 156), M.Fabric)
		S.Sleep.RegisterBed(bed, "house", V3(-side * 3, 2.5, 0))
	end
	-- добыча создаётся до отделки: её детали тоже входят в бюджет чанка
	counted(m, S.Loot.SpawnFromTable, k.loot, spots, rng, m, key)
	if k.safe and rng:NextNumber() < k.safe then
		counted(m, S.Loot.SpawnSafe, base * CF(w / 2 - 2.5, 0.4, dd / 2 - 3.5) * ANG(0, rad(180), 0), m, rng, key .. "_safe")
	end
	addSpawner(c, cf.Position, zombieCount(c, rng), key .. "_z")

	-- Отделка фасада — по остатку бюджета чанка
	if not k.stilts and can(4) then
		plinthOf(m, base, w, dd, doorW, (k.plinthColor or C.concreteDark))
	end
	if not gable and can(4) then
		corniceOf(m, base, w, dd, h, trimColor)
	end
	if can(k.awning and 7 or 4) then
		doorway(m, base, dd, doorW, doorH, k, rng, k.awning and can(7))
	end
	if k.porch == "wood" and can(8) then
		porchOf(m, base, dd, doorW, doorH, k, rng)
	elseif k.porch == "walkway" and can(8) then
		mk(m, V3(w + 1, 0.4, 4), base * CF(0, 0.2, -dd / 2 - 2), rgb(96, 94, 90), M.Concrete)
		for i = 0, 4 do
			mk(m, V3(0.4, doorH + 1.2, 0.4), base * CF(-w / 2 + i * (w / 4), (doorH + 1.2) / 2, -dd / 2 - 3.6), rgb(86, 84, 80), M.Metal)
		end
		mk(m, V3(w + 2, 0.4, 4.6), base * CF(0, doorH + 1.4, -dd / 2 - 2.2) * ANG(rad(8), 0, 0), k.roof, M.Metal)
	elseif k.porch == "deck" and can(3) then
		mk(m, V3(7.4, 0.4, 3), base * CF(0.7, 0.2, -dd / 2 - 1.4), rgb(96, 78, 56), M.WoodPlanks)
		deco(m, V3(0.25, 1.4, 3), base * CF(-3, 0.9, -dd / 2 - 1.4), rgb(96, 78, 56), M.Wood, { CastShadow = false })
	elseif not k.stilts then
		mk(m, V3(doorW + 1.6, 0.35, 1.8), base * CF(0, 0.175, -dd / 2 - 0.9), rgb(84, 82, 78), M.Concrete)
	end
	-- подоконники и балконы верхних этажей
	if k.floors and upperRows > 0 then
		local winW = 0.5 / upperCols * (w - 1)
		local winH = 0.55 / upperRows * upperH
		local balconies = 0
		for r = 1, upperRows do
			for col = 1, upperCols do
				local x = ((col - 0.5) / upperCols - 0.5) * (w - 1)
				local y = 11 + upperH - ((r - 0.5) / upperRows) * upperH
				if can(1) then
					deco(m, V3(winW + 0.8, 0.26, 0.6), base * CF(x, y - winH / 2 - 0.2, -dd / 2 - 0.3), C.concreteDark, M.Concrete, { CastShadow = false })
				end
				if k.balconies and balconies < 3 and rng:NextNumber() < 0.4 and can(4) then
					balconies = balconies + 1
					balconyOf(m, base * CF(x, y - winH / 2 - 0.3, -dd / 2 - 0.1), winW + 1.6, rgb(72, 70, 66))
				end
			end
		end
	end
	if k.fireEscape and h >= 16 and can(11) then
		fireEscapeOf(m, base, w, dd, h, 11, 6)
	end
	-- водостоки по углам фасада
	if can(3) then
		drainpipe(m, base * CF(w / 2 - 0.2, 0, -dd / 2 - 0.35), h, rgb(60, 62, 60))
	end
	if can(3) then
		drainpipe(m, base * CF(-w / 2 + 0.2, 0, -dd / 2 - 0.35), h, rgb(60, 62, 60))
	end
	if rng:NextNumber() < 0.6 and can(3) then
		acUnit(m, base * CF(-w / 2, math.min(h - 2, 7.5), dd / 4) * ANG(0, rad(90), 0))
	end
	if k.blade and can(2) then
		bladeSign(m, base * CF(-segW * 0.6, doorH + 1.4, -dd / 2), k.sign or CONST.SHOP_SIGNS[rng:NextInteger(1, #CONST.SHOP_SIGNS)], k.signColor or C.neonYellow)
	end
	if k.yard then
		yardFence(c, m, base, k, rng, can)
	end
	if k.extra and extras[k.extra] then
		extras[k.extra](c, m, cf, k, rng)
	end
	return m
end

local open = {}

open.camp = function(c, cf)
	local key = posKey("camp", cf.Position)
	local rng = Random.new(hashSeed(key))
	local m = model(c.folder, "Camp")
	for i = 1, 2 do
		local a = (i / 2) * math.pi * 2 + 0.6
		local tcf = cf * CF(math.cos(a) * 8, 0, math.sin(a) * 8) * ANG(0, a, 0)
		camoTent(m, tcf, rng, 7, 9)
		circle(c, tcf, 4, true, nil)
	end
	local fire = deco(m, V3(1.5, 0.5, 1.5), cf * CF(0, 0.25, 0), rgb(40, 30, 20), M.Wood)
	local f = Instance.new("Fire")
	f.Size = 4
	f.Parent = fire
	lightAt(fire, 26, 2, rgb(255, 150, 60))
	local spots = {}
	for i = 1, 3 do
		local ccf = cf * CF(-6 + i * 3.2, 0, 6)
		crate(m, ccf, 2.6, i == 2)
		table.insert(spots, ccf * CF(0, 2.65, 0))
	end
	table.insert(spots, cf * CF(3, 0.1, -3))
	counted(m, S.Loot.SpawnFromTable, "camp", spots, rng, m, key)
	addSpawner(c, cf.Position, zombieCount(c, rng), key .. "_z")
	box(c, cf * CF(0, 0, 6), 5, 2, true, nil)
	return m
end

open.temple = function(c, cf)
	local key = posKey("t", cf.Position)
	local rng = Random.new(hashSeed(key))
	local m = model(c.folder, "Temple")
	local stone = rgb(96, 100, 90)
	local moss = rgb(56, 76, 50)
	mk(m, V3(34, 2, 34), cf * CF(0, 1, 0), stone, M.Cobblestone)
	mk(m, V3(26, 2, 24), cf * CF(0, 3, 3), stone, M.Cobblestone)
	mk(m, V3(10, 1, 3), cf * CF(0, 0.5, -18.5), stone, M.Cobblestone)
	mk(m, V3(10, 1, 3), cf * CF(0, 2.5, -10.5), stone, M.Cobblestone)
	for _, pos in ipairs({ { -11, -7 }, { 11, -7 }, { -11, 11 }, { 11, 11 } }) do
		local hh = rng:NextNumber(5, 12)
		vcyl(m, hh, 2.4, cf * CF(pos[1], 4 + hh / 2, pos[2]), stone, M.Slate)
		deco(m, V3(2.6, 1.2, 2.6), cf * CF(pos[1], 4 + hh * 0.4, pos[2]), moss, M.Grass)
	end
	mk(m, V3(20, 8, 2), cf * CF(0, 8, 14), stone, M.Cobblestone)
	deco(m, V3(20.2, 2, 2.2), cf * CF(0, 11, 14), moss, M.Grass)
	mk(m, V3(6, 2.5, 3), cf * CF(0, 5.25, 6), rgb(120, 120, 112), M.Marble)
	local spots = { cf * CF(-1.5, 6.5, 6), cf * CF(1.5, 6.5, 6), cf * CF(6, 4, -2), cf * CF(-6, 4, -2) }
	counted(m, S.Loot.SpawnFromTable, "temple", spots, rng, m, key)
	if rng:NextNumber() < 0.25 then
		counted(m, S.Loot.SpawnSafe, cf * CF(8, 4, 8) * ANG(0, rad(180), 0), m, rng, key .. "_safe")
	end
	addSpawner(c, (cf * CF(0, 4, -14)).Position, zombieCount(c, rng) + 1, key .. "_z")
	box(c, cf, 17.5, 17.5, true, nil, { kind = "building" })
	return m
end

open.military = function(c, cf)
	local key = posKey("mil", cf.Position)
	local rng = Random.new(hashSeed(key))
	local m = model(c.folder, "MilitaryWreck")
	local olive = rgb(62, 68, 50)
	local truckCF = cf * ANG(0, rng:NextNumber(-0.4, 0.4), rad(8))
	mk(m, V3(8, 5, 18), truckCF * CF(0, 3, 2), olive, M.CorrodedMetal)
	mk(m, V3(8, 4, 5), truckCF * CF(0, 2.8, -9.5), olive:Lerp(rgb(20, 20, 20), 0.3), M.Metal)
	deco(m, V3(8.4, 0.6, 18.4), truckCF * CF(0, 6, 2), rgb(40, 42, 34), M.Fabric)
	local smokePart = deco(m, V3(1, 1, 1), truckCF * CF(0, 5, -9), rgb(20, 20, 20))
	local smoke = Instance.new("Smoke")
	smoke.Color = rgb(40, 40, 40)
	smoke.Size = 6
	smoke.RiseVelocity = 6
	smoke.Opacity = 0.2
	smoke.Parent = smokePart
	box(c, truckCF, 4.5, 12, true, nil)
	local spots = {}
	for i = 1, 3 do
		local ccf = cf * CF(8 + i * 0.5, 0, -6 + i * 4)
		crate(m, ccf, 2.8, true)
		table.insert(spots, ccf * CF(0, 2.85, 0))
	end
	box(c, cf * CF(9, 0, 2), 2.4, 6.5, true, nil)
	counted(m, S.Loot.SpawnFromTable, "military_wreck", spots, rng, m, key)
	addSpawner(c, (cf * CF(10, 0, 0)).Position, zombieCount(c, rng), key .. "_z")
	return m
end

-- Здание по типу. c — контекст чанка {ci, folder, biome, s0}; недостающие поля заполняются.
function Props.Building(kind, cf, c)
	local k = Kinds[kind]
	if not k or typeof(cf) ~= "CFrame" then
		return nil
	end
	c = c or {}
	c.folder = c.folder or workspace:FindFirstChild("World") or workspace
	if c.ci == nil then
		c.ci = "props"
	end
	c.s0 = c.s0 or 0
	c.biome = c.biome or S.World.BiomeAtS(c.s0)
	if k.open then
		return open[k.open](c, cf)
	end
	return shell(c, kind, cf, k)
end

-- Поставить здание в (s, d) передом к дороге, если есть место
local function placeKind(c, kind, s, d)
	local k = Kinds[kind]
	if not k or math.abs(d) < 1 then
		return nil
	end
	local hx, hz, offZ = kindFootprint(k)
	local cf = facingRoad(s, d)
	local fpD = d + (d > 0 and 1 or -1) * offZ
	if not tryPlace(c, cf * CF(0, 0, offZ), hx, hz, { s = s, d = fpD }) then
		return nil
	end
	return Props.Building(kind, cf, c)
end

-- Земля и дорога ----------------------------------------------------------------------------
-- Поверхность дороги: выцветшая разметка, трещины, заплаты, пятна, выбоины, снег/песок у кромки.
-- Всё рисуется SurfaceGui на верхней грани полотна — без лишних деталей.
CONST.ROAD_PPS = 6

local function roadSurface(part, c, dirt, roadColor, s)
	local rng = c.rng
	local biomeId = c.biome and c.biome.id or "desert"
	local depot = type(s) == "number" and s < DEPOT_END
	if depot then
		-- улица депо: люки и заплаты вместо песка у кромки
		biomeId = "city"
	end
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = CONST.ROAD_PPS
	gui.LightInfluence = 1
	gui.ClipsDescendants = true
	gui.MaxDistance = 280
	local W, L = part.Size.X, part.Size.Z
	-- u — поперёк полотна от центра, v — вдоль; размеры в studs
	local function rect(u, v, w, h, color, transparency, rot, round)
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(0.5 + u / W, 0.5 + v / L)
		f.Size = UDim2.fromOffset(math.max(1, math.floor(w * CONST.ROAD_PPS + 0.5)), math.max(1, math.floor(h * CONST.ROAD_PPS + 0.5)))
		f.BackgroundColor3 = color
		f.BackgroundTransparency = transparency or 0
		f.Rotation = rot or 0
		if round then
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0.5, 0)
			corner.Parent = f
		end
		f.Parent = gui
		return f
	end
	local function crack(u, v, len, color)
		local a = rng:NextNumber(0, math.pi * 2)
		for _ = 1, rng:NextInteger(2, 3) do
			local l = len * rng:NextNumber(0.3, 0.5)
			local du, dv = math.cos(a) * l, math.sin(a) * l
			rect(u + du / 2, v + dv / 2, l, 0.17, color, 0.2, math.deg(a))
			u, v = u + du, v + dv
			a = a + rng:NextNumber(-0.9, 0.9)
		end
	end
	local function anyU(margin)
		return rng:NextNumber(-W / 2 + margin, W / 2 - margin)
	end
	local function anyV(margin)
		return rng:NextNumber(-L / 2 + margin, L / 2 - margin)
	end

	if dirt then
		-- грунтовка: колеи, лужи, листья
		for _, sd in ipairs({ -1, 1 }) do
			rect(sd * 4.5, 0, 1.3, L, roadColor:Lerp(rgb(0, 0, 0), 0.3), 0.45)
		end
		if rng:NextNumber() < 0.22 then
			local r = rng:NextNumber(2, 4)
			rect(anyU(4), anyV(2), r * 1.6, r, rgb(40, 44, 46), 0.2, rng:NextNumber(0, 180), true)
		end
		for _ = 1, rng:NextInteger(2, 5) do
			local leaf = rng:NextNumber() < 0.5 and rgb(70, 86, 40) or rgb(96, 70, 40)
			rect(anyU(1), anyV(0.5), rng:NextNumber(0.4, 0.8), rng:NextNumber(0.25, 0.5), leaf, 0.1, rng:NextNumber(0, 180))
		end
		gui.Parent = part
		return
	end

	local paint = rgb(192, 188, 172)
	local fade = rng:NextNumber(0.28, 0.6)
	if biomeId == "snow" or biomeId == "wasteland" then
		fade = math.min(0.85, fade + 0.2)
	end
	-- осевая прерывистая (штрих 6, промежуток 10), местами стёрта
	if rng:NextNumber() > 0.12 then
		rect(0, 0, 0.45, 6, paint, fade)
	end
	-- краевые линии
	for _, sd in ipairs({ -1, 1 }) do
		if rng:NextNumber() > 0.1 then
			rect(sd * (W / 2 - 1), 0, 0.35, L, paint, math.min(0.9, fade + 0.12))
		end
	end
	-- «зебра» перед магазином депо
	if depot and s >= 94 and s < 110 then
		for u = -W / 2 + 2, W / 2 - 2, 2.6 do
			rect(u, 0, 1.2, 6, paint, 0.22)
		end
	end
	-- трещины
	local crackColor = roadColor:Lerp(rgb(0, 0, 0), 0.6)
	for _ = 1, rng:NextInteger(0, biomeId == "wasteland" and 4 or 2) do
		crack(anyU(2), anyV(1), rng:NextNumber(3, 8), crackColor)
	end
	-- заплаты свежего и старого асфальта
	if rng:NextNumber() < 0.2 then
		local w, h = rng:NextNumber(3, 8), rng:NextNumber(2.5, 7)
		local shade = rng:NextNumber() < 0.7 and rgb(0, 0, 0) or rgb(140, 140, 136)
		rect(anyU(w / 2), anyV(h / 2), w, h, roadColor:Lerp(shade, rng:NextNumber(0.15, 0.3)), 0.08, rng:NextNumber(-6, 6))
	end
	-- масляные пятна на полосах движения
	if rng:NextNumber() < 0.22 then
		local r = rng:NextNumber(1.2, 2.6)
		rect(randSide(rng) * rng:NextNumber(3, 6), anyV(1), r * 1.4, r, rgb(12, 12, 14), rng:NextNumber(0.5, 0.72), rng:NextNumber(0, 180), true)
	end
	-- выбоина
	if rng:NextNumber() < 0.07 then
		local u, v = anyU(3), anyV(2)
		local r = rng:NextNumber(1.4, 2.4)
		rect(u, v, r * 1.25, r, roadColor:Lerp(rgb(150, 150, 150), 0.25), 0.3, 0, true)
		rect(u, v, r, r * 0.75, rgb(14, 14, 16), 0.15, 0, true)
	end
	if biomeId == "city" and rng:NextNumber() < 0.08 then
		-- канализационный люк
		local u, v = randSide(rng) * rng:NextNumber(2, 8), anyV(2)
		rect(u, v, 2.6, 2.6, rgb(58, 58, 60), 0.05, 0, true)
		rect(u, v, 2.1, 2.1, rgb(34, 34, 36), 0.05, 0, true)
		rect(u, v, 1.6, 0.2, rgb(70, 70, 72), 0.3)
	elseif biomeId == "snow" then
		for _, sd in ipairs({ -1, 1 }) do
			if rng:NextNumber() < 0.65 then
				rect(sd * (W / 2 - rng:NextNumber(0.3, 1.8)), anyV(0), rng:NextNumber(1.5, 4.5), rng:NextNumber(5, 14), rgb(226, 232, 240), 0.12, rng:NextNumber(-5, 5), true)
			end
		end
		if rng:NextNumber() < 0.3 then
			rect(anyU(3), anyV(2), rng:NextNumber(3, 6), rng:NextNumber(2, 5), rgb(200, 214, 228), 0.35, rng:NextNumber(0, 180), true)
		end
	elseif biomeId == "desert" or biomeId == "swamp" then
		local drift = biomeId == "desert" and rgb(188, 158, 108) or rgb(70, 60, 44)
		for _, sd in ipairs({ -1, 1 }) do
			if rng:NextNumber() < 0.4 then
				rect(sd * (W / 2 - rng:NextNumber(0.3, 1.5)), anyV(0), rng:NextNumber(1.5, 3.5), rng:NextNumber(4, 12), drift, 0.2, rng:NextNumber(-8, 8), true)
			end
		end
	elseif biomeId == "wasteland" and rng:NextNumber() < 0.35 then
		rect(anyU(3), anyV(2), rng:NextNumber(3, 7), rng:NextNumber(3, 6), rgb(26, 24, 22), 0.35, rng:NextNumber(0, 180), true)
	end
	gui.Parent = part
end

CONST.DEPOT_GROUND = rgb(50, 54, 44)
CONST.MUTE = { snow = 0.18, city = 0.3 }

-- Цвет и материал земли в точке s: цвета биома приглушены, у депо — тёмная земля
function Props.GroundStyle(s)
	s = tonumber(s) or 0
	local biome = S.World.BiomeAtS(s)
	local color = biome.ground:Lerp(rgb(68, 68, 64), CONST.MUTE[biome.id] or 0.45)
	local material = biome.groundMat
	local k = math.clamp((s - DEPOT_END) / 420, 0, 1)
	if k < 1 then
		color = CONST.DEPOT_GROUND:Lerp(color, k)
		if k < 0.5 then
			material = M.Ground
		end
	end
	return color, material
end

local function groundAndRoad(c)
	local b = c.biome
	local road = S.World.Road
	local width = 2 * (HW + WT) + 24
	local parts = 4
	local step = (c.s1 - c.s0) / parts
	for i = 0, parts - 1 do
		local sa = c.s0 + i * step
		local _, _, _, ha = road:Frame(sa)
		local _, _, _, hb = road:Frame(sa + step)
		local len = step + (width / 2) * math.abs(hb - ha) + 10
		local color, material = Props.GroundStyle(sa + step / 2)
		local shade = c.rng:NextNumber(-0.02, 0.02)
		color = Color3.new(math.clamp(color.R + shade, 0, 1), math.clamp(color.G + shade, 0, 1), math.clamp(color.B + shade, 0, 1))
		mk(c.folder, V3(width, 2, len), roadCF(sa + step / 2, 0) * CF(0, -1 + ((c.ci * parts + i) % 2) * 0.02, 0), color, material)
	end

	local seg = 16
	local dirt = b.id == "jungle"
	local roadMat = dirt and M.Ground or M.Asphalt
	local roadColor = dirt and rgb(64, 54, 42) or b.road:Lerp(C.asphalt, 0.65)
	local s = c.s0
	local idx = 0
	while s < c.s1 do
		local cf = roadCF(s + seg / 2, 0)
		-- соседние куски чуть разнесены по высоте, чтобы перекрытия не мерцали
		local slab = mk(c.folder, V3(RHW * 2, 0.3, seg + 1.4), cf * CF(0, 0.12 + ((math.floor(s / seg)) % 2) * 0.012, 0), roadColor, roadMat)
		roadSurface(slab, c, dirt, roadColor, s)
		s = s + seg
		idx = idx + 1
	end
	local mid = (c.s0 + c.s1) / 2
	if mid < DEPOT_END - 340 then
		return -- тротуары депо строит само депо
	end
	if b.id == "city" then
		for _, sd in ipairs({ -1, 1 }) do
			strip(c.folder, c.s0, c.s1, sd * (RHW + 0.5), 1, C.curb, M.Concrete, 0.6, 0.6, true)
			strip(c.folder, c.s0, c.s1, sd * (RHW + 4.5), 7, rgb(96, 96, 94), M.Concrete, 0.5, 0.5, true)
		end
	elseif not dirt then
		local gravel = b.id == "snow" and rgb(206, 212, 220) or rgb(74, 70, 64)
		for _, sd in ipairs({ -1, 1 }) do
			strip(c.folder, c.s0, c.s1, sd * (RHW + 1.8), 3.6, gravel, b.id == "snow" and M.Snow or M.Pebble, 0.08)
		end
	end
end

-- Стены границ ------------------------------------------------------------------------------
-- base: центр сегмента на земле, вперёд вдоль дороги; локальная X = вправо от дороги;
-- внутренняя сторона (к дороге) — локальная X = −sd
local wallStyles = {}

wallStyles.forest = function(folder, base, len, sd, rng)
	mk(folder, V3(WT, 90, len), base * CF(0, 45, 0), C.pine, M.Grass, { Transparency = 1, CastShadow = false })
	deco(folder, V3(WT - 4, 30, len), base * CF(sd * 2, 15, 0), rgb(24, 30, 26), M.Grass)
	pine(folder, base * CF(-sd * (WT / 2 - 4), 0, rng:NextNumber(-len / 3, len / 3)), rng:NextNumber(62, 84), rng, { lod = 1, sparse = true })
end

wallStyles.desert = function(folder, base, len, sd, rng)
	local h = rng:NextNumber(72, 104)
	local cliff = rgb(122, 98, 78):Lerp(rgb(100, 82, 68), rng:NextNumber())
	mk(folder, V3(WT - 8, h, len), base * CF(sd * 4, h / 2, 0), cliff, M.Sandstone)
	local h2 = h * rng:NextNumber(0.35, 0.6)
	mk(folder, V3(8, h2, len - 1), base * CF(-sd * (WT / 2 - 4), h2 / 2, 0), cliff:Lerp(rgb(140, 120, 100), 0.2), M.Sandstone)
end

wallStyles.city = function(folder, base, len, sd, rng)
	local h = rng:NextNumber(90, 150)
	local color = rng:NextNumber() < 0.5 and C.brickDark or rgb(78, 78, 80)
	local wall = mk(folder, V3(WT, h, len), base * CF(0, h / 2, 0), color, color == C.brickDark and M.Brick or M.Concrete)
	local face = sd > 0 and Enum.NormalId.Left or Enum.NormalId.Right
	windowGui(wall, face, math.max(2, math.floor(len / 6)), math.floor(h / 7), rgb(90, 88, 84), 0.02, rng)
	nightWindows(wall, face, math.max(2, math.floor(len / 6)), math.floor(h / 7), 0.09, rng)
	deco(folder, V3(WT + 1, 1.2, len + 0.5), base * CF(0, h + 0.6, 0), color:Lerp(rgb(0, 0, 0), 0.3), M.Concrete)
end

wallStyles.jungle = function(folder, base, len, sd, rng)
	local h = rng:NextNumber(64, 82)
	local leaf = rgb(26 + rng:NextInteger(0, 10), 46 + rng:NextInteger(0, 16), 30)
	mk(folder, V3(WT, h, len), base * CF(0, h / 2, 0), leaf, M.Grass)
	ball(folder, rng:NextNumber(30, 42), base * CF(sd * rng:NextNumber(0, 6), h + rng:NextNumber(-4, 4), 0), leaf:Lerp(rgb(40, 70, 40), 0.3), M.Grass, false)
end

wallStyles.swamp = function(folder, base, len, sd, rng, biome)
	local fog = (biome.fogColor or rgb(110, 118, 100)):Lerp(rgb(80, 86, 84), 0.4)
	mk(folder, V3(WT - 6, 72, len), base * CF(sd * 3, 36, 0), fog, M.SmoothPlastic, { Transparency = 0.35, CastShadow = false })
	if rng:NextNumber() < 0.6 then
		pine(folder, base * CF(-sd * (WT / 2 - 3), 0, rng:NextNumber(-len / 3, len / 3)), rng:NextNumber(40, 60), rng, { lod = 1, sparse = true })
	end
end

wallStyles.snow = function(folder, base, len, sd, rng)
	local h = rng:NextNumber(100, 150)
	local rock = rgb(92, 96, 106):Lerp(rgb(70, 74, 82), rng:NextNumber())
	deco(folder, V3(WT - 12, h, len), base * CF(sd * 6, h / 2, 0), rock, M.Rock)
	deco(folder, V3(WT - 10, 4, len + 1), base * CF(sd * 6, h + 2, 0), rgb(226, 232, 240), M.Snow)
	-- коллизия — отвесная невидимая стена на всю толщину
	mk(folder, V3(WT, h, len), base * CF(0, h / 2, 0), rock, M.Rock, { Transparency = 1, CastShadow = false })
	if rng:NextNumber() < 0.7 then
		pine(folder, base * CF(-sd * (WT / 2 - 2), 0, rng:NextNumber(-len / 3, len / 3)), rng:NextNumber(55, 75), rng, { lod = 1, snow = true })
	end
end

wallStyles.wasteland = function(folder, base, len, sd, rng)
	mk(folder, V3(8, 10, len), base * CF(-sd * (WT / 2 - 4), 5, 0), rgb(92, 90, 86), M.Concrete)
	mk(folder, V3(1.2, 64, len), base * CF(-sd * (WT / 2 - 9), 32, 0), rgb(50, 52, 54), M.DiamondPlate, { Transparency = 0.55, CastShadow = false })
	vcyl(folder, 68, 1.4, base * CF(-sd * (WT / 2 - 9), 34, 0), rgb(56, 58, 56), M.Metal)
end

CONST.WALL_STEP = 40

local function buildSideWalls(c)
	local road = S.World.Road
	local sMin = math.max(c.s0, Config.Bounds.BackS - WT)
	local sMax = math.min(c.s1, finalS() + Config.Bounds.FrontExtra + WT)
	if sMax - sMin < 1 then
		return
	end
	local n = math.max(1, math.ceil((sMax - sMin) / CONST.WALL_STEP))
	local step = (sMax - sMin) / n
	local rng = Random.new(c.ci * 7717 + (tonumber(S.World.Seed) or 1) % 1000 + 3)
	local dm = HW + WT / 2
	for i = 0, n - 1 do
		local sa = sMin + i * step
		local sb = sa + step
		local sm = (sa + sb) / 2
		local biome = S.World.BiomeAtS(sm)
		local style = wallStyles[biome.id] or wallStyles.desert
		if sm < DEPOT_END + 200 then
			style = wallStyles.forest
		end
		for _, sd in ipairs({ -1, 1 }) do
			local mid = road:ToWorld(sm, sd * dm)
			local _, pd = road:Project(mid, sm, 700)
			-- на внутренней стороне крутого поворота сегмент залез бы в проезжую часть — пропускаем
			if math.abs(pd) >= HW + 2 then
				local pa = road:ToWorld(sa, sd * dm)
				local pb = road:ToWorld(sb, sd * dm)
				local dir = pb - pa
				if dir.Magnitude > 0.5 then
					local len = dir.Magnitude + WT
					local center = (pa + pb) / 2
					local base = CFrame.lookAt(center, center + dir)
					style(c.folder, base, len, sd, rng, biome)
					S.Obstacles.AddBox(c.ci, base, WT / 2 + 1, len / 2, { hard = true, kind = "bounds" })
				end
			end
		end
	end
end

-- Торцевые стены: позади депо и за конечной (не выгружаются с чанками)
function Props.BuildEndWalls(folder)
	local width = 2 * (HW + WT) + WT
	local h = 96
	local function endWall(s, color, material)
		local base = roadCF(s, 0)
		mk(folder, V3(width, h, WT), base * CF(0, h / 2, 0), color, material)
		deco(folder, V3(width + 2, 3, WT + 2), base * CF(0, h + 1.5, 0), color:Lerp(rgb(0, 0, 0), 0.25), material)
		S.Obstacles.AddBox("bounds", base, width / 2, WT / 2 + 1, { hard = true, kind = "bounds" })
		return base
	end
	-- позади депо: тёмная масса леса
	endWall(Config.Bounds.BackS - WT / 2, rgb(24, 30, 26), M.Grass)
	local front = endWall(finalS() + Config.Bounds.FrontExtra + WT / 2, rgb(56, 54, 52), M.Slate)
	local plate = mk(folder, V3(70, 9, 0.6), front * CF(0, 16, WT / 2 + 0.4) * ANG(0, math.pi, 0), rgb(26, 24, 22), M.Metal)
	signText(plate, "ДАЛЬШЕ ДОРОГИ НЕТ", rgb(255, 110, 70), Enum.NormalId.Front, true)
	for _, x in ipairs({ -80, 80 }) do
		deco(folder, V3(1, 30, 1), front * CF(x, 15, WT / 2 + 1), rgb(80, 24, 20), M.Metal)
	end
end

-- Деревья и растительность с регистрацией -------------------------------------------------------
-- Сосна в точке (лес вокруг депо); detail 2 — ближняя, 1 — дальняя
local function placePine(c, s, d, opts)
	opts = opts or {}
	return placeTree(c, opts.kind or "pine_tall", s, d, {
		lod = opts.lod or (opts.detail == 2 and 3 or 1),
		depot = opts.depot,
		reserve = opts.reserve,
	})
end

-- Деревья биома: count попыток в полосе |d| ∈ [dMin, dMax]
local function treeBelt(c, count, dMin, dMax, opts)
	opts = opts or {}
	local rng = c.rng
	for _ = 1, count do
		local kind = biomeTree(c, opts.set or c.biome.id)
		local s = rng:NextNumber(c.s0, c.s1)
		local d = randSide(rng) * rng:NextNumber(dMin, dMax)
		placeTree(c, kind, s, d, { reserve = opts.reserve, depot = opts.depot, scale = opts.scale, lod = opts.lod })
	end
end

local function placeWith(c, s, d, r, builder, kind, hard, ...)
	local cf = spot(c, s, d, r, c.rng:NextNumber(0, 6.28))
	if not cf then
		return nil
	end
	local m, rr = builder(c.folder, cf, ...)
	circle(c, cf, rr or r, hard ~= false, m, { kind = kind })
	return m, cf
end

-- Придорожная инфраструктура: столбы ЛЭП с проводами, километровые столбики, знаки, отбойники,
-- сигнальные столбики (ночью светятся отражатели), брошенные машины на обочинах
CONST.ROADSIDE = {
	desert = { poles = true, wood = true, guard = 0.2, posts = true, signs = 0.35, wrecks = 0.35 },
	city = { poles = false, guard = 0, posts = false, signs = 0.4, wrecks = 0.55 },
	jungle = { poles = false, wood = true, guard = 0.15, posts = false, signs = 0.25, wrecks = 0.15 },
	swamp = { poles = true, wood = true, guard = 0.3, posts = true, signs = 0.3, wrecks = 0.25 },
	snow = { poles = true, wood = true, guard = 0.45, posts = true, signs = 0.3, wrecks = 0.3 },
	wasteland = { poles = true, wood = false, guard = 0.3, posts = true, signs = 0.3, wrecks = 0.5 },
}
CONST.SPOOKY_SIGNS = { "НЕ ОСТАНАВЛИВАЙТЕСЬ", "ОНИ РЯДОМ", "ПОМОГИТЕ", "КАРАНТИН", "ОБЪЕЗДА НЕТ", "ВЫЖИВШИЕ — ВПЕРЁД" }
CONST.POLE_STEP = 44
CONST.POLE_D = RHW + 5

-- Столб в точке s есть всегда, когда это место не занято депо/станцией/целью: провода к соседу
-- тянутся без знания соседнего чанка
local function poleAt(s)
	if s < 0 or reserved(s) then
		return false
	end
	return not S.World.IsReserved(S.World.Road:ToWorld(s, CONST.POLE_D), 2)
end

local function poleBase(s)
	return roadCF(s, CONST.POLE_D) * ANG(math.sin(s * 0.173) * 0.022, 0, math.cos(s * 0.131) * 0.022)
end

local function utilityPole(c, s, wood)
	local base = poleBase(s)
	local pole = model(c.folder, "Pole")
	local color = wood and rgb(62, 50, 40) or rgb(92, 94, 96)
	local mat = wood and M.Wood or M.Metal
	vcyl(pole, 18, wood and 0.8 or 0.6, base * CF(0, 9, 0), color, mat)
	local arm = deco(pole, V3(5, 0.36, 0.36), base * CF(0, 16.6, 0), color:Lerp(rgb(0, 0, 0), 0.15), mat)
	for _, x in ipairs({ -2.1, 2.1 }) do
		deco(pole, V3(0.22, 0.45, 0.22), base * CF(x, 17, 0), rgb(150, 160, 150), M.Glass, { CastShadow = false })
	end
	local roll = c.rng:NextNumber()
	if roll < 0.16 and budget(c, 1) then
		-- трансформатор
		vcyl(pole, 2.2, 1.5, base * CF(0.95, 13.2, 0), rgb(84, 88, 86), M.Metal, false)
	elseif roll < 0.3 and budget(c, 2) then
		-- фонарь на столбе, к дороге
		deco(pole, V3(2.2, 0.2, 0.2), base * CF(-1.1, 14.4, 0), color, mat, { CastShadow = false })
		local lamp = deco(pole, V3(1.1, 0.3, 0.6), base * CF(-2.2, 14.25, 0), rgb(255, 206, 150), M.Neon, { CastShadow = false })
		local spotL = Instance.new("SpotLight")
		spotL.Face = Enum.NormalId.Bottom
		spotL.Angle = 110
		spotL.Range = 34
		spotL.Brightness = 1.5
		spotL.Color = rgb(255, 200, 140)
		spotL.Parent = lamp
		nightLamp(lamp, rgb(110, 106, 96), "Glass")
	end
	local prevS = s - CONST.POLE_STEP
	if poleAt(prevS) then
		local prev = poleBase(prevS)
		for _, x in ipairs({ -2.1, 2.1 }) do
			wire(arm, (base * CF(x, 16.85, 0)).Position, (prev * CF(x, 16.85, 0)).Position, 1.3)
		end
	end
	circle(c, base, 0.9, true, pole, { kind = "pole" })
	table.insert(c.occ, footprint(base, 1, 1))
end

local function utilityPoles(c, wood)
	for s = math.ceil(c.s0 / CONST.POLE_STEP) * CONST.POLE_STEP, c.s1 - 0.001, CONST.POLE_STEP do
		if poleAt(s) then
			utilityPole(c, s, wood)
		end
	end
end

local function kmPosts(c)
	for s = math.ceil(c.s0 / SPK) * SPK, c.s1 - 0.001, SPK do
		if s > 0 and not reserved(s) and budget(c, 2) then
			local cf = spot(c, s, -(RHW + 3.2), 0.6, nil, nil)
			if cf then
				local post = deco(c.folder, V3(0.55, 2.8, 0.42), cf * CF(0, 1.4, 0), rgb(226, 224, 216), M.SmoothPlastic)
				deco(c.folder, V3(0.57, 0.45, 0.44), cf * CF(0, 2.6, 0), rgb(24, 24, 26), M.SmoothPlastic, { CastShadow = false })
				local text = tostring(math.floor(s / SPK + 0.5))
				signText(post, text, rgb(24, 24, 26), Enum.NormalId.Front, false, Enum.Font.GothamBold)
				signText(post, text, rgb(24, 24, 26), Enum.NormalId.Back, false, Enum.Font.GothamBold)
			end
		end
	end
end

-- Щит на левой обочине лицом к подъезжающему автобусу: модель, щит
local function signBoard(c, s, w, h, color, material)
	local cf = spot(c, s, -(RHW + 1.7 + w / 2), math.max(0.8, w / 2), nil, nil)
	if not cf then
		return nil, nil
	end
	cf = cf * ANG(0, math.pi, 0)
	local m = model(c.folder, "RoadSign")
	for _, x in ipairs(w > 4 and { -w / 2 + 0.8, w / 2 - 0.8 } or { 0 }) do
		mk(m, V3(0.26, 3.2 + h, 0.26), cf * CF(x, (3.2 + h) / 2, 0.14), rgb(118, 120, 122), M.Metal)
	end
	local board = mk(m, V3(w, h, 0.16), cf * CF(0, 3.2 + h / 2, 0), color, material or M.Metal)
	return m, board
end

local function roadSign(c)
	if not budget(c, 5) then
		return
	end
	local rng = c.rng
	local s = rng:NextNumber(c.s0 + 12, c.s1 - 12)
	local km = s / SPK
	local roll = rng:NextNumber()
	local nextSt = nil
	for _, st in ipairs(Config.Stations) do
		if st.km > km + 0.8 and st.km - km < 8 then
			nextSt = st
			break
		end
	end
	if nextSt and roll < 0.45 then
		local m, board = signBoard(c, s, 12, 2.4, rgb(28, 86, 52))
		if board then
			local dist = math.max(1, math.floor(nextSt.km - km + 0.5))
			signText(board, nextSt.name .. " · " .. dist .. " км", rgb(240, 240, 232), Enum.NormalId.Front, false, Enum.Font.GothamBold)
			deco(m, V3(12.3, 2.7, 0.08), board.CFrame * CF(0, 0, 0.1), rgb(226, 226, 222), M.SmoothPlastic, { CastShadow = false })
		end
	elseif roll < 0.62 then
		local m, board = signBoard(c, s, 9, 2.2, rgb(30, 60, 118))
		if board then
			local left = math.max(1, math.floor(Config.RouteKm - km + 0.5))
			signText(board, Config.FinalName .. " · " .. left .. " км", rgb(240, 240, 232), Enum.NormalId.Front, false, Enum.Font.GothamBold)
			deco(m, V3(9.3, 2.5, 0.08), board.CFrame * CF(0, 0, 0.1), rgb(226, 226, 222), M.SmoothPlastic, { CastShadow = false })
		end
	elseif roll < 0.76 then
		-- предупреждающий знак: жёлтый ромб с «!»
		local _, board = signBoard(c, s, 2.6, 2.6, rgb(206, 166, 40))
		if board then
			board.CFrame = board.CFrame * ANG(0, 0, rad(45))
			local gui = signText(board, "!", rgb(24, 20, 14), Enum.NormalId.Front, false, Enum.Font.GothamBlack)
			local label = gui:FindFirstChildOfClass("TextLabel")
			if label then
				label.Rotation = -45
			end
		end
	elseif roll < 0.88 then
		-- ограничение скорости: белый круг с красной каймой на прозрачном щите
		local _, board = signBoard(c, s, 2.8, 2.8, rgb(200, 30, 30))
		if board then
			board.Transparency = 1
			local gui = Instance.new("SurfaceGui")
			gui.Face = Enum.NormalId.Front
			gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
			gui.PixelsPerStud = 40
			local ring = Instance.new("Frame")
			ring.Size = UDim2.fromScale(1, 1)
			ring.BackgroundColor3 = rgb(196, 30, 28)
			ring.BorderSizePixel = 0
			Instance.new("UICorner", ring).CornerRadius = UDim.new(0.5, 0)
			ring.Parent = gui
			local inner = Instance.new("Frame")
			inner.AnchorPoint = Vector2.new(0.5, 0.5)
			inner.Position = UDim2.fromScale(0.5, 0.5)
			inner.Size = UDim2.fromScale(0.76, 0.76)
			inner.BackgroundColor3 = rgb(236, 234, 228)
			inner.BorderSizePixel = 0
			Instance.new("UICorner", inner).CornerRadius = UDim.new(0.5, 0)
			inner.Parent = ring
			local num = Instance.new("TextLabel")
			num.AnchorPoint = Vector2.new(0.5, 0.5)
			num.Position = UDim2.fromScale(0.5, 0.5)
			num.Size = UDim2.fromScale(0.7, 0.55)
			num.BackgroundTransparency = 1
			num.Font = Enum.Font.GothamBlack
			num.TextScaled = true
			num.TextColor3 = rgb(20, 20, 22)
			num.Text = rng:NextNumber() < 0.5 and "40" or "60"
			num.Parent = inner
			gui.Parent = board
		end
	else
		-- самодельная табличка из досок
		local _, board = signBoard(c, s, 6, 1.8, rgb(96, 74, 52), M.WoodPlanks)
		if board then
			board.CFrame = board.CFrame * ANG(0, 0, rad(rng:NextNumber(-6, 6)))
			signText(board, CONST.SPOOKY_SIGNS[rng:NextInteger(1, #CONST.SPOOKY_SIGNS)], rgb(150, 24, 20), Enum.NormalId.Front, false, Enum.Font.GothamBlack)
		end
	end
end

-- Отбойник вдоль обочины (не препятствие для автобуса)
local function guardrail(c, wood)
	local rng = c.rng
	local len = rng:NextNumber(40, 96)
	local sA = rng:NextNumber(c.s0 + 2, math.max(c.s0 + 2, c.s1 - len - 2))
	local sB = math.min(c.s1 - 1, sA + len)
	if sB - sA < 16 or reserved(sA) or reserved(sB) then
		return
	end
	local sd = randSide(rng)
	local d = sd * (RHW + 2.3)
	local sm = (sA + sB) / 2
	local n = math.max(2, math.floor((sB - sA) / 8))
	if not budget(c, n + 3 + math.ceil((sB - sA) / 40)) then
		return
	end
	if not tryPlace(c, roadCF(sm, d), 0.7, (sB - sA) / 2, { s = sm, d = d }) then
		return
	end
	local m = model(c.folder, "Guardrail")
	local postColor = wood and rgb(66, 52, 40) or rgb(70, 72, 74)
	for i = 0, n do
		local ps = sA + i * (sB - sA) / n
		deco(m, V3(0.34, 2.6, 0.34), roadCF(ps, d) * CF(0, 1.3, 0), postColor, wood and M.Wood or M.Metal, { CastShadow = false })
	end
	if wood then
		strip(m, sA, sB, d - sd * 0.25, 0.3, rgb(92, 72, 52), M.WoodPlanks, 2.3, 0.45)
		strip(m, sA, sB, d - sd * 0.25, 0.3, rgb(84, 66, 48), M.WoodPlanks, 1.3, 0.4)
	else
		strip(m, sA, sB, d - sd * 0.25, 0.22, rgb(150, 152, 148), M.Metal, 2.4, 0.85)
	end
end

-- Сигнальные столбики на обочинах: отражатель ночью светится
local function delineators(c)
	for s = math.ceil(c.s0 / 40) * 40, c.s1 - 0.001, 40 do
		for _, sd in ipairs({ -1, 1 }) do
			local ps = s + (sd > 0 and 20 or 0)
			if ps < c.s1 and not reserved(ps) and budget(c, 2) then
				local cf = spot(c, ps, sd * (RHW + 1.4), 0.3, nil, { road = true })
				if cf then
					deco(c.folder, V3(0.3, 2.2, 0.3), cf * CF(0, 1.1, 0), rgb(222, 222, 214), M.SmoothPlastic, { CastShadow = false })
					local band = deco(c.folder, V3(0.32, 0.4, 0.32), cf * CF(0, 1.85, 0), rgb(255, 140, 50), M.Neon, { CastShadow = false })
					nightLamp(band, rgb(26, 26, 28), "SmoothPlastic")
				end
			end
		end
	end
end

-- Брошенная машина: на обочине (в городе — у бордюра, не на полосе автобуса)
local function shoulderWreck(c, cfg)
	local rng = c.rng
	if rng:NextNumber() > (cfg.wrecks or 0) or not budget(c, 24) then
		return
	end
	local sd = randSide(rng)
	local s = rng:NextNumber(c.s0 + 10, c.s1 - 10)
	local city = c.biome.id == "city"
	local d = sd * (city and (RHW - 2.4) or rng:NextNumber(RHW + 5.5, RHW + 12))
	local yaw = city and rng:NextNumber(-0.04, 0.04) or rng:NextNumber(-0.5, 0.5)
	if rng:NextNumber() < 0.5 then
		yaw = yaw + math.pi
	end
	local cf = roadCF(s, d, yaw)
	if not tryPlace(c, cf, 3.3, 6.5, { s = s, d = d, road = city }) then
		return
	end
	if not city then
		cf = cf * ANG(0, 0, sd * rng:NextNumber(0.03, 0.1))
	end
	local m = carWreck(c.folder, cf, rng, c.biome.id == "snow" and rgb(150, 170, 186) or nil)
	box(c, cf, 3.3, 6.5, true, m, { kind = "wreck" })
end

local function roadsideInfra(c)
	local cfg = CONST.ROADSIDE[c.biome.id] or CONST.ROADSIDE.desert
	if cfg.poles then
		utilityPoles(c, cfg.wood)
	end
	kmPosts(c)
	if cfg.guard > 0 and c.rng:NextNumber() < cfg.guard then
		guardrail(c, cfg.wood)
	end
	if cfg.posts then
		delineators(c)
	end
	if c.rng:NextNumber() < cfg.signs then
		roadSign(c)
	end
	shoulderWreck(c, cfg)
end

-- Забор вдоль дороги (поля, промзона, периметры): прямой прогон с проломами, иногда с вышкой.
-- Все случайные величины бросаются до проверок бюджета.
local function fenceLine(c, sd, dist, style, o)
	o = o or {}
	local rng = c.rng
	local len = rng:NextNumber(o.lenMin or 40, o.lenMax or 80)
	local sA = rng:NextNumber(c.s0 + 6, math.max(c.s0 + 6, c.s1 - len - 6))
	local towerRoll = rng:NextNumber()
	local gapRoll = rng:NextNumber()
	local gapLen = rng:NextNumber(5, 9)
	local tower = o.tower and towerRoll < 0.6
	local sm = sA + len / 2
	local d = sd * dist
	if not afford(c, fenceCost(style, len) + (tower and 42 or 0), o.reserve) then
		return
	end
	local cf = roadCF(sm, d)
	if not tryPlace(c, cf, 1.5, len / 2, { s = sm, d = d }) then
		return
	end
	local base = sd > 0 and roadCF(sA, d) * ANG(0, rad(90), 0) or roadCF(sA + len, d) * ANG(0, rad(-90), 0)
	fenceRun(c.folder, base, len, style, rng, {
		height = o.height,
		coil = o.coil,
		broken = o.broken or 0.2,
		lean = o.lean or 0.3,
		snow = o.snow,
		gap = gapRoll < 0.4 and { len * 0.4, len * 0.4 + gapLen } or nil,
	})
	box(c, cf, 1, len / 2, true, nil, { kind = "fence" })
	if tower then
		local tcf = spot(c, sA + len + 6, sd * (dist + 6), 5, 0)
		if tcf then
			watchtower(c.folder, tcf, 20, rng, { simple = true })
			box(c, tcf, 4, 4, true, nil, { kind = "tower" })
		end
	end
end

-- Декорации биомов ---------------------------------------------------------------------------------
local decorate = {}

-- Разбросать мелочь без занятия места: count штук builder(folder, cf, rng, ...) в полосе |d| ∈ [dMin, dMax]
local function scatter(c, count, dMin, dMax, r, per, builder, ...)
	local rng = c.rng
	for _ = 1, count do
		if not budget(c, per) then
			return
		end
		local s = rng:NextNumber(c.s0 + 1, c.s1 - 1)
		local d = randSide(rng) * rng:NextNumber(dMin, dMax)
		local cf = spot(c, s, d, r, rng:NextNumber(0, 6.28), { noClaim = true })
		if cf then
			builder(c.folder, cf, rng, ...)
		end
	end
end

-- Твёрдая мелочь (пни, кактусы, молодые ёлки) с проверкой бюджета
local function placeSolid(c, per, dMin, dMax, r, builder, kind, ...)
	if not budget(c, per) then
		return nil
	end
	local rng = c.rng
	return placeWith(c, rng:NextNumber(c.s0, c.s1), randSide(rng) * rng:NextNumber(dMin, dMax), r, builder, kind, true, ...)
end

local function placeLog(c, snow)
	if not budget(c, 3) then
		return
	end
	local rng = c.rng
	local s = rng:NextNumber(c.s0 + 8, c.s1 - 8)
	local d = randSide(rng) * rng:NextNumber(RHW + 8, HW - 20)
	local cf = spot(c, s, d, 6, rng:NextNumber(0, 6.28))
	if cf then
		local m = fallenLog(c.folder, cf, rng, snow)
		box(c, cf, 6, 1.2, true, m, { kind = "log" })
	end
end

decorate.desert = function(c)
	local rng = c.rng
	-- заборы ставим до растительности: иначе им не остаётся бюджета
	if rng:NextNumber() < 0.45 then
		fenceLine(c, randSide(rng), rng:NextNumber(28, 62), "rail", { broken = 0.3, lean = 0.4, reserve = 120 })
	end
	if rng:NextNumber() < 0.3 then
		fenceLine(c, randSide(rng), rng:NextNumber(36, 68), rng:NextNumber() < 0.5 and "chain" or "sheet", { coil = true, tower = true, height = 8, broken = 0.25, reserve = 90 })
	end
	treeBelt(c, 5, 22, 70, { reserve = 60 })
	treeBelt(c, 5, 70, HW - 20, { reserve = 40 })
	for _ = 1, 6 do
		local size = rng:NextNumber(3, 9)
		placeSolid(c, 2, 22, HW - 14, size * 0.45, rock, "rock", size, rgb(104, 90, 76), M.Sandstone, rng)
	end
	for _ = 1, rng:NextInteger(3, 6) do
		placeSolid(c, 6, 20, HW - 16, 1.2, cactus, "cactus", rng)
	end
	for _ = 1, 3 do
		placeSolid(c, 2, 20, HW - 16, 1.3, stump, "stump", rng)
	end
	scatter(c, 5, 18, HW - 20, 2, 3, bush, rgb(96, 88, 62))
	scatter(c, 9, RHW + 3, 90, 0.8, 3, grassTuft, rgb(150, 132, 84))
	if rng:NextNumber() < 0.4 and budget(c, 24) then
		placeWith(c, rng:NextNumber(c.s0 + 20, c.s1 - 20), randSide(rng) * rng:NextNumber(RHW + 14, 60), 6.5, carWreck, "wreck", true, rng)
	end
end

-- Город: здания вдоль тротуаров (с деталями) и силуэты второго ряда
local function cityHighrise(c, s, d, w, depth, h, detailed)
	local rng = c.rng
	local cf = facingRoad(s, d)
	local function can(need)
		return afford(c, need, c.buildReserve or 0)
	end
	if not tryPlace(c, cf, w / 2 + 0.5, depth / 2 + 0.5, { s = s, d = d }) then
		return nil
	end
	local m = model(c.folder, "Block")
	local lib = not detailed and AssetLibrary.Has("Buildings") and AssetLibrary.Spawn("Buildings", cf * CF(0, 0, 0), rng, m)
	if not lib then
		local brick = rng:NextNumber() < 0.6
		local color = brick and C.brick:Lerp(C.brickDark, rng:NextNumber()) or rgb(84, 84, 84):Lerp(rgb(110, 106, 100), rng:NextNumber())
		local body = mk(m, V3(w, h, depth), cf * CF(0, h / 2, 0), color, brick and M.Brick or M.Concrete)
		local cols, rows = math.max(2, math.floor(w / 5)), math.max(1, math.floor((h - 8) / 6))
		windowGui(body, Enum.NormalId.Front, cols, rows, rgb(100, 96, 90), 0.03, rng)
		nightWindows(body, Enum.NormalId.Front, cols, rows, 0.14, rng)
		deco(m, V3(w + 1, 0.9, 1.2), cf * CF(0, h - 0.3, -depth / 2 - 0.4), color:Lerp(rgb(0, 0, 0), 0.35), M.Concrete)
		if detailed and can(10) then
			-- витрина первого этажа, навес, водосток, кондиционер, бак на крыше
			local shop = deco(m, V3(w - 2, 5, 0.1), cf * CF(0, 3.2, -depth / 2 - 0.06), C.tile, M.Concrete)
			seamGrid(shop, Enum.NormalId.Front, math.max(2, math.floor(w / 1.4)), 4, C.tileSeam, 0.3)
			deco(m, V3(w * 0.5, 3.4, 0.2), cf * CF(-w * 0.15, 3, -depth / 2 - 0.15), C.glass, M.Glass, { Transparency = 0.1 })
			deco(m, V3(w - 1, 0.5, 2.4), cf * CF(0, 6.4, -depth / 2 - 1.2) * ANG(rad(-8), 0, 0), rgb(60, 60, 62), M.CorrodedMetal)
			vcyl(m, h, 0.5, cf * CF(w / 2 - 0.5, h / 2, -depth / 2 - 0.4), rgb(56, 58, 58), M.Metal, false)
			if rng:NextNumber() < 0.6 then
				acUnit(m, cf * CF(rng:NextNumber(-w / 3, w / 3), rng:NextNumber(10, math.max(11, h - 6)), -depth / 2))
			end
			if rng:NextNumber() < 0.35 then
				vcyl(m, 5, 5, cf * CF(rng:NextNumber(-w / 4, w / 4), h + 3.5, depth / 4), rgb(70, 60, 50), M.CorrodedMetal, false)
			end
			-- цоколь и карниз в два уступа
			if can(2) then
				deco(m, V3(w + 0.6, 1.3, 0.5), cf * CF(0, 0.65, -depth / 2 - 0.2), C.concreteDark, M.Concrete, { CastShadow = false })
				deco(m, V3(w + 0.4, 0.5, 0.7), cf * CF(0, h - 1.2, -depth / 2 - 0.25), color:Lerp(rgb(0, 0, 0), 0.45), M.Concrete, { CastShadow = false })
			end
			-- пожарная лестница по фасаду и вывеска-«флаг»
			if rng:NextNumber() < 0.4 and h > 22 and can(11) then
				fireEscapeOf(m, cf * ANG(0, rad(-90), 0), depth, w, h, 11, 6)
			end
			if rng:NextNumber() < 0.45 and can(2) then
				bladeSign(m, cf * CF(-w * 0.25, 8.5, -depth / 2), CONST.SHOP_SIGNS[rng:NextInteger(1, #CONST.SHOP_SIGNS)], rng:NextNumber() < 0.5 and C.neonOrange or rgb(110, 210, 255))
			end
		end
	end
	box(c, cf, w / 2 + 0.5, depth / 2 + 0.5, true, nil, { kind = "building" })
	return m
end

CONST.CITY_ROWS = {
	{ dIn = 22, jitter = 2, depthMin = 18, depthMax = 28, hMin = 18, hMax = 44, loot = 0.25, detailed = true, lot = 0.22 },
	{ dIn = 76, jitter = 10, depthMin = 22, depthMax = 36, hMin = 36, hMax = 90, loot = 0.12 },
}

-- Пустырь: забор вдоль тротуара с проломом, за ним сухое дерево
local function cityLot(c, s, d, w, sd, rng)
	local cf = roadCF(s, d)
	-- площадка забора вытянута вдоль дороги: hx — поперёк, hz — вдоль
	if not tryPlace(c, cf, 2, w / 2, { s = s, d = d }) then
		return false
	end
	local style = rng:NextNumber() < 0.45 and "concrete" or (rng:NextNumber() < 0.5 and "sheet" or "chain")
	local base = sd > 0 and roadCF(s - w / 2, d) * ANG(0, rad(90), 0) or roadCF(s + w / 2, d) * ANG(0, rad(-90), 0)
	fenceRun(c.folder, base, w, style, rng, { height = 7.5, broken = 0.3, lean = 0.2, coil = style == "concrete" })
	box(c, cf, w / 2, 1, true, nil, { kind = "fence" })
	placeTree(c, rng:NextNumber() < 0.5 and "dead" or "poplar", s, d + sd * rng:NextNumber(9, 16), { reserve = c.buildReserve or 0 })
	return true
end

local function cityBlock(c, sd, row, sA, sB, lootLeft)
	local rng = c.rng
	local s = sA
	while sB - s >= 12 do
		local w = rng:NextNumber(18, 32)
		if sB - s - w < 12 then
			w = sB - s
		end
		local built = false
		local lotRoll = rng:NextNumber()
		-- дом с добычей дорогой: ставим, только если в чанке ещё есть запас деталей
		if lootLeft.n > 0 and rng:NextNumber() < row.loot and budget(c, 130) then
			local kind = Util.Weighted(rng, c.biome.buildings or {})
			local k = kind and Kinds[kind]
			if k and not k.open then
				local hx, hz, offZ = kindFootprint(k)
				if hx * 2 <= w + 4 then
					local front = hz - offZ
					if placeKind(c, kind, s + w / 2, sd * (row.dIn + rng:NextNumber(0, row.jitter) + front)) then
						lootLeft.n = lootLeft.n - 1
						built = true
					end
				end
			end
		end
		if not built and row.lot and lotRoll < row.lot then
			built = cityLot(c, s + w / 2, sd * (row.dIn + 1.5), w - 2, sd, rng)
		end
		if not built then
			local depth = rng:NextNumber(row.depthMin, row.depthMax)
			local dIn = row.dIn + rng:NextNumber(0, row.jitter)
			if budget(c, 10) then
				cityHighrise(c, s + w / 2, sd * (dIn + depth / 2), w - rng:NextNumber(1, 3), depth, rng:NextNumber(row.hMin, row.hMax), row.detailed)
			end
		end
		s = s + w
	end
end

decorate.city = function(c)
	local rng = c.rng
	local lootLeft = { n = 3 }
	for _, row in ipairs(CONST.CITY_ROWS) do
		for _, sd in ipairs({ -1, 1 }) do
			cityBlock(c, sd, row, c.s0 + 3, c.s1 - 3, lootLeft)
		end
	end
	for s = math.ceil(c.s0 / 64) * 64, c.s1 - 1, 64 do
		if not reserved(s) then
			for _, sd in ipairs({ -1, 1 }) do
				local ls = s + (sd > 0 and 32 or 0)
				local d = sd * (RHW + 1.6)
				local cf = roadCF(ls, d)
				if budget(c, 6) and tryPlace(c, cf, 0.8, 0.8, { s = ls, d = d, road = true }) then
					local m = streetLamp(c.folder, cf, -sd, rng)
					circle(c, cf, 0.7, true, m, { kind = "light" })
				end
				-- дерево на тротуаре между фонарями
				local ts = ls + 32
				if ts > c.s0 and ts < c.s1 and not reserved(ts) then
					placeTree(c, rng:NextNumber() < 0.65 and "poplar" or "birch", ts, sd * 19.5, { reserve = 25 })
				end
			end
		end
	end
	for _ = 1, 4 do
		local s = rng:NextNumber(c.s0, c.s1)
		local d = randSide(rng) * rng:NextNumber(RHW + 2, RHW + 7)
		local cf = spot(c, s, d, 1, nil, { road = true })
		if cf then
			if rng:NextNumber() < 0.5 then
				barrel(c.folder, cf, rgb(40, 48, 40))
			else
				ball(c.folder, rng:NextNumber(1.2, 2), cf * CF(0, 0.9, 0), rgb(24, 24, 26), M.Plastic, false)
			end
		end
	end
end

decorate.jungle = function(c)
	local rng = c.rng
	if rng:NextNumber() < 0.35 then
		fenceLine(c, randSide(rng), rng:NextNumber(26, 50), "plank", { broken = 0.45, lean = 0.4, height = 5.5, color = rgb(122, 112, 72), reserve = 110 })
	end
	treeBelt(c, 10, 20, 60, { reserve = 70 })
	treeBelt(c, 12, 60, HW - 26, { reserve = 40 })
	scatter(c, 8, RHW + 4, 120, 1.5, 3, fern, rgb(52, 92, 44))
	scatter(c, 6, 18, HW - 20, 2.5, 3, bush, rgb(40, 76, 40))
	scatter(c, 10, RHW + 2, 80, 0.8, 3, grassTuft, rgb(70, 110, 52))
	for _ = 1, 2 do
		placeLog(c, false)
	end
	for _ = 1, 2 do
		placeSolid(c, 2, 20, HW - 16, 1.3, stump, "stump", rng)
	end
end

decorate.swamp = function(c)
	local rng = c.rng
	if rng:NextNumber() < 0.4 then
		fenceLine(c, randSide(rng), rng:NextNumber(24, 52), rng:NextNumber() < 0.5 and "picket" or "plank",
			{ broken = 0.5, lean = 0.5, height = 4.6, color = rgb(126, 122, 104), reserve = 110 })
	end
	for _ = 1, rng:NextInteger(1, 3) do
		local r = rng:NextNumber(12, 24)
		local s = rng:NextNumber(c.s0 + r + 2, c.s1 - r - 2)
		local d = randSide(rng) * rng:NextNumber(RHW + r + 8, HW - r - 8)
		local cf = roadCF(s, d)
		if budget(c, 16) and tryPlace(c, cf, r, r, { s = s, d = d }) then
			local water = mkShape(c.folder, CYL, V3(0.3, r * 2, r * 2), cf * CF(0, 0.08, 0) * ANG(0, 0, rad(90)), rgb(30, 38, 34), M.Glass, false)
			water.Transparency = 0.1
			water.Reflectance = 0.08
			water.CastShadow = false
			-- тина по берегу и камыш
			local rim = mkShape(c.folder, CYL, V3(0.22, r * 2 + 3, r * 2 + 3), cf * CF(0, 0.05, 0) * ANG(0, 0, rad(90)), rgb(52, 60, 40), M.Mud, false)
			rim.CastShadow = false
			for i = 1, 2 do
				local a = i * math.pi + rng:NextNumber(-0.7, 0.7)
				reeds(c.folder, cf * CF(math.cos(a) * (r + 0.6), 0, math.sin(a) * (r + 0.6)), rng)
			end
		end
	end
	treeBelt(c, 9, 18, 70, { reserve = 60 })
	treeBelt(c, 8, 70, HW - 16, { reserve = 35 })
	scatter(c, 4, 18, HW - 20, 2, 3, bush, rgb(62, 70, 46))
	scatter(c, 8, RHW + 3, 90, 0.8, 3, grassTuft, rgb(96, 100, 62))
	for _ = 1, 3 do
		placeSolid(c, 2, 20, HW - 16, 1.3, stump, "stump", rng)
	end
	placeLog(c, false)
	if rng:NextNumber() < 0.5 then
		local s = rng:NextNumber(c.s0, c.s1 - 30)
		for i = 1, 5 do
			local cf = spot(c, s + i * 6, randSide(rng) * rng:NextNumber(18, 40), 1)
			if cf then
				local g = model(c.folder, "Cross")
				mk(g, V3(0.5, 4, 0.5), cf * CF(0, 2, 0), rgb(56, 48, 40), M.Wood)
				mk(g, V3(2.2, 0.5, 0.5), cf * CF(0, 3, 0), rgb(56, 48, 40), M.Wood)
			end
		end
	end
end

decorate.snow = function(c)
	local rng = c.rng
	if rng:NextNumber() < 0.45 then
		fenceLine(c, randSide(rng), rng:NextNumber(26, 60), rng:NextNumber() < 0.5 and "rail" or "plank", { broken = 0.3, lean = 0.4, snow = true, height = 5, reserve = 120 })
	end
	treeBelt(c, 8, 20, 85, { reserve = 70 })
	treeBelt(c, 11, 85, HW - 14, { reserve = 40 })
	for _ = 1, 6 do
		placeSolid(c, 5, 18, 110, 1, youngPine, "tree", rng, true)
	end
	for _ = 1, 4 do
		local size = rng:NextNumber(4, 9)
		local r = placeSolid(c, 3, 22, HW - 14, size * 0.45, rock, "rock", size, rgb(96, 100, 110), M.Rock, rng)
		local top = r and r:FindFirstChildOfClass("Part")
		if top then
			deco(r, V3(top.Size.X * 0.9, 0.6, top.Size.Z * 0.9), top.CFrame * CF(0, top.Size.Y / 2, 0), rgb(232, 236, 244), M.Snow, { CastShadow = false })
		end
	end
	for _ = 1, 5 do
		if budget(c, 1) then
			local cf = roadCF(rng:NextNumber(c.s0, c.s1), randSide(rng) * rng:NextNumber(18, HW - 20))
			ball(c.folder, rng:NextNumber(4, 9), cf * CF(0, -1, 0), rgb(226, 232, 240), M.Snow, false)
		end
	end
	for _ = 1, 2 do
		placeSolid(c, 2, 20, HW - 16, 1.3, stump, "stump", rng, true)
	end
	placeLog(c, true)
	scatter(c, 5, RHW + 3, 70, 0.8, 3, grassTuft, rgb(150, 150, 130))
end

decorate.wasteland = function(c)
	local rng = c.rng
	if rng:NextNumber() < 0.5 then
		fenceLine(c, randSide(rng), rng:NextNumber(28, 62), rng:NextNumber() < 0.55 and "concrete" or "chain", { coil = true, tower = true, broken = 0.3, height = 8, reserve = 110 })
	end
	if rng:NextNumber() < 0.3 then
		fenceLine(c, randSide(rng), rng:NextNumber(24, 48), "sheet", { broken = 0.45, lean = 0.4, reserve = 90 })
	end
	for _ = 1, rng:NextInteger(2, 4) do
		local r = rng:NextNumber(6, 12)
		local s = rng:NextNumber(c.s0 + r, c.s1 - r)
		local d = randSide(rng) * rng:NextNumber(RHW + r + 4, HW - r - 8)
		local cf = roadCF(s, d)
		if tryPlace(c, cf, r, r, { s = s, d = d, noClaim = true }) then
			mkShape(c.folder, CYL, V3(0.3, r * 2, r * 2), cf * CF(0, 0.06, 0) * ANG(0, 0, rad(90)), rgb(30, 27, 25), M.Slate, false)
			for i = 1, 3 do
				local a = i / 3 * math.pi * 2 + rng:NextNumber(-0.4, 0.4)
				ball(c.folder, rng:NextNumber(1.5, 3), cf * CF(math.cos(a) * r, 0.2, math.sin(a) * r), rgb(52, 48, 44), M.Slate, false)
			end
		end
	end
	treeBelt(c, 9, 20, HW - 14, { reserve = 40 })
	scatter(c, 5, 18, HW - 20, 2, 3, bush, rgb(74, 68, 58))
	scatter(c, 6, RHW + 3, 90, 0.8, 3, grassTuft, rgb(104, 96, 80))
	for _ = 1, 3 do
		placeSolid(c, 2, 20, HW - 16, 1.3, stump, "stump", rng)
	end
	for _ = 1, 3 do
		local size = rng:NextNumber(4, 8)
		placeWith(c, rng:NextNumber(c.s0, c.s1), randSide(rng) * rng:NextNumber(22, HW - 14), size * 0.45, rock, "rock", true, size, rgb(62, 58, 54), M.Slate, rng)
	end
	for _ = 1, 2 do
		local s = rng:NextNumber(c.s0 + 10, c.s1 - 10)
		local d = randSide(rng) * rng:NextNumber(RHW + 3, RHW + 9)
		local cf = spot(c, s, d, 2.5, nil)
		if cf then
			jersey(c.folder, cf * ANG(0, rng:NextNumber(-0.3, 0.3), 0), 6)
		end
	end
	if rng:NextNumber() < 0.5 then
		local cf = spot(c, rng:NextNumber(c.s0, c.s1), randSide(rng) * rng:NextNumber(18, 30), 1.2)
		if cf then
			local b = barrel(c.folder, cf)
			local fire = Instance.new("Fire")
			fire.Size = 4
			fire.Parent = b
			lightAt(b, 20, 1.5, rgb(255, 140, 60))
		end
	end
end

-- Мусор на дороге: только мягкий (автобус таранит) и зоны замедления ------------------------------
CONST.ROAD_DEBRIS = {
	desert = { { "wreck", 3 }, { "planks", 2 }, { "tires", 2 }, { "barrels", 1 } },
	city = { { "wreck", 4 }, { "planks", 2 }, { "cones", 2 }, { "trash", 3 } },
	jungle = { { "log", 4 }, { "mud", 3 }, { "planks", 1 } },
	swamp = { { "log", 2 }, { "mud", 4 }, { "wreck", 1 } },
	snow = { { "drift", 4 }, { "wreck", 2 }, { "planks", 1 } },
	wasteland = { { "wreck", 2 }, { "planks", 3 }, { "crater", 3 }, { "barrels", 2 }, { "tires", 1 } },
}
CONST.DEBRIS_CHANCE = { desert = 0.45, city = 0.6, jungle = 0.5, swamp = 0.5, snow = 0.5, wasteland = 0.6 }

local function roadDebris(c)
	local rng = c.rng
	local b = c.biome
	if rng:NextNumber() > (CONST.DEBRIS_CHANCE[b.id] or 0.4) then
		return
	end
	local s = rng:NextNumber(c.s0 + 30, c.s1 - 30)
	if reserved(s, 30) then
		return
	end
	local kind = Util.Weighted(rng, CONST.ROAD_DEBRIS[b.id] or CONST.ROAD_DEBRIS.desert)
	local lane = rng:NextNumber(-8, 8)
	local cf = roadCF(s, lane, rng:NextNumber(-0.6, 0.6))
	if S.World.IsReserved(cf.Position, 8) or not budget(c, 26) then
		return
	end
	if kind == "mud" or kind == "crater" or kind == "drift" then
		local r = rng:NextNumber(8, 12)
		local color, mat, slow = rgb(56, 44, 32), M.Mud, 0.55
		if kind == "crater" then
			color, mat, slow = rgb(30, 27, 25), M.Slate, 0.6
		elseif kind == "drift" then
			color, mat, slow = rgb(226, 232, 240), M.Snow, 0.6
			for _ = 1, 3 do
				ball(c.folder, rng:NextNumber(3, 6), cf * CF(rng:NextNumber(-r * 0.6, r * 0.6), -0.8, rng:NextNumber(-r * 0.6, r * 0.6)), color, mat, false)
			end
		end
		mkShape(c.folder, CYL, V3(0.2, r * 2, r * 2), cf * CF(0, 0.3, 0) * ANG(0, 0, rad(90)), color, mat, false)
		S.Obstacles.AddCircle(c.ci, cf.X, cf.Z, r, { hard = false, zone = true, slow = slow, kind = kind })
		return
	end
	local m, hx, hz, mult
	if kind == "wreck" then
		m = carWreck(c.folder, cf, rng, b.id == "snow" and rgb(150, 170, 186) or nil)
		hx, hz, mult = 3.3, 6.3, 1.6
	elseif kind == "planks" then
		m = model(c.folder, "Barricade")
		mk(m, V3(9, 0.8, 0.5), cf * CF(0, 2.2, 0) * ANG(0, 0, rad(20)), rgb(90, 70, 50), M.WoodPlanks)
		mk(m, V3(9, 0.8, 0.5), cf * CF(0, 2.2, 0.6) * ANG(0, 0, rad(-20)), rgb(90, 70, 50), M.WoodPlanks)
		mk(m, V3(10, 0.6, 0.5), cf * CF(0, 3.4, 0.3), rgb(150, 60, 40), M.WoodPlanks)
		hx, hz, mult = 5, 1.2, 1
	elseif kind == "cones" then
		m = model(c.folder, "Cones")
		for i = -2, 2 do
			vcyl(m, 1.8, 1, cf * CF(i * 2.4, 0.9, 0), rgb(200, 100, 40))
		end
		hx, hz, mult = 6.5, 1, 0.5
	elseif kind == "tires" then
		m = model(c.folder, "Tires")
		tires(m, cf, rng:NextInteger(1, 3), rng)
		tires(m, cf * CF(3.2, 0, 1), rng:NextInteger(1, 2), rng)
		hx, hz, mult = 4, 2.5, 0.6
	elseif kind == "barrels" then
		m = model(c.folder, "Barrels")
		for i = 1, 3 do
			barrel(m, cf * CF(i * 2.2 - 4.4, 0, rng:NextNumber(-1, 1)))
		end
		hx, hz, mult = 4, 1.5, 0.8
	elseif kind == "trash" then
		m = model(c.folder, "Trash")
		for _ = 1, 4 do
			ball(m, rng:NextNumber(1.4, 2.4), cf * CF(rng:NextNumber(-3, 3), 0.8, rng:NextNumber(-2, 2)), rgb(24, 24, 26), M.Plastic)
		end
		mk(m, V3(4, 0.4, 2.5), cf * CF(0, 0.3, 0) * ANG(0, 0.5, 0.1), rgb(84, 70, 54), M.WoodPlanks)
		hx, hz, mult = 4, 3, 0.4
	elseif kind == "log" then
		local len = rng:NextNumber(12, 16)
		m = model(c.folder, "Log")
		mkShape(m, CYL, V3(len, 2.4, 2.4), cf * CF(0, 1.2, 0), rgb(62, 48, 36), M.Wood)
		deco(m, V3(0.5, 4, 0.5), cf * CF(len * 0.3, 2.6, 0) * ANG(0, 0, rad(30)), rgb(62, 48, 36), M.Wood)
		hx, hz, mult = len / 2, 1.4, 1.3
	end
	if m then
		S.Obstacles.AddBox(c.ci, cf, hx, hz, { hard = false, model = m, kind = kind, damageMult = mult })
	end
end

local function roadsideCrate(c)
	local rng = c.rng
	if rng:NextNumber() > 0.16 then
		return
	end
	local s = rng:NextNumber(c.s0 + 25, c.s1 - 25)
	local d = randSide(rng) * rng:NextNumber(RHW + 4, RHW + 14)
	local cf = spot(c, s, d, 2, rng:NextNumber(0, 6.28))
	if not cf or not budget(c, 26) then
		return
	end
	local key = posKey("r", cf.Position)
	local m = model(c.folder, "Crate")
	crate(m, cf, 3, rng:NextNumber() < 0.4)
	circle(c, cf, 2, true, m)
	counted(m, S.Loot.SpawnFromTable, "roadside", { cf * CF(0, 3.05, 0) }, Random.new(hashSeed(key)), m, key)
end

-- Завалы: редкие твёрдые преграды на дороге, разбиваются оружием -----------------------------------
local roadblocks = {} -- { s, key }
local broken = {} -- [key] = true
local breakables = setmetatable({}, { __mode = "k" }) -- [model] = { ob, key }

CONST.BLOCK_KIND = { desert = "stone", city = "metal", jungle = "wood", swamp = "wood", snow = "stone", wasteland = "metal" }
CONST.GATE_TEXT = "Завал — разбейте его"

function Props.NewRun(seed)
	roadblocks = {}
	broken = {}
	breakables = setmetatable({}, { __mode = "k" })
	local rng = Random.new((tonumber(seed) or 1) % 1000003 + 911)
	local fin = Config.RouteKm * SPK
	local s = 3 * SPK + rng:NextNumber(0, 0.8) * SPK
	while s < fin - 1.2 * SPK do
		local ok = s > DEPOT_END + 400
		for _, st in ipairs(Config.Stations) do
			if math.abs(s - st.km * SPK) < 450 then
				ok = false
			end
		end
		if ok then
			table.insert(roadblocks, { s = s, key = "rb_" .. math.floor(s), alt = rng:NextNumber() })
		end
		s = s + rng:NextNumber(3, 4) * SPK
	end
end

function Props.GetRoadblocks()
	return roadblocks
end

local function warningSign(c, s)
	local cf = roadCF(s, RHW + 3.5) * ANG(0, math.pi, 0)
	local m = model(c.folder, "RoadblockSign")
	mk(m, V3(0.4, 6, 0.4), cf * CF(0, 3, 0), C.metal, M.Metal)
	local board = mk(m, V3(6, 3.4, 0.25), cf * CF(0, 5.8, 0), rgb(200, 150, 40), M.Metal)
	signText(board, "ЗАВАЛ ВПЕРЕДИ", rgb(30, 24, 18))
	signText(board, "ЗАВАЛ ВПЕРЕДИ", rgb(30, 24, 18), Enum.NormalId.Back)
	deco(m, V3(6.3, 3.7, 0.2), cf * CF(0, 5.8, 0.05), rgb(30, 28, 26), M.Metal)
end

local function buildRoadblock(c, rb)
	local rng = Random.new(hashSeed(rb.key))
	local kind = CONST.BLOCK_KIND[c.biome.id] or "wood"
	if rb.alt < 0.3 then
		kind = kind == "wood" and "metal" or "wood"
	end
	local cf = roadCF(rb.s, 0)
	local m = model(c.folder, "Roadblock")
	local function loose(p)
		p:SetAttribute("Loose", true)
		return p
	end
	if kind == "wood" then
		for i = 0, 2 do
			hcyl(m, 32, 2.4, cf * CF(rng:NextNumber(-1, 1), 1.2 + i * 2.1, i * 0.4) * ANG(0, rng:NextNumber(-0.06, 0.06), 0), rgb(66, 52, 38):Lerp(rgb(40, 32, 26), i / 3), M.Wood)
		end
		for _, x in ipairs({ -9, 0, 9 }) do
			loose(mk(m, V3(0.6, 8, 1.2), cf * CF(x, 3.6, -1.6) * ANG(rad(-15), 0, rng:NextNumber(-0.4, 0.4)), rgb(94, 74, 52), M.WoodPlanks))
		end
		loose(mk(m, V3(14, 0.8, 0.4), cf * CF(4, 5.4, -1.8) * ANG(0, 0, rad(12)), rgb(120, 60, 40), M.WoodPlanks))
	elseif kind == "metal" then
		carWreck(m, cf * CF(-7, 0, 0) * ANG(0, rad(80), 0), rng)
		carWreck(m, cf * CF(7.5, 0, 0.5) * ANG(0, rad(-95), rad(4)), rng)
		loose(mk(m, V3(8, 5, 0.3), cf * CF(0, 2.6, -2) * ANG(rad(-10), 0, rad(6)), C.rust, M.CorrodedMetal))
		for _, x in ipairs({ -13, 13 }) do
			loose(barrel(m, cf * CF(x, 0, -1.5)))
		end
	else
		for _, x in ipairs({ -10, 0, 10 }) do
			jersey(m, cf * CF(x, 0, rng:NextNumber(-0.5, 0.5)) * ANG(0, rad(90) + rng:NextNumber(-0.15, 0.15), 0), 9)
		end
		for _ = 1, 4 do
			local size = rng:NextNumber(2.5, 4.5)
			loose(mk(m, V3(size, size * 0.7, size), cf * CF(rng:NextNumber(-12, 12), size * 0.4 + 2.2, rng:NextNumber(-1.5, 1.5)) * ANG(rng:NextNumber(-0.5, 0.5), rng:NextNumber(0, 3), 0), C.concrete:Lerp(C.concreteDark, rng:NextNumber()), M.Concrete))
		end
		for _ = 1, 3 do
			deco(m, V3(0.2, 5, 0.2), cf * CF(rng:NextNumber(-10, 10), 4, 0) * ANG(rng:NextNumber(-0.6, 0.6), 0, rng:NextNumber(-0.6, 0.6)), rgb(80, 50, 36), M.CorrodedMetal)
		end
	end
	local km = rb.s / SPK
	local maxHP = math.floor(400 + km * 5)
	m:SetAttribute("Breakable", true)
	m:SetAttribute("BreakKind", kind)
	m:SetAttribute("MaxHP", maxHP)
	m:SetAttribute("HP", maxHP)
	m:SetAttribute("RoadblockKey", rb.key)
	local center = deco(m, V3(1, 1, 1), cf * CF(0, 5, 0), C.metal, M.Metal, { Transparency = 1 })
	center.Name = "Center"
	m.PrimaryPart = center
	waypoint(m, "ЗАВАЛ", C.neonOrange, 160)
	local ob = S.Obstacles.AddBox(c.ci, cf, RHW + 2, 2.8, { hard = true, gate = true, gateText = CONST.GATE_TEXT, kind = "roadblock", model = m })
	breakables[m] = { ob = ob, key = rb.key }
	addSpawner(c, (cf * CF(RHW + 12, 0, 6)).Position, 3, rb.key .. "_z")
end

local function roadblocksFor(c)
	for _, rb in ipairs(roadblocks) do
		if not broken[rb.key] then
			if rb.s >= c.s0 and rb.s < c.s1 then
				buildRoadblock(c, rb)
			end
			local signS = rb.s - 60
			if signS >= c.s0 and signS < c.s1 then
				warningSign(c, signS)
			end
		end
	end
end

local function findBreakable(inst)
	local node = inst
	while node and node ~= workspace do
		if node:GetAttribute("Breakable") == true then
			return node
		end
		node = node.Parent
	end
	return nil
end

local function fling(p, center, power)
	p.Anchored = false
	p.CanCollide = true
	p.CanQuery = false
	p.CanTouch = false
	p.CollisionGroup = "Debris"
	local away = p.Position - center
	away = V3(away.X, 0, away.Z)
	away = away.Magnitude > 0.1 and away.Unit or V3(math.random() - 0.5, 0, math.random() - 0.5)
	p.AssemblyLinearVelocity = away * power + V3(0, power * 0.9 + math.random() * 10, 0)
	p.AssemblyAngularVelocity = V3(math.random(-8, 8), math.random(-8, 8), math.random(-8, 8))
end

-- Урон разрушаемому объекту (модель с атрибутом Breakable). Возвращает destroyed, kind
function Props.DamageBreakable(target, amount, attacker)
	if typeof(target) ~= "Instance" then
		return false, nil
	end
	local m = findBreakable(target)
	if not m then
		return false, nil
	end
	local kind = m:GetAttribute("BreakKind") or "wood"
	amount = tonumber(amount)
	if not amount or amount ~= amount or amount <= 0 or amount == math.huge then
		return false, kind
	end
	amount = math.min(amount, 5000)
	local maxHP = tonumber(m:GetAttribute("MaxHP")) or 100
	local hp = tonumber(m:GetAttribute("HP")) or maxHP
	local newHP = hp - amount
	local center = m:IsA("Model") and m:GetPivot().Position or (m:IsA("BasePart") and m.Position) or Vector3.zero
	-- на порогах 75/50/25% отваливаются незакреплённые куски
	for _, th in ipairs({ 0.75, 0.5, 0.25 }) do
		if hp > maxHP * th and newHP <= maxHP * th and newHP > 0 then
			for _, p in ipairs(m:GetDescendants()) do
				if p:IsA("BasePart") and p:GetAttribute("Loose") and p.Anchored then
					p:SetAttribute("Loose", nil)
					fling(p, center, 14)
					task.delay(4, function()
						if p.Parent then
							p:Destroy()
						end
					end)
					break
				end
			end
		end
	end
	if newHP > 0 then
		m:SetAttribute("HP", newHP)
		return false, kind
	end
	m:SetAttribute("HP", 0)
	m:SetAttribute("Breakable", false)
	CollectionService:RemoveTag(m, "LR_Waypoint")
	local info = breakables[m]
	if info then
		breakables[m] = nil
		if info.ob then
			S.Obstacles.Remove(info.ob)
		end
		if info.key then
			broken[info.key] = true
		end
	end
	for _, p in ipairs(m:GetDescendants()) do
		if p:IsA("BasePart") then
			fling(p, center, 22)
		end
	end
	Net.FireNear("Explosion", center, 400, center, 7, "crash")
	if typeof(attacker) == "Instance" and attacker:IsA("Player") and S.PlayerData and S.PlayerData.Notify then
		S.PlayerData.Notify(attacker, "Завал разбит — путь свободен", rgb(255, 210, 120))
	end
	task.delay(5, function()
		if m.Parent then
			m:Destroy()
		end
	end)
	return true, kind
end

-- Здания у дороги (в пешей доступности)
local function placeBuildings(c)
	local rng = c.rng
	local b = c.biome
	if not b.buildings or #b.buildings == 0 then
		return
	end
	local function attempt(sd, dMinFront, dMaxFront)
		for _ = 1, 2 do
			local kind = Util.Weighted(rng, b.buildings)
			local k = kind and Kinds[kind]
			if not k then
				return
			end
			local hx, hz, offZ = kindFootprint(k)
			local sLo, sHi = c.s0 + hx + 4, c.s1 - hx - 4
			if sHi > sLo then
				local s = rng:NextNumber(sLo, sHi)
				local front = hz - offZ
				local d = sd * (rng:NextNumber(dMinFront, dMaxFront) + front)
				if placeKind(c, kind, s, d) then
					return
				end
			end
		end
	end
	for _, sd in ipairs({ -1, 1 }) do
		if rng:NextNumber() < b.buildingChance and budget(c, 70) then
			attempt(sd, 22, 46)
		end
	end
	if rng:NextNumber() < b.buildingChance * 0.6 and budget(c, 140) then
		attempt(randSide(rng), 55, 95)
	end
end

-- Окрестности депо: лес за заборами, дорога к тоннелю, горы с тоннелем -------------------------------
CONST.TUNNEL_S0, CONST.TUNNEL_S1 = 525, 595

function CONST.forestBand(c, sA, sB, dIn, dOut, sd)
	local rng = c.rng
	local cell = 30
	local a = math.max(sA, c.s0)
	local b = math.min(sB, c.s1)
	if b - a < 4 then
		return
	end
	for s = math.floor(a / cell) * cell, b, cell do
		for dist = dIn, dOut, cell do
			local depth = dist - dIn
			-- ближние ряды плотно, дальние (в тумане) — редко: ≈ 450 деталей на чанк
			local keep = depth < 70 or rng:NextNumber() < 0.2
			local ps = s + rng:NextNumber(0.1, 0.9) * cell
			local pd = sd * (dist + rng:NextNumber(0.1, 0.9) * cell)
			if keep and ps >= a and ps < b and math.abs(pd) < HW - 12 then
				placeTree(c, biomeTree(c, "depot"), ps, pd, { depot = true, lod = (depth < 30 and 3) or (depth < 80 and 2) or 1 })
			end
		end
	end
end

local function tunnel(c)
	local rng = c.rng
	-- зелёные холмы вокруг портала (как в оригинале)
	local hill = rgb(76, 106, 60)
	local segs = 3
	local segLen = (CONST.TUNNEL_S1 - CONST.TUNNEL_S0) / segs
	local innerHalf = RHW + 2
	for i = 0, segs - 1 do
		local sm = CONST.TUNNEL_S0 + (i + 0.5) * segLen
		local cf = roadCF(sm, 0)
		for _, sd in ipairs({ -1, 1 }) do
			local wall = mk(c.folder, V3(3, 26, segLen + 0.6), cf * CF(sd * (innerHalf + 1.5), 13, 0), C.concreteDark, M.Concrete)
			if i == 1 then
				local strip2 = deco(c.folder, V3(0.2, 0.4, segLen - 4), cf * CF(sd * innerHalf, 18, 0), rgb(255, 214, 150), M.Neon)
				lightAt(strip2, 30, 0.9, rgb(255, 200, 140))
			end
			S.Obstacles.AddBox(c.ci, wall.CFrame, 1.5, segLen / 2, { hard = true, kind = "tunnel" })
		end
		mk(c.folder, V3(2 * (innerHalf + 3), 3, segLen + 0.6), cf * CF(0, 27.5, 0), C.concreteDark, M.Concrete)
		-- масса холма над тоннелем
		prism(c.folder, cf * CF(0, 29, 0) * ANG(0, rad(90), 0), 2 * (innerHalf + 26), rng:NextNumber(26, 40), segLen + 0.6, hill, M.Grass)
	end
	for _, s in ipairs({ CONST.TUNNEL_S0, CONST.TUNNEL_S1 }) do
		local face = roadCF(s, 0) * (s == CONST.TUNNEL_S0 and CF() or ANG(0, math.pi, 0))
		for _, sd in ipairs({ -1, 1 }) do
			mk(c.folder, V3(6, 32, 3), face * CF(sd * (innerHalf + 3), 16, 1.5), C.concrete, M.Concrete)
		end
		local lintel = mk(c.folder, V3(2 * (innerHalf + 6), 8, 3), face * CF(0, 28, 1.5), C.concrete, M.Concrete)
		deco(c.folder, V3(2 * innerHalf, 0.8, 0.2), face * CF(0, 23.4, 0), rgb(180, 150, 50), M.Concrete)
		lintel.Name = "TunnelPortal"
		-- арка портала: клинья свода по дуге
		local r2, n = innerHalf + 1.2, 7
		local arcBase = face * CF(0, 14, 1.5) * ANG(0, rad(90), 0)
		for i = 0, n - 1 do
			local a = (math.pi * (i + 0.5)) / n - math.pi / 2
			mk(c.folder, V3(3, 2.6, math.pi * r2 / n * 1.15), arcBase * ANG(a, 0, 0) * CF(0, r2, 0), C.concrete:Lerp(rgb(0, 0, 0), 0.12), M.Concrete)
		end
		-- валуны у портала
		for _, sd in ipairs({ -1, 1 }) do
			rock(c.folder, face * CF(sd * (innerHalf + 9), 0, -2), rng:NextNumber(5, 9), rgb(104, 106, 98), M.Rock, rng)
		end
		-- тёмный «зев»: чёрная завеса глубоко в тоннеле не нужна, хватает тени и дымки
	end
	-- хребет по обе стороны
	for _, sd in ipairs({ -1, 1 }) do
		local d = innerHalf + 32
		while d < HW + WT do
			local sm = (CONST.TUNNEL_S0 + CONST.TUNNEL_S1) / 2 + rng:NextNumber(-6, 6)
			local cf = roadCF(sm, sd * d)
			local width = rng:NextNumber(56, 72)
			local h = rng:NextNumber(50, 95) + math.min(40, d * 0.12)
			if not S.World.IsReserved(cf.Position, width / 2) then
				mk(c.folder, V3(width, h * 0.3, CONST.TUNNEL_S1 - CONST.TUNNEL_S0), cf * CF(0, h * 0.15, 0), hill:Lerp(rgb(52, 74, 46), 0.4), M.Grass)
				prism(c.folder, cf * CF(0, h * 0.28, 0) * ANG(0, rad(90), 0), width, h * 0.72, CONST.TUNNEL_S1 - CONST.TUNNEL_S0 - 8, hill:Lerp(rgb(96, 124, 76), rng:NextNumber()), M.Grass)
				S.Obstacles.AddBox(c.ci, cf, width / 2, (CONST.TUNNEL_S1 - CONST.TUNNEL_S0) / 2, { hard = true, kind = "rock" })
				table.insert(c.occ, footprint(cf, width / 2, (CONST.TUNNEL_S1 - CONST.TUNNEL_S0) / 2 + 4))
			end
			d = d + width * 0.7
		end
	end
end

function CONST.depotOuter(c)
	-- тоннель ставится первым, чтобы лес не залез в холмы
	if CONST.TUNNEL_S0 >= c.s0 and CONST.TUNNEL_S0 < c.s1 then
		tunnel(c)
	end
	-- фонари вдоль дороги к тоннелю — раньше леса: они у самой дороги
	for s = 336, CONST.TUNNEL_S0 - 20, 48 do
		for _, sd in ipairs({ -1, 1 }) do
			local ls = s + (sd > 0 and 24 or 0)
			if ls >= c.s0 and ls < c.s1 and budget(c, 6) then
				streetLamp(c.folder, roadCF(ls, sd * (RHW + 3)), -sd, c.rng)
			end
		end
	end
	-- по бокам депо, за заборами
	CONST.forestBand(c, -70, 312, 66, HW - 14, -1)
	CONST.forestBand(c, -70, 312, 86, HW - 14, 1)
	-- дорога к тоннелю и после него
	for _, sd in ipairs({ -1, 1 }) do
		CONST.forestBand(c, 312, CONST.TUNNEL_S0 - 8, 24, HW - 14, sd)
		CONST.forestBand(c, CONST.TUNNEL_S1 + 10, DEPOT_END, 24, HW - 14, sd)
	end
end

function Props.BuildChunk(ci, s0, s1, biome, rng, folder)
	-- в чанке со станцией её постройки добавятся сверху: оставляем им место
	local station = finalS() >= s0 and finalS() < s1
	for _, st in ipairs(Config.Stations) do
		local ss = st.km * SPK
		if ss >= s0 and ss < s1 then
			station = true
		end
	end
	local c = {
		ci = ci,
		s0 = s0,
		s1 = s1,
		biome = biome,
		rng = rng,
		folder = folder,
		occ = {},
		startMade = made,
		budget = station and STATION_BUDGET or CHUNK_BUDGET,
		-- запас на растительность и мелочь: отделка зданий идёт, пока он остаётся
		buildReserve = biome.id == "city" and 60 or 110,
	}
	groundAndRoad(c)
	buildSideWalls(c)
	if s1 < Config.Bounds.BackS or s0 > finalS() then
		return made - c.startMade
	end
	-- придорожное — первым: столбы детерминированы, остальное обходит их
	roadsideInfra(c)
	if s0 < DEPOT_END + 40 then
		CONST.depotOuter(c)
	end
	-- завалы (игровые) — до зданий, чтобы им хватило бюджета
	roadblocksFor(c)
	if biome.id == "city" then
		decorate.city(c)
	else
		placeBuildings(c)
	end
	roadDebris(c)
	roadsideCrate(c)
	local fn = decorate[biome.id]
	if fn and biome.id ~= "city" then
		fn(c)
	end
	return made - c.startMade
end

-- Депо: мрачный городок у начала дороги ---------------------------------------------------------
-- Автобус стоит на дороге в s = 70, d = 0 (корпус |d| ≤ 7, ±23 по длине): там ничего не ставим и не вешаем.
CONST.DEPOT_CHUNK = "depot"

function CONST.depotBox(cf, hx, hz, kind)
	S.Obstacles.AddBox(CONST.DEPOT_CHUNK, cf, hx, hz, { hard = true, kind = kind or "building" })
end

-- Магазин: 2 этажа, первый — плитка с открытыми гаражными воротами, второй — кирпич
function CONST.buildShop(folder)
	local m = model(folder, "DepotShop")
	local shop = facingRoad(70, 40) -- локальная X = вдоль дороги (+s), −Z = к дороге
	local W, D, G, U = 68, 32, 12, 10
	local hw, hd = W / 2, D / 2
	local gateW, gateH = 22, 10
	local tileFace = Enum.NormalId.Front

	-- пол и перекрытие
	local floor = mk(m, V3(W, 0.55, D), shop * CF(0, 0.275, 0), rgb(92, 94, 92), M.Concrete)
	seamGrid(floor, Enum.NormalId.Top, 34, 16, C.tileSeam, 0.4)
	mk(m, V3(W, 1, D), shop * CF(0, G + 0.5, 0), C.concreteDark, M.Concrete)

	-- первый этаж: фасад из плитки с проёмом ворот
	local segW = (W - gateW) / 2
	for _, sx in ipairs({ -1, 1 }) do
		local p = mk(m, V3(segW, G, 1), shop * CF(sx * (gateW / 2 + segW / 2), G / 2, -hd + 0.5), C.tile, M.Concrete)
		seamGrid(p, tileFace, math.floor(segW / 1.3), math.floor(G / 1.3), C.tileSeam, 0.3)
		local inner = seamGrid(p, Enum.NormalId.Back, math.floor(segW / 1.3), math.floor(G / 1.3), C.tileSeam, 0.4)
		inner.Name = "InnerTiles"
	end
	local lintel = mk(m, V3(gateW, G - gateH, 1), shop * CF(0, gateH + (G - gateH) / 2, -hd + 0.5), C.tile, M.Concrete)
	seamGrid(lintel, tileFace, math.floor(gateW / 1.3), 2, C.tileSeam, 0.3)
	-- задняя и боковые стены (внутри тоже плитка)
	local back = mk(m, V3(W, G, 1), shop * CF(0, G / 2, hd - 0.5), C.tile, M.Concrete)
	seamGrid(back, Enum.NormalId.Front, 52, 9, C.tileSeam, 0.35)
	for _, sx in ipairs({ -1, 1 }) do
		local side = mk(m, V3(1, G, D), shop * CF(sx * (hw - 0.5), G / 2, 0), C.tile, M.Concrete)
		seamGrid(side, sx < 0 and Enum.NormalId.Right or Enum.NormalId.Left, 25, 9, C.tileSeam, 0.35)
		seamGrid(side, sx < 0 and Enum.NormalId.Left or Enum.NormalId.Right, 25, 9, C.tileSeam, 0.3)
	end
	-- рулонные ворота подняты: короб, направляющие, порог
	deco(m, V3(gateW + 1, 1.8, 1.8), shop * CF(0, gateH - 0.9, -hd + 1.6), rgb(64, 66, 66), M.CorrodedMetal)
	for _, sx in ipairs({ -1, 1 }) do
		deco(m, V3(0.5, gateH, 0.6), shop * CF(sx * (gateW / 2 + 0.1), gateH / 2, -hd - 0.1), rgb(46, 48, 50), M.Metal)
	end
	deco(m, V3(gateW, 0.08, 1.4), shop * CF(0, 0.58, -hd + 0.5), rgb(80, 80, 80), M.DiamondPlate)

	-- второй этаж: кирпич, окна с рамами, карниз
	mk(m, V3(W, U, 1), shop * CF(0, G + 1 + U / 2, -hd + 0.5), C.brick, M.Brick)
	mk(m, V3(W, U, 1), shop * CF(0, G + 1 + U / 2, hd - 0.5), C.brick, M.Brick)
	for _, sx in ipairs({ -1, 1 }) do
		mk(m, V3(1, U, D), shop * CF(sx * (hw - 0.5), G + 1 + U / 2, 0), C.brick, M.Brick)
	end
	for _, x in ipairs({ -29, -21, -13, 13, 21, 29 }) do
		realWindow(m, shop * CF(x, G + 1 + U / 2 + 0.3, -hd), 4.2, 4.4, false, x == -21 or x == 13)
	end
	for _, z in ipairs({ -8, 8 }) do
		realWindow(m, shop * CF(-hw, G + 1 + U / 2 + 0.3, z) * ANG(0, rad(90), 0), 4.2, 4.4, false)
	end
	local roofY = G + 1 + U
	mk(m, V3(W + 0.6, 0.8, D + 0.6), shop * CF(0, roofY + 0.4, 0), rgb(52, 52, 54), M.Concrete)
	deco(m, V3(W + 1.4, 0.8, 1.4), shop * CF(0, roofY - 0.2, -hd - 0.4), C.brickDark:Lerp(rgb(20, 20, 20), 0.4), M.Concrete)
	deco(m, V3(W + 1, 0.5, 0.9), shop * CF(0, G + 1.2, -hd - 0.3), C.concreteDark, M.Concrete)
	for _, z in ipairs({ -hd + 0.25, hd - 0.25 }) do
		deco(m, V3(W + 0.6, 1.4, 0.5), shop * CF(0, roofY + 1.5, z), C.brickDark, M.Brick)
	end
	for _, sx in ipairs({ -1, 1 }) do
		deco(m, V3(0.5, 1.4, D), shop * CF(sx * (hw + 0.05), roofY + 1.5, 0), C.brickDark, M.Brick)
	end
	barbedCoil(m, shop * CF(-hw, roofY + 3, -hd + 0.2), W, 0.8, 1.3)
	barbedCoil(m, shop * CF(hw, roofY + 3, -hd) * ANG(0, rad(-90), 0), D, 0.8, 1.3)
	-- крыша: кондиционеры и вытяжка
	for _, x in ipairs({ -18, 10 }) do
		deco(m, V3(4, 2.4, 3), shop * CF(x, roofY + 2, 6), rgb(140, 140, 136), M.Metal)
		deco(m, V3(2.6, 0.2, 2.6), shop * CF(x, roofY + 3.3, 6), rgb(50, 50, 50), M.DiamondPlate)
	end
	vcyl(m, 4, 1.2, shop * CF(24, roofY + 2.5, 10), rgb(90, 92, 90), M.Metal, false)

	-- козырёк над первым этажом (скат к дороге, нижний край на высоте ≈12.5 у тротуара)
	local awning = mk(m, V3(W + 2, 0.5, 5.4), shop * CF(0, G + 1.5, -hd - 2.5) * ANG(rad(-14), 0, 0), rgb(46, 48, 50), M.Slate)
	seamGrid(awning, Enum.NormalId.Top, 40, 3, rgb(26, 28, 30), 0.3)
	-- водостоки, камеры, настенные фонари
	for _, sx in ipairs({ -1, 1 }) do
		vcyl(m, roofY, 0.5, shop * CF(sx * (hw - 0.6), roofY / 2, -hd - 0.4), rgb(56, 58, 58), M.Metal, false)
		deco(m, V3(0.6, 0.6, 1.4), shop * CF(sx * (hw - 2), roofY - 1.2, -hd - 0.8), rgb(200, 200, 196), M.Metal)
		local wl = deco(m, V3(1, 0.6, 0.8), shop * CF(sx * (gateW / 2 + 2), gateH + 0.8, -hd - 0.4), rgb(40, 40, 42), M.Metal)
		lightAt(deco(m, V3(0.8, 0.1, 0.6), wl.CFrame * CF(0, -0.35, 0), rgb(255, 226, 180), M.Neon), 18, 0.9)
	end

	-- неоновая вывеска «МАГАЗИН» над воротами
	local signCF = shop * CF(0, G + 4.6, -hd - 1.6)
	local backing = deco(m, V3(15, 3.8, 0.1), signCF, C.neonGreen, M.SmoothPlastic, { Transparency = 1 })
	signText(backing, "МАГАЗИН", C.neonGreen, Enum.NormalId.Front, true, Enum.Font.GothamBold)
	neonOutline(m, signCF * CF(0, 0, -0.05), 17, 4.8, 1.6, C.neonGreen, 0.24)
	lightAt(backing, 22, 1.6, C.neonGreen)
	for _, x in ipairs({ -6, 6 }) do
		deco(m, V3(0.2, 0.2, 1.6), shop * CF(x, G + 4.6, -hd - 0.8), rgb(40, 40, 40), M.Metal)
	end

	-- автоматы у входа (свои, без надписей оригинала)
	local vend = shop * CF(-gateW / 2 - 5, 0.5, -hd - 1.8)
	mk(m, V3(4, 7, 2.6), vend * CF(0, 3.5, 0), rgb(34, 36, 40), M.Metal)
	deco(m, V3(2.6, 4.6, 0.1), vend * CF(-0.4, 4.2, -1.32), rgb(30, 44, 52), M.Glass, { Transparency = 0.1 })
	local strip = deco(m, V3(0.2, 4.6, 0.12), vend * CF(-1.85, 4.2, -1.34), rgb(90, 200, 230), M.Neon)
	lightAt(strip, 8, 0.6, rgb(90, 200, 230))
	deco(m, V3(0.8, 2, 0.1), vend * CF(1.4, 4.4, -1.32), rgb(20, 20, 22), M.Metal)
	local yel = shop * CF(gateW / 2 + 6, 0.5, -hd - 2) * ANG(0, rad(-8), 0)
	mk(m, V3(4.4, 7.2, 3), yel * CF(0, 4.2, 0), rgb(160, 128, 40), M.CorrodedMetal)
	deco(m, V3(2.8, 3.8, 0.1), yel * CF(-0.4, 5, -1.52), rgb(150, 148, 130), M.Neon)
	deco(m, V3(1, 1.4, 0.1), yel * CF(1.5, 5.2, -1.52), rgb(20, 22, 20), M.Metal)
	deco(m, V3(0.6, 0.2, 0.1), yel * CF(1.5, 4.3, -1.53), C.neonGreen, M.Neon)
	for _, x in ipairs({ -1.9, 1.9 }) do
		for _, z in ipairs({ -1.2, 1.2 }) do
			deco(m, V3(0.2, 0.6, 0.2), yel * CF(x, 0.3, z), rgb(30, 30, 30), M.Metal)
		end
	end
	-- киоск билетов: козырёк и вывеска над автоматом
	deco(m, V3(6, 0.35, 2.6), yel * CF(0, 8.4, -1) * ANG(rad(11), 0, 0), rgb(150, 120, 36), M.Metal)
	local ticket = deco(m, V3(6.4, 1.7, 0.2), yel * CF(0, 9.7, -0.6), rgb(26, 26, 24), M.Metal)
	signText(ticket, "БИЛЕТЫ", C.neonYellow, Enum.NormalId.Front, true, Enum.Font.GothamBold)
	lightAt(ticket, 12, 0.8, C.neonYellow)

	-- интерьер: лампы
	for _, x in ipairs({ -20, 0, 20 }) do
		local lamp = deco(m, V3(6, 0.2, 0.6), shop * CF(x, G - 0.2, 0), rgb(255, 240, 214), M.Neon)
		lightAt(lamp, 26, 0.9, rgb(255, 232, 200))
	end
	-- таблички категорий над витринами у задней стены и слева
	local boards = {
		{ "ОРУЖИЕ", shop * CF(-26, 7.6, hd - 1.2) },
		{ "ПАТРОНЫ", shop * CF(-13, 7.6, hd - 1.2) },
		{ "ДЕТАЛИ", shop * CF(0, 7.6, hd - 1.2) },
		{ "ПРИПАСЫ", shop * CF(-hw + 1.2, 7.6, -2) * ANG(0, rad(-90), 0) },
	}
	for _, b in ipairs(boards) do
		local board = mk(m, V3(7.5, 1.8, 0.3), b[2], rgb(28, 28, 30), M.Metal)
		signText(board, b[1], rgb(236, 236, 230), Enum.NormalId.Front, false, Enum.Font.GothamBold)
		local table1 = mk(m, V3(9, 2.8, 3.4), b[2] * CF(0, -6.1, -1.9), rgb(46, 48, 52), M.DiamondPlate)
		deco(m, V3(9, 0.14, 0.14), table1.CFrame * CF(0, -1.2, -1.75), rgb(70, 170, 210), M.Neon)
		deco(m, V3(2.2, 0.8, 1.2), table1.CFrame * CF(-2.4, 1.8, 0), rgb(56, 64, 48), M.Metal)
		deco(m, V3(3.2, 0.5, 0.6), table1.CFrame * CF(1.8, 1.65, -0.3) * ANG(0, 0.3, 0), rgb(34, 34, 36), M.Metal)
	end
	-- стеклянная витрина слева
	mk(m, V3(3, 3, 14), shop * CF(-hw + 3, 2, -8) , rgb(64, 50, 40), M.WoodPlanks)
	deco(m, V3(3.1, 1.2, 14), shop * CF(-hw + 3, 4.1, -8), rgb(170, 200, 190), M.Glass, { Transparency = 0.6 })
	deco(m, V3(0.1, 0.1, 13), shop * CF(-hw + 3, 3.6, -8), rgb(120, 255, 170), M.Neon)

	-- касса «МАГАЗИН»
	local desk = mk(m, V3(6, 3.2, 2.4), shop * CF(-18, 2.15, -8), rgb(52, 46, 40), M.WoodPlanks)
	desk.Name = "ShopCounter"
	deco(m, V3(1.6, 1, 1.2), desk.CFrame * CF(-1.5, 2.1, 0), rgb(30, 30, 32), M.Metal)
	deco(m, V3(1.2, 0.7, 0.1), desk.CFrame * CF(-1.5, 2.9, -0.4) * ANG(rad(-20), 0, 0), C.neonGreen, M.Neon)
	S.Stations.RegisterTrader(desk, { name = "Магазин депо", kind = "depot" })
	waypoint(desk, "МАГАЗИН", C.neonGreen)

	-- прилавок «ПРОДАТЬ» с оранжевым неоном и светящейся решёткой
	local sell = mk(m, V3(16, 3.4, 3), shop * CF(20, 2.25, hd - 5.5), rgb(58, 52, 46), M.WoodPlanks)
	sell.Name = "SellCounter"
	deco(m, V3(16.2, 0.3, 3.2), sell.CFrame * CF(0, 1.85, 0), rgb(80, 80, 80), M.DiamondPlate)
	local sellSign = shop * CF(14, 9.2, hd - 1.1)
	local sellBack = deco(m, V3(7, 2, 0.1), sellSign, C.neonOrange, M.SmoothPlastic, { Transparency = 1 })
	signText(sellBack, "ПРОДАТЬ", C.neonOrange, Enum.NormalId.Front, true, Enum.Font.GothamBold)
	neonOutline(m, sellSign * CF(0, 0, -0.05), 8, 2.6, 0.9, C.neonOrange, 0.18)
	lightAt(sellBack, 14, 1.2, C.neonOrange)
	local grate = deco(m, V3(7, 6, 0.2), shop * CF(26, 3.6, hd - 1.05), rgb(255, 170, 70), M.Neon)
	for i = -3, 3 do
		deco(m, V3(0.35, 6.2, 0.3), grate.CFrame * CF(i, 0, -0.25), rgb(30, 26, 22), M.Metal)
	end
	deco(m, V3(7.6, 0.5, 0.4), grate.CFrame * CF(0, 3.2, -0.2), rgb(30, 26, 22), M.Metal)
	lightAt(grate, 16, 1.3, rgb(255, 150, 60))
	local red = ball(m, 0.7, shop * CF(19, 8.8, hd - 1.2), rgb(255, 40, 30), M.Neon, false)
	lightAt(red, 8, 0.8, rgb(255, 50, 40))
	S.Stations.RegisterTrader(sell, { name = "Магазин депо", kind = "depot" })
	waypoint(sell, "ПРОДАТЬ", C.neonOrange)

	-- ящики и покрышки внутри
	crate(m, shop * CF(28, 0.55, -10), 3, true)
	crate(m, shop * CF(28, 3.55, -10.3), 2.4, false)
	tires(m, shop * CF(22, 0.55, -12), 3, Random.new(7))
	CONST.depotBox(shop, hw, hd)
end

-- Соседние кирпичные дома вдоль улицы (сплошные)
function CONST.buildNeighbours(folder)
	local rng = Random.new(hashSeed("depot_houses"))
	-- склад справа за магазином
	do
		local m = model(folder, "DepotWarehouse")
		local cf = facingRoad(138, 38)
		local w, d, h = 44, 28, 17
		local body = mk(m, V3(w, h, d), cf * CF(0, h / 2, 0), C.brickDark, M.Brick)
		windowGui(body, Enum.NormalId.Front, 6, 1, rgb(80, 76, 70), 0, rng)
		nightWindows(body, Enum.NormalId.Front, 6, 1, 0.35, rng)
		local base = deco(m, V3(w, 7, 0.1), cf * CF(0, 3.5, -d / 2 - 0.06), C.tile, M.Concrete)
		seamGrid(base, Enum.NormalId.Front, 32, 5, C.tileSeam, 0.3)
		deco(m, V3(12, 8, 0.3), cf * CF(-8, 4, -d / 2 - 0.2), rgb(70, 72, 72), M.CorrodedMetal)
		deco(m, V3(w + 1.2, 0.8, 1.2), cf * CF(0, h - 0.4, -d / 2 - 0.4), rgb(40, 32, 30), M.Concrete)
		local sb = deco(m, V3(6, 1.8, 0.1), cf * CF(10, 9.5, -d / 2 - 0.4), C.neonOrange, M.SmoothPlastic, { Transparency = 1 })
		signText(sb, "СКЛАД", C.neonOrange, Enum.NormalId.Front, true, Enum.Font.GothamBold)
		neonOutline(m, cf * CF(10, 9.5, -d / 2 - 0.45), 7, 2.4, 0.8, C.neonOrange, 0.16)
		lightAt(sb, 10, 0.9, C.neonOrange)
		barbedCoil(m, cf * CF(-w / 2, h + 1, -d / 2 + 0.3), w, 0.7, 1.3)
		vcyl(m, h, 0.5, cf * CF(w / 2 - 0.5, h / 2, -d / 2 - 0.4), rgb(56, 58, 58), M.Metal, false)
		acUnit(m, cf * CF(-16, 12, -d / 2))
		CONST.depotBox(cf, w / 2, d / 2)
	end
	-- заколоченный дом позади магазина (ближе к тупику)
	do
		local m = model(folder, "DepotHouse")
		local cf = facingRoad(4, 38)
		local w, d, h = 40, 26, 20
		mk(m, V3(w, h, d), cf * CF(0, h / 2, 0), C.brick, M.Brick)
		local low = deco(m, V3(w, 9, 0.1), cf * CF(0, 4.5, -d / 2 - 0.06), C.tile, M.Concrete)
		seamGrid(low, Enum.NormalId.Front, 29, 6, C.tileSeam, 0.3)
		for _, x in ipairs({ -12, 0, 12 }) do
			realWindow(m, cf * CF(x, 14.5, -d / 2), 4, 4, false, x == 12)
		end
		deco(m, V3(10, 6, 0.4), cf * CF(-8, 4, -d / 2 - 0.3), rgb(84, 64, 46), M.WoodPlanks)
		deco(m, V3(0.5, 7, 0.5), cf * CF(-13.4, 3.6, -d / 2 - 0.6), rgb(70, 54, 40), M.Wood)
		deco(m, V3(w + 2, 0.5, 4), cf * CF(0, 9.4, -d / 2 - 2) * ANG(rad(-12), 0, 0), rgb(46, 48, 50), M.Slate)
		barbedCoil(m, cf * CF(-w / 2, h + 1, -d / 2 + 0.3), w, 0.7, 1.3)
		CONST.depotBox(cf, w / 2, d / 2)
	end
end

-- Навес с верстаком на другой стороне улицы
function CONST.buildWorkshop(folder)
	local m = model(folder, "DepotWorkshop")
	local cf = facingRoad(71, -33) -- −Z к дороге
	local w, d = 26, 14
	mk(m, V3(w, 0.3, d), cf * CF(0, 0.5, 0), rgb(70, 70, 68), M.Concrete)
	for _, x in ipairs({ -w / 2 + 0.5, w / 2 - 0.5 }) do
		for _, z in ipairs({ -d / 2 + 0.5, d / 2 - 0.5 }) do
			vcyl(m, 10, 0.5, cf * CF(x, 5, z), C.metal, M.Metal)
		end
	end
	mk(m, V3(w + 2, 0.4, d + 3), cf * CF(0, 10, 0.5) * ANG(rad(8), 0, 0), rgb(84, 70, 56), M.CorrodedMetal)
	mk(m, V3(w, 8, 0.3), cf * CF(0, 4.5, d / 2 - 0.2), rgb(70, 72, 70), M.CorrodedMetal)
	for _, sx in ipairs({ -1, 1 }) do
		mk(m, V3(0.3, 4, d - 1), cf * CF(sx * (w / 2 - 0.3), 2.5, 0), rgb(76, 66, 52), M.CorrodedMetal)
	end
	local benchCF = cf * CF(0, 0.65, 2)
	local top = mk(m, V3(11, 0.6, 4), benchCF * CF(0, 3, 0), rgb(96, 74, 50), M.WoodPlanks)
	top.Name = "BenchTop"
	for _, x in ipairs({ -5, 5 }) do
		for _, z in ipairs({ -1.6, 1.6 }) do
			mk(m, V3(0.5, 3, 0.5), benchCF * CF(x, 1.5, z), rgb(70, 54, 40), M.Wood)
		end
	end
	deco(m, V3(10.5, 0.3, 3.4), benchCF * CF(0, 1, 0), rgb(70, 54, 40), M.WoodPlanks)
	deco(m, V3(3, 0.05, 2), benchCF * CF(1.5, 3.33, 0) * ANG(0, 0.2, 0), rgb(90, 130, 170), M.SmoothPlastic)
	deco(m, V3(2.4, 1, 1.1), benchCF * CF(-3, 3.8, -0.4), rgb(150, 36, 30), M.Metal)
	deco(m, V3(0.9, 0.9, 1.2), benchCF * CF(4.6, 3.75, -1.2), rgb(40, 90, 60), M.Metal)
	-- стенд с инструментами на задней стене
	local peg = deco(m, V3(9, 4, 0.2), cf * CF(0, 6, d / 2 - 0.45), rgb(84, 70, 52), M.WoodPlanks)
	for i = -1, 1 do
		deco(m, V3(0.25, 2.4, 0.2), peg.CFrame * CF(i * 2.6, 0, -0.2) * ANG(0, 0, i * 0.3), rgb(120, 120, 124), M.Metal)
	end
	local lamp = deco(m, V3(2, 0.2, 0.5), cf * CF(0, 9.3, 1), rgb(255, 236, 200), M.Neon)
	lightAt(lamp, 22, 1, rgb(255, 226, 180))
	S.Workbench.RegisterBench(top, "depot")
	waypoint(top, "ИЗГОТОВИТЬ", C.neonYellow)
	CONST.depotBox(cf, w / 2, d / 2, "workshop")

	-- поддон с углём у тротуара
	local pal = roadCF(96, -27)
	deco(m, V3(4, 0.5, 4), pal * CF(0, 0.25, 0), rgb(96, 76, 52), M.WoodPlanks)
	for i = 1, 5 do
		ball(m, 1.3, pal * CF(math.cos(i) * 1.1, 1, math.sin(i) * 1.1), rgb(24, 24, 24), M.Slate, false)
	end
end

-- Плакат на стене: тонкая панель с надписью (−Z — лицевая сторона)
function CONST.poster(parent, cf, w, h, text, bg, fg)
	local p = deco(parent, V3(w, h, 0.05), cf, bg, M.SmoothPlastic, { CastShadow = false })
	local gui = signText(p, text, fg, Enum.NormalId.Front, false, Enum.Font.GothamBlack)
	gui.LightInfluence = 1
	local label = gui:FindFirstChildOfClass("TextLabel")
	if label then
		label.Size = UDim2.fromScale(0.86, 0.5)
		label.Position = UDim2.fromScale(0.07, 0.25)
	end
	return p
end

-- Мелочи депо: урны, скамейка, гидрант, столбики у ворот, лужи, мусор, коробки и поддоны, мешки у вышек,
-- прожекторы на крыше магазина, провода к фонарям, плакаты, бочка с огнём, конусы у выезда, брошенная машина.
-- Точки колёс, угля и спавна не заняты.
function CONST.buildDepotDetails(folder)
	local rng = Random.new(hashSeed("depot_details"))
	local walk = 0.5 -- верх тротуара
	local avoid = { { 104, -10.5 }, { 52, 19 }, { 36, 10.5 }, { 64, -19.5 }, { 118, 18.5 }, { 22, -18.5 }, { 96, -20 }, { 40, -19 } }
	local function free(s, d)
		for _, a in ipairs(avoid) do
			if math.abs(a[1] - s) < 4 and math.abs(a[2] - d) < 4 then
				return false
			end
		end
		return true
	end

	for _, p in ipairs({ { 26, 21.5 }, { 108, 22 }, { 196, -21.5 }, { 56, -22 } }) do
		local cf = roadCF(p[1], p[2]) * CF(0, walk, 0)
		vcyl(folder, 2.4, 1.6, cf * CF(0, 1.2, 0), rgb(46, 58, 50), M.Metal)
		deco(folder, V3(0.2, 1.8, 1.8), cf * CF(0, 2.45, 0) * ANG(0, 0, rad(90)), rgb(30, 34, 32), M.Metal, { Shape = CYL, CastShadow = false })
	end
	do
		local cf = roadCF(132, 21) * CF(0, walk, 0)
		mk(folder, V3(1.8, 0.3, 5), cf * CF(0, 1.5, 0), rgb(96, 72, 50), M.WoodPlanks)
		deco(folder, V3(0.3, 1.5, 5), cf * CF(0.95, 2.35, 0) * ANG(0, 0, rad(-8)), rgb(90, 68, 48), M.WoodPlanks)
		for _, z in ipairs({ -2, 2 }) do
			deco(folder, V3(1.8, 1.4, 0.3), cf * CF(0.1, 0.7, z), rgb(50, 52, 54), M.Metal)
		end
	end
	do
		local cf = roadCF(148, 16.8) * CF(0, walk, 0)
		vcyl(folder, 1.8, 0.8, cf * CF(0, 0.9, 0), rgb(170, 36, 30), M.Metal)
		ball(folder, 0.8, cf * CF(0, 1.8, 0), rgb(170, 36, 30), M.Metal, false)
		hcyl(folder, 1.3, 0.35, cf * CF(0, 1.2, 0), rgb(150, 30, 26), M.Metal, false)
	end
	for _, s in ipairs({ 63, 70, 77 }) do
		local cf = roadCF(s, 22.6) * CF(0, walk, 0)
		vcyl(folder, 2.2, 0.7, cf * CF(0, 1.1, 0), rgb(52, 54, 56), M.Metal)
		deco(folder, V3(0.25, 0.74, 0.74), cf * CF(0, 1.7, 0) * ANG(0, 0, rad(90)), rgb(210, 170, 40), M.SmoothPlastic, { Shape = CYL, CastShadow = false })
	end

	-- лужи: тротуары, дорога, двор
	for _, p in ipairs({ { 12, 19.5, walk, 3.6 }, { 150, -19, walk, 3 }, { 232, 18, walk, 4.2 }, { 130, -6, 0.28, 5 }, { 172, 5, 0.28, 3.4 }, { 60, -48, 0.3, 4.6 }, { 196, 42, 0.3, 3.8 } }) do
		local disc = mkShape(folder, CYL, V3(0.04, p[4], p[4]), roadCF(p[1], p[2]) * CF(0, p[3] + 0.02, 0) * ANG(0, 0, rad(90)), rgb(24, 28, 32), M.Glass, false)
		disc.Transparency = 0.2
		disc.Reflectance = 0.35
		disc.CastShadow = false
	end
	local canColors = { rgb(150, 40, 36), rgb(60, 90, 140), rgb(170, 160, 150) }
	for _ = 1, 14 do
		local s = rng:NextNumber(-30, 290)
		local d = randSide(rng) * rng:NextNumber(15.5, 22.5)
		if free(s, d) then
			local cf = roadCF(s, d) * CF(0, walk + 0.03, 0) * ANG(0, rng:NextNumber(0, 6.28), 0)
			if rng:NextNumber() < 0.6 then
				deco(folder, V3(0.9, 0.04, 1.2), cf, rgb(206, 200, 186), M.SmoothPlastic, { CastShadow = false })
			else
				deco(folder, V3(0.9, 0.34, 0.34), cf * CF(0, 0.15, 0), canColors[rng:NextInteger(1, #canColors)], M.Metal, { Shape = CYL, CastShadow = false })
			end
		end
	end

	-- коробки у склада и стопка поддонов
	do
		local cf = roadCF(152, 22) * CF(0, walk, 0)
		mk(folder, V3(2.4, 1.8, 2.4), cf * CF(0, 0.9, 0) * ANG(0, 0.2, 0), rgb(150, 116, 74), M.Cardboard)
		mk(folder, V3(2, 1.5, 2), cf * CF(0.3, 2.55, 0.2) * ANG(0, -0.3, 0), rgb(160, 126, 82), M.Cardboard)
		mk(folder, V3(2.2, 1.6, 2.2), cf * CF(0.2, 0.8, 2.6) * ANG(0, 0.5, 0), rgb(140, 108, 70), M.Cardboard)
	end
	for i = 0, 2 do
		deco(folder, V3(4, 0.45, 4), roadCF(126, 21) * CF(0, walk + 0.225 + i * 0.47, 0) * ANG(0, i * 0.08, 0), rgb(110, 86, 58), M.WoodPlanks, { CanCollide = true })
	end

	-- мешки с песком у подножия вышек (с разрывом у лестницы)
	for _, t in ipairs({ { -26, 64 }, { 292, -44 } }) do
		local cf = roadCF(t[1], t[2])
		for _, k in ipairs({ 0, 1, 2, 4, 5 }) do
			deco(folder, V3(2.6, 1.1, 1.3), cf * ANG(0, k * math.pi / 3, 0) * CF(0, 0.55, -5.4), rgb(122, 110, 84), M.Fabric)
		end
	end

	-- прожекторы на крыше магазина (ночью светят на улицу), провода к фонарям, плакаты на плитке
	local shop = facingRoad(70, 40)
	for _, x in ipairs({ -30, 30 }) do
		local fcf = shop * CF(x, 24.6, -16.8) * ANG(rad(-35), 0, 0)
		deco(folder, V3(1.8, 1.2, 1.2), fcf, rgb(40, 42, 44), M.Metal)
		local lens = deco(folder, V3(1.5, 0.9, 0.1), fcf * CF(0, 0, -0.65), rgb(255, 244, 220), M.Neon, { CastShadow = false })
		local sl = Instance.new("SpotLight")
		sl.Face = Enum.NormalId.Front
		sl.Angle = 60
		sl.Range = 50
		sl.Brightness = 2.2
		sl.Color = rgb(255, 236, 206)
		sl.Parent = lens
		nightLamp(lens, rgb(140, 138, 130), "Glass")
	end
	for _, w in ipairs({ { -33.5, 30 }, { 33.5, 112 } }) do
		local bracket = deco(folder, V3(0.4, 0.4, 0.6), shop * CF(w[1], 20, -16.3), rgb(40, 40, 42), M.Metal, { CastShadow = false })
		wire(bracket, bracket.Position, (roadCF(w[2], RHW + 1.8) * CF(0, 18.4, 0)).Position, 1.1)
	end
	CONST.poster(folder, shop * CF(-27, 6.5, -16.06), 3, 4, "РАЗЫСКИВАЕТСЯ", rgb(214, 204, 176), rgb(40, 30, 24))
	CONST.poster(folder, shop * CF(28, 6, -16.06) * ANG(0, 0, rad(3)), 3.4, 2.6, "ЭВАКУАЦИЯ ОТМЕНЕНА", rgb(150, 36, 30), rgb(240, 236, 226))

	-- бочка с огнём и два походных стула у палатки
	do
		local cf = roadCF(102, -48)
		local b = barrel(folder, cf, rgb(70, 50, 36))
		local fire = Instance.new("Fire")
		fire.Size = 3.5
		fire.Heat = 7
		fire.Parent = b
		lightAt(b, 20, 1.6, rgb(255, 140, 60))
		CONST.depotBox(cf, 1.2, 1.2, "barrel")
		for k = 0, 1 do
			local ccf = cf * ANG(0, 0.8 + k * 1.9, 0) * CF(0, 0, -3.4)
			deco(folder, V3(1.6, 0.25, 1.6), ccf * CF(0, 1.3, 0), rgb(60, 70, 50), M.Fabric)
			deco(folder, V3(1.6, 1.4, 0.2), ccf * CF(0, 1.9, -0.75) * ANG(rad(10), 0, 0), rgb(60, 70, 50), M.Fabric)
			deco(folder, V3(1.4, 1.2, 0.15), ccf * CF(0, 0.65, 0), rgb(40, 40, 42), M.Metal, { CastShadow = false })
		end
	end

	-- конусы у выезда (у кромки дороги, не на пути автобуса)
	for _, p in ipairs({ { 282, -11.5 }, { 287, -12 }, { 283, 11.8 } }) do
		local cf = roadCF(p[1], p[2]) * CF(0, 0.27, 0)
		deco(folder, V3(1.4, 0.2, 1.4), cf * CF(0, 0.1, 0), rgb(40, 40, 40), M.Rubber, { CastShadow = false })
		deco(folder, V3(1.8, 0.9, 0.9), cf * CF(0, 1.1, 0) * ANG(0, 0, rad(90)), rgb(220, 110, 40), M.SmoothPlastic, { Shape = CYL, CastShadow = false })
		deco(folder, V3(0.35, 0.95, 0.95), cf * CF(0, 1.3, 0) * ANG(0, 0, rad(90)), rgb(236, 236, 230), M.SmoothPlastic, { Shape = CYL, CastShadow = false })
	end

	-- брошенная машина во дворе
	local carCF = roadCF(240, -31, rad(12))
	carWreck(folder, carCF, rng)
	CONST.depotBox(carCF, 3.3, 6.5, "wreck")
end

function CONST.buildYard(folder)
	local rng = Random.new(hashSeed("depot_yard"))
	local sA, sB = -44, 312
	-- бордюры и тротуары вдоль улицы, площадки двора
	for _, sd in ipairs({ -1, 1 }) do
		strip(folder, sA, sB, sd * (RHW + 0.5), 1, C.curb, M.Concrete, 0.6, 0.6, true)
		strip(folder, sA, sB, sd * (RHW + 5), 8, rgb(92, 92, 90), M.Concrete, 0.5, 0.5, true)
	end
	strip(folder, sA, sB, 51, 54, rgb(58, 58, 56), M.Concrete, 0.3, 0.4, true)
	strip(folder, sA, sB, -42, 36, rgb(58, 58, 56), M.Concrete, 0.3, 0.4, true)

	-- фонари на тротуарах
	for _, s in ipairs({ -10, 30, 112, 160, 200, 240, 280 }) do
		streetLamp(folder, roadCF(s, RHW + 1.8), -1, rng)
	end
	for _, s in ipairs({ -20, 20, 48, 100, 140, 180, 220, 260, 300 }) do
		streetLamp(folder, roadCF(s, -(RHW + 1.8)), 1, rng)
	end

	-- забор из рабицы с колючкой вокруг двора
	chainFence(folder, roadCF(sA, -60) * ANG(0, rad(90), 0), sB - 12 - sA, { height = 9, spacing = 3, coil = true })
	chainFence(folder, roadCF(sA, 80) * ANG(0, rad(90), 0), sB - 12 - sA, { height = 9, spacing = 3, coil = true })
	chainFence(folder, roadCF(sA, -60), 140, { height = 9, spacing = 3, coil = true })

	-- КПП на выезде: открытые створки, будка, поднятый шлагбаум
	for _, sd in ipairs({ -1, 1 }) do
		chainFence(folder, roadCF(sB - 12, sd * (RHW + 3)) * ANG(0, sd > 0 and rad(60) or rad(120), 0), 12, { height = 8, spacing = 3 })
		local fenceEnd = sd > 0 and 80 or -60
		local dStart = math.min(sd * (RHW + 3), fenceEnd)
		chainFence(folder, roadCF(sB - 12, dStart), math.abs(fenceEnd - sd * (RHW + 3)), { height = 9, spacing = 3, coil = true })
	end
	local booth = facingRoad(290, 24)
	mk(folder, V3(6, 7, 6), booth * CF(0, 3.5, 0), rgb(84, 86, 84), M.Concrete)
	deco(folder, V3(4.4, 2.2, 0.2), booth * CF(0, 4.6, -3.05), C.glass, M.Glass, { Transparency = 0.1 })
	deco(folder, V3(7, 0.5, 7), booth * CF(0, 7.25, 0), rgb(50, 52, 50), M.CorrodedMetal)
	vcyl(folder, 12, 0.4, roadCF(300, RHW + 2.5) * CF(0, 6, 0), rgb(200, 50, 40), M.Metal, false)
	CONST.depotBox(booth, 3.2, 3.2)

	-- вышки
	local t1 = roadCF(-26, 64)
	watchtower(folder, t1, 24, rng)
	CONST.depotBox(t1, 4, 4, "tower")
	local t2 = roadCF(292, -44)
	watchtower(folder, t2, 22, rng)
	CONST.depotBox(t2, 4, 4, "tower")

	-- камуфляжная палатка, ящики, покрышки, бочки, отбойники
	local tent = roadCF(118, -44)
	camoTent(folder, tent, rng, 10, 16)
	CONST.depotBox(tent, 5.5, 8.5, "tent")
	for i = 1, 3 do
		crate(folder, roadCF(132 + i * 3.4, -34) * ANG(0, rng:NextNumber(-0.2, 0.2), 0), 2.8, true)
	end
	crate(folder, roadCF(136.4, -34) * CF(0, 2.8, 0) * ANG(0, 0.4, 0), 2.2, false)
	tires(folder, roadCF(104, -30), 3, rng)
	tires(folder, roadCF(108, -31), 2, rng)
	tires(folder, roadCF(170, 30), 4, rng)
	for i = 1, 3 do
		barrel(folder, roadCF(180 + i * 2.3, 29))
	end
	for _, s in ipairs({ 200, 212 }) do
		jersey(folder, roadCF(s, -30) * ANG(0, rad(90), 0), 8)
	end
	crate(folder, roadCF(24, -30), 3, false)
	crate(folder, roadCF(27.5, -30.5), 3, true)

	-- тупик позади: закрытые ворота через дорогу
	chainFence(folder, roadCF(sA, -(RHW + 1)), 2 * RHW + 2, { height = 9, spacing = 3, coil = true })
	S.Obstacles.AddBox(CONST.DEPOT_CHUNK, roadCF(sA, 0), RHW + 2, 1.5, { hard = true, gate = true, gateText = "Тупик — езжайте вперёд", kind = "bounds" })

	local spawn = Instance.new("SpawnLocation")
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Size = V3(6, 0.2, 6)
	spawn.CFrame = roadCF(40, -(RHW + 5)) * CF(0, 0.55, 0)
	spawn.Color = rgb(70, 70, 72)
	spawn.Material = M.DiamondPlate
	spawn.Duration = 0
	spawn.CollisionGroup = "World"
	spawn.Parent = folder
	local decal = spawn:FindFirstChildOfClass("Decal")
	if decal then
		decal:Destroy()
	end
end

function Props.BuildDepot(folder)
	CONST.buildYard(folder)
	CONST.buildShop(folder)
	CONST.buildNeighbours(folder)
	CONST.buildWorkshop(folder)
	CONST.buildDepotDetails(folder)
end

-- Точки на земле для 4+ колёс автобуса (рядом с автобусом и магазином)
function Props.DepotWheelSpawns()
	if not (S and S.World and S.World.Road) then
		return {}
	end
	local list = {}
	for _, p in ipairs({
		{ 104, -10.5, 0.27 },
		{ 52, 19, 0.5 },
		{ 36, 10.5, 0.27 },
		{ 64, -19.5, 0.5 },
		{ 118, 18.5, 0.5 },
		{ 22, -18.5, 0.5 },
	}) do
		table.insert(list, roadCF(p[1], p[2], p[1] * 0.37) + V3(0, p[3], 0))
	end
	return list
end

-- Точки для топлива (уголь) у поддона напротив магазина
function Props.DepotFuelSpawns()
	if not (S and S.World and S.World.Road) then
		return {}
	end
	local list = {}
	for _, p in ipairs({ { 92, -19.5 }, { 96, -20 }, { 100, -19.5 } }) do
		table.insert(list, roadCF(p[1], p[2]) + V3(0, 0.5, 0))
	end
	return list
end

return Props
