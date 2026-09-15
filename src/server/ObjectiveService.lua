-- Цели биомов: выбор мест по сиду, активация рядом с автобусом/игроками, 6 типов целей
-- (сбор, зачистка гнезда, спасение выжившего, охота на элиту, оборона объекта, тайник),
-- награды через профиль и синхронизация клиентам (ObjectivesSync).
-- Контракт API — docs/SPEC_v2.md, раздел 3.4.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Biomes = require(Shared.Biomes)
local ObjectiveDefs = require(Shared.Objectives)
local ZombieDefs = require(Shared.Zombies)
local Progression = require(Shared.Progression)
local Items = require(Shared.Items)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local Obj = {}
local S
local folder
local list = {} -- все цели заезда
local byBiome = {} -- [biomeId] = { id, name, index, need, list }
local runSeed = 1
local placed = false
local wantPlace = false
local runToken = 0
local dirty = true
local syncAcc = 0
local logicAcc = 0
local followAcc = 0
local rng = Random.new()

local OB_CHUNK = "objectives" -- препятствия мест целей не выгружаются с чанками
local ACTIVATE_BUS = 900
local ACTIVATE_PLAYER = 400
local WAKE_PLAYER = 320
local WAKE_BUS = 420
local SLEEP_PLAYER = 700
local SLEEP_BUS = 1000
local RESERVE_RADIUS = 45
local REWARD_MONEY = 60
local RESCUE_RESPAWN = 45
local CACHE_DISTANCE = 150
local DEFEND_RADIUS = 75

local rgb = Color3.fromRGB
local V3 = Vector3.new
local CF = CFrame.new
local M = Enum.Material
local GREEN = rgb(120, 230, 140)
local YELLOW = rgb(255, 215, 90)
local RED = rgb(255, 100, 90)

local TYPE_COLORS = {
	collect = rgb(255, 200, 70),
	clear = rgb(230, 80, 60),
	rescue = rgb(90, 200, 255),
	elite = rgb(190, 110, 255),
	defend = rgb(120, 220, 120),
	cache = rgb(255, 150, 40),
}

-- Помощники ---------------------------------------------------------------------------

local function mk(parent, size, cf, color, material, extra)
	local p = Util.Part({ Size = size, CFrame = cf, Color = color, Material = material or M.SmoothPlastic, Parent = parent })
	p.CollisionGroup = "World"
	if extra then
		for k, v in pairs(extra) do
			if k == "Shape" and type(v) == "string" then
				p.Shape = Enum.PartType[v]
			else
				p[k] = v
			end
		end
	end
	return p
end

local function deco(parent, size, cf, color, material, extra)
	local p = mk(parent, size, cf, color, material, extra)
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	return p
end

local function signText(part, text, color)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 25
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.GothamBlack
	label.TextColor3 = color
	label.Text = text
	label.Parent = gui
	gui.Parent = part
	return gui
end

-- Растяжка/кабель: прямой Beam между точками мира (крепления в детали holder)
local function guyWire(holder, a, b, width, color)
	local a0 = Instance.new("Attachment")
	a0.Position = holder.CFrame:PointToObjectSpace(a)
	a0.Parent = holder
	local a1 = Instance.new("Attachment")
	a1.Position = holder.CFrame:PointToObjectSpace(b)
	a1.Parent = holder
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Width0 = width or 0.07
	beam.Width1 = width or 0.07
	beam.FaceCamera = true
	beam.Color = ColorSequence.new(color or rgb(40, 40, 44))
	beam.Transparency = NumberSequence.new(0)
	beam.Parent = holder
	return beam
end

-- Лампа, которую DayNight включает ночью
local function nightLamp(part)
	part:SetAttribute("NightOffColor", rgb(120, 114, 100))
	part:SetAttribute("NightOffMaterial", "Glass")
	game:GetService("CollectionService"):AddTag(part, "LR_NightLight")
	return part
end

local function addCircle(x, z, r)
	return S.Obstacles.AddCircle(OB_CHUNK, x, z, r, { hard = true, kind = "objective" })
end

local function setText(o, text)
	if o.text ~= text then
		o.text = text
		dirty = true
	end
end

local function setProgress(o, value)
	value = math.clamp(math.floor(value), 0, o.goal)
	if o.progress ~= value then
		o.progress = value
		dirty = true
	end
end

-- Множитель числа зомби: с учётом доли пути (km), иначе — общий множитель
local function countMult(km)
	local m = 1
	if type(km) == "number" and S.Zombies.HordeMult then
		m = S.Zombies.HordeMult(km)
	elseif S.Zombies.CountMult then
		m = S.Zombies.CountMult()
	end
	if type(m) ~= "number" or m <= 0 then
		m = 1
	end
	return m
end

local function scaled(n, km)
	-- v5: охрана целей на четверть меньше (зомби казалось слишком много)
	return math.max(1, math.floor(n * countMult(km) * 0.75 + 0.5))
end

local function busHalfSize()
	local halfX, halfZ = 6, 22
	local def = S.Bus.TypeDef
	if type(def) == "table" then
		if type(def.width) == "number" then
			halfX = def.width / 2
		end
		if type(def.length) == "number" then
			halfZ = def.length / 2
		end
	end
	return halfX, halfZ
end

-- Точка рядом с корпусом автобуса (pad — запас от борта)
local function nearBusHull(pos, pad)
	local root = S.Bus.Root
	if not root then
		return false
	end
	local halfX, halfZ = busHalfSize()
	local lp = root.CFrame:PointToObjectSpace(pos)
	return math.abs(lp.X) < halfX + pad and math.abs(lp.Z) < halfZ + pad and math.abs(lp.Y) < 16
end

-- Свободная точка для спавна: не в препятствии, не в автобусе, внутри границ
local function spawnPoint(center, rMin, rMax, hintS)
	for _ = 1, 8 do
		local a = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(rMin, rMax)
		local p = V3(center.X + math.cos(a) * r, 0, center.Z + math.sin(a) * r)
		local ok = not S.Obstacles.IsBlocked(p.X, p.Z, 3) and not nearBusHull(p, 6)
		if ok and S.World.IsInsideBounds then
			ok = S.World.IsInsideBounds(p, hintS) and true or false
		end
		if ok then
			return p
		end
	end
	return nil
end

-- Живые активные игроки: { {player, pos} }
local function activeRoots()
	local out = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		local root = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
		if root and S.PlayerData.IsAlive(plr) then
			table.insert(out, { player = plr, pos = root.Position })
		end
	end
	return out
end

local function nearestDist(roots, pos)
	local best = math.huge
	for _, r in ipairs(roots) do
		local d = Util.FlatDist(r.pos, pos)
		if d < best then
			best = d
		end
	end
	return best
end

local function eachRunPlayer(fn)
	for _, plr in ipairs(Players:GetPlayers()) do
		if S.PlayerData.Get(plr) then
			fn(plr)
		end
	end
end

-- Выбор мест ---------------------------------------------------------------------------

local function biomeRange(bi)
	local SPK = Config.StudsPerKm
	local biome = Biomes.List[bi]
	local finalS = S.World.FinalS or Config.RouteKm * SPK
	local startS = biome.startKm * SPK
	local nextBiome = Biomes.List[bi + 1]
	local endS = nextBiome and nextBiome.startKm * SPK or finalS
	local stationS, stationIndex = nil, nil
	for i, st in ipairs(Config.Stations) do
		local s = st.km * SPK
		if s >= startS and s < endS then
			stationS, stationIndex = s, i
			break
		end
	end
	local s0 = math.max(startS + 350, Config.DepotLength + 200)
	local s1 = stationS and (stationS - 450) or (finalS - 500)
	if s1 < s0 + 150 then
		s1 = s0 + 150
	end
	return s0, s1, stationIndex
end

-- Тайник примерно в CACHE_DISTANCE от ключа, внутри границ и не на дороге
local function cacheSpot(r, s, d)
	local limit = Config.Bounds.HalfWidth - 40
	local start = r:NextNumber(0, math.pi * 2)
	for k = 0, 11 do
		local a = start + k * math.pi / 6
		local cs = s + math.cos(a) * CACHE_DISTANCE
		local cd = d + math.sin(a) * CACHE_DISTANCE
		if math.abs(cd) <= limit and math.abs(cd) >= Config.RoadHalfWidth + 20 then
			return cs, cd
		end
	end
	return s + CACHE_DISTANCE, d
end

local function zombieName(id)
	local def = ZombieDefs.Types[id]
	return def and def.name or "элитный зомби"
end

local function newObjective(def, biome, k, s, d)
	local id = biome.id .. "_" .. k
	local o = {
		id = id,
		biomeId = biome.id,
		biomeName = biome.name,
		biomeIndex = biome.index,
		def = def,
		type = def.type,
		title = def.title or ObjectiveDefs.TypeNames[def.type] or "Цель",
		s = s,
		d = d,
		pos = S.World.Road:ToWorld(s, d, 0),
		state = "pending",
		progress = 0,
		goal = 1,
		text = "",
		tag = "obj_" .. id,
		token = runToken,
		site = nil,
	}
	local t = def.type
	if t == "collect" then
		local item = Items.List[def.item]
		o.goal = math.max(1, math.floor(def.count or 1))
		o.text = "Соберите: " .. (item and item.name or tostring(def.item)) .. " ×" .. o.goal
	elseif t == "clear" then
		o.text = "Уничтожьте гнездо и его охрану"
	elseif t == "rescue" then
		o.text = "Найдите выжившего и доведите его до автобуса"
	elseif t == "elite" then
		o.text = "Выследите и убейте: " .. zombieName(def.zombie)
	elseif t == "defend" then
		o.goal = math.max(5, math.floor(def.duration or 45))
		o.text = "Почините объект и удерживайте зону " .. o.goal .. " с"
	elseif t == "cache" then
		o.goal = 2
		o.text = "Найдите ключ и откройте тайник"
	end
	return o
end

local KNOWN_TYPES = { collect = true, clear = true, rescue = true, elite = true, defend = true, cache = true }

