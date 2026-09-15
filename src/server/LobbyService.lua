-- Лобби v3: ночная площадь в тумане, ряд ржавых школьных автобусов-площадок.
-- Вход в зону посадки = вход в группу автобуса (первый — лидер), выход из зоны = выход.
-- Отсчёт 20 с, лидер может отправиться сразу. Старт: живой сервер — резервный сервер + телепорт,
-- Studio/ошибка — локальный заезд. Быстрый одиночный старт — PartyAction "solo" (кнопка «ИГРАТЬ»).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local CollectionService = game:GetService("CollectionService")
local TeleportService = game:GetService("TeleportService")
local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Net = require(Shared.Net)
local Difficulty = require(Shared.Difficulty)

local Lobby = {}

local S
local rgb = Color3.fromRGB
local V3 = Vector3.new
local CF = CFrame.new
local ANG = CFrame.Angles
local MAT = Enum.Material

local ORIGIN = V3(0, 0, -4000)
local AREA_RADIUS = 420 -- дальше этого от центра лобби действия групп не принимаются
local CODE_CHARS = "ABCDEFGHJKLMNPQRSTUVWXYZ"
local BEST_STORE_NAME = (Config.DataStoreName or "LastRun") .. "_BestKm"
local COUNTDOWN = 20 -- секунд от первого игрока в автобусе до отправления
local MIN_LEFT_ON_JOIN = 6 -- вошедшему в последний момент даём хотя бы столько секунд
local RETRY_COUNTDOWN = 30 -- после неудачного старта группа ждёт дольше
local ZONE_HALF = 7 -- половина стороны зоны посадки

-- Автобусы-площадки: сложность и подпись
local BUS_DEFS = {
	{ difficulty = "normal", title = "АВТОБУС 1" },
	{ difficulty = "normal", title = "АВТОБУС 2" },
	{ difficulty = "normal", title = "АВТОБУС 3" },
	{ difficulty = "normal", title = "АВТОБУС 4" },
	{ difficulty = "hard", title = "ТЯЖЁЛЫЙ" },
	{ difficulty = "nightmare", title = "КОШМАР" },
}

local GREEN = rgb(120, 230, 120)
local RED = rgb(255, 100, 90)
local YELLOW = rgb(255, 215, 90)
local BLUE = rgb(120, 180, 255)

local active = false
local waiting = false
local folder = nil
local buses = {} -- index -> { index, def, difficulty, zoneCF, center, party, status, title, patch, lines, lastText }
local leaderBoard = nil -- { rows = {TextLabel}, sub }

local parties = {} -- id -> party
local partyOf = {} -- Player -> party
local codeIndex = {} -- code -> party
local nextPartyId = 0
local teleporting = {} -- Player -> { options, attempts, party, at, pending }
local TELEPORT_STALE = 45 -- через столько секунд незавершённый старт считается зависшим
local localStartAt = nil -- os.clock() запроса локального старта (Studio/запасной)
local LOCAL_START_HOLD = 10 -- секунд блокировки повторного локального старта
local lastAction = {}
local lastSig = {}
local lastDenied = {} -- Player -> { bus, at } — чтобы не спамить отказами
local joinGrace = {} -- Player -> { bus, untilT } — перенос по коду: зона ещё не «поймала» игрока

local stateAcc = 0
local zoneAcc = 0
local boardAcc = 0
local leaderAcc = 0
local safetyAcc = 0
local leaderBusy = false
local bestLocal = {} -- userId -> лучший результат в км (этот сервер)
local nameCache = {}

-- Помощники -------------------------------------------------------------------------------------

local function now()
	return workspace:GetServerTimeNow()
end

local function notify(player, text, color)
	S.PlayerData.Notify(player, text, color)
end

local function difficultyIndex(id)
	for i, d in ipairs(Difficulty.Order) do
		if d == id then
			return i
		end
	end
	return nil
end

local function profileOf(player)
	local ok, profile = pcall(S.Profile.Get, player)
	if ok and type(profile) == "table" then
		return profile
	end
	return nil
end

local function difficultyUnlocked(player, diffId)
	local want = difficultyIndex(diffId)
	if not want then
		return false
	end
	if want == 1 then
		return true
	end
	local profile = profileOf(player)
	local have = profile and difficultyIndex(profile.unlockedDifficulty or "normal") or 1
	return want <= (have or 1)
end

local function rootOf(player)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if root and root:IsA("BasePart") and hum and hum.Health > 0 then
		return root
	end
	return nil
end

local function inLobbyArea(player)
	local root = rootOf(player)
	if not root then
		return false
	end
	local offset = root.Position - ORIGIN
	return V3(offset.X, 0, offset.Z).Magnitude <= AREA_RADIUS and offset.Y > -60 and offset.Y < 300
end

-- Можно ли сейчас принимать действие лобби от игрока
local function canAct(player)
	if not active or waiting or S.Run.Mode ~= "lobby" then
		return false
	end
	if not S.PlayerData.Get(player) then
		return false
	end
	local t = os.clock()
	if lastAction[player] and t - lastAction[player] < 0.25 then
		return false
	end
	lastAction[player] = t
	if not inLobbyArea(player) then
		notify(player, "Действие доступно только в лобби", RED)
		return false
	end
	return true
end

local function markDirty()
	stateAcc = math.huge
end

-- Игрок уже в процессе старта/телепорта (зависшие отметки старше TELEPORT_STALE снимаются)
local function startPending(player)
	local info = teleporting[player]
	if not info then
		return false
	end
	if os.clock() - (info.at or 0) > TELEPORT_STALE then
		teleporting[player] = nil
		return false
	end
	return true
end

local function localStartPending()
	return localStartAt ~= nil and os.clock() - localStartAt < LOCAL_START_HOLD
end

local function notifyParty(party, text, color, except)
	for _, member in ipairs(party.members) do
		if member.Parent and member ~= except then
			notify(member, text, color)
		end
	end
end

local function playerLevel(player)
	local lvl = player:GetAttribute("Level")
	if type(lvl) == "number" then
		return lvl
	end
	local profile = profileOf(player)
	return profile and profile.level or 1
end

-- Состояние для клиента ---------------------------------------------------------------------------

local function fullParty(party, viewer)
	local members = {}
	for _, member in ipairs(party.members) do
		table.insert(members, {
			userId = member.UserId,
			name = member.DisplayName,
			level = playerLevel(member),
			isLeader = member == party.leader,
		})
	end
	local bus = buses[party.bus]
	return {
		id = party.id,
		code = party.code,
		bus = party.bus,
		busName = bus and bus.def.title or "АВТОБУС",
		leaderName = party.leader and party.leader.DisplayName or "?",
		isLeader = party.leader == viewer,
		members = members,
		count = #party.members,
		maxSize = party.maxSize,
		difficulty = party.difficulty,
		difficultyName = Difficulty.Get(party.difficulty).name,
		starting = party.starting == true,
		startAt = party.startAt, -- серверное время (workspace:GetServerTimeNow())
	}
end

local function buildState(player)
	local party = partyOf[player]
	local profile = profileOf(player)
	return {
		myParty = party and fullParty(party, player) or nil,
		unlockedDifficulty = profile and profile.unlockedDifficulty or "normal",
		maxPartySize = Config.MaxPartySize,
		startPending = startPending(player) or localStartPending() or (party ~= nil and party.starting == true),
	}
end

local function sendState(player)
	if not player.Parent or not S.PlayerData.Get(player) then
		return
	end
	local state = buildState(player)
	local okSig, sig = pcall(HttpService.JSONEncode, HttpService, state)
	if not okSig then
		sig = tostring(os.clock())
	end
	if sig == lastSig[player] then
		return
	end
	lastSig[player] = sig
	Net.Get("PartyState"):FireClient(player, state)
end

local function broadcast()
	for _, player in ipairs(Players:GetPlayers()) do
		sendState(player)
	end
end

-- Группы ------------------------------------------------------------------------------------------

