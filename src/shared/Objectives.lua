-- Цели биомов. В каждом заезде из списка биома выбирается Config.Objectives.PerBiome целей,
-- для открытия ворот станции в конце биома нужно выполнить Config.Objectives.RequiredPerBiome.
-- Для последнего биома (Пустошь) цели открывают бой с боссом.
local Objectives = {}

--[[ Типы:
	collect — подобрать командой N предметов itemId (гарантированно лежат на месте цели)
	clear   — уничтожить гнездо (зомби типа "nest") и охрану
	rescue  — довести выжившего NPC до автобуса
	elite   — убить элитного зомби (zombie = id типа из shared/Zombies.lua)
	defend  — починить объект (site) и удерживать зону duration секунд
	cache   — найти ключ (cache_key) и открыть тайник
]]
Objectives.TypeNames = {
	collect = "Сбор",
	clear = "Зачистка",
	rescue = "Спасение",
	elite = "Охота",
	defend = "Оборона",
	cache = "Тайник",
}

Objectives.ByBiome = {
	desert = {
		{ type = "collect", item = "gas_can", count = 3, title = "Бензин для станции" },
		{ type = "rescue", title = "Застрявший дальнобойщик" },
		{ type = "elite", zombie = "sand_giant", title = "Песчаный великан" },
		{ type = "defend", site = "radio", duration = 45, title = "Радиовышка" },
	},
	city = {
		{ type = "clear", title = "Гнездо в торговом центре" },
		{ type = "collect", item = "medkit", count = 2, title = "Лекарства для станции" },
		{ type = "rescue", title = "Выживший на парковке" },
		{ type = "elite", zombie = "riot_brute", title = "Бронированный омоновец" },
	},
	jungle = {
		{ type = "cache", title = "Тайник исследователей" },
		{ type = "elite", zombie = "jungle_giant", title = "Лесной великан" },
		{ type = "collect", item = "orchid", count = 2, title = "Редкие орхидеи" },
		{ type = "clear", title = "Гнездо в руинах" },
	},
	swamp = {
		{ type = "defend", site = "pump", duration = 50, title = "Насосная станция" },
		{ type = "rescue", title = "Рыбак из лодочной" },
		{ type = "elite", zombie = "swamp_hag", title = "Болотная утопленница" },
		{ type = "collect", item = "herbs", count = 4, title = "Травы для знахаря" },
	},
	snow = {
		{ type = "defend", site = "generator", duration = 55, title = "Генератор" },
		{ type = "elite", zombie = "yeti", title = "Снежный великан" },
		{ type = "cache", title = "Тайник альпинистов" },
		{ type = "collect", item = "wolf_pelt", count = 2, title = "Шкуры для тепла" },
	},
	wasteland = {
		{ type = "clear", title = "Гнездо у бункера" },
		{ type = "elite", zombie = "mutant", title = "Мутант" },
		{ type = "defend", site = "radio", duration = 60, title = "Военная рация" },
	},
}

return Objectives
