-- Визуальные эффекты и звук: попадания по материалам (кровь, щепки, искры, каменная пыль),
-- цифры урона, трассеры, вспышки и гильзы, снаряды, взрывы, тряска/отдача/толчок камеры, погода,
-- 3D-звуки через shared/Sounds (пустой id = тишина), лупы двигателя автобуса, огня печи и эмбиента.
-- Частые эффекты берутся из пулов деталей/звуков — Instance не создаются на каждый выстрел/удар.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local WeaponModels = require(Shared.WeaponModels)
local Weapons = require(Shared.Weapons)
local Biomes = require(Shared.Biomes)
local Sounds = require(Shared.Sounds)

local Effects = {}
local C
local player = Players.LocalPlayer
local rng = Random.new()
local fx
local projectiles = {}

local shakeAmp = 0
local shakeUntil = 0
local shakeDuration = 0.3
local kick = 0
local punchP, punchY, punchR = 0, 0, 0

local rgb = Color3.fromRGB
local NEON = Enum.Material.Neon
local SMOOTH = Enum.Material.SmoothPlastic
local BALL = Enum.PartType.Ball
local CYL = Enum.PartType.Cylinder
local SMOKE_TEX = "rbxasset://textures/particles/smoke_main.dds"
local PARK = CFrame.new(0, 4000, 0)

local function cam()
	return workspace.CurrentCamera
end

local function V3n(n)
	return Vector3.new(n, n, n)
end

local function easeOut(a)
	local i = 1 - a
	return 1 - i * i
end

local STYLES = {
	normal = { color = rgb(255, 255, 255), size = 22 },
	crit = { color = rgb(255, 150, 40), size = 30, suffix = "!" },
	headshot = { color = rgb(255, 225, 60), size = 30, suffix = " В ГОЛОВУ!" },
	fire = { color = rgb(255, 120, 40), size = 18 },
	explosion = { color = rgb(255, 110, 200), size = 26 },
	shell = { color = rgb(255, 130, 60), size = 28 },
	ram = { color = rgb(120, 200, 255), size = 26 },
	turret = { color = rgb(200, 200, 200), size = 16 },
	mg_turret = { color = rgb(255, 220, 90), size = 18 },
	tesla = { color = rgb(130, 220, 255), size = 24 },
	lightning = { color = rgb(170, 230, 255), size = 26 },
	elite = { color = rgb(190, 90, 255), size = 34, big = true },
	player = { color = rgb(255, 60, 60), size = 26, prefix = "-", big = true },
	heal = { color = rgb(90, 230, 110), size = 24, prefix = "+", big = true },
	bus = { color = rgb(255, 160, 60), size = 22, prefix = "-", suffix = " авт." },
	busheal = { color = rgb(120, 230, 140), size = 22, prefix = "+", suffix = " авт." },
}

-- Звук ------------------------------------------------------------------------------------
-- Все звуки — через C.SoundFX (пул, варианты записей и высоты из shared/Sounds, защита от дублей).
-- Effects.Play — совместимость для других модулей: старый ключ эффекта -> ключ shared/Sounds.
local SOUND_ALIAS = {
	ui = { key = "ui_click" },
	click = { key = "ui_click", volume = 0.8 },
	hit = { key = "empty_click", volume = 0.45 },
	hurt = { key = "player_hurt" },
	shoot = { key = "pistol_shot" },
	shot_pistol = { key = "revolver_shot" },
	shot_shotgun = { key = "shotgun_shot" },
	shot_rifle = { key = "rifle_shot" },
	shot_sniper = { key = "sniper_shot" },
	mg = { key = "rifle_shot", volume = 0.7 },
	zap = { key = "thunder", volume = 0.25, pitch = 2.2 },
	boom = { key = "explosion" },
	thump = { key = "explosion", volume = 0.5, pitch = 0.6 },
	slam = { key = "hit_stone", volume = 1.4, pitch = 0.55 },
	swing = { key = "swing_light" },
	pickup = { key = "pickup_generic" },
	arrow_hit = { key = "arrow_hit_ground" },
}
-- Ключи, которые разные источники могут звать часто: не чаще раза в N секунд
local GAPS = { hurt = 0.35, zombie_groan = 0.4, zombie_attack = 0.12, zombie_death = 0.1, mg = 0.05, zap = 0.08, hit = 0.05 }
local lastSound = {}
local warnedSound = false

-- Проиграть ключ shared/Sounds через C.SoundFX. where: nil — 2D (свои руки, интерфейс), Vector3/CFrame —
-- точка, Instance — на объекте. opts: {volume, pitch, delay, looped}. Sound или nil (нет записи/дубль).
local function sfx(key, where, opts)
	local m = C and C.SoundFX
	if not m or type(m.Play) ~= "function" then
		return nil
	end
	local ok, s = pcall(m.Play, key, where, opts)
	if not ok then
		if not warnedSound then
			warnedSound = true
			warn("[Effects] SoundFX.Play: " .. tostring(s))
		end
		return nil
	end
	return s
end

local function sfxStop(sound, key)
	local m = C and C.SoundFX
	if sound and m and type(m.Stop) == "function" then
		pcall(m.Stop, sound, key)
	end
end

-- Совместимость: key — ключ shared/Sounds или старый ключ эффекта; position — Vector3 (3D) или nil (2D);
-- pitch, volume — множители к настройкам записи. Возвращает Sound или nil.
function Effects.Play(key, position, pitch, volume)
	if type(key) ~= "string" then
		return nil
	end
	local gap = GAPS[key]
	if gap then
		local now = os.clock()
		if now - (lastSound[key] or 0) < gap then
			return nil
		end
		lastSound[key] = now
	end
	local alias = SOUND_ALIAS[key]
	local vol = (alias and alias.volume or 1) * (type(volume) == "number" and volume or 1)
	local pit = (alias and alias.pitch or 1) * (type(pitch) == "number" and pitch or 1)
	local opts = nil
	if vol ~= 1 or pit ~= 1 then
		opts = { volume = vol, pitch = pit }
	end
	return sfx(alias and alias.key or key, typeof(position) == "Vector3" and position or nil, opts)
end

-- Лупы (двигатель, печь, эмбиент): громкость плавно идёт к цели
local loops = {}

local function loopEntry(key, roll)
	local e = loops[key]
	if e then
		return e
	end
	if not Sounds.Get(key) then
		return nil
	end
	local s = Instance.new("Sound")
	s.Name = "LR_Loop_" .. key
	Sounds.Apply(s, key)
	s.Looped = true
	e = { sound = s, base = s.Volume, vol = 0, target = 0, pitch = 1 }
	s.Volume = 0
	if roll then
		local att = Instance.new("Attachment")
		att.Name = "LR_Loop_" .. key
		att.Parent = workspace.Terrain
		s.RollOffMode = Enum.RollOffMode.InverseTapered
		s.RollOffMinDistance = roll[1]
		s.RollOffMaxDistance = roll[2]
		s.Parent = att
		e.att = att
	else
		s.Parent = SoundService
	end
	loops[key] = e
	return e
end

local function setLoop(key, target, pitch, position, roll)
	local e = loops[key]
	if not e then
		if target <= 0.001 then
			return
		end
		e = loopEntry(key, roll)
		if not e then
			return
		end
	end
	e.target = target
	if pitch then
		e.pitch = pitch
	end
	if position and e.att then
		e.att.WorldPosition = position
	end
end

local function updateLoops(dt)
	for _, e in pairs(loops) do
		local s = e.sound
		if s.Parent then
			e.vol = e.vol + (e.target - e.vol) * math.min(1, dt * 2.5)
			if e.target <= 0.001 and e.vol < 0.005 then
				e.vol = 0
				if s.IsPlaying then
					s:Stop()
				end
			else
				if not s.IsPlaying then
					s:Play()
				end
				s.Volume = e.base * e.vol
				s.PlaybackSpeed = s.PlaybackSpeed + (e.pitch - s.PlaybackSpeed) * math.min(1, dt * 3)
			end
		end
	end
end

-- Пул деталей для частых эффектов -------------------------------------------------------------
local SHAPES = { Block = Enum.PartType.Block, Ball = BALL, Cylinder = CYL }
local POOL_CAP = { Block = 240, Ball = 110, Cylinder = 40 }
local partPools = { Block = {}, Ball = {}, Cylinder = {} }
local poolCount = { Block = 0, Ball = 0, Cylinder = 0 }
local items = {}
local moveParts, moveCFs, lastMoveN = {}, {}, 0

local function newPoolPart(shape)
	local p = Instance.new("Part")
	p.Name = "LR_Fx"
	p.Shape = SHAPES[shape]
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Size = V3n(0.2)
	p.Transparency = 1
	p.CFrame = PARK
	p.Parent = fx
	poolCount[shape] = poolCount[shape] + 1
	return p
end

local function acquirePart(shape)
	local list = partPools[shape]
	while #list > 0 do
		local p = table.remove(list)
		if p.Parent then
			return p
		end
		poolCount[shape] = poolCount[shape] - 1
	end
	if poolCount[shape] < POOL_CAP[shape] then
		return newPoolPart(shape)
	end
	-- пул исчерпан: забираем самый старый эффект той же формы
	for i, it in ipairs(items) do
		if it.shape == shape and it.part.Parent then
			table.remove(items, i)
			return it.part
		end
	end
	return nil
end

