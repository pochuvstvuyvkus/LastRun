-- Вид от первого лица: руки (рукава цвета одежды, кисти цвета кожи) и предмет активного слота,
-- привязанные к камере. Покачивание при ходьбе/беге, отставание при повороте мыши, прыжок, дыхание.
-- Анимации заданы ключевыми кадрами (позы хвата интерполируются CFrame:Lerp, без выворачивания):
-- удары каждого оружия ближнего боя (замах → удар → доводка), выстрел с отдачей и ходом затвора,
-- перезарядка по видам (магазин, барабан, патроны по одному, затвор, тетива), натяжение лука,
-- бросок, еда/питьё/лечение, установка, доставание и убирание, подбор с земли.
-- Звук — строго по кадрам анимации через C.SoundFX (ключи shared/Sounds), см. docs/SPEC_v5.md 2.1–2.2.
-- Все детали закреплены, без коллизий и теней, в workspace.CurrentCamera; двигаются одним BulkMoveTo.
-- Модель уменьшена (SCALE) вокруг камеры — на экране выглядит так же, но меньше утыкается в стены;
-- у отдельных предметов свой масштаб (Weapons.List[id].vmScale, например короткая лопата как в оригинале).
-- API: ViewModel.SetItem(entry|nil), ViewModel.Play(name, duration, opts) -> bool, ViewModel.Stop(name),
-- ViewModel.IsVisible(), ViewModel.GetMuzzle(), ViewModel.GetEjectPort(), ViewModel.HitStop(sec),
-- ViewModel.Impact(heavy)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Weapons = require(Shared.Weapons)
local WeaponModels = require(Shared.WeaponModels)
local ItemModels = require(Shared.ItemModels)
local Sounds = require(Shared.Sounds)

local ViewModel = {}
local C
local player = Players.LocalPlayer

local SCALE = 0.4
local PARK = CFrame.new(0, -5000, 0)
local V = Vector3.new
local rad = math.rad
local SMOOTH = Enum.SurfaceType.Smooth
local EMPTY = {}

-- Руки (полный масштаб, пространство камеры: +X вправо, +Y вверх, -Z вперёд)
local UPPER = 1.35
local FORE = 1.3
local SHOULDER = { R = V(1.15, -1.55, 0.55), L = V(-1.15, -1.55, 0.55) }
local POLE = { R = V(1, -1.2, 0.3), L = V(-1, -1.2, 0.3) }
local WRIST = { R = V(0.1, -0.25, 0.32), L = V(-0.1, -0.25, 0.32) }

local EASE = {
	io = function(x)
		return x * x * (3 - 2 * x)
	end,
	out = function(x)
		local i = 1 - x
		return 1 - i * i * i
	end,
	["in"] = function(x)
		return x * x * x
	end,
	lin = function(x)
		return x
	end,
}

local root -- Model в камере
local shown = false
local arms = {}
local item -- активный предмет (запись кэша)
local cache = {}
local pending -- запись для смены: таблица или false (пустые руки)
local targetKey -- ключ предмета, к которому идём
local phase = "idle" -- "lower" | "raise" | "idle"
local equipK = 0
local equipStyle = "normal" -- "normal" | "reach" (подбор с земли)
local reach -- состояние подбора: { t, dur, grabbed, sound, id }
local anim -- текущая анимация
local stopUntil = 0
local moveParts, moveCFs, lastCount = {}, {}, 0
local lastGripWorld -- CFrame хвата в мире (дуло, окно выброса)
local lastGripLocal -- то же в пространстве камеры, полный масштаб (для мировых деталей: магазин)
local lastCam
local grabK = 0
local skinColor = Color3.fromRGB(204, 160, 120)
local sleeveColor = Color3.fromRGB(62, 68, 76)

-- Звук ------------------------------------------------------------------------------------

local warnedSound = false

-- where: nil — 2D (свои руки), Vector3 — точка мира; opts: {volume, pitch, delay}
local function sfx(key, where, opts)
	local m = C and C.SoundFX
	if type(key) ~= "string" or not m or type(m.Play) ~= "function" then
		return nil
	end
	local ok, s = pcall(m.Play, key, where, opts)
	if not ok then
		if not warnedSound then
			warnedSound = true
			warn("[ViewModel] SoundFX.Play: " .. tostring(s))
		end
		return nil
	end
	return s
end

-- Ключ звука подбора/доставания предмета
local function itemSound(id, kind)
	if type(id) ~= "string" then
		return nil
	end
	local ok, key = pcall(Sounds.PickupKey, id, kind)
	return ok and key or "pickup_generic"
end

-- Помощники ------------------------------------------------------------------------------------

local function scaled(cf, k)
	return CFrame.new(cf.Position * (SCALE * (k or 1))) * cf.Rotation
end

local function poseCF(p, r)
	return CFrame.new(p) * CFrame.Angles(0, rad(r.Y), 0) * CFrame.Angles(rad(r.X), 0, 0) * CFrame.Angles(0, 0, rad(r.Z))
end

local function segmentCF(a, b)
	local mid = (a + b) / 2
	local dir = b - a
	if math.abs(dir.X) + math.abs(dir.Z) < 1e-4 then
		return CFrame.lookAt(mid, b, Vector3.xAxis)
	end
	return CFrame.lookAt(mid, b)
end

-- Доля отрезка [a, b] со сглаживанием: 0 до a, 1 после b
local function seg(t, a, b, ease)
	if t <= a then
		return 0
	end
	if t >= b or b <= a then
		return 1
	end
	return (EASE[ease or "io"] or EASE.io)((t - a) / (b - a))
end

-- Двухзвенная рука: локоть по плечу S, запястью W и направлению сгиба pole.
-- Если цель дальше длины руки — плечо подтягивается к ней (оно всё равно за кадром).
local function solveArm(S, W, pole)
	local d = W - S
	local dist = d.Magnitude
	if dist < 1e-3 then
		return S + pole.Unit * UPPER, S
	end
	local dir = d / dist
	local reachLen = UPPER + FORE - 0.02
	if dist > reachLen then
		S = W - dir * reachLen
		dist = reachLen
	elseif dist < math.abs(UPPER - FORE) + 0.05 then
		dist = math.abs(UPPER - FORE) + 0.05
	end
	local x = (UPPER * UPPER - FORE * FORE + dist * dist) / (2 * dist)
	local h = math.sqrt(math.max(0, UPPER * UPPER - x * x))
	local side = pole - dir * pole:Dot(dir)
	if side.Magnitude < 1e-3 then
		side = V(0, -1, 0)
	end
	return S + dir * x + side.Unit * h, S
end

local function newPart(name, size, color, material)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size * SCALE
	p.Color = color
	p.Material = material or Enum.Material.SmoothPlastic
	p.TopSurface = SMOOTH
	p.BottomSurface = SMOOTH
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Massless = true
	p.CFrame = PARK
	p.Parent = root
	return p
end

local function buildArm(side)
	return {
		side = side,
		upper = newPart(side .. "UpperSleeve", V(0.5, 0.5, UPPER), sleeveColor, Enum.Material.Fabric),
		fore = newPart(side .. "ForeSleeve", V(0.46, 0.46, FORE), sleeveColor, Enum.Material.Fabric),
		cuff = newPart(side .. "Cuff", V(0.52, 0.52, 0.14), sleeveColor, Enum.Material.Fabric),
		wrist = newPart(side .. "Wrist", V(0.32, 0.32, 0.3), skinColor),
		fist = newPart(side .. "Fist", V(0.44, 0.46, 0.5), skinColor),
		knuckles = newPart(side .. "Knuckles", V(0.46, 0.12, 0.44), skinColor),
		thumb = newPart(side .. "Thumb", V(0.15, 0.15, 0.32), skinColor),
	}
end

-- Цвета рук по персонажу: кожа — голова; рукава — одежда (рисунок рубашки недоступен —
-- тёмная куртка) или цвет рук, если он отличается от кожи
local function applyColors(char)
	local bc = char and char:FindFirstChildOfClass("BodyColors")
	local head = char and char:FindFirstChild("Head")
	local skin = skinColor
	if bc then
		skin = bc.HeadColor3
	elseif head and head:IsA("BasePart") then
		skin = head.Color
	end
	local armPart = char and (char:FindFirstChild("RightUpperArm") or char:FindFirstChild("Right Arm"))
	local armColor = (armPart and armPart:IsA("BasePart")) and armPart.Color or skin
	local sleeve
	if char and char:FindFirstChildOfClass("Shirt") then
		sleeve = Color3.fromRGB(62, 68, 76)
	else
		local dr, dg, db = armColor.R - skin.R, armColor.G - skin.G, armColor.B - skin.B
		sleeve = (dr * dr + dg * dg + db * db > 0.01) and armColor or skin
	end
	skinColor, sleeveColor = skin, sleeve
	local cuff = sleeve:Lerp(Color3.new(0, 0, 0), 0.3)
	for _, a in pairs(arms) do
		a.upper.Color = sleeve
		a.fore.Color = sleeve
		a.cuff.Color = cuff
		a.wrist.Color = skin
		a.fist.Color = skin
		a.knuckles.Color = skin:Lerp(Color3.new(0, 0, 0), 0.12)
		a.thumb.Color = skin
	end
end

-- Предметы ------------------------------------------------------------------------------------

-- Левая рука на оружии (пространство хвата, полный масштаб предмета)
local SUPPORT = {
	shovel = CFrame.new(0, 0, -2.15),
	bat = CFrame.new(0, 0, 0.38),
	fire_axe = CFrame.new(0, 0, -1.25),
	katana = CFrame.new(0, 0, 0.55),
	sledgehammer = CFrame.new(0, 0, -1.25),
	pistol = CFrame.new(-0.1, -0.26, 0.12) * CFrame.Angles(0, 0, rad(-18)),
	revolver = CFrame.new(-0.12, -0.28, 0.14) * CFrame.Angles(0, 0, rad(-20)),
	shotgun = CFrame.new(0, 0.05, -1.3),
	rifle = CFrame.new(0, 0.18, -1.6),
	sniper = CFrame.new(0, 0.12, -1.9),
	crossbow = CFrame.new(0, 0.05, -1.15),
}

-- Правая рука на оружии (если не в начале координат модели)
local RIGHT_HAND = {
	shovel = CFrame.new(0, 0, 0.12),
}

