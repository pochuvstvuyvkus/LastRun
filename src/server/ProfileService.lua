-- Постоянный профиль игрока (DataStore): уровень, опыт, билеты, автобусы, открытые сложности,
-- ежедневные награды, отложенные предметы, статистика. Контракт — docs/SPEC_v2.md, раздел 3.5.
--
-- Хранение: DataStore Config.DataStoreName, ключ "u_" .. userId. Запись — только UpdateAsync.
-- Сессионная блокировка (_lock = {job, time}) защищает от гонки при телепорте лобби -> заезд:
-- новый сервер ждёт несколько секунд, пока старый сохранит и отпустит профиль.
local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Progression = require(Shared.Progression)
local Difficulty = require(Shared.Difficulty)
local BusTypes = require(Shared.BusTypes)
local Items = require(Shared.Items)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local Profile = {}
local S

local PROFILE_VERSION = 1
local LOAD_BUDGET = 9.5 -- сек: OnPlayerAdded не блокирует дольше
local LOCK_WAIT = 6 -- сек ожидания чужой блокировки, потом профиль забирается
local LOCK_STALE = 1800 -- блокировка старше этого считается брошенной (сервер упал)
local SAVE_RETRIES = 3
local URGENT_SAVE_DELAY = 6 -- покупки/награды сохраняются вскоре после изменения
local SYNC_DELAY = 0.25
local DAY_CHECK_INTERVAL = 30
local CLAIM_COOLDOWN = 1

local GREEN = Color3.fromRGB(120, 230, 120)
local YELLOW = Color3.fromRGB(255, 220, 90)
local ORANGE = Color3.fromRGB(255, 170, 70)
local PURPLE = Color3.fromRGB(190, 130, 255)

local store = nil
local storeUnavailable = false -- DataStore недоступен (неопубликованное место / Studio без API)
local jobId = game.JobId ~= "" and game.JobId or "studio"

-- entries[player] = {
--   data (профиль), userId, key, saveEnabled, loadFailed, lockTime,
--   dirty, saveAt, saving, queued, queuedRelease, syncQueued, xpFrac,
--   lastClaim, dailyNoticeDay
-- }
local entries = {}
local loading = {}
local activeSaves = 0
local shuttingDown = false

local autosaveAcc = 0
local tickAcc = 0
local dayCheckAcc = 0

-- Утилиты ---------------------------------------------------------------------------------------

local function deepCopy(v)
	if type(v) ~= "table" then
		return v
	end
	local out = {}
	for k, x in pairs(v) do
		out[k] = deepCopy(x)
	end
	return out
end

local function isFiniteNumber(x)
	return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function toInt(x, default, minV, maxV)
	if not isFiniteNumber(x) then
		x = default
	end
	x = math.floor(x)
	if minV and x < minV then
		x = minV
	end
	if maxV and x > maxV then
		x = maxV
	end
	return x
end

local function today()
	return Progression.DayIndex(os.time())
end

local function difficultyRank(id)
	for i, d in ipairs(Difficulty.Order) do
		if d == id then
			return i
		end
	end
	return 0
end

local function notify(player, text, color)
	if player.Parent then
		Net.Get("Notify"):FireClient(player, text, color or Color3.new(1, 1, 1))
	end
end

local function toast(player, title, subtitle, color)
	if player.Parent then
		Net.Get("Toast"):FireClient(player, title, subtitle, color)
	end
end

local function defaultProfile()
	return {
		version = PROFILE_VERSION,
		level = 1,
		xp = 0,
		tickets = 0,
		ownedBuses = { school = true },
		selectedBus = "school",
		unlockedDifficulty = "normal",
		dailyStreak = 0,
		lastDailyDay = -1,
		pendingItems = {},
		stats = { runs = 0, wins = 0, bestKm = 0, kills = 0, objectives = 0 },
	}
end

