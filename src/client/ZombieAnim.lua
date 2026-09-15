-- Анимации врагов на клиенте (ходьба, бег, ползание, удар с замахом и рывком, взрыв толстяка,
-- удар босса, способности элиты, пульсация гнезда, стойка мародёра), вздрагивание при попадании,
-- падение при смерти, рычание ближайших зомби и полоски здоровья над головой
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared.Util)
local ZombieDefs = require(Shared.Zombies)
local Net = require(Shared.Net)

local ZombieAnim = {}
local C
local zombies = {}
local rgb = Color3.fromRGB
local rng = Random.new()
local lastGroan = -10
local groanAcc = 0
local lastDeathSound = -10

local ABILITY_ATTRS = { "Throw", "Dash", "Summon", "Cast", "Roar" }
local FLINCH_JOINTS = { "Root", "Neck", "RightShoulder", "LeftShoulder" }

local function camPosition()
	local cam = workspace.CurrentCamera
	return cam and cam.CFrame.Position or Vector3.zero
end

-- Глаза: днём мутные (как собрал сервер), ночью слабо светятся цветом из атрибута Glow;
-- в кровавую луну — ярче и краснее. Меняется только локально, без создания объектов.
local nightEyes = false
local bloodEyes = false
local DEFAULT_GLOW = rgb(170, 36, 28)

local function applyEyes(z)
	local eyes = z.eyes
	if not eyes then
		return
	end
	for _, e in ipairs(eyes) do
		local part = e.part
		if part.Parent then
			if nightEyes then
				part.Material = Enum.Material.Neon
				part.Color = bloodEyes and e.glow:Lerp(rgb(255, 30, 20), 0.6) or e.glow
				part.Transparency = bloodEyes and 0.15 or 0.35
			else
				part.Material = Enum.Material.SmoothPlastic
				part.Color = e.day
				part.Transparency = 0
			end
		end
	end
end

local function addEye(z, part)
	if part.Name ~= "Eye" or not part:IsA("BasePart") then
		return false
	end
	z.eyes = z.eyes or {}
	for _, e in ipairs(z.eyes) do
		if e.part == part then
			return false
		end
	end
	local glow = part:GetAttribute("Glow")
	table.insert(z.eyes, { part = part, day = part.Color, glow = typeof(glow) == "Color3" and glow or DEFAULT_GLOW })
	return true
end

local function setJoint(z, name, pitch, yaw, roll)
	local m = z.motors[name]
	if not m or not m.Parent then
		return
	end
	local o = z.off[name]
	if o then
		pitch, yaw, roll = pitch + o[1], yaw + o[2], roll + o[3]
	end
	m.Transform = Util.JointTransform(z.base[name], CFrame.fromOrientation(math.rad(pitch), math.rad(yaw), math.rad(roll)))
end

-- Высота голоса по типу и размеру
local function voicePitch(z)
	local t = z.type
	local p = 1
	if t == "runner" then
		p = 1.15
	elseif t == "crawler" or t == "spitter" then
		p = 1.08
	elseif t == "brute" or t == "bloater" then
		p = 0.8
	elseif t == "conductor" then
		p = 0.6
	elseif z.elite then
		p = 0.72
	end
	local scale = z.def and z.def.scale or 1
	return p / math.sqrt(math.max(0.5, scale)) * rng:NextNumber(0.92, 1.06)
end

local function makeBar(z)
	local head = z.model:FindFirstChild("Head")
	if not head then
		return
	end
	local gui = Instance.new("BillboardGui")
	gui.LightInfluence = 0
	gui.Adornee = head
	local bg = Instance.new("Frame")
	bg.BackgroundColor3 = rgb(20, 20, 20)
	bg.BackgroundTransparency = 0.25
	bg.BorderSizePixel = 0
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = bg
	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BorderSizePixel = 0
	fill.Parent = bg
	local corner2 = Instance.new("UICorner")
	corner2.CornerRadius = UDim.new(0.5, 0)
	corner2.Parent = fill
	if z.elite then
		-- элита: имя и крупная полоска, видны всегда
		gui.Size = UDim2.fromOffset(180, 38)
		gui.StudsOffset = Vector3.new(0, head.Size.Y * 1.6 + 1, 0)
		gui.MaxDistance = 180
		gui.AlwaysOnTop = false
		local name = Instance.new("TextLabel")
		name.Size = UDim2.new(1, 0, 0, 20)
		name.BackgroundTransparency = 1
		name.Font = Enum.Font.GothamBlack
		name.TextSize = 15
		name.TextColor3 = rgb(210, 150, 255)
		name.TextStrokeTransparency = 0.2
		name.Text = z.model.Name
		name.Parent = gui
		bg.Size = UDim2.new(1, 0, 0, 12)
		bg.Position = UDim2.fromOffset(0, 22)
	else
		gui.Size = UDim2.new(4.5, 0, 0.45, 0)
		gui.StudsOffset = Vector3.new(0, head.Size.Y * 1.9, 0)
		gui.MaxDistance = 130
		bg.Size = UDim2.fromScale(1, 1)
	end
	bg.Parent = gui
	gui.Parent = head
	z.bar = gui
	z.fill = fill
