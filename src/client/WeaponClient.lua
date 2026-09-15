-- Предметы в руках на клиенте (v5): первое лицо в заезде (от третьего — в лобби), ввод (ЛКМ — атака или
-- использование предмета из руки, ПКМ — прицел, R — перезарядка, Q — выбросить 1 шт., Shift+Q — всю стопку,
-- F — поесть, H — лечиться, Tab — рюкзак, G — адреналин, Alt — свободный курсор), анимации рук (ViewModel),
-- мгновенные эффекты попаданий, лук с натяжением, оптика (FOV).
-- Слоты 1–0 и колесо мыши обрабатывает HUD (InventoryAction equip) и вызывает WeaponClient.EquipSlot(i).
-- Ближний бой: анимация сразу, в момент удара — локальное предсказание попадания по той же геометрии,
-- что на сервере (зомби в дуге, завалы, любая поверхность). У каждого удара свой номер (seq): сервер
-- возвращает его в HitFx, поэтому предсказанный звук и эффект никогда не играются дважды.
-- Звук — в кадрах анимации (ViewModel через C.SoundFX); здесь только то, чего нет в анимации.
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Weapons = require(Shared.Weapons)
local Items = require(Shared.Items)
local Classes = require(Shared.Classes)
local Recipes = require(Shared.Recipes)
local Net = require(Shared.Net)

local WeaponClient = {}
local C
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera
local rng = Random.new()
local RED = Color3.fromRGB(255, 110, 100)
local GREY = Color3.fromRGB(200, 200, 200)

local MELEE_RADIUS = 0.8
local USE_GAP = 0.35
local THROW_RELEASE = 0.25 -- секунд от нажатия до кадра выпуска бутылки
local DRINKS = { water = true, coffee = true, energy_drink = true, herbal_tea = true }

local tool, def, weaponId = nil, nil, nil -- в руках; def — оружие (и метательное), у предметов nil
local itemId = nil -- ItemId инструмента в руках
local mouseDown = false
local rmbDown = false
local aimToggle = false -- кнопка «Прицел» на телефоне (переключатель)
local aimHold = false -- ButtonL2 на геймпаде (удержание)
local aimBound = false
local sprintOn = false
local scoped = false
local drawing = false
local drawStart = 0
local drawTime = 1
local lastFire = 0
local lastMelee = 0
local lastUse = 0
local lastReloadAnim = 0
local combo = 0
local comboTime = 0
local cursorFree = false
local firstPerson = false
local lastPitchSent = 999
local lastScopedSent = false
local pitchAcc = 0
local dropConfirmUntil = 0
local hooked = {}
local meleeSeq = 0
local predicted = {} -- seq -> вид попадания предсказания ("air", "flesh", ...)
local predictedN = 0
local lastMode = nil
local modalButton = nil

function WeaponClient.Current()
	return tool, def
end

-- Вид и id предмета в руках ("weapon"|"item", id) или nil
function WeaponClient.CurrentItem()
	if not tool then
		return nil, nil
	end
	return tool:GetAttribute("ItemKind"), itemId
end

function WeaponClient.IsScoped()
	return scoped
end

-- Совместимость (HUD рисует прицел): первое лицо в заезде с предметом в руках
function WeaponClient.IsCombatCamera()
	return firstPerson and tool ~= nil
end

function WeaponClient.DrawCharge()
	if drawing then
		return math.clamp((os.clock() - drawStart) / drawTime, 0, 1)
	end
	return nil
end

-- Звук вне кадров анимации (ключи shared/Sounds): 2D — свои руки и интерфейс
local function sfx(key, where, opts)
	local m = C and C.SoundFX
	if type(key) ~= "string" or not m or type(m.Play) ~= "function" then
		return nil
	end
	local ok, s = pcall(m.Play, key, where, opts)
	return ok and s or nil
end

local function classPerk(key, default)
	return Classes.Perk(player:GetAttribute("ClassId") or "survivor", key, default)
end

local function inventory(id)
	local inv = C.State and C.State.Inventory
	return type(inv) == "table" and (tonumber(inv[id]) or 0) or 0
end

local function gameState()
	return ReplicatedStorage:FindFirstChild("GameState")
end

local function inLobby()
	local st = gameState()
	return st ~= nil and st:GetAttribute("Mode") == "lobby"
end

-- Перенос крупного объекта (GRAB): ЛКМ занята объектом, Q не выбрасывает предмет из руки
local function grabWantsClick()
	local g = C and C.GrabClient
	if not g or type(g.WantsClick) ~= "function" then
		return false
	end
	local ok, v = pcall(g.WantsClick)
	return ok and v == true
end

local function grabbing()
	local g = C and C.GrabClient
	if not g or type(g.IsGrabbing) ~= "function" then
		return false
	end
	local ok, v = pcall(g.IsGrabbing)
	return ok and v == true
end

-- Уровень оружия в руках: кулдаун и магазин
local function cooldownMult()
	local level = tool and tool:GetAttribute("Level") or 0
	return Recipes.WeaponCooldownMult(type(level) == "number" and level or 0)
end

local function maxMag()
	local m = tool and tool:GetAttribute("MaxMag")
	if type(m) == "number" then
		return m
	end
	return def and def.mag or 0
end

local function magNow()
	local m = tool and tool:GetAttribute("Mag")
	return type(m) == "number" and m or 0
end

local function humanoid()
	local char = player.Character
	return char and char:FindFirstChildOfClass("Humanoid"), char
end

