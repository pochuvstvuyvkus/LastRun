-- Звуки на клиенте (v5, агент AUDIO; контракт — docs/SPEC_v5.md 2.1).
-- Пул объектов Sound без утечек: случайный вариант и высота из shared/Sounds, 2D (свои руки и
-- интерфейс), 3D на объекте или в точке, задержка, ограничение одновременных копий одного ключа,
-- защита от дублей (один и тот же ключ в той же точке в тот же миг), автоочистка и прогрев записей.
--
--   SoundFX.Play(key, where, opts) -> Sound|nil
--     where: nil — 2D; BasePart/Attachment (а также Model с PrimaryPart, Tool с Handle) — 3D на
--            объекте (звук едет вместе с ним); Vector3/CFrame — 3D в точке.
--     opts:  {volume = множитель, pitch = множитель, delay = секунды, looped = true}
--   SoundFX.Stop(sound[, key]) — остановить звук, полученный из Play (key — защита: не трогать,
--            если этот Sound уже переиспользован под другой ключ). Храните Sound только пока он звучит.
--   SoundFX.StopAll(key) — остановить все звучащие копии ключа.
--   SoundFX.Has(key) -> bool — есть ли запись (без предупреждения в Output).
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local ContentProvider = game:GetService("ContentProvider")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Sounds = require(Shared.Sounds)

local SoundFX = {}

local MAX_PER_KEY = 6 -- одновременно звучащих копий одного ключа (запись может задать maxActive)
local POOL_MAX = { ["2d"] = 24, point = 48, object = 32 }
local POOL_WARM = { ["2d"] = 8, point = 16, object = 8 }
local DUP_GAP = 0.035 -- тот же ключ почти в той же точке быстрее этого — дубль (запись может задать gap)
local DUP_DIST = 1.5
local START_GRACE = 0.1 -- сек после Play, пока звук считается запущенным, даже если ещё грузится
local SWEEP_PERIOD = 0.2
local CULL_MARGIN = 1.1 -- 3D-звук дальше RollOffMaxDistance * CULL_MARGIN от камеры не запускаем
local DEFAULT_LIFE = 8 -- страховка, если длина записи ещё неизвестна

local ready = false
local holder -- Folder в SoundService: 2D-звуки и свободные звуки «на объект»
local pools = { ["2d"] = {}, point = {}, object = {} }
local byKey = {} -- key -> { entry, ... } в порядке запуска
local bySound = {} -- Sound -> entry
local lastPlay = {} -- key -> { t = время запуска, pos = Vector3|nil }
local warned = {}
local tokenSeq = 0

local function newSound(name, parent)
	local s = Instance.new("Sound")
	s.Name = name
	s.Parent = parent
	return s
end

local function homeOf(e)
	return e.mode == "point" and e.att or holder
end

local function newEntry(mode)
	local e = { mode = mode, busy = false, looped = false, key = nil, token = 0, startAt = 0, expire = 0 }
	if mode == "point" then
		local att = Instance.new("Attachment")
		att.Name = "LR_SoundFX"
		att.Parent = workspace.Terrain
		e.att = att
		e.sound = newSound("LR_SoundFX", att)
	else
		e.sound = newSound(mode == "2d" and "LR_SoundFX2D" or "LR_SoundFXObj", holder)
	end
	bySound[e.sound] = e
	table.insert(pools[mode], e)
	return e
end

-- Вернуть звук «домой»; если он (или его Attachment) уничтожен вместе с объектом — пересоздать
local function repair(e)
	if e.mode == "point" and not pcall(function()
		e.att.Parent = workspace.Terrain
	end) then
		local att = Instance.new("Attachment")
		att.Name = "LR_SoundFX"
		att.Parent = workspace.Terrain
		e.att = att
	end
	local home = homeOf(e)
	if not pcall(function()
		e.sound.Parent = home
	end) then
		bySound[e.sound] = nil
		e.sound = newSound(e.mode == "point" and "LR_SoundFX" or (e.mode == "2d" and "LR_SoundFX2D" or "LR_SoundFXObj"), home)
		bySound[e.sound] = e
	end
end

local function removeFromKey(e)
	local list = e.key and byKey[e.key]
	if not list then
		return
	end
	for i = #list, 1, -1 do
		if list[i] == e then
			table.remove(list, i)
			return
		end
	end
