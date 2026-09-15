-- Станции: орда -> цели биома -> ворота открываются; торговцы, верстаки, сон.
-- Конечная: арена с боссом (бой начинается только после целей последнего биома).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Progression = require(Shared.Progression)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

-- Состояния станции: pending -> locked (орда) -> waiting (орда зачищена, ждём цели биома) -> clear (ворота открыты)
local St = {
	List = {},
	Final = { state = "pending" },
}

local S
local traders = {}
local rng = Random.new()
local runToken = 0
local lastObjText, lastObjCount = "", 0
local rgb = Color3.fromRGB
local V3 = Vector3.new
local CF = CFrame.new

local GATE_OFFSET = 72
local STATION_MONEY = 50
-- Застрявшая орда: время без единого убийства до призыва орды к игрокам / до принудительной зачистки
local STALL_ALERT = 150
local STALL_ALERT_EVERY = 20
local STALL_FORCE_FEW = 210 -- добить ≤ STALL_FEW отставших
local STALL_FEW = 3
local STALL_FORCE_ALL = 360 -- крайний случай: убрать всех (без награды, если команда не перебила большинство)
local REWARD_KILL_SHARE = 0.6
local GREEN = rgb(120, 230, 140)
local ORANGE = rgb(255, 120, 90)

local function gateHalfWidth()
	return Config.Bounds.HalfWidth + 20
end

function St.Init(services)
	S = services
end

local function pruneTraders()
	for i = #traders, 1, -1 do
		local t = traders[i]
		if not t.part.Parent or not t.prompt.Parent then
			table.remove(traders, i)
		end
	end
end

function St.NewRun()
	runToken = runToken + 1
	St.List = {}
	for i, cfg in ipairs(Config.Stations) do
		St.List[i] = {
			index = i,
			s = cfg.km * Config.StudsPerKm,
			name = cfg.name,
			state = "pending",
			tag = "station" .. i,
			gate = nil,
			traderPrompt = nil,
			toSpawn = 0,
			built = false,
			chunkId = nil,
		}
	end
	St.Final = { state = "pending", s = Config.RouteKm * Config.StudsPerKm, built = false }
	pruneTraders()
	lastObjText, lastObjCount = "", 0
	local st = Net.State()
	st:SetAttribute("Objective", "")
	st:SetAttribute("ObjectiveCount", 0)
	st:SetAttribute("BossActive", false)
end

function St.IsNearStation(s, radius)
	for _, station in ipairs(St.List) do
		if math.abs(s - station.s) < radius and station.state ~= "clear" then
			return true
		end
	end
	return St.Final.s ~= nil and math.abs(s - St.Final.s) < radius + 100
end

-- Сколько станций зачищено от орды (для статистики заезда)
function St.CountCleared()
	local n = 0
	for _, station in ipairs(St.List) do
		if station.state == "waiting" or station.state == "clear" then
			n = n + 1
		end
	end
	return n
end

-- Торговец: подсказка открывает магазин
function St.RegisterTrader(part, info)
	info = info or {}
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "TradePrompt"
	prompt.ActionText = "Торговать"
	prompt.ObjectText = info.name or "Торговец"
	prompt.HoldDuration = 0.2
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Enabled = info.enabled ~= false
	prompt.Parent = part
	prompt.Triggered:Connect(function(player)
		if not S.PlayerData.IsActive(player) or not prompt.Enabled then
			return
		end
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if not root or not part.Parent or (root.Position - part.Position).Magnitude > 16 then
			return
		end
		Net.Get("OpenShop"):FireClient(player, { name = info.name, kind = info.kind })
	end)
	pruneTraders()
	table.insert(traders, { part = part, prompt = prompt })
	-- метка в мире «ТОРГОВЕЦ 46m» (если строитель не задал свою подпись)
	task.defer(function()
		if part.Parent and part:GetAttribute("WaypointLabel") == nil then
			part:SetAttribute("WaypointLabel", info.kind == "merchant" and "ТОРГОВЕЦ" or "МАГАЗИН")
		end
		if part.Parent and not game:GetService("CollectionService"):HasTag(part, "LR_Waypoint") then
			game:GetService("CollectionService"):AddTag(part, "LR_Waypoint")
		end
	end)
	return prompt
end

function St.UnregisterTrader(part)
	for i = #traders, 1, -1 do
		local t = traders[i]
		if t.part == part then
			if t.prompt.Parent then
				t.prompt:Destroy()
			end
			table.remove(traders, i)
		end
	end
end

function St.NearTrader(player)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	for _, t in ipairs(traders) do
		if t.part.Parent and t.prompt.Parent and t.prompt.Enabled and (t.part.Position - root.Position).Magnitude < 16 then
			return true
		end
	end
	return false
end

local function mk(folder, size, cf, color, material, extra)
	local p = Util.Part({ Size = size, CFrame = cf, Color = color, Material = material or Enum.Material.SmoothPlastic, Parent = folder })
	p.CollisionGroup = "World"
	if extra then
		for k, v in pairs(extra) do
			p[k] = v
		end
	end
	return p
end

local function signText(part, text, color, ppu)
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = ppu or 25
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

local M = Enum.Material
local ANG = CFrame.Angles

-- Мелкая деталь: без коллизий, запросов и теней
local function deco(folder, size, cf, color, material, extra)
	local p = mk(folder, size, cf, color, material, extra)
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	return p
end

-- Лампа, которую DayNight включает ночью (тег LR_NightLight)
local function nightLamp(part, offColor)
	part:SetAttribute("NightOffColor", offColor or rgb(122, 120, 112))
	part:SetAttribute("NightOffMaterial", "Glass")
	game:GetService("CollectionService"):AddTag(part, "LR_NightLight")
	return part
end