-- Нельзя действовать: открыто окно, при смерти, спит, погиб, за рулём
local function actionsBlocked()
	if C.Panels.IsOpen() then
		return true
	end
	if player:GetAttribute("Downed") or player:GetAttribute("Sleeping") then
		return true
	end
	local hum = humanoid()
	if hum == nil or hum.Health <= 0 then
		return true
	end
	local seat = hum.SeatPart
	return seat ~= nil and seat.Name == "DriverSeat"
end

local function folders(names, list)
	list = list or {}
	for _, name in ipairs(names) do
		local f = workspace:FindFirstChild(name)
		if f then
			table.insert(list, f)
		end
	end
	return list
end

local function addCharacters(list)
	for _, plr in ipairs(Players:GetPlayers()) do
		if plr.Character then
			table.insert(list, plr.Character)
		end
	end
	return list
end

-- Пули: сквозь добычу, эффекты, игроков, укрепления и автобус (как на сервере)
local function shotExclude()
	return addCharacters(folders({ "ClientFX", "Loot", "Effects", "Placeables", "Bus" }))
end

local function params(exclude)
	local p = RaycastParams.new()
	p.FilterType = Enum.RaycastFilterType.Exclude
	p.FilterDescendantsInstances = exclude
	p.IgnoreWater = true
	return p
end

-- Точка прицела: центр экрана (первое лицо)
local function aimPoint()
	local cf = camera.CFrame
	local result = workspace:Raycast(cf.Position, cf.LookVector * 1000, params(shotExclude()))
	if result then
		return result.Position
	end
	return cf.Position + cf.LookVector * 1000
end

local function applySpread(dir, degrees)
	if degrees <= 0 then
		return dir
	end
	local angle = math.rad(degrees) * math.sqrt(rng:NextNumber())
	local spin = rng:NextNumber() * math.pi * 2
	return (CFrame.lookAt(Vector3.zero, dir) * CFrame.Angles(0, 0, spin) * CFrame.Angles(angle, 0, 0)).LookVector
end

local function flat(v)
	return Vector3.new(v.X, 0, v.Z)
end

-- Ощущение попадания у себя: hit-stop рук, толчок и лёгкая тряска камеры
local function localImpact(heavy)
	C.ViewModel.HitStop(heavy and 0.09 or 0.06)
	C.ViewModel.Impact(heavy)
	local char = player.Character
	if char then
		C.CharAnimator.HitStop(char, heavy and 0.09 or 0.06)
	end
	C.Effects.Punch(heavy and -1.8 or -1, rng:NextNumber(-1, 1) * (heavy and 1 or 0.5), rng:NextNumber(-1, 1) * 0.7)
	C.Effects.Shake(heavy and 0.35 or 0.16, heavy and 0.16 or 0.09)
end

local function breakableOf(part)
	local cur = part and part.Parent
	while cur and cur ~= workspace do
		if cur:IsA("Model") and cur:GetAttribute("Breakable") == true then
			return cur
		end
		cur = cur.Parent
	end
	return nil
end

local function closestPoint(part, point)
	local rel = part.CFrame:PointToObjectSpace(point)
	local half = part.Size / 2
	return part.CFrame:PointToWorldSpace(Vector3.new(
		math.clamp(rel.X, -half.X, half.X),
		math.clamp(rel.Y, -half.Y, half.Y),
		math.clamp(rel.Z, -half.Z, half.Z)
	))
end

local KIND_RANK = { flesh = 3, metal = 2, wood = 2, stone = 2, glass = 2, bus = 2, dirt = 1 }

local function breakKind(model, part)
	local kind = Weapons.ValidKind(model:GetAttribute("BreakKind"))
	if not kind or kind == "flesh" or kind == "air" then
		kind = Weapons.SurfaceKind(part, part.Material)
	end
	return kind
end

local function clearLine(origin, targets, radius, rayParams)
	for _, part in ipairs(targets) do
		if part and part.Parent then
			local to = part.Position - origin
			local dist = to.Magnitude
			if dist < 0.5 then
				return true
			end
			local hit = workspace:Raycast(origin, to, rayParams)
			if not hit or (hit.Position - origin).Magnitude >= dist - radius - 0.4 then
				return true
			end
		end
	end
	return false
end

-- Толчок незакреплённой детали, которой управляет этот клиент (сервер толкает остальные)
local function pushOwned(part, dir, strength, position)
	if typeof(part) ~= "Instance" or not part:IsA("BasePart") or part.Anchored or part.ReceiveAge ~= 0 then
		return
	end
	local rootPart = part.AssemblyRootPart
	if rootPart and rootPart.Anchored then
		return
	end
	local model = part:FindFirstAncestorOfClass("Model")
	if model and model:FindFirstChildOfClass("Humanoid") then
		return
	end
	local mass = part.AssemblyMass
	if mass > 0 and mass <= 800 then
		part:ApplyImpulseAtPosition(dir * strength * math.min(mass, 40), position)
	end
end

-- Запомнить предсказание удара: сервер вернёт этот номер в HitFx
local function rememberPredict(seq, kind)
	if predictedN > 24 then
		table.clear(predicted)
		predictedN = 0
	end
	predicted[seq] = kind
	predictedN = predictedN + 1
end