end

local function release(e)
	e.token = e.token + 1
	if e.busy then
		removeFromKey(e)
	end
	e.busy = false
	e.looped = false
	e.key = nil
	pcall(function()
		e.sound:Stop()
	end)
	repair(e)
end

local function finished(e, now)
	if not e.busy then
		return true
	end
	if e.looped or now < e.startAt + START_GRACE then
		return false
	end
	local s = e.sound
	return s.Parent == nil or not s.IsPlaying or now > e.expire
end

local function acquire(mode, now)
	local list = pools[mode]
	for _, e in ipairs(list) do
		if not e.busy then
			return e
		end
	end
	for _, e in ipairs(list) do
		if finished(e, now) then
			release(e)
			return e
		end
	end
	if #list < POOL_MAX[mode] then
		return newEntry(mode)
	end
	-- пул полон: забираем самый старый не зацикленный звук
	local oldest
	for _, e in ipairs(list) do
		if not e.looped and (not oldest or e.startAt < oldest.startAt) then
			oldest = e
		end
	end
	if oldest then
		release(oldest)
	end
	return oldest
end

-- where -> режим, объект, позиция (для отсечения по дальности)
local function resolveWhere(where)
	local t = typeof(where)
	if t == "Vector3" then
		return "point", nil, where
	elseif t == "CFrame" then
		return "point", nil, where.Position
	elseif t ~= "Instance" then
		return "2d", nil, nil
	elseif not where:IsDescendantOf(workspace) then
		-- инструмент в рюкзаке/интерфейс своего игрока — 2D; уничтоженный или чужой объект — не играем
		local lp = game:GetService("Players").LocalPlayer
		if lp and where:IsDescendantOf(lp) then
			return "2d", nil, nil
		end
		return nil, nil, nil
	end
	if where:IsA("Attachment") then
		return "object", where, where.WorldPosition
	elseif where:IsA("BasePart") then
		return "object", where, where.Position
	elseif where:IsA("Model") then
		local p = where.PrimaryPart
		if p then
			return "object", p, p.Position
		end
		return "point", nil, where:GetPivot().Position
	elseif where:IsA("Tool") then
		local h = where:FindFirstChild("Handle")
		if h and h:IsA("BasePart") then
			return "object", h, h.Position
		end
	end
	local part = where:FindFirstAncestorWhichIsA("BasePart")
	if part then
		return "object", part, part.Position
	end
	return "2d", nil, nil
end

local function lifeOf(s)
	local len
	if s.PlaybackRegionsEnabled then
		len = math.min(s.PlaybackRegion.Max - s.PlaybackRegion.Min, s.TimeLength > 0 and s.TimeLength or math.huge)
	elseif s.TimeLength > 0 then
		len = s.TimeLength
	else
		len = DEFAULT_LIFE
	end
	if len == math.huge then
		len = DEFAULT_LIFE
	end
	if s.TimeLength <= 0 then
		len = math.max(len, 3) -- запись ещё грузится: не обрываем раньше времени
	end
	return len / math.max(0.05, s.PlaybackSpeed) + 0.5
end

local function startSound(e)
	local s = e.sound
	if s.Parent == nil then
		release(e)
		return
	end
	s.TimePosition = s.PlaybackRegionsEnabled and s.PlaybackRegion.Min or 0
	s:Play()
	if not e.looped then
		e.expire = e.startAt + lifeOf(s)
	end
end

local function sweep(now)
	for _, list in pairs(pools) do
		for _, e in ipairs(list) do
			if e.busy then
				if e.looped then
					if e.sound.Parent == nil then
						release(e) -- объект, на котором играл луп, уничтожен
					end
				elseif finished(e, now) then
					release(e)
				end
			end
		end
	end
end

-- Прогрев: все варианты записей (частые — первыми), пачками, чтобы первый удар/шаг звучал сразу
local function preload()
	local ids = Sounds.PreloadList()
	local batch = {}
	for i, id in ipairs(ids) do
		local s = Instance.new("Sound")
		s.SoundId = id
		table.insert(batch, s)
		if #batch >= 25 or i == #ids then
			pcall(function()
				ContentProvider:PreloadAsync(batch)
			end)
			for _, snd in ipairs(batch) do
				snd:Destroy()
			end
			table.clear(batch)
		end
	end
end