-- o: cf (неподвижный) или pos+vel; gravity, drag, spin (рад/с), orient (по скорости), size0/size1,
-- tr0/tr1/fadeStart, life, color, material, floorY
local function spawn(shape, o)
	local p = acquirePart(shape)
	if not p then
		return nil
	end
	p.Color = o.color
	p.Material = o.material or NEON
	p.Size = o.size0
	p.Transparency = o.tr0 or 0
	local it = {
		part = p, shape = shape, t = 0, life = math.max(0.02, o.life), pos = o.pos, vel = o.vel,
		gravity = o.gravity or 0, drag = o.drag or 0, rot = o.rot or CFrame.identity, spin = o.spin,
		orient = o.orient, size0 = o.size0, size1 = o.size1, tr0 = o.tr0 or 0, tr1 = o.tr1 or 1,
		fadeStart = o.fadeStart or 0, floorY = o.floorY, cf = o.cf,
	}
	if it.cf then
		p.CFrame = it.cf
	else
		p.CFrame = CFrame.new(it.pos) * it.rot
	end
	table.insert(items, it)
	return it
end

-- CFrame.lookAt без вырождения при строго вертикальном направлении
local function lookAt(a, b)
	local dir = b - a
	if math.abs(dir.X) + math.abs(dir.Z) < 1e-3 then
		return CFrame.lookAt(a, b, Vector3.xAxis)
	end
	return CFrame.lookAt(a, b)
end

local function updateItems(dt)
	local n = 0
	local i = 1
	while i <= #items do
		local it = items[i]
		it.t = it.t + dt
		local a = it.t / it.life
		local p = it.part
		if a >= 1 or not p.Parent then
			if p.Parent then
				p.Transparency = 1
				p.CFrame = PARK
				table.insert(partPools[it.shape], p)
			else
				poolCount[it.shape] = poolCount[it.shape] - 1
			end
			items[i] = items[#items]
			items[#items] = nil
		else
			if it.vel then
				local v = it.vel
				if it.drag > 0 then
					v = v * math.max(0, 1 - it.drag * dt)
				end
				v = v + Vector3.new(0, -it.gravity * dt, 0)
				local pos = it.pos + v * dt
				if it.floorY and pos.Y < it.floorY then
					pos = Vector3.new(pos.X, it.floorY, pos.Z)
					v = Vector3.new(v.X * 0.45, math.abs(v.Y) * 0.25, v.Z * 0.45)
					if v.Magnitude < 1.5 then
						v = Vector3.zero
						it.spin = nil
					end
				end
				it.pos = pos
				it.vel = v
				local cf
				if it.orient and v.Magnitude > 0.5 then
					cf = lookAt(pos, pos + v)
				else
					if it.spin then
						it.rot = it.rot * CFrame.Angles(it.spin.X * dt, it.spin.Y * dt, it.spin.Z * dt)
					end
					cf = CFrame.new(pos) * it.rot
				end
				n = n + 1
				moveParts[n] = p
				moveCFs[n] = cf
			end
			if it.size1 then
				p.Size = it.size0:Lerp(it.size1, easeOut(a))
			end
			local fa = a <= it.fadeStart and 0 or (a - it.fadeStart) / (1 - it.fadeStart)
			p.Transparency = it.tr0 + (it.tr1 - it.tr0) * fa
			i = i + 1
		end
	end
	for k = n + 1, lastMoveN do
		moveParts[k] = nil
		moveCFs[k] = nil
	end
	lastMoveN = n
	if n > 0 then
		workspace:BulkMoveTo(moveParts, moveCFs, Enum.BulkMoveMode.FireCFrameChanged)
	end
end

-- Пул вспышек света
local lightPool, activeLights = {}, {}

local function initLights()
	for i = 1, 10 do
		local att = Instance.new("Attachment")
		att.Name = "LR_FxLight"
		att.Parent = workspace.Terrain
		local l = Instance.new("PointLight")
		l.Shadows = false
		l.Enabled = false
		l.Parent = att
		lightPool[i] = { att = att, light = l, t = 0, life = 0.1, b = 1 }
	end
end

local function flashLight(pos, color, range, brightness, life)
	local e = table.remove(lightPool)
	if not e then
		e = table.remove(activeLights, 1)
		if not e then
			return
		end
	end
	if not e.att.Parent then
		return
	end
	e.att.WorldPosition = pos
	e.light.Color = color
	e.light.Range = math.min(range, 60)
	e.light.Brightness = brightness
	e.light.Enabled = true
	e.b = brightness
	e.t = 0
	e.life = life
	table.insert(activeLights, e)
end

local function updateLights(dt)
	for i = #activeLights, 1, -1 do
		local e = activeLights[i]
		e.t = e.t + dt
		if e.t >= e.life then
			e.light.Enabled = false
			table.remove(activeLights, i)
			table.insert(lightPool, e)
		else
			e.light.Brightness = e.b * (1 - e.t / e.life)
		end
	end
end

-- Высота пола под точкой (для отскока частиц)
local floorParams = RaycastParams.new()
floorParams.FilterType = Enum.RaycastFilterType.Exclude
floorParams.IgnoreWater = true
local floorFilterAt = -10

local function floorY(pos)
	local now = os.clock()
	if now - floorFilterAt > 1 then
		floorFilterAt = now
		local list = { fx }
		for _, name in ipairs({ "Zombies", "Loot", "Effects" }) do
			local f = workspace:FindFirstChild(name)
			if f then
				table.insert(list, f)
			end
		end
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr.Character then
				table.insert(list, plr.Character)
			end
		end
		floorParams.FilterDescendantsInstances = list
	end
	local r = workspace:Raycast(pos + Vector3.new(0, 1.5, 0), Vector3.new(0, -16, 0), floorParams)
	return r and (r.Position.Y + 0.06) or (pos.Y - 10)
end

local function randomSpin(maxRad)
	return Vector3.new(rng:NextNumber(-maxRad, maxRad), rng:NextNumber(-maxRad, maxRad), rng:NextNumber(-maxRad, maxRad))
end

local function randomDir(normal)
	local v = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-0.2, 1), rng:NextNumber(-1, 1))
	if v.Magnitude < 0.05 then
		v = Vector3.yAxis
	end
	v = v.Unit
	if normal then
		v = (v + normal * 1.1).Unit
	end
	return v
end

local function puff(pos, color, s0, s1, life, tr0, drift)
	spawn("Ball", {
		pos = pos, vel = drift or Vector3.new(0, 1.5, 0), drag = 2.5, color = color, material = SMOOTH,
		size0 = V3n(s0), size1 = V3n(s1), life = life, tr0 = tr0 or 0.45, tr1 = 1,
	})
end

-- Попадания по материалам --------------------------------------------------------------------
local BLOOD = { rgb(92, 10, 12), rgb(120, 16, 18), rgb(70, 8, 10) }
local WOODC = { rgb(122, 88, 52), rgb(150, 112, 70), rgb(96, 68, 42) }
local STONEC = { rgb(118, 116, 110), rgb(150, 146, 138), rgb(92, 90, 86) }
local SPARKC = { rgb(255, 226, 140), rgb(255, 180, 70), rgb(255, 245, 200) }
local GLASSC = { rgb(200, 230, 245), rgb(170, 210, 230), rgb(230, 245, 255) }
local DIRTC = { rgb(92, 72, 50), rgb(110, 88, 62), rgb(76, 60, 42) }

