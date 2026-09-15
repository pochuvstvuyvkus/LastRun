-- Прогрессия на экране (v3): окно ежедневных наград (7 дней) и тост повышения уровня в тёмной теме.
-- Полосу уровня рисует LobbyUI (только в лобби); в заезде полосы уровня нет.
-- API: OpenDaily(), CloseDaily(), Toggle(), IsOpen(), GetProfile(), HasClaimable(), OnChanged(fn)
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Progression = require(Shared.Progression)
local Items = require(Shared.Items)
local Net = require(Shared.Net)

local ProgressUI = {}
local C
local player = Players.LocalPlayer
local rgb = Color3.fromRGB

-- Тема
local WHITE = rgb(240, 240, 240)
local DIM = rgb(165, 165, 170)
local ACCENT = rgb(255, 170, 60)
local GREEN = rgb(70, 175, 90)
local GREEN_TEXT = rgb(120, 220, 130)
local YELLOW = rgb(255, 210, 90)
local DISABLED = rgb(55, 55, 58)

local modalGui, toastGui
local modal, streakLabel, hintLabel, claimButton, statusLabel
local toast, toastTitle, toastLevel, toastSub
local scales = {}
local cards = {}

local profile = nil -- последний снимок ProfileSync
local daily = nil -- последняя информация DailyReward
local dailyReceivedAt = 0
local claimPending = false
local countdownToken = 0
local closeAfterClaimToken = 0
local toastToken = 0
local listeners = {}

-- Помощники -------------------------------------------------------------------------------------

local function new(className, props, parent)
	local inst = Instance.new(className)
	for k, v in pairs(props or {}) do
		inst[k] = v
	end
	inst.Parent = parent
	return inst
end

local function frame(parent, props)
	local f = new("Frame", { BorderSizePixel = 0, BackgroundColor3 = rgb(0, 0, 0) }, nil)
	for k, v in pairs(props or {}) do
		f[k] = v
	end
	f.Parent = parent
	return f
end

local function corner(parent, px)
	return new("UICorner", { CornerRadius = UDim.new(0, px or 4) }, parent)
end

local function round(parent)
	return new("UICorner", { CornerRadius = UDim.new(0.5, 0) }, parent)
end

local function stroke(parent, color, thickness, transparency)
	return new("UIStroke", {
		Color = color or WHITE,
		Thickness = thickness or 1,
		Transparency = transparency or 0.6,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	}, parent)
end

local function label(parent, props)
	local l = new("TextLabel", {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextColor3 = WHITE,
		TextSize = 16,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextStrokeTransparency = 0.5,
		TextStrokeColor3 = rgb(0, 0, 0),
	}, nil)
	for k, v in pairs(props or {}) do
		l[k] = v
	end
	l.Parent = parent
	return l
end

local function button(parent, props, onClick)
	local b = new("TextButton", {
		BorderSizePixel = 0,
		BackgroundColor3 = rgb(0, 0, 0),
		BackgroundTransparency = 0.35,
		Font = Enum.Font.GothamBlack,
		TextColor3 = WHITE,
		TextSize = 16,
		TextStrokeTransparency = 0.5,
		AutoButtonColor = true,
	}, nil)
	for k, v in pairs(props or {}) do
		b[k] = v
	end
	corner(b, 4)
	b.Parent = parent
	if onClick then
		b.MouseButton1Click:Connect(onClick)
	end
	return b
end

local function playSound(pitch)
	if C and C.Effects and C.Effects.Play then
		pcall(C.Effects.Play, "ui", nil, pitch)
	end
end

local function addScale(target)
	local s = new("UIScale", {}, target)
	table.insert(scales, s)
	return s
end

local function updateScale()
	local cam = workspace.CurrentCamera
	if not cam then
		return
	end
	local vp = cam.ViewportSize
	if vp.X < 2 or vp.Y < 2 then
		return
	end
	local s = math.clamp(math.min(vp.X / 1280, vp.Y / 720), 0.55, 1)
	for _, sc in ipairs(scales) do
		sc.Scale = s
	end
end

local function fireChanged()
	for _, fn in ipairs(listeners) do
		task.spawn(fn)
	end
end

local function formatDuration(sec)
	sec = math.max(0, math.floor(sec))
	local h = math.floor(sec / 3600)
	local m = math.floor((sec % 3600) / 60)
	if h > 0 then
		return h .. " ч " .. m .. " мин"
	end
	return math.max(1, m) .. " мин"