-- Швы плитки на грани детали
local function tileGrid(part, face, cols, rows, color, transparency)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 8
	gui.LightInfluence = 1
	gui.MaxDistance = 220
	for k = 1, cols - 1 do
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.BackgroundColor3 = color
		f.BackgroundTransparency = transparency
		f.Position = UDim2.fromScale(k / cols, 0)
		f.Size = UDim2.new(0, 1, 1, 0)
		f.Parent = gui
	end
	for k = 1, rows - 1 do
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.BackgroundColor3 = color
		f.BackgroundTransparency = transparency
		f.Position = UDim2.fromScale(0, k / rows)
		f.Size = UDim2.new(1, 0, 0, 1)
		f.Parent = gui
	end
	gui.Parent = part
	return gui
end

-- Табло/плакат: строки текста на грани детали
local function textRows(part, face, rows, glow)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = 30
	gui.LightInfluence = glow and 0 or 1
	if glow then
		gui.Brightness = 1.4
	end
	for _, row in ipairs(rows) do
		local label = Instance.new("TextLabel")
		label.BackgroundTransparency = row.bg and 0 or 1
		if row.bg then
			label.BackgroundColor3 = row.bg
			label.BorderSizePixel = 0
		end
		label.Position = UDim2.fromScale(row.x or 0.04, row.y)
		label.Size = UDim2.fromScale(row.w or 0.92, row.h)
		label.Font = row.font or Enum.Font.RobotoMono
		label.TextScaled = true
		label.TextXAlignment = row.left and Enum.TextXAlignment.Left or Enum.TextXAlignment.Center
		label.TextColor3 = row.color
		label.Text = row.text
		label.Rotation = row.rot or 0
		label.Parent = gui
	end
	gui.Parent = part
	return gui
end

local function roadCF(s, d, y)
	return S.World.Road:CFrameAt(s, d, y or 0, 0)
end

-- Множитель орды: с учётом доли пути (первая станция — небольшая орда), иначе — общий множитель
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

-- Точка внутри или вплотную к автобусу (ревизия №6)
local function nearBus(pos)
	local root = S.Bus.Root
	if not root then
		return false
	end
	if S.Bus.IsInside(pos) or S.Bus.IsInside(pos + V3(0, 3, 0)) then
		return true
	end
	local halfX, halfZ = 12, 30
	local def = S.Bus.TypeDef
	if type(def) == "table" then
		if type(def.width) == "number" then
			halfX = math.max(halfX, def.width / 2 + 6)
		end
		if type(def.length) == "number" then
			halfZ = math.max(halfZ, def.length / 2 + 8)
		end
	end
	local lp = root.CFrame:PointToObjectSpace(pos)
	return math.abs(lp.X) < halfX and math.abs(lp.Z) < halfZ
end

local function buildGate(station, model, chunkId)
	local gateCF = roadCF(station.s + GATE_OFFSET, 0)
	local gateModel = Instance.new("Model")
	gateModel.Name = "Gate"
	gateModel.Parent = model
	for _, x in ipairs({ -16, 16 }) do
		mk(gateModel, V3(1.6, 9, 1.6), gateCF * CF(x, 4.5, 0), rgb(60, 60, 66), Enum.Material.Metal)
		mk(gateModel, V3(2.4, 0.8, 2.4), gateCF * CF(x, 0.4, 0), rgb(96, 96, 92), Enum.Material.Concrete)
		for k = 0, 2 do
			mk(gateModel, V3(1.66, 0.7, 1.66), gateCF * CF(x, 1.6 + k * 2.6, 0), k % 2 == 0 and rgb(220, 50, 40) or rgb(236, 236, 236), Enum.Material.SmoothPlastic, { CastShadow = false })
		end
		local beacon = mk(gateModel, V3(1, 0.8, 1), gateCF * CF(x, 9.4, 0), rgb(255, 60, 40), Enum.Material.Neon, { CastShadow = false })
		local beaconLight = Instance.new("PointLight")
		beaconLight.Range = 14
		beaconLight.Brightness = 1.4
		beaconLight.Color = rgb(255, 70, 50)
		beaconLight.Parent = beacon
	end
	mk(gateModel, V3(32, 1.2, 0.8), gateCF * CF(0, 5, 0), rgb(220, 50, 40), Enum.Material.SmoothPlastic)
	mk(gateModel, V3(32, 1.2, 0.8), gateCF * CF(0, 2.5, 0), rgb(240, 240, 240), Enum.Material.SmoothPlastic)
	local plate = mk(gateModel, V3(12, 3, 0.4), gateCF * CF(0, 7.6, 0.5) * CFrame.Angles(0, math.pi, 0), rgb(30, 30, 34))
	signText(plate, "ЗАКРЫТО", rgb(255, 90, 70))
	-- Забор на всю ширину коридора, чтобы ворота нельзя было объехать
	local half = gateHalfWidth()
	local panel = 46
	for _, side in ipairs({ -1, 1 }) do
		local x = 16
		while x < half do
			local len = math.min(panel, half - x)
			local cx = side * (x + len / 2)
			mk(gateModel, V3(len, 1, 0.6), gateCF * CF(cx, 4.2, 0), rgb(110, 90, 70), Enum.Material.WoodPlanks)
			mk(gateModel, V3(len, 1, 0.6), gateCF * CF(cx, 1.8, 0), rgb(110, 90, 70), Enum.Material.WoodPlanks)
			mk(gateModel, V3(1.2, 6, 1.2), gateCF * CF(side * (x + len), 3, 0), rgb(80, 70, 60), Enum.Material.Wood)
			x = x + len
		end
	end
	local ob = S.Obstacles.AddBox(chunkId, gateCF, half, 1.5, {
		hard = true,
		gate = true,
		gateText = "Ворота закрыты — зачистите станцию!",
		kind = "gate",
	})
	station.gate = { ob = ob, model = gateModel }
end

