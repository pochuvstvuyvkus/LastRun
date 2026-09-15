-- Урон: зомби, игрокам, взрывы, огонь. Всплывающие цифры урона.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local Util = require(Shared.Util)
local Net = require(Shared.Net)

local Combat = {}
local S
local rng = Random.new()

function Combat.Init(services)
	S = services
end

local function sendNumber(position, amount, kind, attacker)
	if typeof(position) ~= "Vector3" or type(amount) ~= "number" then
		return
	end
	local remote = Net.Get("DamageNumber")
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if root and (root.Position - position).Magnitude < 240 then
			remote:FireClient(plr, position, amount, kind, plr == attacker)
		end
	end
end
Combat.SendNumber = sendNumber

local function isPlayer(v)
	return typeof(v) == "Instance" and v:IsA("Player")
end

-- Элита: флаг у экземпляра (opts.elite) или у типа (def.elite)
function Combat.IsElite(z)
	return z ~= nil and (z.elite == true or (z.def ~= nil and z.def.elite == true))
end

-- Какой вид цифры показать. По элите обычные попадания — крупные фиолетовые «elite»;
-- выстрел в голову, огонь и взрывы сохраняют свой вид.
local ELITE_OVERRIDE = { normal = true, crit = true, turret = true, mg_turret = true, ram = true }
local function numberKind(z, kind)
	kind = kind or "normal"
	if kind ~= "elite" and ELITE_OVERRIDE[kind] and Combat.IsElite(z) then
		return "elite"
	end
	return kind
end

-- info: attacker (Player), kind, position, knockDir, knockback, stun, noNumber, weapon
-- Опыт и деньги за убийство здесь не начисляются — это делает ZombieService по z.lastInfo.
function Combat.DamageZombie(z, amount, info)
	if not z or z.dead then
		return false
	end
	info = info or {}
	local hum = z.humanoid
	if not hum or hum.Health <= 0 or not z.root then
		return false
	end
	if type(amount) ~= "number" or amount ~= amount then
		return false
	end
	amount = math.max(0, amount)
	if not isPlayer(info.attacker) then
		info.attacker = nil
	end
	z.lastInfo = info
	-- фильтр урона зомби (щит riot_brute и т.п.): до цифр урона и проверки убийства
	if type(z.damageFilter) == "function" then
		local okFilter, filtered = pcall(z.damageFilter, z, amount, info)
		if okFilter and type(filtered) == "number" and filtered == filtered then
			amount = math.max(0, filtered)
		end
	end
	if info.attacker then
		z.aggro = true
		z.nextThink = 0
	end
	if info.kind == "fire" and info.attacker then
		z.burnAttacker = info.attacker
	end

	local pos = info.position
	if typeof(pos) ~= "Vector3" then
		local head = z.head
		pos = (head and head.Parent and head.Position or z.root.Position) + Vector3.new(0, 1.5, 0)
	end
	if not info.noNumber then
		sendNumber(pos, amount, numberKind(z, info.kind), info.attacker)
	end

	local killed = hum.Health - amount <= 0
	if info.knockback and info.knockback > 0 and info.knockDir and not killed then
		S.Zombies.Knockback(z, info.knockDir, info.knockback, info.stun)
	elseif info.stun and not killed then
		S.Zombies.Stun(z, info.stun)
	end
	if info.attacker then
		Net.Get("HitConfirm"):FireClient(info.attacker, killed, info.kind == "headshot")
	end
	if killed and info.knockDir then
		-- эффектный полёт трупа
		z.deathImpulse = info.knockDir * math.max(info.knockback or 0, 20)
	end
	hum.Health = hum.Health - amount
	return killed
end

-- info: kind, zombie, silent, noSleepWake, knock (Vector3),
-- biomeEffect (true — накладывать эффект биома зомби; по умолчанию только для kind "zombie" не-людей)
-- kind "elite" — удар элитного зомби: сильнее тряска
function Combat.DamagePlayer(player, amount, info)
	info = info or {}
	if not isPlayer(player) or type(amount) ~= "number" or amount ~= amount or amount <= 0 then
		return
	end
	local d = S.PlayerData.Get(player)
	if not d or d.Dead then
		return
	end
	if S.Run and S.Run.State == "Victory" then
		return
	end
	if info.kind == nil and Combat.IsElite(info.zombie) then
		info.kind = "elite"
	end
	local char = player.Character
	local hum = Util.AliveHumanoid(char)
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not root then
		return
	end

	if S.Sleep.IsSleeping(player) and not info.noSleepWake then
		amount = amount * Config.Sleep.AttackedDamageMult
		S.Sleep.OnAttacked(player, info)
	end

	if d.Downed then
		-- лежачего добивают: время до смерти сокращается
		d.DownedUntil = d.DownedUntil - amount * 0.25
		player:SetAttribute("DownedUntil", d.DownedUntil)
		return
	end

	if not info.silent then
		d.LastDamage = os.clock()
	end
	local newHP = hum.Health - amount
	if newHP <= 0 then
		hum.Health = 1
		S.PlayerData.SetDowned(player)
	else
		hum.Health = newHP
	end

	if not info.silent then
		Net.Get("DamageNumber"):FireClient(player, root.Position + Vector3.new(rng:NextNumber(-1, 1), 3, 0), amount, "player", false)
		local shake = math.clamp(amount / 25, 0.15, 1)
		local knock = typeof(info.knock) == "Vector3" and info.knock or nil
		if info.kind == "elite" or Combat.IsElite(info.zombie) then
			shake = math.clamp(shake * 1.6, 0.5, 1.4)
			Net.Get("Shake"):FireClient(player, shake, 0.4, knock)
		else
			Net.Get("Shake"):FireClient(player, shake, 0.25, knock)
		end
	end

	-- Эффект биома (лианы/яд/обморожение) — только от обычного удара зомби вблизи.
	-- Явный флаг info.biomeEffect имеет приоритет; без него пули мародёров, кислота
	-- и прочие виды урона эффект не накладывают.
	local z = info.zombie
	local biomeHit = info.biomeEffect
	if biomeHit == nil then
		biomeHit = info.kind == "zombie" and not (type(z) == "table" and type(z.def) == "table" and z.def.human)
	end
	if biomeHit and type(z) == "table" and z.biome and z.biome.special and z.biome.special.effect then
		local sp = z.biome.special
		if rng:NextNumber() < sp.chance then
			S.PlayerData.AddEffect(player, sp.effect, sp.duration)
			S.PlayerData.Notify(player, sp.text, Color3.fromRGB(255, 170, 90))
		end
	end