end

local function rewardLines(reward)
	local lines = {}
	if type(reward) ~= "table" then
		return lines
	end
	if reward.tickets and reward.tickets > 0 then
		table.insert(lines, reward.tickets .. " билетов")
	end
	if reward.xp and reward.xp > 0 then
		table.insert(lines, reward.xp .. " опыта")
	end
	if type(reward.items) == "table" then
		local itemLines = {}
		for id, n in pairs(reward.items) do
			local def = Items.List[id]
			table.insert(itemLines, (def and def.name or id) .. " ×" .. n)
		end
		table.sort(itemLines)
		for _, line in ipairs(itemLines) do
			table.insert(lines, line)
		end
	end
	return lines
end

-- Иконки из Frame ------------------------------------------------------------------------------

local function ticketIcon(parent, x, y, scale)
	scale = scale or 1
	local t = frame(parent, { Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(30 * scale, 18 * scale), BackgroundColor3 = rgb(230, 165, 55) })
	corner(t, 3)
	for _, px in ipairs({ -4 * scale, 26 * scale }) do
		local hole = frame(t, { Position = UDim2.fromOffset(px, 5 * scale), Size = UDim2.fromOffset(8 * scale, 8 * scale), BackgroundColor3 = rgb(18, 18, 20) })
		round(hole)
	end
	for i = 0, 2 do
		frame(t, { Position = UDim2.fromOffset(20 * scale, (2 + i * 5.5) * scale), Size = UDim2.fromOffset(2 * scale, 3 * scale), BackgroundColor3 = rgb(120, 80, 20) })
	end
	return t
end

local function checkIcon(parent, x, y, color)
	local holder = frame(parent, { Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(22, 22), BackgroundTransparency = 1 })
	frame(holder, { Position = UDim2.fromOffset(2, 11), Size = UDim2.fromOffset(9, 4), BackgroundColor3 = color, Rotation = 45 })
	frame(holder, { Position = UDim2.fromOffset(7, 8), Size = UDim2.fromOffset(15, 4), BackgroundColor3 = color, Rotation = -50 })
	return holder
end

-- Окно ежедневных наград -----------------------------------------------------------------------

local function secondsToNextDay()
	if not daily or type(daily.nextIn) ~= "number" then
		return nil
	end
	return daily.nextIn - (os.clock() - dailyReceivedAt)
end

local function setCard(card, kind, text)
	-- kind: "done" | "today" | "future" | "claimedToday"
	card.state.Text = text or ""
	card.check.Visible = kind == "done" or kind == "claimedToday"
	if kind == "today" then
		card.frame.BackgroundTransparency = 0.15
		card.frame.BackgroundColor3 = rgb(48, 34, 16)
		card.stroke.Color = ACCENT
		card.stroke.Transparency = 0
		card.stroke.Thickness = 2
		card.state.TextColor3 = ACCENT
	elseif kind == "done" or kind == "claimedToday" then
		card.frame.BackgroundTransparency = 0.35
		card.frame.BackgroundColor3 = rgb(10, 22, 14)
		card.stroke.Color = kind == "claimedToday" and GREEN_TEXT or WHITE
		card.stroke.Transparency = kind == "claimedToday" and 0.1 or 0.8
		card.stroke.Thickness = kind == "claimedToday" and 2 or 1
		card.state.TextColor3 = GREEN_TEXT
	else
		card.frame.BackgroundTransparency = 0.35
		card.frame.BackgroundColor3 = rgb(0, 0, 0)
		card.stroke.Color = WHITE
		card.stroke.Transparency = 0.75
		card.stroke.Thickness = 1
		card.state.TextColor3 = DIM
	end
end

local function setClaim(text, enabled)
	claimButton.Text = text
	claimButton.BackgroundColor3 = enabled and GREEN or DISABLED
	claimButton.BackgroundTransparency = 0
	claimButton.AutoButtonColor = enabled
	claimButton.TextColor3 = enabled and WHITE or DIM
end

