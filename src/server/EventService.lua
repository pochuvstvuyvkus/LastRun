-- Случайные события в пути: груз с воздуха, кровавая луна, орда на хвосте,
-- бродячий торговец, засада мародёров, метеоритный дождь
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local EventDefs = require(Shared.Events)
local Progression = require(Shared.Progression)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local Events = {}
local S
local rng = Random.new()
local current = nil
local lastId = nil
local nextKm = math.huge
local bloodMoonOn = false
local fx
local tagCounter = 0

local rgb = Color3.fromRGB
local V3 = Vector3.new
local CF = CFrame.new
local M = Enum.Material
local T = EventDefs.Tuning

local GREEN = rgb(120, 230, 140)
local GREY = rgb(190, 190, 190)

local function fxFolder()
	if not fx or not fx.Parent then
		fx = workspace:FindFirstChild("EventsFX")
		if not fx then
			fx = Instance.new("Folder")
			fx.Name = "EventsFX"
			fx.Parent = workspace
		end
	end
	return fx
end

local function resetAttributes()
	local st = Net.State()
	st:SetAttribute("EventId", "")
	st:SetAttribute("EventTitle", "")
	st:SetAttribute("EventEnd", 0)
	st:SetAttribute("EventPos", nil)
	st:SetAttribute("BloodMoon", false)
end

function Events.Init(services)
	S = services
	fxFolder()
	resetAttributes()
end

function Events.IsBloodMoon()
	return bloodMoonOn
end

-- id текущего события или nil
function Events.Current()
	return current and current.id or nil
end

-- Помощники построения ---------------------------------------------------------------------

local function track(ev, inst)
	table.insert(ev.instances, inst)
	return inst
end

local function part(parent, size, cf, color, material, extra)
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

-- деталь, приваренная к корню (движется вместе с ним)
local function welded(root, parent, size, cf, color, material, extra)
	local p = part(parent, size, cf, color, material, extra)
	p.Anchored = false
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Massless = true
	Util.Weld(root, p)
	return p
end

local function signGui(p, text, color, face)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face or Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.TextScaled = true
	label.Font = Enum.Font.GothamBlack
	label.TextColor3 = color
	label.Text = text
	label.Parent = gui
	gui.Parent = p
end

local function alivePlayers()
	local out = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		local d = S.PlayerData.Get(plr)
		if d and not d.Dead then
			table.insert(out, plr)
		end
	end
	return out
end

local function playerRoot(plr)
	local char = plr.Character
	return char and char:FindFirstChild("HumanoidRootPart")
end

local function nearestPlayerDist(pos)
	local best = math.huge
	for _, plr in ipairs(Players:GetPlayers()) do
		local r = playerRoot(plr)
		if r then
			best = math.min(best, (r.Position - pos).Magnitude)
		end
	end
	return best
end

local function nightSecondsLeft()
	if not S.DayNight.IsNight() then
		return 0
	end
	local hours = (Config.NightEnd - S.DayNight.Clock()) % 24
	return hours * Config.DayLength / 24
end

-- Доля пройденного маршрута: ранние события заметно мягче поздних (v4, плавный рост)
local function progressMult()
	local km = (S.Bus.S or 0) / Config.StudsPerKm
	local p = math.clamp(km / Config.RouteKm, 0, 1)
	return 0.55 + 0.6 * p
end

local function countMult()
	if S.Zombies.HordeMult then
		return S.Zombies.HordeMult()
	end
	return S.Zombies.CountMult() * progressMult()
end

local function newTag(prefix)
	tagCounter = tagCounter + 1
	return prefix .. "_" .. tagCounter
end

local function zombiesWithTag(tag)
	local out = {}
	for _, z in ipairs(S.Zombies.List()) do
		if not z.dead and z.tag == tag then
			table.insert(out, z)
		end
	end
	return out
end

-- Точка у дороги, свободная от препятствий и автобуса
local function findRoadSpot(s, dList, pad, sJitter)
	local road = S.World.Road
	if not road then
		return nil
	end
	for _ = 1, 3 do
		for _, d in ipairs(dList) do
			local ss = s + rng:NextNumber(-(sJitter or 0), sJitter or 0)
			local p = road:ToWorld(ss, d)
			if S.Zombies.IsSpotFree(p, pad) then
				return V3(p.X, 0, p.Z), ss, d
			end
		end
	end
	return nil
end

-- События -----------------------------------------------------------------------------------
-- handler: start(ev) (ev.aborted = true, если не получилось), update(ev, now) -> nil | "success"/"fail", text,
-- timeout(ev) -> "success"/"fail", text  (nil — продлить на 30 с), stop(ev, success), can(km, busS)

local handlers = {}