local function makeCode()
	local rng = Random.new()
	for _ = 1, 200 do
		local chars = {}
		for i = 1, 4 do
			local k = rng:NextInteger(1, #CODE_CHARS)
			chars[i] = string.sub(CODE_CHARS, k, k)
		end
		local code = table.concat(chars)
		if not codeIndex[code] then
			return code
		end
	end
	return nil
end

local function removeParty(party)
	parties[party.id] = nil
	if party.code then
		codeIndex[party.code] = nil
	end
	local bus = buses[party.bus]
	if bus and bus.party == party then
		bus.party = nil
	end
	for _, member in ipairs(party.members) do
		if partyOf[member] == party then
			partyOf[member] = nil
		end
	end
	party.members = {}
	markDirty()
end

local function removeFromParty(player)
	local party = partyOf[player]
	if not party then
		return nil
	end
	partyOf[player] = nil
	for i, member in ipairs(party.members) do
		if member == player then
			table.remove(party.members, i)
			break
		end
	end
	if #party.members == 0 then
		removeParty(party)
	elseif party.leader == player then
		party.leader = party.members[1]
		notify(party.leader, "Теперь вы лидер группы", YELLOW)
	end
	markDirty()
	return party
end

local function createParty(player, bus)
	local code = makeCode()
	if not code then
		return nil
	end
	nextPartyId = nextPartyId + 1
	local t = now()
	local party = {
		id = nextPartyId,
		code = code,
		bus = bus.index,
		leader = player,
		members = { player },
		difficulty = bus.difficulty,
		maxSize = math.max(1, Config.MaxPartySize or 4),
		createdAt = t,
		startAt = t + COUNTDOWN,
		starting = false,
	}
	parties[party.id] = party
	codeIndex[code] = party
	partyOf[player] = party
	bus.party = party
	markDirty()
	return party
end

-- Старт заезда ------------------------------------------------------------------------------------

local function startLocal(difficulty)
	if localStartPending() then
		return
	end
	localStartAt = os.clock()
	Net.Get("Toast"):FireAllClients("СТАРТ ЗАЕЗДА", "Сложность: " .. Difficulty.Get(difficulty).name, YELLOW)
	task.defer(function()
		S.Run.NewRun({ difficulty = difficulty })
	end)
end

local function presentMembers(list)
	local result = {}
	for _, p in ipairs(list) do
		if p.Parent then
			table.insert(result, p)
		end
	end
	return result
end

-- Локальный запасной старт возможен, только если на сервере нет посторонних игроков
local function onlyThesePlayers(list)
	local set = {}
	for _, p in ipairs(list) do
		set[p] = true
	end
	for _, p in ipairs(Players:GetPlayers()) do
		if not set[p] and S.PlayerData.Get(p) then
			return false
		end
	end
	return true
end

local function resetPartyStart(party, delaySec)
	if party and parties[party.id] == party then
		party.starting = false
		party.startedAt = nil
		party.startAt = now() + (delaySec or RETRY_COUNTDOWN)
	end
end

local function cancelStart(party, list, text)
	resetPartyStart(party)
	for _, p in ipairs(list) do
		teleporting[p] = nil
		if p.Parent and text ~= "" then
			notify(p, text, RED)
		end
	end
	markDirty()
end

local function fallbackStart(party, list, difficulty)
	if #list > 0 and onlyThesePlayers(list) and S.Run.Mode == "lobby" then
		for _, p in ipairs(list) do
			teleporting[p] = nil
		end
		startLocal(difficulty)
	else
		cancelStart(party, list, "Не удалось подготовить сервер заезда. Попробуйте ещё раз чуть позже")
	end
end

local function classesOf(list)
	local map = {}
	for _, p in ipairs(list) do
		local classId = p:GetAttribute("ClassId")
		if type(classId) == "string" then
			map[tostring(p.UserId)] = classId
		end
	end
	return map
end

local function startGroup(members, difficulty, leader, party)
	if RunService:IsStudio() or game.PlaceId == 0 then
		if #Players:GetPlayers() > #members then
			Net.Get("Notify"):FireAllClients("Studio: заезд запускается на этом сервере для всех игроков", BLUE)
		end
		if party then
			party.starting = true
			party.startedAt = os.clock()
		end
		startLocal(difficulty)
		return
	end
	if party then
		party.starting = true
		party.startedAt = os.clock()
	end
	-- отметить всех участников до первой уступки: повторный старт/вступление будут отклонены
	local marks = {}
	for _, p in ipairs(members) do
		local mark = { attempts = 0, pending = true, party = party, at = os.clock() }
		teleporting[p] = mark
		marks[p] = mark
	end
	markDirty()
	for _, p in ipairs(members) do
		notify(p, "Готовим сервер заезда...", YELLOW)
	end
	task.spawn(function()
		local code = nil
		for attempt = 1, 3 do
			local ok, result = pcall(function()
				return TeleportService:ReserveServer(game.PlaceId)
			end)
			if ok and type(result) == "string" then
				code = result
				break
			end
			warn("[Lobby] ReserveServer (попытка " .. attempt .. "): " .. tostring(result))
			task.wait(2)
		end
		local list = {}
		for _, p in ipairs(presentMembers(members)) do
			if party == nil or partyOf[p] == party then
				table.insert(list, p)
			elseif teleporting[p] == marks[p] then
				-- страховка: игрок уже не в этой группе — не везём его с ней
				teleporting[p] = nil
			end
		end
		if #list == 0 then
			cancelStart(party, list, "")
			return
		end
		if not code then
			fallbackStart(party, list, difficulty)
			return
		end
		local userIds = {}
		local leaderIn = false
		for _, p in ipairs(list) do
			table.insert(userIds, p.UserId)
			if p == leader then
				leaderIn = true
			end
		end
		if not leaderIn then
			leader = list[1]
		end
		local options = Instance.new("TeleportOptions")
		options.ReservedServerAccessCode = code
		options:SetTeleportData({
			mode = "run",
			difficulty = difficulty,
			members = userIds,
			leader = leader.UserId,
			classes = classesOf(list),
		})
		for _, p in ipairs(list) do
			local at = marks[p] and marks[p].at or os.clock()
			teleporting[p] = { options = options, attempts = 1, party = party, at = at }
		end
		local ok, err = false, nil
		for attempt = 1, 3 do
			ok, err = pcall(function()
				TeleportService:TeleportAsync(game.PlaceId, list, options)
			end)
			if ok then
				break
			end
			warn("[Lobby] TeleportAsync (попытка " .. attempt .. "): " .. tostring(err))
			task.wait(2)
			list = presentMembers(list)
			if #list == 0 then
				return
			end
		end
		if not ok then
			fallbackStart(party, list, difficulty)
		end
	end)
end

local function launchParty(party)
	if party.starting or parties[party.id] ~= party then
		return
	end
	local list = presentMembers(party.members)
	if #list == 0 then
		removeParty(party)
		return
	end
	if party.leader and not difficultyUnlocked(party.leader, party.difficulty) then
		notifyParty(party, "Сложность «" .. Difficulty.Get(party.difficulty).name .. "» закрыта у лидера", RED)
		resetPartyStart(party)
		return
	end
	notifyParty(party, "Автобус отправляется!", GREEN)
	startGroup(list, party.difficulty, party.leader, party)
	markDirty()
end

-- Зоны посадки ------------------------------------------------------------------------------------

local function zoneIndexAt(pos)
	for i, bus in ipairs(buses) do
		local rel = bus.zoneCF:PointToObjectSpace(pos)
		if math.abs(rel.X) <= ZONE_HALF + 0.5 and math.abs(rel.Z) <= ZONE_HALF + 0.5 and rel.Y > -3 and rel.Y < 14 then
			return i
		end
	end
	return nil
end

-- Перенести персонажа внутрь зоны автобуса (вход по коду)
local function placeInZone(player, bus)
	local char = player.Character
	if not char or not rootOf(player) then
		return false
	end
	local rng = Random.new()
	local local_ = CF(rng:NextNumber(-4, 4), 3.2, rng:NextNumber(-3, 4))
	local pos = (bus.zoneCF * local_).Position
	char:PivotTo(CFrame.lookAt(pos, V3(bus.center.X, pos.Y, bus.center.Z - 40)))
	return true
end

-- Вытолкнуть из зоны вперёд (к площади), лицом от автобуса
local function pushOut(player, bus)
	local char = player.Character
	local root = rootOf(player)
	if not char or not root then
		return
	end
	local rel = bus.zoneCF:PointToObjectSpace(root.Position)
	local x = math.clamp(rel.X, -ZONE_HALF, ZONE_HALF)
	local pos = (bus.zoneCF * CF(x, 3.2, ZONE_HALF + 5)).Position
	char:PivotTo(CFrame.lookAt(pos, pos + (bus.zoneCF.LookVector * -1)))
end

local function denyBoarding(player, bus, text)
	pushOut(player, bus)
	local last = lastDenied[player]
	if last and last.bus == bus.index and os.clock() - last.at < 3 then
		return
	end
	lastDenied[player] = { bus = bus.index, at = os.clock() }
	notify(player, text, RED)
end

local function tryBoard(player, bus)
	if not difficultyUnlocked(player, bus.difficulty) then
		local need = Difficulty.Get(Difficulty.Modes[bus.difficulty] and Difficulty.Modes[bus.difficulty].unlockAfter or "normal").name
		denyBoarding(player, bus, "«" .. bus.def.title .. "» закрыт: сначала победите на сложности «" .. need .. "»")
		return
	end
	local party = bus.party
	if party and parties[party.id] ~= party then
		bus.party = nil
		party = nil
	end
	if not party then
		party = createParty(player, bus)
		if not party then
			denyBoarding(player, bus, "Не удалось создать группу, попробуйте ещё раз")
			return
		end
		notify(player, "Вы лидер группы. Код для друзей: " .. party.code .. ". Отправление через " .. COUNTDOWN .. " с", GREEN)
		return
	end
	if party.starting then
		denyBoarding(player, bus, "Этот автобус уже отправляется")
		return
	end
	if #party.members >= party.maxSize then
		denyBoarding(player, bus, "В автобусе нет мест")
		return
	end
	table.insert(party.members, player)
	partyOf[player] = party
	local t = now()
	if party.startAt - t < MIN_LEFT_ON_JOIN then
		party.startAt = t + MIN_LEFT_ON_JOIN
	end
	notifyParty(party, player.DisplayName .. " сел(а) в автобус", GREEN, player)
	notify(player, "Вы в группе «" .. bus.def.title .. "». Лидер: " .. (party.leader and party.leader.DisplayName or "?"), GREEN)
	markDirty()
end

local function updateZones()
	if localStartPending() then
		return
	end
	for _, player in ipairs(Players:GetPlayers()) do
		if S.PlayerData.Get(player) and not startPending(player) then
			local cur = partyOf[player]
			if not (cur and cur.starting) then
				local root = rootOf(player)
				local idx = root and zoneIndexAt(root.Position) or nil
				local grace = joinGrace[player]
				if grace and (os.clock() > grace.untilT or idx == grace.bus) then
					joinGrace[player] = nil
					grace = nil
				end
				if cur and idx ~= cur.bus and not grace then
					removeFromParty(player)
					if parties[cur.id] == cur then
						notifyParty(cur, player.DisplayName .. " вышел(ла) из автобуса", YELLOW)
					end
					notify(player, "Вы вышли из автобуса", YELLOW)
					cur = nil
				end
				if idx and not cur then
					tryBoard(player, buses[idx])
				end
			end
		end
	end
	-- отсчёты групп
	local t = now()
	for _, party in pairs(parties) do
		if not party.starting and t >= party.startAt then
			launchParty(party)
		end
	end
end

-- Действия PartyAction ----------------------------------------------------------------------------

local actions = {}

-- Кнопка «ИГРАТЬ»: мгновенный одиночный заезд на обычной сложности
function actions.solo(player, data)
	local party = partyOf[player]
	if party and party.starting then
		notify(player, "Ваш автобус уже отправляется", RED)
		return
	end
	if party then
		removeFromParty(player)
		if parties[party.id] == party then
			notifyParty(party, player.DisplayName .. " ушёл(ла) в одиночный заезд", YELLOW)
		end
		local bus = buses[party.bus]
		if bus then
			pushOut(player, bus)
		end
	end
	local diff = data.difficulty
	if type(diff) ~= "string" or not Difficulty.Modes[diff] or not difficultyUnlocked(player, diff) then
		diff = "normal"
	end
	startGroup({ player }, diff, player, nil)
end
actions.play = actions.solo

-- Вход по 4-буквенному коду: перенос в зону автобуса этой группы
function actions.join(player, data)
	if type(data.code) ~= "string" or #data.code > 16 then
		return
	end
	local code = string.upper((string.gsub(data.code, "%s", "")))
	if not string.match(code, "^%u%u%u%u$") then
		notify(player, "Код группы — 4 латинские буквы", RED)
		return
	end
	local party = codeIndex[code]
	if not party or parties[party.id] ~= party then
		notify(player, "Группа с кодом «" .. code .. "» не найдена", RED)
		return
	end
	if partyOf[player] == party then
		notify(player, "Вы уже в этой группе", YELLOW)
		return
	end
	local bus = buses[party.bus]
	if not bus then
		return
	end
	if party.starting then
		notify(player, "Группа уже отправляется в заезд", RED)
		return
	end
	if #party.members >= party.maxSize then
		notify(player, "В автобусе нет мест", RED)
		return
	end
	if not difficultyUnlocked(player, party.difficulty) then
		notify(player, "Сложность «" .. Difficulty.Get(party.difficulty).name .. "» у вас ещё не открыта", RED)
		return
	end
	local old = partyOf[player]
	if old then
		removeFromParty(player)
		if parties[old.id] == old then
			notifyParty(old, player.DisplayName .. " вышел(ла) из автобуса", YELLOW)
		end
	end
	if placeInZone(player, bus) then
		joinGrace[player] = { bus = bus.index, untilT = os.clock() + 1.5 }
		tryBoard(player, bus)
	end
end

function actions.leave(player)
	local party = partyOf[player]
	if not party then
		return
	end
	if party.starting then
		notify(player, "Автобус уже отправляется — выйти нельзя", RED)
		return
	end
	joinGrace[player] = nil
	removeFromParty(player)
	if parties[party.id] == party then
		notifyParty(party, player.DisplayName .. " вышел(ла) из автобуса", YELLOW)
	end
	local bus = buses[party.bus]
	if bus then
		pushOut(player, bus)
	end
	notify(player, "Вы вышли из автобуса", YELLOW)
end

-- Лидер: «Отправиться сейчас»
function actions.go(player)
	local party = partyOf[player]
	if not party then
		return
	end
	if party.leader ~= player then
		notify(player, "Отправить автобус может только лидер", RED)
		return
	end
	if party.starting then
		return
	end
	launchParty(party)
end
actions.start = actions.go

local function onPartyAction(player, action, data)
	if type(action) ~= "string" or not actions[action] then
		return
	end
	if data ~= nil and type(data) ~= "table" then
		return
	end
	if not canAct(player) then
		return
	end
	-- пока группа игрока отправляется или идёт его телепорт — никаких действий
	local cur = partyOf[player]
	if cur and cur.starting then
		notify(player, "Автобус уже отправляется", RED)
		sendState(player)
		return
	end
	if localStartPending() or startPending(player) then
		notify(player, "Заезд уже запускается, подождите", RED)
		sendState(player)
		return
	end
	actions[action](player, data or {})
	sendState(player)
end

-- Табло лучших км ---------------------------------------------------------------------------------

local function bestStore()
	local ok, store = pcall(function()
		return DataStoreService:GetOrderedDataStore(BEST_STORE_NAME)
	end)
	if ok then
		return store
	end
	return nil
end

function Lobby.SubmitBestKm(player, km)
	if typeof(player) ~= "Instance" or type(km) ~= "number" or km ~= km or km <= 0 then
		return
	end
	local userId = player.UserId
	bestLocal[userId] = math.max(bestLocal[userId] or 0, km)
	nameCache[userId] = player.DisplayName
	if userId <= 0 or RunService:IsStudio() then
		return
	end
	local value = math.floor(km * 10 + 0.5)
	task.spawn(function()
		local store = bestStore()
		if not store then
			return
		end
		local ok, err = pcall(function()
			store:UpdateAsync(tostring(userId), function(old)
				if type(old) == "number" and old >= value then
					return nil
				end
				return value
			end)
		end)
		if not ok then
			warn("[Lobby] рекорд км не сохранён: " .. tostring(err))
		end
	end)
end

local function nameFor(userId)
	local present = Players:GetPlayerByUserId(userId)
	if present then
		nameCache[userId] = present.DisplayName
		return present.DisplayName
	end
	if nameCache[userId] then
		return nameCache[userId]
	end
	local ok, name = pcall(function()
		return Players:GetNameFromUserIdAsync(userId)
	end)
	nameCache[userId] = ok and name or ("Игрок " .. userId)
	return nameCache[userId]
end

local function renderLeaders(entries, subtitle)
	if not leaderBoard then
		return
	end
	for i, label in ipairs(leaderBoard.rows) do
		local e = entries[i]
		if e then
			label.Text = string.format("%d. %s — %.1f км", i, e.name, e.km)
			label.TextColor3 = i == 1 and rgb(255, 200, 90) or rgb(220, 220, 220)
		else
			label.Text = i == 1 and "Пока нет рекордов" or ""
			label.TextColor3 = rgb(150, 150, 150)
		end
	end
	leaderBoard.sub.Text = subtitle
end

local function refreshLeaderboard()
	if leaderBusy or not leaderBoard then
		return
	end
	leaderBusy = true
	task.spawn(function()
		local entries = {}
		local ok = false
		if not RunService:IsStudio() then
			local store = bestStore()
			if store then
				ok = pcall(function()
					local pages = store:GetSortedAsync(false, 8)
					for _, item in ipairs(pages:GetCurrentPage()) do
						local uid = tonumber(item.key)
						if uid and type(item.value) == "number" then
							table.insert(entries, { userId = uid, km = item.value / 10 })
						end
					end
				end)
			end
		end
		local subtitle = "Лучший результат каждого игрока"
		if not ok or #entries == 0 then
			entries = {}
			local seen = {}
			for _, player in ipairs(Players:GetPlayers()) do
				local profile = profileOf(player)
				local km = profile and type(profile.stats) == "table" and tonumber(profile.stats.bestKm) or 0
				km = math.max(km or 0, bestLocal[player.UserId] or 0)
				if km > 0 then
					seen[player.UserId] = true
					table.insert(entries, { userId = player.UserId, km = km })
				end
			end
			for uid, km in pairs(bestLocal) do
				if not seen[uid] then
					table.insert(entries, { userId = uid, km = km })
				end
			end
			table.sort(entries, function(a, b)
				return a.km > b.km
			end)
			subtitle = "Рекорды игроков этого сервера"
		end
		for i = #entries, 9, -1 do
			entries[i] = nil
		end
		for _, e in ipairs(entries) do
			e.name = nameFor(e.userId)
		end
		leaderBusy = false
		if active then
			renderLeaders(entries, subtitle)
		end
	end)
end

-- Постройка лобби ---------------------------------------------------------------------------------

local RUST = rgb(168, 104, 44)
local RUST_DARK = rgb(96, 60, 34)
local FRAME_DARK = rgb(34, 32, 30)
local PAINT = rgb(176, 150, 70)

local function part(props)
	props.Parent = props.Parent or folder
	if props.CanCollide == false and props.CanQuery == nil then
		props.CanQuery = false
	end
	return Util.Part(props)
end

local function deco(parent, size, cf, color, material, extra)
	local props = { Size = size, CFrame = cf, Color = color, Material = material or MAT.Metal, Parent = parent, CanCollide = false, CanQuery = false, CanTouch = false }
	for k, v in pairs(extra or {}) do
		props[k] = v
	end
	return Util.Part(props)
end

local function solid(parent, size, cf, color, material, extra)
	local props = { Size = size, CFrame = cf, Color = color, Material = material or MAT.Metal, Parent = parent, CanTouch = false }
	for k, v in pairs(extra or {}) do
		props[k] = v
	end
	return Util.Part(props)
end

local function textLabel(parent, props)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBlack
	label.TextColor3 = rgb(240, 240, 240)
	label.TextScaled = true
	label.TextWrapped = true
	label.TextStrokeTransparency = 0.35
	for k, v in pairs(props) do
		label[k] = v
	end
	label.Parent = parent
	return label
end

local function surfaceGui(target, face, ppStud)
	local gui = Instance.new("SurfaceGui")
	gui.Face = face or Enum.NormalId.Front
	gui.SizingMode = Enum.SurfaceGuiSizingMode.PixelsPerStud
	gui.PixelsPerStud = ppStud or 30
	gui.LightInfluence = 0
	gui.Parent = target
	return gui
end

-- Сосна: тонкий ствол и стопка «конусов» из пар клиньев
local function pine(pos, h, rng)
	local m = Instance.new("Model")
	m.Name = "Pine"
	deco(m, V3(1.1, h * 0.5, 1.1), CF(pos + V3(0, h * 0.25, 0)), rgb(46, 36, 30), MAT.Wood)
	local tiers = 4
	for tier = 0, tiers - 1 do
		local w = (1 - tier * 0.2) * rng:NextNumber(10, 13) * (h / 40)
		local th = h * 0.3
		local y = h * 0.22 + tier * h * 0.19 + th / 2
		local tierCF = CF(pos + V3(0, y, 0)) * ANG(0, tier * math.rad(45) + rng:NextNumber(0, 0.4), 0)
		local green = rgb(26, 40 + tier * 3, 32)
		for turn = 0, 1 do
			local base = tierCF * ANG(0, turn * math.rad(90), 0)
			Util.Wedge({ Size = V3(w, th, w / 2), CFrame = base * CF(0, 0, -w / 4), Color = green, Material = MAT.Grass, Parent = m, CanCollide = false, CanQuery = false, CanTouch = false })
			Util.Wedge({ Size = V3(w, th, w / 2), CFrame = base * CF(0, 0, w / 4) * ANG(0, math.pi, 0), Color = green, Material = MAT.Grass, Parent = m, CanCollide = false, CanQuery = false, CanTouch = false })
		end
	end
	m.Parent = folder
	return m
end

-- Фонарный столб: бетонное основание, двухсекционная опора, кронштейн с подкосом, плафон со стеклом,
-- тёплый свет вниз и видимый конус света (Beam лицом к камере, без текстуры)
local LAMP_COLOR = rgb(255, 200, 140)
local function lamp(pos, facingDir)
	local m = Instance.new("Model")
	m.Name = "Lamp"
	local dir = facingDir or V3(0, 0, -1)
	solid(m, V3(1.8, 1.2, 1.8), CF(pos + V3(0, 0.6, 0)), rgb(62, 62, 60), MAT.Concrete)
	solid(m, V3(0.9, 11, 0.9), CF(pos + V3(0, 6.7, 0)), rgb(38, 40, 42), MAT.Metal)
	solid(m, V3(0.6, 9.2, 0.6), CF(pos + V3(0, 16.4, 0)), rgb(42, 44, 46), MAT.Metal)
	deco(m, V3(1.1, 0.3, 1.1), CF(pos + V3(0, 12.3, 0)), rgb(30, 30, 32), MAT.Metal)
	local notice = pos + V3(0, 5.5, 0) + dir * 0.47
	deco(m, V3(1.1, 1.5, 0.05), CFrame.lookAt(notice, notice + dir), rgb(168, 162, 140), MAT.SmoothPlastic, { CastShadow = false })
	local top = pos + V3(0, 20.6, 0)
	local armEnd = top + dir * 4.2
	deco(m, V3(0.35, 0.35, 4.6), CFrame.lookAt(top + dir * 2.1, armEnd), rgb(40, 40, 42))
	deco(m, V3(0.2, 0.2, 2.4), CFrame.lookAt(top + dir * 0.9 - V3(0, 1.0, 0), top + dir * 2.3), rgb(40, 40, 42))
	local headPos = armEnd - V3(0, 0.3, 0)
	local headCF = CFrame.lookAt(headPos, headPos + dir)
	deco(m, V3(2.4, 0.6, 1.6), headCF, rgb(34, 34, 36))
	deco(m, V3(2.6, 0.15, 1.8), headCF * CF(0, 0.36, 0), rgb(26, 26, 28))
	local bulb = deco(m, V3(1.8, 0.16, 1.1), headCF * CF(0, -0.36, 0), LAMP_COLOR, MAT.Neon)
	deco(m, V3(2.0, 0.08, 1.3), headCF * CF(0, -0.46, 0), rgb(220, 204, 176), MAT.Glass, { Transparency = 0.6, CastShadow = false })
	local spot = Instance.new("SpotLight")
	spot.Face = Enum.NormalId.Bottom
	spot.Angle = 100
	spot.Range = 42
	spot.Brightness = 2.2
	spot.Color = LAMP_COLOR
	spot.Shadows = false
	spot.Parent = bulb
	-- конус света до асфальта
	local a0 = Instance.new("Attachment")
	a0.Position = V3(0, -0.2, 0)
	a0.Parent = bulb
	local a1 = Instance.new("Attachment")
	a1.Position = V3(0, -(bulb.Position.Y - pos.Y - 0.6), 0)
	a1.Parent = bulb
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Width0 = 1.6
	beam.Width1 = 15
	beam.FaceCamera = true
	beam.Segments = 1
	beam.LightEmission = 1
	beam.LightInfluence = 0
	beam.Color = ColorSequence.new(rgb(255, 190, 120))
	beam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(0.65, 0.94),
		NumberSequenceKeypoint.new(1, 1),
	})
	beam.Parent = bulb
	m.Parent = folder