local function refreshModal()
	if not modal then
		return
	end
	local info = daily
	if not info then
		streakLabel.Text = "Загрузка профиля..."
		hintLabel.Text = ""
		for _, card in ipairs(cards) do
			setCard(card, "future", "")
		end
		setClaim("...", false)
		statusLabel.Text = ""
		return
	end

	local day = math.clamp(tonumber(info.day) or 1, 1, 7)
	local claimable = info.claimable == true
	local streak = tonumber(info.streak) or 0
	streakLabel.Text = "Серия: " .. streak .. " дн. — заходите каждый день, награды растут"
	hintLabel.Text = "Билеты и опыт начисляются сразу, предметы — в начале следующего заезда"

	local tomorrow = (day % 7) + 1
	for i, card in ipairs(cards) do
		if claimable then
			if i < day then
				setCard(card, "done", "Получено")
			elseif i == day then
				setCard(card, "today", "СЕГОДНЯ")
			else
				setCard(card, "future", "")
			end
		else
			if i < day then
				setCard(card, "done", "Получено")
			elseif i == day then
				setCard(card, "claimedToday", "Сегодня")
			else
				setCard(card, "future", i == tomorrow and "Завтра" or "")
			end
		end
		-- после 7-го дня цикл начинается заново
		if not claimable and day == 7 and i == 1 then
			setCard(card, "future", "Завтра")
		end
	end

	if claimable and info.allowed ~= false then
		setClaim(claimPending and "..." or "ЗАБРАТЬ", not claimPending)
		statusLabel.Text = "Награда дня " .. day .. " ждёт вас!"
		statusLabel.TextColor3 = YELLOW
	elseif claimable then
		setClaim("НЕДОСТУПНО", false)
		statusLabel.Text = "Профиль не загружен — перезайдите, чтобы получить награду"
		statusLabel.TextColor3 = rgb(255, 150, 80)
	else
		setClaim("ПОЛУЧЕНО", false)
		local left = secondsToNextDay()
		statusLabel.Text = left and ("Следующая награда через " .. formatDuration(left)) or "Приходите завтра!"
		statusLabel.TextColor3 = DIM
	end
end

local function startCountdown()
	countdownToken = countdownToken + 1
	local token = countdownToken
	task.spawn(function()
		while token == countdownToken and modal and modal.Visible do
			task.wait(1)
			if token ~= countdownToken or not modal.Visible then
				break
			end
			if daily and not daily.claimable then
				local left = secondsToNextDay()
				if left then
					statusLabel.Text = left <= 0 and "Новая награда уже доступна — откройте окно заново" or ("Следующая награда через " .. formatDuration(left))
				end
			end
		end
	end)
end

local function buildModal()
	modalGui = new("ScreenGui", { Name = "DailyReward", ResetOnSpawn = false, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 11 }, player:WaitForChild("PlayerGui"))
	local W, H = 760, 400
	modal = frame(modalGui, {
		Name = "Window",
		Size = UDim2.fromOffset(W, H),
		Position = UDim2.fromScale(0.5, 0.5),
		AnchorPoint = Vector2.new(0.5, 0.5),
		BackgroundColor3 = rgb(8, 8, 10),
		BackgroundTransparency = 0.12,
		Visible = false,
	})
	addScale(modal)
	corner(modal, 4)
	stroke(modal, WHITE, 1, 0.55)

	label(modal, { Size = UDim2.new(1, -80, 0, 40), Position = UDim2.fromOffset(20, 10), Font = Enum.Font.GothamBlack, TextSize = 26, TextColor3 = ACCENT, Text = "ЕЖЕДНЕВНЫЕ НАГРАДЫ" })
	local close = button(modal, { Size = UDim2.fromOffset(36, 36), Position = UDim2.new(1, -48, 0, 12), Text = "X", TextSize = 18 }, function()
		ProgressUI.CloseDaily()
	end)
	stroke(close, WHITE, 1, 0.5)
	frame(modal, { Size = UDim2.new(1, -40, 0, 1), Position = UDim2.fromOffset(20, 56), BackgroundColor3 = WHITE, BackgroundTransparency = 0.8 })
	streakLabel = label(modal, { Size = UDim2.new(1, -40, 0, 22), Position = UDim2.fromOffset(20, 64), TextSize = 15, Text = "" })

	local gap = 8
	local cardW = math.floor((W - 40 - gap * 6) / 7)
	local cardH = 190
	for i = 1, 7 do
		local card = frame(modal, { Size = UDim2.fromOffset(cardW, cardH), Position = UDim2.fromOffset(20 + (i - 1) * (cardW + gap), 96), BackgroundTransparency = 0.35 })
		corner(card, 4)
		local st = stroke(card, WHITE, 1, 0.75)
		label(card, { Size = UDim2.new(1, 0, 0, 26), Position = UDim2.fromOffset(0, 6), TextXAlignment = Enum.TextXAlignment.Center, Font = Enum.Font.GothamBlack, TextSize = 16, Text = "ДЕНЬ " .. i })
		local reward = Progression.Daily[i]
		if type(reward) == "table" and (reward.tickets or 0) > 0 then
			ticketIcon(card, math.floor(cardW / 2 - 18), 40, 1.2)
		end
		label(card, {
			Size = UDim2.new(1, -8, 0, 90),
			Position = UDim2.fromOffset(4, 70),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextYAlignment = Enum.TextYAlignment.Top,
			TextWrapped = true,
			TextSize = 12,
			Font = Enum.Font.GothamBold,
			Text = table.concat(rewardLines(reward), "\n"),
		})
		local state = label(card, { Size = UDim2.new(1, -30, 0, 22), Position = UDim2.new(0, 4, 1, -28), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 12, Text = "" })
		local check = checkIcon(card, cardW - 28, cardH - 28, GREEN_TEXT)
		check.Visible = false
		cards[i] = { frame = card, stroke = st, state = state, check = check }
	end

	hintLabel = label(modal, { Size = UDim2.new(1, -40, 0, 18), Position = UDim2.fromOffset(20, 296), TextSize = 12, Font = Enum.Font.GothamBold, TextColor3 = DIM, Text = "" })
	statusLabel = label(modal, { Size = UDim2.new(1, -280, 0, 56), Position = UDim2.fromOffset(20, 326), TextSize = 16, TextWrapped = true, TextColor3 = DIM, Text = "" })
	claimButton = button(modal, { Size = UDim2.fromOffset(230, 56), Position = UDim2.new(1, -250, 0, 326), Text = "ЗАБРАТЬ", TextSize = 22, BackgroundColor3 = GREEN, BackgroundTransparency = 0 }, function()
		if claimPending or not daily or not daily.claimable or daily.allowed == false then
			return
		end
		claimPending = true
		playSound(1.2)
		Net.Get("ClaimDaily"):FireServer()
		refreshModal()
		task.delay(4, function()
			if claimPending then
				claimPending = false
				refreshModal()
			end
		end)
	end)
	stroke(claimButton, WHITE, 1.5, 0.3)