local function impact(pos, kind, normal, heavy, small)
	local mult = heavy and 1.6 or (small and 0.5 or 1)
	local fy = floorY(pos)
	if kind == "flesh" then
		for _ = 1, math.max(2, math.floor(7 * mult + 0.5)) do
			local d = rng:NextNumber(0.14, 0.3)
			spawn("Ball", {
				pos = pos, vel = randomDir(normal) * rng:NextNumber(8, 20) + Vector3.new(0, 5, 0), gravity = 75,
				color = BLOOD[rng:NextInteger(1, 3)], material = SMOOTH, size0 = V3n(d), size1 = V3n(d * 0.6),
				life = rng:NextNumber(0.45, 0.75), tr0 = 0, tr1 = 0.7, fadeStart = 0.6, floorY = fy,
			})
		end
		spawn("Ball", { cf = CFrame.new(pos), color = rgb(105, 14, 16), material = SMOOTH, size0 = V3n(0.6), size1 = V3n(2.2 * mult), life = 0.28, tr0 = 0.35, tr1 = 1 })
	elseif kind == "wood" then
		for _ = 1, math.max(2, math.floor(7 * mult + 0.5)) do
			spawn("Block", {
				pos = pos, vel = randomDir(normal) * rng:NextNumber(12, 26) + Vector3.new(0, 6, 0), gravity = 80,
				spin = randomSpin(12), rot = CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), 0),
				color = WOODC[rng:NextInteger(1, 3)], material = Enum.Material.WoodPlanks,
				size0 = Vector3.new(rng:NextNumber(0.07, 0.12), rng:NextNumber(0.07, 0.1), rng:NextNumber(0.3, 0.6)),
				life = rng:NextNumber(0.6, 0.9), tr0 = 0, tr1 = 1, fadeStart = 0.7, floorY = fy,
			})
		end
		puff(pos, rgb(150, 130, 100), 0.8, 2.6 * mult, 0.4)
	elseif kind == "metal" then
		for _ = 1, math.max(3, math.floor(10 * mult + 0.5)) do
			local len = rng:NextNumber(0.35, 0.6)
			spawn("Block", {
				pos = pos, vel = randomDir(normal) * rng:NextNumber(25, 45), gravity = 60, orient = true,
				color = SPARKC[rng:NextInteger(1, 3)], material = NEON,
				size0 = Vector3.new(0.05, 0.05, len), size1 = Vector3.new(0.03, 0.03, len * 0.4),
				life = rng:NextNumber(0.18, 0.35), tr0 = 0, tr1 = 0.6, fadeStart = 0.3, floorY = fy,
			})
		end
		spawn("Ball", { cf = CFrame.new(pos), color = rgb(255, 236, 170), material = NEON, size0 = V3n(0.4), size1 = V3n(1.3 * mult), life = 0.08, tr0 = 0.1, tr1 = 1 })
		flashLight(pos, rgb(255, 200, 120), 10, 3, 0.1)
	elseif kind == "glass" then
		-- осколки стекла и короткий блик
		for _ = 1, math.max(3, math.floor(8 * mult + 0.5)) do
			spawn("Block", {
				pos = pos, vel = randomDir(normal) * rng:NextNumber(10, 24) + Vector3.new(0, 4, 0), gravity = 80,
				spin = randomSpin(14), rot = CFrame.Angles(rng:NextNumber(0, 6.28), rng:NextNumber(0, 6.28), 0),
				color = GLASSC[rng:NextInteger(1, 3)], material = Enum.Material.Glass,
				size0 = Vector3.new(rng:NextNumber(0.08, 0.22), rng:NextNumber(0.02, 0.04), rng:NextNumber(0.08, 0.2)),
				life = rng:NextNumber(0.5, 0.8), tr0 = 0.25, tr1 = 1, fadeStart = 0.6, floorY = fy,
			})
		end
		spawn("Ball", { cf = CFrame.new(pos), color = rgb(220, 240, 255), material = NEON, size0 = V3n(0.3), size1 = V3n(1.1 * mult), life = 0.07, tr0 = 0.3, tr1 = 1 })
	elseif kind == "dirt" then
		-- комья земли и облачко пыли
		for _ = 1, math.max(2, math.floor(6 * mult + 0.5)) do
			spawn("Ball", {
				pos = pos, vel = randomDir(normal) * rng:NextNumber(8, 18) + Vector3.new(0, 6, 0), gravity = 70,
				color = DIRTC[rng:NextInteger(1, 3)], material = SMOOTH, size0 = V3n(rng:NextNumber(0.12, 0.26)),
				life = rng:NextNumber(0.4, 0.7), tr0 = 0, tr1 = 1, fadeStart = 0.6, floorY = fy,
			})
		end
		puff(pos, rgb(120, 100, 76), 1, 3.2 * mult, 0.6, 0.4, Vector3.new(rng:NextNumber(-1, 1), 1.5, rng:NextNumber(-1, 1)))
	else
		for _ = 1, math.max(2, math.floor(6 * mult + 0.5)) do
			spawn("Block", {
				pos = pos, vel = randomDir(normal) * rng:NextNumber(10, 22) + Vector3.new(0, 4, 0), gravity = 85,
				spin = randomSpin(10), color = STONEC[rng:NextInteger(1, 3)], material = Enum.Material.Slate,
				size0 = V3n(rng:NextNumber(0.14, 0.3)), life = rng:NextNumber(0.5, 0.8), tr0 = 0, tr1 = 1, fadeStart = 0.7, floorY = fy,
			})
		end
		puff(pos, rgb(155, 150, 140), 1, 3.4 * mult, 0.55, 0.45, Vector3.new(rng:NextNumber(-1, 1), 2, rng:NextNumber(-1, 1)))
		if heavy then
			puff(pos, rgb(140, 135, 125), 1.4, 4.5, 0.7, 0.5, Vector3.new(rng:NextNumber(-2, 2), 1, rng:NextNumber(-2, 2)))
		end
	end
end

local IMPACT_SOUND = {
	flesh = "hit_flesh", wood = "hit_wood", metal = "hit_metal", stone = "hit_stone", glass = "hit_glass", dirt = "hit_dirt",
	bus = "hit_bus",
}
-- Стрела или болт: звук по виду поверхности (металл, стекло и автобус — обычный удар)
local ARROW_SOUND = {
	flesh = "arrow_hit_flesh", wood = "arrow_hit_wood", dirt = "arrow_hit_ground", stone = "arrow_hit_ground",
	metal = "hit_metal", glass = "hit_glass", bus = "hit_bus",
}

