-- Генерация мира кусками (чанками) вдоль дороги вокруг автобуса и игроков,
-- границы карты и страховка от выхода за них, резервирование мест целей,
-- память чанков (подобранная добыча и сработавшие спавнеры не возвращаются при повторной загрузке)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Biomes = require(Shared.Biomes)
local RoadPath = require(Shared.RoadPath)
local Net = require(Shared.Net)

local Bounds = Config.Bounds

local World = {
	Road = nil,
	Seed = 1,
	FinalS = Config.RouteKm * Config.StudsPerKm,
}

local S
local chunks = {}
local worldFolder
local horizon
local lastBiomeId = nil
local horizonAcc = 0
local safetyAcc = 0
local reserves = {} -- { {s, d, r, x, z} }
local lootTaken = {}
local spawnerUsed = {}
local playerS = {} -- [player] = последняя известная s игрока
local warnedAt = {} -- [player] = os.clock() последнего уведомления

local PLAYER_KEEP = 260 -- чанки вокруг игроков, ушедших от автобуса, не выгружаются

function World.Init(services)
	S = services
	worldFolder = workspace:WaitForChild("World")
	Players.PlayerRemoving:Connect(function(player)
		playerS[player] = nil
		warnedAt[player] = nil
	end)
end

function World.BiomeAtS(s)
	return Biomes.AtKm((s or 0) / Config.StudsPerKm)
end

function World.KmAtS(s)
	return (s or 0) / Config.StudsPerKm
end

-- Координаты дороги (s, d) для точки мира. Надёжнее одного Project: если ближайшая
-- точка оказалась у края окна поиска, поиск повторяется вокруг уточнённой s.
function World.Locate(pos, hintS)
	local road = World.Road
	if not road or typeof(pos) ~= "Vector3" then
		return 0, 0
	end
	-- подсказка за концом дороги сломала бы Project (выход за массив точек)
	local maxHint = (road.length or (World.FinalS + 800)) + 2000
	local function project(hint)
		return road:Project(pos, math.clamp(hint, 0, maxHint), 400)
	end
	local s, d = project(tonumber(hintS) or 0)
	for _ = 1, 4 do
		local p, t, r = road:Frame(s)
		local rx, rz = pos.X - p.X, pos.Z - p.Z
		local along = rx * t.X + rz * t.Z
		if math.abs(along) <= 12 then
			break
		end
		if s <= 1 and along < 0 then
			-- позади начала дороги: там она прямая
			return s + along, rx * r.X + rz * r.Z
		end
		s, d = project(s + along)
	end
	return s, d
end

function World.MinS()
	return Bounds.BackS
end

function World.MaxS()
	return World.FinalS + Bounds.FrontExtra
end

-- inside, s, d
function World.IsInsideBounds(pos, hintS)
	if not World.Road or typeof(pos) ~= "Vector3" then
		return true, 0, 0
	end
	local s, d = World.Locate(pos, hintS)
	local inside = math.abs(d) <= Bounds.HalfWidth and s >= World.MinS() and s <= World.MaxS()
	return inside, s, d
end

-- Ближайшая точка внутри границ (высота Y сохраняется)
function World.ClampToBounds(pos, hintS)
	if not World.Road or typeof(pos) ~= "Vector3" then
		return pos
	end
	local s, d = World.Locate(pos, hintS)
	local cs = math.clamp(s, World.MinS(), World.MaxS())
	local cd = math.clamp(d, -Bounds.HalfWidth, Bounds.HalfWidth)
	if cs == s and cd == d then
		return pos
	end
	local p = World.Road:ToWorld(cs, cd)
	return Vector3.new(p.X, pos.Y, p.Z)
end

-- Резервирование мест целей: Props не ставит здания и крупные объекты в этих кругах
function World.ReserveArea(s, d, radius)
	if type(s) ~= "number" or type(d) ~= "number" then
		return
	end
	table.insert(reserves, { s = s, d = d, r = tonumber(radius) or 45 })
end