-- ГРУЗ С ВОЗДУХА
handlers.airdrop = {
	start = function(ev)
		local road = S.World.Road
		local busS = S.Bus.S or 0
		local s = busS + rng:NextNumber(T.airdropAhead[1], T.airdropAhead[2])
		local halfW = (Config.Bounds and Config.Bounds.HalfWidth or 300) - 30
		local side = rng:NextNumber() < 0.5 and -1 or 1
		local dList = {}
		for _ = 1, 4 do
			table.insert(dList, side * rng:NextNumber(T.airdropSide[1], math.min(T.airdropSide[2], halfW)))
			table.insert(dList, -side * rng:NextNumber(T.airdropSide[1], math.min(T.airdropSide[2], halfW)))
		end
		local landing, landS = findRoadSpot(s, dList, 6, 40)
		if not landing then
			ev.aborted = true
			return
		end
		ev.pos = landing
		ev.data.s = landS
		-- зомби у груза не должны исчезать по дальности, пока событие идёт (см. stop)
		ev.tag = newTag("event_airdrop")
		local _, tangent = road:Frame(landS)
		local folder = fxFolder()

		-- Самолёт
		local plane = track(ev, Instance.new("Model"))
		plane.Name = "Airplane"
		local startCF = CFrame.lookAt(landing - tangent * 700 + V3(0, 170, 0), landing + V3(0, 170, 0))
		local body = part(plane, V3(5, 5, 34), startCF, rgb(90, 100, 90), M.Metal, { CanCollide = false, CanQuery = false, CanTouch = false, CastShadow = false })
		welded(body, plane, V3(44, 0.8, 8), startCF * CF(0, 0, 1), rgb(80, 90, 80), M.Metal)
		welded(body, plane, V3(14, 0.6, 4), startCF * CF(0, 0.5, 15), rgb(80, 90, 80), M.Metal)
		welded(body, plane, V3(0.6, 6, 5), startCF * CF(0, 3.5, 15), rgb(80, 90, 80), M.Metal)
		welded(body, plane, V3(4, 3, 4), startCF * CF(0, 0.5, -17), rgb(60, 70, 80), M.Glass)
		for _, x in ipairs({ -12, 12 }) do
			welded(body, plane, V3(2.4, 2.4, 6), startCF * CF(x, -1, 0), rgb(50, 50, 55), M.Metal)
		end
		local beacon = welded(body, plane, V3(0.8, 0.8, 0.8), startCF * CF(0, -2.7, 0), rgb(255, 60, 40), M.Neon)
		local light = Instance.new("PointLight")
		light.Color = rgb(255, 80, 60)
		light.Range = 30
		light.Brightness = 3
		light.Parent = beacon
		plane.PrimaryPart = body
		plane.Parent = folder
		local flyTime = 10
		local endCF = startCF + tangent * 1400
		TweenService:Create(body, TweenInfo.new(flyTime, Enum.EasingStyle.Linear), { CFrame = endCF }):Play()
		task.delay(flyTime + 0.5, function()
			if plane.Parent then
				plane:Destroy()
			end
		end)

		-- Сброс ящика над точкой
		task.delay(flyTime / 2, function()
			if current ~= ev then
				return
			end
			local crate = track(ev, Instance.new("Model"))
			crate.Name = "Airdrop"
			local topCF = CF(landing + V3(0, 160, 0))
			local box = part(crate, V3(4.5, 3.5, 4.5), topCF, rgb(70, 90, 60), M.WoodPlanks, { CanQuery = false })
			welded(box, crate, V3(4.6, 0.5, 4.6), topCF * CF(0, 1, 0), rgb(200, 60, 40), M.SmoothPlastic)
			local lamp = welded(box, crate, V3(0.7, 0.7, 0.7), topCF * CF(0, 2.1, 0), rgb(255, 80, 60), M.Neon)
			local lampLight = Instance.new("PointLight")
			lampLight.Color = rgb(255, 90, 60)
			lampLight.Range = 26
			lampLight.Brightness = 2.5
			lampLight.Parent = lamp
			local chute = {}
			table.insert(chute, welded(box, crate, V3(2.5, 16, 16), topCF * CF(0, 14, 0) * CFrame.Angles(0, 0, math.rad(90)), rgb(240, 240, 235), M.Fabric, { Shape = "Cylinder" }))
			table.insert(chute, welded(box, crate, V3(1, 10, 10), topCF * CF(0, 15.5, 0) * CFrame.Angles(0, 0, math.rad(90)), rgb(220, 60, 50), M.Fabric, { Shape = "Cylinder" }))
			for _, off in ipairs({ { -5, -5 }, { 5, -5 }, { -5, 5 }, { 5, 5 } }) do
				local from = topCF.Position + V3(0, 1.8, 0)
				local to = topCF.Position + V3(off[1], 12.5, off[2])
				local len = (to - from).Magnitude
				table.insert(chute, welded(box, crate, V3(0.12, 0.12, len), CFrame.lookAt((from + to) / 2, to), rgb(200, 200, 200), M.Fabric))
			end
			crate.PrimaryPart = box
			crate.Parent = fxFolder()
			ev.data.crate = crate
			local fallTime = 9
			TweenService:Create(box, TweenInfo.new(fallTime, Enum.EasingStyle.Linear), { CFrame = CF(landing + V3(0, 1.75, 0)) }):Play()
			task.delay(fallTime, function()
				if current ~= ev or not box.Parent then
					return
				end
				for _, c in ipairs(chute) do
					if c.Parent then
						c:Destroy()
					end
				end
				ev.data.landed = true
				table.insert(ev.obstacles, S.Obstacles.AddCircle(nil, landing.X, landing.Z, 3, { hard = true, kind = "airdrop" }))
				Net.Get("Explosion"):FireAllClients(landing + V3(0, 0.5, 0), 6, "airdrop")
				S.PlayerData.NotifyAll("Груз приземлился! Он отмечен на карте", rgb(120, 200, 255))
				S.Zombies.Alert(landing, 260)
				local group = S.Zombies.SpawnGroup(nil, landing, math.floor(T.airdropZombies * countMult() + 0.5), 45, 85, { aggro = true, tag = ev.tag, noDespawn = true })
				for _, z in ipairs(group) do
					z.alertPos = landing
				end

				local prompt = Instance.new("ProximityPrompt")
				prompt.Name = "AirdropPrompt"
				prompt.ActionText = "Вскрыть груз"
				prompt.ObjectText = "Ящик с припасами"
				prompt.HoldDuration = 2.5
				prompt.MaxActivationDistance = 10
				prompt.RequiresLineOfSight = false
				prompt.Parent = box
				prompt.Triggered:Connect(function(player)
					if current ~= ev or ev.data.opened or not prompt.Parent then
						return
					end
					if not S.PlayerData.IsActive(player) then
						return
					end
					local r = playerRoot(player)
					if not r or (r.Position - box.Position).Magnitude > 16 then
						return
					end
					ev.data.opened = true
					ev.data.openedBy = player
					prompt:Destroy()
					local front = CF(landing + V3(0, 0.1, 0))
					local spots = {}
					for i = 1, 6 do
						local a = (i / 6) * math.pi * 2
						table.insert(spots, front * CF(math.cos(a) * 4.5, 0, math.sin(a) * 4.5))
					end
					S.Loot.SpawnFromTable("airdrop", spots, rng, workspace:FindFirstChild("Loot"))
					local helpers = {}
					for _, plr in ipairs(Players:GetPlayers()) do
						local pr = playerRoot(plr)
						if plr == player or (pr and (pr.Position - landing).Magnitude < 90) then
							table.insert(helpers, plr)
						end
					end
					ev.xpPlayers = helpers
				end)
			end)
		end)
	end,
	update = function(ev)
		if ev.data.opened then
			local who = ev.data.openedBy and ev.data.openedBy.DisplayName or "Кто-то"
			ev.linger = 20
			return "success", who .. " вскрыл(а) груз с воздуха!"
		end
		if (S.Bus.S or 0) > (ev.data.s or 0) + 750 and nearestPlayerDist(ev.pos) > 400 then
			return "fail", "Груз остался позади"
		end
		return nil
	end,
	timeout = function(ev)
		if ev.data.landed and nearestPlayerDist(ev.pos) < 60 and not ev.extended then
			ev.extended = true
			return nil
		end
		return "fail", "Груз так и не вскрыли"
	end,
	stop = function(ev)
		-- зомби у груза становятся обычными (исчезнут вдали)
		if not ev.tag then
			return
		end
		for _, z in ipairs(zombiesWithTag(ev.tag)) do
			z.tag = nil
			z.noDespawn = false
		end
	end,
}