local function placeAll()
	placed = true
	wantPlace = false
	list = {}
	byBiome = {}
	local road = S.World.Road
	for bi, biome in ipairs(Biomes.List) do
		local info = { id = biome.id, name = biome.name, index = bi, need = 0, list = {} }
		byBiome[biome.id] = info
		local pool = {}
		for _, def in ipairs(ObjectiveDefs.ByBiome[biome.id] or {}) do
			if KNOWN_TYPES[def.type] then
				table.insert(pool, def)
			end
		end
		if #pool > 0 then
			local r = Random.new((runSeed % 1000000) * 131 + bi * 7919)
			for k = #pool, 2, -1 do
				local j = r:NextInteger(1, k)
				pool[k], pool[j] = pool[j], pool[k]
			end
			local n = math.min(Config.Objectives.PerBiome, #pool)
			local s0, s1, stationIndex = biomeRange(bi)
			local seg = (s1 - s0) / n
			local maxD = math.min(Config.Objectives.MaxOffset, Config.Bounds.HalfWidth - 50)
			local minD = math.min(Config.Objectives.MinOffset, maxD)
			for k = 1, n do
				local def = pool[k]
				local s = s0 + seg * (k - 1) + seg * r:NextNumber(0.2, 0.8)
				local side = r:NextNumber() < 0.5 and -1 or 1
				local d = side * r:NextNumber(minD, maxD)
				local o = newObjective(def, biome, k, s, d)
				if S.World.ReserveArea then
					S.World.ReserveArea(s, d, RESERVE_RADIUS)
				end
				if def.type == "cache" then
					local cs, cd = cacheSpot(r, s, d)
					o.cacheS, o.cacheD = cs, cd
					o.cachePos = road:ToWorld(cs, cd, 0)
					if S.World.ReserveArea then
						S.World.ReserveArea(cs, cd, RESERVE_RADIUS)
					end
				end
				table.insert(list, o)
				table.insert(info.list, o)
			end
			info.need = math.min(Config.Objectives.RequiredPerBiome, n)
			info.stationIndex = stationIndex
		end
	end
	dirty = true
end

-- Синхронизация и API ------------------------------------------------------------------

local function biomeDone(info)
	local n = 0
	for _, o in ipairs(info.list) do
		if o.state == "done" then
			n = n + 1
		end
	end
	return n
end

local function objectivePos(o)
	local site = o.site
	if site then
		if o.type == "rescue" and site.root and site.root.Parent then
			return site.root.Position
		end
		if o.type == "cache" and o.progress >= 1 and o.cachePos then
			return o.cachePos
		end
	end
	return o.pos
end

local function serializeList()
	local out = {}
	for i, o in ipairs(list) do
		local info = byBiome[o.biomeId]
		out[i] = {
			id = o.id,
			biomeId = o.biomeId,
			biomeName = o.biomeName,
			type = o.type,
			title = o.title,
			text = o.text,
			progress = o.progress,
			goal = o.goal,
			state = o.state,
			pos = objectivePos(o),
			required = info and info.need or 0, -- сколько целей биома обязательно
		}
	end
	return out
end

local function serialize()
	local biomes = {}
	for id, info in pairs(byBiome) do
		if #info.list > 0 then
			biomes[id] = { done = biomeDone(info), need = info.need, name = info.name }
		end
	end
	local current = Biomes.List[1].id
	if S.World.Road and S.Bus.Root then
		current = S.World.BiomeAtS(S.Bus.S or 0).id
	end
	return { objectives = serializeList(), biomes = biomes, currentBiome = current }
end

local function sendSync(player)
	local payload = serialize()
	local remote = Net.Get("ObjectivesSync")
	if player then
		remote:FireClient(player, payload)
	else
		remote:FireAllClients(payload)
	end
end

local function biomeRequirement(biome)
	local name = biome and biome.name or ""
	local info = biome and byBiome[biome.id]
	if not info or #info.list == 0 then
		return 0, 0, name
	end
	return biomeDone(info), info.need, name
end

-- done, need, biomeName для ворот станции stationIndex
function Obj.StationRequirement(stationIndex)
	local cfg = type(stationIndex) == "number" and Config.Stations[stationIndex]
	if not cfg then
		return 0, 0, ""
	end
	return biomeRequirement(Biomes.AtKm(cfg.km))
end

-- done, need, biomeName для боя с боссом (последний биом)
function Obj.FinalRequirement()
	return biomeRequirement(Biomes.AtKm(Config.RouteKm))
end

function Obj.CountDone()
	local n = 0
	for _, o in ipairs(list) do
		if o.state == "done" then
			n = n + 1
		end
	end
	return n
end

function Obj.GetList()
	return serializeList()
end

-- Зомби мест целей ---------------------------------------------------------------------

local function removeTarget(site)
	if site and site.target then
		if S.Zombies.RemoveTarget then
			S.Zombies.RemoveTarget(site.target)
		end
		site.target = nil
	end
end

local function addTarget(site, entity)
	removeTarget(site)
	site.target = entity
	if S.Zombies.AddTarget then
		S.Zombies.AddTarget(entity)
	end
end

-- role: guard | nest | elite | wave. extra: home, aggro, elite, hpMult, fallback, fallbackHP
local function spawnZombie(o, typeId, pos, role, extra)
	local site = o.site
	extra = extra or {}
	local entry = { role = role }
	local opts = {
		biome = Biomes.List[o.biomeIndex],
		tag = o.tag,
		home = extra.home,
		aggro = extra.aggro == true,
		noDespawn = true,
		elite = extra.elite,
		hpMult = extra.hpMult,
		onDeath = function()
			entry.killed = true
		end,
	}
	local z = S.Zombies.Spawn(typeId, pos, opts)
	if not z and extra.fallback then
		opts.hpMult = extra.fallbackHP
		z = S.Zombies.Spawn(extra.fallback, pos, opts)
	end
	if not z then
		return nil
	end
	entry.z = z
	table.insert(site.zombies, entry)
	return z
end

local function aliveRole(site, role)
	for _, e in ipairs(site.zombies) do
		if e.role == role and not e.z.dead then
			return e.z
		end
	end
	return nil
end

-- Разбор погибших/пропавших зомби места цели
local function processZombies(site)
	for i = #site.zombies, 1, -1 do
		local e = site.zombies[i]
		local z = e.z
		if z.dead then
			table.remove(site.zombies, i)
			local killed = e.killed or (z.humanoid ~= nil and z.humanoid.Health <= 0)
			if e.role == "nest" and killed then
				site.nestKilled = true
				site.nestKilledAt = os.clock()
			elseif e.role == "elite" and killed then
				site.eliteKilled = true
			elseif e.role == "guard" and not killed then
				site.guardsLeft = site.guardsLeft + 1
			end
		elseif z.humanoid then
			-- отметка последнего полученного урона (чтобы место не «уснуло» посреди боя)
			local h = z.humanoid.Health
			if e.lastHp and h < e.lastHp then
				e.hurtAt = os.clock()
			end
			e.lastHp = h
		end
	end
end

-- Все зомби места пропадают (игроки ушли далеко); охрана вернётся при возвращении.
-- Порождённые гнездом миньоны не попадают в site.zombies, но несут tag цели — убираем и их.
local function despawnZombies(o, keepGuards)
	local site = o.site
	for _, e in ipairs(site.zombies) do
		if not e.z.dead then
			if e.role == "guard" and keepGuards then
				site.guardsLeft = site.guardsLeft + 1
			end
			S.Zombies.Remove(e.z)
		end
	end
	site.zombies = {}
	if o.tag then
		local stray = {}
		for _, z in ipairs(S.Zombies.List()) do
			if not z.dead and z.tag == o.tag then
				table.insert(stray, z)
			end
		end
		for _, z in ipairs(stray) do
			S.Zombies.Remove(z)
		end
	end
end

-- Цель выполнена: зомби места становятся обычными (исчезают по расстоянию)
local function releaseZombies(o)
	local site = o.site
	for _, e in ipairs(site.zombies) do
		if not e.z.dead then
			e.z.tag = nil
			e.z.noDespawn = nil
		end
	end
	site.zombies = {}
	if o.tag then
		for _, z in ipairs(S.Zombies.List()) do
			if not z.dead and z.tag == o.tag then
				z.tag = nil
				z.noDespawn = nil
			end
		end
	end
end

-- Выполнение и награды ----------------------------------------------------------------

local function complete(o, note)
	if o.cancelled or o.token ~= runToken or o.state == "done" then
		return
	end
	o.state = "done"
	o.progress = o.goal
	dirty = true
	local site = o.site
	if site then
		removeTarget(site)
		releaseZombies(o)
		site.leader = nil
		if site.lamp then
			site.lamp.Color = GREEN
		end
		if site.light then
			site.light.Color = GREEN
		end
		for _, prompt in ipairs(site.prompts) do
			if prompt.Parent then
				prompt:Destroy()
			end
		end
		site.prompts = {}
	end
	setText(o, note or "Выполнено")
	eachRunPlayer(function(plr)
		S.Profile.AddXP(plr, Progression.XP.objective, "objective")
		S.Profile.AddTickets(plr, Progression.Tickets.objective, "objective")
		S.PlayerData.AddMoney(plr, REWARD_MONEY)
	end)
	local info = byBiome[o.biomeId]
	local done, need = 0, 0
	if info then
		done, need = biomeDone(info), info.need
	end
	local sub = o.title .. ": +$" .. REWARD_MONEY .. ", опыт и билеты каждому. Цели биома: " .. done .. "/" .. need
	if done == need and need > 0 then
		sub = sub .. " — обязательные цели выполнены!"
	end
	Net.Get("Toast"):FireAllClients("ЦЕЛЬ ВЫПОЛНЕНА", sub, GREEN)
end

-- Общая часть места цели: маяк и табличка ----------------------------------------------

local function siteCF(pos, s)
	local roadPos = S.World.Road:ToWorld(s, 0)
	local look = Util.Flat(roadPos - pos)
	if look.Magnitude < 1 then
		return CF(pos)
	end
	-- -Z (лицевая сторона) смотрит на дорогу
	return CFrame.lookAt(pos, pos + look.Unit)
end

local function addPrompt(site, part, action, object, hold, distance)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = action
	prompt.ObjectText = object
	prompt.HoldDuration = hold or 0
	prompt.MaxActivationDistance = distance or 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
	table.insert(site.prompts, prompt)
	return prompt
end

local function playerRootNear(player, pos, maxDist)
	if not S.PlayerData.IsActive(player) then
		return nil
	end
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not root or (root.Position - pos).Magnitude > maxDist then
		return nil
	end
	return root
end

local function newSite(o)
	local model = Instance.new("Model")
	model.Name = "Objective_" .. o.id
	model:SetAttribute("ObjectiveId", o.id)
	model:SetAttribute("ObjectiveType", o.type)
	model.Parent = folder
	local site = {
		model = model,
		cf = siteCF(o.pos, o.s),
		zombies = {},
		loot = {},
		prompts = {},
		guardsLeft = 0,
		awake = false,
		nextSpawnTry = 0,
		r = Random.new((runSeed % 1000000) + o.biomeIndex * 97 + #o.id * 13),
	}
	o.site = site
	local cf = site.cf
	local color = TYPE_COLORS[o.type] or YELLOW

	-- Маяк: мачта с перекладинами и растяжками, колпак над сигнальным фонарём — виден издалека
	local beaconCF = cf * CF(-8, 0, 6)
	mk(model, V3(0.8, 22, 0.8), beaconCF * CF(0, 11, 0), rgb(60, 60, 66), M.Metal)
	local beaconBase = mk(model, V3(3, 1, 3), beaconCF * CF(0, 0.5, 0), rgb(90, 90, 96), M.Concrete)
	for _, y in ipairs({ 7, 14, 19 }) do
		deco(model, V3(2.2, 0.22, 0.22), beaconCF * CF(0, y, 0) * CFrame.Angles(0, y * 0.4, 0), rgb(72, 72, 78), M.Metal, { CastShadow = false })
	end
	deco(model, V3(0.3, 2.8, 2.8), beaconCF * CF(0, 24.2, 0) * CFrame.Angles(0, 0, math.rad(90)), rgb(40, 40, 44), M.Metal, { Shape = "Cylinder", CastShadow = false })
	for k = 0, 2 do
		local a = k * math.pi * 2 / 3 + 0.3
		guyWire(beaconBase, (beaconCF * CF(0, 19, 0)).Position, (beaconCF * CF(math.cos(a) * 7, 0.1, math.sin(a) * 7)).Position)
	end
	local lamp = deco(model, V3(2, 2, 2), beaconCF * CF(0, 23, 0), color, M.Neon, { Shape = "Ball" })
	local light = Instance.new("PointLight")
	light.Range = 32
	light.Brightness = 2
	light.Color = color
	light.Parent = lamp
	site.lamp = lamp
	site.light = light
	addCircle(beaconCF.X, beaconCF.Z, 1.6)

	-- Табличка с названием, лицом к дороге
	local signCF = cf * CF(8, 0, -2)
	for _, x in ipairs({ -4.5, 4.5 }) do
		mk(model, V3(0.5, 6, 0.5), signCF * CF(x, 3, 0), rgb(90, 70, 50), M.Wood)
	end
	local board = mk(model, V3(10, 2.6, 0.4), signCF * CF(0, 5, -0.3), rgb(28, 28, 32), M.SmoothPlastic)
	signText(board, o.title, color)
	-- деревянная рамка, козырёк и фонарь над табличкой (горит ночью)
	deco(model, V3(10.6, 3.2, 0.2), signCF * CF(0, 5, -0.05), rgb(70, 56, 42), M.WoodPlanks, { CastShadow = false })
	deco(model, V3(11.4, 0.3, 1.6), signCF * CF(0, 6.6, -0.3) * CFrame.Angles(math.rad(-12), 0, 0), rgb(60, 50, 40), M.WoodPlanks)
	local lantern = deco(model, V3(0.6, 0.9, 0.6), signCF * CF(0, 6.05, -1.1), rgb(255, 214, 140), M.Neon, { CastShadow = false })
	local lanternLight = Instance.new("PointLight")
	lanternLight.Range = 12
	lanternLight.Brightness = 1.1
	lanternLight.Color = rgb(255, 206, 140)
	lanternLight.Parent = lantern
	nightLamp(lantern)
	addCircle(signCF.X, signCF.Z, 5)
	return site
end

-- Сбор ---------------------------------------------------------------------------------

local function addCollectProgress(o, amount)
	if o.state ~= "active" then
		return
	end
	setProgress(o, o.progress + amount)
	if o.progress >= o.goal then
		complete(o, "Всё собрано")
	end
end

local function trackLoot(o, model)
	local entry = { model = model, counted = false, matched = false, countedAt = 0 }
	table.insert(o.site.loot, entry)
	model.Destroying:Connect(function()
		if o.cancelled or entry.counted or o.state ~= "active" then
			return
		end
		if model:GetAttribute("Taken") then
			-- подобрали; OnItemPickup может прийти сразу после — сопоставим его с этой записью
			entry.counted = true
			entry.countedAt = os.clock()
			addCollectProgress(o, math.max(1, model:GetAttribute("Count") or 1))
		end
	end)
end

local function buildCollect(o, site)
	local model, cf = site.model, site.cf
	local tops = {}
	for c = 1, 3 do
		local a = (c / 3) * math.pi * 2 + 0.5
		local ccf = cf * CF(math.cos(a) * 7, 0, math.sin(a) * 7 + 3) * CFrame.Angles(0, a, 0)
		-- ящик на поддоне: металлические пояса, трафаретная надпись, у одного — брезент
		deco(model, V3(4.6, 0.5, 4.6), ccf * CF(0, 0.25, 0), rgb(110, 86, 58), M.WoodPlanks, { CastShadow = false })
		local crateBox = mk(model, V3(4, 3, 4), ccf * CF(0, 2, 0), rgb(125, 92, 55), M.WoodPlanks)
		deco(model, V3(4.2, 0.4, 4.2), ccf * CF(0, 2.8, 0), rgb(80, 70, 60), M.Metal, { CastShadow = false })
		deco(model, V3(4.2, 0.4, 4.2), ccf * CF(0, 1.2, 0), rgb(80, 70, 60), M.Metal, { CastShadow = false })
		local stencil = signText(crateBox, "ПРИПАСЫ", rgb(44, 34, 24))
		stencil.LightInfluence = 1
		if c == 1 then
			Util.Wedge({ Size = V3(4.4, 1.2, 2.4), CFrame = ccf * CF(0, 4.1, 1) * CFrame.Angles(0, math.pi, 0), Color = rgb(62, 76, 54), Material = M.Fabric, CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false, Parent = model })
		end
		addCircle(ccf.X, ccf.Z, 2.8)
		table.insert(tops, ccf * CF(0, 3.5, 0))
	end
	-- гарантированные предметы (+1 про запас)
	for i = 1, o.goal + 1 do
		local top = tops[((i - 1) % #tops) + 1] * CF(site.r:NextNumber(-1, 1), 0, site.r:NextNumber(-1, 1))
		local loot = S.Loot.SpawnItem(o.def.item, 1, top, model)
		if loot then
			trackLoot(o, loot)
		end
	end
	site.guardsLeft = scaled(2 + math.floor(o.biomeIndex / 2), o.s / Config.StudsPerKm)
end

-- Подбор предмета командой (вызывает LootService). source — модель добычи, если передана.
function Obj.OnItemPickup(player, itemId, amount, source)
	if typeof(player) ~= "Instance" or not player:IsA("Player") or type(itemId) ~= "string" then
		return
	end
	amount = math.max(1, math.floor(tonumber(amount) or 1))
	for _, o in ipairs(list) do
		if o.state == "active" and o.type == "collect" and o.def.item == itemId and o.site then
			local site = o.site
			local handled = false
			local now = os.clock()
			for _, e in ipairs(site.loot) do
				local mine = typeof(source) == "Instance" and e.model == source
				if not e.matched and (mine or (source == nil and e.model:GetAttribute("Taken"))) then
					e.matched = true
					handled = true
					if not e.counted then
						e.counted = true
						addCollectProgress(o, amount)
					end
					break
				end
			end
			if not handled and source == nil then
				-- модель уже удалена и засчитана в Destroying
				for _, e in ipairs(site.loot) do
					if e.counted and not e.matched and now - e.countedAt < 1 then
						e.matched = true
						handled = true
						break
					end
				end
			end
			if not handled then
				local dropped = typeof(source) == "Instance" and source:GetAttribute("Dropped") == true
				if not dropped then
					addCollectProgress(o, amount)
				end
			end
		end
	end
end

-- Зачистка гнезда ----------------------------------------------------------------------

local function buildClear(o, site)
	local model, cf = site.model, site.cf
	deco(model, V3(0.2, 34, 34), cf * CF(0, 0.12, 4) * CFrame.Angles(0, 0, math.rad(90)), rgb(46, 34, 44), M.Ground, { Shape = "Cylinder" })
	for k = 1, 5 do
		local a = (k / 5) * math.pi * 2 + site.r:NextNumber(-0.2, 0.2)
		local h = site.r:NextNumber(4, 9)
		local wcf = cf * CF(0, 0, 4) * CFrame.Angles(0, a, 0) * CF(0, 0, -19)
		mk(model, V3(10, h, 1.5), wcf * CF(0, h / 2, 0) * CFrame.Angles(0, 0, math.rad(site.r:NextNumber(-6, 6))), rgb(120, 112, 104), M.Concrete)
		S.Obstacles.AddBox(OB_CHUNK, wcf, 5, 0.9, { hard = true, kind = "objective" })
		-- торчащая арматура и обломок у подножия
		for _ = 1, 2 do
			deco(model, V3(0.2, h * 0.5, 0.2), wcf * CF(site.r:NextNumber(-4, 4), h + h * 0.15, 0) * CFrame.Angles(site.r:NextNumber(-0.4, 0.4), 0, site.r:NextNumber(-0.5, 0.5)), rgb(96, 60, 40), M.CorrodedMetal, { CastShadow = false })
		end
		deco(model, V3(2.2, 1.2, 1.8), wcf * CF(site.r:NextNumber(-3, 3), 0.5, -1.6) * CFrame.Angles(site.r:NextNumber(-0.3, 0.3), site.r:NextNumber(0, 3), 0), rgb(110, 104, 98), M.Concrete)
	end
	-- гнездо: тёмный холм, светящиеся жилы, черепа
	local nestCF = cf * CF(0, 0, 4)
	deco(model, V3(11, 11, 11), nestCF * CF(0, -3.6, 0), rgb(50, 36, 48), M.Ground, { Shape = "Ball" })
	for k = 1, 6 do
		local len = site.r:NextNumber(6, 13)
		deco(model, V3(0.45, 0.25, len), nestCF * CFrame.Angles(0, k * math.pi / 3 + site.r:NextNumber(-0.3, 0.3), 0) * CF(0, 0.2, -len / 2 - 3), rgb(96, 40, 116), M.Neon, { CastShadow = false })
	end
	for _ = 1, 3 do
		deco(model, V3(0.9, 0.9, 0.9), nestCF * CF(site.r:NextNumber(-9, 9), 0.4, site.r:NextNumber(-9, 9)), rgb(214, 208, 190), M.SmoothPlastic, { Shape = "Ball", CastShadow = false })
	end
	for _ = 1, 8 do
		local p = cf * CF(site.r:NextNumber(-12, 12), 0.2, site.r:NextNumber(-8, 16)) * CFrame.Angles(0, site.r:NextNumber(0, 6.28), 0)
		deco(model, V3(0.4, 0.4, site.r:NextNumber(1.2, 2.4)), p, rgb(225, 220, 200), M.SmoothPlastic)
	end
	for _ = 1, 4 do
		local p = cf * CF(site.r:NextNumber(-8, 8), 0.3, site.r:NextNumber(-4, 12))
		deco(model, V3(2.5, 0.3, 2.5), p, rgb(90, 140, 60), M.Neon, { Shape = "Cylinder", Transparency = 0.4 })
	end
	site.nestPos = (cf * CF(0, 0, 4)).Position
	site.guardsLeft = scaled(4 + math.floor(o.biomeIndex / 2), o.s / Config.StudsPerKm)
end

-- Охота на элиту -----------------------------------------------------------------------

local function buildElite(o, site)
	local model, cf = site.model, site.cf
	-- разбитая машина, кости и следы когтей
	local car = cf * CF(-3, 0, 12) * CFrame.Angles(0, math.rad(site.r:NextNumber(-40, 40)), math.rad(12))
	mk(model, V3(6, 3, 11), car * CF(0, 1.8, 0), rgb(90, 70, 60), M.CorrodedMetal)
	mk(model, V3(5.4, 2, 5), car * CF(0, 4, 1), rgb(60, 50, 46), M.Metal)
	addCircle(car.X, car.Z, 6)
	-- выбитое стекло, колёса, следы когтей на борту, оторванная дверь и лужи крови
	deco(model, V3(5, 1.6, 0.12), car * CF(0, 4, -1.6) * CFrame.Angles(math.rad(-25), 0, 0), rgb(30, 36, 40), M.Glass, { Transparency = 0.45, CastShadow = false })
	for _, x in ipairs({ -3.1, 3.1 }) do
		for _, z in ipairs({ -3.6, 3.6 }) do
			if site.r:NextNumber() < 0.75 then
				deco(model, V3(1, 2.2, 2.2), car * CF(x, 1.1, z), rgb(24, 24, 26), M.Rubber, { Shape = "Cylinder" })
			end
		end
	end
	for k = 1, 3 do
		deco(model, V3(0.1, 0.25, 3.4), car * CF(3.06, 1.9 + k * 0.45, -1 + k * 0.4) * CFrame.Angles(math.rad(25), 0, 0), rgb(26, 20, 18), M.SmoothPlastic, { CastShadow = false })
	end
	deco(model, V3(0.25, 2.6, 3.4), car * CF(6.5, 0.2, 2) * CFrame.Angles(0, 0.5, math.rad(80)), rgb(90, 70, 60), M.CorrodedMetal)
	for _ = 1, 4 do
		local rr = site.r:NextNumber(1.5, 3.5)
		deco(model, V3(0.06, rr, rr), cf * CF(site.r:NextNumber(-10, 10), 0.08, site.r:NextNumber(-4, 16)) * CFrame.Angles(0, 0, math.rad(90)), rgb(70, 12, 12), M.SmoothPlastic, { Shape = "Cylinder", CastShadow = false })
	end
	for k = 1, 3 do
		deco(model, V3(0.3, 0.1, 7), cf * CF(-3 + k * 1.5, 0.15, 2) * CFrame.Angles(0, math.rad(20), 0), rgb(110, 20, 20), M.SmoothPlastic)
	end
	for _ = 1, 10 do
		local p = cf * CF(site.r:NextNumber(-14, 14), 0.2, site.r:NextNumber(-6, 20)) * CFrame.Angles(0, site.r:NextNumber(0, 6.28), 0)
		deco(model, V3(0.4, 0.4, site.r:NextNumber(1, 2.6)), p, rgb(225, 220, 200), M.SmoothPlastic)
	end
	local warnSign = mk(model, V3(6, 3, 0.3), cf * CF(4, 3.5, -6), rgb(220, 180, 40), M.SmoothPlastic)
	signText(warnSign, "ОПАСНО", rgb(30, 20, 10))
	mk(model, V3(0.4, 2, 0.4), cf * CF(4, 1, -6), rgb(70, 60, 50), M.Wood)
	site.guardsLeft = 0
end

-- Спасение выжившего -------------------------------------------------------------------

local R6 = {
	RootJoint = { CF(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0), CF(0, 0, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0) },
	Neck = { CF(0, 1, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0), CF(0, -0.5, 0, -1, 0, 0, 0, 0, 1, 0, 1, 0) },
	RightShoulder = { CF(1, 0.5, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0), CF(-0.5, 0.5, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0) },
	LeftShoulder = { CF(-1, 0.5, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0), CF(0.5, 0.5, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0) },
	RightHip = { CF(1, -1, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0), CF(0.5, 1, 0, 0, 0, 1, 0, 1, 0, -1, 0, 0) },
	LeftHip = { CF(-1, -1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0), CF(-0.5, 1, 0, 0, 0, -1, 0, 1, 0, 1, 0, 0) },
}
local SURVIVOR_SHIRTS = { rgb(70, 110, 160), rgb(150, 60, 50), rgb(90, 120, 70), rgb(160, 130, 60), rgb(110, 80, 140), rgb(60, 60, 60) }
local SURVIVOR_HP = 220

local function limb(model, name, size, color, collide, cf)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = M.SmoothPlastic
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.CanCollide = collide
	p.Anchored = false
	p.CFrame = cf
	p.Parent = model
	return p
end

local function motor(parent, name, part0, part1, pair)
	local m = Instance.new("Motor6D")
	m.Name = name
	m.Part0 = part0
	m.Part1 = part1
	m.C0 = pair[1]
	m.C1 = pair[2]
	m.Parent = parent
	return m
end

local function attachDetail(model, basePart, size, offset, color, material)
	local p = Instance.new("Part")
	p.Name = "Detail"
	p.Size = size
	p.Color = color
	p.Material = material or M.SmoothPlastic
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	p.Anchored = false
	p.CFrame = basePart.CFrame * offset
	p.Parent = model
	local w = Instance.new("WeldConstraint")
	w.Part0 = basePart
	w.Part1 = p
	w.Parent = p
	return p
end

local callSurvivor
local onSurvivorDied

local function spawnSurvivor(o)
	local site = o.site
	local base = site.cf * CF(0, 3, 5)
	local model = Instance.new("Model")
	model.Name = "Выживший"
	local skin = rgb(226, 186, 150)
	local shirt = SURVIVOR_SHIRTS[(o.biomeIndex % #SURVIVOR_SHIRTS) + 1]
	local pants = rgb(58, 60, 72)
	local root = limb(model, "HumanoidRootPart", V3(2, 2, 1), skin, false, base)
	root.Transparency = 1
	local torso = limb(model, "Torso", V3(2, 2, 1), shirt, true, base)
	local head = limb(model, "Head", V3(2, 1, 1), skin, true, base * CF(0, 1.5, 0))
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Head
	mesh.Scale = V3(1.25, 1.25, 1.25)
	mesh.Parent = head
	local la = limb(model, "Left Arm", V3(1, 2, 1), skin, false, base * CF(-1.5, 0, 0))
	local ra = limb(model, "Right Arm", V3(1, 2, 1), skin, false, base * CF(1.5, 0, 0))
	local ll = limb(model, "Left Leg", V3(1, 2, 1), pants, false, base * CF(-0.5, -2, 0))
	local rl = limb(model, "Right Leg", V3(1, 2, 1), pants, false, base * CF(0.5, -2, 0))
	motor(root, "RootJoint", root, torso, R6.RootJoint)
	motor(torso, "Neck", torso, head, R6.Neck)
	motor(torso, "Right Shoulder", torso, ra, R6.RightShoulder)
	motor(torso, "Left Shoulder", torso, la, R6.LeftShoulder)
	motor(torso, "Right Hip", torso, rl, R6.RightHip)
	motor(torso, "Left Hip", torso, ll, R6.LeftHip)
	-- рюкзак, кепка, глаза, рукава
	attachDetail(model, torso, V3(1.6, 1.8, 0.8), CF(0, -0.1, 0.9), rgb(90, 70, 50), M.Fabric)
	attachDetail(model, head, V3(1.3, 0.35, 1.3), CF(0, 0.55, 0), rgb(200, 90, 40), M.Fabric)
	attachDetail(model, head, V3(1.1, 0.12, 0.7), CF(0, 0.42, -0.8), rgb(200, 90, 40), M.Fabric)
	attachDetail(model, head, V3(0.25, 0.25, 0.1), CF(-0.3, 0.1, -0.6), rgb(25, 25, 25))
	attachDetail(model, head, V3(0.25, 0.25, 0.1), CF(0.3, 0.1, -0.6), rgb(25, 25, 25))
	attachDetail(model, la, V3(1.05, 0.7, 1.05), CF(0, 0.65, 0), shirt)
	attachDetail(model, ra, V3(1.05, 0.7, 1.05), CF(0, 0.65, 0), shirt)

	local hum = Instance.new("Humanoid")
	hum.RigType = Enum.HumanoidRigType.R6
	hum.MaxHealth = SURVIVOR_HP
	hum.Health = SURVIVOR_HP
	hum.WalkSpeed = 16
	hum.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	hum.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	hum.RequiresNeck = false
	hum.Parent = model
	model.PrimaryPart = root
	model:SetAttribute("Survivor", true)
	model:SetAttribute("ObjectiveId", o.id)
	model:SetAttribute("Following", false)

	-- подпись с прочностью
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(160, 38)
	bb.StudsOffset = V3(0, 2.4, 0)
	bb.MaxDistance = 90
	bb.LightInfluence = 0
	bb.Adornee = head
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Size = UDim2.new(1, 0, 0.55, 0)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Font = Enum.Font.GothamBold
	nameLabel.TextScaled = true
	nameLabel.TextColor3 = rgb(140, 220, 255)
	nameLabel.TextStrokeTransparency = 0.3
	nameLabel.Text = "Выживший"
	nameLabel.Parent = bb
	local hpLabel = Instance.new("TextLabel")
	hpLabel.Size = UDim2.new(1, 0, 0.45, 0)
	hpLabel.Position = UDim2.fromScale(0, 0.55)
	hpLabel.BackgroundTransparency = 1
	hpLabel.Font = Enum.Font.Gotham
	hpLabel.TextScaled = true
	hpLabel.TextColor3 = rgb(230, 230, 230)
	hpLabel.TextStrokeTransparency = 0.3
	hpLabel.Text = "Здоровье 100%"
	hpLabel.Parent = bb
	bb.Parent = head

	local prompt = addPrompt(site, torso, "Позвать за собой", "Выживший", 0.4, 10)
	model.Parent = site.model
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	for _, st in ipairs({ Enum.HumanoidStateType.Seated, Enum.HumanoidStateType.Swimming, Enum.HumanoidStateType.FallingDown, Enum.HumanoidStateType.Ragdoll }) do
		hum:SetStateEnabled(st, false)
	end

	site.survivor = model
	site.hum = hum
	site.root = root
	site.prompt = prompt
	site.leader = nil
	site.lastPos = root.Position
	site.stuck = 0
	hum.HealthChanged:Connect(function(h)
		hpLabel.Text = "Здоровье " .. math.max(0, math.ceil(h / SURVIVOR_HP * 100)) .. "%"
	end)
	hum.Died:Connect(function()
		onSurvivorDied(o, model)
	end)
	prompt.Triggered:Connect(function(player)
		callSurvivor(o, player)
	end)
	setText(o, "Выживший ждёт помощи — позовите его за собой")
end

local function survivorTarget(o)
	local site = o.site
	if site.target or not site.root or not site.hum then
		return
	end
	local hum = site.hum
	addTarget(site, {
		root = site.root,
		radius = 1.5,
		priority = 1,
		onDamage = function(amount)
			if type(amount) == "number" and amount > 0 and hum.Health > 0 then
				hum:TakeDamage(amount)
			end
		end,
	})
end

callSurvivor = function(o, player)
	if o.cancelled or o.state ~= "active" then
		return
	end
	local site = o.site
	if not site or not site.root or not site.hum or site.hum.Health <= 0 or site.leader == player then
		return
	end
	if not playerRootNear(player, site.root.Position, 14) then
		return
	end
	site.leader = player
	if site.root.Anchored then
		site.root.Anchored = false
	end
	if site.prompt then
		site.prompt.Enabled = false
	end
	site.survivor:SetAttribute("Following", true)
	survivorTarget(o)
	S.PlayerData.Notify(player, "Выживший идёт за вами. Доведите его до автобуса", rgb(140, 220, 255))
	setText(o, "Выживший идёт за " .. player.DisplayName .. " — доведите его до автобуса")
end

local function stopFollow(o, message)
	local site = o.site
	local leader = site.leader
	site.leader = nil
	if site.prompt and site.prompt.Parent then
		site.prompt.Enabled = true
	end
	if site.survivor then
		site.survivor:SetAttribute("Following", false)
	end
	if site.hum and site.root then
		site.hum:MoveTo(site.root.Position)
	end
	if leader and leader.Parent and message then
		S.PlayerData.Notify(leader, message, rgb(255, 190, 90))
	end
	setText(o, "Выживший ждёт — позовите его за собой")
end

onSurvivorDied = function(o, model)
	local site = o.site
	if o.cancelled or not site or site.survivor ~= model or o.state ~= "active" then
		return
	end
	removeTarget(site)
	site.survivor, site.hum, site.root, site.prompt, site.leader = nil, nil, nil, nil, nil
	o.state = "failed"
	site.respawnAt = os.clock() + RESCUE_RESPAWN
	dirty = true
	setText(o, "Выживший погиб. Новый появится через " .. RESCUE_RESPAWN .. " с")
	S.PlayerData.NotifyAll("Выживший погиб! Новый появится на месте через " .. RESCUE_RESPAWN .. " с", RED)
	task.delay(4, function()
		if model.Parent then
			model:Destroy()
		end
	end)
end

local function rescueSurvivor(o)
	local site = o.site
	local model, root = site.survivor, site.root
	removeTarget(site)
	site.survivor, site.hum, site.root, site.prompt, site.leader = nil, nil, nil, nil, nil
	if model then
		model:SetAttribute("Following", false)
		if root and root.Anchored then
			root.Anchored = false
		end
		if root and not S.Bus.IsInside(root.Position) then
			local cf = S.Bus.GetSpawnCFrame(rng:NextInteger(0, 5))
			if cf then
				model:PivotTo(cf)
			end
		end
		task.delay(5, function()
			if model.Parent then
				model:Destroy()
			end
		end)
	end
	complete(o, "Выживший в автобусе")
end

-- Место уснуло: ждущий выживший исчезает (как зомби места) и появится снова при пробуждении.
-- Иначе после выгрузки чанка он падает за карту и бесконечно «гибнет».
local function sleepSurvivor(site)
	local model = site.survivor
	if not model or site.leader then
		return
	end
	local prompt = site.prompt
	site.survivor, site.hum, site.root, site.prompt = nil, nil, nil, nil
	for i = #site.prompts, 1, -1 do
		if site.prompts[i] == prompt then
			table.remove(site.prompts, i)
		end
	end
	if model.Parent then
		model:Destroy()
	end
end

-- 5 Гц: следование за игроком и посадка в автобус
local function updateFollower(o, step)
	local site = o.site
	local hum, root = site.hum, site.root
	if not hum or not root or not root.Parent or hum.Health <= 0 then
		return
	end
	local pos = root.Position
	if pos.Y < -30 then
		if site.leader then
			hum.Health = 0
		elseif site.survivor then
			-- под местом цели нет земли (чанк выгружен, автобус далеко): не убиваем,
			-- а возвращаем на место и замораживаем до зова игрока
			pcall(function()
				root.AssemblyLinearVelocity = Vector3.zero
			end)
			site.survivor:PivotTo(site.cf * CF(0, 3, 5))
			root.Anchored = true
			site.lastPos = root.Position
		end
		return
	end
	if S.Bus.Root and S.Bus.IsInside(pos) then
		rescueSurvivor(o)
		return
	end
	local leader = site.leader
	if not leader then
		return
	end
	local lroot = leader.Parent and leader.Character and leader.Character:FindFirstChild("HumanoidRootPart")
	if not lroot or not S.PlayerData.IsAlive(leader) then
		stopFollow(o, "Выживший потерял вас и ждёт на месте")
		return
	end
	local lpos = lroot.Position
	local dist = Util.FlatDist(pos, lpos)
	if dist > 90 then
		stopFollow(o, "Вы ушли слишком далеко — выживший остановился")
		return
	end
	-- дошёл до автобуса вместе с игроком — садится внутрь
	if S.Bus.Root and nearBusHull(pos, 9) and (S.Bus.IsInside(lpos) or nearBusHull(lpos, 14)) then
		rescueSurvivor(o)
		return
	end
	if dist > 6 then
		local dir = Util.Flat(lpos - pos)
		hum.WalkSpeed = dist > 22 and 24 or 16
		hum:MoveTo(lpos - dir.Unit * 4)
		local moved = Util.FlatDist(site.lastPos or pos, pos)
		if moved < 0.3 then
			site.stuck = (site.stuck or 0) + step
			if site.stuck > 1.2 then
				site.stuck = 0
				hum.Jump = true
			end
		else
			site.stuck = 0
		end
	else
		hum:MoveTo(pos)
		site.stuck = 0
	end
	site.lastPos = pos
end

local function buildRescue(o, site)
	local model, cf = site.model, site.cf
	-- палатка из двух клиньев
	local tent = cf * CF(7, 0, 12)
	local tentColor = rgb(80, 110, 70)
	Util.Wedge({ Size = V3(7, 4, 3), CFrame = tent * CF(-1.5, 2, 0) * CFrame.Angles(0, math.rad(90), 0), Color = tentColor, Material = M.Fabric, Parent = model })
	Util.Wedge({ Size = V3(7, 4, 3), CFrame = tent * CF(1.5, 2, 0) * CFrame.Angles(0, math.rad(-90), 0), Color = tentColor, Material = M.Fabric, Parent = model })
	addCircle(tent.X, tent.Z, 4.5)
	-- костёр
	local fireCF = cf * CF(-2, 0, 9)
	for k = 1, 4 do
		deco(model, V3(0.4, 0.4, 2.4), fireCF * CF(0, 0.25, 0) * CFrame.Angles(0, k * math.pi / 4, 0), rgb(90, 60, 40), M.Wood)
	end
	local ember = deco(model, V3(1, 0.3, 1), fireCF * CF(0, 0.4, 0), rgb(255, 120, 40), M.Neon)
	local fire = Instance.new("Fire")
	fire.Size = 3
	fire.Heat = 6
	fire.Parent = ember
	local light = Instance.new("PointLight")
	light.Range = 18
	light.Brightness = 1.4
	light.Color = rgb(255, 160, 80)
	light.Parent = ember
	-- баррикада из досок
	for k = -1, 1 do
		local b = cf * CF(k * 5, 0, -3) * CFrame.Angles(0, math.rad(site.r:NextNumber(-8, 8)), 0)
		mk(model, V3(4.5, 2.2, 0.6), b * CF(0, 1.1, 0), rgb(130, 100, 70), M.WoodPlanks)
	end
	-- вход в палатку, спальник, рюкзак, ящик и надпись на баррикаде
	deco(model, V3(2.2, 2.6, 0.1), tent * CF(0, 1.3, -3.52), rgb(28, 32, 24), M.Fabric, { CastShadow = false })
	deco(model, V3(2, 0.5, 4.6), cf * CF(2, 0.25, 6.5) * CFrame.Angles(0, 0.4, 0), rgb(70, 90, 130), M.Fabric, { CastShadow = false })
	deco(model, V3(1.4, 1.8, 0.9), cf * CF(4.4, 0.9, 7.6) * CFrame.Angles(0.15, 0.6, 0), rgb(96, 64, 40), M.Fabric)
	mk(model, V3(2.4, 1.8, 1.8), cf * CF(-6, 0.9, 10), rgb(104, 80, 54), M.WoodPlanks)
	local plea = deco(model, V3(6, 1.6, 0.2), cf * CF(0, 2.9, -3.45) * CFrame.Angles(0, 0, math.rad(site.r:NextNumber(-5, 5))), rgb(120, 96, 70), M.WoodPlanks)
	local pleaText = signText(plea, "ЗДЕСЬ ЖИВЫЕ", rgb(170, 30, 24))
	pleaText.LightInfluence = 1
	S.Obstacles.AddBox(OB_CHUNK, cf * CF(0, 0, -3), 7.5, 0.8, { hard = true, kind = "objective" })
	site.guardsLeft = scaled(3, o.s / Config.StudsPerKm)
	spawnSurvivor(o)
end

-- Оборона объекта ----------------------------------------------------------------------

local repairDefend

local function defendLabel(site, text, color)
	if site.coreLabel and site.coreLabel.Text ~= text then
		site.coreLabel.Text = text
		site.coreLabel.TextColor3 = color
	end
end

local function buildDefend(o, site)
	local model, cf = site.model, site.cf
	local kind = o.def.site or "radio"
	local center = cf * CF(0, 0, 8)
	local core
	if kind == "pump" then
		local house = center * CF(0, 0, 7)
		mk(model, V3(12, 8, 10), house * CF(0, 4, 0), rgb(150, 150, 140), M.Concrete)
		mk(model, V3(13, 0.8, 11), house * CF(0, 8.4, 0), rgb(90, 90, 96), M.CorrodedMetal)
		S.Obstacles.AddBox(OB_CHUNK, house, 6.5, 5.5, { hard = true, kind = "objective" })
		local tankCF = center * CF(-11, 0, 5)
		mk(model, V3(7, 6, 6), tankCF * CF(0, 3.5, 0) * CFrame.Angles(0, 0, math.rad(90)), rgb(70, 100, 120), M.Metal, { Shape = "Cylinder" })
		addCircle(tankCF.X, tankCF.Z, 3.5)
		mk(model, V3(1, 1, 9), center * CF(-6, 1.2, 1), rgb(90, 90, 90), M.Metal)
		mk(model, V3(10, 1, 1), center * CF(-1, 1.2, -3.5), rgb(90, 90, 90), M.Metal)
		core = mk(model, V3(3, 4, 2), center * CF(4, 2, -2), rgb(60, 80, 110), M.Metal)
	elseif kind == "generator" then
		core = mk(model, V3(8, 5, 4), center * CF(0, 2.5, 0), rgb(210, 170, 40), M.Metal)
		mk(model, V3(0.8, 5, 0.8), center * CF(3, 7, 1), rgb(60, 60, 60), M.Metal)
		for k = 1, 3 do
			local drum = center * CF(-7 + k * 2.4, 0, 5)
			mk(model, V3(3, 2, 2), drum * CF(0, 1.5, 0) * CFrame.Angles(0, 0, math.rad(90)), rgb(170, 50, 40), M.Metal, { Shape = "Cylinder" })
		end
		addCircle(center.X, center.Z, 5)
	else
		local tower = center * CF(0, 0, 7)
		for _, x in ipairs({ -3, 3 }) do
			for _, z in ipairs({ -3, 3 }) do
				mk(model, V3(0.8, 32, 0.8), tower * CF(x, 16, z), rgb(180, 60, 50), M.Metal)
			end
		end
		for y = 5, 29, 8 do
			for _, z in ipairs({ -3, 3 }) do
				deco(model, V3(6.8, 0.4, 0.4), tower * CF(0, y, z), rgb(220, 220, 220), M.Metal)
				deco(model, V3(0.4, 0.4, 6.8), tower * CF(z, y, 0), rgb(220, 220, 220), M.Metal)
			end
		end
		local tip = deco(model, V3(1, 1, 1), tower * CF(0, 33, 0), rgb(255, 40, 30), M.Neon)
		local tipLight = Instance.new("PointLight")
		tipLight.Range = 20
		tipLight.Color = rgb(255, 60, 40)
		tipLight.Parent = tip
		addCircle(tower.X, tower.Z, 4.8)
		core = mk(model, V3(3, 4, 2), center * CF(0, 2, -3), rgb(80, 90, 80), M.Metal)
	end
	addCircle(core.Position.X, core.Position.Z, 2.5)
	site.core = core
	-- детали объекта: оборудование, кабели, канистры, полукруг мешков с песком
	if kind == "pump" then
		deco(model, V3(0.25, 1.8, 1.8), center * CF(-6, 2.6, 1) * CFrame.Angles(0, math.rad(90), 0), rgb(170, 40, 34), M.Metal, { Shape = "Cylinder", CastShadow = false })
		deco(model, V3(1, 3.4, 1), center * CF(-6, 2.3, -3.5), rgb(90, 90, 90), M.Metal)
		guyWire(core, core.Position + V3(0, 1.5, 0), (center * CF(-1, 7.5, 7)).Position, 0.12, rgb(24, 24, 26))
	elseif kind == "generator" then
		for k = 1, 3 do
			deco(model, V3(0.9, 1.3, 0.6), center * CF(5 + k * 1.1, 0.65, 3) * CFrame.Angles(0, k * 0.3, 0), rgb(160, 36, 30), M.Metal)
		end
		guyWire(core, core.Position + V3(0, 2.5, 0), (center * CF(-8, 0.2, -6)).Position, 0.12, rgb(24, 24, 26))
	else
		local cabinet = mk(model, V3(2.4, 3.2, 1.6), center * CF(4.5, 1.6, 4), rgb(120, 124, 120), M.Metal)
		deco(model, V3(0.1, 1.2, 0.8), cabinet.CFrame * CF(-1.22, 0.4, 0), rgb(120, 220, 140), M.Neon, { CastShadow = false })
		local tower = center * CF(0, 0, 7)
		deco(model, V3(0.3, 3.2, 3.2), tower * CF(0, 24, -3.4) * CFrame.Angles(0, math.rad(90), math.rad(-20)), rgb(200, 200, 196), M.Metal, { Shape = "Cylinder", CastShadow = false })
		guyWire(cabinet, cabinet.Position + V3(0, 1.4, 0), (tower * CF(0, 6, 0)).Position, 0.1, rgb(24, 24, 26))
	end
	for k = -2, 2 do
		deco(model, V3(2.6, 1.1, 1.3), center * CFrame.Angles(0, k * 0.35, 0) * CF(0, 0.55, -10), rgb(126, 112, 84), M.Fabric)
	end

	local smoke = Instance.new("Smoke")
	smoke.Color = rgb(60, 60, 60)
	smoke.Size = 4
	smoke.RiseVelocity = 4
	smoke.Opacity = 0.3
	smoke.Enabled = true
	smoke.Parent = core
	site.smoke = smoke

	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(220, 30)
	bb.StudsOffset = V3(0, 4, 0)
	bb.MaxDistance = 140
	bb.LightInfluence = 0
	bb.Adornee = core
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextStrokeTransparency = 0.3
	label.TextColor3 = RED
	label.Text = "СЛОМАНО — удерживайте E"
	label.Parent = bb
	bb.Parent = core
	site.coreLabel = label

	site.phase = "broken"
	site.maxHP = 500 + 120 * o.biomeIndex
	site.hp = site.maxHP
	site.elapsed = 0
	site.nextWave = 0
	local prompt = addPrompt(site, core, "Починить", o.title, 3, 10)
	site.repairPrompt = prompt
	prompt.Triggered:Connect(function(player)
		repairDefend(o, player)
	end)
	setText(o, "Почините объект: удерживайте E 3 с")
end

local function breakDefend(o)
	local site = o.site
	if not site or site.phase ~= "running" then
		return
	end
	site.phase = "broken"
	site.elapsed = 0
	site.hp = 0
	setProgress(o, 0)
	removeTarget(site)
	if site.repairPrompt and site.repairPrompt.Parent then
		site.repairPrompt.Enabled = true
	end
	if site.smoke then
		site.smoke.Enabled = true
	end
	S.PlayerData.NotifyAll("«" .. o.title .. "» разрушен! Почините его заново", RED)
	setText(o, "Объект разрушен — почините заново (E)")
	defendLabel(site, "РАЗРУШЕНО — удерживайте E", RED)
end

repairDefend = function(o, player)
	if o.cancelled or o.state ~= "active" then
		return
	end
	local site = o.site
	if not site or site.phase ~= "broken" or not site.core then
		return
	end
	if not playerRootNear(player, site.core.Position, 14) then
		return
	end
	site.phase = "running"
	site.hp = site.maxHP
	site.elapsed = 0
	site.nextWave = os.clock() + 5
	setProgress(o, 0)
	if site.repairPrompt then
		site.repairPrompt.Enabled = false
	end
	if site.smoke then
		site.smoke.Enabled = false
	end
	local entity
	entity = {
		root = site.core,
		radius = 3,
		priority = 2,
		onDamage = function(amount)
			if o.cancelled or site.target ~= entity or site.phase ~= "running" then
				return
			end
			if type(amount) == "number" and amount > 0 then
				site.hp = site.hp - amount
				if site.hp <= 0 then
					breakDefend(o)
				end
			end
		end,
	}
	addTarget(site, entity)
	S.PlayerData.NotifyAll(player.DisplayName .. " запустил(а) «" .. o.title .. "». Держите зону " .. o.goal .. " с!", GREEN)
	dirty = true
end

local function spawnWave(o)
	local site = o.site
	local alive = S.Zombies.CountTag(o.tag)
	local n = math.floor((2 + o.biomeIndex * 0.5 + (#Players:GetPlayers() - 1)) * countMult(o.s / Config.StudsPerKm) + 0.5)
	n = math.min(n, 16 - alive)
	if n <= 0 then
		return
	end
	local biome = Biomes.List[o.biomeIndex]
	local center = site.core.Position
	for _ = 1, n do
		local p = spawnPoint(center, 45, 65, o.s)
		if p then
			spawnZombie(o, Util.Weighted(rng, biome.zombies), p, "wave", { aggro = true })
		end
	end
	S.Zombies.Alert(center, 75)
end

local function updateDefend(o, step, now, roots)
	local site = o.site
	if not site.core then
		return
	end
	if site.phase ~= "running" then
		return
	end
	local hpPct = math.floor(math.max(0, site.hp) / site.maxHP * 100)
	if nearestDist(roots, site.core.Position) <= DEFEND_RADIUS then
		site.elapsed = site.elapsed + step
		if now >= site.nextWave then
			site.nextWave = now + 11
			spawnWave(o)
		end
		setProgress(o, site.elapsed)
		local left = math.max(0, math.ceil(o.goal - site.elapsed))
		setText(o, "Удерживайте зону: " .. left .. " с • прочность " .. hpPct .. "%")
		defendLabel(site, "Прочность " .. hpPct .. "% • " .. left .. " с", GREEN)
	else
		setText(o, "Пауза: вернитесь к объекту • прочность " .. hpPct .. "%")
		defendLabel(site, "ПАУЗА — рядом никого", YELLOW)
	end
	if site.elapsed >= o.goal then
		site.phase = "done"
		defendLabel(site, "РАБОТАЕТ", GREEN)
		complete(o, "Объект работает")
	end
end

-- Тайник -------------------------------------------------------------------------------

local openCache

local function spawnKey(o)
	local site = o.site
	site.keyModel = S.Loot.SpawnItem("cache_key", 1, site.keyCF, site.model)
end

local function buildCache(o, site)
	local model, cf = site.model, site.cf
	-- стоянка пропавшего исследователя: спальник, рюкзак, фонарь и ящик с ключом
	local camp = cf * CF(0, 0, 6)
	deco(model, V3(2, 0.6, 5), camp * CF(2, 0.3, 1) * CFrame.Angles(0, math.rad(30), 0), rgb(90, 80, 60), M.Fabric)
	deco(model, V3(1.6, 2, 1), camp * CF(4.5, 1, -1), rgb(110, 70, 40), M.Fabric)
	local lantern = deco(model, V3(0.6, 1, 0.6), camp * CF(0, 0.5, -2), rgb(255, 220, 120), M.Neon)
	local lanternLight = Instance.new("PointLight")
	lanternLight.Range = 12
	lanternLight.Brightness = 1.2
	lanternLight.Color = rgb(255, 210, 140)
	lanternLight.Parent = lantern
	local boxCF = camp * CF(-3, 0, 1)
	mk(model, V3(3, 2.2, 2), boxCF * CF(0, 1.1, 0), rgb(110, 85, 55), M.WoodPlanks)
	addCircle(boxCF.X, boxCF.Z, 2)
	site.keyCF = boxCF * CF(0, 2.2, 0)
	spawnKey(o)
	site.guardsLeft = scaled(3, o.s / Config.StudsPerKm)

	-- сам тайник
	local ccf = siteCF(o.cachePos or o.pos, o.cacheS or o.s)
	site.chestCF = ccf
	local body = mk(model, V3(4.5, 2.4, 3), ccf * CF(0, 1.2, 0), rgb(80, 55, 35), M.WoodPlanks)
	for _, x in ipairs({ -1.8, 1.8 }) do
		deco(model, V3(0.3, 2.5, 3.1), ccf * CF(x, 1.2, 0), rgb(200, 160, 50), M.Metal)
	end
	deco(model, V3(0.6, 0.6, 0.2), ccf * CF(0, 1.9, -1.6), rgb(255, 200, 60), M.Neon)
	local lid = mk(model, V3(4.7, 0.8, 3.2), ccf * CF(0, 2.8, 0), rgb(70, 48, 30), M.WoodPlanks)
	for k = 1, 3 do
		local rock = ccf * CF(math.cos(k * 2.1) * 5, 0, math.sin(k * 2.1) * 5 + 1)
		mk(model, V3(2.5, 2, 2.2), rock * CF(0, 1, 0) * CFrame.Angles(0.3 * k, k, 0), rgb(110, 105, 100), M.Slate)
	end
	local pole = ccf * CF(3.5, 0, 2)
	mk(model, V3(0.4, 7, 0.4), pole * CF(0, 3.5, 0), rgb(70, 60, 50), M.Wood)
	local flag = deco(model, V3(1.4, 1.4, 1.4), pole * CF(0, 7.4, 0), TYPE_COLORS.cache, M.Neon, { Shape = "Ball" })
	local flagLight = Instance.new("PointLight")
	flagLight.Range = 16
	flagLight.Color = TYPE_COLORS.cache
	flagLight.Parent = flag
	addCircle(ccf.X, ccf.Z, 3.2)
	site.chest = body
	site.lid = lid
	-- навесной замок, окованные рёбра крышки и лопата, прислонённая к сундуку
	deco(model, V3(0.7, 0.8, 0.3), ccf * CF(0, 1.5, -1.72), rgb(150, 140, 100), M.Metal, { CastShadow = false })
	for _, x in ipairs({ -2.2, 2.2 }) do
		deco(model, V3(0.25, 0.25, 3.15), ccf * CF(x, 2.35, 0), rgb(60, 50, 40), M.Metal, { CastShadow = false })
	end
	deco(model, V3(0.25, 4, 0.25), ccf * CF(2.9, 2, -1.9) * CFrame.Angles(0, 0, math.rad(-20)), rgb(96, 74, 50), M.Wood, { CastShadow = false })
	deco(model, V3(1, 1.2, 0.12), ccf * CF(3.55, 0.35, -1.9) * CFrame.Angles(0, 0, math.rad(-20)), rgb(110, 110, 112), M.Metal, { CastShadow = false })
	local prompt = addPrompt(site, body, "Открыть тайник", o.title, 1.5, 10)
	prompt.Triggered:Connect(function(player)
		openCache(o, player)
	end)
end

-- exists (ключ где-то есть), held (ключ у игрока)
local function keyStatus()
	for _, plr in ipairs(Players:GetPlayers()) do
		if S.PlayerData.Count(plr, "cache_key") > 0 then
			return true, true
		end
	end
	local lootFolder = workspace:FindFirstChild("Loot")
	if lootFolder and lootFolder:FindFirstChild("Loot_cache_key") then
		return true, false
	end
	return false, false
end

openCache = function(o, player)
	if o.cancelled or o.state ~= "active" then
		return
	end
	local site = o.site
	if not site or not site.chest or site.opened then
		return
	end
	if not playerRootNear(player, site.chest.Position, 14) then
		return
	end
	if S.PlayerData.Count(player, "cache_key") <= 0 then
		S.PlayerData.Notify(player, "Тайник заперт. Нужен ключ — он где-то неподалёку (метка на карте)", YELLOW)
		return
	end
	if not S.PlayerData.RemoveItem(player, "cache_key", 1) then
		return
	end
	site.opened = true
	local hinge = site.chestCF * CF(0, 3.2, 1.6)
	site.lid.CFrame = hinge * CFrame.Angles(math.rad(70), 0, 0) * CF(0, 0, -1.6)
	local front = site.chestCF * CF(0, 0, -3.5)
	S.Loot.SpawnFromTable("cache", { front, front * CF(1.6, 0, 0), front * CF(-1.6, 0, 0) }, rng, workspace:FindFirstChild("Loot"))
	complete(o, "Тайник открыт")
end

local function updateCache(o, now)
	local site = o.site
	if site.opened or not site.keyCF then
		return
	end
	if o.progress == 0 then
		local key = site.keyModel
		local gone = not key or not key.Parent or key:GetAttribute("Taken") == true
		if gone then
			local exists, held = keyStatus()
			if held then
				site.keyRespawnAt = nil
				setProgress(o, 1)
			elseif not exists then
				site.keyRespawnAt = site.keyRespawnAt or (now + 20)
				if now >= site.keyRespawnAt then
					site.keyRespawnAt = nil
					spawnKey(o)
				end
			end
		end
	else
		local exists = keyStatus()
		if exists then
			site.keyRespawnAt = nil
		else
			site.keyRespawnAt = site.keyRespawnAt or (now + 20)
			if now >= site.keyRespawnAt then
				site.keyRespawnAt = nil
				setProgress(o, 0)
				spawnKey(o)
				S.PlayerData.NotifyAll("Ключ от тайника потерян — новый лежит на прежнем месте", YELLOW)
			end
		end
	end
	if o.progress == 0 then
		setText(o, "Найдите ключ от тайника")
	else
		setText(o, "Ключ найден — откройте тайник неподалёку")
	end
end

-- Активация, пробуждение мест и главный цикл -------------------------------------------

local BUILDERS = {
	collect = buildCollect,
	clear = buildClear,
	rescue = buildRescue,
	elite = buildElite,
	defend = buildDefend,
	cache = buildCache,
}

local lastWarn = 0
local function warnThrottled(text)
	local now = os.clock()
	if now - lastWarn > 5 then
		lastWarn = now
		warn("[Objectives] " .. text)
	end
end

local function buildSite(o)
	local site = newSite(o)
	local builder = BUILDERS[o.type]
	if builder then
		builder(o, site)
	end
end

local function activate(o)
	o.state = "active"
	dirty = true
	local ok, err = pcall(buildSite, o)
	if not ok then
		warnThrottled("место цели " .. o.id .. ": " .. tostring(err))
	end
	S.PlayerData.NotifyAll("Рядом цель: " .. o.title .. " (" .. (ObjectiveDefs.TypeNames[o.type] or "цель") .. ")", YELLOW)
end

local function spawnMissing(o)
	local site = o.site
	local biome = Biomes.List[o.biomeIndex]
	if o.type == "clear" and not site.nestKilled and not aliveRole(site, "nest") then
		local p = site.nestPos or o.pos
		spawnZombie(o, "nest", p, "nest", { home = p, fallback = "brute", fallbackHP = 3 })
	elseif o.type == "elite" and not site.eliteKilled and not aliveRole(site, "elite") then
		local p = (site.cf * CF(0, 0, 8)).Position
		spawnZombie(o, o.def.zombie or "brute", p, "elite", { home = p, elite = true, fallback = "brute", fallbackHP = 2.5 })
	end
	if site.guardsLeft > 0 then
		local rMin, rMax = 8, 26
		if o.type == "rescue" then
			rMin, rMax = 22, 40
		end
		local n = site.guardsLeft
		site.guardsLeft = 0
		for _ = 1, n do
			local p = spawnPoint(o.pos, rMin, rMax, o.s)
			if p then
				spawnZombie(o, Util.Weighted(rng, biome.zombies), p, "guard", { home = p })
			else
				site.guardsLeft = site.guardsLeft + 1
			end
		end
	end
end

local COMBAT_ROLES = { elite = true, nest = true, wave = true }

-- Бой ещё идёт (элиту/гнездо/волну увели от места): спать нельзя, иначе раненый зомби
-- исчезнет и вернётся с полным здоровьем
local function siteInCombat(site, roots, now)
	for _, e in ipairs(site.zombies) do
		local z = e.z
		if COMBAT_ROLES[e.role] and not z.dead and z.root and z.root.Parent then
			if z.target ~= nil or (e.hurtAt and now - e.hurtAt < 15) then
				return true
			end
			if nearestDist(roots, z.root.Position) < SLEEP_PLAYER then
				return true
			end
		end
	end
	return false
end

local function updateSite(o, step, now, roots, busPos)
	local site = o.site
	processZombies(site)

	-- пробуждение/сон: зомби места существуют, только пока рядом кто-то есть
	local pd = nearestDist(roots, o.pos)
	if o.cachePos then
		pd = math.min(pd, nearestDist(roots, o.cachePos))
	end
	if site.root then
		pd = math.min(pd, nearestDist(roots, site.root.Position))
	end
	local bd = busPos and Util.FlatDist(busPos, o.pos) or math.huge
	if not site.awake and (pd < WAKE_PLAYER or bd < WAKE_BUS) then
		site.awake = true
		site.nextSpawnTry = 0
		if o.type == "rescue" and o.state == "active" and not site.survivor then
			local ok, err = pcall(spawnSurvivor, o)
			if not ok then
				warnThrottled("выживший " .. o.id .. ": " .. tostring(err))
			end
		end
	elseif site.awake and pd > SLEEP_PLAYER and bd > SLEEP_BUS and site.leader == nil and not siteInCombat(site, roots, now) then
		site.awake = false
		despawnZombies(o, true)
		if o.type == "rescue" then
			removeTarget(site)
			sleepSurvivor(site)
		end
	end
	if site.awake and o.state == "active" and now >= site.nextSpawnTry then
		site.nextSpawnTry = now + 5
		spawnMissing(o)
	end

	local t = o.type
	if t == "collect" then
		local item = Items.List[o.def.item]
		setText(o, "Собрано " .. o.progress .. " из " .. o.goal .. ": " .. (item and item.name or "предметы"))
	elseif t == "clear" then
		local left = S.Zombies.CountTag(o.tag)
		if site.nestKilled then
			setProgress(o, 1)
			if left <= 0 or now - (site.nestKilledAt or now) > 90 then
				complete(o, "Гнездо уничтожено")
			else
				setText(o, "Гнездо уничтожено! Добейте оставшихся: " .. left)
			end
		elseif site.awake then
			setText(o, "Уничтожьте гнездо • зомби рядом: " .. left)
		else
			setText(o, "Уничтожьте гнездо и его охрану")
		end
	elseif t == "elite" then
		if site.eliteKilled then
			complete(o, "Цель уничтожена")
		else
			local z = aliveRole(site, "elite")
			if z and z.humanoid then
				local pct = math.ceil(z.humanoid.Health / math.max(1, z.humanoid.MaxHealth) * 10) * 10
				setText(o, "Убейте: " .. zombieName(o.def.zombie) .. " • здоровье ~" .. pct .. "%")
			else
				setText(o, "Выследите и убейте: " .. zombieName(o.def.zombie))
			end
		end
	elseif t == "rescue" then
		if o.state == "failed" then
			local left = math.max(0, (site.respawnAt or now) - now)
			if left > 0 then
				setText(o, "Выживший погиб. Новый появится через " .. math.ceil(left / 5) * 5 .. " с")
			elseif not site.awake then
				-- рядом никого: новый выживший появится, когда игроки или автобус вернутся
				setText(o, "Выживший погиб. Новый ждёт на месте цели")
			else
				o.state = "active"
				site.respawnAt = nil
				dirty = true
				local ok, err = pcall(spawnSurvivor, o)
				if not ok then
					warnThrottled("выживший " .. o.id .. ": " .. tostring(err))
				end
				S.PlayerData.NotifyAll("На месте цели «" .. o.title .. "» появился новый выживший", rgb(140, 220, 255))
			end
		elseif not site.survivor then
			-- выживший пропал без гибели (ошибка сборки) — пересоздадим, когда место активно
			if site.awake then
				o.state = "failed"
				site.respawnAt = now + 5
				dirty = true
			end
		elseif not site.leader then
			if pd < 120 then
				survivorTarget(o)
			end
		end
	elseif t == "defend" then
		updateDefend(o, step, now, roots)
	elseif t == "cache" then
		updateCache(o, now)
	end
end

local function logic(step)
	local now = os.clock()
	local roots = activeRoots()
	local busPos = S.Bus.Root and S.Bus.Root.Position
	for _, o in ipairs(list) do
		if o.state == "pending" then
			local bd = busPos and Util.FlatDist(busPos, o.pos) or math.huge
			if bd < ACTIVATE_BUS or nearestDist(roots, o.pos) < ACTIVATE_PLAYER then
				activate(o)
			end
		elseif (o.state == "active" or o.state == "failed") and o.site then
			local ok, err = pcall(updateSite, o, step, now, roots, busPos)
			if not ok then
				warnThrottled(o.id .. ": " .. tostring(err))
			end
		end
	end
end

local function destroySite(o)
	local site = o.site
	if not site then
		return
	end
	removeTarget(site)
	despawnZombies(o, false)
	if site.model and site.model.Parent then
		site.model:Destroy()
	end
	o.site = nil
end

function Obj.Init(services)
	S = services
	folder = workspace:FindFirstChild("Objectives")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Objectives"
		folder.Parent = workspace
	end
	Players.PlayerAdded:Connect(function(player)
		task.delay(4, function()
			if player.Parent then
				sendSync(player)
			end
		end)
	end)
end

function Obj.Clear()
	runToken = runToken + 1
	for _, o in ipairs(list) do
		o.cancelled = true
		destroySite(o)
	end
	list = {}
	byBiome = {}
	placed = false
	wantPlace = false
	S.Obstacles.ClearChunk(OB_CHUNK)
	if folder then
		folder:ClearAllChildren()
	end
	dirty = false
	sendSync()
end

-- Вызывается сразу после World.NewRun (дорога уже есть, чанки ещё не построены)
function Obj.NewRun(seed)
	Obj.Clear()
	runSeed = math.floor(tonumber(seed) or 1)
	if S.World.Road then
		placeAll()
	else
		wantPlace = true
	end
	syncAcc = 0
	logicAcc = 0
	followAcc = 0
	dirty = true
end

function Obj.Update(dt)
	if wantPlace and S.World.Road then
		placeAll()
	end
	if not placed then
		return
	end
	local state = S.Run.State
	if (state == "Depot" or state == "Driving" or state == "Boss") and S.World.Road then
		followAcc = followAcc + dt
		if followAcc >= 0.2 then
			local step = followAcc
			followAcc = 0
			for _, o in ipairs(list) do
				if o.type == "rescue" and o.state == "active" and o.site and o.site.root then
					local ok, err = pcall(updateFollower, o, step)
					if not ok then
						warnThrottled(o.id .. ": " .. tostring(err))
					end
				end
			end
		end
		logicAcc = logicAcc + dt
		if logicAcc >= 0.25 then
			local step = logicAcc
			logicAcc = 0
			logic(step)
		end
	end
	syncAcc = syncAcc + dt
	if (dirty and syncAcc >= 1) or syncAcc >= 2 then
		syncAcc = 0
		dirty = false
		sendSync()
	end
end

return Obj