-- info: {pos, kind ("flesh"|"wood"|"metal"|"stone"|"glass"|"dirt"|"bus"|"air"), weaponId, attacker,
-- hits = {{pos, kind, normal}}, heavy, dir, normal, gun, projectile, pierce, silent}
-- Звук попадания — ровно один на событие (по главному попаданию). silent — только частицы;
-- projectile — звук даёт конец полёта снаряда (EndProjectile), кроме пробития насквозь (pierce).
function Effects.HitFx(info)
	if type(info) ~= "table" or typeof(info.pos) ~= "Vector3" then
		return
	end
	local kind = info.kind
	if not IMPACT_SOUND[kind] then
		return -- промах: только свист замаха (его играют руки от первого лица и CharAnimator)
	end
	local wdef = Weapons.List[info.weaponId]
	local gun = info.gun == true
	local heavy = info.heavy == true and not gun
	local dir = typeof(info.dir) == "Vector3" and info.dir.Magnitude > 0.01 and info.dir.Unit or nil
	local attacker = typeof(info.attacker) == "Instance" and info.attacker:IsA("Player") and info.attacker or nil
	local attackerChar = attacker and attacker.Character
	local attackerRoot = attackerChar and attackerChar:FindFirstChild("HumanoidRootPart")
	local count = 0
	local function one(h)
		if type(h) ~= "table" or typeof(h.pos) ~= "Vector3" or not IMPACT_SOUND[h.kind] then
			return
		end
		local normal = (typeof(h.normal) == "Vector3" and h.normal.Magnitude > 0.01) and h.normal.Unit or nil
		if not normal then
			if dir then
				normal = -dir
			elseif attackerRoot and (attackerRoot.Position - h.pos).Magnitude > 0.1 then
				normal = (attackerRoot.Position - h.pos).Unit
			else
				normal = Vector3.yAxis
			end
		end
		impact(h.pos, h.kind == "bus" and "metal" or h.kind, normal, heavy, gun)
		if h.kind == "flesh" and C and C.ZombieAnim then
			C.ZombieAnim.OnHit(h.pos, heavy, dir)
		end
		count = count + 1
	end
	local hits = type(info.hits) == "table" and info.hits or nil
	if hits and #hits > 0 then
		for i = 1, math.min(#hits, 8) do
			one(hits[i])
		end
	else
		one(info)
	end
	if count == 0 or info.silent == true then
		return
	end
	if info.projectile then
		-- обычный конец полёта озвучивает EndProjectile; здесь — только пробитие насквозь
		if info.pierce then
			sfx(ARROW_SOUND[kind] or "arrow_hit_flesh", info.pos)
		end
	else
		local pitch, volume = 1, 1
		if gun then
			volume = 0.55
		elseif wdef then
			if wdef.heavy then
				pitch = 0.9
			elseif (wdef.cooldown or 1) < 0.5 then
				pitch = 1.06
			end
			volume = heavy and 1.15 or 1
		end
		sfx(IMPACT_SOUND[kind], info.pos, (pitch ~= 1 or volume ~= 1) and { pitch = pitch, volume = volume } or nil)
	end
	-- короткий hit-stop у чужого атакующего
	if attacker and attacker ~= player and attackerChar and not gun and not info.projectile and C and C.CharAnimator then
		C.CharAnimator.HitStop(attackerChar, heavy and 0.08 or 0.05)
	end
end

-- Цифры урона (пул BillboardGui) ----------------------------------------------------------
local numPool, activeNums = {}, {}

local function acquireNumber()
	local e = table.remove(numPool)
	if e and e.att.Parent then
		return e
	end
	if #activeNums >= 40 then
		return table.remove(activeNums, 1)
	end
	local att = Instance.new("Attachment")
	att.Name = "LR_DamageNumber"
	att.Parent = workspace.Terrain
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(260, 64)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = 260
	gui.Adornee = att
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.Parent = gui
	gui.Parent = att
	return { att = att, gui = gui, label = label, t = 0 }
end

function Effects.DamageNumber(position, amount, kind, mine)
	if typeof(position) ~= "Vector3" or type(amount) ~= "number" or amount ~= amount then
		return
	end
	if kind == "player" then
		-- звук боли — только при уроне самому игроку (не от тряски автобуса)
		Effects.Play("hurt")
	end
	if amount < 0.5 then
		return
	end
	local style = STYLES[kind] or STYLES.normal
	local e = acquireNumber()
	e.att.WorldPosition = position + Vector3.new(rng:NextNumber(-1.2, 1.2), rng:NextNumber(0, 1), rng:NextNumber(-1.2, 1.2))
	local label = e.label
	label.TextColor3 = style.color
	label.TextStrokeColor3 = kind == "elite" and rgb(40, 0, 60) or Color3.new(0, 0, 0)
	label.TextTransparency = 0
	label.TextStrokeTransparency = 0.15
	e.size = style.size * ((mine or style.big) and 1 or 0.72)
	label.TextSize = e.size * 1.7
	label.Text = (style.prefix or "") .. tostring(math.floor(amount + 0.5)) .. (style.suffix or "")
	e.offset = Vector3.new(rng:NextNumber(-1, 1), kind == "elite" and 4.5 or 3.5, 0)
	e.gui.StudsOffset = Vector3.zero
	e.gui.Enabled = true
	e.t = 0
	table.insert(activeNums, e)
end

local function updateNumbers(dt)
	for i = #activeNums, 1, -1 do
		local e = activeNums[i]
		e.t = e.t + dt
		local t = e.t
		if t >= 1 or not e.att.Parent then
			e.gui.Enabled = false
			table.remove(activeNums, i)
			if e.att.Parent then
				table.insert(numPool, e)
			end
		else
			local label = e.label
			label.TextSize = t < 0.18 and (e.size * 1.7 + (e.size - e.size * 1.7) * easeOut(t / 0.18)) or e.size
			e.gui.StudsOffset = e.offset * easeOut(math.min(1, t))
			if t > 0.55 then
				local a = (t - 0.55) / 0.45
				label.TextTransparency = a
				label.TextStrokeTransparency = 0.15 + 0.85 * a
			end
		end
	end
end

-- Трассеры, вспышки, гильзы -------------------------------------------------------------------
local TRACERS = {
	default = { color = rgb(255, 230, 150), width = 0.08, flash = rgb(255, 200, 90), sound = "pistol_shot" },
	pistol = { color = rgb(255, 230, 150), width = 0.08, flash = rgb(255, 200, 90), sound = "pistol_shot" },
	revolver = { color = rgb(255, 230, 150), width = 0.08, flash = rgb(255, 200, 90), sound = "revolver_shot" },
	shotgun = { color = rgb(255, 225, 150), width = 0.06, flash = rgb(255, 190, 80), sound = "shotgun_shot", big = true },
	rifle = { color = rgb(255, 230, 150), width = 0.08, flash = rgb(255, 200, 90), sound = "rifle_shot" },
	sniper = { color = rgb(255, 235, 170), width = 0.16, flash = rgb(255, 210, 110), sound = "sniper_shot", big = true },
	turret = { color = rgb(255, 120, 80), width = 0.1, flash = rgb(255, 160, 90), sound = "rifle_shot", pitch = 1.15, volume = 0.55, spark = true },
	mg_turret = { color = rgb(255, 215, 50), width = 0.12, flash = rgb(255, 220, 80), sound = "mg", noLight = true, spark = true },
	raider = { color = rgb(255, 55, 45), width = 0.12, flash = rgb(255, 80, 60), sound = "rifle_shot", pitch = 0.9, spark = true },
}

local TESLA_CORE = rgb(235, 250, 255)
local TESLA_GLOW = rgb(90, 190, 255)
local BRASS = rgb(200, 160, 70)

-- Отрезок-луч между двумя точками (из пула)
local function beam(a, b, width, color, transparency, fadeTime)
	local dist = (b - a).Magnitude
	if dist < 0.05 then
		return
	end
	spawn("Block", {
		cf = lookAt(a, b) * CFrame.new(0, 0, -dist / 2), size0 = Vector3.new(width, width, dist),
		color = color, material = NEON, life = fadeTime, tr0 = transparency or 0, tr1 = 1,
	})
end

local function light(parent, color, range, brightness)
	local l = Instance.new("PointLight")
	l.Color = color
	l.Range = math.min(range, 60)
	l.Brightness = brightness
	l.Shadows = false
	l.Parent = parent
	return l
end

-- s — масштаб (вспышка у рук от первого лица меньше, чтобы не закрывать экран)
local function muzzleFlash(from, dir, color, big, noLight, s)
	s = s or 1
	spawn("Ball", { cf = CFrame.new(from), size0 = V3n((big and 1 or 0.55) * s), size1 = V3n((big and 1.6 or 0.9) * s), color = color, material = NEON, life = 0.06, tr0 = 0.05, tr1 = 1 })
	if dir then
		spawn("Block", {
			cf = lookAt(from, from + dir) * CFrame.new(0, 0, -(big and 0.9 or 0.5) * s),
			size0 = Vector3.new(0.25, 0.25, big and 1.8 or 1) * s, size1 = Vector3.new(0.08, 0.08, big and 2.3 or 1.3) * s,
			color = rgb(255, 240, 190), material = NEON, life = 0.05, tr0 = 0.1, tr1 = 1,
		})
		puff(from + dir * 0.3 * s, rgb(120, 118, 112), 0.35 * s, (big and 2.2 or 1.2) * s, 0.5, 0.6, dir * 3 * s + Vector3.new(0, 1.5 * s, 0))
	end
	if not noLight then
		flashLight(from, color, big and 18 or 12, big and 4 or 2.5, 0.07)
	end
end

-- opts: {color, size (Vector3), side, up} — гильза пистолета, длинный патрон винтовки или красный
-- патрон дробовика
local function ejectCasing(pos, dir, s, opts)
	s = s or 1
	local right = dir:Cross(Vector3.yAxis)
	right = right.Magnitude > 0.01 and right.Unit or Vector3.xAxis
	local side = (opts and tonumber(opts.side)) or rng:NextNumber(7, 11)
	local up = (opts and tonumber(opts.up)) or rng:NextNumber(5, 8)
	spawn("Cylinder", {
		pos = pos, vel = (right * side + Vector3.new(0, up, 0) - dir * 1.5) * math.max(0.5, s),
		gravity = 70, spin = randomSpin(20), color = (opts and opts.color) or BRASS, material = Enum.Material.Metal,
		size0 = ((opts and opts.size) or Vector3.new(0.22, 0.08, 0.08)) * s, life = 1.1, tr0 = 0, tr1 = 1,
		fadeStart = 0.75, floorY = floorY(pos),
	})
end

-- Выброс гильзы из точки (руки от первого лица зовут в кадре анимации: выстрел, перезарядка барабана)
function Effects.EjectCasing(position, dir, scale, opts)
	if typeof(position) ~= "Vector3" then
		return
	end
	local d = (typeof(dir) == "Vector3" and dir.Magnitude > 0.01) and dir.Unit or Vector3.new(0, 0, -1)
	ejectCasing(position, d, type(scale) == "number" and scale or 1, type(opts) == "table" and opts or nil)
end

-- Ломаная молния от a к b
local function zigzag(a, b, jitter, width, color, fadeTime)
	local dir = b - a
	local len = dir.Magnitude
	if len < 0.3 then
		return
	end
	local frame = lookAt(a, b)
	local right, up = frame.RightVector, frame.UpVector
	local n = math.clamp(math.floor(len / 3.5), 3, 12)
	local prev = a
	for i = 1, n do
		local p
		if i == n then
			p = b
		else
			local off = jitter * math.sin(i / n * math.pi) + jitter * 0.3
			p = a + dir * (i / n) + right * rng:NextNumber(-off, off) + up * rng:NextNumber(-off, off)
		end
		beam(prev, p, width, color, 0, fadeTime)
		prev = p
	end
end

local function teslaTracer(from, ends)
	local prev = from
	for _, e in ipairs(ends) do
		if typeof(e) == "Vector3" then
			zigzag(prev, e, 1.6, 0.22, TESLA_CORE, 0.28)
			zigzag(prev, e, 2.4, 0.1, TESLA_GLOW, 0.2)
			spawn("Ball", { cf = CFrame.new(e), size0 = V3n(1.2), size1 = V3n(3.5), color = TESLA_GLOW, material = NEON, life = 0.3, tr0 = 0.1, tr1 = 1 })
			prev = e
		end
	end
	spawn("Ball", { cf = CFrame.new(from), size0 = V3n(2), size1 = V3n(4), color = TESLA_CORE, material = NEON, life = 0.25, tr0 = 0.1, tr1 = 1 })
	flashLight(from, TESLA_GLOW, 30, 6, 0.25)
	Effects.Play("zap", from)
end

-- opts (необязательно, свой выстрел): {fp = true — дуло у рук от первого лица, scale — масштаб вспышки/гильзы}
function Effects.Tracer(from, ends, weaponId, opts)
	if typeof(from) ~= "Vector3" or type(ends) ~= "table" then
		return
	end
	local fp = type(opts) == "table" and opts.fp == true
	local fxScale = fp and (type(opts.scale) == "number" and opts.scale or 0.4) or 1
	if weaponId == "tesla" then
		teslaTracer(from, ends)
		return
	end
	local style = TRACERS[weaponId] or TRACERS.default
	local firstDir
	for i, e in ipairs(ends) do
		if i > 12 then
			break
		end
		if typeof(e) == "Vector3" and (e - from).Magnitude > 0.5 then
			local dir = (e - from).Unit
			firstDir = firstDir or dir
			local dist = (e - from).Magnitude
			-- бледный след по всей длине и яркий бегущий трассер
			beam(from, e, style.width * 0.6, style.color, 0.65, 0.07)
			local speed = 700
			spawn("Block", {
				pos = from + dir * 1.5 * fxScale, vel = dir * speed, orient = true, color = style.color, material = NEON,
				size0 = Vector3.new(style.width, style.width, math.min(dist, 7)), life = math.max(0.03, dist / speed), tr0 = 0, tr1 = 0.3,
			})
			if style.spark then
				spawn("Ball", { cf = CFrame.new(e), size0 = V3n(0.5), size1 = V3n(1.4), color = style.flash, material = NEON, life = 0.15, tr0 = 0, tr1 = 1 })
			end
		end
	end
	muzzleFlash(from, firstDir, style.flash, style.big, style.noLight, fxScale)
	local wdef = Weapons.List[weaponId]
	local o = type(opts) == "table" and opts or nil
	-- гильза: у себя — из окна выброса модели в руках (casingAt), у затворных — позже, при перезарядке
	if wdef and wdef.casing and firstDir and not (o and o.noCasing) then
		local at = o and typeof(o.casingAt) == "Vector3" and o.casingAt or nil
		if not at then
			local s = WeaponModels.Specs[weaponId]
			local back = (s and s.muzzle and s.casing) and (s.casing.Z - s.muzzle.Z) or 3
			at = from - firstDir * back * fxScale + Vector3.new(0, 0.05 * fxScale, 0)
		end
		ejectCasing(at, firstDir, fxScale)
	end
	-- свой выстрел озвучивают руки в кадре анимации (opts.silent), выстрелы других — здесь
	if not (o and o.silent) then
		Effects.Play(style.sound, from, style.pitch, style.volume)
	end
end

-- Снаряды -------------------------------------------------------------------------------
local projPool = {}
local POOLABLE = { bullet = true, arrow = true, bolt = true, acid = true }

local function fallbackProjectile(kind)
	local model = Instance.new("Model")
	model.Name = "Projectile_" .. tostring(kind)
	local color = kind == "bullet" and rgb(255, 220, 80) or kind == "shell" and rgb(40, 40, 44) or rgb(120, 230, 60)
	local size = kind == "shell" and 1.4 or kind == "bullet" and 0.35 or 0.9
	local root = Instance.new("Part")
	root.Shape = BALL
	root.Anchored = true
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.CastShadow = false
	root.Size = V3n(size)
	root.Color = color
	root.Material = kind == "shell" and SMOOTH or NEON
	root.Parent = model
	model.PrimaryPart = root
	return model
end

local function acquireProjectile(kind)
	local list = projPool[kind]
	local m = list and table.remove(list)
	if m then
		return m
	end
	local ok, model = pcall(WeaponModels.MakeProjectile, kind)
	if not ok or typeof(model) ~= "Instance" then
		model = fallbackProjectile(kind)
	end
	return model
end

local function releaseProjectile(kind, model)
	if POOLABLE[kind] and model.PrimaryPart then
		local list = projPool[kind]
		if not list then
			list = {}
			projPool[kind] = list
		end
		if #list < 24 then
			model.Parent = nil
			table.insert(list, model)
			return
		end
	end
	model:Destroy()
end

-- Торчащие стрелы и болты: на сколько уходит в поверхность, сколько остаются, за сколько тают
local STUCK_DEPTH = { arrow = 1.15, bolt = 0.8 }
local STUCK_TIME = 10
local STUCK_FADE = 0.7
local DEBRIS_GRAVITY = 110
local stuckList = {}
local debrisList = {}

local function cfChanged(a, b)
	return b == nil or (a.Position - b.Position).Magnitude > 1e-3 or a.LookVector:Dot(b.LookVector) < 0.99999
end

local function setModelFade(model, k)
	for _, part in ipairs(model:GetChildren()) do
		if part:IsA("BasePart") then
			part.LocalTransparencyModifier = k
		end
	end
end

-- ownerUserId — чей это снаряд: свой выстрел уже озвучили руки от первого лица
function Effects.StartProjectile(id, kind, origin, velocity, gravity, ownerUserId)
	if id == nil or typeof(origin) ~= "Vector3" or typeof(velocity) ~= "Vector3" then
		return
	end
	local model = acquireProjectile(kind)
	setModelFade(model, 0)
	local dir = velocity.Magnitude > 0.1 and velocity or Vector3.new(0, 0, -1)
	model:PivotTo(lookAt(origin, origin + dir))
	model.Parent = fx
	local p = { model = model, pos = origin, vel = velocity, gravity = type(gravity) == "number" and gravity or 0, kind = kind, t = 0 }
	projectiles[id] = p
	local mine = type(ownerUserId) == "number" and ownerUserId == player.UserId
	if kind == "arrow" or kind == "bolt" then
		if not mine then
			sfx(kind == "bolt" and "crossbow_shot" or "bow_release", origin)
		end
		-- свист летит вместе со стрелой и обрывается на попадании
		local root = model.PrimaryPart
		if root then
			p.flySound = sfx("arrow_fly", root, kind == "bolt" and { volume = 0.8, pitch = 1.1 } or nil)
		end
	elseif kind == "molotov" then
		if not mine then
			sfx("throw", origin)
		end
	elseif kind == "bullet" then
		muzzleFlash(origin, dir.Unit, rgb(255, 90, 60), false, true)
		Effects.Play("shot_rifle", origin, 0.9, 0.8)
	elseif kind == "shell" then
		puff(origin, rgb(90, 90, 90), 1.5, 5, 0.5, 0.3)
		Effects.Play("thump", origin)
	end
end

-- Стрела осталась в цели: держим её на месте попадания, а если цель движется (зомби, автобус) —
-- едем вместе с деталью
local function stickProjectile(p, position, hitPart)
	local dir = p.vel.Magnitude > 0.1 and p.vel.Unit or Vector3.new(0, -1, 0)
	local center = position - dir * (STUCK_DEPTH[p.kind] or 1)
	local cf = lookAt(center, center + dir)
	p.model:PivotTo(cf)
	local ref = (typeof(hitPart) == "Instance" and hitPart:IsA("BasePart")) and hitPart or nil
	table.insert(stuckList, {
		model = p.model, kind = p.kind, t = 0,
		ref = ref, rel = ref and ref.CFrame:ToObjectSpace(cf) or nil, refCF = ref and ref.CFrame or nil,
	})
end

-- stuck — снаряд воткнулся; kind — вид поверхности, hitPart — деталь (см. server/ProjectileService)
function Effects.EndProjectile(id, position, stuck, normal, kind, hitPart)
	local p = projectiles[id]
	if not p then
		return
	end
	projectiles[id] = nil
	if p.flySound then
		sfxStop(p.flySound, "arrow_fly")
		p.flySound = nil
	end
	if typeof(position) ~= "Vector3" then
		position = nil
	end
	local arrow = p.kind == "arrow" or p.kind == "bolt"
	if arrow and position and (kind ~= nil or stuck) then
		-- единственный звук попадания стрелы: по виду поверхности
		sfx(ARROW_SOUND[kind] or "arrow_hit_ground", position)
	end
	if stuck and position and arrow then
		stickProjectile(p, position, hitPart)
		return
	end
	if position then
		if p.kind == "acid" then
			Effects.Explosion(position, 3, "acid")
		elseif p.kind == "bullet" then
			spawn("Ball", { cf = CFrame.new(position), size0 = V3n(0.4), size1 = V3n(1.3), color = rgb(255, 200, 120), material = NEON, life = 0.15, tr0 = 0, tr1 = 1 })
		end
	end
	releaseProjectile(p.kind, p.model)
end

local function updateStuck(dt)
	for i = #stuckList, 1, -1 do
		local s = stuckList[i]
		if not s.model.Parent then
			table.remove(stuckList, i)
		else
			s.t = s.t + dt
			local ref = s.ref
			if ref and s.rel then
				if ref.Parent then
					local cf = ref.CFrame
					if cfChanged(cf, s.refCF) then
						s.refCF = cf
						s.model:PivotTo(cf * s.rel)
					end
				else
					s.ref = nil -- цель убрали: стрела остаётся на месте
				end
			end
			if s.t >= STUCK_TIME then
				table.remove(stuckList, i)
				setModelFade(s.model, 0)
				releaseProjectile(s.kind, s.model)
			elseif s.t > STUCK_TIME - STUCK_FADE then
				setModelFade(s.model, (s.t - (STUCK_TIME - STUCK_FADE)) / STUCK_FADE)
			end
		end
	end
end

-- Падающая деталь: магазин пистолета/автомата из рук. model — Model (WorldPivot в середине детали),
-- cframe — где появиться, velocity/spin — начальные скорость и вращение.
-- opts: {life = 2.5, fade = 0.6, sound = ключ звука касания земли}
function Effects.Debris(model, cframe, velocity, spin, opts)
	if typeof(model) ~= "Instance" or not model:IsA("Model") or typeof(cframe) ~= "CFrame" then
		return
	end
	opts = type(opts) == "table" and opts or {}
	while #debrisList >= 6 do
		local old = table.remove(debrisList, 1)
		old.model:Destroy()
	end
	for _, d in ipairs(model:GetDescendants()) do
		if d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.CastShadow = false
			d.LocalTransparencyModifier = 0
		end
	end
	model:PivotTo(cframe)
	model.Parent = fx
	floorY(cframe.Position) -- обновляет фильтр лучей (персонажи и эффекты не мешают)
	table.insert(debrisList, {
		model = model, cf = cframe,
		vel = typeof(velocity) == "Vector3" and velocity or Vector3.zero,
		spin = typeof(spin) == "Vector3" and spin or Vector3.zero,
		t = 0, life = tonumber(opts.life) or 2.5, fade = tonumber(opts.fade) or 0.6,
		sound = type(opts.sound) == "string" and opts.sound or nil,
	})
end

local function updateDebris(dt)
	for i = #debrisList, 1, -1 do
		local d = debrisList[i]
		if not d.model.Parent then
			table.remove(debrisList, i)
		elseif d.t >= d.life then
			table.remove(debrisList, i)
			d.model:Destroy()
		else
			d.t = d.t + dt
			local rot = d.cf - d.cf.Position
			if not d.landed then
				local vel = d.vel + Vector3.new(0, -DEBRIS_GRAVITY * dt, 0)
				local move = (d.vel + vel) * 0.5 * dt
				d.vel = vel
				local hit = workspace:Raycast(d.cf.Position, move + Vector3.new(0, -0.1, 0), floorParams)
				if hit then
					d.landed = true
					d.vel = Vector3.zero
					local pos = hit.Position + hit.Normal * 0.06
					d.cf = CFrame.new(pos) * rot
					if d.sound then
						sfx(d.sound, pos)
						d.sound = nil
					end
					local ref = hit.Instance
					if ref and ref:IsA("BasePart") then
						d.ref, d.rel, d.refCF = ref, ref.CFrame:ToObjectSpace(d.cf), ref.CFrame
					end
				else
					d.cf = CFrame.new(d.cf.Position + move) * rot * CFrame.Angles(d.spin.X * dt, d.spin.Y * dt, d.spin.Z * dt)
				end
			elseif d.ref and d.rel then
				if d.ref.Parent then
					local cf = d.ref.CFrame
					if cfChanged(cf, d.refCF) then
						d.refCF = cf
						d.cf = cf * d.rel
					end
				else
					d.ref = nil
				end
			end
			local fadeStart = d.life - d.fade
			if d.t > fadeStart then
				setModelFade(d.model, math.clamp((d.t - fadeStart) / d.fade, 0, 1))
			end
			d.model:PivotTo(d.cf)
		end
	end
end

-- Взрывы и вспышки ----------------------------------------------------------------------
local function fxPart(size, cf, color, material, transparency, shape)
	local p = Instance.new("Part")
	if shape then
		p.Shape = shape
	end
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material or NEON
	p.Transparency = transparency or 0
	p.Parent = fx
	return p
end

local function tween(inst, time, props, style)
	local t = TweenService:Create(inst, TweenInfo.new(time, style or Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

local DISC_ROT = CFrame.Angles(0, 0, math.rad(90))

-- Плоский диск на земле (редкие долгие эффекты)
local function groundDisc(position, diameter, color, material, transparency)
	return fxPart(Vector3.new(0.3, diameter, diameter), CFrame.new(position) * DISC_ROT, color, material, transparency, CYL)
end

local function shakeByDistance(position, radius, strength, duration)
	local c = cam()
	if not c then
		return
	end
	local dist = (c.CFrame.Position - position).Magnitude
	local reach = radius * 5
	if dist < reach then
		Effects.Shake(math.clamp((1 - dist / reach) * strength, 0.15, strength), duration)
	end
end

local function fireball(position, radius, color, time)
	spawn("Ball", { cf = CFrame.new(position), size0 = V3n(2), size1 = V3n(radius * 2), color = color, material = NEON, life = time, tr0 = 0.2, tr1 = 1 })
	flashLight(position, color, radius * 3, 5, time)
end

local function chunks(position, count, color, speed, life)
	local fy = floorY(position)
	for _ = 1, count do
		spawn("Block", {
			pos = position, vel = Vector3.new(rng:NextNumber(-speed, speed), rng:NextNumber(speed * 0.6, speed * 1.6), rng:NextNumber(-speed, speed)),
			gravity = 90, spin = randomSpin(8), color = color, material = SMOOTH, size0 = V3n(0.6),
			life = life, tr0 = 0, tr1 = 1, fadeStart = 0.75, floorY = fy,
		})
	end
end

local function smokePuff(position, radius, color, time)
	spawn("Ball", {
		pos = position + Vector3.new(0, radius * 0.4, 0), vel = Vector3.new(0, radius / time, 0), color = color, material = SMOOTH,
		size0 = V3n(radius), size1 = V3n(radius * 2.6), life = time, tr0 = 0.35, tr1 = 1,
	})
end

local function ring(position, radius, color, material, time, transparency)
	spawn("Cylinder", {
		cf = CFrame.new(position) * DISC_ROT, size0 = Vector3.new(0.3, 2, 2), size1 = Vector3.new(0.3, radius * 2.2, radius * 2.2),
		color = color, material = material or SMOOTH, life = time, tr0 = transparency or 0.3, tr1 = 1,
	})
end

local function telegraph(position, radius, time)
	spawn("Cylinder", {
		cf = CFrame.new(position) * DISC_ROT, size0 = Vector3.new(0.3, radius * 2, radius * 2),
		color = rgb(255, 40, 30), material = NEON, life = time, tr0 = 0.65, tr1 = 0.25,
	})
end

local function airdropSmoke(position)
	local base = fxPart(Vector3.new(1.5, 0.5, 1.5), CFrame.new(position + Vector3.new(0, 0.5, 0)), rgb(255, 60, 50), NEON, 0.2, BALL)
	local flare = light(base, rgb(255, 70, 50), 24, 3)
	local emitter = Instance.new("ParticleEmitter")
	emitter.Texture = SMOKE_TEX
	emitter.Color = ColorSequence.new(rgb(255, 70, 60), rgb(255, 170, 90))
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 2.5), NumberSequenceKeypoint.new(1, 12) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(0.7, 0.45), NumberSequenceKeypoint.new(1, 1) })
	emitter.Lifetime = NumberRange.new(6, 8)
	emitter.Rate = 16
	emitter.Speed = NumberRange.new(9, 13)
	emitter.SpreadAngle = Vector2.new(8, 8)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Acceleration = Vector3.new(1.5, 1, 0)
	emitter.RotSpeed = NumberRange.new(-30, 30)
	emitter.Rotation = NumberRange.new(0, 360)
	emitter.LightInfluence = 0.4
	emitter.Parent = base
	task.delay(20, function()
		if base.Parent then
			emitter.Enabled = false
			flare.Enabled = false
			tween(base, 1, { Transparency = 1 })
		end
	end)
	Debris:AddItem(base, 29)