function World.IsReserved(pos, radius)
	if #reserves == 0 or not World.Road then
		return false
	end
	radius = radius or 0
	for _, rv in ipairs(reserves) do
		if not rv.x then
			local p = World.Road:ToWorld(rv.s, rv.d)
			rv.x = p.X
			rv.z = p.Z
		end
		local dx = pos.X - rv.x
		local dz = pos.Z - rv.z
		local rr = rv.r + radius
		if dx * dx + dz * dz < rr * rr then
			return true
		end
	end
	return false
end

function World.GetReserves()
	return reserves
end

-- Память чанков ------------------------------------------------------------------------
function World.IsLootTaken(key)
	return key ~= nil and lootTaken[key] == true
end

function World.MarkLootTaken(key)
	if key ~= nil then
		lootTaken[key] = true
	end
end

function World.IsSpawnerUsed(key)
	return key ~= nil and spawnerUsed[key] == true
end

function World.MarkSpawnerUsed(key)
	if key ~= nil then
		spawnerUsed[key] = true
	end
end

-- Чанки ---------------------------------------------------------------------------------
local function unloadChunk(ci)
	local f = chunks[ci]
	chunks[ci] = nil
	if f then
		f:Destroy()
	end
	S.Obstacles.ClearChunk(ci)
	S.Zombies.ClearChunk(ci)
	if S.Stations.OnChunkUnloaded then
		S.Stations.OnChunkUnloaded(ci)
	end
end

function World.Clear()
	for ci in pairs(chunks) do
		unloadChunk(ci)
	end
	chunks = {}
	if S then
		S.Obstacles.ClearChunk("depot")
		S.Obstacles.ClearChunk("bounds")
	end
	if worldFolder then
		worldFolder:ClearAllChildren()
	end
	horizon = nil
	lastBiomeId = nil
	reserves = {}
	lootTaken = {}
	spawnerUsed = {}
	playerS = {}
	warnedAt = {}
	World.Road = nil
end

function World.NewRun(seed)
	World.Clear()
	World.Seed = seed
	World.FinalS = Config.RouteKm * Config.StudsPerKm
	local straight = {}
	for _, st in ipairs(Config.Stations) do
		table.insert(straight, st.km * Config.StudsPerKm)
	end
	table.insert(straight, World.FinalS)
	World.Road = RoadPath.new(seed, World.FinalS + 800, straight)

	-- план завалов на дороге (детерминированно от seed)
	S.Props.NewRun(seed)

	local groundColor, groundMat = S.Props.GroundStyle(0)
	horizon = Instance.new("Part")
	horizon.Name = "Horizon"
	horizon.Anchored = true
	horizon.Size = Vector3.new(2048, 1, 2048)
	horizon.CFrame = CFrame.new(0, -0.56, 0)
	horizon.Color = groundColor:Lerp(Color3.new(0, 0, 0), 0.08)
	horizon.Material = groundMat
	horizon.TopSurface = Enum.SurfaceType.Smooth
	horizon.CollisionGroup = "World"
	horizon.Parent = worldFolder

	local depot = Instance.new("Folder")
	depot.Name = "Depot"
	S.Props.BuildDepot(depot)
	depot.Parent = worldFolder

	local ends = Instance.new("Folder")
	ends.Name = "Bounds"
	S.Props.BuildEndWalls(ends)
	ends.Parent = worldFolder

	horizonAcc = 0
	safetyAcc = 0
end

local function chunkAllowed(ci)
	local CL = Config.ChunkLength
	return ci * CL < World.FinalS + 600 and (ci + 1) * CL > World.MinS() - 400
end

