-- Случайные события в пути: названия, тексты, длительность, веса выбора
local Events = {}

local rgb = Color3.fromRGB

--[[ Поля:
	title, text      — баннер (EventsUI)
	color            — цвет заголовка и метки на миникарте
	marker           — подпись метки на миникарте
	duration         — сек (максимум; событие может закончиться раньше)
	weight           — вес случайного выбора
	minKm            — не раньше этого километра
	nightOnly        — только ночью
]]
Events.List = {
	airdrop = {
		title = "ГРУЗ С ВОЗДУХА",
		text = "Самолёт сбросил ящик с припасами в стороне от дороги. Зомби уже бегут к нему!",
		color = rgb(120, 200, 255),
		marker = "Груз",
		duration = 150,
		weight = 3,
		minKm = 0,
	},
	blood_moon = {
		title = "КРОВАВАЯ ЛУНА",
		text = "Зомби быстрее и их больше, но награды удвоены. Продержитесь до конца!",
		color = rgb(255, 60, 60),
		marker = "Луна",
		duration = 150,
		weight = 2.5,
		minKm = 6,
		nightOnly = true,
	},
	horde_chase = {
		title = "ОРДА НА ХВОСТЕ",
		text = "Огромная толпа догоняет автобус. Жмите газ или отбивайтесь!",
		color = rgb(255, 150, 60),
		marker = "Орда",
		duration = 80,
		weight = 3,
		minKm = 5,
	},
	merchant = {
		title = "БРОДЯЧИЙ ТОРГОВЕЦ",
		text = "У дороги стоит фургон торговца. Он уедет через 2 минуты",
		color = rgb(255, 220, 90),
		marker = "Торговец",
		duration = 120,
		weight = 2,
		minKm = 0,
	},
	raiders = {
		title = "ЗАСАДА МАРОДЁРОВ",
		text = "Впереди баррикада и вооружённые люди. Перебейте их или прорвитесь!",
		color = rgb(230, 80, 60),
		marker = "Мародёры",
		duration = 180,
		weight = 2,
		minKm = 9,
	},
	meteor_shower = {
		title = "МЕТЕОРИТНЫЙ ДОЖДЬ",
		text = "С неба падают раскалённые камни. Уходите из красных кругов! Осколки ценятся у торговцев",
		color = rgb(255, 120, 40),
		marker = "Метеориты",
		duration = 45,
		weight = 2,
		minKm = 8,
	},
}

Events.Order = { "airdrop", "blood_moon", "horde_chase", "merchant", "raiders", "meteor_shower" }

for id, e in pairs(Events.List) do
	e.id = id
end

-- Параметры отдельных событий (баланс)
Events.Tuning = {
	airdropAhead = { 380, 520 }, -- где упадёт ящик, studs впереди автобуса
	airdropSide = { 70, 190 }, -- смещение от дороги
	airdropZombies = 5, -- v5: было 8
	hordeCount = 12, -- v5: было 20
	hordeWaves = 3,
	merchantAhead = 320,
	raidersAhead = 520,
	raidersCount = 5,
	meteorInterval = { 1.1, 2.3 },
	meteorRadius = 11,
	meteorDamage = 45,
	meteorLootChance = 0.14,
	bloodMoonCountMult = 1.5,
	bloodMoonSpeedMult = 1.2,
	bloodMoonRewardMult = 2,
}

function Events.Get(id)
	return Events.List[id]
end

return Events
