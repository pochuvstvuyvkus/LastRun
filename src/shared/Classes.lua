-- Классы выживших. Выбираются в депо до отправления.
local Classes = {}

Classes.Order = { "survivor", "medic", "mechanic", "driver", "hunter", "soldier", "sleepwalker" }

Classes.List = {
	survivor = {
		name = "Выживший",
		desc = "Без слабых мест. Больше здоровья.",
		perks = { "+10 макс. здоровья" },
		maxHP = 110,
		weapons = { "shovel", "revolver" },
		items = { ammo_light = 18, bandage = 2, canned_food = 2 },
	},
	medic = {
		name = "Медик",
		desc = "Лечит быстрее и эффективнее, поднятые им союзники крепче.",
		perks = { "Лечение x2 и вдвое быстрее", "Поднятые союзники получают вдвое больше здоровья" },
		healMult = 2,
		reviveMult = 2,
		weapons = { "machete" },
		items = { medkit = 2, bandage = 4, adrenaline = 1 },
	},
	mechanic = {
		name = "Механик",
		desc = "Чинит автобус вдвое лучше, турель стреляет сильнее.",
		perks = { "Ремонт x2", "Турель +50% урона" },
		repairMult = 2,
		turretMult = 1.5,
		weapons = { "shovel" },
		items = { scrap = 6, tape = 4, gas_can = 1 },
	},
	driver = {
		name = "Водитель",
		desc = "Автобус под его управлением едет быстрее и тратит меньше топлива.",
		perks = { "+15% скорости автобуса (за рулём)", "-25% расхода топлива", "-30% урона от столкновений" },
		busSpeed = 1.15,
		fuelEff = 0.75,
		crashMult = 0.7,
		weapons = { "bat", "revolver" },
		items = { gas_can = 2, coffee = 2, ammo_light = 12 },
	},
	hunter = {
		name = "Охотник",
		desc = "Мастер лука и арбалета.",
		perks = { "+30% урона луком и арбалетом", "Быстрее натягивает тетиву" },
		bowMult = 1.3,
		drawMult = 0.8,
		weapons = { "machete", "bow" },
		items = { arrow = 30, canned_food = 1 },
	},
	soldier = {
		name = "Солдат",
		desc = "Сильнее в перестрелке, крепче телом.",
		perks = { "+15% урона огнестрелом", "+20 макс. здоровья", "Перезарядка быстрее на 20%" },
		gunMult = 1.15,
		reloadMult = 0.8,
		maxHP = 120,
		weapons = { "shovel", "shotgun" },
		items = { ammo_shell = 10, bandage = 1 },
	},
	sleepwalker = {
		name = "Лунатик",
		desc = "Во сне лечится вдвое быстрее. Если его будят зомби — впадает в ярость.",
		perks = { "Сон лечит вдвое быстрее", "Разбужен зомби -> Адреналин вместо сонливости" },
		sleepMult = 2, -- множитель лечения во сне (SleepService)
		rageOnWake = true,
		weapons = { "machete", "crossbow" },
		items = { bolt = 8, energy_drink = 1, coffee = 2 },
	},
}

for id, c in pairs(Classes.List) do
	c.id = id
end

function Classes.Get(id)
	return Classes.List[id] or Classes.List.survivor
end

-- Значение перка с запасным значением
function Classes.Perk(id, key, default)
	local c = Classes.Get(id)
	local v = c[key]
	if v == nil then
		return default
	end
	return v
end

return Classes