-- Приводит загруженные данные к корректному виду (защита от порчи и старых версий)
local function sanitize(raw)
	local p = defaultProfile()
	if type(raw) ~= "table" then
		return p
	end
	p.level = toInt(raw.level, 1, 1, Progression.MaxLevel)
	p.xp = toInt(raw.xp, 0, 0)
	if p.level >= Progression.MaxLevel then
		p.xp = math.min(p.xp, Progression.XPForLevel(Progression.MaxLevel))
	end
	p.tickets = toInt(raw.tickets, 0, 0)
	if type(raw.ownedBuses) == "table" then
		for id, owned in pairs(raw.ownedBuses) do
			if type(id) == "string" and owned == true and BusTypes.List[id] then
				p.ownedBuses[id] = true
			end
		end
	end
	p.ownedBuses.school = true
	if type(raw.selectedBus) == "string" and p.ownedBuses[raw.selectedBus] then
		p.selectedBus = raw.selectedBus
	end
	if type(raw.unlockedDifficulty) == "string" and Difficulty.Modes[raw.unlockedDifficulty] then
		p.unlockedDifficulty = raw.unlockedDifficulty
	end
	p.dailyStreak = toInt(raw.dailyStreak, 0, 0)
	p.lastDailyDay = toInt(raw.lastDailyDay, -1, -1)
	if type(raw.pendingItems) == "table" then
		for id, n in pairs(raw.pendingItems) do
			if type(id) == "string" and Items.List[id] and isFiniteNumber(n) and n >= 1 then
				p.pendingItems[id] = math.floor(n)
			end
		end
	end
	if type(raw.stats) == "table" then
		for k, v in pairs(p.stats) do
			local x = raw.stats[k]
			if isFiniteNumber(x) and x >= 0 then
				p.stats[k] = (k == "bestKm") and (math.floor(x * 10 + 0.5) / 10) or math.floor(x)
			else
				p.stats[k] = v
			end
		end
	end
	return p
end

-- Постоянная недоступность (не временная ошибка): неопубликованное место или Studio без доступа к API
local function looksUnavailable(err)
	local msg = tostring(err)
	return msg:find("publish", 1, true) ~= nil
		or msg:find("403", 1, true) ~= nil
		or msg:find("not allowed", 1, true) ~= nil
		or msg:find("StudioAccessToApisNotAllowed", 1, true) ~= nil
end

-- Идёт ли заезд (в лобби ежедневное окно открывается само, в заезде — только по кнопке)
local function isRunMode()
	local state = Net.State()
	if not state then
		return false
	end
	local mode = state:GetAttribute("Mode")
	if mode ~= nil then
		return mode == "run"
	end
	local rs = state:GetAttribute("RunState")
	return rs ~= nil and rs ~= "Lobby"
end

local function getStore()
	if store or storeUnavailable then
		return store
	end
	if game.PlaceId == 0 then
		storeUnavailable = true
		return nil
	end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(Config.DataStoreName)
	end)
	if ok and result then
		store = result
	else
		storeUnavailable = true
		warn("[Profile] DataStore недоступен: " .. tostring(result))
	end
	return store
end

-- Ежедневные награды ----------------------------------------------------------------------------

-- Возвращает (номер дня 1..7, серия после получения, доступна ли)
local function dailyState(data)
	local t = today()
	local last = data.lastDailyDay or -1
	local streak = data.dailyStreak or 0
	if last >= t then
		-- уже забрана сегодня: показываем полученный день
		local day = ((math.max(1, streak) - 1) % 7) + 1
		return day, streak, false
	end
	if last == t - 1 then
		return (streak % 7) + 1, streak + 1, true
	end
	return 1, 1, true
end

local function dailyInfo(entry, open)
	local day, nextStreak, claimable = dailyState(entry.data)
	local nowT = os.time()
	-- текущая серия: сбрасывается в 0, если вчера награду не забирали
	local streak = entry.data.dailyStreak
	if claimable and entry.data.lastDailyDay ~= today() - 1 then
		streak = 0
	end
	return {
		day = day,
		streak = streak,
		nextStreak = nextStreak,
		reward = deepCopy(Progression.Daily[day]),
		claimable = claimable,
		open = open == true,
		nextIn = (Progression.DayIndex(nowT) + 1) * 86400 - nowT,
		allowed = not entry.loadFailed,
	}
end

local function sendDaily(player, open, extra)
	local entry = entries[player]
	if not entry or not player.Parent then
		return
	end
	local info = dailyInfo(entry, open)
	if extra then
		for k, v in pairs(extra) do
			info[k] = v
		end
	end
	Net.Get("DailyReward"):FireClient(player, info)