end

local function lightningStrike(position, radius)
	local top = position + Vector3.new(rng:NextNumber(-12, 12), 140, rng:NextNumber(-12, 12))
	zigzag(top, position, 6, 0.6, TESLA_CORE, 0.35)
	zigzag(top, position, 9, 0.25, TESLA_GLOW, 0.25)
	spawn("Ball", { cf = CFrame.new(position), size0 = V3n(3), size1 = V3n(radius * 1.6), color = TESLA_CORE, material = NEON, life = 0.35, tr0 = 0, tr1 = 1 })
	flashLight(position, TESLA_GLOW, radius * 4, 10, 0.35)
	ring(position, radius, TESLA_GLOW, NEON, 0.4, 0.2)
	local scorch = groundDisc(position + Vector3.new(0, 0.05, 0), radius * 1.2, rgb(25, 25, 30), SMOOTH, 0.2)
	task.delay(3, function()
		if scorch.Parent then
			tween(scorch, 2, { Transparency = 1 })
		end
	end)
	Debris:AddItem(scorch, 5.1)
	Effects.Play("thunder", position, 1.1)
	shakeByDistance(position, radius, 0.6, 0.3)
end

local function meteorImpact(position, radius)
	fireball(position, radius * 1.4, rgb(255, 110, 30), 0.55)
	spawn("Ball", { cf = CFrame.new(position), size0 = V3n(3), size1 = V3n(radius), color = rgb(255, 230, 150), material = NEON, life = 0.3, tr0 = 0, tr1 = 1 })
	ring(position, radius * 1.3, rgb(255, 120, 40), NEON, 0.6, 0.2)
	smokePuff(position, radius, rgb(60, 50, 45), 1.8)
	chunks(position, 12, rgb(70, 50, 40), 40, 2)
	local crater = groundDisc(position + Vector3.new(0, 0.05, 0), radius * 1.3, rgb(35, 25, 20), SMOOTH, 0)
	local ember = Instance.new("Fire")
	ember.Size = math.clamp(radius * 0.6, 3, 10)
	ember.Heat = 8
	ember.Color = rgb(255, 120, 40)
	ember.SecondaryColor = rgb(255, 60, 20)
	ember.Parent = crater
	task.delay(4, function()
		if crater.Parent then
			ember.Enabled = false
			tween(crater, 3, { Transparency = 1 })
		end
	end)
	Debris:AddItem(crater, 7.1)
	Effects.Play("explosion", position, 0.7)
	shakeByDistance(position, radius, 1.2, 0.6)