end

local function onHealth(z, health)
	if health <= 0 then
		if z.bar then
			z.bar:Destroy()
			z.bar = nil
		end
		return
	end
	if z.type == "conductor" then
		return
	end
	if not z.bar then
		if health >= z.hum.MaxHealth and not z.elite then
			return
		end
		makeBar(z)
		if not z.bar then
			return
		end
	end
	local frac = math.clamp(health / math.max(1, z.hum.MaxHealth), 0, 1)
	z.fill.Size = UDim2.fromScale(frac, 1)
	if z.elite then
		z.fill.BackgroundColor3 = rgb(160, 70, 220):Lerp(rgb(220, 120, 255), frac)
		z.bar.Enabled = true
		z.barUntil = nil
	else
		z.fill.BackgroundColor3 = rgb(230, 60, 50):Lerp(rgb(110, 210, 90), frac)
		z.bar.Enabled = true
		z.barUntil = os.clock() + 4
	end
end

local function onDeath(z)
	z.deadAt = os.clock()
	z.deathSide = rng:NextNumber() < 0.5 and -1 or 1
	if z.nest or not (C and C.Effects) then
		return
	end
	local now = os.clock()
	if now - lastDeathSound > 0.1 and (z.root.Position - camPosition()).Magnitude < 120 then
		lastDeathSound = now
		local human = z.def ~= nil and z.def.human == true
		C.Effects.Play(human and "player_hurt" or "zombie_death", z.root.Position, human and 0.9 or voicePitch(z))
	end
end