end

-- Состояние и синхронизация ---------------------------------------------------------------------

local function setAttributes(player, data)
	player:SetAttribute("Level", data.level)
	player:SetAttribute("XP", data.xp)
	player:SetAttribute("XPNext", Progression.XPForLevel(data.level))
	player:SetAttribute("Tickets", data.tickets)
end

local function snapshot(entry)
	local d = entry.data
	local perks = Progression.LevelPerks(d.level)
	return {
		version = d.version,
		level = d.level,
		xp = d.xp,
		xpNext = Progression.XPForLevel(d.level),
		maxLevel = Progression.MaxLevel,
		tickets = d.tickets,
		ownedBuses = deepCopy(d.ownedBuses),
		selectedBus = d.selectedBus,
		unlockedDifficulty = d.unlockedDifficulty,
		dailyStreak = d.dailyStreak,
		lastDailyDay = d.lastDailyDay,
		pendingItems = deepCopy(d.pendingItems),
		stats = deepCopy(d.stats),
		perks = perks,
		saveEnabled = entry.saveEnabled,
		daily = dailyInfo(entry, false),
	}
end

function Profile.SendSync(player)
	local entry = entries[player]
	if not entry or not player.Parent then
		return
	end
	Net.Get("ProfileSync"):FireClient(player, snapshot(entry))
end

-- Отложенная синхронизация: частые изменения (опыт за убийства) склеиваются в одну отправку
local function queueSync(player)
	local entry = entries[player]
	if not entry or entry.syncQueued then
		return
	end
	entry.syncQueued = true
	task.delay(SYNC_DELAY, function()
		entry.syncQueued = false
		if entries[player] == entry then
			Profile.SendSync(player)
		end
	end)
end

local function markDirty(entry, urgent)
	entry.dirty = true
	if urgent and entry.saveEnabled then
		local at = os.clock() + URGENT_SAVE_DELAY
		if not entry.saveAt or entry.saveAt > at then
			entry.saveAt = at
		end
	end
end

local function changed(player, entry, urgent)
	setAttributes(player, entry.data)
	markDirty(entry, urgent)
	queueSync(player)
end

-- Загрузка ---------------------------------------------------------------------------------------

-- Одна попытка: UpdateAsync читает профиль и ставит нашу блокировку.
-- Возвращает status ("ok" | "locked" | "error" | "unavailable"), data, lockTime
local function tryLoad(key, force)
	local ds = getStore()
	if not ds then
		return "unavailable"
	end
	local status, result, lockTime = "error", nil, nil
	local ok, err = pcall(function()
		ds:UpdateAsync(key, function(current)
			local now = os.time()
			if type(current) == "table" and type(current._lock) == "table" and not force then
				local lk = current._lock
				if lk.job ~= jobId and isFiniteNumber(lk.time) and now - lk.time < LOCK_STALE then
					status = "locked"
					result = nil
					return nil -- не записываем, повторим позже
				end
			end
			local data = sanitize(current)
			status = "ok"
			result = data
			lockTime = now
			local out = deepCopy(data)
			out._lock = { job = jobId, time = now }
			return out
		end)
	end)
	if not ok then
		if looksUnavailable(err) then
			storeUnavailable = true
			store = nil
			warn("[Profile] DataStore недоступен: " .. tostring(err))
			return "unavailable"
		end
		warn("[Profile] ошибка загрузки " .. key .. ": " .. tostring(err))
		return "error"
	end
	return status, result, lockTime
end

-- Снять нашу блокировку, не меняя данные (например, игрок ушёл во время загрузки)
local function releaseLockOnly(key)
	local ds = getStore()
	if not ds then
		return
	end
	pcall(function()
		ds:UpdateAsync(key, function(current)
			if type(current) == "table" and type(current._lock) == "table" and current._lock.job == jobId then
				current._lock = nil
				return current
			end
			return nil
		end)
	end)
end