end

local STEAM_TEXTURE = "rbxasset://textures/particles/smoke_main.dds" -- встроенная текстура клиента

-- Люк с паром: бетонное кольцо, рифлёная крышка со щелями, ParticleEmitter
local function manhole(pos, rng)
	local m = Instance.new("Model")
	m.Name = "Manhole"
	deco(m, V3(0.12, 4.8, 4.8), CF(pos + V3(0, 0.04, 0)) * ANG(0, 0, math.rad(90)), rgb(46, 46, 46), MAT.Concrete, { Shape = Enum.PartType.Cylinder })
	deco(m, V3(0.16, 4, 4), CF(pos + V3(0, 0.07, 0)) * ANG(0, 0, math.rad(90)), rgb(34, 32, 30), MAT.DiamondPlate, { Shape = Enum.PartType.Cylinder, Reflectance = 0.05 })
	local yaw = ANG(0, rng:NextNumber(0, math.pi), 0)
	for i = -1, 1 do
		deco(m, V3(3.0 - math.abs(i) * 0.8, 0.02, 0.12), CF(pos + V3(0, 0.16, 0)) * yaw * CF(0, 0, i * 0.7), rgb(12, 12, 12), MAT.Metal, { CastShadow = false })
	end
	local vent = deco(m, V3(2.4, 0.2, 2.4), CF(pos + V3(0, 0.3, 0)), rgb(0, 0, 0), MAT.SmoothPlastic, { Transparency = 1, CastShadow = false })
	local steam = Instance.new("ParticleEmitter")
	steam.Texture = STEAM_TEXTURE
	steam.Color = ColorSequence.new(rgb(190, 196, 206))
	steam.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1.5), NumberSequenceKeypoint.new(1, 9) })
	steam.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.12, 0.62),
		NumberSequenceKeypoint.new(1, 1),
	})
	steam.Lifetime = NumberRange.new(3, 5)
	steam.Rate = 7
	steam.Speed = NumberRange.new(2.5, 5)
	steam.SpreadAngle = Vector2.new(14, 14)
	steam.Acceleration = V3(1.2, 0.6, 0.4)
	steam.Drag = 0.4
	steam.Rotation = NumberRange.new(0, 360)
	steam.RotSpeed = NumberRange.new(-25, 25)
	steam.LightInfluence = 1
	steam.LightEmission = 0.05
	steam.Parent = vent
	m.Parent = folder