local THROW_BY_ITEM = {}
for id, def in pairs(Weapons.List) do
	if def.kind == "throw" and type(def.item) == "string" then
		THROW_BY_ITEM[def.item] = def
	end
end

local function entryKey(entry)
	if type(entry) == "table" and (entry.kind == "weapon" or entry.kind == "item") and type(entry.id) == "string" then
		return entry.kind .. ":" .. entry.id
	end
	return nil
end

local function prepPart(p)
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
end

local function attachmentAt(handle, handleOffset, name, pos)
	local a = Instance.new("Attachment")
	a.Name = name
	a.CFrame = handleOffset:Inverse() * CFrame.new(pos * SCALE)
	a.Parent = handle
	return a
end

local function buildItem(entry)
	local key = entryKey(entry)
	if not key then
		return nil
	end
	local rec = cache[key]
	if rec then
		return rec
	end
	local isWeapon = entry.kind == "weapon" and WeaponModels.Has(entry.id)
	local ok, model = pcall(function()
		if isWeapon then
			return WeaponModels.Build(entry.id)
		end
		return ItemModels.Build(entry.id)
	end)
	if not ok or typeof(model) ~= "Instance" then
		return nil
	end
	local def = isWeapon and Weapons.List[entry.id] or THROW_BY_ITEM[entry.id]
	local bbCF, bbSize = model:GetBoundingBox()
	local scale = (def and tonumber(def.vmScale)) or 1
	rec = {
		key = key,
		kind = entry.kind,
		id = entry.id,
		model = model,
		def = def,
		parts = {},
		byGroup = {},
		byName = {},
		scale = scale,
		center = bbCF.Position,
		size = bbSize,
	}
	if isWeapon then
		rec.style = def and def.kind or "melee"
		if rec.style == "melee" and not SUPPORT[entry.id] then
			rec.style = "melee1"
		elseif rec.style == "gun" and not (def and def.twoHanded) then
			rec.style = "pistol"
		elseif rec.style == "crossbow" then
			rec.style = "gun"
		end
		local spec = WeaponModels.Specs[entry.id]
		rec.spec = spec
		rec.muzzle = spec and spec.muzzle
		rec.casing = spec and spec.casing
		rec.magAxis = spec and spec.magAxis
		rec.magPivot = spec and spec.magPivot
		rec.support = SUPPORT[entry.id]
		rec.rightHand = RIGHT_HAND[entry.id]
	else
		rec.style = ItemModels.HoldStyle(entry.id)
		if def then
			rec.style = "throw"
		end
	end
	local handle = model.PrimaryPart
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			local offset = scaled(d.CFrame, scale)
			prepPart(d)
			d.Size = d.Size * (SCALE * scale)
			if d.Name == "String" then
				d.Transparency = 1 -- тетиву лука рисуют лучи (Beam) по точке натяжения
			end
			if d == handle then
				rec.handleOffset = offset
			end
			local e = { part = d, offset = offset }
			table.insert(rec.parts, e)
			local group = d:GetAttribute("Group") or d.Name
			local list = rec.byGroup[group]
			if not list then
				list = {}
				rec.byGroup[group] = list
			end
			table.insert(list, e)
			if d.Name ~= group then
				local named = rec.byName[d.Name]
				if not named then
					named = {}
					rec.byName[d.Name] = named
				end
				table.insert(named, e)
			end
		elseif d:IsA("Attachment") then
			d.CFrame = CFrame.new(d.CFrame.Position * (SCALE * scale)) * d.CFrame.Rotation
		end
	end
	for _, e in ipairs(rec.parts) do
		e.part.CFrame = PARK
	end
	-- имена групп совпадают с именами деталей: видимостью управляем через них же
	for group, list in pairs(rec.byGroup) do
		if not rec.byName[group] then
			rec.byName[group] = list
		end
	end

	-- след удара у холодного оружия
	if handle and def and def.kind == "melee" then
		local base, tip = handle:FindFirstChild("TrailBase"), handle:FindFirstChild("TrailTip")
		if base and tip then
			local trail = Instance.new("Trail")
			trail.Attachment0 = base
			trail.Attachment1 = tip
			trail.FaceCamera = false
			trail.Lifetime = 0.12
			trail.MinLength = 0.01
			trail.LightEmission = 0.3
			trail.LightInfluence = 0.5
			trail.Color = ColorSequence.new(WeaponModels.TrailColor(entry.id))
			trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 1) })
			trail.Enabled = false
			trail.Parent = handle
			rec.trail = trail
		end
	end

	-- лук: тетива из двух лучей к точке натяжения и стрела на полке
	if handle and rec.handleOffset and def and def.kind == "bow" then
		local top = attachmentAt(handle, rec.handleOffset, "StringTop", V(0, 2.5, 0.52))
		local bottom = attachmentAt(handle, rec.handleOffset, "StringBottom", V(0, -2.5, 0.52))
		rec.nock = attachmentAt(handle, rec.handleOffset, "StringNock", V(0, 0, 0.52))
		for _, a in ipairs({ top, bottom }) do
			local beam = Instance.new("Beam")
			beam.Attachment0 = a
			beam.Attachment1 = rec.nock
			beam.Width0 = 0.04 * SCALE
			beam.Width1 = 0.04 * SCALE
			beam.FaceCamera = true
			beam.Segments = 1
			beam.Color = ColorSequence.new(Color3.fromRGB(235, 232, 220))
			beam.LightInfluence = 1
			beam.Transparency = NumberSequence.new(0)
			beam.Parent = handle
		end
		local okArrow, arrow = pcall(WeaponModels.MakeProjectile, "arrow")
		if okArrow and typeof(arrow) == "Instance" then
			rec.arrowParts = {}
			for _, p in ipairs(arrow:GetDescendants()) do
				if p:IsA("BasePart") then
					local offset = scaled(p.CFrame)
					prepPart(p)
					p.Size = p.Size * SCALE
					p.CFrame = PARK
					p.Parent = model
					table.insert(rec.arrowParts, { part = p, offset = offset })
				end
			end
			arrow:Destroy()
		end
	end

	-- бутылка с тряпкой: огонёк на фитиле при замахе
	if def and def.kind == "throw" then
		local wick = model:FindFirstChild("Wick")
		local flame = Instance.new("Part")
		flame.Name = "Flame"
		flame.Shape = Enum.PartType.Ball
		flame.Material = Enum.Material.Neon
		flame.Color = Color3.fromRGB(255, 150, 50)
		flame.Size = V(0.3, 0.3, 0.3) * SCALE
		flame.Transparency = 1
		prepPart(flame)
		flame.CFrame = PARK
		flame.Parent = model
		local wickOffset = wick and (function()
			for _, e in ipairs(rec.parts) do
				if e.part == wick then
					return e.offset
				end
			end
			return nil
		end)() or CFrame.new(V(0, 0.9, 0) * SCALE)
		table.insert(rec.parts, { part = flame, offset = wickOffset * CFrame.new(0, 0.18 * SCALE, 0) })
		rec.flame = flame
	end

	model.Parent = nil
	cache[key] = rec
	return rec
end

local function applyItem(entry)
	if item then
		if item.trail then
			item.trail.Enabled = false
		end
		item.model.Parent = nil
	end
	anim = nil
	item = nil
	if entry then
		local rec = buildItem(entry)
		if rec then
			rec.model.Parent = root
			item = rec
		end
	end
end

-- Звук доставания предмета в руки
local function equipSound(rec)
	if not rec then
		return
	end
	local key
	if rec.kind == "weapon" then
		key = Weapons.EquipSound(rec.id) or "pickup_weapon"
	else
		key = itemSound(rec.id, "item")
	end
	sfx(key, nil, { volume = 0.9 })
end

-- Сменить предмет в руках: опустить текущий и поднять новый (entry = nil — пустые руки)
function ViewModel.SetItem(entry)
	local key = entryKey(entry)
	if key == targetKey then
		return
	end
	targetKey = key
	pending = key and entry or false
	if reach and not reach.grabbed then
		return -- подбор сам подставит предмет в кадре захвата
	end
	if not item then
		applyItem(pending)
		pending = nil
		equipK = 0
		phase = item and "raise" or "idle"
		if item then
			equipSound(item)
		end
	else
		phase = "lower"
		equipStyle = "normal"
		if not key then
			-- убрали в рюкзак: короткий звук убирания
			local cur = item
			if cur then
				sfx(cur.kind == "weapon" and (Weapons.EquipSound(cur.id) or "pickup_weapon") or itemSound(cur.id, "item"), nil, { volume = 0.5, pitch = 0.9 })
			end
		end
	end
end

function ViewModel.IsVisible()
	return shown and item ~= nil
end

-- Короткое замедление анимации при попадании
function ViewModel.HitStop(duration)
	duration = type(duration) == "number" and math.clamp(duration, 0, 0.2) or 0.06
	stopUntil = math.max(stopUntil, os.clock() + duration)
end

-- Позы и анимации -------------------------------------------------------------------------------
-- Поза хвата: p — позиция в пространстве камеры (полный масштаб), r — {наклон вверх, поворот влево,
-- крен} в градусах; модель смотрит -Z вперёд, +Y вверх.

local function P(x, y, z, pitch, yaw, roll)
	return { p = V(x, y, z), r = V(pitch or 0, yaw or 0, roll or 0) }
end

local REST = {
	-- лопата: полотно внизу-слева впереди, черенок по диагонали к правой руке у тела (как в оригинале)
	shovel = P(1.67, -1.24, -1.52, 12, 92, 106),
	melee = P(0.9, -0.8, -1.45, 38, -6, -12),
	melee1 = P(0.85, -0.78, -1.35, 48, 4, -18),
	bat = P(0.95, -0.72, -1.3, 52, -14, -26),
	fire_axe = P(0.85, -0.85, -1.3, 30, -8, -10),
	katana = P(0.78, -0.72, -1.4, 40, -4, -16),
	sledgehammer = P(0.8, -1.02, -1.25, 18, -10, -8),
	pistol = P(0.62, -0.62, -1.55, 1, 2, 0),
	gun = P(0.55, -0.62, -1.25, 0, 1.5, 0),
	bow = P(-0.32, -0.42, -2.05, 0, 6, -12),
	throw = P(0.75, -0.62, -1.35, 8, 0, -10),
	hand = P(0.72, -0.7, -1.45, 10, -15, -5),
	handle = P(0.8, -0.28, -1.6, 0, -20, 0),
	long = P(0.85, -0.85, -1.3, 22, -10, -8),
}