local function loadWithRetries(player, key)
	local start = os.clock()
	local attempt = 0
	while true do
		attempt = attempt + 1
		local force = os.clock() - start >= LOCK_WAIT
		local status, data, lockTime = tryLoad(key, force)
		if status == "ok" or status == "unavailable" then
			return status, data, lockTime
		end
		if not player.Parent or os.clock() - start > LOAD_BUDGET - 2 then
			return status
		end
		task.wait(status == "locked" and 1.5 or math.min(2, attempt))
	end
end

local function createEntry(player, data, saveEnabled, loadFailed, lockTime)
	return {
		data = data,
		userId = player.UserId,
		key = "u_" .. player.UserId,
		saveEnabled = saveEnabled,
		loadFailed = loadFailed,
		lockTime = lockTime or os.time(),
		dirty = false,
		saveAt = nil,
		saving = false,
		queued = false,
		queuedRelease = false,
		syncQueued = false,
		xpFrac = 0,
		lastClaim = 0,
		dailyNoticeDay = today(),
	}
end

local saveEntry -- объявлено ниже

function Profile.OnPlayerAdded(player)
	if entries[player] then
		return
	end
	if loading[player] then
		-- повторный вызов во время загрузки: дождаться первой
		local t0 = os.clock()
		while loading[player] and os.clock() - t0 < LOAD_BUDGET + 1 do
			task.wait(0.1)
		end
		return
	end
	loading[player] = true
	local key = "u_" .. player.UserId

	local result = nil
	task.spawn(function()
		local status, data, lockTime = loadWithRetries(player, key)
		if result == "timeout" then
			-- загрузка завершилась слишком поздно: профиль уже заменён временным, отпускаем блокировку
			if status == "ok" then
				releaseLockOnly(key)
			end
			return
		end
		result = { status = status, data = data, lockTime = lockTime }
	end)

	local start = os.clock()
	while result == nil and os.clock() - start < LOAD_BUDGET do
		task.wait(0.1)
	end
	if result == nil then
		result = "timeout"
	end
	local leftDuringLoad = loading[player] == "left"
	loading[player] = nil

	local entry
	local message = nil
	if type(result) == "table" and result.status == "ok" then
		entry = createEntry(player, result.data, true, false, result.lockTime)
	elseif type(result) == "table" and result.status == "unavailable" then
		entry = createEntry(player, defaultProfile(), false, false)
		message = "Сохранения недоступны (нет доступа к DataStore): прогресс этой сессии не сохранится"
	else
		entry = createEntry(player, defaultProfile(), false, true)
		message = "Не удалось загрузить профиль: прогресс этой сессии не сохранится. Попробуйте перезайти"
	end

	if leftDuringLoad or not player.Parent then
		-- игрок ушёл во время загрузки: вернуть профиль, сняв блокировку
		if entry.saveEnabled then
			task.spawn(releaseLockOnly, key)
		end
		return
	end

	entries[player] = entry
	setAttributes(player, entry.data)

	task.delay(3, function()
		if entries[player] ~= entry or not player.Parent then
			return
		end
		Profile.SendSync(player)
		if message then
			notify(player, message, ORANGE)
		end
		local _, _, claimable = dailyState(entry.data)
		if claimable and not entry.loadFailed then
			local inRun = isRunMode()
			sendDaily(player, not inRun)
			if inRun then
				notify(player, "Доступна ежедневная награда — кнопка «Награды»", YELLOW)
			end
		else
			sendDaily(player, false)
		end
	end)
end

function Profile.OnPlayerRemoving(player)
	if loading[player] then
		loading[player] = "left" -- OnPlayerAdded увидит это после загрузки и отпустит профиль
	end
	local entry = entries[player]
	if not entry then
		return
	end
	entries[player] = nil
	if entry.saveEnabled then
		task.spawn(saveEntry, entry, true)
	end
end

function Profile.Get(player)
	local entry = entries[player]
	return entry and entry.data or nil
end

-- Сохранение -------------------------------------------------------------------------------------

local function budgetOk()
	local ok, budget = pcall(function()
		return DataStoreService:GetRequestBudgetForRequestType(Enum.DataStoreRequestType.UpdateAsync)
	end)
	return not ok or budget >= 1
end

