-- Сон (v5): койки и спальные места, лечение во сне (за счёт сытости), «Выспался» после спокойного сна,
-- угроза от зомби во сне и пробуждение (шум, нападение, кошмар, сигнализация, друг, рассвет).
-- При Config.Sleep.NightOnly лечь можно только ночью (и не в бою, и если рядом нет зомби); на рассвете
-- спящие просыпаются сами. Ночь идёт быстрее, когда спят все. Контракт — docs/SPEC_v5.md, 2.4.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Classes = require(Shared.Classes)
local Upgrades = require(Shared.Upgrades)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local Sleep = {}
local S
local PD
local sleepers = {}
local beds = {}
local rng = Random.new()

local BLUE = Color3.fromRGB(140, 190, 255)
local ORANGE = Color3.fromRGB(255, 170, 80)
local RED = Color3.fromRGB(255, 90, 90)

local HEAL_RATE = 2 -- здоровья в секунду во сне (каждое HP стоит сытости, как регенерация)
local RESTED_TIME = 25 -- секунд сна без помех для эффекта «Выспался»
local COMBAT_TIME = 5 -- секунд после полученного урона, когда уснуть нельзя
local DAY_TOAST_COOLDOWN = 3 -- секунд между подсказками «Спать можно только ночью» одному игроку

-- пробуждения без помех: такой сон засчитывается в «Выспался» (рассвет — тоже)
local CALM_REASONS = { manual = true, rested = true, friend = true, dawn = true }

local dayToastAt = setmetatable({}, { __mode = "k" }) -- [player] = os.clock() последней подсказки

-- Уровень улучшения автобуса (терпит отсутствие автобуса и старый API)
local function busLevel(id)
	local bus = S and S.Bus
	if not bus then
		return 0
	end
	if bus.GetLevel then
		local ok, level = pcall(bus.GetLevel, id)
		if ok and type(level) == "number" then
			return level
		end
		return 0
	end
	if bus.HasUpgrade and bus.HasUpgrade(id) then
		return 1
	end
	return 0
end

local function busInside(position)
	local bus = S.Bus
	if not bus or not bus.Root or not bus.Root.Parent or not bus.IsInside then
		return false
	end
	local ok, inside = pcall(bus.IsInside, position)
	return ok and inside == true
end

-- Сигнализация: радиус слышимости = HearRadius * hearMult
function Sleep.AlarmHearRadius()
	local level = busLevel("alarm")
	return Config.Sleep.HearRadius * Upgrades.Value("alarm", "hearMult", level, 1), level
end

function Sleep.Init(services)
	S = services
	PD = S.PlayerData
	Net.Get("WakeUp").OnServerEvent:Connect(function(player)
		if sleepers[player] then
			Sleep.Wake(player, "manual")
		end
	end)
end

function Sleep.IsSleeping(player)
	return sleepers[player] ~= nil
end

-- kind: "bus" | "station" | "house"; standOffset — куда встать после сна (в осях кровати)
function Sleep.RegisterBed(part, kind, standOffset)
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") then
		return
	end
	if beds[part] then
		beds[part].kind = kind or beds[part].kind
		beds[part].standOffset = standOffset or beds[part].standOffset
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "SleepPrompt"
	prompt.ActionText = "Лечь спать"
	prompt.ObjectText = kind == "bus" and "Койка" or "Спальное место"
	prompt.HoldDuration = 0.5
	prompt.MaxActivationDistance = 8
	-- кровать в доме стоит у стены: без проверки видимости её можно было занять снаружи сквозь стену
	prompt.RequiresLineOfSight = kind == "house"
	prompt.Parent = part
	beds[part] = { occupant = nil, prompt = prompt, kind = kind, standOffset = standOffset or Vector3.new(3, 2.5, 0) }
	prompt.Triggered:Connect(function(player)
		Sleep.TryBed(player, part)
	end)
	part.Destroying:Connect(function()
		local b = beds[part]
		if b and b.occupant then
			Sleep.Wake(b.occupant, "bed_gone")
		end
		beds[part] = nil
	end)
end