local function register(model)
	if zombies[model] then
		return
	end
	local torso = model:WaitForChild("Torso", 5)
	local root = model:WaitForChild("HumanoidRootPart", 5)
	local hum = model:WaitForChild("Humanoid", 5)
	if not torso or not root or not hum or not model.Parent then
		return
	end
	local typeId = model:GetAttribute("ZType") or "walker"
	local def = ZombieDefs.Types[typeId]
	local now = os.clock()
	local z = {
		model = model,
		torso = torso,
		root = root,
		hum = hum,
		motors = {},
		base = {},
		off = {},
		phase = math.random() * 6,
		attackAt = -10,
		slamAt = -10,
		abilityAt = -10,
		abilityKind = nil,
		fuseAt = nil,
		hitAt = -10,
		hitMag = 1,
		hitSide = 1,
		lastHealth = hum.Health,
		nextGroan = now + rng:NextNumber(1.5, 7),
		torsoColor = torso.Color,
		type = typeId,
		def = def,
		elite = model:GetAttribute("Elite") == true or (def ~= nil and def.elite == true),
		nest = def ~= nil and def.stationary == true,
		-- походка от сервера: shamble / drag / limp / run / heavy / waddle / crawl / human / boss
		gait = model:GetAttribute("Gait") or "shamble",
		dragSide = model:GetAttribute("DragSide") == -1 and -1 or 1,
		hunch = tonumber(model:GetAttribute("Hunch")) or 0.5,
		burstAt = -10,
		lurchAt = -10,
		nextLurch = now + rng:NextNumber(2, 7),
	}
	for _, name in ipairs(FLINCH_JOINTS) do
		z.off[name] = { 0, 0, 0 }
	end
	local joints = {
		RightShoulder = { torso, "Right Shoulder" },
		LeftShoulder = { torso, "Left Shoulder" },
		RightHip = { torso, "Right Hip" },
		LeftHip = { torso, "Left Hip" },
		Neck = { torso, "Neck" },
		Root = { root, "RootJoint" },
	}
	for name, path in pairs(joints) do
		local m = path[1]:FindFirstChild(path[2])
		if m then
			z.motors[name] = m
			z.base[name] = m.C0
		end
	end
	if z.nest then
		local head = model:FindFirstChild("Head")
		z.mesh = head and head:FindFirstChildOfClass("SpecialMesh")
	end
	for _, d in ipairs(model:GetDescendants()) do
		addEye(z, d)
	end
	model.DescendantAdded:Connect(function(d)
		if addEye(z, d) then
			applyEyes(z)
		end
	end)
	applyEyes(z)
	model:GetAttributeChangedSignal("Burst"):Connect(function()
		z.burstAt = os.clock()
	end)
	model:GetAttributeChangedSignal("Attack"):Connect(function()
		local t = os.clock()
		z.attackAt = t
		-- рык при атаке (не у гнезда и не у мародёров-людей)
		if not z.nest and not (z.def and z.def.human) and C and C.Effects and t - (z.lastAttackSound or -10) > 1.2 then
			if (z.root.Position - camPosition()).Magnitude < 80 then
				z.lastAttackSound = t
				C.Effects.Play("zombie_attack", z.root.Position, voicePitch(z))
			end
		end
	end)
	model:GetAttributeChangedSignal("Slam"):Connect(function()
		z.slamAt = os.clock()
	end)
	model:GetAttributeChangedSignal("Fuse"):Connect(function()
		z.fuseAt = os.clock()
	end)
	for _, attr in ipairs(ABILITY_ATTRS) do
		model:GetAttributeChangedSignal(attr):Connect(function()
			z.abilityAt = os.clock()
			z.abilityKind = attr
		end)
	end
	model:GetAttributeChangedSignal("Elite"):Connect(function()
		z.elite = model:GetAttribute("Elite") == true
	end)
	hum.HealthChanged:Connect(function(h)
		local prev = z.lastHealth or h
		z.lastHealth = h
		if h > 0 and h < prev - 0.5 then
			local t = os.clock()
			-- не перебиваем более сильное вздрагивание от удара (OnHit)
			if t - z.hitAt > 0.12 then
				z.hitAt = t
				z.hitMag = math.clamp((prev - h) / math.max(1, hum.MaxHealth) * 4, 0.4, 1)
				z.hitSide = rng:NextNumber() < 0.5 and -1 or 1
			end
		end
		if h <= 0 and not z.deadAt then
			onDeath(z)
		end
		onHealth(z, h)
	end)
	zombies[model] = z
	if z.elite then
		onHealth(z, hum.Health)
	end
end

-- Попадание рядом с точкой (HitFx «flesh»): сильнее вздрагивает ближайший зомби
function ZombieAnim.OnHit(position, heavy, dir)
	if typeof(position) ~= "Vector3" then
		return
	end
	local best, bestDist = nil, 5
	for _, z in pairs(zombies) do
		if z.root.Parent and not z.deadAt then
			local d = (z.root.Position - position).Magnitude
			if d < bestDist then
				best, bestDist = z, d
			end
		end
	end
	if not best then
		return
	end
	best.hitAt = os.clock()
	best.hitMag = heavy and 1.4 or 1
	if typeof(dir) == "Vector3" and dir.Magnitude > 0.01 then
		local rel = best.root.CFrame:VectorToObjectSpace(dir)
		best.hitSide = rel.X >= 0 and 1 or -1
	else
		best.hitSide = rng:NextNumber() < 0.5 and -1 or 1
	end
end

-- Смещения вздрагивания (добавляются в setJoint)
local function updateFlinch(z, now)
	local x = now - z.hitAt
	local k = 0
	if x < 0.38 then
		k = (x < 0.07 and (x / 0.07) or (1 - (x - 0.07) / 0.31) ^ 2) * z.hitMag
	end
	local o = z.off
	local side = z.hitSide
	o.Root[1], o.Root[2], o.Root[3] = 14 * k, 0, 7 * k * side
	o.Neck[1], o.Neck[2], o.Neck[3] = 24 * k, 12 * k * side, 0
	o.RightShoulder[1], o.RightShoulder[2], o.RightShoulder[3] = 22 * k, 0, 0
	o.LeftShoulder[1], o.LeftShoulder[2], o.LeftShoulder[3] = 18 * k, 0, 0
	return k
end

