-- Сон на клиенте (v4): затемнение, растущая «опасность» от зомби, кошмары, резкое пробуждение.
-- Бодрости больше нет: ни виньетки усталости, ни микроснов. Сервер шлёт SleepEvent:
-- "start" {bed}, "wake" {reason, rested}, "nightmare".
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local SleepClient = {}
local C
local UI
local player = Players.LocalPlayer
local rgb = Color3.fromRGB

local RED_EDGE = rgb(170, 0, 0)
local FLASH_TIME = 1.2

local gui, black, edgesGroup, edges, center, title, status, threatBar, threatLabel, hint, wakeButton, blur, flashLabel, eyes
local sleeping = false
local sleepStarted = 0
local flashStart, flashUntil = 0, 0
local blackTween, blackToken = nil, 0
local flashToken = 0
local idleAcc = 0
local sleepyBlur = 0

local STATUS = {
	{ 0.3, "Вы крепко спите..." },
	{ 0.6, "Сквозь сон слышно рычание..." },
	{ 0.85, "Что-то скребётся совсем рядом!" },
	{ 1.01, "ПРОСНИСЬ!" },
}

-- Все изменения чёрного экрана — только здесь: предыдущий твин всегда отменяется
local function setBlack(transparency, time)
	blackToken = blackToken + 1
	if blackTween then
		blackTween:Cancel()
		blackTween = nil
	end
	if time and time > 0 then
		blackTween = UI.Tween(black, time, { BackgroundTransparency = transparency })
	else
		black.BackgroundTransparency = transparency
	end
	return blackToken
end

local flashTween = nil
local function flash(text, color)
	flashToken = flashToken + 1
	local token = flashToken
	-- гасим прошлое затухание: иначе оно перезаписывает прозрачность новой надписи
	if flashTween then
		flashTween:Cancel()
		flashTween = nil
	end
	flashLabel.Text = text
	flashLabel.TextColor3 = color
	flashLabel.TextTransparency = 0
	flashLabel.TextStrokeTransparency = 0.4
	flashLabel.Visible = true
	task.delay(0.6, function()
		if token == flashToken then
			flashTween = UI.Tween(flashLabel, 0.8, { TextTransparency = 1, TextStrokeTransparency = 1 })
		end
	end)
end

local function showSleepUI(on)
	title.Visible = on
	status.Visible = on
	threatBar.Frame.Visible = on
	threatLabel.Visible = on
	hint.Visible = on
	wakeButton.Visible = on
end

local function hideOwnPrompts(char)
	local root = char:WaitForChild("HumanoidRootPart", 10)
	if not root then
		return
	end
	for _, name in ipairs({ "RevivePrompt", "WakePrompt" }) do
		task.spawn(function()
			local prompt = root:WaitForChild(name, 10)
			if prompt then
				prompt.Enabled = false
				prompt:GetPropertyChangedSignal("Enabled"):Connect(function()
					if prompt.Enabled then
						prompt.Enabled = false
					end
				end)
			end
		end)
	end
end

local function requestWake()
	if sleeping then
		Net.Get("WakeUp"):FireServer()
	end
end

local function onWake(reason, rested)
	sleeping = false
	showSleepUI(false)
	eyes.Visible = false
	if reason == "attacked" or reason == "noise" or reason == "alarm" or reason == "nightmare" then
		setBlack(1)
		local now = os.clock()
		flashStart = now
		flashUntil = now + FLASH_TIME
		blur.Size = 24
		C.Effects.Shake(0.9, 0.6)
		flash(reason == "alarm" and "ТРЕВОГА!" or "ПРОСНИСЬ!", rgb(255, 70, 50))
	else
		setBlack(1, 0.9)
		if rested then
			flash("ВЫ ВЫСПАЛИСЬ", rgb(150, 200, 255))
		end
	end
end

local function onEvent(event, data)
	data = type(data) == "table" and data or {}
	if event == "start" then
		sleeping = true
		sleepStarted = os.clock()
		flashUntil = 0
		title.Text = "Z z z"
		setBlack(0.12, 1.2)
		showSleepUI(true)
	elseif event == "wake" then
		onWake(data.reason, data.rested == true)
	elseif event == "nightmare" then
		setBlack(0)
		eyes.Visible = true
		flash("ОНИ ВНУТРИ", rgb(255, 40, 30))
		C.Effects.Shake(1, 0.8)
		task.delay(0.8, function()
			eyes.Visible = false
		end)
	end
