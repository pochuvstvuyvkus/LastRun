-- Летящие снаряды (стрелы, болты, бутылки, кислота, пули мародёров, мины миномёта).
-- Считаются на сервере, клиенты рисуют ту же траекторию у себя.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared.Util)
local Net = require(Shared.Net)
local Weapons = require(Shared.Weapons)

-- Снаряды, которые втыкаются в поверхность и в зомби (клиент оставляет их торчать)
local STICKS = { arrow = true, bolt = true }

local Proj = {}
local S
local list = {}
local pending = {} -- выпущенные во время Update (нельзя добавлять ключи в обходимую таблицу)
local updating = false
local nextId = 0

-- Урон автобусу от враждебных снарядов (доля от урона по игроку) по видам
local BUS_MULT = {
	acid = 0.5,
	bullet = 0.35,
	shell = 1,
}
-- Вид урона игроку по виду снаряда
local PLAYER_KIND = {
	acid = "acid",
	bullet = "bullet",
	shell = "explosion",
}

function Proj.Init(services)
	S = services
end

function Proj.Clear()
	local remote = Net.Get("ProjectileEnd")
	for id in pairs(list) do
		remote:FireAllClients(id, nil, false)
	end
	for id in pairs(pending) do
		remote:FireAllClients(id, nil, false)
	end
	list = {}
	pending = {}
end

function Proj.Count()
	local n = 0
	for _ in pairs(list) do
		n = n + 1
	end
	return n
end

local function busModel()
	local bus = S and S.Bus
	local model = bus and bus.Model
	if model and model.Parent then
		return model
	end
	return nil
end

-- Враждебный снаряд: выпущен зомби/мародёром или явно помечен как бьющий игроков без владельца-игрока
local function isHostile(p)
	if p.owner then
		return false
	end
	return p.zombieOwner ~= nil or p.hitsPlayers == true or p.hostile == true
end

--[[ p:
	kind ("arrow"|"bolt"|"molotov"|"acid"|"bullet"|"shell"|...), origin, velocity, gravity,
	owner (Player), zombieOwner (z), damage, pierce, headshot, knockback, hitsZombies, hitsPlayers,
	maxTime, onImpact(pos, normal), critKind, weaponId, busMult (урон автобусу), damageKind,
	friendly (снаряд автобуса без владельца — не бьёт автобус и игроков), hostile
	Возвращает id снаряда или nil при неверных данных.
]]
function Proj.Fire(p)
	if type(p) ~= "table" or typeof(p.origin) ~= "Vector3" or typeof(p.velocity) ~= "Vector3" then
		warn("[Projectiles] Fire: нужны origin и velocity (Vector3)")
		return nil
	end
	nextId = nextId + 1
	p.id = nextId
	p.kind = type(p.kind) == "string" and p.kind or "acid"
	p.pos = p.origin
	p.vel = p.velocity
	p.t = 0
	p.damage = type(p.damage) == "number" and p.damage or 0
	p.maxTime = p.maxTime or (p.kind == "bullet" and 2.5 or 4)
	p.pierceLeft = p.pierce or 1
	p.gravity = p.gravity or 0
	p.hostile = isHostile(p)

	local exclude = {}
	local function add(inst)
		if inst then
			table.insert(exclude, inst)
		end
	end
	add(workspace:FindFirstChild("Loot"))
	add(workspace:FindFirstChild("Effects"))
	-- EventsFX целиком не исключаем: баррикада и укрытия мародёров там твёрдые.
	-- Декоративные эффекты пропускаются по ходу полёта (см. fxBlocks в step).
	if not p.hostile then
		-- снаряды игроков и автобуса пролетают сквозь своих, сквозь автобус и свои баррикады
		for _, plr in ipairs(Players:GetPlayers()) do
			add(plr.Character)
		end
		add(busModel())
		add(workspace:FindFirstChild("Placeables"))
	end
	if p.zombieOwner or p.hostile then
		-- снаряды зомби и мародёров не задевают других зомби
		add(workspace:FindFirstChild("Zombies"))
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = exclude
	params.IgnoreWater = true
	p.params = params

	if updating then
		pending[p.id] = p
	else
		list[p.id] = p
	end
	-- последний аргумент — UserId владельца (0 — без игрока): стрелявший сам уже слышал выстрел
	Net.Get("Projectile"):FireAllClients(p.id, p.kind, p.origin, p.velocity, p.gravity, p.owner and p.owner.UserId or 0)
	return p.id