local function writeOnce(entry, payload, release)
	local ds = getStore()
	if not ds then
		return false, false
	end
	local stolen = false
	local ok, err = pcall(function()
		ds:UpdateAsync(entry.key, function(current)
			stolen = false
			if type(current) == "table" and type(current._lock) == "table" then
				local lk = current._lock
				if lk.job ~= jobId and isFiniteNumber(lk.time) and lk.time >= entry.lockTime then
					-- профиль забрал другой сервер после нас: не перезаписываем его данные
					stolen = true
					return nil
				end
			end
			local out = deepCopy(payload)
			if not release then
				out._lock = { job = jobId, time = os.time() }
			end
			return out
		end)
	end)
	if not ok then
		warn("[Profile] ошибка сохранения " .. entry.key .. ": " .. tostring(err))
		return false, false
	end
	return not stolen, stolen
end

-- Сохраняет профиль (yield). release = снять блокировку (выход игрока, остановка сервера)
saveEntry = function(entry, release)
	if not entry.saveEnabled then
		return false
	end
	if entry.released and release ~= true then
		-- профиль уже отпущен (выход игрока / остановка сервера): запоздалое обычное сохранение
		-- снова поставило бы _lock и задержало вход на другом сервере
		return not entry.dirty
	end
	if entry.saving then
		entry.queued = true
		entry.queuedRelease = entry.queuedRelease or release == true
		local t0 = os.clock()
		while entry.saving and os.clock() - t0 < 30 do
			task.wait(0.1)
		end
		return not entry.dirty
	end
	entry.saving = true
	activeSaves = activeSaves + 1
	local success = false
	repeat
		entry.queued = false
		local rel = release == true or entry.queuedRelease
		entry.queuedRelease = false
		release = rel
		local payload = deepCopy(entry.data)
		payload.version = PROFILE_VERSION
		entry.dirty = false
		entry.saveAt = nil
		success = false
		for attempt = 1, SAVE_RETRIES do
			local ok, stolen = writeOnce(entry, payload, rel)
			if ok then
				success = true
				if rel then
					entry.released = true
				end
				break
			end
			if stolen then
				entry.saveEnabled = false
				warn("[Profile] профиль " .. entry.key .. " открыт на другом сервере, сохранение отключено")
				break
			end
			if attempt < SAVE_RETRIES then
				task.wait(shuttingDown and 0.5 or attempt * 1.5)
			end
		end
		if not success then
			entry.dirty = true
		end
	until not entry.queued or not entry.saveEnabled
	entry.saving = false
	activeSaves = activeSaves - 1
	return success
end

function Profile.Save(player)
	local entry = entries[player]
	if not entry then
		return false
	end
	return saveEntry(entry, false)
end

function Profile.SaveAll()
	shuttingDown = true
	for _, entry in pairs(entries) do
		if entry.saveEnabled then
			task.spawn(saveEntry, entry, true)
		end
	end
	local t0 = os.clock()
	task.wait()
	while activeSaves > 0 and os.clock() - t0 < 25 do
		task.wait(0.1)
	end
end

-- Опыт и уровни ----------------------------------------------------------------------------------

local function refreshMaxHealth(player)
	local hum = Util.AliveHumanoid(player.Character)
	if not hum or not S or not S.PlayerData then
		return
	end
	local okHp, newMax = pcall(S.PlayerData.MaxHP, player)
	if not okHp or not isFiniteNumber(newMax) or newMax <= 0 then
		return
	end
	local oldMax = math.max(1, hum.MaxHealth)
	local ratio = math.clamp(hum.Health / oldMax, 0, 1)
	hum.MaxHealth = newMax
	if player:GetAttribute("Downed") == true then
		return -- при смерти здоровье остаётся 1
	end
	hum.Health = math.clamp(newMax * ratio, 1, newMax)
end