end

local function render(dt)
	local now = os.clock()

	-- страховка: событие «wake» могло потеряться — не оставляем игрока в темноте
	if sleeping and now - sleepStarted > 2 and player:GetAttribute("Sleeping") ~= true then
		onWake("lost")
	end

	local targetBlur = 0
	if sleeping then
		local threat = player:GetAttribute("SleepThreat")
		threat = math.clamp(type(threat) == "number" and threat or 0, 0, 1)
		threatBar:Set(threat, "", rgb(255, 170, 60):Lerp(rgb(235, 50, 40), threat))
		threatLabel.Text = "Опасность " .. math.floor(threat * 100) .. "%" .. (player:GetAttribute("SleepAlarm") and "  ·  сигнализация включена" or "")
		for _, entry in ipairs(STATUS) do
			if threat < entry[1] then
				status.Text = entry[2]
				break
			end
		end
		status.TextColor3 = rgb(255, 255, 255):Lerp(rgb(255, 70, 50), threat)
		local pulse = 0.5 + 0.5 * math.sin(now * (3 + threat * 8))
		edgesGroup.GroupTransparency = 1 - math.clamp(threat * (0.55 + 0.45 * pulse), 0, 0.95)
		title.TextTransparency = 0.2 + 0.3 * math.sin(now * 1.5)
		targetBlur = 10 + threat * 8
		if threat > 0.6 and math.random() < dt * 4 then
			C.Effects.Shake(threat * 0.4, 0.2)
		end
	elseif now < flashUntil then
		-- красная вспышка резкого пробуждения
		edgesGroup.GroupTransparency = math.clamp((now - flashStart) / FLASH_TIME, 0, 1)
	else
		-- бодрствование: только лёгкое размытие «Сонный» после резкого пробуждения (проверка 5 Гц)
		idleAcc = idleAcc + dt
		if idleAcc >= 0.2 then
			idleAcc = 0
			local sleepyUntil = player:GetAttribute("Eff_Sleepy")
			sleepyBlur = (type(sleepyUntil) == "number" and sleepyUntil > workspace:GetServerTimeNow()) and 8 or 0
		end
		targetBlur = sleepyBlur
		if edgesGroup.GroupTransparency < 1 then
			edgesGroup.GroupTransparency = math.min(1, edgesGroup.GroupTransparency + dt)
		end
		if targetBlur == 0 and blur.Size < 0.05 then
			if blur.Size ~= 0 then
				blur.Size = 0
			end
			return
		end
	end
	blur.Size = blur.Size + (targetBlur - blur.Size) * math.min(1, dt * 3)
end