end

local impacts = {}

-- Вид поверхности для эффектов клиента: по материалу детали (металл автобуса — "bus")
local function surfaceKind(hitPart)
	if typeof(hitPart) == "Instance" and hitPart:IsA("BasePart") then
		return Weapons.SurfaceKind(hitPart, hitPart.Material)
	end
	return nil
end

-- stuck — снаряд остался в цели (стрелы и болты торчат из стены, земли, зомби); hitPart — деталь попадания
-- (или nil), kind — вид поверхности ("flesh" у зомби). Клиентам: ProjectileEnd(id, позиция, stuck, нормаль,
-- вид, деталь); onImpact(позиция, нормаль, деталь, вид)
local function finish(p, position, normal, stuck, hitPart, kind)
	list[p.id] = nil
	Net.Get("ProjectileEnd"):FireAllClients(p.id, position, stuck, normal, kind, hitPart)
	if p.onImpact then
		table.insert(impacts, { p.onImpact, position, normal, hitPart, kind })
	end
end

local function damageBus(p)
	if not p.hostile or p.damage <= 0 then
		return
	end
	local mult = p.busMult or BUS_MULT[p.kind] or 0.5
	if mult > 0 then
		S.Bus.Damage(p.damage * mult, { kind = p.kind, zombie = p.zombieOwner })
	end
end

-- Попадание в EventsFX: твёрдые только баррикада на дороге и укрытия мародёров
-- (свои укрытия мародёры простреливают). Возвращает true — снаряд останавливается,
-- иначе второе значение — что добавить в фильтр, чтобы лететь дальше.
local function fxBlocks(p, hitPart, fx)
	local top = hitPart
	while top.Parent and top.Parent ~= fx do
		top = top.Parent
	end
	if top.Name == "RaiderBarricade" or (top.Name == "RaiderCovers" and not p.hostile) then
		if hitPart.CanCollide then
			return true, nil
		end
		return false, hitPart
	end
	return false, top
end

-- Враждебный снаряд попал в стену баррикады игрока: баррикада получает урон
local function damagePlaceable(p, hitPart)
	if not p.hostile or p.damage <= 0 then
		return
	end
	local placeables = workspace:FindFirstChild("Placeables")
	if not placeables or not hitPart:IsDescendantOf(placeables) then
		return
	end
	local entry = S.Workbench.FindPlaceableNear(hitPart.Position, math.max(hitPart.Size.X, hitPart.Size.Y, hitPart.Size.Z))
	if entry and entry.root == hitPart and type(entry.Damage) == "function" then
		local ok, err = pcall(entry.Damage, p.damage)
		if not ok then
			warn("[Projectiles] placeable.Damage: " .. tostring(err))
		end
	end
end