local function buildChunk(ci)
	local CL = Config.ChunkLength
	local s0 = ci * CL
	local s1 = s0 + CL
	local folder = Instance.new("Folder")
	folder.Name = "Chunk_" .. ci
	chunks[ci] = folder
	local rng = Random.new((World.Seed % 100000) * 31 + ci * 7919 + 17)
	local biome = World.BiomeAtS(s0 + CL / 2)
	local ok, err = pcall(S.Props.BuildChunk, ci, s0, s1, biome, rng, folder)
	if not ok then
		warn("[World] ошибка генерации чанка " .. ci .. ": " .. tostring(err))
	elseif type(err) == "number" then
		folder:SetAttribute("PropParts", err)
	end
	for i, st in ipairs(S.Stations.List or {}) do
		if st.s >= s0 and st.s < s1 then
			local okSt, errSt = pcall(S.Stations.BuildStation, i, folder, ci)
			if not okSt then
				warn("[World] станция " .. i .. ": " .. tostring(errSt))
			end
		end
	end
	if World.FinalS >= s0 and World.FinalS < s1 then
		local okF, errF = pcall(S.Stations.BuildFinal, folder, ci)
		if not okF then
			warn("[World] конечная: " .. tostring(errF))
		end
	end
	-- диагностика бюджета чанка (≤ 500 деталей вместе со станцией)
	local parts = 0
	for _, d in ipairs(folder:GetDescendants()) do
		if d:IsA("BasePart") then
			parts = parts + 1
		end
	end
	folder:SetAttribute("PartCount", parts)
	folder.Parent = worldFolder
end

function World.GenerateAround(s, ahead, behind)
	if not World.Road then
		return
	end
	local CL = Config.ChunkLength
	for ci = math.floor((s - behind) / CL), math.floor((s + ahead) / CL) do
		if not chunks[ci] and chunkAllowed(ci) then
			buildChunk(ci)
		end
	end
end

function World.IsChunkLoaded(ci)
	return chunks[ci] ~= nil
end

-- Страховка границ ---------------------------------------------------------------------
local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include

local function groundY(x, z)
	rayParams.FilterDescendantsInstances = { worldFolder }
	local hit = workspace:Raycast(Vector3.new(x, 300, z), Vector3.new(0, -600, 0), rayParams)
	if hit then
		return hit.Position.Y
	end
	return nil
end

-- Безопасная точка на земле внутри границ рядом с (s, d)
local function safePoint(s, d)
	local road = World.Road
	local cs = math.clamp(s, World.MinS() + 14, World.MaxS() - 14)
	local cd = math.clamp(d, -(Bounds.HalfWidth - 16), Bounds.HalfWidth - 16)
	local dir = cd >= 0 and 1 or -1
	for i = 0, 8 do
		local dd = cd - dir * i * 18
		if dir * dd < 0 and i > 0 then
			dd = 0
		end
		local p = road:ToWorld(cs, dd)
		local y = groundY(p.X, p.Z)
		if y and y < 4 then
			return Vector3.new(p.X, y + 3.5, p.Z), cs
		end
		if dd == 0 then
			break
		end
	end
	local p = road:ToWorld(cs, 0)
	return Vector3.new(p.X, 4, p.Z), cs
end

local function isOutside(pos, s, d)
	if pos.Y < -40 then
		return true
	end
	local extra = Bounds.PlayerLimit - Bounds.HalfWidth
	return math.abs(d) > Bounds.PlayerLimit or s < World.MinS() - extra or s > World.MaxS() + extra
end

local function faceRoad(target, s)
	local rp = World.Road:ToWorld(s, 0)
	local flat = Vector3.new(rp.X, target.Y, rp.Z)
	if (flat - target).Magnitude < 1 then
		return CFrame.new(target)
	end
	return CFrame.lookAt(target, flat)
end