end

function Effects.Explosion(position, radius, kind)
	if typeof(position) ~= "Vector3" then
		return
	end
	radius = type(radius) == "number" and math.clamp(radius, 0.5, 80) or 6
	if kind == "explosion" or kind == "bloater" or kind == "fire" then
		local color = kind == "bloater" and rgb(140, 220, 60) or rgb(255, 140, 40)
		fireball(position, radius, color, 0.4)
		chunks(position, 8, color:Lerp(rgb(40, 30, 20), 0.5), 30, 1.5)
		if kind == "fire" then
			-- бутылка разбилась и вспыхнула лужа: горение слышно, пока горит огонь
			sfx("molotov_break", position)
			sfx("fire_ignite", position, { delay = 0.05 })
			local loop = sfx("fire_loop", position)
			if loop then
				task.delay(6, sfxStop, loop, "fire_loop")
			end
		else
			Effects.Play("boom", position)
		end
		shakeByDistance(position, radius, 1, 0.4)
	elseif kind == "shell" then
		fireball(position, radius * 1.25, rgb(255, 150, 50), 0.5)
		smokePuff(position, radius * 0.9, rgb(70, 66, 60), 1.4)
		ring(position, radius * 1.2, rgb(120, 110, 95), SMOOTH, 0.5, 0.25)
		chunks(position, 14, rgb(90, 75, 60), 38, 1.8)
		Effects.Play("explosion", position, 0.8)
		shakeByDistance(position, radius, 1.2, 0.5)
	elseif kind == "meteor" then
		meteorImpact(position, radius)
	elseif kind == "lightning" then
		lightningStrike(position, radius)
	elseif kind == "airdrop" then
		airdropSmoke(position)
	elseif kind == "slam" or kind == "crash" then
		ring(position, radius, kind == "slam" and rgb(150, 130, 100) or rgb(170, 170, 170), SMOOTH, 0.45, 0.3)
		if kind == "slam" then
			puff(position + Vector3.new(0, 0.5, 0), rgb(150, 140, 125), 1.5, radius * 0.8, 0.6, 0.4)
			Effects.Play("slam", position)
		else
			Effects.Play("crash", position, 1, 0.6)
		end
		local c = cam()
		if c and (c.CFrame.Position - position).Magnitude < 60 then
			Effects.Shake(kind == "slam" and 0.7 or 0.4, 0.3)
		end
	elseif kind == "telegraph" then
		telegraph(position, radius, 1.1)
	elseif kind == "warning" or kind == "meteor_warn" then
		telegraph(position, radius, 2.2)
	elseif kind == "blood" then
		local fy = floorY(position)
		for _ = 1, 8 do
			spawn("Ball", {
				pos = position, vel = Vector3.new(rng:NextNumber(-12, 12), rng:NextNumber(8, 20), rng:NextNumber(-12, 12)),
				gravity = 80, color = BLOOD[rng:NextInteger(1, 3)], material = SMOOTH, size0 = V3n(0.4),
				life = 0.8, tr0 = 0, tr1 = 1, fadeStart = 0.6, floorY = fy,
			})
		end
	elseif kind == "acid" then
		spawn("Ball", { cf = CFrame.new(position), size0 = V3n(1), size1 = V3n(radius * 2), color = rgb(140, 230, 60), material = NEON, life = 0.3, tr0 = 0.3, tr1 = 1 })
	elseif kind == "poison" then
		local cloud = fxPart(Vector3.new(2, 2, 2), CFrame.new(position), rgb(120, 190, 60), SMOOTH, 0.5, BALL)
		tween(cloud, 0.8, { Size = Vector3.new(radius * 2, radius * 1.2, radius * 2), Transparency = 0.7 })
		task.delay(3, function()
			if cloud.Parent then
				tween(cloud, 1.5, { Transparency = 1 })
			end
		end)
		Debris:AddItem(cloud, 4.6)
	elseif kind == "roar" then
		ring(position, radius, rgb(200, 160, 255), NEON, 0.6, 0.4)
		Effects.Play("zombie_groan", position, 0.6, 1.4)
		local c = cam()
		if c and (c.CFrame.Position - position).Magnitude < radius * 2 then
			Effects.Shake(0.5, 0.4)
		end
	else
		-- неизвестный вид: лёгкое облачко пыли без тряски
		ring(position, radius, rgb(150, 140, 120), SMOOTH, 0.4, 0.4)
	end