local function nearestZombie(position)
	local best = math.huge
	for _, z in ipairs(S.Zombies.List()) do
		if not z.dead and z.root then
			local d = (z.root.Position - position).Magnitude
			if d < best then
				best = d
			end
		end
	end
	return best
end

-- Спать можно только ночью (Config.Sleep.NightOnly)
local function nightOnly()
	return Config.Sleep.NightOnly == true
end

local function canSleepNow()
	return not nightOnly() or S.DayNight.IsNight()
end

-- Днём: тост «Спать можно только ночью» и когда наступит ночь (одному игроку не чаще DAY_TOAST_COOLDOWN)
local function dayToast(player)
	local now = os.clock()
	local last = dayToastAt[player]
	if last and now - last < DAY_TOAST_COOLDOWN then
		return
	end
	dayToastAt[player] = now
	local startH = math.floor(Config.NightStart)
	local startM = math.floor((Config.NightStart - startH) * 60 + 0.5) % 60
	-- днём время идёт с обычной скоростью: игровые часы -> реальные минуты
	local minutes = ((Config.NightStart - S.DayNight.Clock()) % 24) * Config.DayLength / 24 / 60
	local wait = minutes < 1 and "меньше чем через минуту" or string.format("примерно через %d мин", math.floor(minutes + 0.5))
	Net.Get("Toast"):FireClient(player, "Спать можно только ночью", string.format("Ночь наступит в %02d:%02d — %s", startH, startM, wait), BLUE)
end

function Sleep.TryBed(player, bed)
	local b = beds[bed]
	if not b then
		return
	end
	if not PD.IsActive(player) then
		return
	end
	-- днём лечь нельзя (Config.Sleep.NightOnly)
	if not canSleepNow() then
		dayToast(player)
		return
	end
	if b.occupant then
		PD.Notify(player, "Место занято", ORANGE)
		return
	end
	local d = PD.Get(player)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not d or not hum or not root then
		return
	end
	if os.clock() - (d.LastDamage or 0) < COMBAT_TIME then
		PD.Notify(player, "Во время боя не уснуть", ORANGE)
		return
	end
	if nearestZombie(root.Position) < Config.Sleep.NoZombieRadius then
		PD.Notify(player, "Рядом зомби — глаза не закрываются", RED)
		return
	end
	if hum.SeatPart then
		PD.Notify(player, "Сначала встаньте", ORANGE)
		return
	end
	Sleep.StartSleep(player, bed)
end

function Sleep.StartSleep(player, bed)
	if sleepers[player] or not canSleepNow() then
		return
	end
	local b = bed and beds[bed]
	if not b or b.occupant then
		return
	end
	local d = PD.Get(player)
	local char = player.Character
	local hum = Util.AliveHumanoid(char)
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not d or not hum or not root or hum.SeatPart then
		return
	end
	hum:UnequipTools()
	PD.SetActive(player, 0)

	local lieCF = bed.CFrame * CFrame.new(0, bed.Size.Y / 2 + 0.6, 0.4) * CFrame.Angles(math.rad(90), 0, 0)
	b.occupant = player
	b.prompt.Enabled = false

	hum.PlatformStand = true
	root.AssemblyLinearVelocity = Vector3.zero
	root.AssemblyAngularVelocity = Vector3.zero
	root.CFrame = lieCF
	local weld = Instance.new("Weld")
	weld.Name = "SleepWeld"
	weld.Part0 = bed
	weld.Part1 = root
	weld.C0 = bed.CFrame:ToObjectSpace(lieCF)
	weld.C1 = CFrame.new()
	weld.Parent = root

	local st = {
		bed = bed,
		weld = weld,
		start = os.clock(),
		threat = 0,
		sentThreat = -1,
	}
	if S.DayNight.IsNight() and rng:NextNumber() < Config.Sleep.NightmareChance then
		st.nightmareAt = os.clock() + rng:NextNumber(6, 16)
	end
	sleepers[player] = st
	player:SetAttribute("Sleeping", true)
	player:SetAttribute("SleepThreat", 0)
	PD.SetPrompt(player, "WakePrompt", true)
	Net.Get("SleepEvent"):FireClient(player, "start", { bed = b.kind })
end