local function safetyNet()
	local busS = S.Bus.S or 0
	for _, player in ipairs(Players:GetPlayers()) do
		local char = player.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if root and hum and hum.Health > 0 then
			local pos = root.Position
			local s, d = World.Locate(pos, playerS[player] or busS)
			playerS[player] = s
			if isOutside(pos, s, d) and not hum.SeatPart then
				local target, cs = safePoint(s, d)
				char:PivotTo(faceRoad(target, cs))
				root.AssemblyLinearVelocity = Vector3.zero
				playerS[player] = cs
				local now = os.clock()
				if not warnedAt[player] or now - warnedAt[player] > 3 then
					warnedAt[player] = now
					S.PlayerData.Notify(player, "Дальше не пройти", Color3.fromRGB(255, 170, 80))
				end
			end
		else
			playerS[player] = nil
		end
	end

	local list = {}
	for _, z in ipairs(S.Zombies.List()) do
		table.insert(list, z)
	end
	for _, z in ipairs(list) do
		local root = z.root
		if not z.dead and root and root.Parent then
			local pos = root.Position
			local s, d = World.Locate(pos, busS)
			if isOutside(pos, s, d) then
				local def = z.def or {}
				local important = def.boss or def.elite or z.elite or z.noDespawn or def.stationary
				if important and z.model and z.model.Parent then
					-- боссов и элиту целей не удаляем, а возвращаем внутрь
					local target, cs = safePoint(s, d)
					z.model:PivotTo(faceRoad(target, cs))
					root.AssemblyLinearVelocity = Vector3.zero
				else
					S.Zombies.Remove(z)
				end
			end
		end
	end
end

-- Главный цикл ---------------------------------------------------------------------------
local function wanted(ci, minCi, maxCi)
	if ci >= minCi and ci <= maxCi then
		return true
	end
	local CL = Config.ChunkLength
	for _, ps in pairs(playerS) do
		if ci >= math.floor((ps - PLAYER_KEEP) / CL) and ci <= math.floor((ps + PLAYER_KEEP) / CL) then
			return true
		end
	end
	return false
end

function World.Update(dt)
	if not World.Road or not worldFolder then
		return
	end
	if S.Run and S.Run.Mode == "lobby" then
		return
	end
	local busS = S.Bus.S or 0
	local CL = Config.ChunkLength
	local minCi = math.floor((busS - Config.ChunkBehind) / CL)
	local maxCi = math.floor((busS + Config.ChunkAhead) / CL)

	-- не больше одного нового чанка за кадр, ближайший к автобусу первым
	local centerCi = math.floor(busS / CL)
	local built = false
	for offset = 0, maxCi - minCi do
		for _, ci in ipairs({ centerCi + offset, centerCi - offset }) do
			if ci >= minCi and ci <= maxCi and not chunks[ci] and chunkAllowed(ci) then
				buildChunk(ci)
				built = true
				break
			end
		end
		if built then
			break
		end
	end
	-- потом — чанки вокруг игроков, отошедших от автобуса
	if not built then
		for _, ps in pairs(playerS) do
			local ci = math.floor(ps / CL)
			for _, c2 in ipairs({ ci, ci - 1, ci + 1 }) do
				if not chunks[c2] and chunkAllowed(c2) and wanted(c2, minCi, maxCi) then
					buildChunk(c2)
					built = true
					break
				end
			end
			if built then
				break
			end
		end
	end

	for ci in pairs(chunks) do
		if (ci < minCi - 1 or ci > maxCi + 2) and not wanted(ci, minCi - 1, maxCi + 2) then
			unloadChunk(ci)
		end
	end

	safetyAcc = safetyAcc + dt
	if safetyAcc >= 1 then
		safetyAcc = 0
		safetyNet()
	end

	horizonAcc = horizonAcc + dt
	if horizonAcc >= 1 and horizon then
		horizonAcc = 0
		local busRoot = S.Bus.Root
		if busRoot then
			local p = busRoot.Position
			if (Vector3.new(p.X, -0.56, p.Z) - horizon.Position).Magnitude > 150 then
				horizon.CFrame = CFrame.new(p.X, -0.56, p.Z)
			end
		end
		local biome = World.BiomeAtS(busS)
		local groundColor, groundMat = S.Props.GroundStyle(busS)
		horizon.Color = groundColor:Lerp(Color3.new(0, 0, 0), 0.08)
		horizon.Material = groundMat
		if biome.id ~= lastBiomeId then
			local first = lastBiomeId == nil
			lastBiomeId = biome.id
			local st = Net.State()
			st:SetAttribute("BiomeId", biome.id)
			st:SetAttribute("BiomeName", biome.name)
			if not first then
				Net.Get("Toast"):FireAllClients(biome.name:upper(), biome.subtitle, Color3.fromRGB(255, 230, 170))
			end
		end
	end
end

return World
