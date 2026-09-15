-- Типы автобусов. Покупаются за билеты в лобби, выбираются лидером группы перед заездом.
-- Размеры модели: length (вдоль, по оси Z), width (по X). Все скорости в studs/сек.
local BusTypes = {}

local rgb = Color3.fromRGB

BusTypes.Order = { "school", "minibus", "armored", "offroad", "doubledecker" }

BusTypes.List = {
	school = {
		name = "Школьный автобус",
		desc = "Надёжная классика: всего понемногу.",
		price = 0,
		color = rgb(236, 180, 40),
		length = 44,
		width = 12,
		hp = 1000,
		maxSpeed = 48,
		accel = 8,
		turnRate = 0.55, -- рад/сек на полной скорости при полном руле
		grip = 1,
		offroadMult = 1, -- множитель к штрафу бездорожья биома (больше = лучше)
		fuelMax = 100,
		fuelPerKm = 8.5,
		beds = 2,
		seats = 6,
		decks = 1,
	},
	minibus = {
		name = "Маршрутка",
		desc = "Быстрая и вёрткая, но хлипкая и тесная.",
		price = 600,
		color = rgb(240, 240, 232),
		length = 32,
		width = 10,
		hp = 650,
		maxSpeed = 60,
		accel = 11,
		turnRate = 0.75,
		grip = 1.1,
		offroadMult = 0.9,
		fuelMax = 80,
		fuelPerKm = 6.5,
		beds = 1,
		seats = 4,
		decks = 1,
	},
	armored = {
		name = "Инкассатор",
		desc = "Толстая броня, но тяжёлый и медленный.",
		price = 1500,
		color = rgb(70, 92, 70),
		length = 40,
		width = 12.5,
		hp = 2000,
		maxSpeed = 40,
		accel = 6,
		turnRate = 0.45,
		grip = 1,
		offroadMult = 0.95,
		fuelMax = 120,
		fuelPerKm = 11,
		beds = 2,
		seats = 6,
		decks = 1,
	},
	offroad = {
		name = "Вездеход «Тайга»",
		desc = "Бездорожье ему нипочём, отлично держит занос.",
		price = 2200,
		color = rgb(120, 92, 60),
		length = 38,
		width = 12.5,
		hp = 1300,
		maxSpeed = 46,
		accel = 9,
		turnRate = 0.62,
		grip = 1.35,
		offroadMult = 1.35,
		fuelMax = 110,
		fuelPerKm = 10,
		beds = 2,
		seats = 6,
		decks = 1,
	},
	doubledecker = {
		name = "Двухэтажный",
		desc = "Второй этаж: больше коек и отличная площадка для стрельбы.",
		price = 3500,
		color = rgb(190, 40, 40),
		length = 48,
		width = 13,
		hp = 1600,
		maxSpeed = 42,
		accel = 7,
		turnRate = 0.42,
		grip = 0.95,
		offroadMult = 0.85,
		fuelMax = 140,
		fuelPerKm = 12,
		beds = 4,
		seats = 8,
		decks = 2,
	},
}

for id, b in pairs(BusTypes.List) do
	b.id = id
end

function BusTypes.Get(id)
	return BusTypes.List[id] or BusTypes.List.school
end

return BusTypes