-- Предсказание попадания ближнего боя (та же геометрия, что на сервере)
local function predictMelee(t, d, id, heavy, aim, seq)
	if tool ~= t or actionsBlocked() then
		return
	end
	local char = player.Character
	local head = char and char:FindFirstChild("Head")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not head or not root then
		return
	end
	local origin = head.Position
	local dir = camera.CFrame.LookVector
	if typeof(aim) == "Vector3" and (aim - origin).Magnitude > 0.3 then
		dir = (aim - origin).Unit
	end
	local flatDir = flat(dir)
	if flatDir.Magnitude < 0.05 then
		flatDir = flat(root.CFrame.LookVector)
	end
	if flatDir.Magnitude < 0.01 then
		return
	end
	flatDir = flatDir.Unit
	local range = d.range
	local cosHalf = math.cos(math.rad(math.min(d.arc, 359) / 2))
	local hits, primary = {}, nil
	local function add(pos, kind, dist, normal)
		if #hits < 8 then
			table.insert(hits, { pos = pos, kind = kind, normal = normal })
		end
		local rank = KIND_RANK[kind] or 1
		if not primary or rank > primary.rank or (rank == primary.rank and dist < primary.dist) then
			primary = { pos = pos, kind = kind, dist = dist, rank = rank, normal = normal }
		end
	end
	local exclude = addCharacters(folders({ "ClientFX", "Loot", "Effects", "Zombies" }))
	local rayParams = params(exclude)

	local zombieHits = 0
	local zombiesFolder = workspace:FindFirstChild("Zombies")
	if zombiesFolder then
		for _, m in ipairs(zombiesFolder:GetChildren()) do
			local hrp = m:FindFirstChild("HumanoidRootPart")
			local zh = m:FindFirstChildOfClass("Humanoid")
			if hrp and hrp:IsA("BasePart") and zh and zh.Health > 0 then
				local radius = math.max(1.2, hrp.Size.X * 0.6)
				local offset = hrp.Position - origin
				local f = flat(offset)
				local dist = f.Magnitude - radius
				if dist <= range and math.abs(hrp.Position.Y - (origin.Y - 1.5)) < 6 + radius then
					local inArc = d.arc >= 360 or f.Magnitude < 2 or f.Unit:Dot(flatDir) >= cosHalf
					local zhead = m:FindFirstChild("Head")
					if inArc and clearLine(origin, zhead and { zhead, hrp } or { hrp }, radius, rayParams) then
						local knock = f.Magnitude > 0.1 and f.Unit or flatDir
						add(hrp.Position - knock * math.min(radius, f.Magnitude) * 0.7 + Vector3.new(0, 0.8, 0), "flesh", math.max(0, dist), -knock)
						zombieHits = zombieHits + 1
					end
				end
			end
		end
	end

	local okCast, surface = pcall(function()
		return workspace:Spherecast(origin, MELEE_RADIUS, dir * range, rayParams)
	end)
	if not okCast or not surface then
		surface = workspace:Raycast(origin, dir * range, rayParams)
	end

	local candidates = {}
	if surface then
		local model = breakableOf(surface.Instance)
		if model then
			candidates[model] = { pos = surface.Position, dist = (surface.Position - origin).Magnitude, part = surface.Instance, normal = surface.Normal }
		end
	end
	local base = origin - Vector3.new(0, 1.5, 0)
	local reach = d.aoe or range
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = exclude
	overlap.MaxParts = 80
	local okQuery, parts = pcall(function()
		return workspace:GetPartBoundsInRadius(base, reach + 6, overlap)
	end)
	if okQuery and type(parts) == "table" then
		for _, part in ipairs(parts) do
			local model = breakableOf(part)
			if model then
				local cp = closestPoint(part, base)
				local off = cp - base
				local f = flat(off)
				if f.Magnitude <= reach and math.abs(off.Y) < 7 and (d.arc >= 360 or f.Magnitude < 2.5 or f.Unit:Dot(flatDir) >= cosHalf) then
					local prev = candidates[model]
					if not prev or f.Magnitude < prev.dist then
						candidates[model] = { pos = cp, dist = f.Magnitude, part = part }
					end
				end
			end
		end
	end
	local damaged = {}
	for model, b in pairs(candidates) do
		add(b.pos, breakKind(model, b.part), b.dist, b.normal)
		damaged[model] = true
	end

	if zombieHits == 0 and surface then
		local model = breakableOf(surface.Instance)
		if not (model and damaged[model]) then
			add(surface.Position, Weapons.SurfaceKind(surface.Instance, surface.Material), (surface.Position - origin).Magnitude, surface.Normal)
		end
		pushOwned(surface.Instance, dir, math.max(8, (d.knockback or 10) * 0.8), surface.Position)
	elseif zombieHits == 0 and not primary and d.aoe then
		local down = workspace:Raycast(origin + flatDir * 2, Vector3.new(0, -9, 0), rayParams)
		if down then
			add(down.Position, Weapons.SurfaceKind(down.Instance, down.Material), 2, down.Normal)
		end
	end

	rememberPredict(seq, primary and primary.kind or "air")
	if primary then
		-- звук попадания ровно один: здесь, в момент контакта (серверный HitFx его не повторит)
		C.Effects.HitFx({
			pos = primary.pos,
			kind = primary.kind,
			normal = primary.normal,
			weaponId = id,
			attacker = player,
			hits = hits,
			heavy = heavy,
			dir = dir,
		})
		localImpact(heavy)
	end
end

-- Шаг/выпад вперёд в момент удара
local function stepForward(t, d)
	if tool ~= t then
		return
	end
	local amount = (d.step or 0) + (d.lunge or 0)
	local hum, char = humanoid()
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if amount <= 0 or not root or not hum or hum.SeatPart then
		return
	end
	if hum.FloorMaterial == Enum.Material.Air and (d.lunge or 0) <= 0 then
		return
	end
	local look = flat(camera.CFrame.LookVector)
	if look.Magnitude > 0.01 then
		root.AssemblyLinearVelocity = root.AssemblyLinearVelocity + look.Unit * amount
	end
end