end

-- Тост повышения уровня -------------------------------------------------------------------------

local function buildToast()
	toastGui = new("ScreenGui", { Name = "LevelToast", ResetOnSpawn = false, IgnoreGuiInset = true, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, DisplayOrder = 13 }, player:WaitForChild("PlayerGui"))
	local holder = frame(toastGui, { AnchorPoint = Vector2.new(0.5, 0), Position = UDim2.new(0.5, 0, 0, 96), Size = UDim2.fromOffset(380, 96), BackgroundTransparency = 1 })
	addScale(holder)
	toast = frame(holder, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = rgb(0, 0, 0), BackgroundTransparency = 0.3, Visible = false })
	corner(toast, 4)
	stroke(toast, ACCENT, 1.5, 0.2)
	frame(toast, { Size = UDim2.new(0, 4, 1, -16), Position = UDim2.fromOffset(8, 8), BackgroundColor3 = ACCENT })
	toastTitle = label(toast, { Size = UDim2.new(1, -40, 0, 20), Position = UDim2.fromOffset(24, 8), TextSize = 14, TextColor3 = ACCENT, Font = Enum.Font.GothamBlack, Text = "НОВЫЙ УРОВЕНЬ" })
	toastLevel = label(toast, { Size = UDim2.new(1, -40, 0, 38), Position = UDim2.fromOffset(24, 28), TextSize = 32, Font = Enum.Font.GothamBlack, Text = "" })
	toastSub = label(toast, { Size = UDim2.new(1, -40, 0, 20), Position = UDim2.fromOffset(24, 68), TextSize = 13, TextColor3 = DIM, Text = "" })
end