-- Удар: замах (руки вверх, корпус назад) -> рывок (руки вниз, корпус вперёд) -> возврат.
-- Возвращает добавку к рукам, наклон корпуса и силу рывка 0..1
local function attackCurve(t)
	if t < 0 or t >= 0.6 then
		return 0, 0, 0
	end
	if t < 0.28 then
		local w = Util.Smooth(t / 0.28)
		return 50 * w, 7 * w, 0
	end
	if t < 0.4 then
		local s = Util.Smooth((t - 0.28) / 0.12)
		return 50 - 90 * s, 7 - 33 * s, s
	end
	local r = Util.Smooth((t - 0.4) / 0.2)
	return -40 * (1 - r), -26 * (1 - r), 1 - r
end

-- Базовая поза «зомби» (руки вперёд, покачивание) с замахом и рывком.
-- Походки: ковыляние (неровный шаг, руки вразнобой, спотыкания), волочение ноги (прямая нога
-- отстаёт и развёрнута, корпус кренится на здоровую сторону), хромота, тяжёлый шаг, переваливание.
-- Знаки: pitch > 0 — конечность вперёд / корпус назад; roll > 0 — корпус влево, стопа вправо.
local function zombiePose(z, now, s, move, arm, strike, armBase, pitch)
	local gait = z.gait
	local side = z.dragSide or 1
	local hunch = z.hunch or 0.5
	local abs = math.abs(s)
	if move > 0.3 and now >= z.nextLurch and (gait == "shamble" or gait == "drag" or gait == "limp") then
		z.lurchAt = now
		z.nextLurch = now + rng:NextNumber(3, 8)
	end
	local lurch = 0
	local lt = now - z.lurchAt
	if lt >= 0 and lt < 0.6 then
		lurch = math.sin(lt / 0.6 * math.pi)
	end
	local sway = math.sin(z.phase * 0.5) * 8
	local rsP, lsP = armBase + sway + arm, armBase - sway + arm * 0.9
	local rhP, lhP = -s * 30 * move - 10 * strike, s * 30 * move + 22 * strike
	local rhY, lhY, rhR, lhR = 0, 0, 0, 0
	local rootP = pitch - hunch * 8 - lurch * 16
	local rootY = 0
	local rootR = math.sin(z.phase * 0.5) * 6 * move
	local neckP = -10 - 15 * strike - hunch * 10 + lurch * 12
	local neckR = math.sin(z.phase * 0.3) * 14
	if gait == "drag" then
		local good = s * 38 * move
		local dragged = -4 - 12 * move + math.sin(z.phase + 1.2) * 3 * move
		if side > 0 then
			rhP, lhP = dragged - 6 * strike, good + 22 * strike
			rhY, rhR = 14, 7 + abs * 6 * move
			rsP = rsP - 30
		else
			rhP, lhP = -good - 10 * strike, dragged + 12 * strike
			lhY, lhR = -14, -(7 + abs * 6 * move)
			lsP = lsP - 30
		end
		rootR = side * (4 + 9 * abs) * move
		rootP = rootP - abs * 7 * move
		rootY = side * 5 * move
		neckR = neckR * 0.5 - side * 10
	elseif gait == "limp" then
		local k = abs * move
		if side > 0 then
			rhP, lhP = rhP * 0.5, lhP * 1.2
		else
			rhP, lhP = rhP * 1.2, lhP * 0.5
		end
		rootR = side * 9 * k + rootR * 0.4
		rootP = rootP - k * 6
	elseif gait == "waddle" then
		rootR = s * 10 * move
		rhR, lhR = 6, -6
	elseif gait == "heavy" or gait == "boss" then
		rhR, lhR = 5, -5
		rootR = s * 7 * move
		rootY = s * 8 * move
		if gait == "heavy" then
			rsP, lsP = rsP - 18 - s * 14 * move, lsP - 18 + s * 14 * move
		end
	else
		-- ковыляние: неровный шаг, руки тянутся вразнобой, голова мотается
		local wobble = math.sin(z.phase * 0.73 + hunch * 3)
		rhP = rhP * (0.85 + 0.25 * wobble)
		rootR = rootR + wobble * 4 * move
		rsP = rsP + math.sin(z.phase * 0.61) * 10
		lsP = lsP + math.sin(z.phase * 0.47 + 2) * 12
		neckR = neckR + wobble * 6
	end
	if z.fuseAt then
		rootR = rootR + math.random(-15, 15)
		z.torso.Color = (math.floor((now - z.fuseAt) * 12) % 2 == 0) and rgb(230, 60, 40) or z.torsoColor
	end
	setJoint(z, "RightShoulder", rsP, 8, 0)
	setJoint(z, "LeftShoulder", lsP, -8, 0)
	setJoint(z, "RightHip", rhP, rhY, rhR)
	setJoint(z, "LeftHip", lhP, lhY, lhR)
	setJoint(z, "Root", rootP, rootY, rootR)
	setJoint(z, "Neck", neckP, 0, neckR)