function SleepClient.Init(c)
	C = c
	UI = C.UI
	gui = UI.Screen("SleepOverlay", 20)

	black = UI.Frame(gui, { Size = UDim2.fromScale(1, 1), BackgroundColor3 = rgb(0, 0, 0), BackgroundTransparency = 1, ZIndex = 1 })

	edgesGroup = Instance.new("CanvasGroup")
	edgesGroup.Size = UDim2.fromScale(1, 1)
	edgesGroup.BackgroundTransparency = 1
	edgesGroup.GroupTransparency = 1
	edgesGroup.ZIndex = 2
	edgesGroup.Parent = gui
	edges = {}
	local function edge(pos, size, rotation)
		local f = UI.Frame(edgesGroup, { Position = pos, Size = size, BackgroundColor3 = RED_EDGE })
		local g = Instance.new("UIGradient")
		g.Rotation = rotation
		g.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0), NumberSequenceKeypoint.new(1, 1) })
		g.Parent = f
		table.insert(edges, f)
	end
	edge(UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.3), 90)
	edge(UDim2.fromScale(0, 0.7), UDim2.fromScale(1, 0.3), -90)
	edge(UDim2.fromScale(0, 0), UDim2.fromScale(0.25, 1), 0)
	edge(UDim2.fromScale(0.75, 0), UDim2.fromScale(0.25, 1), 180)

	eyes = UI.Frame(gui, { Size = UDim2.fromScale(1, 1), BackgroundTransparency = 1, ZIndex = 3, Visible = false })
	for _, x in ipairs({ 0.4, 0.56 }) do
		local eye = UI.Frame(eyes, { Size = UDim2.fromScale(0.05, 0.03), Position = UDim2.fromScale(x, 0.42), BackgroundColor3 = rgb(255, 30, 20), ZIndex = 3 })
		UI.Corner(eye, 20)
	end

	-- центральный блок текста масштабируется под экран (тема: белый жирный текст с обводкой,
	-- тонкая полоса опасности, «клавиша» подсказки, оранжевая кнопка)
	center = UI.Frame(gui, { Size = UDim2.fromOffset(640, 300), Position = UDim2.new(0.5, 0, 0.3, 0), AnchorPoint = Vector2.new(0.5, 0), BackgroundTransparency = 1, ZIndex = 5 })
	UI.AddScale(center)

	title = UI.Label(center, { Size = UDim2.new(1, 0, 0, 70), Position = UDim2.fromOffset(0, 0), TextXAlignment = Enum.TextXAlignment.Center, Font = UI.Theme.fontBlack, TextSize = 56, Text = "Z z z", TextColor3 = rgb(170, 190, 255), TextStrokeTransparency = 0.5, ZIndex = 5, Visible = false })
	status = UI.Label(center, { Size = UDim2.new(1, 0, 0, 28), Position = UDim2.fromOffset(0, 80), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 21, Text = "", TextStrokeTransparency = 0.4, ZIndex = 5, Visible = false })
	threatBar = UI.Bar(center, { Size = UDim2.fromOffset(320, 8), Position = UDim2.new(0.5, -160, 0, 122), Color = rgb(255, 170, 60), TextSize = 1, Radius = 2 })
	threatBar.Frame.ZIndex = 5
	threatBar.Fill.ZIndex = 5
	threatBar.Label.ZIndex = 6
	threatBar.Frame.Visible = false
	threatLabel = UI.Label(center, { Size = UDim2.new(1, 0, 0, 18), Position = UDim2.fromOffset(0, 134), TextXAlignment = Enum.TextXAlignment.Center, TextSize = 13, TextColor3 = rgb(220, 220, 225), Text = "", ZIndex = 5, Visible = false })
	hint = UI.Frame(center, { Size = UDim2.fromOffset(240, 22), Position = UDim2.new(0.5, -120, 0, 170), BackgroundTransparency = 1, ZIndex = 5, Visible = false })
	local hintLayout = UI.List(hint, 6, true)
	hintLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	hintLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	UI.KeyCap(hint, "Пробел", { LayoutOrder = 1, ZIndex = 5 })
	UI.Label(hint, { Size = UDim2.fromOffset(0, 22), AutomaticSize = Enum.AutomaticSize.X, Text = "проснуться", TextSize = 15, LayoutOrder = 2, ZIndex = 5 })
	wakeButton = UI.ActionButton(center, { Size = UDim2.fromOffset(180, 38), Position = UDim2.new(0.5, -90, 0, 204), Text = "Проснуться", ZIndex = 6, Visible = false }, "primary", requestWake)
	flashLabel = UI.Label(center, { Size = UDim2.new(1, 0, 0, 90), Position = UDim2.fromOffset(0, 40), TextXAlignment = Enum.TextXAlignment.Center, Font = UI.Theme.fontBlack, TextSize = 68, Text = "", TextStrokeTransparency = 0.4, ZIndex = 8, Visible = false })

	blur = Instance.new("BlurEffect")
	blur.Size = 0
	blur.Parent = workspace.CurrentCamera

	Net.Get("SleepEvent").OnClientEvent:Connect(onEvent)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.KeyCode == Enum.KeyCode.Space then
			requestWake()
		end
	end)

	if player.Character then
		task.spawn(hideOwnPrompts, player.Character)
	end
	player.CharacterAdded:Connect(function(char)
		sleeping = false
		flashUntil = 0
		showSleepUI(false)
		eyes.Visible = false
		setBlack(1)
		task.spawn(hideOwnPrompts, char)
	end)

	RunService.RenderStepped:Connect(render)
end

return SleepClient