end

-- Низкий туман: невидимый объём, из которого медленно ползут крупные полупрозрачные клубы
local function mist(cf, size, rate)
	local p = part({ Name = "Mist", Size = size, CFrame = cf, Transparency = 1, CanCollide = false, CanTouch = false, CastShadow = false })
	local e = Instance.new("ParticleEmitter")
	e.Texture = STEAM_TEXTURE
	e.Shape = Enum.ParticleEmitterShape.Box
	e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	e.Color = ColorSequence.new(rgb(112, 122, 140))
	e.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 18), NumberSequenceKeypoint.new(1, 34) })
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.3, 0.87),
		NumberSequenceKeypoint.new(0.7, 0.89),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Lifetime = NumberRange.new(12, 18)
	e.Rate = rate or 0.6
	e.Speed = NumberRange.new(0.4, 1.2)
	e.SpreadAngle = Vector2.new(80, 80)
	e.Acceleration = V3(0.25, 0, 0.1)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-4, 4)
	e.LightInfluence = 1
	e.Parent = p
	return p
end

-- Мерцание неона рисует клиент (LobbyUI) по этому тегу — без репликации свойств
local FLICKER_TAG = "LR_LobbyFlicker"

-- Неоновая вывеска: тёмная панель, светящиеся буквы (SurfaceGui), неоновая рамка-трубка, свет.
-- cf — центр панели, лицевая сторона смотрит по LookVector
local function neonSign(cf, w, h, text, color, opts)
	opts = opts or {}
	local m = Instance.new("Model")
	m.Name = "NeonSign"
	local board = solid(m, V3(w, h, 0.5), cf, rgb(16, 16, 18), MAT.Metal)
	local gui = surfaceGui(board, Enum.NormalId.Front, opts.ppStud or 20)
	pcall(function()
		gui.Brightness = 2
	end)
	textLabel(gui, { Size = UDim2.fromScale(0.9, 0.78), Position = UDim2.fromScale(0.05, 0.11), Text = text, TextColor3 = color, TextStrokeTransparency = 1, Font = opts.font or Enum.Font.GothamBlack })
	local t = 0.18
	deco(m, V3(w - 0.4, t, t), cf * CF(0, h / 2 - 0.3, -0.32), color, MAT.Neon)
	deco(m, V3(w - 0.4, t, t), cf * CF(0, -h / 2 + 0.3, -0.32), color, MAT.Neon)
	deco(m, V3(t, h - 0.6, t), cf * CF(-w / 2 + 0.3, 0, -0.32), color, MAT.Neon)
	deco(m, V3(t, h - 0.6, t), cf * CF(w / 2 - 0.3, 0, -0.32), color, MAT.Neon)
	for _, side in ipairs({ -1, 1 }) do
		deco(m, V3(0.12, 0.12, 0.9), cf * CF(side * (w / 2 - 0.8), h / 2 - 0.5, 0.2), rgb(60, 60, 62), MAT.Metal, { CastShadow = false })
	end
	local light = Instance.new("PointLight")
	light.Color = color
	light.Range = opts.range or 22
	light.Brightness = opts.brightness or 1.4
	light.Shadows = false
	light.Parent = board
	if opts.flicker then
		CollectionService:AddTag(m, FLICKER_TAG)
	end
	m.Parent = opts.parent or folder
	return m, board
end

-- Бочка с огнём
local function fireBarrel(pos)
	local m = Instance.new("Model")
	m.Name = "FireBarrel"
	solid(m, V3(3.2, 3, 3), CF(pos + V3(0, 1.5, 0)) * ANG(0, 0, math.rad(90)), RUST_DARK, MAT.CorrodedMetal, { Shape = Enum.PartType.Cylinder })
	local top = deco(m, V3(2.4, 0.2, 2.4), CF(pos + V3(0, 3.05, 0)), rgb(40, 20, 10), MAT.Slate)
	local fire = Instance.new("Fire")
	fire.Size = 4
	fire.Heat = 7
	fire.Color = rgb(255, 130, 40)
	fire.SecondaryColor = rgb(120, 30, 10)
	fire.Parent = top
	local light = Instance.new("PointLight")
	light.Range = 18
	light.Brightness = 1.6
	light.Color = rgb(255, 140, 60)
	light.Parent = top
	m.Parent = folder
end

local function tireStack(pos, n, rng)
	for i = 1, n do
		local p = pos + V3(rng:NextNumber(-0.3, 0.3), 0.5 + (i - 1) * 1, rng:NextNumber(-0.3, 0.3))
		part({ Name = "Tire", Size = V3(1, 3.6, 3.6), CFrame = CF(p) * ANG(0, 0, math.rad(90)), Color = rgb(22, 22, 22), Material = MAT.Rubber, Shape = Enum.PartType.Cylinder })
	end
end

local function buildGround()
	-- мокрый асфальт площади (слабое отражение) и тёмная земля вокруг (край прячет туман)
	part({ Name = "Plaza", Size = V3(304, 2, 214), CFrame = CF(ORIGIN + V3(0, -1, -5)), Color = rgb(40, 42, 46), Material = MAT.Asphalt, Reflectance = 0.05 })
	part({ Name = "OuterGround", Size = V3(900, 2, 900), CFrame = CF(ORIGIN + V3(0, -1.08, -5)), Color = rgb(30, 32, 28), Material = MAT.Ground })
	local rng = Random.new(4107)
	-- лужи: неровные пятна из нескольких дисков тёмной зеркальной воды
	for _ = 1, 18 do
		local c = ORIGIN + V3(rng:NextNumber(-138, 138), 0, rng:NextNumber(-32, 92))
		local d = rng:NextNumber(4, 11)
		for k = 1, rng:NextInteger(2, 3) do
			local off = k == 1 and Vector3.zero or V3(rng:NextNumber(-0.45, 0.45) * d, 0, rng:NextNumber(-0.45, 0.45) * d)
			local dd = d * (k == 1 and 1 or rng:NextNumber(0.45, 0.75))
			part({ Name = "Puddle", Size = V3(0.05, dd, dd), CFrame = CF(c + off + V3(0, 0.025 + k * 0.004, 0)) * ANG(0, 0, math.rad(90)), Color = rgb(16, 18, 22), Material = MAT.Glass, Reflectance = 0.32, Transparency = 0.2, Shape = Enum.PartType.Cylinder, CanCollide = false, CastShadow = false })
		end
	end
	-- трещины и заплаты
	for _ = 1, 26 do
		local p = ORIGIN + V3(rng:NextNumber(-145, 145), 0.012, rng:NextNumber(-94, 96))
		part({ Name = "Crack", Size = V3(0.25, 0.03, rng:NextNumber(4, 14)), CFrame = CF(p) * ANG(0, rng:NextNumber(0, math.pi), 0), Color = rgb(20, 20, 22), Material = MAT.Asphalt, CanCollide = false, CastShadow = false })
	end
	for _ = 1, 10 do
		local p = ORIGIN + V3(rng:NextNumber(-140, 140), 0.01, rng:NextNumber(-25, 95))
		part({ Name = "Patch", Size = V3(rng:NextNumber(6, 16), 0.025, rng:NextNumber(4, 10)), CFrame = CF(p) * ANG(0, rng:NextNumber(0, math.pi), 0), Color = rgb(32, 33, 36), Material = MAT.Asphalt, Reflectance = 0.08, CanCollide = false, CastShadow = false })
	end
	-- люки с паром
	for _, p in ipairs({ V3(-62, 0, 8), V3(74, 0, -12), V3(12, 0, 76), V3(-112, 0, 62), V3(118, 0, 84) }) do
		manhole(ORIGIN + p, rng)
	end
	-- тротуар с бордюром за рядом автобусов
	part({ Name = "Sidewalk", Size = V3(300, 0.3, 13), CFrame = CF(ORIGIN + V3(0, 0.15, -102.5)), Color = rgb(72, 72, 74), Material = MAT.Concrete })
	part({ Name = "Curb", Size = V3(300, 0.45, 0.7), CFrame = CF(ORIGIN + V3(0, 0.22, -95.8)), Color = rgb(96, 96, 96), Material = MAT.Concrete })
	-- выцветшая разметка: линии, стоп-линия перед автобусами, «зебра»
	for i = -3, 3 do
		part({ Name = "Mark", Size = V3(0.6, 0.04, 10), CFrame = CF(ORIGIN + V3(i * 22, 0.02, 60)), Color = rgb(150, 146, 130), Material = MAT.Concrete, Transparency = 0.35, CanCollide = false })
	end
	part({ Name = "StopLine", Size = V3(260, 0.04, 0.8), CFrame = CF(ORIGIN + V3(0, 0.02, -30)), Color = rgb(170, 150, 80), Material = MAT.Concrete, Transparency = 0.5, CanCollide = false, CastShadow = false })
	for i = 0, 5 do
		part({ Name = "Zebra", Size = V3(2.2, 0.04, 9), CFrame = CF(ORIGIN + V3(-30 + i * 4.2, 0.021, 20)), Color = rgb(170, 166, 150), Material = MAT.Concrete, Transparency = 0.45, CanCollide = false, CastShadow = false })
	end
end

-- Забор из рабицы с колючей проволокой по периметру
local function fenceSide(a, b)
	local delta = b - a
	local len = delta.Magnitude
	local mid = (a + b) / 2
	local cf = CFrame.lookAt(mid, b)
	local h = 12
	-- невидимая стена: игроки не уходят с площади
	part({ Name = "FenceWall", Size = V3(1, 40, len), CFrame = cf * CF(0, 20, 0), Transparency = 1, CanQuery = false })
	part({ Name = "FenceRail", Size = V3(0.3, 0.3, len), CFrame = cf * CF(0, h, 0), Color = rgb(70, 72, 74), Material = MAT.Metal, CanCollide = false })
	part({ Name = "FenceRail", Size = V3(0.3, 0.3, len), CFrame = cf * CF(0, 0.4, 0), Color = rgb(70, 72, 74), Material = MAT.Metal, CanCollide = false })
	for row = 1, 4 do
		part({ Name = "FenceWire", Size = V3(0.08, 0.08, len), CFrame = cf * CF(0, row * h / 5, 0), Color = rgb(96, 98, 100), Material = MAT.Metal, CanCollide = false })
	end
	local posts = math.max(1, math.floor(len / 16))
	for i = 0, posts do
		local z = -len / 2 + i * len / posts
		part({ Name = "FencePost", Size = V3(0.5, h + 1.5, 0.5), CFrame = cf * CF(0, (h + 1.5) / 2, z), Color = rgb(60, 62, 64), Material = MAT.Metal, CanCollide = false })
	end
	local wires = math.floor(len / 3)
	for i = 0, wires do
		local z = -len / 2 + i * len / wires
		part({ Name = "FenceWire", Size = V3(0.08, h, 0.08), CFrame = cf * CF(0, h / 2, z), Color = rgb(96, 98, 100), Material = MAT.Metal, CanCollide = false, Transparency = 0.2 })
	end
	-- колючая проволока: спираль из тонких колец
	local coils = math.floor(len / 4)
	for i = 0, coils do
		local z = -len / 2 + i * len / coils
		part({ Name = "Barbed", Size = V3(0.1, 1.8, 1.8), CFrame = cf * CF(0, h + 1.3, z) * ANG(0, math.rad(90), 0) * ANG(math.rad(25), 0, 0), Color = rgb(110, 108, 104), Material = MAT.Metal, Shape = Enum.PartType.Cylinder, CanCollide = false, Transparency = 0.1 })
	end