-- Прицеливание (ПКМ): оружие по центру, мушка на линии взгляда
local AIM = {
	pistol = P(0, -0.56, -1.4),
	revolver = P(0, -0.56, -1.4),
	shotgun = P(0, -0.47, -1.15),
	rifle = P(0, -0.6, -1.0),
	sniper = P(0, -0.82, -0.9),
	crossbow = P(0, -0.62, -0.95),
	bow = P(-0.12, -0.3, -2.0, 0, 3, -6),
}

local SPRINT_DP, SPRINT_DR = V(-0.15, -0.2, 0.2), V(-22, 28, 14)

-- Есть ли ещё стрелы: по ним видно, лежит ли стрела на полке лука в покое
local function hasAmmo(rec)
	local inv = C and C.State and C.State.Inventory
	local ammo = (rec.def and rec.def.ammo) or "arrow"
	return type(inv) == "table" and (tonumber(inv[ammo]) or 0) > 0
end

local function restPose(rec)
	if rec.style == "carry" then
		local s = rec.size
		return { p = V(0, -0.6 - s.Y * 0.3, -1.2 - math.max(s.X, s.Z) * 0.35), r = V(-8, 0, 0) }
	end
	return REST[rec.id] or REST[rec.style] or REST.hand
end

local ANIMS = {}

local function K(t, pose, ease)
	return { t, poseCF(pose.p, pose.r), ease }
end

-- Ключ между двумя позами (доводка к покою): доля k от a к b
local function KMix(t, a, b, k, ease)
	return { t, poseCF(a.p, a.r):Lerp(poseCF(b.p, b.r), k), ease }
end

local function keyAnim(name, keys, spec)
	spec = spec or {}
	spec.keys = keys
	spec.strike = spec.strike or (keys[1] and keys[1][1]) or 0.18
	ANIMS[name] = spec
end

-- Ключи идут между позой покоя (t = 0) и возвратом в неё (t = 1)
local function sampleKeys(keys, t, restCF)
	local prevT, prevCF = 0, restCF
	for i = 1, #keys + 1 do
		local k = keys[i]
		local kt, kcf, ease
		if k then
			kt, kcf, ease = k[1], k[2], k[3]
		else
			kt, kcf, ease = 1, restCF, "io"
		end
		if t <= kt then
			local span = kt - prevT
			local x = span > 0 and (t - prevT) / span or 1
			x = (EASE[ease or "io"] or EASE.io)(math.clamp(x, 0, 1))
			return prevCF:Lerp(kcf, x)
		end
		prevT, prevCF = kt, kcf
	end
	return restCF
end

-- Удары: 0.18 — пик замаха (в этот кадр свистит оружие), 0.3 — попадание (резко, "in"),
-- 0.42 — доводка ("out"), 0.62 — фиксация, дальше возврат в позу покоя.
-- Лопата: позы подобраны по кадрам оригинала (полотно крупно, черенок через кадр).
local SHOVEL_REST = REST.shovel

keyAnim("shovel_side", {
	K(0.18, P(0.71, -1.13, -2.15, 26, 97, 75)),
	K(0.3, P(2.9, -0.93, -0.99, 16, 75, 155), "in"),
	K(0.42, P(3.26, -1.41, -1.43, 27, 100, 81), "out"),
	KMix(0.62, P(3.26, -1.41, -1.43, 27, 100, 81), SHOVEL_REST, 0.45),
}, { melee = true })

keyAnim("shovel_back", {
	K(0.18, P(3.53, -1.71, -0.45, 29, 68, 51)),
	K(0.3, P(2.64, -0.83, -1.1, 13, 80, 54), "in"),
	K(0.42, P(1.5, -1.04, -0.79, 13, 80, 129), "out"),
	KMix(0.62, P(1.5, -1.04, -0.79, 13, 80, 129), SHOVEL_REST, 0.45),
}, { melee = true })

keyAnim("shovel_overhead", {
	K(0.18, P(0.36, -1.71, -0.52, 67, 22, 94)),
	K(0.3, P(0.18, -2.78, -0.81, 24, 4, 25), "in"),
	K(0.42, P(0.22, -2.62, -0.64, 6, 7, -2), "out"),
	KMix(0.62, P(0.22, -2.62, -0.64, 6, 7, -2), SHOVEL_REST, 0.45),
}, { melee = true })

keyAnim("bat_swing", {
	K(0.18, P(1.6, -0.1, -0.6, 20, -95, -75)),
	K(0.3, P(0.2, -0.35, -2.0, 0, 5, -90), "in"),
	K(0.44, P(-1.1, -0.45, -1.1, -8, 85, -80), "out"),
	K(0.62, P(-0.5, -0.8, -1.2, 15, 45, -40)),
}, { melee = true })

keyAnim("bat_backswing", {
	K(0.18, P(-1.2, -0.1, -0.7, 20, 95, 75)),
	K(0.3, P(0.3, -0.35, -2.0, 0, -5, 90), "in"),
	K(0.44, P(1.5, -0.45, -1.1, -8, -85, 80), "out"),
	K(0.62, P(1.0, -0.8, -1.3, 20, -35, 20)),
}, { melee = true })

keyAnim("machete_slash_r", {
	K(0.18, P(1.2, 0.3, -0.8, 70, -40, -60)),
	K(0.3, P(0.1, -0.3, -1.7, 5, 20, -80), "in"),
	K(0.42, P(-0.7, -0.8, -1.3, -30, 50, -80), "out"),
	K(0.58, P(-0.2, -0.85, -1.3, 10, 20, -40)),
}, { melee = true })

keyAnim("machete_slash_l", {
	K(0.18, P(-0.5, 0.35, -0.9, 70, 40, 60)),
	K(0.3, P(0.4, -0.3, -1.7, 5, -20, 80), "in"),
	K(0.42, P(1.2, -0.8, -1.3, -30, -50, 80), "out"),
	K(0.58, P(1.0, -0.85, -1.3, 20, -20, 30)),
}, { melee = true })

keyAnim("machete_rise", {
	K(0.18, P(1.1, -1.2, -1.0, -40, -30, -70)),
	K(0.3, P(0.2, -0.2, -1.8, 30, 15, -80), "in"),
	K(0.42, P(-0.5, 0.4, -1.4, 70, 40, -70), "out"),
	K(0.58, P(0.2, -0.4, -1.3, 40, 10, -30)),
}, { melee = true })

keyAnim("machete_stab", {
	K(0.18, P(0.9, -0.7, -0.5, 0, 5, -90)),
	K(0.3, P(0.15, -0.35, -2.6, -2, 0, -90), "in"),
	K(0.45, P(0.12, -0.35, -2.8, -4, 0, -90), "out"),
	K(0.62, P(0.7, -0.7, -1.5, 25, 5, -40)),
}, { melee = true })

keyAnim("axe_chop", {
	K(0.2, P(0.6, 0.45, -0.6, 130, -5, -5)),
	K(0.3, P(0.3, -0.3, -1.9, -15, 0, 0), "in"),
	K(0.44, P(0.25, -0.8, -1.7, -45, 0, 0), "out"),
	K(0.62, P(0.6, -0.9, -1.5, 5, 0, -5)),
}, { melee = true })

keyAnim("axe_sweep", {
	K(0.2, P(1.7, -0.2, -0.6, 10, -100, -80)),
	K(0.3, P(0.2, -0.45, -2.1, -5, 5, -90), "in"),
	K(0.44, P(-1.2, -0.55, -1.1, -10, 90, -85), "out"),
	K(0.62, P(-0.5, -0.9, -1.2, 10, 45, -45)),
}, { melee = true })

keyAnim("katana_slash_r", {
	K(0.18, P(1.1, 0.4, -0.9, 80, -35, -55)),
	K(0.3, P(0, -0.25, -2.0, 0, 15, -75), "in"),
	K(0.42, P(-0.9, -0.75, -1.4, -30, 55, -80), "out"),
	K(0.56, P(-0.3, -0.8, -1.3, 15, 25, -40)),
}, { melee = true })

keyAnim("katana_slash_l", {
	K(0.18, P(-0.6, 0.45, -0.9, 80, 35, 55)),
	K(0.3, P(0.4, -0.25, -2.0, 0, -15, 75), "in"),
	K(0.42, P(1.3, -0.75, -1.4, -30, -55, 80), "out"),
	K(0.56, P(1.0, -0.8, -1.3, 20, -25, 35)),
}, { melee = true })

keyAnim("katana_spin", {
	K(0.15, P(1.6, -0.4, -0.2, 5, -120, -85)),
	K(0.3, P(0.1, -0.4, -2.1, 0, 0, -90), "lin"),
	K(0.45, P(-1.6, -0.4, -0.3, 5, 120, -85), "lin"),
	K(0.56, P(-0.8, -0.9, -0.9, 10, 60, -50), "out"),
}, { melee = true })

keyAnim("sledge_slam", {
	K(0.22, P(0.3, 0.55, -0.5, 140, 0, 0)),
	K(0.3, P(0.15, -0.8, -2.2, -50, 0, 0), "in"),
	K(0.42, P(0.15, -1.1, -2.1, -65, 0, 0), "out"),
	K(0.62, P(0.4, -1.0, -1.7, -30, 0, 0)),
}, { melee = true })

-- Старые имена серий (совместимость с сохранёнными данными и v4)
ANIMS.shovel_sweep = ANIMS.shovel_side
ANIMS.shovel_thrust = ANIMS.shovel_back
ANIMS.shovel_chop = ANIMS.shovel_overhead

-- Бросок бутылки: замах с горящим фитилём, бросок, следующая бутылка поднимается
keyAnim("throw", {
	K(0.3, P(1.1, 0.15, 0.25, 80, -20, -30), "out"),
	K(0.45, P(0.5, 0.0, -2.2, 10, 0, 0), "in"),
	K(0.62, P(0.4, -1.0, -2.0, -30, 0, 0), "out"),
}, {
	duration = 0.55,
	events = { { 0.45, "throw" } },
	extra = function(t)
		return { hideItem = t > 0.47 and t < 0.86, flame = t > 0.05 and t < 0.47 }
	end,
})