function St.BuildStation(i, folder, chunkId)
	local station = St.List[i]
	if not station or station.built or not S.World.Road then
		return
	end
	station.built = true
	station.chunkId = chunkId
	local s = station.s
	local model = Instance.new("Model")
	model.Name = "Station_" .. i
	model.Parent = folder

	local base = roadCF(s, 27)
	local r = Random.new(i * 7919 + 13)
	local steel = rgb(64, 66, 70)
	local top = 1.4 -- верх платформы
	-- Платформа справа от дороги: плитка, жёлтый край, тактильная полоса, пандусы на торцах
	local platform = mk(model, V3(22, 1.4, 120), base * CF(0, 0.7, 0), rgb(146, 146, 142), M.Concrete)
	tileGrid(platform, Enum.NormalId.Top, 11, 60, rgb(92, 92, 90), 0.45)
	mk(model, V3(0.6, 1.5, 120), base * CF(-11, 0.75, 0), rgb(230, 200, 40), M.SmoothPlastic)
	deco(model, V3(1.2, 0.06, 118), base * CF(-9.6, top + 0.03, 0), rgb(206, 178, 44), M.Concrete)
	for _, z in ipairs({ -1, 1 }) do
		local ramp = Util.Wedge({ Size = V3(8, 1.4, 6), CFrame = base * CF(4, 0.7, z * 63) * ANG(0, z > 0 and math.pi or 0, 0), Color = rgb(132, 132, 128), Material = M.Concrete, Parent = model })
		ramp.CollisionGroup = "World"
	end
	S.Obstacles.AddBox(chunkId, base, 11.5, 60, { hard = true, kind = "platform" })

	-- Навес: стойки у задней кромки, консоли и подкосы, ржавая кровля с водостоком
	for _, z in ipairs({ -42, -14, 14, 42 }) do
		mk(model, V3(0.9, 12.4, 0.9), base * CF(7, top + 6.2, z), steel, M.Metal)
		deco(model, V3(17, 0.5, 0.5), base * CF(-1, 12.75, z), steel, M.Metal)
		local x0, y0, x1, y1 = 7, 8.6, 1.5, 12.5
		local len = math.sqrt((x1 - x0) ^ 2 + (y1 - y0) ^ 2)
		deco(model, V3(len, 0.35, 0.35), base * CF((x0 + x1) / 2, (y0 + y1) / 2, z) * ANG(0, 0, math.atan2(y1 - y0, x1 - x0)), steel, M.Metal)
	end
	mk(model, V3(20, 0.6, 100), base * CF(-1, 13.3, 0) * ANG(0, 0, math.rad(-2)), rgb(112, 42, 38), M.CorrodedMetal)
	deco(model, V3(0.3, 1, 100), base * CF(-11.1, 13.1, 0), rgb(70, 30, 28), M.Metal)
	deco(model, V3(0.7, 0.5, 100.4), base * CF(9.2, 12.8, 0), rgb(80, 82, 84), M.Metal)
	for k = -2, 2 do
		local lamp = deco(model, V3(1, 0.25, 5), base * CF(-1, 12.3, k * 20 + 7), rgb(255, 238, 206), M.Neon)
		local light = Instance.new("PointLight")
		light.Range = 24
		light.Brightness = 1.3
		light.Color = rgb(255, 226, 180)
		light.Parent = lamp
		nightLamp(lamp)
	end

	-- Табличка с названием (лицом к подъезжающему автобусу) в белой рамке
	local sign = mk(model, V3(20, 3, 0.5), base * CF(1, 15.5, -48) * ANG(0, math.pi, 0), rgb(30, 60, 110), M.SmoothPlastic)
	signText(sign, station.name, rgb(255, 255, 255))
	deco(model, V3(20.6, 3.6, 0.3), sign.CFrame * CF(0, 0, 0.3), rgb(220, 222, 226), M.Metal)

	-- Табло расписания у задней кромки, лицом к дороге
	local board = mk(model, V3(6, 3.6, 0.3), base * CF(8.6, top + 4.2, -30) * ANG(0, math.rad(90), 0), rgb(18, 20, 22), M.Metal)
	for _, x in ipairs({ -2.6, 2.6 }) do
		mk(model, V3(0.3, 5, 0.3), board.CFrame * CF(x, -1.7, 0.3), steel, M.Metal)
	end
	textRows(board, Enum.NormalId.Front, {
		{ text = "РАСПИСАНИЕ", y = 0.04, h = 0.24, color = rgb(255, 176, 70), font = Enum.Font.GothamBlack },
		{ text = "08:15 ГОРОД — ОТМЕНЁН", y = 0.34, h = 0.18, color = rgb(255, 176, 70), left = true },
		{ text = "12:40 ПЕРЕВАЛ — ОТМЕНЁН", y = 0.55, h = 0.18, color = rgb(255, 176, 70), left = true },
		{ text = "--:-- ПОСЛЕДНИЙ РЕЙС", y = 0.76, h = 0.18, color = rgb(255, 90, 60), left = true },
	}, true)

	-- Стенка с объявлениями за спальниками
	local wall = mk(model, V3(0.6, 7, 30), base * CF(9.9, top + 3.5, -5), rgb(120, 116, 108), M.Concrete)
	textRows(wall, Enum.NormalId.Left, {
		{ text = "ЭВАКУАЦИЯ ОТМЕНЕНА", x = 0.06, y = 0.2, w = 0.26, h = 0.34, color = rgb(30, 26, 22), bg = rgb(214, 204, 176), font = Enum.Font.GothamBold, rot = -3 },
		{ text = "НЕ ВЫХОДИТЕ НОЧЬЮ", x = 0.4, y = 0.26, w = 0.22, h = 0.3, color = rgb(240, 236, 226), bg = rgb(150, 36, 30), font = Enum.Font.GothamBlack, rot = 2 },
		{ text = "ПРОПАЛ ПЁС. ЗОВУТ БИМ", x = 0.7, y = 0.18, w = 0.24, h = 0.36, color = rgb(40, 40, 44), bg = rgb(226, 226, 220), font = Enum.Font.GothamBold, rot = -1 },
	}, false)

	-- Спальники под навесом (с подушками)
	for k = 1, 4 do
		local bag = mk(model, V3(3, 0.5, 7), base * CF(6.5, 1.65, -30 + k * 10), rgb(60, 110, 70), M.Fabric)
		deco(model, V3(2.2, 0.4, 1.2), bag.CFrame * CF(0, 0.35, 2.6), rgb(176, 170, 156), M.Fabric)
		S.Sleep.RegisterBed(bag, "station", V3(-3.5, 2.5, 0))
	end

	-- Скамейки со спинками, урны, мусор на платформе
	for _, z in ipairs({ -52, -41, 50 }) do
		local cf = base * CF(7.4, top, z)
		mk(model, V3(1.8, 0.3, 5), cf * CF(0, 1.5, 0), rgb(96, 72, 50), M.WoodPlanks)
		deco(model, V3(0.3, 1.5, 5), cf * CF(0.95, 2.35, 0) * ANG(0, 0, math.rad(-8)), rgb(90, 68, 48), M.WoodPlanks)
		for _, dz in ipairs({ -2, 2 }) do
			deco(model, V3(1.8, 1.4, 0.3), cf * CF(0.1, 0.7, dz), steel, M.Metal)
		end
	end
	for _, z in ipairs({ -46, 30 }) do
		mk(model, V3(2.2, 1.5, 1.5), base * CF(8.8, top + 1.1, z) * ANG(0, 0, math.rad(90)), rgb(46, 64, 50), M.Metal, { Shape = Enum.PartType.Cylinder })
		deco(model, V3(0.25, 1.7, 1.7), base * CF(8.8, top + 2.25, z) * ANG(0, 0, math.rad(90)), rgb(30, 34, 32), M.Metal, { Shape = Enum.PartType.Cylinder })
	end
	for _ = 1, 10 do
		local lcf = base * CF(r:NextNumber(-8, 9), top + 0.05, r:NextNumber(-56, 56)) * ANG(0, r:NextNumber(0, 6.28), 0)
		local kind = r:NextInteger(1, 3)
		if kind == 1 then
			deco(model, V3(0.9, 0.04, 1.2), lcf, rgb(206, 200, 186), M.SmoothPlastic)
		elseif kind == 2 then
			deco(model, V3(0.9, 0.34, 0.34), lcf * CF(0, 0.15, 0), rgb(150, 40, 36), M.Metal, { Shape = Enum.PartType.Cylinder })
		else
			deco(model, V3(1.1, 0.32, 0.32), lcf * CF(0, 0.15, 0), rgb(50, 90, 60), M.Glass, { Shape = Enum.PartType.Cylinder, Transparency = 0.3 })
		end
	end

	-- Перила вдоль задней кромки
	for k = 0, 10 do
		-- за стенкой с объявлениями стойки не нужны
		if k ~= 4 and k ~= 5 then
			deco(model, V3(0.25, 3, 0.25), base * CF(10.7, top + 1.5, -60 + k * 12), steel, M.Metal)
		end
	end
	for _, y in ipairs({ 1.5, 2.9 }) do
		deco(model, V3(0.2, 0.2, 120), base * CF(10.7, top + y, 0), rgb(90, 92, 94), M.Metal)
	end

	-- Автомат и прожекторы на мачтах по краям платформы
	local vend = base * CF(8.6, top, 56)
	mk(model, V3(2.2, 5, 3), vend * CF(0, 2.5, 0), rgb(150, 34, 30), M.Metal)
	deco(model, V3(0.1, 2.8, 1.8), vend * CF(-1.12, 3.1, -0.3), rgb(40, 52, 58), M.Glass, { Transparency = 0.1 })
	deco(model, V3(0.12, 0.2, 2.6), vend * CF(-1.14, 4.7, 0), rgb(120, 220, 255), M.Neon)
	for _, z in ipairs({ -58, 58 }) do
		local mast = base * CF(9.6, top, z)
		mk(model, V3(0.7, 17, 0.7), mast * CF(0, 8.5, 0), steel, M.Metal)
		deco(model, V3(2.6, 1.3, 1.2), mast * CF(-0.6, 17.3, 0) * ANG(0, 0, math.rad(-25)), rgb(40, 42, 44), M.Metal)
		local lens = deco(model, V3(0.2, 1, 2.2), mast * CF(-1.4, 16.9, 0) * ANG(0, 0, math.rad(-25)), rgb(255, 244, 220), M.Neon)
		local spotL = Instance.new("SpotLight")
		spotL.Face = Enum.NormalId.Left
		spotL.Angle = 70
		spotL.Range = 60
		spotL.Brightness = 2
		spotL.Color = rgb(255, 236, 206)
		spotL.Parent = lens
		nightLamp(lens)
	end

	-- Верстак (с тисками, ящиком инструментов и лампой)
	local benchCF = base * CF(-6, 1.4, 34)
	local bench = mk(model, V3(3, 3, 7), benchCF * CF(0, 1.5, 0), rgb(130, 95, 60), M.WoodPlanks)
	mk(model, V3(3.4, 0.3, 7.4), benchCF * CF(0, 3.15, 0), rgb(90, 90, 96), M.Metal)
	mk(model, V3(0.8, 0.8, 1.2), benchCF * CF(0, 3.7, -2.4), rgb(60, 70, 90), M.Metal)
	mk(model, V3(1.6, 0.25, 0.4), benchCF * CF(0.2, 3.45, 1.5), rgb(200, 60, 40), M.SmoothPlastic)
	deco(model, V3(1.2, 0.7, 2), benchCF * CF(0.4, 3.65, 0.2), rgb(150, 36, 30), M.Metal)
	deco(model, V3(2.6, 0.12, 1.6), benchCF * CF(-0.2, 3.36, -0.6) * ANG(0, 0.3, 0), rgb(90, 130, 170), M.SmoothPlastic)
	S.Workbench.RegisterBench(bench, "station")

	-- Торговец в киоске «КАССА»
	local counterCF = base * CF(4, 1.4, 22)
	mk(model, V3(3, 3.5, 10), counterCF * CF(-2.5, 1.75, 0), rgb(120, 85, 55), M.WoodPlanks)
	deco(model, V3(3.2, 0.2, 10.2), counterCF * CF(-2.5, 3.6, 0), rgb(70, 70, 74), M.DiamondPlate)
	mk(model, V3(0.3, 6.8, 11), counterCF * CF(3.3, 3.4, 0), rgb(84, 90, 96), M.CorrodedMetal)
	for _, z in ipairs({ -5.4, 5.4 }) do
		mk(model, V3(5.8, 6.8, 0.3), counterCF * CF(0.4, 3.4, z), rgb(84, 90, 96), M.CorrodedMetal)
	end
	mk(model, V3(7.6, 0.4, 11.6), counterCF * CF(0, 7, 0), rgb(60, 62, 66), M.CorrodedMetal)
	local kassa = deco(model, V3(0.2, 1.2, 5), counterCF * CF(-3.8, 6.3, 0), rgb(24, 26, 30), M.Metal)
	textRows(kassa, Enum.NormalId.Left, { { text = "КАССА", y = 0.08, h = 0.84, color = rgb(120, 220, 255), font = Enum.Font.GothamBlack } }, true)
	local kioskLamp = deco(model, V3(1.2, 0.2, 1.2), counterCF * CF(1.2, 6.7, 0), rgb(255, 232, 190), M.Neon)
	local kioskLight = Instance.new("PointLight")
	kioskLight.Range = 12
	kioskLight.Brightness = 1
	kioskLight.Color = rgb(255, 222, 170)
	kioskLight.Parent = kioskLamp
	local npc = S.Props.MakeNPC(model, counterCF * CF(1, 0, 0) * CFrame.Angles(0, math.rad(90), 0), rgb(60, 100, 160), "Торговец")
	local open = station.state == "waiting" or station.state == "clear"
	station.traderPrompt = St.RegisterTrader(npc, { name = "Торговец · " .. station.name, kind = "station", enabled = open })

	-- Ворота через дорогу после платформы (после полной зачистки не восстанавливаются)
	station.gate = nil
	if station.state ~= "clear" then
		buildGate(station, model, chunkId)
	end