end

local function buildFenceAndTrees()
	local x0, x1, z0, z1 = -150, 150, -110, 100
	fenceSide(ORIGIN + V3(x0, 0, z0), ORIGIN + V3(x1, 0, z0))
	fenceSide(ORIGIN + V3(x0, 0, z1), ORIGIN + V3(x1, 0, z1))
	fenceSide(ORIGIN + V3(x0, 0, z0), ORIGIN + V3(x0, 0, z1))
	fenceSide(ORIGIN + V3(x1, 0, z0), ORIGIN + V3(x1, 0, z1))
	local rng = Random.new(90210)
	-- сосны за забором, плотнее позади автобусов
	for _ = 1, 64 do
		local side = rng:NextInteger(1, 4)
		local p
		if side == 1 then
			p = V3(rng:NextNumber(-190, 190), 0, z0 - rng:NextNumber(8, 70))
		elseif side == 2 then
			p = V3(rng:NextNumber(-190, 190), 0, z1 + rng:NextNumber(8, 60))
		elseif side == 3 then
			p = V3(x0 - rng:NextNumber(8, 60), 0, rng:NextNumber(z0, z1))
		else
			p = V3(x1 + rng:NextNumber(8, 60), 0, rng:NextNumber(z0, z1))
		end
		pine(ORIGIN + p, rng:NextNumber(34, 58), rng)
	end
	-- пара сосен внутри по углам
	for _, p in ipairs({ V3(-138, 0, 88), V3(138, 0, 88), V3(-140, 0, -20), V3(140, 0, 30) }) do
		pine(ORIGIN + p, rng:NextNumber(28, 40), rng)
	end
end

-- Ржавый школьный автобус (перед — к +Z). cf — точка на земле под центром автобуса
local function busModel(cf, def, rng)
	local m = Instance.new("Model")
	m.Name = "LobbyBus"
	local W, BODY_L, BZ = 10, 28, -3 -- ширина, длина салона, центр салона по Z
	local rust = RUST:Lerp(rgb(130, 84, 42), rng:NextNumber(0, 0.5))
	local function s(size, lcf, color, material, extra)
		return solid(m, size, cf * lcf, color, material, extra)
	end
	local function d(size, lcf, color, material, extra)
		return deco(m, size, cf * lcf, color, material, extra)
	end
	local zBack, zFront = BZ - BODY_L / 2, BZ + BODY_L / 2
	-- рама, пол, юбка кузова
	s(V3(W - 1, 1.2, 33), CF(0, 2.2, 0), FRAME_DARK, MAT.Metal)
	s(V3(W, 0.6, BODY_L), CF(0, 3.1, BZ), rgb(70, 70, 72), MAT.DiamondPlate)
	for _, side in ipairs({ -1, 1 }) do
		s(V3(0.4, 3.2, BODY_L), CF(side * (W / 2 - 0.2), 4.6, BZ), rust, MAT.CorrodedMetal)
		d(V3(0.46, 0.35, BODY_L), CF(side * (W / 2 - 0.2), 5.4, BZ), rgb(24, 22, 20), MAT.Metal)
		d(V3(0.46, 0.35, BODY_L), CF(side * (W / 2 - 0.2), 4.3, BZ), rgb(24, 22, 20), MAT.Metal)
		-- окна: стойки, подоконник, верхний пояс (стёкол нет — выбиты)
		d(V3(0.5, 0.35, BODY_L), CF(side * (W / 2 - 0.25), 6.2, BZ), rust, MAT.CorrodedMetal)
		d(V3(0.5, 0.35, BODY_L), CF(side * (W / 2 - 0.25), 9.6, BZ), rust, MAT.CorrodedMetal)
		s(V3(0.4, 1.3, BODY_L), CF(side * (W / 2 - 0.2), 10.35, BZ), rust, MAT.CorrodedMetal)
		for k = 0, 7 do
			local z = zBack + 0.3 + k * (BODY_L - 0.6) / 7
			s(V3(0.5, 3.4, 0.6), CF(side * (W / 2 - 0.25), 7.9, z), rust, MAT.CorrodedMetal)
		end
		-- пятна ржавчины
		for _ = 1, 3 do
			d(V3(0.1, rng:NextNumber(0.8, 2.2), rng:NextNumber(1.5, 4.5)), CF(side * (W / 2 + 0.02), rng:NextNumber(3.6, 5.6), rng:NextNumber(zBack + 3, zFront - 3)), RUST_DARK, MAT.CorrodedMetal)
		end
		-- грязные уцелевшие стёкла кое-где
		if rng:NextNumber() < 0.6 then
			local k = rng:NextInteger(0, 5)
			local z = zBack + 0.3 + (k + 0.5) * (BODY_L - 0.6) / 7
			d(V3(0.1, 3.2, 3.2), CF(side * (W / 2 - 0.25), 7.9, z), rgb(70, 80, 78), MAT.Glass, { Transparency = 0.55 })
		end
	end
	-- задняя стенка
	s(V3(W, 3.2, 0.4), CF(0, 4.6, zBack + 0.2), rust, MAT.CorrodedMetal)
	s(V3(W, 1.3, 0.4), CF(0, 10.35, zBack + 0.2), rust, MAT.CorrodedMetal)
	for _, x in ipairs({ -W / 2 + 0.3, 0, W / 2 - 0.3 }) do
		s(V3(0.6, 3.4, 0.4), CF(x, 7.9, zBack + 0.2), rust, MAT.CorrodedMetal)
	end
	d(V3(W + 0.2, 1, 0.8), CF(0, 2.8, zBack - 0.4), rgb(26, 26, 26), MAT.Metal)
	-- передняя стенка и лобовое стекло
	s(V3(W, 3.2, 0.4), CF(0, 4.6, zFront - 0.2), rust, MAT.CorrodedMetal)
	s(V3(W, 1.3, 0.4), CF(0, 10.35, zFront - 0.2), rust, MAT.CorrodedMetal)
	for _, x in ipairs({ -W / 2 + 0.3, 0, W / 2 - 0.3 }) do
		s(V3(0.5, 3.4, 0.4), CF(x, 7.9, zFront - 0.2), rust, MAT.CorrodedMetal)
	end
	d(V3(W / 2 - 0.8, 3.2, 0.1), CF(-W / 4, 7.9, zFront - 0.2), rgb(70, 80, 78), MAT.Glass, { Transparency = 0.6 })
	-- крыша
	s(V3(W + 0.4, 0.6, BODY_L + 0.6), CF(0, 11.3, BZ), rust:Lerp(rgb(150, 110, 70), 0.2), MAT.CorrodedMetal)
	d(V3(3, 0.3, 3), CF(0, 11.75, BZ - 6), RUST_DARK, MAT.CorrodedMetal)
	for _, x in ipairs({ -W / 2 + 0.6, W / 2 - 0.6 }) do
		d(V3(0.6, 0.5, 0.6), CF(x, 11.8, zFront - 0.4), rgb(200, 120, 40), MAT.Neon)
	end
	-- капот, решётка, бампер, фары
	s(V3(W - 1.6, 3.6, 6), CF(0, 4.7, zFront + 3), rust, MAT.CorrodedMetal)
	d(V3(W - 1.8, 0.8, 5.6), CF(0, 6.8, zFront + 2.9), rust:Lerp(RUST_DARK, 0.3), MAT.CorrodedMetal)
	d(V3(4, 2.4, 0.3), CF(0, 4.6, zFront + 6.05), rgb(30, 30, 30), MAT.DiamondPlate)
	s(V3(W + 0.2, 1, 0.8), CF(0, 2.8, zFront + 6.4), rgb(26, 26, 26), MAT.Metal)
	d(V3(0.3, 1.3, 1.3), CF(-3.2, 5.3, zFront + 6.05) * ANG(0, math.rad(90), 0), rgb(210, 180, 110), MAT.Neon, { Shape = Enum.PartType.Cylinder })
	d(V3(0.3, 1.3, 1.3), CF(3.2, 5.3, zFront + 6.05) * ANG(0, math.rad(90), 0), rgb(40, 40, 38), MAT.Glass, { Shape = Enum.PartType.Cylinder })
	-- колёса
	for _, z in ipairs({ zFront + 1.5, zBack + 5 }) do
		for _, side in ipairs({ -1, 1 }) do
			d(V3(1.6, 4.4, 4.4), CF(side * (W / 2 - 0.5), 2.2, z), rgb(20, 20, 20), MAT.Rubber, { Shape = Enum.PartType.Cylinder })
			d(V3(1.7, 1.8, 1.8), CF(side * (W / 2 - 0.5), 2.2, z), rgb(110, 108, 104), MAT.Metal, { Shape = Enum.PartType.Cylinder })
		end
	end
	-- дверь справа спереди и ступенька
	d(V3(0.3, 6.4, 2.8), CF(W / 2 + 0.1, 6.3, zFront - 2), rgb(40, 44, 42), MAT.Glass, { Transparency = 0.35 })
	d(V3(1.2, 0.4, 2.8), CF(W / 2 + 0.6, 2.5, zFront - 2), rgb(60, 60, 60), MAT.DiamondPlate)
	-- сиденья
	for r = 0, 3 do
		for _, side in ipairs({ -1, 1 }) do
			local z = zBack + 4 + r * 5
			d(V3(3.4, 0.8, 1.4), CF(side * 2.8, 4.0, z), rgb(58, 50, 38), MAT.Fabric)
			d(V3(3.4, 2.2, 0.4), CF(side * 2.8, 5.1, z - 0.8), rgb(58, 50, 38), MAT.Fabric)
		end
	end
	-- жёлтый плафон в салоне
	local ceiling = d(V3(0.2, 1.2, 1.2), CF(0, 10.9, BZ) * ANG(0, 0, math.rad(90)), rgb(255, 210, 120), MAT.Neon, { Shape = Enum.PartType.Cylinder })
	local light = Instance.new("PointLight")
	light.Range = 14
	light.Brightness = 0.9
	light.Color = rgb(255, 200, 120)
	light.Parent = ceiling
	-- табличка маршрута над лобовым стеклом
	local sign = d(V3(6, 1, 0.2), CF(0, 10.35, zFront + 0.05), rgb(14, 14, 14), MAT.SmoothPlastic)
	local diffColor = def.difficulty == "hard" and rgb(255, 150, 60) or (def.difficulty == "nightmare" and rgb(255, 70, 60) or rgb(255, 190, 80))
	textLabel(surfaceGui(sign, Enum.NormalId.Back, 40), { Size = UDim2.fromScale(1, 1), Text = def.title, TextColor3 = diffColor, TextStrokeTransparency = 1 })
	local signLight = Instance.new("PointLight")
	signLight.Range = 7
	signLight.Brightness = 0.8
	signLight.Color = diffColor
	signLight.Parent = sign

	-- детализация: заклёпки, ржавые подтёки, грязевые щитки, решётки на окнах
	local noShadow = { CastShadow = false }
	for _, side in ipairs({ -1, 1 }) do
		for k = 0, 13 do
			d(V3(0.12, 0.16, 0.16), CF(side * (W / 2 + 0.03), 3.4, zBack + 1 + k * 2), rgb(70, 60, 50), MAT.Metal, noShadow)
		end
		for _ = 1, 3 do
			d(V3(0.06, rng:NextNumber(1.2, 2.6), 0.5), CF(side * (W / 2 + 0.05), 4.6, rng:NextNumber(zBack + 2, zFront - 2)), RUST_DARK:Lerp(rgb(120, 70, 30), 0.3), MAT.CorrodedMetal, noShadow)
		end
		for _, wz in ipairs({ zFront + 1.5, zBack + 5 }) do
			d(V3(1.6, 1.8, 0.12), CF(side * (W / 2 - 0.5), 1.6, wz - 2.8), rgb(18, 18, 18), MAT.Rubber, noShadow)
			d(V3(1.66, 2.8, 2.8), CF(side * (W / 2 - 0.5), 2.2, wz), rgb(52, 50, 48), MAT.Metal, { Shape = Enum.PartType.Cylinder, CastShadow = false })
		end
		for k = 0, 6 do
			if rng:NextNumber() < 0.3 then
				local z0 = zBack + 0.3 + (k + 0.5) * (BODY_L - 0.6) / 7
				for bar = -1, 1 do
					d(V3(0.14, 3.3, 0.14), CF(side * (W / 2 - 0.05), 7.9, z0 + bar * 1.1), rgb(46, 44, 42), MAT.Metal, noShadow)
				end
			end
		end
		-- зеркала
		d(V3(0.15, 0.15, 1.6), CF(side * (W / 2 + 0.6), 8.6, zFront + 0.6) * ANG(0, side * math.rad(30), 0), rgb(30, 30, 30), MAT.Metal, noShadow)
		d(V3(0.9, 1.4, 0.25), CF(side * (W / 2 + 1.3), 8.2, zFront + 1.1), rgb(26, 26, 28), MAT.Metal, noShadow)
		d(V3(0.7, 1.2, 0.05), CF(side * (W / 2 + 1.3), 8.2, zFront + 0.96), rgb(120, 130, 140), MAT.Glass, { Reflectance = 0.4, CastShadow = false })
		-- фары: хромированные ободки, поворотники; задние фонари
		d(V3(0.2, 1.7, 1.7), CF(side * 3.2, 5.3, zFront + 5.95) * ANG(0, math.rad(90), 0), rgb(150, 150, 150), MAT.Metal, { Shape = Enum.PartType.Cylinder, CastShadow = false })
		d(V3(0.7, 0.5, 0.15), CF(side * 4.1, 6.4, zFront + 6.0), rgb(200, 120, 30), MAT.Neon, { Transparency = 0.45, CastShadow = false })
		d(V3(0.9, 0.9, 0.12), CF(side * (W / 2 - 0.9), 4.2, zBack - 0.08), rgb(120, 20, 16), MAT.Neon, { Transparency = 0.35, CastShadow = false })
		d(V3(0.9, 0.45, 0.12), CF(side * (W / 2 - 0.9), 5.0, zBack - 0.08), rgb(170, 100, 30), MAT.Neon, { Transparency = 0.55, CastShadow = false })
		-- поручни в салоне
		d(V3(0.14, 0.14, BODY_L - 2), CF(side * 2.2, 9.9, BZ), rgb(150, 150, 150), MAT.Metal, noShadow)
	end
	for i = -1, 1 do
		d(V3(0.14, 6.6, 0.14), CF(1.0, 6.6, BZ + i * 8), rgb(150, 150, 150), MAT.Metal, noShadow)
	end
	-- дворники
	d(V3(3, 0.12, 0.08), CF(-W / 4, 6.6, zFront + 0.06) * ANG(0, 0, math.rad(20)), rgb(20, 20, 20), MAT.Metal, noShadow)
	d(V3(3, 0.12, 0.08), CF(W / 4, 6.6, zFront + 0.06) * ANG(0, 0, math.rad(160)), rgb(20, 20, 20), MAT.Metal, noShadow)
	-- знак «СТОП» на левом борту
	d(V3(0.12, 2.2, 2.2), CF(-(W / 2 + 0.2), 7.2, zFront - 4), rgb(150, 30, 26), MAT.SmoothPlastic, { Shape = Enum.PartType.Cylinder, CastShadow = false })
	local stopPlate = d(V3(0.05, 1.0, 1.6), CF(-(W / 2 + 0.29), 7.2, zFront - 4), rgb(150, 30, 26), MAT.SmoothPlastic, noShadow)
	textLabel(surfaceGui(stopPlate, Enum.NormalId.Left, 40), { Size = UDim2.fromScale(1, 1), Text = "СТОП", TextColor3 = rgb(240, 240, 240), TextStrokeTransparency = 1 })
	-- выхлопная труба, лестница на задней стенке
	d(V3(2.2, 0.35, 0.35), CF(W / 2 - 1.6, 1.6, zBack - 1.0) * ANG(0, math.rad(90), 0), rgb(40, 36, 34), MAT.CorrodedMetal, { Shape = Enum.PartType.Cylinder })
	for _, x in ipairs({ -1.2, 1.2 }) do
		d(V3(0.18, 8.4, 0.18), CF(x, 7.2, zBack - 0.35), rgb(60, 58, 56), MAT.Metal, noShadow)
	end
	for i = 0, 5 do
		d(V3(2.4, 0.14, 0.14), CF(0, 3.6 + i * 1.3, zBack - 0.35), rgb(60, 58, 56), MAT.Metal, noShadow)
	end
	-- номера спереди и сзади
	local plateText = "А " .. rng:NextInteger(100, 999) .. " РЙ"
	local frontPlate = d(V3(3, 0.8, 0.08), CF(0, 2.8, zFront + 6.85), rgb(206, 206, 196), MAT.SmoothPlastic, noShadow)
	textLabel(surfaceGui(frontPlate, Enum.NormalId.Back, 40), { Size = UDim2.fromScale(1, 1), Text = plateText, TextColor3 = rgb(20, 20, 20), TextStrokeTransparency = 1 })
	local rearPlate = d(V3(3, 0.8, 0.08), CF(0, 2.8, zBack - 0.85), rgb(206, 206, 196), MAT.SmoothPlastic, noShadow)
	textLabel(surfaceGui(rearPlate, Enum.NormalId.Front, 40), { Size = UDim2.fromScale(1, 1), Text = plateText, TextColor3 = rgb(20, 20, 20), TextStrokeTransparency = 1 })
	-- тряпьё на сиденьях
	for r = 0, 3 do
		if rng:NextNumber() < 0.45 then
			local side = rng:NextNumber() < 0.5 and -1 or 1
			d(V3(2.2, 0.12, 1.2), CF(side * 2.8, 4.45, zBack + 4 + r * 5) * ANG(0, rng:NextNumber(-0.4, 0.4), 0), rgb(96, 84, 64):Lerp(rgb(60, 70, 80), rng:NextNumber()), MAT.Fabric, noShadow)
		end
	end
	m.Parent = folder
	return m, diffColor