function Sleep.OnAttacked(player)
	if sleepers[player] then
		Sleep.Wake(player, "attacked")
	end
end

function Sleep.Wake(player, reason)
	local st = sleepers[player]
	if not st then
		return
	end
	sleepers[player] = nil
	if st.weld then
		st.weld:Destroy()
	end
	local bedInfo = st.bed and beds[st.bed]
	if bedInfo then
		bedInfo.occupant = nil
		bedInfo.prompt.Enabled = true
	end
	player:SetAttribute("Sleeping", false)
	player:SetAttribute("SleepThreat", 0)
	PD.SetPrompt(player, "WakePrompt", false)

	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if hum then
		hum.PlatformStand = false
	end
	if root and root.Parent then
		local standPos
		if st.bed and st.bed.Parent and bedInfo then
			standPos = (st.bed.CFrame * CFrame.new(bedInfo.standOffset)).Position
		else
			standPos = root.Position + Vector3.new(0, 2.5, 0)
		end
		local look = st.bed and st.bed.Parent and Util.Flat(st.bed.CFrame.LookVector) or Vector3.new(0, 0, -1)
		if look.Magnitude < 0.1 then
			look = Vector3.new(0, 0, -1)
		end
		root.CFrame = CFrame.lookAt(standPos, standPos + look.Unit)
		root.AssemblyLinearVelocity = Vector3.zero
		if hum and hum.Health > 0 then
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	end
	-- Сварка с койкой автобуса отдавала персонажа серверу — возвращаем владение игроку
	if root and root.Parent and player.Parent and reason ~= "left" then
		pcall(function()
			root:SetNetworkOwner(player)
		end)
		task.delay(0.2, function()
			if root.Parent and player.Parent and player.Character == char and not sleepers[player] then
				pcall(function()
					if root:GetNetworkOwner() ~= player then
						root:SetNetworkOwner(player)
					end
				end)
			end
		end)
	end

	local d = PD.Get(player)
	local class = d and Classes.Get(d.ClassId)
	local rested = false
	if d and not d.Dead and reason ~= "died" and reason ~= "left" then
		if reason == "attacked" then
			if class and class.rageOnWake then
				PD.AddEffect(player, "Adrenaline", 12)
				PD.Notify(player, "Вас разбудили ударом — вы в ярости!", RED)
			else
				PD.AddEffect(player, "Sleepy", Config.Sleep.SleepyDuration)
				PD.Notify(player, "На вас напали во сне! Вы ещё сонный", RED)
			end
		elseif reason == "noise" then
			if class and class.rageOnWake then
				PD.AddEffect(player, "Adrenaline", 12)
				PD.Notify(player, "Рычание разбудило вас — ярость!", RED)
			else
				PD.AddEffect(player, "Adrenaline", 4)
				PD.Notify(player, "Вас разбудил шум — зомби совсем рядом!", ORANGE)
			end
		elseif reason == "alarm" then
			PD.AddEffect(player, "Adrenaline", 6)
			PD.Notify(player, "Сигнализация! Зомби подходят к автобусу", ORANGE)
		elseif reason == "nightmare" then
			if root then
				S.Zombies.Alert(root.Position, Config.Sleep.NightmareAlertRadius)
			end
			PD.Notify(player, "Кошмар! Вы проснулись с криком — зомби услышали", RED)
		elseif CALM_REASONS[reason] then
			if os.clock() - st.start >= RESTED_TIME then
				rested = true
				PD.AddEffect(player, "WellRested", Config.Sleep.WellRestedDuration)
				local minutes = math.max(1, math.floor(Config.Sleep.WellRestedDuration / 60 + 0.5))
				PD.Notify(player, string.format("%sВы выспались! +15%% урона на %d мин", reason == "dawn" and "Рассвет. " or "", minutes), BLUE)
			elseif reason == "friend" then
				PD.Notify(player, "Вас разбудили", BLUE)
			elseif reason == "dawn" then
				PD.Notify(player, "Рассвет — пора вставать. Поспать толком не удалось", BLUE)
			else
				PD.Notify(player, "Слишком мало поспали — не выспались", BLUE)
			end
		end
	end
	Net.Get("SleepEvent"):FireClient(player, "wake", { reason = reason, rested = rested })
