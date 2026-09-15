-- Типы зомби (и других врагов: гнездо, мародёры)
-- Общие поля: name, hp, speed, damage, range, cooldown, reward ($ за убийство), scale, noise (для сна), busDamage.
-- Флаги: heavy (устойчив к оглушению/отбросу), boss, elite (элита со способностью ability),
-- stationary (не двигается), human (человек, не зомби), ranged (дальняя атака), explode (взрыв).
local Zombies = {}

local rgb = Color3.fromRGB

Zombies.Types = {
	walker = {
		name = "Ходячий", hp = 60, speed = 9, damage = 8, range = 4.5, cooldown = 1.2,
		reward = 2, scale = 1, noise = 1, busDamage = 6,
	},
	runner = {
		name = "Бегун", hp = 35, speed = 19, damage = 6, range = 4.2, cooldown = 0.8,
		reward = 3, scale = 0.95, noise = 1.3, busDamage = 4, lean = true,
	},
	brute = {
		name = "Громила", hp = 320, speed = 8, damage = 24, range = 6.5, cooldown = 1.8,
		knockback = 55, reward = 15, scale = 1.7, noise = 2, busDamage = 25, heavy = true,
	},
	spitter = {
		name = "Плевальщик", hp = 55, speed = 8.5, damage = 8, range = 4.2, cooldown = 1.2,
		reward = 5, scale = 1, noise = 0.8, busDamage = 4,
		ranged = { kind = "acid", range = 50, cooldown = 2.8, speed = 105, damage = 12, keep = 22, gravity = 30 },
	},
	bloater = {
		name = "Раздутый", hp = 90, speed = 7, damage = 6, range = 4, cooldown = 1.4,
		reward = 6, scale = 1.2, fat = true, noise = 0.6, busDamage = 30,
		explode = { radius = 13, damage = 35, fuse = 0.9, trigger = 6 },
	},
	crawler = {
		name = "Ползун", hp = 40, speed = 12, damage = 7, range = 4, cooldown = 1.0,
		reward = 3, scale = 0.85, crawl = true, noise = 0.5, busDamage = 3,
	},
	conductor = {
		name = "Кондуктор", hp = 3200, speed = 11, damage = 30, range = 11, cooldown = 1.6,
		knockback = 70, reward = 500, scale = 3.2, boss = true, noise = 4, busDamage = 60, heavy = true,
	},

	-- Элита: у каждой своя способность (ability.kind)
	sand_giant = {
		name = "Песчаный великан", hp = 1400, speed = 9, damage = 30, range = 8, cooldown = 1.9,
		knockback = 60, reward = 60, scale = 2.6, noise = 3, busDamage = 45, heavy = true, elite = true,
		colors = { skin = rgb(196, 160, 104), shirt = rgb(150, 112, 70), pants = rgb(110, 84, 56) },
		ability = { kind = "boulder", cooldown = 6, minRange = 18, range = 95, speed = 80, gravity = 60, damage = 32, radius = 9 },
		desc = "Бросает валуны",
	},
	riot_brute = {
		name = "Бронированный омоновец", hp = 1500, speed = 10, damage = 26, range = 6, cooldown = 1.5,
		knockback = 65, reward = 60, scale = 2.1, noise = 3, busDamage = 40, heavy = true, elite = true,
		colors = { skin = rgb(120, 136, 118), shirt = rgb(34, 38, 48), pants = rgb(28, 30, 36) },
		shield = { mult = 0.2, dot = 0.35 }, -- спереди проходит только 20% урона
		ability = { kind = "bash", cooldown = 8, minRange = 12, range = 48, speed = 40, duration = 1.1, damage = 24, knock = 85 },
		desc = "Щит спереди, таранит",
	},
	jungle_giant = {
		name = "Лесной великан", hp = 1700, speed = 8.5, damage = 32, range = 8.5, cooldown = 2,
		knockback = 60, reward = 65, scale = 2.8, noise = 3, busDamage = 45, heavy = true, elite = true,
		colors = { skin = rgb(84, 116, 64), shirt = rgb(70, 90, 44), pants = rgb(60, 50, 36) },
		ability = { kind = "summon", cooldown = 15, range = 70, zombie = "crawler", count = 3, maxAlive = 7 },
		desc = "Призывает ползунов",
	},
	swamp_hag = {
		name = "Болотная утопленница", hp = 1100, speed = 10, damage = 20, range = 5, cooldown = 1.4,
		reward = 60, scale = 1.9, noise = 2, busDamage = 25, heavy = true, elite = true,
		colors = { skin = rgb(110, 138, 120), shirt = rgb(52, 70, 56), pants = rgb(40, 52, 44) },
		ability = { kind = "poison", cooldown = 8, range = 65, keep = 18, speed = 70, gravity = 40, radius = 10, duration = 7, dps = 7, effectTime = 4 },
		desc = "Ядовитые облака",
	},
	yeti = {
		name = "Снежный великан", hp = 1800, speed = 9.5, damage = 34, range = 8, cooldown = 1.8,
		knockback = 75, reward = 70, scale = 2.7, noise = 3, busDamage = 50, heavy = true, elite = true,
		colors = { skin = rgb(226, 234, 242), shirt = rgb(200, 212, 226), pants = rgb(180, 194, 210) },
		ability = { kind = "roar", cooldown = 11, range = 36, radius = 40, damage = 12, effect = "Slowed", fallbackEffect = "Frozen", effectTime = 3.5 },
		desc = "Замедляющий рёв",
	},
	mutant = {
		name = "Мутант", hp = 2000, speed = 13, damage = 30, range = 7, cooldown = 1.3,
		knockback = 60, reward = 80, scale = 2.4, noise = 3, busDamage = 50, heavy = true, elite = true,
		colors = { skin = rgb(150, 80, 90), shirt = rgb(90, 50, 60), pants = rgb(60, 40, 44) },
		ability = { kind = "dash", cooldown = 6, minRange = 14, range = 85, speed = 64, duration = 0.9, windup = 0.45, damage = 28, knock = 70, regen = 0.012 },
		desc = "Рывок и регенерация",
	},

	-- Гнездо: неподвижное, рождает зомби со своим tag
	nest = {
		name = "Гнездо", hp = 900, speed = 0, damage = 0, range = 0, cooldown = 99,
		reward = 40, scale = 1, noise = 0, busDamage = 0, stationary = true, heavy = true,
		spawn = { interval = 9, activateRadius = 150, maxAlive = 6, perWave = 2, types = { { "walker", 3 }, { "runner", 2 }, { "crawler", 1 } } },
	},

	-- Мародёр-человек: держит дистанцию и стреляет пулями
	raider = {
		name = "Мародёр", hp = 110, speed = 14, damage = 10, range = 4.5, cooldown = 1.1,
		reward = 12, scale = 1, noise = 1.5, busDamage = 5, human = true,
		ranged = { kind = "bullet", range = 95, cooldown = 1.5, speed = 240, damage = 9, keep = 26, gravity = 0, spread = 1.6, burst = 2 },
	},
}

for id, z in pairs(Zombies.Types) do
	z.id = id
end

-- Элита каждого биома (для случайных встреч и событий)
Zombies.BiomeElite = {
	desert = "sand_giant",
	city = "riot_brute",
	jungle = "jungle_giant",
	swamp = "swamp_hag",
	snow = "yeti",
	wasteland = "mutant",
}

function Zombies.Get(id)
	return Zombies.Types[id]
end

return Zombies