function Profile.AddXP(player, amount, _reason)
	local entry = entries[player]
	if not entry or not isFiniteNumber(amount) or amount <= 0 then
		return 0
	end
	local d = entry.data
	entry.xpFrac = entry.xpFrac + amount
	local whole = math.floor(entry.xpFrac)
	entry.xpFrac = entry.xpFrac - whole
	if whole <= 0 then
		return 0
	end
	local startLevel = d.level
	d.xp = d.xp + whole
	while d.level < Progression.MaxLevel and d.xp >= Progression.XPForLevel(d.level) do
		d.xp = d.xp - Progression.XPForLevel(d.level)
		d.level = d.level + 1
	end
	if d.level >= Progression.MaxLevel then
		d.xp = math.min(d.xp, Progression.XPForLevel(Progression.MaxLevel))
	end
	local gained = d.level - startLevel
	changed(player, entry, gained > 0)
	if gained > 0 then
		refreshMaxHealth(player)
		if player.Parent then
			Net.Get("LevelUp"):FireClient(player, d.level)
		end
		for _, other in ipairs(Players:GetPlayers()) do
			if other ~= player then
				notify(other, player.DisplayName .. " достиг(ла) уровня " .. d.level, PURPLE)
			end
		end
	end
	return whole
end

function Profile.AddTickets(player, amount, _reason)
	local entry = entries[player]
	if not entry or not isFiniteNumber(amount) or amount <= 0 then
		return 0
	end
	local n = math.floor(amount + 0.5)
	if n <= 0 then
		return 0
	end
	entry.data.tickets = entry.data.tickets + n
	changed(player, entry, n >= 50)
	return n
end

function Profile.SpendTickets(player, amount)
	local entry = entries[player]
	if not entry or not isFiniteNumber(amount) or amount < 0 then
		return false
	end
	local n = math.ceil(amount)
	if entry.data.tickets < n then
		return false
	end
	entry.data.tickets = entry.data.tickets - n
	changed(player, entry, true)
	return true
end

-- Автобусы и сложности ---------------------------------------------------------------------------

function Profile.OwnsBus(player, busId)
	if type(busId) ~= "string" then
		return false
	end
	local entry = entries[player]
	if not entry then
		return busId == "school"
	end
	return entry.data.ownedBuses[busId] == true
end

function Profile.GrantBus(player, busId)
	local entry = entries[player]
	if not entry or type(busId) ~= "string" or not BusTypes.List[busId] then
		return false
	end
	if entry.data.ownedBuses[busId] then
		return true
	end
	entry.data.ownedBuses[busId] = true
	changed(player, entry, true)
	return true
end

function Profile.SelectBus(player, busId)
	local entry = entries[player]
	if not entry or type(busId) ~= "string" or not entry.data.ownedBuses[busId] then
		return false
	end
	if entry.data.selectedBus ~= busId then
		entry.data.selectedBus = busId
		changed(player, entry, false)
	end
	return true
end

function Profile.IsDifficultyUnlocked(player, difficultyId)
	if type(difficultyId) ~= "string" or not Difficulty.Modes[difficultyId] then
		return false
	end
	local entry = entries[player]
	local current = entry and entry.data.unlockedDifficulty or "normal"
	return difficultyRank(difficultyId) <= difficultyRank(current)
end

function Profile.UnlockDifficulty(player, difficultyId)
	local entry = entries[player]
	if not entry or type(difficultyId) ~= "string" or not Difficulty.Modes[difficultyId] then
		return false
	end
	if difficultyRank(difficultyId) <= difficultyRank(entry.data.unlockedDifficulty) then
		return false
	end
	entry.data.unlockedDifficulty = difficultyId
	changed(player, entry, true)
	toast(player, "ОТКРЫТА СЛОЖНОСТЬ", "«" .. Difficulty.Get(difficultyId).name .. "»", Color3.fromRGB(255, 110, 90))
	return true
end

-- Командные значения -----------------------------------------------------------------------------

function Profile.TeamLevel()
	local sum, count = 0, 0
	for _, player in ipairs(Players:GetPlayers()) do
		local entry = entries[player]
		if entry then
			sum = sum + entry.data.level
			count = count + 1
		end
	end
	if count == 0 then
		return 1
	end
	return math.max(1, sum / count)
end

function Profile.LevelPerks(player)
	local entry = player and entries[player]
	if not entry then
		return { bonusHP = 0, damageBonus = 0 }
	end
	return Progression.LevelPerks(entry.data.level)
end