end

function St.OpenGate(station)
	if not station.gate then
		return
	end
	S.Obstacles.Remove(station.gate.ob)
	local model = station.gate.model
	if model and model.Parent then
		for _, p in ipairs(model:GetDescendants()) do
			if p:IsA("BasePart") then
				p.Anchored = false
				p.CanCollide = false
				p.CollisionGroup = "Debris"
				p.AssemblyLinearVelocity = V3(rng:NextNumber(-10, 10), rng:NextNumber(10, 25), rng:NextNumber(-10, 10))
			end
		end
		task.delay(4, function()
			if model.Parent then
				model:Destroy()
			end
		end)
	end
	station.gate = nil
end

-- Выгрузка чанка: станцию/конечную пересоберём при возвращении, состояние сохраняется
function St.OnChunkUnloaded(ci)
	for _, station in ipairs(St.List) do
		if station.built and station.chunkId == ci then
			station.built = false
			station.chunkId = nil
			station.gate = nil
			station.traderPrompt = nil
		end
	end
	if St.Final.built and St.Final.chunkId == ci then
		St.Final.built = false
		St.Final.chunkId = nil
	end
	pruneTraders()
end

function St.BuildFinal(folder, chunkId)
	if St.Final.built or not S.World.Road then
		return
	end
	St.Final.built = true
	St.Final.chunkId = chunkId
	local s = St.Final.s
	local model = Instance.new("Model")
	model.Name = "FinalStop"
	model.Parent = folder
	-- локальная -Z смотрит вперёд по дороге, +Z — назад, к подъезжающему автобусу
	local center = roadCF(s + 40, 0)
	St.Final.center = center.Position

	-- Площадь-арена
	local arena = mk(model, V3(150, 1, 150), center * CF(0, -0.35, 0), rgb(60, 56, 54), Enum.Material.Cobblestone)
	for k = 1, 10 do
		local a = (k / 10) * math.pi * 2
		local p = center * CF(math.cos(a) * 68, 0, math.sin(a) * 68)
		mk(model, V3(3, 14, 3), p * CF(0, 7, 0), rgb(80, 76, 72), Enum.Material.Slate)
		if k % 2 == 0 then
			local fireHolder = mk(model, V3(2, 1, 2), p * CF(0, 14.5, 0), rgb(40, 40, 40), Enum.Material.Metal)
			local fire = Instance.new("Fire")
			fire.Size = 6
			fire.Parent = fireHolder
			local light = Instance.new("PointLight")
			light.Color = rgb(255, 150, 60)
			light.Range = 40
			light.Brightness = 2
			light.Parent = fireHolder
		end
		S.Obstacles.AddCircle(chunkId, p.Position.X, p.Position.Z, 2, { hard = true })
	end

	-- Разрушенный терминал в дальнем конце арены (ревизия №4: впереди по дороге, а не позади)
	local term = center * CF(0, 0, -60)
	mk(model, V3(60, 18, 4), term * CF(0, 9, 0), rgb(90, 90, 96), Enum.Material.Concrete)
	mk(model, V3(64, 2, 20), term * CF(0, 19, 8), rgb(70, 70, 76), Enum.Material.Concrete)
	for _, x in ipairs({ -28, 28 }) do
		mk(model, V3(2, 18, 2), term * CF(x, 9, 16), rgb(80, 80, 86), Enum.Material.Concrete)
	end
	-- Табличка на стороне арены, лицевой гранью к игрокам
	local signPos = (term * CF(0, 24, 2.6)).Position
	local signCF = CFrame.lookAt(signPos, signPos - center.LookVector)
	local sign = mk(model, V3(36, 6, 1), signCF, rgb(20, 20, 24), Enum.Material.SmoothPlastic)
	signText(sign, Config.FinalName, rgb(255, 80, 60), 20)
	S.Obstacles.AddBox(chunkId, term, 32, 3, { hard = true })

	-- Детали арены: пятна и трещины на брусчатке, рамка и лампы вывески, развалины терминала,
	-- старый автобус без колёс, остановка «А», брошенные чемоданы
	local r = Random.new(4242)
	local stains = Instance.new("SurfaceGui")
	stains.Face = Enum.NormalId.Top
	stains.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	stains.PixelsPerStud = 3
	stains.LightInfluence = 1
	stains.MaxDistance = 400
	for k = 1, 24 do
		local f = Instance.new("Frame")
		f.BorderSizePixel = 0
		f.AnchorPoint = Vector2.new(0.5, 0.5)
		f.Position = UDim2.fromScale(r:NextNumber(0.08, 0.92), r:NextNumber(0.08, 0.92))
		f.Rotation = r:NextNumber(0, 180)
		if k <= 12 then
			f.Size = UDim2.fromOffset(r:NextInteger(10, 40), r:NextInteger(8, 26))
			f.BackgroundColor3 = k % 3 == 0 and rgb(70, 16, 14) or rgb(22, 20, 20)
			f.BackgroundTransparency = r:NextNumber(0.35, 0.6)
			local corner = Instance.new("UICorner")
			corner.CornerRadius = UDim.new(0.5, 0)
			corner.Parent = f
		else
			f.Size = UDim2.fromOffset(r:NextInteger(20, 70), 1)
			f.BackgroundColor3 = rgb(24, 22, 20)
			f.BackgroundTransparency = 0.25
		end
		f.Parent = stains
	end
	stains.Parent = arena

	deco(model, V3(37, 7, 0.6), signCF * CF(0, 0, 0.7), rgb(40, 30, 28), M.Metal)
	for _, x in ipairs({ -19.4, 19.4 }) do
		local bulb = deco(model, V3(1.2, 1.2, 1.2), signCF * CF(x, 0, -0.2), rgb(255, 60, 40), M.Neon, { Shape = Enum.PartType.Ball })
		local glow = Instance.new("PointLight")
		glow.Range = 16
		glow.Brightness = 1.6
		glow.Color = rgb(255, 70, 50)
		glow.Parent = bulb
	end

	for _ = 1, 7 do
		local size = r:NextNumber(2, 5)
		mk(model, V3(size, size * 0.6, size * 0.8), term * CF(r:NextNumber(-26, 26), size * 0.3, r:NextNumber(5, 13)) * ANG(r:NextNumber(-0.4, 0.4), r:NextNumber(0, 3), r:NextNumber(-0.3, 0.3)), rgb(96, 96, 100):Lerp(rgb(60, 60, 64), r:NextNumber()), M.Concrete)
	end
	mk(model, V3(22, 1.6, 12), term * CF(-16, 4, 13) * ANG(math.rad(18), 0, math.rad(-12)), rgb(76, 76, 80), M.Concrete)
	S.Obstacles.AddBox(chunkId, term * CF(-16, 0, 13), 11, 6, { hard = true })

	local busCF = center * CF(-46, 0, -4) * ANG(0, math.rad(64), math.rad(4))
	local shell = mk(model, V3(8, 7, 30), busCF * CF(0, 4.6, 0), rgb(150, 92, 40), M.CorrodedMetal)
	for _, face in ipairs({ Enum.NormalId.Left, Enum.NormalId.Right }) do
		local wg = Instance.new("SurfaceGui")
		wg.Face = face
		wg.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
		wg.PixelsPerStud = 10
		wg.LightInfluence = 1
		for k = 0, 6 do
			local w = Instance.new("Frame")
			w.BorderSizePixel = 0
			w.BackgroundColor3 = rgb(16, 18, 20)
			w.Position = UDim2.fromScale(0.05 + k * 0.13, 0.12)
			w.Size = UDim2.fromScale(0.1, 0.38)
			w.Parent = wg
		end
		local stripe = Instance.new("Frame")
		stripe.BorderSizePixel = 0
		stripe.BackgroundColor3 = rgb(30, 28, 26)
		stripe.Position = UDim2.fromScale(0, 0.62)
		stripe.Size = UDim2.fromScale(1, 0.06)
		stripe.Parent = wg
		wg.Parent = shell
	end
	deco(model, V3(8.4, 0.5, 30.4), busCF * CF(0, 8.3, 0), rgb(110, 70, 34), M.CorrodedMetal)
	for _, x in ipairs({ -3.2, 3.2 }) do
		for _, z in ipairs({ -10, 10 }) do
			deco(model, V3(1.6, 1.2, 1.6), busCF * CF(x, 0.6, z), rgb(90, 90, 92), M.Concrete)
		end
	end
	S.Obstacles.AddBox(chunkId, busCF, 4.5, 15.5, { hard = true, kind = "wreck" })

	local shelterCF = center * CF(48, 0, -12) * ANG(0, math.rad(-90), 0)
	for _, x in ipairs({ -4.5, 4.5 }) do
		mk(model, V3(0.4, 8, 0.4), shelterCF * CF(x, 4, 1.4), rgb(60, 62, 66), M.Metal)
	end
	mk(model, V3(10.5, 0.4, 4), shelterCF * CF(0, 8.1, 0.4), rgb(70, 72, 76), M.CorrodedMetal)
	deco(model, V3(9.4, 5, 0.15), shelterCF * CF(0, 4, 1.5), rgb(120, 140, 150), M.Glass, { Transparency = 0.55 })
	mk(model, V3(7, 0.4, 1.4), shelterCF * CF(0, 1.8, 0.7), rgb(90, 70, 50), M.WoodPlanks)
	mk(model, V3(0.3, 9.6, 0.3), shelterCF * CF(6.2, 4.8, 1.6), rgb(60, 62, 66), M.Metal)
	local stopSign = deco(model, V3(2.4, 2.4, 0.2), shelterCF * CF(6.2, 8.6, 1.4), rgb(40, 90, 160), M.Metal)
	textRows(stopSign, Enum.NormalId.Front, { { text = "А", y = 0.1, h = 0.8, color = rgb(255, 255, 255), font = Enum.Font.GothamBlack } }, false)
	S.Obstacles.AddBox(chunkId, shelterCF, 5.5, 2.5, { hard = true })

	local bagColors = { rgb(90, 60, 40), rgb(30, 30, 34), rgb(120, 40, 36) }
	for _ = 1, 5 do
		local h = r:NextNumber(1.2, 1.8)
		deco(model, V3(r:NextNumber(1.6, 2.4), h, 0.7), center * CF(r:NextNumber(-50, 50), 0.15 + h / 2, r:NextNumber(-40, 20)) * ANG(0, r:NextNumber(0, 6.28), 0), bagColors[r:NextInteger(1, #bagColors)], M.Fabric)
	end

	-- Автобус дальше не проедет: барьер на всю ширину коридора до арены
	local endCF = roadCF(s + 10, 0)
	mk(model, V3(40, 3, 2), endCF * CF(0, 1.5, 0), rgb(200, 40, 30), Enum.Material.SmoothPlastic)
	local half = gateHalfWidth()
	local x = 30
	while x < half do
		for _, side in ipairs({ -1, 1 }) do
			mk(model, V3(6, 3, 2.5), endCF * CF(side * x, 1.5, 0), rgb(170, 165, 150), Enum.Material.Concrete)
		end
		x = x + 22
	end
	S.Obstacles.AddBox(chunkId, endCF, half, 1.5, { hard = true, gate = true, gateText = "Это конечная. Дальше только пешком", kind = "gate" })
end

function St.OnBossKilled()
	if St.Final.state == "done" then
		return
	end
	St.Final.state = "done"
	Net.State():SetAttribute("BossActive", false)
	S.Run.Victory()
end

local function setObjective(text, count)
	count = count or 0
	if text == lastObjText and count == lastObjCount then
		return
	end
	lastObjText, lastObjCount = text, count
	local st = Net.State()
	st:SetAttribute("Objective", text)
	st:SetAttribute("ObjectiveCount", count)
end

local function spawnHorde(station, amount)
	local biome = S.World.BiomeAtS(station.s)
	local deferred = 0
	for _ = 1, amount do
		local pos = nil
		for _ = 1, 6 do
			local p = S.World.Road:ToWorld(station.s + rng:NextNumber(-60, GATE_OFFSET - 8), rng:NextNumber(-45, 45))
			if not S.Obstacles.IsBlocked(p.X, p.Z, 3) and not nearBus(p) then
				pos = p
				break
			end
		end
		if pos then
			local z = S.Zombies.Spawn(Util.Weighted(rng, biome.zombies), pos, {
				biome = biome,
				tag = station.tag,
				aggro = false,
				home = pos,
				onDeath = function()
					station.killed = (station.killed or 0) + 1
					station.lastProgress = os.clock()
				end,
			})
			if z then
				station.spawned = (station.spawned or 0) + 1
			end
		else
			deferred = deferred + 1
		end
	end
	station.toSpawn = station.toSpawn + deferred
end

local function eachRunPlayer(fn)
	for _, plr in ipairs(Players:GetPlayers()) do
		if S.PlayerData.Get(plr) then
			fn(plr)
		end
	end
end

local function lockStation(station, nPlayers)
	station.state = "locked"
	station.lockedAt = os.clock()
	station.lastProgress = station.lockedAt
	station.nextAlert = 0
	station.killed = 0
	station.spawned = 0
	local total = math.max(1, math.floor((5 + station.index * 3 + (nPlayers - 1) * 3) * countMult(station.s / Config.StudsPerKm) + 0.5))
	local first = math.ceil(total * 0.6)
	spawnHorde(station, first)
	station.toSpawn = station.toSpawn + (total - first)
	station.nextWave = os.clock() + 12
	Net.Get("Toast"):FireAllClients("СТАНЦИЯ ЗАХВАЧЕНА", station.name .. ": зачистите её, чтобы открыть ворота", ORANGE)
end

-- rewarded=false: орду убрал запасной механизм, а команда не перебила большинство — без наград
local function onHordeCleared(station, rewarded)
	station.state = "waiting"
	station.toSpawn = 0
	if station.traderPrompt and station.traderPrompt.Parent then
		station.traderPrompt.Enabled = true
	end
	local title, sub
	if rewarded ~= false then
		eachRunPlayer(function(plr)
			S.PlayerData.AddMoney(plr, STATION_MONEY)
			S.Profile.AddXP(plr, Progression.XP.stationClear, "station")
			S.Profile.AddTickets(plr, Progression.Tickets.stationClear, "station")
		end)
		title = "СТАНЦИЯ ЗАЧИЩЕНА"
		sub = "+$" .. STATION_MONEY .. ", опыт и билеты каждому. Торговец и верстак открыты"
	else
		title = "СТАНЦИЯ ОСВОБОЖДЕНА"
		sub = "Орда разбрелась — награды нет. Торговец и верстак открыты"
	end
	local done, need, biomeName = S.Objectives.StationRequirement(station.index)
	if done < need then
		sub = sub .. ". Для ворот выполните цели биома «" .. tostring(biomeName) .. "» (" .. done .. "/" .. need .. ")"
	end
	Net.Get("Toast"):FireAllClients(title, sub, GREEN)
end

local function hordeOf(station)
	local out = {}
	for _, z in ipairs(S.Zombies.List()) do
		if z.tag == station.tag and not z.dead then
			table.insert(out, z)
		end
	end
	return out
end

-- Орда долго никого не встречает: зовём её к ближайшему игроку (или к автобусу)
local function alertHorde(station)
	local points = {}
	for _, plr in ipairs(Players:GetPlayers()) do
		local r = plr.Character and plr.Character:FindFirstChild("HumanoidRootPart")
		if r and S.PlayerData.IsAlive(plr) then
			table.insert(points, r.Position)
		end
	end
	if #points == 0 and S.Bus.Root then
		table.insert(points, S.Bus.Root.Position)
	end
	if #points == 0 then
		return
	end
	for _, z in ipairs(hordeOf(station)) do
		if z.root and z.root.Parent and not z.def.stationary then
			local zp = z.root.Position
			local best, bestD = nil, math.huge
			for _, p in ipairs(points) do
				local d = (p - zp).Magnitude
				if d < bestD then
					best, bestD = p, d
				end
			end
			-- своя точка для каждого зомби; home снимается, чтобы не вернулся к платформе
			S.Zombies.AlertTo(z, best)
		end
	end
end

-- Запасной механизм против застрявших зомби. Возвращает nil (ещё рано) или rewarded (bool) после зачистки.
local function stallFallback(station, now, left)
	local stall = now - (station.lastProgress or station.lockedAt or now)
	if stall < STALL_ALERT then
		return nil
	end
	if now >= (station.nextAlert or 0) then
		station.nextAlert = now + STALL_ALERT_EVERY
		alertHorde(station)
	end
	local total = (station.spawned or 0) + (station.toSpawn or 0)
	local mostKilled = total > 0 and (station.killed or 0) >= math.ceil(total * REWARD_KILL_SHARE)
	local force = stall >= STALL_FORCE_ALL or (stall >= STALL_FORCE_FEW and left <= STALL_FEW)
	if not force then
		return nil
	end
	-- Remove, а не Health = 0: не засчитываем убийства зомби, с которыми никто не дрался
	for _, z in ipairs(hordeOf(station)) do
		S.Zombies.Remove(z)
	end
	station.toSpawn = 0
	return mostKilled
end

local function openStation(station)
	station.state = "clear"
	St.OpenGate(station)
	Net.Get("Toast"):FireAllClients("ВОРОТА ОТКРЫТЫ", station.name .. ": путь свободен", GREEN)
end

local function startBoss(final)
	final.state = "boss"
	S.Run.SetState("Boss")
	Net.Get("Toast"):FireAllClients(Config.FinalName, "Выходите из автобуса. Вас встречает Кондуктор...", rgb(255, 80, 60))
	local token = runToken
	task.delay(5, function()
		if token ~= runToken or S.Run.State ~= "Boss" or final.state ~= "boss" then
			return
		end
		final.spawnBoss = true
	end)
end

local function spawnBoss(final)
	final.spawnBoss = false
	local pos = final.center or S.World.Road:ToWorld(final.s + 40, 0)
	final.boss = S.Zombies.Spawn("conductor", pos, { aggro = true, tag = "boss", noDespawn = true })
	if final.boss then
		local st = Net.State()
		st:SetAttribute("BossActive", true)
		st:SetAttribute("BossName", "КОНДУКТОР")
		if not final.bossAnnounced then
			final.bossAnnounced = true
			Net.Get("Toast"):FireAllClients("КОНДУКТОР", "«Ваш билетик, пожалуйста»", rgb(255, 200, 80))
		end
	end
end

local acc = 0
function St.Update(dt)
	acc = acc + dt
	if acc < 0.5 then
		return
	end
	acc = 0
	if not S.Bus.Root or not S.World.Road then
		return
	end
	local runState = S.Run.State
	if runState ~= "Driving" and runState ~= "Boss" then
		if runState == "Depot" then
			setObjective("", 0)
		end
		return
	end
	local busS = S.Bus.S or 0
	local nPlayers = math.max(1, #Players:GetPlayers())
	local now = os.clock()
	local objText, objCount = "", 0

	local nextStation = nil
	for _, station in ipairs(St.List) do
		if station.state == "pending" and busS >= station.s - Config.StationTriggerDistance then
			lockStation(station, nPlayers)
		end
		if station.state == "locked" then
			if station.toSpawn > 0 and now >= station.nextWave then
				local n = station.toSpawn
				station.toSpawn = 0
				spawnHorde(station, n)
				station.nextWave = now + 3
			end
			local left = S.Zombies.CountTag(station.tag) + station.toSpawn
			local rewarded = true
			-- застрявшие зомби не должны блокировать проход навсегда, но ожиданием орду не пропустить:
			-- сперва орда идёт к игрокам, зачистка — только отставших или после долгого простоя
			if left > 0 then
				local res = stallFallback(station, now, left)
				if res ~= nil then
					rewarded = res
					left = 0
				end
			end
			if left <= 0 then
				onHordeCleared(station, rewarded)
			elseif objText == "" then
				objText = "Зачистите " .. station.name
				objCount = left
			end
		end
		if station.state == "waiting" then
			local done, need, biomeName = S.Objectives.StationRequirement(station.index)
			if done >= need then
				openStation(station)
			else
				local text = "Ворота: выполните цели «" .. tostring(biomeName) .. "»"
				if station.gate and station.gate.ob then
					station.gate.ob.gateText = "Ворота закрыты — выполните цели биома (" .. done .. "/" .. need .. ")"
				end
				if objText == "" then
					objText = text
					objCount = need - done
				end
			end
		end
		if not nextStation and station.state ~= "clear" and station.s > busS - 100 then
			nextStation = station
		end
	end

	local st = Net.State()
	if nextStation then
		st:SetAttribute("NextStationKm", Util.Round(nextStation.s / Config.StudsPerKm, 1))
		st:SetAttribute("NextStationName", nextStation.name)
	else
		st:SetAttribute("NextStationKm", Config.RouteKm)
		st:SetAttribute("NextStationName", Config.FinalName)
	end

	-- Конечная: босс только после целей последнего биома
	local final = St.Final
	if final.state == "pending" and busS >= final.s - 170 then
		local done, need, biomeName = S.Objectives.FinalRequirement()
		if done >= need then
			startBoss(final)
		else
			if not final.warned then
				final.warned = true
				Net.Get("Toast"):FireAllClients(Config.FinalName, "Кондуктор не выйдет, пока не выполнены цели биома «" .. tostring(biomeName) .. "» (" .. done .. "/" .. need .. ")", ORANGE)
			end
			if objText == "" then
				objText = "Цели «" .. tostring(biomeName) .. "» для боя с Кондуктором"
				objCount = need - done
			end
		end
	end
	if final.state == "boss" then
		if final.spawnBoss then
			spawnBoss(final)
		end
		local boss = final.boss
		if boss then
			local hum = boss.humanoid
			if boss.dead and hum and hum.Health > 0 and not final.respawnAt then
				-- босс пропал без убийства (упал за карту) — вернём его на арену
				final.respawnAt = now + 3
			end
			if final.respawnAt and now >= final.respawnAt then
				final.respawnAt = nil
				spawnBoss(final)
			elseif not boss.dead and hum then
				st:SetAttribute("BossHP", math.max(0, math.floor(hum.Health)))
				st:SetAttribute("BossMaxHP", math.floor(hum.MaxHealth))
			end
		end
		objText = "Победите Кондуктора"
		objCount = 0
	end
	setObjective(objText, objCount)
end

return St