end

function Sleep.AllAsleep()
	local anyAsleep = false
	for _, plr in ipairs(Players:GetPlayers()) do
		local d = PD.Get(plr)
		if d and not d.Dead then
			if sleepers[plr] then
				anyAsleep = true
			elseif not d.Downed then
				return false
			end
		end
	end
	return anyAsleep
end

function Sleep.Clear()
	for plr in pairs(sleepers) do
		Sleep.Wake(plr, "reset")
	end
end

local acc = 0
function Sleep.Update(dt)
	acc = acc + dt
	if acc < 0.25 then
		return
	end
	local step = acc
	acc = 0
	if not next(sleepers) then
		S.DayNight.SetTimeScale(1)
		return
	end
	local zombies = S.Zombies.List()
	local alarmRadius, alarmLevel = Sleep.AlarmHearRadius()
	local bunksMult = Upgrades.Value("bunks", "sleepMult", busLevel("bunks"), 1)
	local now = os.clock()
	local night = S.DayNight.IsNight()
	local onlyNight = nightOnly()

	for player, st in pairs(sleepers) do
		local d = PD.Get(player)
		local char = player.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local anchorPart = st.weld.Part0
		if not d or d.Dead or not hum or hum.Health <= 0 or not root or not st.weld.Parent or not anchorPart or not anchorPart:IsDescendantOf(workspace) then
			Sleep.Wake(player, "invalid")
		elseif onlyNight and not night then
			-- рассвет: спящие просыпаются сами («Выспался», если спали достаточно и без помех)
			Sleep.Wake(player, "dawn")
		else
			-- Лечение во сне за счёт сытости (на пустой желудок сон не лечит); койки автобуса — быстрее
			if not d.Downed and hum.Health < hum.MaxHealth then
				local rate = HEAL_RATE * Classes.Perk(d.ClassId, "sleepMult", 1)
				local bedInfo = st.bed and beds[st.bed]
				if bedInfo and bedInfo.kind == "bus" then
					rate = rate * bunksMult
				end
				PD.HealWithHunger(player, rate * step)
			end

			-- Угроза: чем ближе и громче зомби, тем быстрее растёт
			local useAlarm = alarmLevel > 0 and busInside(root.Position)
			local radius = useAlarm and alarmRadius or Config.Sleep.HearRadius
			local gain = 0
			for _, z in ipairs(zombies) do
				if not z.dead and z.root then
					local dist = (z.root.Position - root.Position).Magnitude
					if dist < radius then
						gain = gain + (1 - dist / radius) * (z.def.noise or 1)
					end
				end
			end
			if gain > 0 then
				st.threat = st.threat + gain * Config.Sleep.ThreatGain * step
			else
				st.threat = math.max(0, st.threat - Config.Sleep.ThreatDecay * step)
			end
			local threshold = useAlarm and Config.Sleep.AlarmWakeThreshold or Config.Sleep.WakeThreshold
			local shown = math.floor(math.clamp(st.threat / threshold, 0, 1) * 20) / 20
			if shown ~= st.sentThreat then
				st.sentThreat = shown
				player:SetAttribute("SleepThreat", shown)
				player:SetAttribute("SleepAlarm", useAlarm)
			end

			if st.threat >= threshold then
				Sleep.Wake(player, useAlarm and "alarm" or "noise")
			elseif st.nightmareAt and now >= st.nightmareAt then
				Net.Get("SleepEvent"):FireClient(player, "nightmare", {})
				st.nightmareAt = nil
				task.delay(0.9, function()
					if sleepers[player] == st then
						Sleep.Wake(player, "nightmare")
					end
				end)
			elseif not night and now - st.start >= RESTED_TIME and hum.Health >= hum.MaxHealth - 0.5 then
				-- день (или наступило утро), здоровье полное — просыпается сам
				Sleep.Wake(player, "rested")
			end
		end
	end

	S.DayNight.SetTimeScale((night and Sleep.AllAsleep()) and Config.Sleep.TimeScaleAllAsleep or 1)
end

return Sleep