-- Сервер прислал HitFx по нашему удару/выстрелу
function WeaponClient.OnServerHit(info)
	if type(info) ~= "table" then
		return
	end
	local wdef = Weapons.List[info.weaponId]
	if not wdef then
		C.Effects.HitFx(info)
		return
	end
	if wdef.kind == "gun" then
		return -- попадания пуль уже нарисованы и озвучены локально
	end
	if wdef.kind == "melee" then
		local seq = info.seq
		if type(seq) == "number" then
			local kind = predicted[seq]
			predicted[seq] = nil
			if kind ~= nil then
				if kind ~= "air" then
					return -- предсказание уже показано и озвучено
				end
				-- предсказали промах, а сервер попал: показываем и озвучиваем его результат
				if info.kind ~= "air" then
					C.Effects.HitFx(info)
					localImpact(info.heavy == true)
				end
				return
			end
		end
		if info.kind ~= "air" then
			C.Effects.HitFx(info)
			localImpact(info.heavy == true)
		end
		return
	end
	C.Effects.HitFx(info)
end

-- Оружие ----------------------------------------------------------------------------------------

-- Анимация рук; если рук не видно, звук играем сами (ключ key)
local function playHands(name, duration, opts, key, keyOpts)
	local okAnim = C.ViewModel.Play(name, duration, opts)
	if not okAnim and key then
		sfx(key, nil, keyOpts)
	end
	return okAnim
end

local function reload()
	if not tool or not def or not def.mag then
		return
	end
	if tool:GetAttribute("Reloading") or magNow() >= maxMag() then
		return
	end
	if inventory(def.ammo) <= 0 then
		local ammo = Items.List[def.ammo]
		C.HUD.Notify("Нет патронов: " .. (ammo and ammo.name or ""), RED)
		sfx(def.drySound or "pistol_dry")
		return
	end
	Net.Get("Reload"):FireServer(tool)
	local time = def.reload * classPerk("reloadMult", 1) * cooldownMult()
	local mag = magNow()
	local cap = maxMag()
	lastReloadAnim = os.clock()
	-- кадры перезарядки: пустой магазин (затвор), сколько патронов досылать, сколько гильз выбросить
	playHands("reload", time, {
		empty = mag <= 0,
		need = math.max(1, math.min(cap - mag, inventory(def.ammo))),
		spent = math.max(1, cap - mag),
	}, "reload")
	C.CharAnimator.Play(player.Character, "reload", weaponId, time)
end

local function tryFire()
	if not tool or not def or def.kind ~= "gun" or tool:GetAttribute("Reloading") then
		return
	end
	local now = os.clock()
	if now - lastFire < def.cooldown * cooldownMult() then
		return
	end
	local hum, char = humanoid()
	local head = char and char:FindFirstChild("Head")
	if not head or not hum then
		return
	end
	local mag = magNow()
	if mag <= 0 then
		mouseDown = false
		-- пустой щелчок бойка, дальше — перезарядка, если есть патроны
		playHands("recoil", 0.2, { dry = true }, def.drySound or "pistol_dry")
		if inventory(def.ammo) > 0 then
			reload()
		else
			local ammo = Items.List[def.ammo]
			C.HUD.Notify("Нет патронов: " .. (ammo and ammo.name or ""), RED)
		end
		return
	end
	lastFire = now
	local aim = aimPoint()
	Net.Get("Attack"):FireServer(tool, { aim = aim, scoped = scoped })

	-- выстрел: звук и ход затвора — в кадре анимации отдачи
	playHands("recoil", 0.22, { empty = mag <= 1 }, def.shotSound)
	local vmMuzzle = C.ViewModel.GetMuzzle()
	local handle = tool:FindFirstChild("Handle")
	local muzzle = handle and handle:FindFirstChild("Muzzle")
	local from = vmMuzzle or (muzzle and muzzle.WorldPosition) or head.Position
	local dir = aim - head.Position
	dir = dir.Magnitude > 0.01 and dir.Unit or camera.CFrame.LookVector
	local spread = scoped and (def.aimSpread or def.spread) or def.spread
	if hum.MoveDirection.Magnitude > 0.1 then
		spread = spread * 1.35
	end
	local rayParams = params(shotExclude())
	local zombiesFolder = workspace:FindFirstChild("Zombies")
	local ends, hits = {}, {}
	for _ = 1, def.pellets or 1 do
		local pdir = applySpread(dir, spread)
		local result = workspace:Raycast(head.Position, pdir * def.range, rayParams)
		table.insert(ends, result and result.Position or (head.Position + pdir * def.range))
		if result and #hits < 8 then
			local isZombie = zombiesFolder ~= nil and result.Instance:IsDescendantOf(zombiesFolder)
			local kind = isZombie and "flesh" or Weapons.SurfaceKind(result.Instance, result.Material)
			table.insert(hits, { pos = result.Position, kind = kind, normal = result.Normal })
			if not isZombie then
				pushOwned(result.Instance, pdir, (def.knockback or 6) * 0.6 + 4, result.Position)
			end
		end
	end
	-- трассер и вспышка без звука (его уже играет анимация), гильза — из окна выброса модели в руках
	C.Effects.Tracer(from, ends, weaponId, {
		fp = vmMuzzle ~= nil,
		silent = true,
		noCasing = def.boltCycle == true,
		casingAt = C.ViewModel.GetEjectPort(),
	})
	if #hits > 0 then
		C.Effects.HitFx({ pos = hits[1].pos, kind = hits[1].kind, weaponId = weaponId, attacker = player, hits = hits, gun = true, dir = dir })
	end
	C.CharAnimator.Play(char, "recoil", weaponId, 0.18)
	C.Effects.Kick((def.recoil or 5) * (scoped and 0.2 or 0.12))
	C.Effects.Punch(0, rng:NextNumber(-1, 1) * (def.recoil or 5) * 0.05, rng:NextNumber(-1, 1) * (def.recoil or 5) * 0.04)
	if def.boltCycle then
		-- снайперская винтовка: затвор передёргивается после выстрела (со звуком и гильзой)
		local fired = tool
		task.delay(0.3, function()
			if tool == fired and not actionsBlocked() then
				C.ViewModel.Play("bolt_cycle", math.max(0.6, def.cooldown * cooldownMult() * 0.8))
			end
		end)
	end
	if not def.auto then
		mouseDown = false
	end