local function step(p, dt, zombiesFolder, bus)
	p.t = p.t + dt
	local newVel = p.vel + Vector3.new(0, -p.gravity * dt, 0)
	local target = p.pos + (p.vel + newVel) * 0.5 * dt
	local from = p.pos

	for _ = 1, 6 do
		local delta = target - from
		if delta.Magnitude < 0.01 then
			break
		end
		local result = workspace:Raycast(from, delta, p.params)
		if not result then
			break
		end
		local hitPart = result.Instance
		local zModel = zombiesFolder and Util.ModelIn(hitPart, zombiesFolder)
		if zModel then
			p.params:AddToFilter(zModel)
			local z = S.Zombies.Active[zModel]
			-- убитый в этом же кадре зомби (Died ещё не пришёл) — пролетаем, не тратя пробитие
			local alive = z and not z.dead and z.humanoid and z.humanoid.Health > 0
			if alive and p.hitsZombies then
				local dmg = p.damage
				local kind = p.critKind or "normal"
				if hitPart.Name == "Head" and p.headshot then
					dmg = dmg * p.headshot
					kind = "headshot"
				end
				S.Combat.DamageZombie(z, dmg, {
					attacker = p.owner,
					kind = kind,
					position = result.Position,
					knockDir = p.vel.Magnitude > 0 and p.vel.Unit or nil,
					knockback = p.knockback,
					weapon = p.weaponId,
				})
				p.pierceLeft = p.pierceLeft - 1
				if p.pierceLeft <= 0 then
					-- стрела/болт остаётся торчать в зомби (клиент прикрепляет её к этой детали)
					finish(p, result.Position, result.Normal, STICKS[p.kind] == true, hitPart, "flesh")
					return
				end
				if p.onPierce then
					-- пробил насквозь: эффект попадания без остановки снаряда
					table.insert(impacts, { p.onPierce, result.Position, result.Normal, hitPart, "flesh" })
				end
			elseif alive and p.onImpact and not p.hostile then
				-- мина/бутылка без прямого урона взрывается о первого зомби
				finish(p, result.Position, result.Normal, false, hitPart, "flesh")
				return
			end
			from = result.Position
		else
			local char, plr = Util.GetCharacterFromPart(hitPart)
			local fx = workspace:FindFirstChild("EventsFX")
			local passFx = nil
			if not plr and fx and hitPart:IsDescendantOf(fx) then
				local blocks, skip = fxBlocks(p, hitPart, fx)
				if not blocks then
					passFx = skip
				end
			end
			if plr then
				if p.hostile and (p.hitsPlayers or p.onImpact) then
					if p.hitsPlayers and p.damage > 0 then
						S.Combat.DamagePlayer(plr, p.damage, {
							kind = p.damageKind or PLAYER_KIND[p.kind] or "acid",
							zombie = p.zombieOwner,
						})
					end
					finish(p, result.Position, result.Normal, false, hitPart, "flesh")
					return
				end
				p.params:AddToFilter(char)
				from = result.Position
			elseif passFx then
				-- декоративный эффект события или своё укрытие мародёра — летим дальше
				p.params:AddToFilter(passFx)
				from = result.Position
			else
				if bus and hitPart:IsDescendantOf(bus) then
					damageBus(p)
				else
					damagePlaceable(p, hitPart)
				end
				finish(p, result.Position, result.Normal, true, hitPart, surfaceKind(hitPart))
				return
			end
		end
	end

	p.pos = target
	p.vel = newVel
	if p.t > p.maxTime or p.pos.Y < -40 then
		finish(p, p.pos, Vector3.new(0, 1, 0), false)
	end
end

function Proj.Update(dt)
	if next(pending) then
		for id, p in pairs(pending) do
			list[id] = p
		end
		table.clear(pending)
	end
	if not next(list) then
		return
	end
	local zombiesFolder = workspace:FindFirstChild("Zombies")
	local bus = busModel()
	updating = true
	for _, p in pairs(list) do
		local ok, err = pcall(step, p, dt, zombiesFolder, bus)
		if not ok then
			warn("[Projectiles] " .. tostring(err))
			list[p.id] = nil
			Net.Get("ProjectileEnd"):FireAllClients(p.id, p.pos, false)
		end
	end
	updating = false

	if #impacts > 0 then
		local batch = impacts
		impacts = {}
		for _, e in ipairs(batch) do
			-- (позиция, нормаль, деталь попадания, вид поверхности)
			task.spawn(e[1], e[2], e[3], e[4], e[5])
		end
	end
end

return Proj