end

function Effects.Shake(intensity, duration, knock)
	intensity = type(intensity) == "number" and intensity or 0.3
	duration = type(duration) == "number" and math.max(0.05, duration) or 0.3
	local now = os.clock()
	if now > shakeUntil or intensity > shakeAmp * ((shakeUntil - now) / shakeDuration) then
		shakeAmp = math.min(intensity, 2)
		shakeDuration = duration
		shakeUntil = now + duration
	end
	if typeof(knock) == "Vector3" then
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root then
			root.AssemblyLinearVelocity = root.AssemblyLinearVelocity + knock
		end
	end
end

-- Отдача прицела (затухающий подъём камеры)
function Effects.Kick(amount)
	if type(amount) ~= "number" then
		return
	end
	kick = math.clamp(kick + amount, 0, 12)
end

-- Толчок камеры при попадании (градусы; быстро затухает)
function Effects.Punch(pitch, yaw, roll)
	punchP = math.clamp(punchP + (type(pitch) == "number" and pitch or 0), -8, 8)
	punchY = math.clamp(punchY + (type(yaw) == "number" and yaw or 0), -8, 8)
	punchR = math.clamp(punchR + (type(roll) == "number" and roll or 0), -8, 8)
end

-- Погода -----------------------------------------------------------------------------------
local weatherPart, emitter, currentWeather

local WEATHER = {
	dust = { rate = 25, color = rgb(220, 180, 120), size = 2.5, speed = 25, life = 3, transparency = 0.8, dir = Enum.NormalId.Right, texture = SMOKE_TEX },
	sandstorm = { rate = 260, color = rgb(210, 160, 100), size = 5, speed = 60, life = 2, transparency = 0.6, dir = Enum.NormalId.Right, texture = SMOKE_TEX },
	rain = { rate = 400, color = rgb(170, 200, 230), size = 0.15, speed = 90, life = 0.8, transparency = 0.3, dir = Enum.NormalId.Bottom },
	snow = { rate = 180, color = rgb(255, 255, 255), size = 0.35, speed = 7, life = 7, transparency = 0.1, dir = Enum.NormalId.Bottom },
	fog = { rate = 12, color = rgb(190, 200, 190), size = 14, speed = 2, life = 8, transparency = 0.9, dir = Enum.NormalId.Right, texture = SMOKE_TEX },
	ash = { rate = 90, color = rgb(80, 76, 72), size = 0.4, speed = 5, life = 6, transparency = 0.2, dir = Enum.NormalId.Bottom },
}

local function setWeather(id)
	if id == currentWeather then
		return
	end
	currentWeather = id
	local w = WEATHER[id]
	if not w then
		emitter.Enabled = false
		return
	end
	emitter.Enabled = true
	emitter.Rate = w.rate
	emitter.Color = ColorSequence.new(w.color)
	emitter.Size = NumberSequence.new(w.size)
	emitter.Speed = NumberRange.new(w.speed * 0.8, w.speed * 1.2)
	emitter.Lifetime = NumberRange.new(w.life * 0.8, w.life)
	emitter.Transparency = NumberSequence.new(w.transparency)
	emitter.EmissionDirection = w.dir
	emitter.Texture = w.texture or "rbxasset://textures/particles/sparkles_main.dds"
	emitter.LightEmission = 0
	emitter.SpreadAngle = Vector2.new(15, 15)
end

local weatherAcc = 0
local stateFolder
local function updateWeather(dt)
	local c = cam()
	if c and weatherPart then
		weatherPart.CFrame = CFrame.new(c.CFrame.Position + Vector3.new(0, 25, 0))
	end
	weatherAcc = weatherAcc + dt
	if weatherAcc < 0.5 then
		return
	end
	weatherAcc = 0
	stateFolder = stateFolder or ReplicatedStorage:FindFirstChild("GameState")
	if not stateFolder then
		return
	end
	local id
	if stateFolder:GetAttribute("Mode") ~= "lobby" then
		local biome = Biomes.ById[stateFolder:GetAttribute("BiomeId") or ""] or Biomes.AtKm(stateFolder:GetAttribute("Km") or 0)
		id = biome and biome.weather
		if stateFolder:GetAttribute("Weather") == "sandstorm" then
			id = "sandstorm"
		end
	end
	setWeather(id)
end

-- Мировые звуки: двигатель автобуса и эмбиент. Печь (furnace_loop) и прикрепление деталей
-- озвучивает сервер (BusService) прямо на месте — здесь их нет, иначе звук двоится.
local busRoot
local busScanAcc, ambienceAcc = 1, 1
local lastWheels, lastUpgrades
local WIND_BY_BIOME = { desert = 1, city = 0.5, jungle = 0.25, swamp = 0.35, snow = 1, wasteland = 0.85 }
local EERIE_BY_BIOME = { swamp = 0.8, wasteland = 0.6, city = 0.35 }
local ambienceTargets = { ambience_wind = 0, ambience_night = 0, ambience_rain = 0, ambience_eerie = 0 }