end

local function tryCrossbow()
	if tool:GetAttribute("Reloading") then
		return
	end
	local now = os.clock()
	if now - lastFire < def.cooldown * cooldownMult() then
		return
	end
	if magNow() <= 0 then
		reload()
		return
	end
	lastFire = now
	Net.Get("Attack"):FireServer(tool, { aim = aimPoint(), scoped = scoped })
	playHands("recoil", 0.25, {}, def.shotSound)
	C.CharAnimator.Play(player.Character, "recoil", weaponId, 0.2)
	C.Effects.Kick(2.5)
end

-- Предмет в руке (ЛКМ): мгновенная анимация там, где исход известен заранее; остальное
-- (печь, прикрепление, осмотр) подтверждает сервер анимацией PlayAnim самому игроку
local function useHeldItem(t)
	local now = os.clock()
	if now - lastUse < USE_GAP then
		return
	end
	lastUse = now
	local id = t:GetAttribute("ItemId")
	local item = Items.List[id]
	if not item then
		return
	end
	local hum = humanoid()
	local cat = item.cat
	-- звук каждого действия — в кадре анимации (ViewModel)
	if cat == "food" then
		local hunger = player:GetAttribute("Hunger") or 100
		local wantsHeal = (item.heal or 0) > 0 and hum ~= nil and hum.Health < hum.MaxHealth - 0.5
		if item.effect or wantsHeal or hunger < 99 then
			local drink = DRINKS[id] == true
			playHands(drink and "drink" or "eat", nil, { id = id }, drink and "drink" or "eat")
		end
	elseif cat == "medical" then
		if item.revive then
			playHands("inject", nil, { id = id }, "inject")
		elseif hum and hum.Health < hum.MaxHealth - 0.5 then
			playHands("heal", (item.useTime or 1.5) / classPerk("healMult", 1), { id = id }, "bandage")
		end
	elseif cat == "placeable" then
		playHands("place", nil, { id = id }, "place")
	elseif cat == "tool" and not item.busRepair then
		C.ViewModel.Play("inspect", nil, { id = id })
	end
	Net.Get("Attack"):FireServer(t, {})
end

local function cancelDraw(t)
	if not drawing then
		return
	end
	local charge = math.clamp((os.clock() - drawStart) / drawTime, 0, 1)
	drawing = false
	C.ViewModel.Stop("bow_draw")
	C.ViewModel.Play("bow_ease", 0.25, { draw = charge })
	C.CharAnimator.Stop(player.Character, "bow_draw")
	if t then
		-- сообщить серверу, иначе остальные игроки видят вечное натяжение
		Net.Get("Release"):FireServer(t, { cancel = true })
	end
end