local function showLevelToast(level)
	if not toast then
		return
	end
	toastToken = toastToken + 1
	local token = toastToken
	local perks = Progression.LevelPerks(level)
	toastLevel.Text = "УРОВЕНЬ " .. level
	toastSub.Text = string.format("Здоровье +%d  ·  урон +%d%%", perks.bonusHP, math.floor(perks.damageBonus * 100 + 0.5))
	toast.Visible = true
	toast.Position = UDim2.fromOffset(0, -20)
	toast.BackgroundTransparency = 1
	for _, l in ipairs({ toastTitle, toastLevel, toastSub }) do
		l.TextTransparency = 1
		TweenService:Create(l, TweenInfo.new(0.3), { TextTransparency = 0 }):Play()
	end
	TweenService:Create(toast, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Position = UDim2.fromOffset(0, 0), BackgroundTransparency = 0.3 }):Play()
	task.delay(3.2, function()
		if token ~= toastToken then
			return
		end
		for _, l in ipairs({ toastTitle, toastLevel, toastSub }) do
			TweenService:Create(l, TweenInfo.new(0.4), { TextTransparency = 1 }):Play()
		end
		TweenService:Create(toast, TweenInfo.new(0.4), { BackgroundTransparency = 1 }):Play()
		task.delay(0.45, function()
			if token == toastToken then
				toast.Visible = false
			end
		end)
	end)
end

-- Публичный API ---------------------------------------------------------------------------------

function ProgressUI.IsOpen()
	return modal ~= nil and modal.Visible
end

function ProgressUI.OpenDaily()
	if not modal then
		return
	end
	closeAfterClaimToken = closeAfterClaimToken + 1 -- игрок открыл окно сам: не закрывать автоматически
	refreshModal()
	if not modal.Visible then
		modal.Visible = true
		playSound()
		startCountdown()
	end
end

function ProgressUI.CloseDaily()
	if modal and modal.Visible then
		modal.Visible = false
		countdownToken = countdownToken + 1
	end
end

function ProgressUI.Toggle()
	if ProgressUI.IsOpen() then
		ProgressUI.CloseDaily()
	else
		ProgressUI.OpenDaily()
	end
end

-- Последний снимок профиля (уровень, билеты, статистика) — для других окон клиента
function ProgressUI.GetProfile()
	return profile
end

-- Есть ли награда дня, которую можно забрать
function ProgressUI.HasClaimable()
	return type(daily) == "table" and daily.claimable == true and daily.allowed ~= false
end

-- Подписка на изменения профиля/награды
function ProgressUI.OnChanged(fn)
	if type(fn) == "function" then
		table.insert(listeners, fn)
	end
end

-- События ---------------------------------------------------------------------------------------

local function applyDaily(info)
	if type(info) ~= "table" then
		return
	end
	daily = info
	dailyReceivedAt = os.clock()
	if modal and modal.Visible then
		refreshModal()
	end
end

local function onProfileSync(snapshot)
	if type(snapshot) ~= "table" then
		return
	end
	profile = snapshot
	if type(snapshot.daily) == "table" then
		-- снимок не открывает окно и не сбрасывает ожидание ответа на «Забрать»
		local info = snapshot.daily
		info.open = false
		applyDaily(info)
	end
	fireChanged()
end

local function onDailyReward(info)
	if type(info) ~= "table" then
		return
	end
	local wasPending = claimPending
	claimPending = false
	applyDaily(info)
	if info.justClaimed then
		playSound(1.5)
		refreshModal()
		closeAfterClaimToken = closeAfterClaimToken + 1
		local token = closeAfterClaimToken
		task.delay(2, function()
			if token == closeAfterClaimToken then
				ProgressUI.CloseDaily()
			end
		end)
	elseif info.open and info.claimable then
		ProgressUI.OpenDaily()
	elseif wasPending then
		refreshModal()
	end
	fireChanged()
end

local function onLevelUp(level)
	if type(level) ~= "number" then
		return
	end
	showLevelToast(level)
	playSound(1.6)
	fireChanged()
end

local cameraConn = nil
local function watchCamera()
	if cameraConn then
		cameraConn:Disconnect()
		cameraConn = nil
	end
	local cam = workspace.CurrentCamera
	if cam then
		cameraConn = cam:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale)
	end
	updateScale()
end

function ProgressUI.Init(c)
	C = c
	buildModal()
	buildToast()

	if C.Panels and C.Panels.RegisterWindow then
		C.Panels.RegisterWindow(ProgressUI.IsOpen, ProgressUI.CloseDaily)
	end

	Net.Get("ProfileSync").OnClientEvent:Connect(onProfileSync)
	Net.Get("DailyReward").OnClientEvent:Connect(onDailyReward)
	Net.Get("LevelUp").OnClientEvent:Connect(onLevelUp)

	-- в заезде окно наград не держим открытым поверх боя
	Net.State():GetAttributeChangedSignal("Mode"):Connect(function()
		if Net.State():GetAttribute("Mode") ~= "lobby" then
			ProgressUI.CloseDaily()
		end
	end)

	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
	watchCamera()
end

return ProgressUI