local function updateWorldSounds(dt)
	stateFolder = stateFolder or ReplicatedStorage:FindFirstChild("GameState")
	local st = stateFolder
	local lobby = st and st:GetAttribute("Mode") == "lobby"

	busScanAcc = busScanAcc + dt
	if busScanAcc >= 1 then
		busScanAcc = 0
		local m = workspace:FindFirstChild("Bus")
		if m and m:IsA("Model") and not lobby then
			local r = m:FindFirstChild("BusRoot") or m.PrimaryPart
			busRoot = (r and r:IsA("BasePart")) and r or nil
		else
			busRoot = nil
		end
	end

	-- двигатель: громкость и высота от скорости
	if busRoot and busRoot.Parent and st then
		local speed = st:GetAttribute("Speed")
		speed = type(speed) == "number" and speed or 0
		local driver = st:GetAttribute("DriverName")
		local driving = type(driver) == "string" and driver ~= ""
		local k = math.clamp(speed / 60, 0, 1)
		local target = (speed > 0.5 or driving) and (0.45 + 0.55 * k) or 0
		setLoop("bus_engine", target, 0.75 + 0.55 * k, busRoot.Position, { 14, 170 })
	else
		setLoop("bus_engine", 0)
	end

	-- эмбиент (2 Гц)
	ambienceAcc = ambienceAcc + dt
	if ambienceAcc >= 0.5 and st then
		ambienceAcc = 0
		local night = st:GetAttribute("IsNight") == true
		if lobby then
			ambienceTargets.ambience_wind = 0.5
			ambienceTargets.ambience_night = 0.6
			ambienceTargets.ambience_rain = 0
			ambienceTargets.ambience_eerie = 0.45
		else
			local biome = st:GetAttribute("BiomeId")
			biome = type(biome) == "string" and biome or ""
			local wind = WIND_BY_BIOME[biome] or 0.5
			if st:GetAttribute("Weather") == "sandstorm" then
				wind = 1.4
			end
			ambienceTargets.ambience_wind = wind
			ambienceTargets.ambience_rain = currentWeather == "rain" and 1 or 0
			ambienceTargets.ambience_night = (night and biome ~= "snow" and biome ~= "desert") and 0.9 or 0
			ambienceTargets.ambience_eerie = st:GetAttribute("BloodMoon") == true and 1 or ((EERIE_BY_BIOME[biome] or 0) * (night and 1 or 0.6))
		end
	end
	for key, target in pairs(ambienceTargets) do
		setLoop(key, target)
	end
	updateLoops(dt)
end

-- Звуки интерфейса: подбор, покупка/продажа, уровень, детали автобуса ---------------------------
local lastInvTotal, lastWeaponCount, lastMoney
local lastInvChange = { t = -10, sign = 0 }
local lastMoneyChange = { t = -10, sign = 0 }
local lastCashAt = -10

local function tryCash()
	local now = os.clock()
	if now - lastCashAt < 0.5 then
		return true
	end
	if now - lastInvChange.t < 0.8 and now - lastMoneyChange.t < 0.8 and lastInvChange.sign ~= 0 and lastInvChange.sign ~= lastMoneyChange.sign then
		lastCashAt = now
		Effects.Play("cash")
		return true
	end
	return false
end

local function onInventory(inv, order)
	if type(inv) ~= "table" then
		return
	end
	local total = 0
	for _, n in pairs(inv) do
		if type(n) == "number" then
			total = total + n
		end
	end
	local wc = type(order) == "table" and #order or 0
	if lastInvTotal then
		local itemDelta = total - lastInvTotal
		local delta = itemDelta + (wc - lastWeaponCount) * 3
		if delta ~= 0 then
			lastInvChange = { t = os.clock(), sign = delta > 0 and 1 or -1 }
			-- звук подбора играет рука от первого лица по событию PickupFx; здесь — только касса
			tryCash()
		end
	end
	lastInvTotal = total
	lastWeaponCount = wc
end

-- Прикрепление колёс и деталей озвучивает сервер (BusService), здесь только следим за состоянием
local function watchState(st)
	local function track()
		local w = st:GetAttribute("BusWheels")
		lastWheels = type(w) == "number" and w or lastWheels
		local u = st:GetAttribute("Upgrades")
		lastUpgrades = type(u) == "string" and u or lastUpgrades
	end
	st:GetAttributeChangedSignal("BusWheels"):Connect(track)
	st:GetAttributeChangedSignal("Upgrades"):Connect(track)
	track()
end

-- Камера: смещение снимается ДО стандартной камеры и накладывается ПОСЛЕ неё,
-- поэтому отдача и тряска не накапливаются в camera.CFrame.
local appliedOffset, appliedCF, appliedCamera

local function sameCF(a, b)
	return (a.Position - b.Position).Magnitude < 1e-3 and a.LookVector:Dot(b.LookVector) > 0.99999 and a.UpVector:Dot(b.UpVector) > 0.99999
end

local function undoCameraFx()
	local c = cam()
	if appliedOffset and c and c == appliedCamera and sameCF(c.CFrame, appliedCF) then
		c.CFrame = c.CFrame * appliedOffset:Inverse()
	end
	appliedOffset, appliedCF, appliedCamera = nil, nil, nil
end

local function applyCameraFx(dt)
	local c = cam()
	if not c then
		return
	end
	local now = os.clock()
	local offset
	if now < shakeUntil and shakeDuration > 0 then
		local a = shakeAmp * ((shakeUntil - now) / shakeDuration)
		offset = CFrame.Angles(rng:NextNumber(-1, 1) * a * 0.02, rng:NextNumber(-1, 1) * a * 0.02, 0) * CFrame.new(rng:NextNumber(-1, 1) * a * 0.25, rng:NextNumber(-1, 1) * a * 0.25, 0)
	end
	if kick > 0.01 then
		local k = CFrame.Angles(math.rad(kick), 0, 0)
		offset = offset and offset * k or k
		kick = kick * math.exp(-12 * dt)
	else
		kick = 0
	end
	if math.abs(punchP) + math.abs(punchY) + math.abs(punchR) > 0.01 then
		local p = CFrame.Angles(math.rad(punchP), math.rad(punchY), math.rad(punchR))
		offset = offset and offset * p or p
		local decay = math.exp(-16 * dt)
		punchP, punchY, punchR = punchP * decay, punchY * decay, punchR * decay
	else
		punchP, punchY, punchR = 0, 0, 0
	end
	if offset then
		c.CFrame = c.CFrame * offset
		appliedOffset = offset
		appliedCF = c.CFrame
		appliedCamera = c
	end
end

function Effects.Init(c)
	C = c
	fx = Instance.new("Folder")
	fx.Name = "ClientFX"
	fx.Parent = workspace

	initLights()
	-- прогрев пула деталей, чтобы первые попадания не создавали Instance
	for shape, n in pairs({ Block = 80, Ball = 40, Cylinder = 8 }) do
		for _ = 1, n do
			table.insert(partPools[shape], newPoolPart(shape))
		end
	end

	weatherPart = fxPart(Vector3.new(160, 1, 160), CFrame.new(0, 50, 0), rgb(0, 0, 0), SMOOTH, 1)
	emitter = Instance.new("ParticleEmitter")
	emitter.Enabled = false
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.Parent = weatherPart

	Net.Get("DamageNumber").OnClientEvent:Connect(Effects.DamageNumber)
	Net.Get("Tracer").OnClientEvent:Connect(Effects.Tracer)
	Net.Get("Projectile").OnClientEvent:Connect(Effects.StartProjectile)
	Net.Get("ProjectileEnd").OnClientEvent:Connect(Effects.EndProjectile)
	Net.Get("Explosion").OnClientEvent:Connect(Effects.Explosion)
	Net.Get("Shake").OnClientEvent:Connect(function(intensity, duration, knock)
		Effects.Shake(intensity, duration, knock)
	end)
	Net.Get("HitFx").OnClientEvent:Connect(function(info)
		if type(info) ~= "table" then
			return
		end
		-- свои удары: клиент уже показал предсказанное попадание — решает WeaponClient
		if info.attacker == player and C and C.WeaponClient then
			C.WeaponClient.OnServerHit(info)
		else
			Effects.HitFx(info)
		end
	end)
	Net.Get("LevelUp").OnClientEvent:Connect(function()
		Effects.Play("level_up")
	end)
	Net.Get("Inventory").OnClientEvent:Connect(onInventory)
	player:GetAttributeChangedSignal("Money"):Connect(function()
		local m = player:GetAttribute("Money")
		if type(m) ~= "number" then
			return
		end
		if lastMoney and m ~= lastMoney then
			lastMoneyChange = { t = os.clock(), sign = m > lastMoney and 1 or -1 }
			tryCash()
		end
		lastMoney = m
	end)
	lastMoney = player:GetAttribute("Money")

	local watched = false
	RunService.Heartbeat:Connect(function(dt)
		for id, p in pairs(projectiles) do
			p.t = p.t + dt
			local newVel = p.vel + Vector3.new(0, -p.gravity * dt, 0)
			p.pos = p.pos + (p.vel + newVel) * 0.5 * dt
			p.vel = newVel
			if p.t > 6 or not p.model.Parent then
				projectiles[id] = nil
				if p.flySound then
					sfxStop(p.flySound, "arrow_fly")
					p.flySound = nil
				end
				releaseProjectile(p.kind, p.model)
			elseif p.vel.Magnitude > 0.1 then
				p.model:PivotTo(lookAt(p.pos, p.pos + p.vel))
			end
		end
		updateStuck(dt)
		updateDebris(dt)
		updateItems(dt)
		updateLights(dt)
		updateNumbers(dt)
		updateWeather(dt)
		updateWorldSounds(dt)
		if not watched and stateFolder then
			watched = true
			watchState(stateFolder)
		end
	end)

	RunService:BindToRenderStep("LastRunCameraFxUndo", Enum.RenderPriority.Camera.Value - 20, undoCameraFx)
	RunService:BindToRenderStep("LastRunCameraFx", Enum.RenderPriority.Camera.Value + 1, applyCameraFx)
end

return Effects