local function onActivated(t)
	if t ~= tool or actionsBlocked() or inLobby() then
		return
	end
	if grabWantsClick() then
		return -- ЛКМ занята переносом объекта
	end
	local _, char = humanoid()
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	if not def then
		useHeldItem(t)
		return
	end
	local now = os.clock()
	if def.kind == "melee" then
		local cd = def.cooldown * cooldownMult()
		if now - lastMelee < cd then
			return
		end
		lastMelee = now
		if now - comboTime > cd + 0.6 then
			combo = 0
		end
		combo = (combo % #def.combo) + 1
		comboTime = now
		local heavy = (#def.combo > 1 and combo == #def.combo) or def.heavy == true
		local aim = aimPoint()
		local animName = def.combo[combo]
		meleeSeq = meleeSeq + 1
		local seq = meleeSeq
		-- руки от первого лица (свист в кадре начала удара) и поза тела — сразу
		C.ViewModel.Play(animName, cd, { heavy = heavy })
		C.CharAnimator.Play(char, animName, weaponId, cd)
		Net.Get("Attack"):FireServer(t, { aim = aim, seq = seq })
		local hitDelay = def.hitDelay or 0.15
		task.delay(hitDelay * 0.75, stepForward, t, def)
		task.delay(hitDelay, predictMelee, t, def, weaponId, heavy, aim, seq)
	elseif def.kind == "gun" then
		mouseDown = true
		tryFire()
	elseif def.kind == "bow" then
		if inventory(def.ammo) <= 0 then
			C.HUD.Notify("Нет стрел", RED)
			return
		end
		if now - lastFire < def.cooldown * cooldownMult() then
			return
		end
		drawing = true
		drawStart = now
		drawTime = def.drawTime * classPerk("drawMult", 1)
		playHands("bow_draw", drawTime, nil, "bow_draw")
		C.CharAnimator.Play(char, "bow_draw", weaponId, drawTime, true)
		Net.Get("Attack"):FireServer(t, {})
	elseif def.kind == "crossbow" then
		tryCrossbow()
	elseif def.kind == "throw" then
		if now - lastFire < def.cooldown then
			return
		end
		lastFire = now
		C.ViewModel.Play("throw")
		C.CharAnimator.Play(char, "throw", weaponId, 0.5)
		-- бутылка вылетает в кадре выпуска, а не по клику
		task.delay(THROW_RELEASE, function()
			if tool == t and not actionsBlocked() then
				Net.Get("Attack"):FireServer(t, { aim = aimPoint() })
			end
		end)
	end
end

local function onDeactivated(t)
	if t ~= tool then
		return
	end
	mouseDown = false
	if drawing then
		drawing = false
		lastFire = os.clock()
		Net.Get("Release"):FireServer(t, { aim = aimPoint() })
		-- выстрел и наложение следующей стрелы (если стрелы ещё есть)
		playHands("bow_release", 0.3, { has = inventory(def and def.ammo or "arrow") > 1 }, "bow_release")
		C.CharAnimator.Play(player.Character, "bow_release", weaponId, 0.25)
		C.Effects.Kick(1.2)
	end
end

-- Прицел без правой кнопки мыши: ButtonL2 (удержание) и кнопка на экране (переключатель)
local function unbindAim()
	aimToggle = false
	aimHold = false
	if aimBound then
		aimBound = false
		ContextActionService:UnbindAction("LastRunAim")
	end
end

local function bindAim()
	if aimBound then
		return
	end
	aimBound = true
	ContextActionService:BindAction("LastRunAim", function(_, state, input)
		if UserInputService:GetFocusedTextBox() then
			return Enum.ContextActionResult.Pass
		end
		if input.UserInputType == Enum.UserInputType.Touch then
			if state == Enum.UserInputState.Begin then
				aimToggle = not aimToggle
			end
		elseif state == Enum.UserInputState.Begin then
			aimHold = true
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			aimHold = false
		end
		return Enum.ContextActionResult.Sink
	end, true, Enum.KeyCode.ButtonL2)
	ContextActionService:SetTitle("LastRunAim", "Прицел")
	ContextActionService:SetPosition("LastRunAim", UDim2.new(1, -70, 0, 10))
end

-- Инструменты -------------------------------------------------------------------------------------

local function entryFromTool(t)
	local kind, id = t:GetAttribute("ItemKind"), t:GetAttribute("ItemId")
	if kind ~= "weapon" and kind ~= "item" then
		local wid = t:GetAttribute("WeaponId")
		if type(wid) == "string" then
			kind, id = "weapon", wid
		end
	end
	if (kind == "weapon" or kind == "item") and type(id) == "string" then
		return { kind = kind, id = id }
	end
	return nil
end

local function hookTool(t)
	if hooked[t] then
		return
	end
	hooked[t] = true
	t.Activated:Connect(function()
		onActivated(t)
	end)
	t.Deactivated:Connect(function()
		onDeactivated(t)
	end)
	-- перезарядку мог начать сервер (пустой магазин) — руки тоже перезаряжают
	t:GetAttributeChangedSignal("Reloading"):Connect(function()
		if t == tool and t:GetAttribute("Reloading") == true and os.clock() - lastReloadAnim > 0.5 then
			lastReloadAnim = os.clock()
			local left = (t:GetAttribute("ReloadEnd") or 0) - workspace:GetServerTimeNow()
			local cap = maxMag()
			local mag = magNow()
			playHands("reload", math.max(0.3, left), {
				empty = mag <= 0,
				need = math.max(1, cap - mag),
				spent = math.max(1, cap - mag),
			}, "reload")
		end
	end)
	t.Destroying:Connect(function()
		hooked[t] = nil
	end)
end

local function onEquipped(t)
	if tool and tool ~= t then
		cancelDraw(tool)
	end
	tool = t
	weaponId = t:GetAttribute("WeaponId")
	def = Weapons.List[weaponId]
	itemId = t:GetAttribute("ItemId") or weaponId
	mouseDown = false
	drawing = false
	combo = 0
	unbindAim()
	if def and (def.scope or def.kind == "gun" or def.kind == "bow") then
		bindAim()
	end
	hookTool(t)
	C.ViewModel.SetItem(entryFromTool(t))
end

local function onUnequipped(t)
	if t ~= tool then
		return
	end
	cancelDraw(t)
	tool, def, weaponId, itemId = nil, nil, nil, nil
	mouseDown = false
	unbindAim()
	local char = player.Character
	local other = char and char:FindFirstChildOfClass("Tool")
	if other and other ~= t then
		onEquipped(other)
	else
		C.ViewModel.SetItem(nil)
	end
end

local function hookCharacter(char)
	char.ChildAdded:Connect(function(child)
		if child:IsA("Tool") then
			onEquipped(child)
		end
	end)
	char.ChildRemoved:Connect(function(child)
		if child:IsA("Tool") then
			onUnequipped(child)
		end
	end)
	local existing = char:FindFirstChildOfClass("Tool")
	if existing then
		onEquipped(existing)
	end
end

-- Слот хотбара выбран в HUD (он уже отправил InventoryAction): взять инструмент в руки сразу
-- и начать смену предмета у рук от первого лица. index = 0 — пустые руки.
function WeaponClient.EquipSlot(index)
	index = tonumber(index) or 0
	local hum, char = humanoid()
	if not hum or hum.Health <= 0 or inLobby() then
		return
	end
	if player:GetAttribute("Downed") or player:GetAttribute("Sleeping") then
		return
	end
	if index >= 1 then
		for _, container in ipairs({ char, player:FindFirstChildOfClass("Backpack") }) do
			if container then
				for _, t in ipairs(container:GetChildren()) do
					if t:IsA("Tool") and t:GetAttribute("Slot") == index then
						if t.Parent ~= char then
							hum:EquipTool(t)
						end
						C.ViewModel.SetItem(entryFromTool(t))
						return
					end
				end
			end
		end
	end
	if char:FindFirstChildOfClass("Tool") then
		hum:UnequipTools()
	end
	C.ViewModel.SetItem(nil)
end

-- Быстрые действия ----------------------------------------------------------------------------------

local function useFirst(ids)
	for _, id in ipairs(ids) do
		if inventory(id) > 0 then
			Net.Get("UseItem"):FireServer(id)
			return id
		end
	end
	return nil
end

local function eatBest()
	if actionsBlocked() then
		return
	end
	local hunger = player:GetAttribute("Hunger") or 100
	if hunger >= 95 then
		C.HUD.Notify("Вы не голодны", GREY)
		return
	end
	local order = hunger < 60 and { "canned_food", "chips", "herbal_tea", "water", "coffee", "energy_drink" }
		or { "chips", "water", "herbal_tea", "canned_food", "coffee", "energy_drink" }
	local used = useFirst(order)
	if used then
		local drink = DRINKS[used] == true
		C.CharAnimator.Play(player.Character, drink and "drink" or "eat", nil, 0.8)
		sfx(drink and "drink" or "eat", nil, { delay = 0.2 })
	else
		C.HUD.Notify("Нечего есть", RED)
	end
end

local function healBest()
	if actionsBlocked() then
		return
	end
	local hum = humanoid()
	local missing = hum.MaxHealth - hum.Health
	if missing < 1 then
		C.HUD.Notify("Здоровье полное", GREY)
		return
	end
	local used = useFirst(missing > 45 and { "medkit", "bandage" } or { "bandage", "medkit" })
	if used then
		C.CharAnimator.Play(player.Character, "heal", nil, (Items.List[used].useTime or 1.5) / classPerk("healMult", 1))
		sfx("bandage", nil, { delay = 0.1 })
	else
		C.HUD.Notify("Нет бинтов и аптечек", RED)
	end
end

-- Q — выбросить 1 шт. из руки, Shift+Q — всю стопку (на телефоне — двойное нажатие)
local function dropCurrent(fromTouch)
	if grabbing() then
		return -- Q отпускает переносимый объект (GrabClient)
	end
	if not tool then
		C.HUD.Notify("В руках ничего нет", GREY)
		return
	end
	if actionsBlocked() then
		return
	end
	if fromTouch and os.clock() > dropConfirmUntil then
		dropConfirmUntil = os.clock() + 2.5
		C.HUD.Notify("Нажмите ещё раз, чтобы выбросить: " .. tool.Name, GREY)
		return
	end
	dropConfirmUntil = 0
	local slot = tool:GetAttribute("Slot")
	if type(slot) == "number" then
		local whole = UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
		local count = whole and (tonumber(tool:GetAttribute("Count")) or 1) or 1
		cancelDraw(tool)
		Net.Get("InventoryAction"):FireServer("drop", { slot = slot, count = count })
	elseif def and def.kind ~= "throw" then
		Net.Get("DropWeapon"):FireServer(weaponId)
	elseif def then
		Net.Get("DropItem"):FireServer(def.item or "molotov", 1)
	end
	sfx("drop_item")
end

local function bindAction(name, title, position, callback, ...)
	ContextActionService:BindAction(name, function(_, state, input)
		if state ~= Enum.UserInputState.Begin then
			return Enum.ContextActionResult.Pass
		end
		if UserInputService:GetFocusedTextBox() then
			return Enum.ContextActionResult.Pass
		end
		callback(input.UserInputType == Enum.UserInputType.Touch)
		return Enum.ContextActionResult.Sink
	end, true, ...)
	ContextActionService:SetTitle(name, title)
	ContextActionService:SetPosition(name, position)
end

-- Кнопка Modal освобождает курсор в первом лице, пока открыто окно или включён свободный курсор (Alt)
local function createCursorUnlock()
	local gui = Instance.new("ScreenGui")
	gui.Name = "LR_CursorUnlock"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = -10
	modalButton = Instance.new("TextButton")
	modalButton.Name = "Unlock"
	modalButton.Size = UDim2.fromOffset(1, 1)
	modalButton.BackgroundTransparency = 1
	modalButton.Text = ""
	modalButton.AutoButtonColor = false
	modalButton.Selectable = false
	modalButton.Active = false
	modalButton.Modal = true
	modalButton.Visible = false
	modalButton.Parent = gui
	local playerGui = player:FindFirstChildOfClass("PlayerGui")
	if playerGui then
		gui.Parent = playerGui
	else
		task.spawn(function()
			gui.Parent = player:WaitForChild("PlayerGui")
		end)
	end
end

-- Каждый кадр после камеры: режим камеры, курсор, оптика, автоматический огонь, угол прицела
local function renderStep(dt)
	camera = workspace.CurrentCamera or camera
	local st = gameState()
	local mode = st and st:GetAttribute("Mode")
	-- страховка к серверу: первое лицо в заезде, от третьего лица в лобби
	if mode == "run" then
		if player.CameraMode ~= Enum.CameraMode.LockFirstPerson then
			player.CameraMode = Enum.CameraMode.LockFirstPerson
		end
	elseif mode == "lobby" then
		if player.CameraMode ~= Enum.CameraMode.Classic then
			player.CameraMode = Enum.CameraMode.Classic
		end
		if lastMode == "run" then
			-- отъехать из первого лица
			local saved = player.CameraMinZoomDistance
			player.CameraMinZoomDistance = math.max(saved, 10)
			task.delay(0.3, function()
				player.CameraMinZoomDistance = saved
			end)
		end
		cursorFree = false
	end
	lastMode = mode

	local hum, char = humanoid()
	local head = char and char:FindFirstChild("Head")
	firstPerson = mode ~= "lobby" and head ~= nil and (camera.CFrame.Position - head.Position).Magnitude < 2.5
	local panelOpen = C.Panels.IsOpen()
	local downed = player:GetAttribute("Downed") == true
	local sleeping = player:GetAttribute("Sleeping") == true
	local dead = hum == nil or hum.Health <= 0
	-- автоматический огонь и натяжение лука прерываются окнами, обмороком, сном, смертью и переносом
	if panelOpen or downed or sleeping or dead or grabbing() then
		mouseDown = false
		if drawing then
			cancelDraw(tool)
		end
	end

	-- курсор: окно или Alt — свободная мышь; иначе первое лицо держит мышь, системный курсор скрыт (прицел — HUD)
	local free = (panelOpen or cursorFree) and mode ~= "lobby"
	if free then
		if UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
		if not UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = true
		end
	elseif firstPerson and not dead then
		if UserInputService.MouseIconEnabled then
			UserInputService.MouseIconEnabled = false
		end
	elseif not UserInputService.MouseIconEnabled then
		UserInputService.MouseIconEnabled = true
	end
	if modalButton and modalButton.Visible ~= free then
		modalButton.Visible = free
	end

	-- оптика и прицеливание
	local blocked = dead or sleeping or downed or panelOpen or mode == "lobby"
	local targetFov = 70
	scoped = false
	if not blocked and def and (rmbDown or aimToggle or aimHold) then
		if def.scope then
			targetFov = def.zoomFov or 30
			scoped = true
		elseif def.kind == "gun" or def.kind == "bow" then
			targetFov = 55
			scoped = true
		end
	end
	local fov = camera.FieldOfView
	if math.abs(fov - targetFov) > 0.05 then
		camera.FieldOfView = fov + (targetFov - fov) * math.min(1, dt * 14)
	end
	local sensitivity = (scoped and def and def.scope) and 0.35 or 1
	if UserInputService.MouseDeltaSensitivity ~= sensitivity then
		UserInputService.MouseDeltaSensitivity = sensitivity
	end

	if mouseDown and def and def.auto and not blocked then
		tryFire()
	end

	pitchAcc = pitchAcc + dt
	if tool and pitchAcc > 0.12 then
		pitchAcc = 0
		local p = C.CharAnimator.LocalAimPitch()
		if math.abs(p - lastPitchSent) > 2 or scoped ~= lastScopedSent then
			lastPitchSent = p
			lastScopedSent = scoped
			Net.Get("AimPitch"):FireServer(p, scoped)
		end
	end
end

function WeaponClient.Init(c)
	C = c
	createCursorUnlock()
	if player.Character then
		hookCharacter(player.Character)
	end
	player.CharacterAdded:Connect(function(char)
		tool, def, weaponId, itemId = nil, nil, nil, nil
		mouseDown = false
		drawing = false
		unbindAim()
		C.ViewModel.SetItem(nil)
		if sprintOn then
			sprintOn = false
			Net.Get("Sprint"):FireServer(false)
		end
		hookCharacter(char)
	end)

	-- подбор с земли: рука тянется за предметом, звук — по материалу предмета в кадре захвата
	Net.Get("PickupFx").OnClientEvent:Connect(function(id, _count, kind, _position)
		if type(id) ~= "string" then
			return
		end
		C.ViewModel.Play("pickup", nil, { id = id, kind = kind })
	end)

	bindAction("LastRunInventory", "Сумка", UDim2.new(1, -70, 0, -60), function()
		C.Panels.ToggleInventory()
	end, Enum.KeyCode.Tab, Enum.KeyCode.ButtonSelect)
	bindAction("LastRunEat", "Есть", UDim2.new(1, -140, 0, -60), eatBest, Enum.KeyCode.F, Enum.KeyCode.DPadUp)
	bindAction("LastRunHeal", "Лечить", UDim2.new(1, -210, 0, -60), healBest, Enum.KeyCode.H, Enum.KeyCode.DPadDown)
	bindAction("LastRunReload", "Перезар.", UDim2.new(1, -140, 0, 10), function()
		if not actionsBlocked() then
			reload()
		end
	end, Enum.KeyCode.R, Enum.KeyCode.ButtonX)
	bindAction("LastRunDrop", "Бросить", UDim2.new(1, -210, 0, 10), dropCurrent, Enum.KeyCode.Q)
	-- бег на телефоне и геймпаде: переключатель (на клавиатуре — удержание Shift)
	bindAction("LastRunSprint", "Бег", UDim2.new(1, -280, 0, -60), function()
		sprintOn = not sprintOn
		Net.Get("Sprint"):FireServer(sprintOn)
		C.HUD.Notify(sprintOn and "Бег включён" or "Бег выключен", GREY)
	end, Enum.KeyCode.ButtonL3)

	UserInputService.InputBegan:Connect(function(input, processed)
		-- клик по интерфейсу (ПКМ по слоту хотбара со свободным курсором) не должен целиться
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			rmbDown = true
		end
		local key = input.KeyCode
		if key == Enum.KeyCode.LeftShift or key == Enum.KeyCode.RightShift then
			Net.Get("Sprint"):FireServer(true)
		elseif key == Enum.KeyCode.G then
			if player:GetAttribute("Downed") then
				Net.Get("SelfRevive"):FireServer()
			end
		elseif key == Enum.KeyCode.LeftAlt or key == Enum.KeyCode.RightAlt then
			if not inLobby() then
				cursorFree = not cursorFree
				C.HUD.Notify(cursorFree and "Курсор свободен (Alt — вернуть)" or "Курсор скрыт", GREY)
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			rmbDown = false
		elseif input.KeyCode == Enum.KeyCode.LeftShift or input.KeyCode == Enum.KeyCode.RightShift then
			sprintOn = false
			Net.Get("Sprint"):FireServer(false)
		end
	end)

	RunService:BindToRenderStep("LastRunCombat", Enum.RenderPriority.Camera.Value + 2, renderStep)
end

return WeaponClient