-- КРОВАВАЯ ЛУНА
handlers.blood_moon = {
	can = function()
		return nightSecondsLeft() >= 60
	end,
	start = function(ev)
		local duration = math.min(ev.def.duration, nightSecondsLeft())
		if duration < 30 then
			ev.aborted = true
			return
		end
		ev.endsAt = os.clock() + duration
		bloodMoonOn = true
		Net.State():SetAttribute("BloodMoon", true)
		Net.Get("Toast"):FireAllClients("КРОВАВАЯ ЛУНА", "Зомби бешеные. Награды ×2", rgb(255, 70, 60))
	end,
	update = function()
		if not S.DayNight.IsNight() then
			return "success", "Рассвет! Кровавая луна зашла"
		end
		return nil
	end,
	timeout = function()
		return "success", "Вы пережили кровавую луну"
	end,
	stop = function()
		bloodMoonOn = false
		Net.State():SetAttribute("BloodMoon", false)
	end,
}

-- ОРДА НА ХВОСТЕ
handlers.horde_chase = {
	start = function(ev)
		ev.tag = newTag("event_horde")
		ev.data.wavesLeft = T.hordeWaves
		ev.data.total = math.max(6, math.floor(T.hordeCount * countMult() + 0.5) + 3 * (#Players:GetPlayers() - 1))
		ev.data.nextWave = os.clock() + 1
		ev.data.spawned = 0
		ev.pos = S.World.Road:ToWorld((S.Bus.S or 0) - 200, 0)
	end,
	update = function(ev, now)
		local d = ev.data
		local road = S.World.Road
		if d.wavesLeft > 0 and now >= d.nextWave then
			d.wavesLeft = d.wavesLeft - 1
			d.nextWave = now + 8
			local busS = S.Bus.S or 0
			local center = road:ToWorld(busS - rng:NextNumber(170, 210), rng:NextNumber(-25, 25))
			local biome = S.World.BiomeAtS(busS)
			local types = { { "runner", 5 } }
			for _, e in ipairs(biome.zombies) do
				if e[1] ~= "bloater" then
					table.insert(types, { e[1], e[2] * 0.4 })
				end
			end
			local count = math.ceil(d.total / T.hordeWaves)
			local group = S.Zombies.SpawnGroup(types, V3(center.X, 0, center.Z), count, 0, 26, { aggro = true, tag = ev.tag, noDespawn = true, speedMult = 1.3, biome = biome })
			d.spawned = d.spawned + #group
			if S.Bus.Root then
				for _, z in ipairs(group) do
					z.alertPos = S.Bus.Root.Position
				end
			end
			if d.wavesLeft == T.hordeWaves - 1 then
				S.PlayerData.NotifyAll("Орда показалась позади автобуса!", rgb(255, 150, 60))
			end
		end
		local horde = zombiesWithTag(ev.tag)
		if #horde > 0 then
			local sum = Vector3.zero
			for _, z in ipairs(horde) do
				sum = sum + z.root.Position
			end
			ev.pos = V3(sum.X / #horde, 0, sum.Z / #horde)
		end
		if d.wavesLeft <= 0 then
			if #horde == 0 and d.spawned > 0 then
				return "success", "Орда перебита!"
			end
			local busRoot = S.Bus.Root
			if busRoot and #horde > 0 then
				local far = true
				for _, z in ipairs(horde) do
					if (z.root.Position - busRoot.Position).Magnitude < 420 or nearestPlayerDist(z.root.Position) < 300 then
						far = false
						break
					end
				end
				if far then
					return "success", "Автобус оторвался от орды"
				end
			end
		end
		return nil
	end,
	timeout = function()
		if (S.Bus.HP or 1) > 0 then
			return "success", "Орда отстала"
		end
		return "fail", "Орда потрепала автобус"
	end,
	stop = function(ev)
		-- выжившие зомби орды становятся обычными (исчезнут вдали)
		for _, z in ipairs(zombiesWithTag(ev.tag)) do
			z.tag = nil
			z.noDespawn = false
			z.speedMult = nil
		end
	end,
}

-- БРОДЯЧИЙ ТОРГОВЕЦ
local function buildMerchant(ev, cf, side)
	local model = track(ev, Instance.new("Model"))
	model.Name = "MerchantVan"
	local cream = rgb(236, 226, 200)
	part(model, V3(7, 6, 12), cf * CF(0, 3.9, 2), cream, M.SmoothPlastic)
	part(model, V3(7, 4.6, 4.2), cf * CF(0, 3.2, -6.1), cream, M.SmoothPlastic)
	part(model, V3(6.4, 2, 0.2), cf * CF(0, 4.3, -8.25), rgb(40, 60, 80), M.Glass)
	part(model, V3(7.1, 0.8, 12.1), cf * CF(0, 4.8, 2), rgb(200, 60, 40), M.SmoothPlastic, { CanCollide = false })
	for _, z in ipairs({ -5.5, 5.5 }) do
		for _, x in ipairs({ -3.5, 3.5 }) do
			part(model, V3(0.9, 2.6, 2.6), cf * CF(x, 1.3, z), rgb(30, 30, 32), M.SmoothPlastic, { Shape = "Cylinder", CanCollide = false })
		end
	end
	-- навес и прилавок со стороны дороги
	part(model, V3(4.5, 0.3, 11), cf * CF(side * 5.6, 6.6, 2) * CFrame.Angles(0, 0, math.rad(side * -12)), rgb(230, 190, 60), M.Fabric, { CanCollide = false })
	part(model, V3(1.6, 3, 8), cf * CF(side * 4.4, 1.5, 2), rgb(130, 90, 55), M.WoodPlanks)
	for i = 1, 4 do
		part(model, V3(1, 1, 1), cf * CF(side * 4.4, 3.5, -1 + i * 1.5), Color3.fromHSV(rng:NextNumber(), 0.6, 0.9), M.SmoothPlastic, { CanCollide = false })
	end
	local lamp = part(model, V3(0.8, 0.8, 0.8), cf * CF(side * 5.8, 6.0, 2), rgb(255, 230, 170), M.Neon, { CanCollide = false })
	local light = Instance.new("PointLight")
	light.Color = rgb(255, 220, 160)
	light.Range = 32
	light.Brightness = 2
	light.Parent = lamp
	local board = part(model, V3(6.5, 1.8, 0.3), cf * CF(0, 7.8, 2) * CFrame.Angles(0, math.rad(side * 90), 0), rgb(40, 30, 20), M.Wood, { CanCollide = false })
	signGui(board, "ТОРГОВЕЦ", rgb(255, 220, 90), Enum.NormalId.Front)
	signGui(board, "ТОРГОВЕЦ", rgb(255, 220, 90), Enum.NormalId.Back)

	-- сам торговец
	local npcCF = cf * CF(side * 6.6, 0, 2) * CFrame.Angles(0, -side * math.pi / 2, 0)
	local skin = rgb(210, 170, 130)
	local noCollide = { CanCollide = false }
	local torso = part(model, V3(2, 2, 1), npcCF * CF(0, 3, 0), rgb(120, 70, 140), M.Fabric, noCollide)
	local head = part(model, V3(2, 1, 1), npcCF * CF(0, 4.5, 0), skin, M.SmoothPlastic, noCollide)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Head
	mesh.Scale = V3(1.25, 1.25, 1.25)
	mesh.Parent = head
	part(model, V3(1, 2, 1), npcCF * CF(-1.5, 3, 0), skin, M.SmoothPlastic, noCollide)
	part(model, V3(1, 2, 1), npcCF * CF(1.5, 3, 0), skin, M.SmoothPlastic, noCollide)
	part(model, V3(1, 2, 1), npcCF * CF(-0.5, 1, 0), rgb(60, 50, 40), M.Fabric, noCollide)
	part(model, V3(1, 2, 1), npcCF * CF(0.5, 1, 0), rgb(60, 50, 40), M.Fabric, noCollide)
	part(model, V3(2.6, 0.2, 2.6), npcCF * CF(0, 5.1, 0), rgb(90, 60, 30), M.Fabric, noCollide)
	part(model, V3(1.4, 0.7, 1.4), npcCF * CF(0, 5.5, 0), rgb(90, 60, 30), M.Fabric, noCollide)
	local bb = Instance.new("BillboardGui")
	bb.Size = UDim2.fromOffset(220, 40)
	bb.StudsOffset = V3(0, 2.4, 0)
	bb.MaxDistance = 90
	bb.Adornee = head
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "Бродячий торговец"
	label.TextColor3 = rgb(255, 220, 90)
	label.TextStrokeTransparency = 0.3
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = bb
	bb.Parent = head
	model.Parent = fxFolder()
	return torso
end

handlers.merchant = {
	can = function(_, busS)
		return not S.Stations.IsNearStation(busS + T.merchantAhead, 500)
	end,
	start = function(ev)
		local road = S.World.Road
		local busS = S.Bus.S or 0
		local side = rng:NextNumber() < 0.5 and -1 or 1
		local offset = Config.RoadHalfWidth + 11
		local spot, s, d = findRoadSpot(busS + T.merchantAhead, { side * offset, -side * offset, side * (offset + 8), -side * (offset + 8) }, 9, 30)
		if not spot then
			ev.aborted = true
			return
		end
		local cf = road:CFrameAt(s, d, 0, 0)
		-- навес и торговец — со стороны дороги (локальная +X совпадает с направлением +d)
		local awningSide = d > 0 and -1 or 1
		local trader = buildMerchant(ev, cf, awningSide)
		table.insert(ev.obstacles, S.Obstacles.AddBox(nil, cf, 4, 8.8, { hard = true, kind = "merchant" }))
		S.Stations.RegisterTrader(trader, { name = "Бродячий торговец", kind = "merchant" })
		ev.pos = spot
		ev.data.s = s
		ev.data.trader = trader
		ev.visitors = {}
	end,
	update = function(ev)
		local trader = ev.data.trader
		if trader and trader.Parent then
			for _, plr in ipairs(Players:GetPlayers()) do
				local r = playerRoot(plr)
				if r and (r.Position - trader.Position).Magnitude < 22 and not ev.visitors[plr] then
					ev.visitors[plr] = true
				end
			end
		end
		if (S.Bus.S or 0) > (ev.data.s or 0) + 900 and nearestPlayerDist(ev.pos) > 500 then
			return next(ev.visitors) and "success" or "fail", "Торговец остался позади"
		end
		return nil
	end,
	timeout = function(ev)
		if next(ev.visitors) then
			return "success", "Торговец собрал товар и уехал"
		end
		return "fail", "Торговец уехал, никого не дождавшись"
	end,
	stop = function(ev)
		local list = {}
		for plr in pairs(ev.visitors or {}) do
			if plr.Parent then
				table.insert(list, plr)
			end
		end
		ev.xpPlayers = list
	end,
}

-- ЗАСАДА МАРОДЁРОВ
local function buildBarricade(ev, cf)
	local model = track(ev, Instance.new("Model"))
	model.Name = "RaiderBarricade"
	local half = Config.RoadHalfWidth + 3
	local x = -half
	while x <= half do
		part(model, V3(3.8, 1.6, 2.2), cf * CF(x, 0.8, 0) * CFrame.Angles(0, math.rad(rng:NextNumber(-6, 6)), 0), rgb(150, 130, 90), M.Fabric)
		if math.abs(x) > 4 then
			part(model, V3(3.6, 1.5, 2), cf * CF(x + 1.5, 2.35, 0.1), rgb(140, 120, 84), M.Fabric)
		end
		x = x + 4
	end
	-- остов машины и бочки с огнём
	part(model, V3(6, 3.4, 12), cf * CF(-6, 1.7, 5) * CFrame.Angles(0, math.rad(70), math.rad(8)), rgb(90, 60, 50), M.CorrodedMetal)
	for _, bx in ipairs({ -half - 2, half + 2 }) do
		local barrel = part(model, V3(3, 2.4, 2.4), cf * CF(bx, 1.5, 1.5) * CFrame.Angles(0, 0, math.rad(90)), rgb(70, 60, 50), M.CorrodedMetal, { Shape = "Cylinder" })
		local fire = Instance.new("Fire")
		fire.Size = 5
		fire.Heat = 8
		fire.Parent = barrel
		local light = Instance.new("PointLight")
		light.Color = rgb(255, 140, 60)
		light.Range = 26
		light.Brightness = 2
		light.Parent = barrel
	end
	-- шипы и флаг
	for i = -3, 3 do
		part(model, V3(0.4, 2.2, 0.4), cf * CF(i * 4 + 2, 1.1, -1.8) * CFrame.Angles(math.rad(-40), 0, 0), rgb(120, 110, 100), M.Metal, { CanCollide = false })
	end
	part(model, V3(0.4, 12, 0.4), cf * CF(half - 1, 6, 1), rgb(60, 50, 40), M.Wood)
	part(model, V3(0.2, 3, 5), cf * CF(half - 1, 10.5, 3.5), rgb(160, 30, 30), M.Fabric, { CanCollide = false })
	model.Parent = fxFolder()
	return model
end

handlers.raiders = {
	can = function(_, busS)
		return not S.Stations.IsNearStation(busS + T.raidersAhead, 700)
	end,
	start = function(ev)
		local road = S.World.Road
		local busS = S.Bus.S or 0
		local s = busS + T.raidersAhead
		local cf = road:CFrameAt(s, 0, 0, 0)
		local barricade = buildBarricade(ev, cf)
		table.insert(ev.obstacles, S.Obstacles.AddBox(nil, cf, Config.RoadHalfWidth + 3, 2.5, { hard = false, model = barricade, kind = "barricade", damageMult = 3 }))
		ev.tag = newTag("event_raiders")
		ev.pos = cf.Position
		ev.data.s = s
		ev.data.cf = cf
		local biome = S.World.BiomeAtS(s)
		local n = math.floor(T.raidersCount * countMult() + 0.5) + (#Players:GetPlayers() - 1)
		local spawned = 0
		-- укрытия отдельно от баррикады (баррикаду автобус может снести)
		local covers = track(ev, Instance.new("Model"))
		covers.Name = "RaiderCovers"
		covers.Parent = fxFolder()
		for i = 1, n + 4 do
			if spawned >= n then
				break
			end
			local side = i % 2 == 0 and 1 or -1
			local p = road:ToWorld(s + rng:NextNumber(8, 55), side * rng:NextNumber(Config.RoadHalfWidth + 4, 60))
			if S.Zombies.IsSpotFree(p, 3) then
				local pos = V3(p.X, 0, p.Z)
				local leader = spawned == 0
				local z = S.Zombies.Spawn("raider", pos, {
					biome = biome,
					tag = ev.tag,
					home = pos,
					noDespawn = true,
					elite = leader,
					hpMult = leader and 0.6 or 1,
					name = leader and "Главарь мародёров" or nil,
				})
				if z then
					spawned = spawned + 1
					-- укрытие рядом
					local coverCF = CFrame.lookAt(pos, cf.Position) * CF(0, 1.5, -3.5)
					part(covers, V3(4, 3, 1.4), coverCF, rgb(110, 90, 60), M.WoodPlanks)
				end
			end
		end
		if spawned == 0 then
			ev.aborted = true
		end
	end,
	update = function(ev)
		local alive = S.Zombies.CountTag(ev.tag)
		if alive == 0 then
			local base = ev.data.cf
			local spots = {}
			for i = 1, 4 do
				table.insert(spots, base * CF(-6 + i * 3, 0.1, 6))
			end
			S.Loot.SpawnFromTable("military_wreck", spots, rng, workspace:FindFirstChild("Loot"))
			ev.linger = 40
			return "success", "Мародёры перебиты! Их припасы у баррикады"
		end
		if (S.Bus.S or 0) > ev.data.s + 650 and nearestPlayerDist(ev.pos) > 400 then
			return "fail", "Засада осталась позади"
		end
		return nil
	end,
	timeout = function(ev)
		if nearestPlayerDist(ev.pos) < 200 and (ev.extensions or 0) < 3 then
			ev.extensions = (ev.extensions or 0) + 1
			return nil
		end
		return "fail", "Мародёры ушли"
	end,
	stop = function(ev)
		for _, z in ipairs(zombiesWithTag(ev.tag)) do
			S.Zombies.Remove(z)
		end
	end,
}

-- МЕТЕОРИТНЫЙ ДОЖДЬ
handlers.meteor_shower = {
	start = function(ev)
		ev.data.nextMeteor = os.clock() + 2
		if S.Bus.Root then
			ev.pos = S.Bus.Root.Position
		end
	end,
	update = function(ev, now)
		local busRoot = S.Bus.Root
		if busRoot then
			ev.pos = busRoot.Position
		end
		if now < ev.data.nextMeteor then
			return nil
		end
		ev.data.nextMeteor = now + rng:NextNumber(T.meteorInterval[1], T.meteorInterval[2])
		local centers = {}
		for _, plr in ipairs(alivePlayers()) do
			local r = playerRoot(plr)
			if r then
				table.insert(centers, r.Position)
			end
		end
		if busRoot and (#centers == 0 or rng:NextNumber() < 0.3) then
			table.insert(centers, busRoot.Position)
		end
		if #centers == 0 then
			return nil
		end
		local c = centers[rng:NextInteger(1, #centers)]
		local a = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(4, 45)
		local ground = V3(c.X + math.cos(a) * r, 0.3, c.Z + math.sin(a) * r)
		local radius = T.meteorRadius
		-- круг "meteor_warn" на клиенте живёт 2.2 с: метеорит падает, пока круг ещё виден
		Net.FireNear("Explosion", ground, 700, ground, radius, "meteor_warn")
		local origin = ground + V3(rng:NextNumber(-45, 45), 160, rng:NextNumber(-45, 45))
		local flight = 2.0
		local damage = T.meteorDamage * S.Zombies.GetScale().damage
		S.Projectiles.Fire({
			kind = "meteor",
			origin = origin,
			velocity = (ground - origin) / flight,
			gravity = 0,
			damage = 0,
			hostile = true, -- сталкивается с автобусом и игроками (урон — взрывом при падении)
			hitsPlayers = false,
			hitsZombies = false,
			maxTime = flight + 1,
			onImpact = function(hitPos)
				local p = hitPos
				if typeof(p) ~= "Vector3" or p.Y < -5 or p.Y > 40 then
					p = ground
				end
				S.Combat.Explode(p, radius, damage, { kind = "meteor", hurtPlayers = true, hurtZombies = true, busMult = 0.35 })
				if rng:NextNumber() < T.meteorLootChance then
					S.Loot.SpawnFromTable("meteor", { CF(V3(p.X, 0.1, p.Z)) }, rng, workspace:FindFirstChild("Loot"))
				end
			end,
		})
		return nil
	end,
	timeout = function()
		return "success", "Метеоритный дождь закончился"
	end,
}

-- Жизненный цикл ----------------------------------------------------------------------------

local function cleanup(ev, immediate)
	for _, ob in ipairs(ev.obstacles) do
		S.Obstacles.Remove(ob)
	end
	ev.obstacles = {}
	local instances = ev.instances
	ev.instances = {}
	local function destroyAll()
		for _, inst in ipairs(instances) do
			if inst.Parent then
				inst:Destroy()
			end
		end
	end
	if immediate or not ev.linger or ev.linger <= 0 then
		destroyAll()
	else
		task.delay(ev.linger, destroyAll)
	end
end

local function setEventAttributes(ev)
	local st = Net.State()
	st:SetAttribute("EventId", ev.id)
	st:SetAttribute("EventTitle", ev.def.title)
	st:SetAttribute("EventEnd", Util.Now() + math.max(0, ev.endsAt - os.clock()))
	if typeof(ev.pos) == "Vector3" then
		st:SetAttribute("EventPos", ev.pos)
	end
end

local function start(id)
	local def = EventDefs.List[id]
	local h = handlers[id]
	if not def or not h then
		return false
	end
	local now = os.clock()
	local ev = {
		id = id,
		def = def,
		startedAt = now,
		endsAt = now + def.duration,
		data = {},
		instances = {},
		obstacles = {},
	}
	current = ev
	local ok, err = pcall(h.start, ev)
	if not ok or ev.aborted then
		if not ok then
			warn("[Events] " .. id .. ": " .. tostring(err))
		end
		current = nil
		pcall(function()
			if h.stop then
				h.stop(ev, false)
			end
		end)
		cleanup(ev, true)
		return false
	end
	lastId = id
	setEventAttributes(ev)
	Net.Get("EventBanner"):FireAllClients({
		id = id,
		title = def.title,
		text = def.text,
		color = def.color,
		duration = math.floor(ev.endsAt - now + 0.5),
		pos = ev.pos,
	})
	return true
end

local function finish(success, text)
	local ev = current
	if not ev then
		return
	end
	current = nil
	local h = handlers[ev.id]
	if h and h.stop then
		local ok, err = pcall(h.stop, ev, success)
		if not ok then
			warn("[Events] stop " .. ev.id .. ": " .. tostring(err))
		end
	end
	cleanup(ev, false)
	resetAttributes()
	if bloodMoonOn then
		Net.State():SetAttribute("BloodMoon", true)
	end
	if success then
		local receivers = ev.xpPlayers or alivePlayers()
		for _, plr in ipairs(receivers) do
			if plr.Parent and S.PlayerData.Get(plr) then
				S.Profile.AddXP(plr, Progression.XP.event, "event")
			end
		end
		if #receivers > 0 then
			text = (text or "") .. "  (+" .. Progression.XP.event .. " опыта)"
		end
	end
	Net.Get("EventBanner"):FireAllClients({
		id = ev.id,
		title = ev.def.title,
		text = text or "",
		color = success and GREEN or GREY,
		duration = 6,
		ended = true,
		success = success == true,
	})
	-- следующее событие — через MinGap..MaxGap км после окончания этого
	local km = (S.Bus.S or 0) / Config.StudsPerKm
	nextKm = km + rng:NextNumber(Config.Events.MinGapKm, Config.Events.MaxGapKm)
end

local function abort()
	local ev = current
	if not ev then
		return
	end
	current = nil
	local h = handlers[ev.id]
	if h and h.stop then
		pcall(h.stop, ev, false)
	end
	cleanup(ev, true)
	Net.Get("EventBanner"):FireAllClients({ id = ev.id, ended = true, silent = true })
end

function Events.NewRun(seed)
	Events.Clear()
	rng = Random.new((tonumber(seed) or os.time()) % 1000000 + 7331)
	lastId = nil
	nextKm = Config.Events.StartKm + rng:NextNumber(0, 1.5)
end

function Events.Clear()
	abort()
	bloodMoonOn = false
	lastId = nil
	nextKm = Config.Events.StartKm + rng:NextNumber(0, 1.5)
	resetAttributes()
	for _, child in ipairs(fxFolder():GetChildren()) do
		child:Destroy()
	end
end

local function pickEvent(km, busS)
	local night = S.DayNight.IsNight()
	local candidates = {}
	for _, id in ipairs(EventDefs.Order) do
		local def = EventDefs.List[id]
		local h = handlers[id]
		if def and h and id ~= lastId and km >= (def.minKm or 0) and (not def.nightOnly or night) then
			if not h.can or h.can(km, busS) then
				local weight = def.weight or 1
				if def.nightOnly then
					weight = weight * 1.5
				end
				table.insert(candidates, { id, weight })
			end
		end
	end
	return Util.Weighted(rng, candidates)
end

-- Запустить событие вручную (для отладки и целей), true — если получилось
function Events.Start(id)
	if current or type(id) ~= "string" or not S.World.Road then
		return false
	end
	return start(id)
end

local acc = 0
local posAcc = 0
function Events.Update(dt)
	acc = acc + dt
	if acc < 0.25 then
		return
	end
	local step = acc
	acc = 0
	local state = S.Run.State
	if state ~= "Driving" and state ~= "Boss" then
		if current and state ~= "Depot" then
			abort()
			resetAttributes()
			bloodMoonOn = false
		end
		return
	end
	if not S.World.Road or not S.Bus.Root then
		return
	end
	local now = os.clock()

	if current then
		local ev = current
		local h = handlers[ev.id]
		local ok, result, text = pcall(h.update, ev, now, step)
		if not ok then
			warn("[Events] update " .. ev.id .. ": " .. tostring(result))
			finish(false, "Событие прервано")
			return
		end
		if result then
			finish(result == "success", text)
			return
		end
		if now >= ev.endsAt then
			local okT, r2, t2 = pcall(h.timeout, ev)
			if okT and r2 == nil then
				ev.endsAt = now + 30
				setEventAttributes(ev)
			else
				finish(okT and r2 == "success", okT and t2 or "")
			end
			return
		end
		posAcc = posAcc + step
		if posAcc >= 1 then
			posAcc = 0
			if typeof(ev.pos) == "Vector3" then
				Net.State():SetAttribute("EventPos", ev.pos)
			end
		end
		return
	end

	if state ~= "Driving" then
		return
	end
	local busS = S.Bus.S or 0
	local km = busS / Config.StudsPerKm
	if km < nextKm then
		return
	end
	if S.Stations.IsNearStation(busS, 450) then
		nextKm = km + 0.4
		return
	end
	local id = pickEvent(km, busS)
	if not id or not start(id) then
		nextKm = km + 0.5
	else
		nextKm = math.huge
	end
end

return Events