-- Награда за заезд -------------------------------------------------------------------------------
-- stats: km, victory, difficulty, kills, objectives, stations.
-- Опыт/билеты за цели и станции начисляются по ходу заезда (ObjectiveService/StationService),
-- здесь — только за километры и победу, чтобы не удваивать; objectives/kills идут в статистику.
function Profile.AwardRun(player, stats)
	local entry = entries[player]
	if not entry or type(stats) ~= "table" then
		return { tickets = 0, xp = 0 }
	end
	local d = entry.data
	local km = isFiniteNumber(stats.km) and math.clamp(stats.km, 0, Config.RouteKm + 50) or 0
	local victory = stats.victory == true
	local mode = Difficulty.Get(type(stats.difficulty) == "string" and stats.difficulty or "normal")
	local mult = mode.rewardMult or 1
	local kills = toInt(stats.kills, 0, 0)
	local objectives = toInt(stats.objectives, 0, 0)

	local tickets = math.floor(km * Progression.Tickets.perKm * mult + 0.5)
	local xp = math.floor(km * Progression.XP.perKm * mult + 0.5)
	if victory then
		tickets = tickets + math.floor(Progression.Tickets.victory * mult + 0.5)
		xp = xp + math.floor(Progression.XP.runVictory * mult + 0.5)
	end

	d.stats.runs = d.stats.runs + 1
	if victory then
		d.stats.wins = d.stats.wins + 1
	end
	d.stats.bestKm = math.max(d.stats.bestKm, math.floor(km * 10 + 0.5) / 10)
	d.stats.kills = d.stats.kills + kills
	d.stats.objectives = d.stats.objectives + objectives

	local startLevel = d.level
	if tickets > 0 then
		Profile.AddTickets(player, tickets, "run")
	end
	if xp > 0 then
		Profile.AddXP(player, xp, "run")
	end

	local unlocked = nil
	if victory then
		for _, id in ipairs(Difficulty.Order) do
			local m = Difficulty.Modes[id]
			if m.unlockAfter == mode.id and Profile.UnlockDifficulty(player, id) then
				unlocked = id
			end
		end
	end

	changed(player, entry, true)
	-- сохранить сразу: после заезда возможен телепорт в лобби
	if entry.saveEnabled then
		task.spawn(saveEntry, entry, false)
	end
	return {
		tickets = tickets,
		xp = xp,
		levelUps = d.level - startLevel,
		level = d.level,
		unlockedDifficulty = unlocked,
	}
end

function Profile.TakePendingItems(player)
	local entry = entries[player]
	if not entry then
		return {}
	end
	local items = entry.data.pendingItems
	if next(items) == nil then
		return {}
	end
	entry.data.pendingItems = {}
	changed(player, entry, true)
	return items
end

-- Ежедневная награда: получение ------------------------------------------------------------------

local function playerInActiveRun(player)
	local state = Net.State()
	if not state or state:GetAttribute("Mode") == "lobby" then
		return false
	end
	-- Только Driving/Boss: в депо выбор класса (PD.ApplyClass) очищает инвентарь, поэтому
	-- награды, полученные в депо, идут в pendingItems и выдаются RunManager.grantPendingItems
	-- при выезде автобуса из депо
	local rs = state:GetAttribute("RunState")
	if rs ~= "Driving" and rs ~= "Boss" then
		return false
	end
	return S and S.PlayerData and S.PlayerData.Get(player) ~= nil
end

local function itemsText(items)
	local parts = {}
	for id, n in pairs(items) do
		local def = Items.List[id]
		if def then
			table.insert(parts, def.name .. " x" .. n)
		end
	end
	table.sort(parts)
	return table.concat(parts, ", ")
end