local function init()
	if ready then
		return
	end
	ready = true
	holder = Instance.new("Folder")
	holder.Name = "LR_SoundFX"
	holder.Parent = SoundService
	for mode, n in pairs(POOL_WARM) do
		for _ = 1, n do
			newEntry(mode)
		end
	end
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc = acc + dt
		if acc >= SWEEP_PERIOD then
			acc = 0
			sweep(os.clock())
		end
	end)
	task.spawn(preload)
end

function SoundFX.Has(key)
	return type(key) == "string" and Sounds.Get(key) ~= nil
end

function SoundFX.Play(key, where, opts)
	if type(key) ~= "string" then
		return nil
	end
	local def = Sounds.Get(key)
	if not def then
		if not warned[key] then
			warned[key] = true
			warn("[SoundFX] неизвестный ключ звука: " .. key)
		end
		return nil
	end
	init()
	if type(opts) ~= "table" then
		opts = nil
	end
	local now = os.clock()
	local mode, target, pos = resolveWhere(where)
	if not mode then
		return nil
	end
	if pos then
		local cam = workspace.CurrentCamera
		local maxDist = (def.rolloff and def.rolloff[2] or Sounds.DefaultRollOff[2]) * CULL_MARGIN
		if cam and (cam.CFrame.Position - pos).Magnitude > maxDist then
			return nil
		end
	end
	local delay = opts and tonumber(opts.delay) or 0
	delay = delay > 0 and delay or 0
	local startAt = now + delay

	-- дубль: тот же ключ почти одновременно и почти в той же точке (или оба 2D)
	local lp = lastPlay[key]
	if lp and math.abs(startAt - lp.t) < (def.gap or DUP_GAP) then
		if (pos == nil and lp.pos == nil) or (pos and lp.pos and (pos - lp.pos).Magnitude < DUP_DIST) then
			return nil
		end
	end

	-- лимит одновременных копий ключа: завершившиеся освобождаем, иначе глушим самую старую
	local list = byKey[key]
	if not list then
		list = {}
		byKey[key] = list
	end
	for i = #list, 1, -1 do
		if finished(list[i], now) then
			release(list[i])
		end
	end
	local cap = def.maxActive or MAX_PER_KEY
	while #list >= cap do
		local victim
		for _, e in ipairs(list) do
			if not e.looped then
				victim = e
				break
			end
		end
		if not victim then
			return nil
		end
		release(victim)
	end

	local e = acquire(mode, now)
	if not e then
		return nil
	end
	local s = e.sound
	if mode == "point" then
		e.att.WorldPosition = pos
	elseif mode == "object" then
		if not pcall(function()
			s.Parent = target
		end) then
			release(e)
			return nil
		end
	end
	if not Sounds.Apply(s, key) then
		release(e)
		return nil
	end
	local vm = opts and tonumber(opts.volume) or 1
	local pm = opts and tonumber(opts.pitch) or 1
	s.Volume = math.clamp(s.Volume * vm, 0, 10)
	s.PlaybackSpeed = math.clamp(s.PlaybackSpeed * pm, 0.1, 4)
	local looped = def.looped == true or (opts ~= nil and opts.looped == true)
	s.Looped = looped

	tokenSeq = tokenSeq + 1
	e.token = tokenSeq
	e.busy = true
	e.looped = looped
	e.key = key
	e.startAt = startAt
	e.expire = looped and math.huge or startAt + DEFAULT_LIFE
	table.insert(list, e)
	if lp then
		lp.t, lp.pos = startAt, pos
	else
		lastPlay[key] = { t = startAt, pos = pos }
	end

	if delay > 0 then
		local token = e.token
		task.delay(delay, function()
			if e.token == token and e.busy then
				startSound(e)
			end
		end)
	else
		startSound(e)
	end
	return s
end

function SoundFX.Stop(sound, key)
	if typeof(sound) ~= "Instance" then
		return
	end
	local e = bySound[sound]
	if e then
		if e.busy and (key == nil or e.key == key) then
			release(e)
		end
	elseif sound:IsA("Sound") then
		pcall(function()
			sound:Stop()
		end)
	end
end

function SoundFX.StopAll(key)
	local list = byKey[key]
	if not list then
		return
	end
	for i = #list, 1, -1 do
		release(list[i])
	end
end

function SoundFX.Init()
	init()
end

return SoundFX