end

local function legs(z, s, move, amp)
	setJoint(z, "RightHip", -s * amp * move, 0, 0)
	setJoint(z, "LeftHip", s * amp * move, 0, 0)
end

-- Падение при смерти (если суставы ещё целы): подкашиваются ноги, голова и руки запрокидываются
local function deathPose(z, now)
	local x = now - z.deadAt
	local k = Util.Smooth(math.clamp(x / 0.45, 0, 1))
	local limp = Util.Smooth(math.clamp((x - 0.45) / 0.4, 0, 1))
	local side = z.deathSide or 1
	setJoint(z, "Root", 25 * k, 0, 15 * k * side)
	setJoint(z, "RightHip", 55 * k, 0, 0)
	setJoint(z, "LeftHip", 40 * k, 0, 0)
	setJoint(z, "RightShoulder", 40 + 60 * k - 70 * limp, 0, 20 * k)
	setJoint(z, "LeftShoulder", 40 + 50 * k - 60 * limp, 0, -20 * k)
	setJoint(z, "Neck", 40 * k - 20 * limp, 0, 10 * side * k)
end

local function animate(z, dt, now)
	if z.nest then
		-- гнездо пульсирует, при рождении зомби — сильный толчок, при попадании — дрожь
		local pulse = 1 + math.sin(now * 2.6 + z.phase) * 0.07
		local birth = now - z.attackAt
		if birth < 0.8 then
			pulse = pulse + math.sin(birth / 0.8 * math.pi) * 0.35
		end
		local hit = now - z.hitAt
		if hit < 0.3 then
			pulse = pulse - math.sin(hit / 0.3 * math.pi) * 0.1 * z.hitMag
		end
		if z.mesh and z.mesh.Parent then
			z.mesh.Scale = Vector3.new(pulse, pulse * (1 + math.sin(now * 5.2) * 0.04), pulse)
		end
		return
	end

	updateFlinch(z, now)
	local vel = z.root.AssemblyLinearVelocity
	local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
	z.phase = z.phase + dt * (speed * 0.45 + 1.2)
	local move = math.clamp(speed / 9, 0, 1)
	local s = math.sin(z.phase)
	local attackT = now - z.attackAt
	local atk = 0
	if attackT < 0.45 then
		atk = math.sin(math.clamp(attackT / 0.45, 0, 1) * math.pi)
	end
	local arm, lean, strike = attackCurve(attackT)
	local abT = now - z.abilityAt
	local ab = abT < 1.5 and z.abilityKind or nil
	local t = z.type

	if t == "crawler" then
		setJoint(z, "Root", -70 - 10 * strike, 0, s * 5)
		setJoint(z, "RightShoulder", 150 + s * 25 * move + atk * 20 + arm * 0.4, 0, 0)
		setJoint(z, "LeftShoulder", 150 - s * 25 * move + atk * 20 + arm * 0.4, 0, 0)
		setJoint(z, "RightHip", -20 + s * 20 * move, 0, 0)
		setJoint(z, "LeftHip", -20 - s * 20 * move, 0, 0)
		setJoint(z, "Neck", 60, 0, 0)
	elseif t == "runner" then
		-- рывок (атрибут Burst от сервера): корпус ниже, руки откинуты назад, шаг шире
		local bt = now - z.burstAt
		local burst = 0
		if bt >= 0 and bt < 1.4 then
			burst = bt < 0.2 and bt / 0.2 or math.max(0, 1 - (bt - 0.2) / 1.2)
		end
		local sprint = math.clamp((speed - 12) / 12, 0, 1)
		local swing = (60 + 30 * sprint) * move
		local stride = (45 + 15 * sprint) * move
		setJoint(z, "Root", -22 - 14 * sprint - 10 * burst + lean * 0.6, 0, s * 4 * move)
		setJoint(z, "RightShoulder", s * swing + atk * 90 + arm * 0.5 - 25 * burst, 0, 0)
		setJoint(z, "LeftShoulder", -s * swing + atk * 90 + arm * 0.5 - 25 * burst, 0, 0)
		setJoint(z, "RightHip", -s * stride - 10 * strike, 0, 0)
		setJoint(z, "LeftHip", s * stride + 20 * strike, 0, 0)
		setJoint(z, "Neck", 15 + 12 * burst, 0, s * 6)
	elseif t == "raider" then
		-- мародёр держит оружие двумя руками, отдача при выстреле
		local recoil = 0
		if attackT < 0.6 then
			recoil = math.abs(math.sin(attackT * 22)) * (1 - attackT / 0.6)
		end
		local bob = s * 4 * move
		setJoint(z, "RightShoulder", 88 + bob + recoil * 14, 6, 0)
		setJoint(z, "LeftShoulder", 82 + bob + recoil * 10, -38, 0)
		legs(z, s, move, 38)
		setJoint(z, "Root", -5 * move - recoil * 4, 0, 0)
		setJoint(z, "Neck", 2, 0, 0)
	elseif t == "mutant" then
		if ab == "Dash" then
			-- замах перед рывком и сам рывок: низкий наклон, руки назад
			setJoint(z, "Root", -45, 0, 0)
			setJoint(z, "RightShoulder", -35, 0, 0)
			setJoint(z, "LeftShoulder", -35, 0, 0)
			legs(z, s, math.max(move, 0.8), 55)
			setJoint(z, "Neck", 35, 0, 0)
		else
			setJoint(z, "Root", -28 + lean * 0.8, 0, math.sin(z.phase * 0.5) * 6)
			setJoint(z, "RightShoulder", 60 + s * 40 * move + atk * 100 + arm * 0.5, 10, 0)
			setJoint(z, "LeftShoulder", 60 - s * 40 * move + atk * 60 + arm * 0.4, -10, 0)
			legs(z, s, move, 42)
			setJoint(z, "Neck", 20, 0, s * 8)
		end
	elseif t == "swamp_hag" then
		if ab == "Cast" and abT < 0.9 then
			local k = math.sin(math.clamp(abT / 0.9, 0, 1) * math.pi)
			setJoint(z, "RightShoulder", 60 + k * 110, 10, 0)
			setJoint(z, "LeftShoulder", 60 + k * 110, -10, 0)
			setJoint(z, "Root", -20 + k * 25, 0, 0)
			setJoint(z, "Neck", -10 - k * 20, 0, 0)
		else
			-- сгорбленная, руки свисают вперёд
			local sway = math.sin(z.phase * 0.4) * 10
			setJoint(z, "RightShoulder", 40 + sway + atk * 70 + arm * 0.4, 12, 0)
			setJoint(z, "LeftShoulder", 40 - sway + atk * 70 + arm * 0.4, -12, 0)
			setJoint(z, "Root", -25 + lean * 0.5, 0, math.sin(z.phase * 0.3) * 8)
			setJoint(z, "Neck", 25, 0, math.sin(z.phase * 0.25) * 18)
		end
		legs(z, s, move, 25)
	elseif t == "sand_giant" and ab == "Throw" and abT < 1.0 then
		-- поднимает валун над головой и швыряет
		local a
		if abT < 0.55 then
			a = 90 + (abT / 0.55) * 85
		else
			a = 175 - math.clamp((abT - 0.55) / 0.3, 0, 1) * 140
		end
		setJoint(z, "RightShoulder", a, 0, 0)
		setJoint(z, "LeftShoulder", a, 0, 0)
		setJoint(z, "Root", abT < 0.55 and 12 or -18, 0, 0)
		setJoint(z, "Neck", abT < 0.55 and -15 or 10, 0, 0)
		legs(z, s, 0, 0)
	elseif t == "jungle_giant" and ab == "Summon" and abT < 1.3 then
		-- руки вверх, бьёт о землю
		local k = abT < 0.8 and abT / 0.8 or 1 - (abT - 0.8) / 0.5
		setJoint(z, "RightShoulder", 90 + k * 80, 20, 0)
		setJoint(z, "LeftShoulder", 90 + k * 80, -20, 0)
		setJoint(z, "Root", 10 * k - (abT > 0.8 and 20 or 0), 0, 0)
		setJoint(z, "Neck", -20 * k, 0, 0)
		legs(z, s, 0, 0)
	elseif t == "yeti" and ab == "Roar" and abT < 1.4 then
		-- рёв: откидывается назад, руки в стороны
		local k = math.sin(math.clamp(abT / 1.4, 0, 1) * math.pi)
		setJoint(z, "RightShoulder", 80 + k * 50, 45 * k, 0)
		setJoint(z, "LeftShoulder", 80 + k * 50, -45 * k, 0)
		setJoint(z, "Root", 18 * k, 0, math.random(-2, 2) * k)
		setJoint(z, "Neck", -30 * k, 0, 0)
		legs(z, s, 0, 0)
	elseif t == "riot_brute" then
		-- левая рука держит щит перед собой
		if ab == "Dash" then
			setJoint(z, "Root", -30, 0, 0)
			setJoint(z, "LeftShoulder", 95, -30, 0)
			setJoint(z, "RightShoulder", 20, 0, 0)
			legs(z, s, math.max(move, 0.8), 50)
		else
			setJoint(z, "LeftShoulder", 85 + math.sin(z.phase * 0.5) * 3, -35, 0)
			setJoint(z, "RightShoulder", 30 + s * 20 * move + atk * 120 + arm * 0.6, 8, 0)
			setJoint(z, "Root", -6 - atk * 10 + lean * 0.5, 0, 0)
			legs(z, s, move, 30)
		end
		setJoint(z, "Neck", -5, 0, 0)
	else
		local armBase = 85
		local pitch = -8 + lean
		if t == "conductor" then
			local slamT = now - z.slamAt
			if slamT < 1.4 then
				armBase = slamT < 1.0 and 170 or (170 - (slamT - 1.0) / 0.4 * 150)
			end
		elseif t == "spitter" and atk > 0 then
			armBase = 40
			pitch = 15 - atk * 35
			arm, strike = 0, 0
		elseif z.elite then
			-- тяжёлая элита: сильнее наклон, мощнее замах
			pitch = -12 + lean * 1.3
			armBase = 75
			arm = arm * 1.3
		end
		zombiePose(z, now, s, move, arm, strike, armBase, pitch)
	end