end

local function buildBuses()
	local rng = Random.new(1337)
	buses = {}
	for i, def in ipairs(BUS_DEFS) do
		local x = -100 + (i - 1) * 40
		local busCF = CF(ORIGIN + V3(x, 0, -72))
		local _, diffColor = busModel(busCF, def, rng)
		local center = ORIGIN + V3(x, 0, -44)
		local zoneCF = CF(center)
		-- площадка посадки: пятно бетона и выцветшая рамка
		local patch = part({ Name = "BoardingPad", Size = V3(ZONE_HALF * 2, 0.05, ZONE_HALF * 2), CFrame = zoneCF * CF(0, 0.03, 0), Color = rgb(58, 60, 60), Material = MAT.Concrete, CanCollide = false })
		local lineColor = def.difficulty == "normal" and PAINT or diffColor:Lerp(rgb(80, 60, 50), 0.35)
		local lines = {}
		for _, info in ipairs({
			{ V3(ZONE_HALF * 2, 0.06, 0.5), CF(0, 0.05, -ZONE_HALF) },
			{ V3(ZONE_HALF * 2, 0.06, 0.5), CF(0, 0.05, ZONE_HALF) },
			{ V3(0.5, 0.06, ZONE_HALF * 2), CF(-ZONE_HALF, 0.05, 0) },
			{ V3(0.5, 0.06, ZONE_HALF * 2), CF(ZONE_HALF, 0.05, 0) },
		}) do
			table.insert(lines, part({ Name = "PadLine", Size = info[1], CFrame = zoneCF * info[2], Color = lineColor, Material = MAT.SmoothPlastic, CanCollide = false }))
		end
		local label = part({ Name = "PadLabel", Size = V3(11, 0.06, 2.6), CFrame = zoneCF * CF(0, 0.06, ZONE_HALF - 2.2), Transparency = 1, CanCollide = false })
		textLabel(surfaceGui(label, Enum.NormalId.Top, 30), { Size = UDim2.fromScale(1, 1), Text = "ПОСАДКА", TextColor3 = lineColor, TextStrokeTransparency = 1, TextTransparency = 0.25 })
		-- невидимая зона (для наглядности в Studio; логика — по координатам)
		part({ Name = "BoardingZone", Size = V3(ZONE_HALF * 2, 10, ZONE_HALF * 2), CFrame = zoneCF * CF(0, 5, 0), Transparency = 1, CanCollide = false, CanTouch = false })

		-- подпись над автобусом
		local anchor = part({ Name = "BusLabelAnchor", Size = V3(1, 1, 1), CFrame = busCF * CF(0, 17, 4), Transparency = 1, CanCollide = false, CanTouch = false })
		local bill = Instance.new("BillboardGui")
		bill.Size = UDim2.new(20, 0, 6.5, 0)
		bill.MaxDistance = 320
		bill.LightInfluence = 0
		bill.Parent = anchor
		local title = textLabel(bill, { Size = UDim2.new(1, 0, 0.3, 0), Text = def.title, TextColor3 = def.difficulty == "normal" and rgb(230, 230, 230) or diffColor })
		local status = textLabel(bill, { Size = UDim2.new(1, 0, 0.42, 0), Position = UDim2.fromScale(0, 0.3), Text = "Пусто", TextStrokeTransparency = 0.2 })
		local need = Difficulty.Modes[def.difficulty] and Difficulty.Modes[def.difficulty].unlockAfter
		local sub = textLabel(bill, {
			Size = UDim2.new(1, 0, 0.22, 0),
			Position = UDim2.fromScale(0, 0.76),
			Font = Enum.Font.GothamBold,
			Text = need and ("Нужна победа на «" .. Difficulty.Get(need).name .. "»") or "",
			TextColor3 = rgb(190, 190, 190),
		})
		table.insert(buses, {
			index = i,
			def = def,
			difficulty = def.difficulty,
			zoneCF = zoneCF,
			center = center,
			party = nil,
			title = title,
			status = status,
			sub = sub,
			patch = patch,
			lines = lines,
			lastText = "",
		})
	end
end