-- Еда: ко рту и жевание; питьё: запрокинуть бутылку
keyAnim("eat", {
	K(0.22, P(0.15, -0.4, -0.6, -30, 15, -10), "out"),
	K(0.4, P(0.12, -0.46, -0.58, -24, 15, -8)),
	K(0.55, P(0.15, -0.4, -0.6, -30, 15, -10)),
	K(0.7, P(0.12, -0.46, -0.58, -24, 15, -8)),
	K(0.82, P(0.15, -0.42, -0.62, -28, 15, -10)),
}, { duration = 0.8, events = { { 0.24, "eat" } } })

keyAnim("drink", {
	K(0.25, P(0.1, -0.3, -0.62, -70, 8, 0), "out"),
	K(0.78, P(0.08, -0.26, -0.6, -80, 8, 0)),
}, { duration = 0.9, events = { { 0.3, "drink" } } })

-- Лечение: левая рука поднята, правая обматывает её бинтом
ANIMS.heal = {
	duration = 1.5,
	events = { { 0.1, "bandage" } },
	fn = function(t, ctx)
		local w = math.sin(math.min(1, t / 0.12) * math.pi / 2)
		if t > 0.88 then
			w = w * (1 - (t - 0.88) / 0.12)
		end
		local a = ctx.elapsed * 9
		local dp = V(-0.55 * w + math.cos(a) * 0.12 * w, -0.1 * w + math.sin(a) * 0.1 * w, 0.25 * w)
		return dp, V(-10 * w, 30 * w, 0), {
			lh = CFrame.new(-0.25, -0.95, -1.35) * CFrame.Angles(rad(50), rad(20), 0),
			lhWeight = w,
		}
	end,
}

-- Укол адреналина в руку
keyAnim("inject", {
	K(0.3, P(0.45, -0.15, -1.2, 10, 0, 30), "out"),
	K(0.45, P(-0.15, -1.25, -1.1, -70, 30, 0), "in"),
	K(0.7, P(-0.15, -1.3, -1.05, -72, 30, 0)),
}, {
	duration = 0.9,
	events = { { 0.45, "inject" } },
	extra = function(t)
		return { lh = CFrame.new(-0.35, -1.45, -1.25) * CFrame.Angles(rad(70), 0, 0), lhWeight = (t > 0.15 and t < 0.9) and 1 or 0 }
	end,
})

-- Установка на землю, прикрепление к автобусу, закинуть в печь, осмотр
keyAnim("place", {
	K(0.35, P(0.35, -1.35, -2.1, -40, 0, 0), "out"),
	K(0.6, P(0.35, -1.4, -2.2, -42, 0, 0)),
}, { duration = 0.8, events = { { 0.4, "place" } } })

-- звук прикрепления играет сервер (BusService) в точке слота
keyAnim("attach", {
	K(0.3, P(0, -0.8, -1.6, 5, 0, 0), "out"),
	K(0.45, P(0, -0.75, -2.8, 0, 0, 0), "in"),
	K(0.65, P(0, -0.8, -2.7, 0, 0, 0)),
}, { duration = 0.8 })

keyAnim("throw_in", {
	K(0.3, P(0.3, -0.5, -1.0, 20, 0, 0), "out"),
	K(0.45, P(0.15, -0.8, -2.6, -25, 5, 0), "in"),
	K(0.6, P(0.15, -0.9, -2.5, -30, 5, 0)),
}, { duration = 0.7, events = { { 0.45, "furnace_load" } } })

keyAnim("inspect", {
	K(0.2, P(0.25, -0.4, -1.1, 15, 30, 0), "out"),
	K(0.5, P(0.2, -0.38, -1.05, 25, -40, 10)),
	K(0.8, P(0.25, -0.42, -1.1, 10, 20, -5)),
}, { duration = 1.2, itemSound = 0.18 })

-- Отдача и ход затвора. opts: {empty = магазин опустел (затвор встаёт назад), dry = осечка}
ANIMS.recoil = {
	duration = 0.22,
	build = function(a, rec)
		local def = rec and rec.def
		a.empty = a.opts.empty == true
		local key = a.opts.dry and (def and def.drySound or "pistol_dry") or (def and def.shotSound)
		a.events = key and { { 0, key } } or nil
		if def and def.casing and not a.opts.dry and not def.boltCycle then
			a.events = a.events or {}
			table.insert(a.events, { 0.04, function()
				local at = ViewModel.GetEjectPort()
				if at and C and C.Effects then
					C.Effects.EjectCasing(at, lastCam and lastCam.CFrame.LookVector or nil, SCALE)
				end
			end })
		end
	end,
	fn = function(t, ctx)
		if ctx.opts.dry then
			local k = math.sin(math.min(1, t / 0.1) * math.pi)
			return V(0, -0.01 * k, 0.02 * k), V(-1.5 * k, 0, 0), nil
		end
		local r = math.clamp(((ctx.def and ctx.def.recoil) or 6) / 10, 0.25, 2.4)
		local k = t < 0.12 and (t / 0.12) or (1 - (t - 0.12) / 0.88) ^ 2
		-- затвор: назад за 0.03 и обратно за 0.07; пустой — остаётся сзади
		local slide
		if ctx.empty then
			slide = math.min(1, t / 0.03) * 0.32
		else
			slide = (t < 0.03 and t / 0.03 or math.max(0, 1 - (t - 0.03) / 0.07)) * 0.32
		end
		return V(0, 0.03 * r * k, 0.2 * r * k), V(5 * r * k, ctx.jitter * r * k, ctx.jitter * 0.8 * r * k), { slide = slide }
	end,
}

-- Затвор снайперской винтовки после выстрела: правая рука уходит на рукоять затвора и возвращается
ANIMS.bolt_cycle = {
	duration = 1.0,
	events = { { 0.28, "sniper_bolt" }, { 0.42, function()
		local at = ViewModel.GetEjectPort()
		if at and C and C.Effects then
			C.Effects.EjectCasing(at, lastCam and lastCam.CFrame.RightVector or nil, SCALE, { size = V(0.3, 0.1, 0.1) })
		end
	end } },
	fn = function(t)
		local w = seg(t, 0.12, 0.28) - seg(t, 0.62, 0.8)
		local up = seg(t, 0.2, 0.32) - seg(t, 0.58, 0.68)
		local back = seg(t, 0.32, 0.45) - seg(t, 0.5, 0.62)
		local dp = V(0.05 * w, -0.05 * w, 0.1 * w)
		local dr = V(-4 * w, 3 * w, -6 * w)
		return dp, dr, {
			groups = { Bolt = { up = up, back = back } },
			rhPlan = w > 0.02 and { "grip", "bolt", w } or nil,
		}
	end,
}

-- Перезарядка: общий каркас. Стиль берётся из Weapons.List[id].reloadStyle
-- (magazine — пистолет, rifle_magazine — автомат, cylinder — револьвер, shells — дробовик,
-- bolt — снайперская винтовка, string — арбалет).

-- Уронить магазин на землю: мировая деталь с гравитацией и вращением, звук при касании
local function dropMagazine(rec, distance)
	if not rec or not rec.magAxis or not lastGripLocal or not lastCam or not shown then
		return
	end
	local okBuild, model = pcall(WeaponModels.BuildGroup, rec.id, "Magazine", rec.magPivot)
	if not okBuild or typeof(model) ~= "Instance" then
		return
	end
	local camCF = lastCam.CFrame
	local pivot = rec.magPivot or V(0, 0, 0)
	local gripFull = lastGripLocal * CFrame.new(rec.magAxis * distance)
	local cf = camCF * gripFull * CFrame.new(pivot)
	local down = (camCF * lastGripLocal):VectorToWorldSpace(rec.magAxis)
	local vel = down * 4 + V(0, -1, 0)
	local char = player.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if hrp then
		vel = vel + hrp.AssemblyLinearVelocity -- на едущем автобусе магазин падает рядом, а не отстаёт
	end
	if C and C.Effects and type(C.Effects.Debris) == "function" then
		C.Effects.Debris(model, cf, vel, V(math.random() * 6 - 3, math.random() * 6 - 3, math.random() * 8 - 4), {
			sound = "pistol_mag_drop",
			life = 2.6,
		})
	else
		model:Destroy()
	end
end

-- Пистолет: наклон, магазин выпадает, новый с пояса, вставка, затвор (если было пусто)
ANIMS.reload_magazine = {
	duration = 1.6,
	build = function(a, rec)
		local empty = a.opts.empty == true
		a.empty = empty
		local ev = {
			{ 0.1, "pistol_mag_out" },
			{ 0.18, function()
				dropMagazine(rec, 0.5)
			end },
			{ 0.64, "pistol_mag_in" },
		}
		if empty then
			table.insert(ev, { 0.83, "pistol_slide" })
		end
		a.events = ev
	end,
	fn = function(t, ctx)
		local tilt = seg(t, 0, 0.12) - seg(t, 0.82, 0.97)
		local jolt = (t > 0.64 and t < 0.72) and math.sin((t - 0.64) / 0.08 * math.pi) or 0
		local dp = V(-0.16 * tilt, 0.06 * tilt - 0.03 * jolt, 0.12 * tilt)
		local dr = V(10 * tilt - 4 * jolt, 16 * tilt, 26 * tilt)
		local extra = {}
		-- магазин: выходит и падает, новый появляется в руке под рукоятью и садится на место
		if t < 0.18 then
			extra.mag = 0.5 * seg(t, 0.1, 0.18, "in")
		elseif t < 0.5 then
			extra.mag = false
		else
			extra.mag = 0.6 * (1 - seg(t, 0.5, 0.64, "out"))
		end
		if ctx.empty then
			if t < 0.78 then
				extra.slide = 0.32
			elseif t < 0.83 then
				extra.slide = 0.32 + 0.06 * seg(t, 0.78, 0.83)
			else
				extra.slide = 0.38 * (1 - seg(t, 0.83, 0.87, "in"))
			end
		end
		if t < 0.12 then
			extra.lhPlan = { "support", "support", 0 }
		elseif t < 0.36 then
			extra.lhPlan = { "support", "belt", seg(t, 0.12, 0.3) }
		elseif t < 0.5 then
			extra.lhPlan = { "belt", "magOut", seg(t, 0.36, 0.5, "out") }
		elseif t < 0.64 then
			extra.lhPlan = { "magOut", "magIn", seg(t, 0.5, 0.64, "in") }
		elseif ctx.empty then
			if t < 0.74 then
				extra.lhPlan = { "magIn", "slide", seg(t, 0.64, 0.74) }
			elseif t < 0.83 then
				extra.lhPlan = { "slide", "slideBack", seg(t, 0.74, 0.8) }
			else
				extra.lhPlan = { "slideBack", "support", seg(t, 0.85, 0.96) }
			end
		else
			extra.lhPlan = { "magIn", "support", seg(t, 0.64, 0.82) }
		end
		return dp, dr, extra
	end,
}