end

function ZombieAnim.Init(c)
	C = c
	local st = Net.State()
	local function refreshEyes()
		nightEyes = st:GetAttribute("IsNight") == true and st:GetAttribute("Mode") ~= "lobby"
		bloodEyes = st:GetAttribute("BloodMoon") == true
		for _, z in pairs(zombies) do
			applyEyes(z)
		end
	end
	for _, attr in ipairs({ "IsNight", "BloodMoon", "Mode" }) do
		st:GetAttributeChangedSignal(attr):Connect(refreshEyes)
	end
	refreshEyes()
	local folder = workspace:WaitForChild("Zombies")
	folder.ChildAdded:Connect(function(model)
		task.spawn(register, model)
	end)
	for _, model in ipairs(folder:GetChildren()) do
		task.spawn(register, model)
	end
	RunService.Stepped:Connect(function(_, dt)
		local camPos = camPosition()
		local now = os.clock()
		local candidates = nil
		groanAcc = groanAcc + dt
		local groanTick = groanAcc >= 0.7
		if groanTick then
			groanAcc = 0
		end
		for model, z in pairs(zombies) do
			if not model.Parent then
				zombies[model] = nil
			else
				local dist = (z.root.Position - camPos).Magnitude
				if z.hum.Health > 0 then
					if dist < 230 then
						animate(z, dt, now)
					end
					if groanTick and dist < 60 and not z.nest and not (z.def and z.def.human) and now >= z.nextGroan then
						candidates = candidates or {}
						table.insert(candidates, z)
					end
				elseif z.deadAt and now - z.deadAt < 1.2 and dist < 150 then
					deathPose(z, now)
				end
				if z.bar and z.barUntil and now > z.barUntil then
					z.bar.Enabled = false
				end
			end
		end
		-- периодическое рычание одного из ближайших зомби (с ограничением частоты)
		if candidates and C and C.Effects and now - lastGroan > 1.1 and rng:NextNumber() < 0.45 then
			local z = candidates[rng:NextInteger(1, #candidates)]
			z.nextGroan = now + rng:NextNumber(6, 12)
			lastGroan = now
			C.Effects.Play("zombie_groan", z.root.Position, voicePitch(z))
		end
	end)
end

return ZombieAnim