end

-- info: kind ("explosion"|"shell"|"meteor"|"lightning"|"bloater"|"slam"...), attacker, source (z),
-- hurtPlayers, hurtZombies (по умолчанию true), busMult (0 — не бить автобус), noFx
function Combat.Explode(position, radius, damage, info)
	info = info or {}
	if typeof(position) ~= "Vector3" or type(radius) ~= "number" or type(damage) ~= "number" then
		return
	end
	if not isPlayer(info.attacker) then
		info.attacker = nil
	end
	if not info.noFx then
		Net.FireNear("Explosion", position, 500, position, radius, info.kind or "explosion")
	end
	if info.hurtZombies ~= false then
		local victims = {}
		for _, z in ipairs(S.Zombies.List()) do
			if not z.dead and z.root and z ~= info.source then
				local dist = (z.root.Position - position).Magnitude
				if dist <= radius + z.radius then
					table.insert(victims, { z, dist })
				end
			end
		end
		for _, v in ipairs(victims) do
			local z, dist = v[1], v[2]
			local falloff = 1 - math.clamp(dist / (radius + z.radius), 0, 1) * 0.6
			local dir = z.root.Position - position
			if dir.Magnitude < 0.1 then
				dir = Vector3.new(0, 1, 0)
			end
			Combat.DamageZombie(z, damage * falloff, {
				attacker = info.attacker,
				kind = "explosion",
				knockDir = dir.Unit,
				knockback = 55,
				stun = 0.8,
			})
		end
	end
	if info.hurtPlayers then
		for _, plr in ipairs(Players:GetPlayers()) do
			local char = plr.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if root then
				local dist = (root.Position - position).Magnitude
				if dist <= radius then
					local falloff = 1 - math.clamp(dist / radius, 0, 1) * 0.6
					local dir = root.Position - position
					local knock = nil
					if dir.Magnitude > 0.1 then
						knock = dir.Unit * 40 + Vector3.new(0, 25, 0)
					end
					Combat.DamagePlayer(plr, damage * 0.7 * falloff, { kind = "explosion", knock = knock })
				end
			end
		end
	end
	local busRoot = S.Bus and S.Bus.Root
	local busMult = info.busMult or 0.6
	if busRoot and busRoot.Parent and busMult > 0 and (busRoot.Position - position).Magnitude <= radius + 22 then
		S.Bus.Damage(damage * busMult, { kind = "explosion" })
	end
end

-- Горящая область (коктейль Молотова)
function Combat.FireZone(position, radius, dps, duration, attacker)
	if typeof(position) ~= "Vector3" then
		return
	end
	local effects = workspace:FindFirstChild("Effects") or workspace
	local model = Instance.new("Model")
	model.Name = "FireZone"
	local disc = Util.Part({
		Name = "Disc",
		Shape = "Cylinder",
		Size = Vector3.new(0.3, radius * 2, radius * 2),
		CFrame = CFrame.new(position + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = Color3.fromRGB(255, 120, 30),
		Material = Enum.Material.Neon,
		Transparency = 0.6,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CastShadow = false,
		Parent = model,
	})
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 140, 40)
	light.Range = radius * 2
	light.Brightness = 3
	light.Parent = disc
	for i = 1, 6 do
		local a = (i / 6) * math.pi * 2
		local r = radius * rng:NextNumber(0.2, 0.75)
		local p = Util.Part({
			Name = "Flame",
			Size = Vector3.new(1, 1, 1),
			Transparency = 1,
			CFrame = CFrame.new(position + Vector3.new(math.cos(a) * r, 1, math.sin(a) * r)),
			CanCollide = false,
			CanQuery = false,
			CanTouch = false,
			Parent = model,
		})
		local fire = Instance.new("Fire")
		fire.Size = rng:NextNumber(4, 7)
		fire.Heat = 9
		fire.Parent = p
	end
	model.Parent = effects

	task.spawn(function()
		local t = 0
		while t < duration do
			task.wait(0.5)
			t = t + 0.5
			for _, z in ipairs(S.Zombies.List()) do
				if not z.dead and Util.FlatDist(z.root.Position, position) <= radius + z.radius then
					z.burnUntil = os.clock() + 2.5
					z.burnAttacker = attacker
					Combat.DamageZombie(z, dps * 0.5, { attacker = attacker, kind = "fire" })
				end
			end
		end
		model:Destroy()
	end)
end

return Combat
