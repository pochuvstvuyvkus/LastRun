-- Сложность: режим заезда + средний уровень команды + пройденные километры
local Difficulty = {}

Difficulty.Order = { "normal", "hard", "nightmare" }

Difficulty.Modes = {
	normal = { name = "Обычный", hpMult = 1, countMult = 1, damageMult = 1, rewardMult = 1, unlockAfter = nil, threatBase = 0 },
	hard = { name = "Тяжёлый", hpMult = 1.5, countMult = 1.3, damageMult = 1.3, rewardMult = 1.6, unlockAfter = "normal", threatBase = 3 },
	nightmare = { name = "Кошмар", hpMult = 2.2, countMult = 1.6, damageMult = 1.7, rewardMult = 2.5, unlockAfter = "hard", threatBase = 6 },
}

for id, m in pairs(Difficulty.Modes) do
	m.id = id
end

function Difficulty.Get(id)
	return Difficulty.Modes[id] or Difficulty.Modes.normal
end

-- Итоговые множители для зомби. teamLevel — средний уровень игроков в заезде.
function Difficulty.Scale(modeId, teamLevel, km)
	local m = Difficulty.Get(modeId)
	local lvl = math.max(0, (teamLevel or 1) - 1)
	km = math.max(0, km or 0)
	return {
		hp = m.hpMult * (1 + km / 110) * (1 + lvl * 0.015),
		damage = m.damageMult * (1 + km / 170) * (1 + lvl * 0.008),
		count = m.countMult * (1 + lvl * 0.012),
		reward = m.rewardMult,
		threat = 1 + math.floor(km / 10 + lvl / 5 + m.threatBase), -- «уровень угрозы» для интерфейса
	}
end

return Difficulty
