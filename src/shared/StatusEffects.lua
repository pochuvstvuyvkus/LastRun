-- Временные эффекты игрока (баффы и дебаффы)
local StatusEffects = {}

local rgb = Color3.fromRGB

StatusEffects.List = {
	WellRested = { name = "Выспался", desc = "+15% урона", good = true, color = rgb(120, 200, 255), damageMult = 1.15 },
	Sleepy = { name = "Сонный", desc = "Разбудили — ноги ватные", good = false, color = rgb(150, 130, 200), speedMult = 0.65 },
	Adrenaline = { name = "Адреналин", desc = "+25% скорости, +20% урона", good = true, color = rgb(255, 90, 60), speedMult = 1.25, damageMult = 1.2 },
	Caffeine = { name = "Кофеин", desc = "+10% скорости", good = true, color = rgb(190, 140, 90), speedMult = 1.1 },
	Crash = { name = "Упадок сил", desc = "Действие энергетика прошло: -15% скорости", good = false, color = rgb(120, 120, 120), speedMult = 0.85 },
	Rooted = { name = "Опутан лианами", desc = "-70% скорости", good = false, color = rgb(80, 170, 60), speedMult = 0.3 },
	Frozen = { name = "Обморожение", desc = "-40% скорости", good = false, color = rgb(160, 220, 255), speedMult = 0.6 },
	Poison = { name = "Отравление", desc = "Теряете здоровье", good = false, color = rgb(140, 200, 60), dps = 3 },
	Slowed = { name = "Оглушён рёвом", desc = "-45% скорости", good = false, color = rgb(200, 160, 255), speedMult = 0.55 },
}

StatusEffects.Order = { "Adrenaline", "WellRested", "Caffeine", "Sleepy", "Crash", "Rooted", "Frozen", "Slowed", "Poison" }

for id, e in pairs(StatusEffects.List) do
	e.id = id
end

function StatusEffects.Get(id)
	return StatusEffects.List[id]
end

return StatusEffects
