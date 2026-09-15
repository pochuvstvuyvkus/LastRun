-- Постоянная прогрессия: уровень игрока, опыт, билеты, ежедневные награды
local Progression = {}

Progression.MaxLevel = 60

-- Опыт, нужный для перехода с уровня level на level+1
function Progression.XPForLevel(level)
	return math.floor(100 * (level ^ 1.35))
end

Progression.XP = {
	killPerReward = 2, -- опыт = награда зомби ($) * это
	elite = 60,
	boss = 600,
	stationClear = 150,
	objective = 120,
	perKm = 8,
	runVictory = 800,
	revive = 40,
	craft = 5,
	event = 80,
}

Progression.Tickets = {
	perKm = 1,
	objective = 15,
	stationClear = 25,
	victory = 250,
}

-- Бонусы уровня (складываются с классом, эффектами и уровнем оружия)
function Progression.LevelPerks(level)
	level = math.max(1, level or 1)
	return {
		bonusHP = math.min(40, level - 1),
		damageBonus = math.min(0.25, (level - 1) * 0.005),
	}
end

-- Ежедневные награды: цикл из 7 дней. items выдаются в начале следующего заезда.
Progression.Daily = {
	{ tickets = 50 },
	{ tickets = 75, xp = 200 },
	{ tickets = 100, items = { gas_can = 1 } },
	{ tickets = 125, items = { medkit = 1 } },
	{ tickets = 150, xp = 500 },
	{ tickets = 200, items = { adrenaline = 1, ammo_light = 24 } },
	{ tickets = 400, xp = 1000, items = { repair_kit = 1, gunpowder = 3, circuit = 1 } },
}

-- Номер дня по UTC (для ежедневных наград)
function Progression.DayIndex(unixTime)
	return math.floor((unixTime or os.time()) / 86400)
end

return Progression