-- Автомат: магазин выщёлкивается вперёд-вниз и падает, новый вставляется, затвор при пустом
ANIMS.reload_rifle_magazine = {
	duration = 2.6,
	build = function(a, rec)
		local empty = a.opts.empty == true
		a.empty = empty
		local ev = {
			{ 0.1, "rifle_mag_out" },
			{ 0.2, function()
				dropMagazine(rec, 0.55)
			end },
			{ 0.62, "rifle_mag_in" },
		}
		if empty then
			table.insert(ev, { 0.8, "rifle_bolt" })
		end
		a.events = ev
	end,
	fn = function(t, ctx)
		local tilt = seg(t, 0, 0.12) - seg(t, 0.84, 0.97)
		local jolt = (t > 0.62 and t < 0.7) and math.sin((t - 0.62) / 0.08 * math.pi) or 0
		local dp = V(-0.1 * tilt, -0.14 * tilt - 0.03 * jolt, 0.14 * tilt)
		local dr = V(-12 * tilt - 4 * jolt, 12 * tilt, 22 * tilt)
		local extra = {}
		if t < 0.2 then
			extra.mag = 0.55 * seg(t, 0.1, 0.2, "in")
		elseif t < 0.48 then
			extra.mag = false
		else
			extra.mag = 0.6 * (1 - seg(t, 0.48, 0.62, "out"))
		end
		if ctx.empty then
			extra.groups = { Bolt = { back = seg(t, 0.72, 0.8) - seg(t, 0.8, 0.86) } }
		end
		if t < 0.12 then
			extra.lhPlan = { "support", "support", 0 }
		elseif t < 0.34 then
			extra.lhPlan = { "support", "belt", seg(t, 0.12, 0.3) }
		elseif t < 0.48 then
			extra.lhPlan = { "belt", "magOut", seg(t, 0.34, 0.48, "out") }
		elseif t < 0.62 then
			extra.lhPlan = { "magOut", "magIn", seg(t, 0.48, 0.62, "in") }
		elseif ctx.empty then
			if t < 0.78 then
				extra.lhPlan = { "magIn", "bolt", seg(t, 0.62, 0.76) }
			else
				extra.lhPlan = { "bolt", "support", seg(t, 0.84, 0.96) }
			end
		else
			extra.lhPlan = { "magIn", "support", seg(t, 0.62, 0.8) }
		end
		return dp, dr, extra
	end,
}

-- Револьвер: барабан откидывается влево, гильзы вылетают, новые патроны, барабан защёлкивается
ANIMS.reload_cylinder = {
	duration = 2.0,
	build = function(a, rec)
		a.events = {
			{ 0.1, "revolver_open" },
			{ 0.3, "revolver_eject" },
			{ 0.32, function()
				local at = ViewModel.GetEjectPort() or (lastGripWorld and lastGripWorld.Position)
				local n = math.max(1, math.floor(tonumber(a.opts.spent) or 6))
				if at and C and C.Effects then
					for i = 1, math.min(n, 6) do
						C.Effects.EjectCasing(at, lastCam and -lastCam.CFrame.UpVector or nil, SCALE, {
							side = (i - 3.5) * 1.2,
							up = 1.5,
						})
					end
				end
			end },
			{ 0.68, "revolver_load" },
			{ 0.82, "revolver_close" },
		}
		a.rec = rec
	end,
	fn = function(t)
		local open = seg(t, 0.06, 0.18) - seg(t, 0.78, 0.84)
		local up = seg(t, 0.2, 0.32) - seg(t, 0.36, 0.5)
		local tilt = seg(t, 0, 0.1) - seg(t, 0.86, 0.98)
		local dp = V(-0.14 * tilt, -0.06 * tilt + 0.12 * up, 0.16 * tilt)
		local dr = V(10 * tilt + 55 * up, 22 * tilt, 34 * tilt)
		local extra = { groups = { Cylinder = { open = open } } }
		if t < 0.1 then
			extra.lhPlan = { "support", "support", 0 }
		elseif t < 0.36 then
			extra.lhPlan = { "support", "cylinder", seg(t, 0.1, 0.2) }
		elseif t < 0.5 then
			extra.lhPlan = { "cylinder", "belt", seg(t, 0.4, 0.5) }
		elseif t < 0.7 then
			extra.lhPlan = { "belt", "cylinder", seg(t, 0.56, 0.68, "out") }
		else
			extra.lhPlan = { "cylinder", "support", seg(t, 0.82, 0.95) }
		end
		return dp, dr, extra
	end,
}

-- Дробовик: стволы переламываются, гильзы вылетают, патроны по одному, стволы защёлкиваются
ANIMS.reload_shells = {
	duration = 2.3,
	build = function(a, rec)
		local need = math.clamp(math.floor(tonumber(a.opts.need) or 2), 1, 2)
		local ev = {
			{ 0.12, "revolver_open", { pitch = 0.8, volume = 0.8 } },
			{ 0.2, function()
				local at = ViewModel.GetEjectPort() or (lastGripWorld and lastGripWorld.Position)
				if at and C and C.Effects then
					for i = 1, need do
						C.Effects.EjectCasing(at, lastCam and lastCam.CFrame.UpVector or nil, SCALE, {
							color = Color3.fromRGB(186, 36, 30),
							size = V(0.36, 0.17, 0.17),
							side = (i - 1.5) * 2,
							up = 3,
						})
					end
				end
			end },
			{ 0.45, "shotgun_shell_in" },
		}
		if need > 1 then
			table.insert(ev, { 0.62, "shotgun_shell_in" })
		end
		table.insert(ev, { 0.85, "shotgun_pump" })
		a.events = ev
		a.rec = rec
	end,
	fn = function(t)
		local open = seg(t, 0.08, 0.2) - seg(t, 0.8, 0.88)
		local down = seg(t, 0.06, 0.2) - seg(t, 0.82, 0.96)
		local dp = V(-0.06 * down, -0.2 * down, 0.1 * down)
		local dr = V(-26 * down, 10 * down, 12 * down)
		local extra = { groups = { Barrels = { open = open } }, hide = open > 0.5 and nil or { Shell = true } }
		if t < 0.28 then
			extra.lhPlan = { "support", "barrels", seg(t, 0.08, 0.24) }
		elseif t < 0.42 then
			extra.lhPlan = { "barrels", "belt", seg(t, 0.28, 0.4) }
		elseif t < 0.72 then
			extra.lhPlan = { "belt", "breech", seg(t, 0.42, 0.52, "out") }
		else
			extra.lhPlan = { "breech", "support", seg(t, 0.78, 0.94) }
		end
		return dp, dr, extra
	end,
}

-- Снайперская винтовка: затвор открывается, патроны по одному, затвор закрывается
ANIMS.reload_bolt = {
	duration = 3.0,
	build = function(a)
		local need = math.clamp(math.floor(tonumber(a.opts.need) or 5), 1, 5)
		local ev = { { 0.1, "sniper_bolt" } }
		for i = 1, math.min(need, 5) do
			table.insert(ev, { 0.3 + (i - 1) * 0.1, "shotgun_shell_in", { pitch = 1.35, volume = 0.6 } })
		end
		table.insert(ev, { 0.88, "sniper_bolt", { pitch = 0.92 } })
		a.events = ev
	end,
	fn = function(t)
		local tilt = seg(t, 0, 0.1) - seg(t, 0.92, 1)
		local up = seg(t, 0.06, 0.14) - seg(t, 0.86, 0.94)
		local back = seg(t, 0.12, 0.2) - seg(t, 0.8, 0.88)
		local dp = V(-0.12 * tilt, -0.08 * tilt, 0.14 * tilt)
		local dr = V(-10 * tilt, 18 * tilt, 26 * tilt)
		local extra = { groups = { Bolt = { up = up, back = back } } }
		if t < 0.22 then
			extra.rhPlan = { "grip", "bolt", seg(t, 0.06, 0.18) }
		elseif t < 0.8 then
			extra.rhPlan = { "bolt", "grip", seg(t, 0.24, 0.34) }
			extra.lhPlan = t < 0.3 and { "support", "belt", seg(t, 0.22, 0.3) }
				or { "belt", "breech", seg(t, 0.32, 0.44, "out") }
		else
			extra.rhPlan = { "grip", "bolt", seg(t, 0.8, 0.86) - seg(t, 0.9, 0.97) }
			extra.lhPlan = { "breech", "support", seg(t, 0.8, 0.94) }
		end
		return dp, dr, extra
	end,
}

-- Арбалет: наклон вниз, тетива натягивается, болт кладётся на ложе
ANIMS.reload_string = {
	duration = 1.5,
	events = { { 0.45, "crossbow_reload" } },
	fn = function(t)
		local down = seg(t, 0, 0.18) - seg(t, 0.8, 0.96)
		local pull = seg(t, 0.25, 0.45)
		local dp = V(0.05 * down, -0.22 * down, 0.1 * down)
		local dr = V(-36 * down, 6 * down, 8 * down)
		local extra = {
			hide = {},
			lhPlan = t < 0.5 and { "support", "string", seg(t, 0.15, 0.4) }
				or (t < 0.72 and { "string", "belt", seg(t, 0.5, 0.62) } or { "belt", "bolt", seg(t, 0.72, 0.84, "out") }),
		}
		if pull < 1 then
			extra.hide.StringCocked = true
		else
			extra.hide.StringRest = true
		end
		if t < 0.82 then
			extra.hide.Bolt = true
		end
		return dp, dr, extra
	end,
}