local function updateBillboards()
	local t = now()
	for _, bus in ipairs(buses) do
		local party = bus.party
		if party and parties[party.id] ~= party then
			bus.party = nil
			party = nil
		end
		local text, color, patchColor
		if not party then
			text, color, patchColor = "Пусто", rgb(200, 200, 200), rgb(58, 60, 60)
		elseif party.starting then
			text, color, patchColor = "Отправление…", rgb(255, 200, 90), rgb(96, 78, 44)
		elseif t - party.createdAt < 1.5 then
			text, color, patchColor = "Создание лобби…", rgb(230, 230, 230), rgb(52, 74, 58)
		else
			local left = math.max(0, math.ceil(party.startAt - t))
			text = string.format("Сбор %d/%d · старт через %d с", #party.members, party.maxSize, left)
			color, patchColor = rgb(140, 235, 140), rgb(52, 74, 58)
		end
		if text ~= bus.lastText then
			bus.lastText = text
			bus.status.Text = text
			bus.status.TextColor3 = color
			bus.patch.Color = patchColor
			bus.sub.Visible = party == nil
		end
	end
end

local function buildSigns()
	-- большая вывеска за рядом автобусов
	local pos = ORIGIN + V3(0, 30, -104)
	local board = part({ Name = "DepotSign", Size = V3(70, 9, 1), CFrame = CF(pos), Color = rgb(22, 22, 24), Material = MAT.Metal })
	for _, x in ipairs({ -30, 30 }) do
		part({ Name = "SignPost", Size = V3(1, 30, 1), CFrame = CF(ORIGIN + V3(x, 15, -104.8)), Color = rgb(44, 44, 46), Material = MAT.Metal })
	end
	local signGui = surfaceGui(board, Enum.NormalId.Back, 12)
	pcall(function()
		signGui.Brightness = 1.6
	end)
	textLabel(signGui, { Size = UDim2.fromScale(1, 1), Text = "ПОСЛЕДНИЙ РЕЙС", TextColor3 = rgb(255, 160, 60), TextStrokeTransparency = 1 })
	local glow = Instance.new("PointLight")
	glow.Range = 30
	glow.Brightness = 1.2
	glow.Color = rgb(255, 150, 60)
	glow.Parent = board
	-- неоновая рамка-трубка и подсветка снизу
	local tubeColor = rgb(255, 150, 50)
	part({ Name = "SignTube", Size = V3(68, 0.3, 0.3), CFrame = CF(pos + V3(0, 4.1, 0.65)), Color = tubeColor, Material = MAT.Neon, CanCollide = false, CastShadow = false })
	part({ Name = "SignTube", Size = V3(68, 0.3, 0.3), CFrame = CF(pos + V3(0, -4.1, 0.65)), Color = tubeColor, Material = MAT.Neon, CanCollide = false, CastShadow = false })
	part({ Name = "SignTube", Size = V3(0.3, 8.2, 0.3), CFrame = CF(pos + V3(-34.6, 0, 0.65)), Color = tubeColor, Material = MAT.Neon, CanCollide = false, CastShadow = false })
	part({ Name = "SignTube", Size = V3(0.3, 8.2, 0.3), CFrame = CF(pos + V3(34.6, 0, 0.65)), Color = tubeColor, Material = MAT.Neon, CanCollide = false, CastShadow = false })
	part({ Name = "SignCatwalk", Size = V3(66, 0.3, 2.4), CFrame = CF(pos + V3(0, -5.2, 1.4)), Color = rgb(40, 40, 42), Material = MAT.DiamondPlate, CanCollide = false })
	for _, x in ipairs({ -24, 0, 24 }) do
		local box = part({ Name = "SignUplight", Size = V3(1.6, 0.8, 1), CFrame = CF(pos + V3(x, -4.7, 2.0)), Color = rgb(30, 30, 32), Material = MAT.Metal, CanCollide = false, CastShadow = false })
		local up = Instance.new("SpotLight")
		up.Face = Enum.NormalId.Top
		up.Angle = 70
		up.Range = 14
		up.Brightness = 1.2
		up.Color = rgb(255, 214, 170)
		up.Shadows = false
		up.Parent = box
	end

	-- табло рекордов слева от площади
	local lbPos = ORIGIN + V3(-138, 10, 40)
	local lbCF = CFrame.lookAt(lbPos, lbPos + V3(1, 0, 0))
	local lb = part({ Name = "Leaderboard", Size = V3(22, 16, 0.8), CFrame = lbCF, Color = rgb(20, 20, 22), Material = MAT.Metal })
	for _, side in ipairs({ -1, 1 }) do
		part({ Name = "BoardPost", Size = V3(0.8, 18, 0.8), CFrame = lbCF * CF(side * 11.4, -1, 0.5), Color = rgb(44, 44, 46), Material = MAT.Metal })
	end
	local gui = surfaceGui(lb, Enum.NormalId.Front, 25)
	textLabel(gui, { Size = UDim2.new(1, 0, 0.14, 0), Text = "ЛУЧШИЕ ЗАЕЗДЫ", TextColor3 = rgb(255, 170, 60) })
	local sub = textLabel(gui, { Size = UDim2.new(1, 0, 0.07, 0), Position = UDim2.fromScale(0, 0.14), Font = Enum.Font.GothamBold, Text = "", TextColor3 = rgb(160, 160, 160) })
	local rows = {}
	for i = 1, 8 do
		table.insert(rows, textLabel(gui, { Size = UDim2.new(0.9, 0, 0.085, 0), Position = UDim2.new(0.05, 0, 0.23 + (i - 1) * 0.095, 0), Font = Enum.Font.GothamBold, Text = "", TextXAlignment = Enum.TextXAlignment.Left }))
	end
	leaderBoard = { rows = rows, sub = sub }
end

-- Остановка: навес, стекло, скамья, табло расписания, урна (лицом к -Z, к автобусам)
local function busStop(pos)
	local m = Instance.new("Model")
	m.Name = "BusStop"
	local base = CF(pos)
	solid(m, V3(14, 0.3, 6), base * CF(0, 0.15, 0), rgb(70, 70, 72), MAT.Concrete)
	for _, x in ipairs({ -6.6, 6.6 }) do
		for _, z in ipairs({ -2.4, 2.4 }) do
			solid(m, V3(0.35, 8, 0.35), base * CF(x, 4.3, z), rgb(44, 48, 50), MAT.Metal)
		end
	end
	solid(m, V3(14.6, 0.4, 6.6), base * CF(0, 8.5, 0), rgb(52, 56, 58), MAT.CorrodedMetal)
	deco(m, V3(13.2, 5.2, 0.12), base * CF(0, 4.4, 2.4), rgb(90, 104, 110), MAT.Glass, { Transparency = 0.55 })
	deco(m, V3(4, 1.4, 0.05), base * CF(-3, 3.2, 2.33), rgb(60, 50, 40), MAT.SmoothPlastic, { Transparency = 0.5, CastShadow = false })
	solid(m, V3(10, 0.3, 1.6), base * CF(0, 2.1, 1.4), rgb(80, 62, 44), MAT.WoodPlanks)
	deco(m, V3(10, 1.2, 0.2), base * CF(0, 3.0, 2.15), rgb(80, 62, 44), MAT.WoodPlanks)
	for _, x in ipairs({ -4.4, 0, 4.4 }) do
		deco(m, V3(0.3, 1.9, 0.3), base * CF(x, 1.1, 1.4), rgb(40, 40, 42), MAT.Metal)
	end
	local board = solid(m, V3(3.4, 4.4, 0.3), base * CF(-6.6, 4.6, -0.3), rgb(20, 20, 22), MAT.Metal)
	local gui = surfaceGui(board, Enum.NormalId.Front, 40)
	textLabel(gui, { Size = UDim2.fromScale(1, 0.18), Text = "РАСПИСАНИЕ", TextColor3 = rgb(255, 190, 80), TextStrokeTransparency = 1 })
	for i, line in ipairs({ "Рейс 1 — ОТМЕНЁН", "Рейс 2 — ОТМЕНЁН", "Рейс 3 — ???", "Последний рейс — 00:00" }) do
		textLabel(gui, { Size = UDim2.fromScale(0.92, 0.13), Position = UDim2.fromScale(0.04, 0.22 + (i - 1) * 0.18), Font = Enum.Font.GothamBold, Text = line, TextXAlignment = Enum.TextXAlignment.Left, TextColor3 = i == 4 and rgb(255, 120, 90) or rgb(200, 200, 200), TextStrokeTransparency = 1 })
	end
	local glow = Instance.new("PointLight")
	glow.Range = 9
	glow.Brightness = 0.7
	glow.Color = rgb(200, 220, 255)
	glow.Parent = board
	solid(m, V3(2.6, 1.6, 1.6), base * CF(8.4, 1.3, -1) * ANG(0, 0, math.rad(90)), rgb(52, 60, 50), MAT.CorrodedMetal, { Shape = Enum.PartType.Cylinder })
	deco(m, V3(1.3, 1.3, 1.3), base * CF(8.9, 0.65, 0.6), rgb(22, 24, 22), MAT.Plastic, { Shape = Enum.PartType.Ball })
	m.Parent = folder
end

local function bench(cf)
	local m = Instance.new("Model")
	m.Name = "Bench"
	solid(m, V3(7, 0.3, 1.8), cf * CF(0, 1.7, 0), rgb(84, 64, 46), MAT.WoodPlanks)
	deco(m, V3(7, 1.2, 0.25), cf * CF(0, 2.6, 0.85) * ANG(math.rad(-10), 0, 0), rgb(84, 64, 46), MAT.WoodPlanks)
	for _, x in ipairs({ -3, 3 }) do
		deco(m, V3(0.3, 1.6, 1.6), cf * CF(x, 0.8, 0), rgb(38, 38, 40), MAT.Metal)
	end
	m.Parent = folder
end

local function barrier(cf)
	local m = Instance.new("Model")
	m.Name = "Barrier"
	solid(m, V3(8, 1.2, 2.2), cf * CF(0, 0.6, 0), rgb(150, 146, 136), MAT.Concrete)
	solid(m, V3(8, 1.8, 1.1), cf * CF(0, 2.1, 0), rgb(150, 146, 136), MAT.Concrete)
	deco(m, V3(8.05, 0.5, 1.15), cf * CF(0, 2.4, 0), rgb(200, 80, 40), MAT.SmoothPlastic, { Transparency = 0.2, CastShadow = false })
	m.Parent = folder
end

local function cone(pos)
	local m = Instance.new("Model")
	m.Name = "Cone"
	deco(m, V3(1.6, 0.2, 1.6), CF(pos + V3(0, 0.1, 0)), rgb(30, 30, 30), MAT.Rubber)
	for i = 0, 2 do
		local d = 1.2 - i * 0.35
		deco(m, V3(0.8, d, d), CF(pos + V3(0, 0.6 + i * 0.8, 0)) * ANG(0, 0, math.rad(90)), i == 1 and rgb(226, 226, 216) or rgb(226, 100, 30), MAT.SmoothPlastic, { Shape = Enum.PartType.Cylinder })
	end
	m.Parent = folder
end

-- Ларёк «КАФЕ 24» лицом к центру площади (к -X)
local function kiosk(pos)
	local m = Instance.new("Model")
	m.Name = "Kiosk"
	local base = CFrame.lookAt(pos, pos + V3(-1, 0, 0))
	solid(m, V3(12, 9, 9), base * CF(0, 4.5, 0), rgb(92, 52, 40), MAT.Brick)
	solid(m, V3(12.6, 0.5, 9.6), base * CF(0, 9.25, 0), rgb(40, 40, 42), MAT.Concrete)
	local win = deco(m, V3(7, 3.6, 0.1), base * CF(-1.5, 4.6, -4.52), rgb(255, 214, 150), MAT.Neon, { Transparency = 0.55 })
	deco(m, V3(7.4, 0.3, 0.3), base * CF(-1.5, 2.7, -4.6), rgb(50, 50, 52), MAT.Metal)
	deco(m, V3(7.4, 0.3, 0.3), base * CF(-1.5, 6.5, -4.6), rgb(50, 50, 52), MAT.Metal)
	for i = 0, 2 do
		deco(m, V3(0.2, 3.6, 0.2), base * CF(-4.9 + i * 3.4, 4.6, -4.6), rgb(50, 50, 52), MAT.Metal)
	end
	solid(m, V3(3, 6.6, 0.2), base * CF(4.2, 3.3, -4.55), rgb(70, 72, 74), MAT.CorrodedMetal)
	deco(m, V3(12.4, 0.2, 3), base * CF(0, 7.4, -5.8) * ANG(math.rad(-12), 0, 0), rgb(120, 40, 36), MAT.Fabric)
	deco(m, V3(2.4, 1.6, 1.2), base * CF(-4.5, 7.6, 5.1), rgb(150, 150, 146), MAT.Metal)
	for _, x in ipairs({ -3.5, 3.5 }) do
		deco(m, V3(0.25, 1.4, 0.25), base * CF(x, 10.2, -3.6), rgb(40, 40, 42), MAT.Metal)
	end
	for i = 1, 3 do
		deco(m, V3(1.6, 1.6, 1.6), base * CF(6.6 + i * 0.4, 0.8, -3 + i * 1.5), rgb(22, 24, 22), MAT.Plastic, { Shape = Enum.PartType.Ball })
	end
	local light = Instance.new("PointLight")
	light.Range = 14
	light.Brightness = 1.2
	light.Color = rgb(255, 200, 130)
	light.Parent = win
	m.Parent = folder
	neonSign(base * CF(0, 12.2, -3.6), 10, 2.6, "КАФЕ 24", rgb(80, 255, 120), { flicker = true, range = 26 })
end

-- Столбы с провисающими проводами (Beam с изгибом)
local function powerLine(points, height)
	local bars = {}
	for _, p in ipairs(points) do
		local m = Instance.new("Model")
		m.Name = "PowerPole"
		solid(m, V3(0.9, height, 0.9), CF(p + V3(0, height / 2, 0)), rgb(56, 44, 34), MAT.Wood)
		local bar = deco(m, V3(0.4, 0.4, 7), CF(p + V3(0, height - 1.5, 0)), rgb(56, 44, 34), MAT.Wood)
		for _, z in ipairs({ -3, 3 }) do
			deco(m, V3(0.3, 0.5, 0.3), CF(p + V3(0, height - 1.05, z)), rgb(120, 136, 124), MAT.Glass, { CastShadow = false })
		end
		m.Parent = folder
		table.insert(bars, bar)
	end
	local down = CFrame.fromMatrix(Vector3.zero, V3(0, -1, 0), V3(1, 0, 0))
	for i = 1, #bars - 1 do
		for _, z in ipairs({ -3, 3 }) do
			local a0 = Instance.new("Attachment")
			a0.CFrame = CF(0, 0.55, z) * down
			a0.Parent = bars[i]
			local a1 = Instance.new("Attachment")
			a1.CFrame = CF(0, 0.55, z) * down
			a1.Parent = bars[i + 1]
			local wire = Instance.new("Beam")
			wire.Attachment0 = a0
			wire.Attachment1 = a1
			wire.Width0 = 0.1
			wire.Width1 = 0.1
			wire.FaceCamera = true
			wire.Segments = 12
			wire.CurveSize0 = 4
			wire.CurveSize1 = -4
			wire.Color = ColorSequence.new(rgb(18, 18, 20))
			wire.LightInfluence = 1
			wire.Transparency = NumberSequence.new(0)
			wire.Parent = bars[i]
		end
	end
end

local function buildAmbience()
	busStop(ORIGIN + V3(-46, 0, 58))
	bench(CF(ORIGIN + V3(44, 0, 62)))
	bench(CFrame.lookAt(ORIGIN + V3(-128, 0, 14), ORIGIN + V3(-100, 0, 14)))
	kiosk(ORIGIN + V3(132, 0, 38))
	for i = 0, 2 do
		barrier(CF(ORIGIN + V3(140, 0, -62 + i * 9)) * ANG(0, math.rad(90 + (i - 1) * 5), 0))
	end
	for _, p in ipairs({ V3(108, 0, 26), V3(112, 0, 30), V3(-16, 0, 26), V3(-38, 0, 25) }) do
		cone(ORIGIN + p)
	end
	-- вывеска мотеля на высоком столбе за забором
	local mpos = ORIGIN + V3(186, 0, -50)
	part({ Name = "SignPole", Size = V3(1.2, 34, 1.2), CFrame = CF(mpos + V3(0, 17, 0)), Color = rgb(44, 44, 46), Material = MAT.Metal })
	neonSign(CFrame.lookAt(mpos + V3(0, 36, 0), mpos + V3(-1, 36, 0)), 18, 6, "МОТЕЛЬ", rgb(255, 70, 90), { flicker = true, range = 40, brightness = 2, ppStud = 12 })
	powerLine({ ORIGIN + V3(-180, 0, -124), ORIGIN + V3(-120, 0, -128), ORIGIN + V3(-60, 0, -124), ORIGIN + V3(0, 0, -128), ORIGIN + V3(60, 0, -124), ORIGIN + V3(120, 0, -128), ORIGIN + V3(180, 0, -124) }, 26)
	-- туман: за периметром гуще, на площади — тонкая дымка
	mist(CF(ORIGIN + V3(0, 3, -130)), V3(320, 4, 36), 1.0)
	mist(CF(ORIGIN + V3(-178, 3, 0)), V3(40, 4, 220), 0.8)
	mist(CF(ORIGIN + V3(178, 3, 0)), V3(40, 4, 220), 0.8)
	mist(CF(ORIGIN + V3(0, 3, 128)), V3(320, 4, 40), 0.9)
	mist(CF(ORIGIN + V3(0, 1.5, 20)), V3(240, 2, 110), 0.4)
end

local function buildDecor()
	local lampSpots = {
		{ V3(-120, 0, -40), V3(1, 0, 0) },
		{ V3(-40, 0, -40), V3(1, 0, 0) },
		{ V3(40, 0, -40), V3(-1, 0, 0) },
		{ V3(120, 0, -40), V3(-1, 0, 0) },
		{ V3(-80, 0, 30), V3(0, 0, -1) },
		{ V3(80, 0, 30), V3(0, 0, -1) },
		{ V3(-140, 0, 80), V3(1, 0, 0) },
		{ V3(140, 0, 80), V3(-1, 0, 0) },
		{ V3(0, 0, 90), V3(0, 0, -1) },
	}
	for _, info in ipairs(lampSpots) do
		lamp(ORIGIN + info[1], info[2])
	end
	fireBarrel(ORIGIN + V3(-58, 0, 18))
	fireBarrel(ORIGIN + V3(62, 0, 44))
	local rng = Random.new(77)
	tireStack(ORIGIN + V3(-132, 0, -60), 3, rng)
	tireStack(ORIGIN + V3(134, 0, -8), 2, rng)
	tireStack(ORIGIN + V3(-20, 0, 92), 2, rng)
	for _, p in ipairs({ V3(128, 0, 60), V3(-120, 0, 0), V3(40, 0, 94) }) do
		part({ Name = "Crate", Size = V3(4, 4, 4), CFrame = CF(ORIGIN + p + V3(0, 2, 0)) * ANG(0, rng:NextNumber(0, 1.5), 0), Color = rgb(78, 62, 44), Material = MAT.WoodPlanks })
	end
	buildAmbience()
end

local function buildWaitingSign()
	local pos = ORIGIN + V3(0, 14, 0)
	local sign = part({ Name = "WaitingSign", Size = V3(44, 8, 1), CFrame = CF(pos), Color = rgb(22, 22, 24), Material = MAT.Metal })
	textLabel(surfaceGui(sign, Enum.NormalId.Back, 20), { Size = UDim2.fromScale(1, 1), Text = "СОБИРАЕМ ГРУППУ… ЗАЕЗД СКОРО НАЧНЁТСЯ", TextColor3 = rgb(255, 200, 90), TextStrokeTransparency = 1 })
end

-- API ---------------------------------------------------------------------------------------------

function Lobby.Init(services)
	S = services
	Net.Get("PartyAction").OnServerEvent:Connect(onPartyAction)

	TeleportService.TeleportInitFailed:Connect(function(player, result, message, placeId, options)
		local info = teleporting[player]
		if not info then
			return
		end
		if result == Enum.TeleportResult.IsTeleporting then
			return
		end
		info.attempts = (info.attempts or 0) + 1
		if info.attempts <= 3 and player.Parent then
			notify(player, "Телепорт не удался, пробуем ещё раз...", YELLOW)
			task.delay(2, function()
				if teleporting[player] ~= info or not player.Parent then
					return
				end
				local ok, err = pcall(function()
					TeleportService:TeleportAsync(placeId or game.PlaceId, { player }, options or info.options)
				end)
				if not ok then
					warn("[Lobby] повтор телепорта: " .. tostring(err))
				end
			end)
		else
			teleporting[player] = nil
			notify(player, "Не удалось перенести на сервер заезда: " .. tostring(message), RED)
			local party = info.party
			if party and parties[party.id] == party then
				resetPartyStart(party)
				markDirty()
			end
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		local party = partyOf[player]
		removeFromParty(player)
		if party and parties[party.id] == party and not teleporting[player] then
			notifyParty(party, player.DisplayName .. " вышел(ла) из игры", YELLOW)
		end
		teleporting[player] = nil
		lastAction[player] = nil
		lastSig[player] = nil
		lastDenied[player] = nil
		joinGrace[player] = nil
	end)
end

-- opts.waiting = true — площадка ожидания на сервере заезда (без автобусов и кнопок)
function Lobby.Start(opts)
	local wantWaiting = type(opts) == "table" and opts.waiting == true
	if active and folder and folder.Parent then
		if waiting and not wantWaiting then
			Lobby.Stop()
		else
			return
		end
	end
	waiting = wantWaiting
	local old = workspace:FindFirstChild("Lobby")
	if old then
		old:Destroy()
	end
	folder = Instance.new("Folder")
	folder.Name = "Lobby"
	buses = {}
	leaderBoard = nil
	buildGround()
	buildFenceAndTrees()
	buildDecor()
	if waiting then
		buildWaitingSign()
	else
		buildBuses()
		buildSigns()
	end
	folder.Parent = workspace
	localStartAt = nil
	active = true
	stateAcc = 0
	zoneAcc = 0
	boardAcc = 0
	leaderAcc = 0
	safetyAcc = 0
	lastSig = {}
	if not waiting then
		updateBillboards()
		renderLeaders({}, "Загрузка...")
		refreshLeaderboard()
	end
end

function Lobby.Stop()
	for _, party in pairs(parties) do
		removeParty(party)
	end
	parties = {}
	partyOf = {}
	codeIndex = {}
	lastSig = {}
	joinGrace = {}
	buses = {}
	leaderBoard = nil
	if folder then
		folder:Destroy()
		folder = nil
	end
	active = false
	waiting = false
	localStartAt = nil
end

function Lobby.IsActive()
	return active
end

function Lobby.GetSpawnCFrame()
	if not active then
		return nil
	end
	local rng = Random.new()
	local pos = ORIGIN + V3(rng:NextNumber(-24, 24), 4, rng:NextNumber(34, 50))
	return CFrame.lookAt(pos, V3(pos.X * 0.5, pos.Y, ORIGIN.Z - 60))
end

function Lobby.Update(dt)
	if not active then
		return
	end
	safetyAcc = safetyAcc + dt
	if safetyAcc >= 1 then
		safetyAcc = 0
		-- страховка: упавших с площади вернуть на место появления
		if S.Run.Mode == "lobby" or waiting then
			for _, player in ipairs(Players:GetPlayers()) do
				local root = rootOf(player)
				if root and root.Position.Y < ORIGIN.Y - 40 and player.Character then
					local cf = Lobby.GetSpawnCFrame()
					if cf then
						player.Character:PivotTo(cf)
					end
				end
			end
		end
	end
	if waiting or S.Run.Mode ~= "lobby" then
		return
	end
	zoneAcc = zoneAcc + dt
	stateAcc = stateAcc + dt
	boardAcc = boardAcc + dt
	leaderAcc = leaderAcc + dt
	if zoneAcc >= 0.2 then
		zoneAcc = 0
		updateZones()
	end
	if boardAcc >= 0.25 then
		boardAcc = 0
		updateBillboards()
	end
	if stateAcc >= 0.5 then
		stateAcc = 0
		-- зависшие старты групп (телепорт не случился)
		local t = os.clock()
		for _, party in pairs(parties) do
			if party.starting and party.startedAt and t - party.startedAt > TELEPORT_STALE then
				for _, member in ipairs(party.members) do
					teleporting[member] = nil
				end
				resetPartyStart(party)
				notifyParty(party, "Старт не удался. Попробуйте ещё раз", RED)
			end
		end
		-- зависшие одиночные старты/телепорты
		for p, info in pairs(teleporting) do
			if t - (info.at or 0) > TELEPORT_STALE then
				teleporting[p] = nil
				local party = info.party
				if not (party and parties[party.id] == party) and p.Parent then
					notify(p, "Старт не удался. Попробуйте ещё раз", RED)
				end
			end
		end
		broadcast()
	end
	if leaderAcc >= 30 then
		leaderAcc = 0
		refreshLeaderboard()
	end
end

return Lobby
