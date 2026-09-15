-- Биомы маршрута. Порядок = порядок на дороге.
local Biomes = {}

local rgb = Color3.fromRGB

Biomes.List = {
	{
		id = "desert",
		name = "Выжженная пустыня",
		subtitle = "Песок, ржавчина и тишина",
		startKm = 0,
		ground = rgb(214, 180, 122),
		groundMat = Enum.Material.Sand,
		road = rgb(74, 70, 66),
		fogColor = rgb(232, 204, 160),
		fogEnd = 950,
		ambient = rgb(120, 104, 84),
		outdoor = rgb(170, 150, 120),
		atmoDensity = 0.3,
		atmoColor = rgb(230, 200, 160),
		tint = rgb(255, 244, 228),
		offroadSpeed = 0.85,
		grip = 1,
		spawnMult = 1,
		zombies = { { "walker", 10 }, { "runner", 3 }, { "bloater", 1 }, { "spitter", 1.2 }, { "brute", 0.4 } },
		skin = { skin = rgb(146, 158, 108), shirt = rgb(160, 116, 74), pants = rgb(96, 84, 64), extra = "bandana" },
		buildings = { { "gas_station", 3 }, { "motel", 2 }, { "ranch", 2 } },
		buildingChance = 0.42,
		weather = "dust",
	},
	{
		id = "city",
		name = "Мёртвый город",
		subtitle = "Тут было шумно. Теперь шумят они",
		startKm = 18,
		ground = rgb(92, 92, 96),
		groundMat = Enum.Material.Concrete,
		road = rgb(52, 52, 56),
		fogColor = rgb(150, 150, 160),
		fogEnd = 800,
		ambient = rgb(96, 96, 104),
		outdoor = rgb(130, 130, 140),
		atmoDensity = 0.38,
		atmoColor = rgb(170, 170, 180),
		tint = rgb(236, 240, 255),
		offroadSpeed = 0.8,
		grip = 1,
		spawnMult = 1.4,
		zombies = { { "walker", 10 }, { "runner", 5 }, { "bloater", 1.5 }, { "spitter", 1.5 }, { "brute", 0.9 } },
		skin = { skin = rgb(128, 146, 120), shirt = rgb(70, 90, 140), pants = rgb(50, 50, 60), extra = "cap" },
		buildings = { { "store", 3 }, { "pharmacy", 2 }, { "police", 1.5 }, { "apartment", 3 } },
		buildingChance = 0.9,
		weather = "none",
	},
	{
		id = "jungle",
		name = "Дикие джунгли",
		subtitle = "Сойдёшь с дороги — останешься в лесу навсегда",
		startKm = 38,
		ground = rgb(58, 104, 46),
		groundMat = Enum.Material.LeafyGrass,
		road = rgb(88, 70, 50),
		fogColor = rgb(96, 130, 90),
		fogEnd = 520,
		ambient = rgb(70, 96, 64),
		outdoor = rgb(96, 128, 86),
		atmoDensity = 0.5,
		atmoColor = rgb(120, 160, 110),
		tint = rgb(226, 255, 222),
		offroadSpeed = 0.5,
		grip = 0.9,
		spawnMult = 1.25,
		zombies = { { "walker", 8 }, { "runner", 4 }, { "crawler", 4 }, { "spitter", 2 }, { "brute", 0.8 } },
		skin = { skin = rgb(94, 132, 80), shirt = rgb(110, 120, 70), pants = rgb(76, 70, 48), extra = "vines" },
		special = { effect = "Rooted", duration = 1.4, chance = 0.35, text = "Лианы опутали ноги!" },
		buildings = { { "camp", 3 }, { "temple", 1.4 }, { "stilt_hut", 2 } },
		buildingChance = 0.45,
		weather = "rain",
	},
	{
		id = "swamp",
		name = "Гнилые топи",
		subtitle = "Туман, кресты и что-то в воде",
		startKm = 58,
		ground = rgb(70, 74, 52),
		groundMat = Enum.Material.Mud,
		road = rgb(64, 60, 52),
		fogColor = rgb(110, 118, 100),
		fogEnd = 420,
		ambient = rgb(76, 80, 70),
		outdoor = rgb(96, 100, 88),
		atmoDensity = 0.6,
		atmoColor = rgb(120, 128, 110),
		tint = rgb(232, 240, 220),
		offroadSpeed = 0.6,
		grip = 0.85,
		spawnMult = 1.35,
		zombies = { { "walker", 9 }, { "crawler", 4 }, { "bloater", 3 }, { "spitter", 1.5 }, { "brute", 1 } },
		skin = { skin = rgb(104, 118, 104), shirt = rgb(60, 70, 60), pants = rgb(46, 50, 42), extra = "algae" },
		special = { effect = "Poison", duration = 4, chance = 0.35, text = "Вас отравили!" },
		buildings = { { "crypt", 2 }, { "boathouse", 2 } },
		buildingChance = 0.45,
		weather = "fog",
	},
	{
		id = "snow",
		name = "Снежный перевал",
		subtitle = "Скользко, холодно и очень тихо",
		startKm = 76,
		ground = rgb(232, 238, 246),
		groundMat = Enum.Material.Snow,
		road = rgb(120, 126, 136),
		fogColor = rgb(214, 224, 238),
		fogEnd = 600,
		ambient = rgb(140, 150, 170),
		outdoor = rgb(170, 180, 200),
		atmoDensity = 0.45,
		atmoColor = rgb(220, 230, 245),
		tint = rgb(226, 238, 255),
		offroadSpeed = 0.7,
		grip = 0.5, -- машину заносит
		spawnMult = 1.3,
		zombies = { { "walker", 9 }, { "runner", 4 }, { "brute", 1.4 }, { "bloater", 1 } },
		skin = { skin = rgb(160, 180, 196), shirt = rgb(140, 40, 40), pants = rgb(50, 56, 70), extra = "beanie" },
		special = { effect = "Frozen", duration = 2, chance = 0.4, text = "Обморожение!" },
		buildings = { { "cabin", 3 }, { "weather_station", 1.5 } },
		buildingChance = 0.42,
		weather = "snow",
	},
	{
		id = "wasteland",
		name = "Пустошь у конечной",
		subtitle = "Пепел. Дальше дороги нет",
		startKm = 92,
		ground = rgb(80, 72, 66),
		groundMat = Enum.Material.Slate,
		road = rgb(44, 40, 38),
		fogColor = rgb(120, 90, 80),
		fogEnd = 560,
		ambient = rgb(100, 80, 70),
		outdoor = rgb(130, 100, 90),
		atmoDensity = 0.55,
		atmoColor = rgb(150, 100, 80),
		tint = rgb(255, 226, 210),
		offroadSpeed = 0.75,
		grip = 1,
		spawnMult = 1.6,
		zombies = { { "walker", 7 }, { "runner", 5 }, { "brute", 2 }, { "bloater", 2 }, { "spitter", 2 } },
		skin = { skin = rgb(120, 110, 100), shirt = rgb(60, 60, 50), pants = rgb(40, 38, 34), extra = "helmet" },
		special = { damageMult = 1.2 },
		buildings = { { "bunker", 2 }, { "military_wreck", 3 } },
		buildingChance = 0.4,
		weather = "ash",
	},
}

Biomes.ById = {}
for i, b in ipairs(Biomes.List) do
	b.index = i
	Biomes.ById[b.id] = b
end

function Biomes.AtKm(km)
	local found = Biomes.List[1]
	for _, b in ipairs(Biomes.List) do
		if km >= b.startKm then
			found = b
		end
	end
	return found
end

-- Следующий биом (для плавного перехода цвета земли)
function Biomes.Next(biome)
	return Biomes.List[biome.index + 1]
end

return Biomes