local RELOAD_BY_STYLE = {
	magazine = "reload_magazine",
	rifle_magazine = "reload_rifle_magazine",
	cylinder = "reload_cylinder",
	shells = "reload_shells",
	bolt = "reload_bolt",
	string = "reload_string",
}

-- Лук: натяжение удерживается, пока не отпустят; тетива и стрела видны
ANIMS.bow_draw = {
	hold = true,
	duration = 0.85,
	events = { { 0, "bow_draw" } },
	fn = function(t, ctx)
		-- при долгом удержании рука дрожит
		local over = math.max(0, ctx.elapsed - ctx.duration)
		local tremble = t >= 1 and math.sin(ctx.now * 34) * math.min(0.035, 0.008 + over * 0.012) or 0
		return V(0.12 * t, 0.05 * t + tremble, 0.1 * t), V(0, -4 * t, 6 * t + tremble * 60), { draw = 1.15 * t, arrow = true }
	end,
}

ANIMS.bow_release = {
	duration = 0.3,
	events = { { 0, "bow_release" } },
	next = "bow_nock",
	fn = function(t)
		local k = 1 - EASE.out(t)
		return V(0.05 * k, 0.03 * k, -0.05 * k), V(3 * k, 0, 0), { rhBack = 1.1 * k }
	end,
}

-- Тетива плавно отпускается без выстрела (отмена натяжения)
ANIMS.bow_ease = {
	duration = 0.25,
	fn = function(t, ctx)
		local k = (1 - EASE.io(t)) * (ctx.opts.draw or 0.6)
		return V(0.1 * k, 0.04 * k, 0.08 * k), V(0, -3 * k, 5 * k), { draw = 1.15 * k, arrow = true }
	end,
}

-- Следующая стрела: рука за спину к колчану и обратно на тетиву
ANIMS.bow_nock = {
	duration = 0.6,
	fn = function(t, ctx)
		local away = seg(t, 0, 0.35) - seg(t, 0.45, 0.9)
		local extra = { arrow = t > 0.85 and ctx.opts.has ~= false, arrowInHand = t > 0.4 and t <= 0.85 }
		extra.rhPlan = { "nock", "quiver", away }
		return V(0.02 * away, 0.03 * away, 0), V(0, 3 * away, 0), extra
	end,
}

-- Подбор предмета с земли: рука тянется вниз-вперёд и возвращается с предметом
local REACH_DUR = 0.66
local REACH_GRAB = 0.34

local function specDuration(spec, duration, rec)
	if spec.melee and rec and rec.def and type(rec.def.hitDelay) == "number" then
		return rec.def.hitDelay / 0.3
	end
	if type(duration) == "number" and duration == duration and duration > 0 then
		return math.clamp(duration, 0.1, 12)
	end
	return spec.duration or 0.6
end

-- Проиграть анимацию рук. opts: {empty, dry, need, spent, id, sound, has, draw}.
-- Возвращает true, если анимация запущена (иначе звук играет вызывающий код).
function ViewModel.Play(name, duration, opts)
	if type(name) ~= "string" then
		return false
	end
	opts = type(opts) == "table" and opts or EMPTY
	if name == "pickup" then
		-- подбор: рука опускается за предметом и возвращается уже с ним
		local key = opts.sound or itemSound(opts.id, opts.kind)
		if not shown then
			-- рук не видно (открыто окно, третье лицо): звук всё равно в нужный момент
			sfx(key, nil, { delay = REACH_GRAB * REACH_DUR })
			return false
		end
		reach = { t = 0, grabbed = false, sound = key, id = opts.id }
		equipStyle = "reach"
		phase = "lower"
		return true
	end
	if name == "reload" then
		local style = item and item.def and item.def.reloadStyle
		name = RELOAD_BY_STYLE[style] or "reload_magazine"
	end
	local spec = ANIMS[name]
	if not spec then
		return false
	end
	if item and item.trail then
		item.trail.Enabled = false
	end
	local a = {
		name = name,
		spec = spec,
		opts = opts,
		elapsed = 0,
		duration = specDuration(spec, duration, item),
		jitter = math.random() * 2 - 1,
		fired = 0,
		events = spec.events,
	}
	if spec.build then
		local okBuild, err = pcall(spec.build, a, item)
		if not okBuild then
			warn("[ViewModel] " .. name .. ": " .. tostring(err))
		end
	end
	if spec.melee then
		-- свист — в кадре начала удара; тяжёлый у финального удара серии и у тяжёлого оружия
		local heavy = opts.heavy == true or (item and item.def and item.def.heavy == true)
		a.events = { { spec.strike, heavy and "swing_heavy" or "swing_light" } }
	elseif spec.itemSound then
		local key = itemSound(opts.id or (item and item.id), item and item.kind)
		a.events = key and { { spec.itemSound, key, { volume = 0.6 } } } or nil
	end
	anim = a
	if spec.melee and item and item.trail then
		item.trail:Clear()
		item.trail.Enabled = true
		a.trailOff = a.duration * 0.55
	end
	return true
end

function ViewModel.Stop(name)
	if anim and (not name or anim.name == name) then
		if item and item.trail then
			item.trail.Enabled = false
		end
		anim = nil
	end
end

local impactK = 0

-- Толчок рук при попадании
function ViewModel.Impact(heavy)
	impactK = math.max(impactK, heavy and 1 or 0.6)
end

-- Мировая позиция дула предмета в руках (или nil, если вид скрыт)
function ViewModel.GetMuzzle()
	if not shown or not item or not lastGripWorld then
		return nil
	end
	if not item.muzzle then
		return lastGripWorld.Position
	end
	return (lastGripWorld * CFrame.new(item.muzzle * (SCALE * item.scale))).Position
end

-- Мировая позиция окна выброса гильз (для гильзы в кадре выстрела)
function ViewModel.GetEjectPort()
	if not shown or not item or not lastGripWorld then
		return nil
	end
	local at = item.casing or item.muzzle
	if not at then
		return nil
	end
	return (lastGripWorld * CFrame.new(at * (SCALE * item.scale))).Position
end

-- Кадр ------------------------------------------------------------------------------------------

local FIST_R = CFrame.new(0.03, -0.02, 0.04)
local FIST_L = CFrame.new(-0.03, -0.02, 0.04)
local ARM_KEYS = { "upper", "fore", "cuff", "wrist", "fist", "knuckles", "thumb" }
local BELT_CF = CFrame.new(-0.6, -1.95, -0.9) * CFrame.Angles(rad(-25), rad(25), 0)
local QUIVER_CF = CFrame.new(1.0, -0.35, 0.5) * CFrame.Angles(rad(15), rad(-45), 0)

-- Куда тянется рука в сложных анимациях (пространство камеры)
local function handTarget(name, rec, grip, extra)
	if name == "belt" then
		return BELT_CF
	elseif name == "quiver" then
		return QUIVER_CF
	elseif name == "support" then
		return grip * (rec.support or CFrame.new(-0.22, -0.24, 0.1)) * FIST_L
	elseif name == "grip" then
		return grip * (rec.rightHand or CFrame.new()) * FIST_R
	elseif name == "magOut" then
		local axis = rec.magAxis or V(0, -1, 0)
		return grip * CFrame.new((rec.magPivot or V(0, 0, 0)) + axis * 0.78) * CFrame.Angles(rad(-25), 0, 0)
	elseif name == "magIn" then
		local axis = rec.magAxis or V(0, -1, 0)
		return grip * CFrame.new((rec.magPivot or V(0, 0, 0)) + axis * 0.28) * CFrame.Angles(rad(-25), 0, 0)
	elseif name == "slide" then
		return grip * CFrame.new(0, 0.5, 0.16) * CFrame.Angles(0, rad(70), 0)
	elseif name == "slideBack" then
		return grip * CFrame.new(0, 0.5, 0.5) * CFrame.Angles(0, rad(70), 0)
	elseif name == "cylinder" then
		return grip * CFrame.new(-0.34, 0.26, -0.5) * CFrame.Angles(0, 0, rad(-25))
	elseif name == "breech" then
		return grip * CFrame.new(0.12, 0.26, -0.75) * CFrame.Angles(rad(-15), 0, 0)
	elseif name == "barrels" then
		return grip * CFrame.new(0, 0.1, -1.3)
	elseif name == "bolt" then
		return grip * CFrame.new(0.32, 0.5, 0.2) * CFrame.Angles(0, rad(60), 0)
	elseif name == "string" then
		return grip * CFrame.new(0, 0.34, -0.85) * CFrame.Angles(0, 0, rad(-20))
	elseif name == "nock" then
		local draw = (extra and extra.draw) or 0
		return grip * CFrame.new(0.08, 0.02, 0.52 + draw) * CFrame.Angles(0, 0, rad(-80))
	end
	return grip * (rec.rightHand or CFrame.new()) * FIST_R
end

local function planHand(plan, rec, grip, extra)
	local a = handTarget(plan[1], rec, grip, extra)
	local b = handTarget(plan[2], rec, grip, extra)
	return a:Lerp(b, math.clamp(plan[3] or 0, 0, 1))
end

local function handsFor(rec, grip, extra)
	local style = rec.style
	local rh, lh
	if style == "bow" then
		lh = grip * FIST_L
		local draw = extra and extra.draw or 0
		local back = extra and extra.rhBack or 0
		rh = grip * CFrame.new(0.08, 0.02, 0.52 + draw + back) * CFrame.Angles(0, 0, rad(-80))
	elseif style == "melee" or style == "gun" or style == "pistol" then
		rh = grip * (rec.rightHand or CFrame.new()) * FIST_R
		if rec.support then
			lh = grip * rec.support * FIST_L
		end
	elseif style == "melee1" then
		rh = grip * FIST_R
	elseif style == "carry" then
		local hx = rec.size.X / 2 + 0.08
		local cx = rec.center.X
		rh = grip * CFrame.new(cx + hx, 0, 0.05) * CFrame.Angles(0, 0, rad(90))
		lh = grip * CFrame.new(cx - hx, 0, 0.05) * CFrame.Angles(0, 0, rad(-90))
	elseif style == "long" then
		rh = grip * FIST_R
		lh = grip * CFrame.new(0, 0, -1.1) * FIST_L
	elseif style == "handle" then
		rh = grip * CFrame.new(0, 0.04, 0.02)
	else
		rh = grip * CFrame.new(0.16, -0.26, 0.06)
	end
	if extra then
		if extra.lhPlan then
			lh = planHand(extra.lhPlan, rec, grip, extra)
		end
		if extra.rhPlan then
			rh = planHand(extra.rhPlan, rec, grip, extra)
		end
		if extra.lh and (extra.lhWeight or 1) > 0.05 then
			lh = extra.lh
		end
		if extra.lhOffset and lh then
			lh = CFrame.new(extra.lhOffset) * lh
		end
	end
	return rh, lh