local function claimDaily(player)
	local entry = entries[player]
	if not entry then
		return
	end
	local now = os.clock()
	if now - entry.lastClaim < CLAIM_COOLDOWN then
		return
	end
	entry.lastClaim = now
	if entry.loadFailed then
		notify(player, "Профиль не загружен — ежедневная награда недоступна. Перезайдите", ORANGE)
		sendDaily(player, false)
		return
	end
	local day, newStreak, claimable = dailyState(entry.data)
	if not claimable then
		notify(player, "Сегодняшняя награда уже получена. Приходите завтра!", ORANGE)
		sendDaily(player, false)
		return
	end
	local reward = Progression.Daily[day] or {}
	local d = entry.data
	d.dailyStreak = newStreak
	d.lastDailyDay = today()

	local lines = {}
	if isFiniteNumber(reward.tickets) and reward.tickets > 0 then
		Profile.AddTickets(player, reward.tickets, "daily")
		table.insert(lines, "+" .. reward.tickets .. " билетов")
	end
	if isFiniteNumber(reward.xp) and reward.xp > 0 then
		Profile.AddXP(player, reward.xp, "daily")
		table.insert(lines, "+" .. reward.xp .. " опыта")
	end
	if type(reward.items) == "table" and next(reward.items) ~= nil then
		local direct = playerInActiveRun(player)
		for id, n in pairs(reward.items) do
			if Items.List[id] and isFiniteNumber(n) and n >= 1 then
				local count = math.floor(n)
				local given = direct and S.PlayerData.AddItem(player, id, count)
				if not given then
					d.pendingItems[id] = (d.pendingItems[id] or 0) + count
				end
			end
		end
		local text = itemsText(reward.items)
		if text ~= "" then
			table.insert(lines, direct and (text .. " — в инвентаре") or (text .. " — в начале заезда"))
		end
	end

	changed(player, entry, true)
	sendDaily(player, false, { justClaimed = true, claimedDay = day, summary = table.concat(lines, "   ") })
	toast(player, "НАГРАДА ДНЯ " .. day, table.concat(lines, "   "), YELLOW)
	notify(player, "Серия ежедневных наград: " .. newStreak .. " дн.", GREEN)
end

-- Показать окно ежедневной награды (киоск наград в лобби)
function Profile.ShowDaily(player)
	if entries[player] then
		Profile.SendSync(player)
		sendDaily(player, true)
	end
end

-- Инициализация и цикл ---------------------------------------------------------------------------

function Profile.Init(services)
	S = services
	getStore()
	Net.Get("ClaimDaily").OnServerEvent:Connect(function(player)
		if typeof(player) ~= "Instance" or not player:IsA("Player") then
			return
		end
		claimDaily(player)
	end)
	if RunService:IsStudio() and storeUnavailable then
		warn("[Profile] Studio без доступа к DataStore: профили не сохраняются")
	end
end

function Profile.Update(dt)
	tickAcc = tickAcc + dt
	if tickAcc < 1 then
		return
	end
	local step = tickAcc
	tickAcc = 0
	if shuttingDown then
		return
	end
	local clock = os.clock()

	-- срочные сохранения (покупки, награды)
	for _, entry in pairs(entries) do
		if entry.saveAt and clock >= entry.saveAt and entry.saveEnabled and not entry.saving then
			entry.saveAt = nil
			task.spawn(saveEntry, entry, false)
		end
	end

	-- автосохранение (вразнобой, чтобы не упираться в лимиты)
	autosaveAcc = autosaveAcc + step
	if autosaveAcc >= (Config.AutosaveInterval or 120) then
		autosaveAcc = 0
		local i = 0
		for player, entry in pairs(entries) do
			if entry.saveEnabled and entry.dirty and not entry.saving then
				i = i + 1
				task.delay(i * 0.7, function()
					-- за время задержки игрок мог выйти (профиль уже отпущен) или сервер начал остановку
					if entries[player] ~= entry or shuttingDown or not entry.dirty then
						return
					end
					if budgetOk() then
						saveEntry(entry, false)
					else
						markDirty(entry, true)
					end
				end)
			end
		end
	end

	-- смена суток: новая ежедневная награда для игроков, которые в игре
	dayCheckAcc = dayCheckAcc + step
	if dayCheckAcc >= DAY_CHECK_INTERVAL then
		dayCheckAcc = 0
		local t = today()
		for player, entry in pairs(entries) do
			if entry.dailyNoticeDay ~= t then
				entry.dailyNoticeDay = t
				local _, _, claimable = dailyState(entry.data)
				if claimable and not entry.loadFailed and player.Parent then
					sendDaily(player, false)
					notify(player, "Новый день — доступна ежедневная награда (кнопка «Награды»)", YELLOW)
					queueSync(player)
				end
			end
		end
	end
end

return Profile