end

local function placeArm(a, hand, side, camCF, n)
	if not hand then
		for _, k in ipairs(ARM_KEYS) do
			n = n + 1
			moveParts[n] = a[k]
			moveCFs[n] = PARK
		end
		return n
	end
	local handPos = hand.Position
	local W = handPos + WRIST[side]
	local E, S = solveArm(SHOULDER[side], W, POLE[side])
	local fore = segmentCF(E, W)
	local right = side == "R"
	local list = {
		segmentCF(S, E),
		fore,
		fore * CFrame.new(0, 0, -(FORE / 2 - 0.08)),
		segmentCF(W, handPos),
		hand,
		hand * CFrame.new(0, 0.2, -0.04),
		hand * CFrame.new(right and -0.2 or 0.2, 0.16, -0.08) * CFrame.Angles(rad(-10), rad(right and -25 or 25), 0),
	}
	for i, k in ipairs(ARM_KEYS) do
		n = n + 1
		moveParts[n] = a[k]
		moveCFs[n] = camCF * scaled(list[i])
	end
	return n
end

local function modeIsLobby()
	local st = ReplicatedStorage:FindFirstChild("GameState")
	return st ~= nil and st:GetAttribute("Mode") == "lobby"
end

local function isScoped()
	local wc = C and C.WeaponClient
	return wc ~= nil and wc.IsScoped ~= nil and wc.IsScoped() == true
end

local function isGrabbing()
	local g = C and C.GrabClient
	if not g or type(g.IsGrabbing) ~= "function" then
		return false
	end
	local ok, v = pcall(g.IsGrabbing)
	return ok and v == true
end

local bobPhase, bobAmp, sprintK, adsK = 0, 0, 0, 0
local lagX, lagY, lagVX, lagVY = 0, 0, 0, 0
local jumpY, landK, lastVy, wasAir = 0, 0, 0, false
local lastCamCF
local toolAcc = 0
local hiddenTool, heldTool

local function setToolHidden(tool, value)
	for _, d in ipairs(tool:GetDescendants()) do
		if d:IsA("BasePart") then
			d.LocalTransparencyModifier = value
		end
	end
end

-- Инструмент в руке персонажа от первого лица скрыт локально (руки рисует вид от первого лица)
local function updateToolHide(char, firstPerson)
	local tool = char and char:FindFirstChildOfClass("Tool")
	heldTool = tool
	if tool ~= hiddenTool then
		if hiddenTool and hiddenTool.Parent then
			setToolHidden(hiddenTool, 0)
		end
		hiddenTool = tool
	end
	if tool then
		setToolHidden(tool, firstPerson and 1 or 0)
	end
end

local function shouldShow(cam, char, hum, firstPerson)
	if not firstPerson or (not item and not reach) then
		return false
	end
	if not hum or hum.Health <= 0 then
		return false
	end
	if player:GetAttribute("Downed") or player:GetAttribute("Sleeping") then
		return false
	end
	-- окна прячут руки; новый компактный инвентарь (Tab) мира не закрывает — руки видно
	if C and C.Panels and C.Panels.IsOpen() and not C.Panels.IsInventoryOpen() then
		return false
	end
	local seat = hum.SeatPart
	if seat and seat.Name == "DriverSeat" then
		return false
	end
	-- оптика снайперской винтовки: прицел рисует HUD
	if item and item.def and item.def.scope and item.def.kind == "gun" and adsK > 0.85 and isScoped() then
		return false
	end
	return cam ~= nil and char ~= nil
end

local function stepSpring(dt, targetX, targetY)
	local steps = math.clamp(math.ceil(dt * 120), 1, 8)
	local h = dt / steps
	for _ = 1, steps do
		lagVX = lagVX + ((targetX - lagX) * 140 - lagVX * 18) * h
		lagVY = lagVY + ((targetY - lagY) * 140 - lagVY * 18) * h
		lagX = lagX + lagVX * h
		lagY = lagY + lagVY * h
	end
end

-- Событие анимации: звук по ключу или действие (гильза, падение магазина)
local function fireEvents(a, t)
	local ev = a.events
	if not ev then
		return
	end
	while a.fired < #ev do
		local e = ev[a.fired + 1]
		if t < e[1] then
			return
		end
		a.fired = a.fired + 1
		if type(e[2]) == "string" then
			sfx(e[2], nil, e[3])
		elseif type(e[2]) == "function" then
			local ok, err = pcall(e[2])
			if not ok then
				warn("[ViewModel] " .. a.name .. ": " .. tostring(err))
			end
		end
	end
end

-- Подвижные группы деталей оружия (затвор, магазин, барабан, стволы) по состоянию анимации
local function groupCF(rec, name, data, extra)
	if name == "Slide" then
		local s = extra and extra.slide
		if not s or s <= 0 then
			return nil
		end
		return CFrame.new(0, 0, s)
	elseif name == "Magazine" then
		local m = extra and extra.mag
		if type(m) ~= "number" or m <= 0 then
			return nil
		end
		return CFrame.new((rec.magAxis or V(0, -1, 0)) * m)
	elseif name == "Cylinder" then
		local open = data and data.open or 0
		if open <= 0 then
			return nil
		end
		local pivot = (rec.spec and rec.spec.cylinderPivot) or V(0, 0.08, -0.45)
		return CFrame.new(pivot) * CFrame.Angles(0, 0, rad(75 * open)) * CFrame.new(-pivot)
	elseif name == "Barrels" then
		local open = data and data.open or 0
		if open <= 0 then
			return nil
		end
		local hinge = (rec.spec and rec.spec.hinge) or V(0, 0.12, -0.72)
		return CFrame.new(hinge) * CFrame.Angles(rad(-38 * open), 0, 0) * CFrame.new(-hinge)
	elseif name == "Bolt" then
		local up = data and data.up or 0
		local back = data and data.back or 0
		if up <= 0 and back <= 0 then
			return nil
		end
		local pivot = V(0, 0.4, 0.12)
		return CFrame.new(pivot) * CFrame.Angles(0, 0, rad(-65 * up)) * CFrame.new(-pivot) * CFrame.new(0, 0, 0.45 * back)
	end
	return nil
end

local function render(dt)
	local cam = workspace.CurrentCamera
	if not cam or not root then
		return
	end
	lastCam = cam
	local now = os.clock()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local head = char and char:FindFirstChild("Head")
	local firstPerson = head ~= nil and not modeIsLobby() and (cam.CFrame.Position - head.Position).Magnitude < 2.5

	toolAcc = toolAcc + dt
	if toolAcc > 0.2 or (char and char:FindFirstChildOfClass("Tool") ~= hiddenTool) then
		toolAcc = 0
		updateToolHide(char, firstPerson)
	end

	-- смена предмета: опустить, заменить, поднять; при подборе — тянемся вниз за предметом
	if reach then
		reach.t = reach.t + dt / REACH_DUR
		if not reach.grabbed and reach.t >= REACH_GRAB then
			reach.grabbed = true
			sfx(reach.sound)
			if pending ~= nil then
				applyItem(pending)
				pending = nil
			end
		end
		if reach.t >= 1 then
			reach = nil
			equipStyle = "normal"
			equipK = 1
			-- предмет сменился уже после захвата: обычная смена в руках
			phase = pending ~= nil and "lower" or "idle"
		end
	elseif phase == "lower" then
		equipK = equipK - dt / 0.12
		if equipK <= 0 then
			equipK = 0
			applyItem(pending)
			pending = nil
			phase = item and "raise" or "idle"
			if item then
				equipSound(item)
			end
		end
	elseif phase == "raise" then
		equipK = equipK + dt / 0.22
		if equipK >= 1 then
			equipK = 1
			phase = "idle"
		end
	end

	-- время анимации идёт и когда рук не видно: звуки остаются в своих кадрах
	local stopped = now < stopUntil
	local a = anim
	if a then
		a.elapsed = a.elapsed + dt * (stopped and 0.08 or 1)
		local at = math.clamp(a.elapsed / a.duration, 0, 1)
		fireEvents(a, at)
		if a.trailOff and a.elapsed >= a.trailOff then
			a.trailOff = nil
			if item and item.trail then
				item.trail.Enabled = false
			end
		end
		if a.elapsed >= a.duration and not a.spec.hold then
			local nextName = a.spec.next
			local opts = a.opts
			anim = nil
			a = nil
			if nextName then
				ViewModel.Play(nextName, nil, opts)
				a = anim
			end
		end
	end

	local want = shouldShow(cam, char, hum, firstPerson)
	if want ~= shown then
		shown = want
		if not want and item and item.trail then
			item.trail.Enabled = false
		end
		if want then
			lagX, lagY, lagVX, lagVY = 0, 0, 0, 0
		end
	end
	local parent = want and cam or nil
	if root.Parent ~= parent then
		root.Parent = parent
	end
	local camCF = cam.CFrame
	if not shown then
		lastCamCF = camCF
		return
	end

	-- перенос крупного объекта (GRAB): предмет убран, руки вытянуты вперёд
	grabK = grabK + ((isGrabbing() and 1 or 0) - grabK) * math.min(1, dt * 10)

	-- движение: покачивание, бег, прыжок, приземление
	local rootPart = char:FindFirstChild("HumanoidRootPart")
	local vel = rootPart and rootPart.AssemblyLinearVelocity or Vector3.zero
	local flatSpeed = Vector3.new(vel.X, 0, vel.Z).Magnitude
	local grounded = hum.FloorMaterial ~= Enum.Material.Air
	local moveTarget = grounded and math.clamp(flatSpeed / 16, 0, 1.5) or 0
	bobAmp = bobAmp + (moveTarget - bobAmp) * math.min(1, dt * 8)
	bobPhase = bobPhase + dt * (5 + flatSpeed * 0.45) * (grounded and 1 or 0.3)
	local sprinting = grounded and flatSpeed > 19.5 and not (a and a.spec.melee)
	sprintK = sprintK + ((sprinting and 1 or 0) - sprintK) * math.min(1, dt * 8)
	local aimPose = item and AIM[item.id]
	adsK = adsK + (((aimPose and isScoped()) and 1 or 0) - adsK) * math.min(1, dt * 14)
	local jumpTarget = grounded and 0 or math.clamp(-vel.Y * 0.006, -0.18, 0.18)
	jumpY = jumpY + (jumpTarget - jumpY) * math.min(1, dt * 10)
	if grounded and wasAir and lastVy < -25 then
		landK = math.clamp(-lastVy / 60, 0.3, 1)
	end
	wasAir = not grounded
	lastVy = vel.Y
	landK = landK * math.exp(-dt * 7)
	impactK = impactK * math.exp(-dt * 14)

	-- отставание при повороте мыши (пружина)
	local targetX, targetY = 0, 0
	if lastCamCF then
		local rx, ry = lastCamCF.Rotation:ToObjectSpace(camCF.Rotation):ToEulerAnglesYXZ()
		local invDt = 1 / math.max(dt, 1 / 240)
		targetX = math.clamp(ry * invDt * 0.04, -0.3, 0.3)
		targetY = math.clamp(-rx * invDt * 0.035, -0.25, 0.25)
	end
	lastCamCF = camCF
	stepSpring(math.min(dt, 0.1), targetX, targetY)

	local n = 0
	local extra
	local grip
	if item then
		-- поза хвата
		local rest = restPose(item)
		local p, r = rest.p, rest.r
		if aimPose and adsK > 0.001 then
			p = p:Lerp(aimPose.p, adsK)
			r = r:Lerp(aimPose.r, adsK)
		end
		if sprintK > 0.001 then
			p = p + SPRINT_DP * sprintK
			r = r + SPRINT_DR * sprintK
		end
		local baseCF = poseCF(p, r)
		local gripCF = baseCF
		if a then
			local spec = a.spec
			local t = math.clamp(a.elapsed / a.duration, 0, 1)
			local ctx = {
				def = item.def, id = item.id, now = now, elapsed = a.elapsed, duration = a.duration,
				jitter = a.jitter, style = item.style, opts = a.opts, empty = a.empty,
			}
			if spec.keys then
				gripCF = sampleKeys(spec.keys, t, baseCF)
				if spec.extra then
					extra = spec.extra(t, ctx)
				end
			elseif spec.fn then
				local dp, dr, ex = spec.fn(t, ctx)
				gripCF = poseCF(p + (dp or Vector3.zero), r + (dr or Vector3.zero))
				extra = ex
			end
		end

		local calm = 1 - 0.8 * adsK
		local breathe = math.sin(now * 1.7) * calm
		local bobX = math.sin(bobPhase) * 0.05 * bobAmp * calm
		local bobY = -math.abs(math.cos(bobPhase)) * 0.07 * bobAmp * calm + breathe * 0.012
		local layer = CFrame.new(bobX + lagX * calm, bobY + lagY * calm + jumpY - landK * 0.12 + impactK * 0.02, impactK * 0.1)
			* CFrame.Angles(rad(lagY * 22 * calm + breathe * 0.4 - landK * 4 + impactK * 2.5), rad(-lagX * 18 * calm), rad(lagX * 26 * calm + math.sin(bobPhase) * 1.5 * bobAmp * calm))
		-- доставание/убирание и подбор: предмет уходит вниз (при подборе — вниз-вперёд, за предметом)
		local e
		if reach then
			local k = reach.t <= REACH_GRAB and seg(reach.t, 0, REACH_GRAB, "out") or (1 - seg(reach.t, REACH_GRAB, 1, "io"))
			e = k
		else
			e = 1 - EASE.io(math.clamp(equipK, 0, 1))
		end
		local equipCF
		if equipStyle == "reach" then
			equipCF = CFrame.new(-0.1 * e, -1.5 * e, -0.75 * e) * CFrame.Angles(rad(-55 * e), rad(10 * e), 0)
		else
			equipCF = CFrame.new(0.25 * e, -1.5 * e, 0.3 * e) * CFrame.Angles(rad(-35 * e), 0, rad(-12 * e))
		end
		if grabK > 0.001 then
			-- несём объект: оружие опускаем совсем
			equipCF = equipCF * CFrame.new(0.1 * grabK, -1.6 * grabK, 0.2 * grabK) * CFrame.Angles(rad(-45 * grabK), 0, 0)
		end
		grip = layer * equipCF * gripCF

		-- детали предмета
		local gripWorld = camCF * scaled(grip)
		lastGripWorld = gripWorld
		lastGripLocal = grip
		local hideItem = (extra ~= nil and extra.hideItem == true) or grabK > 0.6
		local hide = extra and extra.hide
		local groups = extra and extra.groups
		local scale = item.scale
		for _, entry in ipairs(item.parts) do
			n = n + 1
			moveParts[n] = entry.part
			moveCFs[n] = hideItem and PARK or gripWorld * entry.offset
		end
		if not hideItem then
			-- подвижные группы и скрытые детали (затвор, магазин, барабан, стволы, тетива, болт)
			local slideBase = extra and extra.slide
			if slideBase == nil and item.def and item.def.reloadStyle == "magazine"
				and heldTool and heldTool:GetAttribute("Mag") == 0 then
				slideBase = 0.32 -- магазин пуст: затвор стоит на задержке
			end
			for group, list in pairs(item.byGroup) do
				local cf
				if group == "Slide" then
					cf = (slideBase and slideBase > 0) and CFrame.new(0, 0, slideBase) or nil
				else
					cf = groupCF(item, group, groups and groups[group], extra)
				end
				if cf then
					local scaledCF = CFrame.new(cf.Position * (SCALE * scale)) * cf.Rotation
					for _, entry in ipairs(list) do
						n = n + 1
						moveParts[n] = entry.part
						moveCFs[n] = gripWorld * scaledCF * entry.offset
					end
				end
			end
			if extra and extra.mag == false then
				hide = hide or {}
				hide.Magazine = true
			end
			-- арбалет: без болта тетива спущена (вне анимации перезарядки, она ведёт это сама)
			if item.def and item.def.reloadStyle == "string" and not (a and a.name == "reload_string") then
				hide = hide or {}
				if not heldTool or (heldTool:GetAttribute("Mag") or 1) > 0 then
					hide.StringRest = true
				else
					hide.StringCocked = true
					hide.Bolt = true
				end
			end
			if hide then
				for name in pairs(hide) do
					for _, entry in ipairs(item.byName[name] or EMPTY) do
						n = n + 1
						moveParts[n] = entry.part
						moveCFs[n] = PARK
					end
				end
			end
		end
		if item.flame then
			local tr = (extra and extra.flame) and 0.1 or 1
			if item.flame.Transparency ~= tr then
				item.flame.Transparency = tr
			end
		end
		if item.nock and item.handleOffset then
			local draw = extra and extra.draw or 0
			item.nock.CFrame = item.handleOffset:Inverse() * CFrame.new(V(0, 0, 0.52 + draw) * SCALE)
			local rh = grip * CFrame.new(0.08, 0.02, 0.52 + draw) * CFrame.Angles(0, 0, rad(-80))
			local showArrow = not hideItem and ((extra ~= nil and extra.arrow == true) or (a == nil and hasAmmo(item)))
			local inHand = extra ~= nil and extra.arrowInHand == true
			for _, entry in ipairs(item.arrowParts or EMPTY) do
				n = n + 1
				moveParts[n] = entry.part
				if inHand then
					local handCF = extra.rhPlan and planHand(extra.rhPlan, item, grip, extra) or rh
					moveCFs[n] = camCF * scaled(handCF * CFrame.new(0, 0, -0.6)) * entry.offset
				elseif showArrow then
					moveCFs[n] = camCF * scaled(grip * CFrame.new(V(0.03, 0.06, 0.52 + draw - 1.3) * SCALE)) * entry.offset
				else
					moveCFs[n] = PARK
				end
			end
		end
	end

	-- руки
	local rh, lh
	if item then
		rh, lh = handsFor(item, grip, extra)
		if grabK > 0.5 then
			rh = CFrame.new(0.5, -0.8, -1.85) * CFrame.Angles(rad(-15), 0, 0)
			lh = CFrame.new(-0.5, -0.8, -1.85) * CFrame.Angles(rad(-15), 0, 0)
		end
	elseif reach then
		-- пустая рука тянется за предметом
		local k = reach.t <= REACH_GRAB and seg(reach.t, 0, REACH_GRAB, "out") or (1 - seg(reach.t, REACH_GRAB, 1, "io"))
		rh = CFrame.new(0.45, -0.7 - 0.85 * k, -1.35 - 0.85 * k) * CFrame.Angles(rad(10 - 45 * k), rad(-10), 0)
	elseif grabK > 0.5 then
		rh = CFrame.new(0.5, -0.8, -1.85) * CFrame.Angles(rad(-15), 0, 0)
		lh = CFrame.new(-0.5, -0.8, -1.85) * CFrame.Angles(rad(-15), 0, 0)
	end
	n = placeArm(arms.R, rh, "R", camCF, n)
	n = placeArm(arms.L, lh, "L", camCF, n)

	for k = n + 1, lastCount do
		moveParts[k] = nil
		moveCFs[k] = nil
	end
	lastCount = n
	workspace:BulkMoveTo(moveParts, moveCFs, Enum.BulkMoveMode.FireCFrameChanged)
end

function ViewModel.Init(c)
	C = c
	root = Instance.new("Model")
	root.Name = "LR_ViewModel"
	arms.R = buildArm("R")
	arms.L = buildArm("L")
	local function recolor(char)
		if player.Character == char then
			applyColors(char)
		end
	end
	player.CharacterAppearanceLoaded:Connect(recolor)
	player.CharacterAdded:Connect(function(char)
		ViewModel.Stop()
		lastCamCF = nil
		hiddenTool, heldTool = nil, nil
		reach = nil
		equipStyle = "normal"
		task.delay(1.5, recolor, char)
	end)
	if player.Character then
		applyColors(player.Character)
	end
	RunService:BindToRenderStep("LastRunViewModel", Enum.RenderPriority.Camera.Value + 5, render)
end

return ViewModel
