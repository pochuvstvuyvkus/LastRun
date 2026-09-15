-- Процедурные анимации игроков без загружаемых ассетов.
-- Удары ближнего боя: замах (anticipation) -> резкий удар -> доводка -> возврат, с поворотом и
-- наклоном корпуса и шагом; у каждого оружия свой набор. Позы удержания оружия при ходьбе,
-- прицеливание, отдача и перезарядка по типу оружия, лук, бросок, еда/лечение, «при смерти».
-- Hit-stop: CharAnimator.HitStop(char, сек) — короткое замедление анимации при попадании.
-- След клинка (Trail) включается на время удара у всех игроков.
-- Работает поверх стандартных анимаций: в RunService.Stepped подменяем Motor6D.Transform (R15 и R6).
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Util = require(Shared.Util)
local Weapons = require(Shared.Weapons)
local WeaponModels = require(Shared.WeaponModels)
local Sounds = require(Shared.Sounds)
local Net = require(Shared.Net)

local CharAnimator = {}
local C
local localPlayer = Players.LocalPlayer
local rigs = {}
local trails = setmetatable({}, { __mode = "k" })

-- доля длительности удара, в которую происходит попадание (длительность = hitDelay / CONTACT)
local CONTACT = 0.3

local JOINTS_R15 = {
	RightShoulder = { "RightUpperArm", "RightShoulder" },
	LeftShoulder = { "LeftUpperArm", "LeftShoulder" },
	RightElbow = { "RightLowerArm", "RightElbow" },
	LeftElbow = { "LeftLowerArm", "LeftElbow" },
	RightWrist = { "RightHand", "RightWrist" },
	Waist = { "UpperTorso", "Waist" },
	Neck = { "Head", "Neck" },
	RightHip = { "RightUpperLeg", "RightHip" },
	LeftHip = { "LeftUpperLeg", "LeftHip" },
}
local JOINTS_R6 = {
	RightShoulder = { "Torso", "Right Shoulder" },
	LeftShoulder = { "Torso", "Left Shoulder" },
	Waist = { "HumanoidRootPart", "RootJoint" },
	Neck = { "Torso", "Neck" },
	RightHip = { "Torso", "Right Hip" },
	LeftHip = { "Torso", "Left Hip" },
}

-- Короткие имена суставов в описании поз. Значения: {наклон вперёд, поворот влево, крен} в градусах.
-- Плечо: +наклон — рука вперёд/вверх, +поворот — рука влево. Пояс: -наклон — корпус вперёд.
-- Локоть/кисть (R15): +наклон — сгиб. Бедро: +наклон — нога вперёд. Шея: +наклон — голова назад.
local ALIAS = {
	RS = "RightShoulder", LS = "LeftShoulder", RE = "RightElbow", LE = "LeftElbow", RW = "RightWrist",
	W = "Waist", N = "Neck", RH = "RightHip", LH = "LeftHip",
}

local EASE = {
	io = function(x)
		return x * x * (3 - 2 * x)
	end,
	out = function(x)
		local i = 1 - x
		return 1 - i * i * i
	end,
	["in"] = function(x)
		return x * x * x
	end,
	lin = function(x)
		return x
	end,
}

-- угол в [-180, 180)
local function wrap180(a)
	return (a + 180) % 360 - 180
end

local function expandPose(p)
	local out = {}
	for k, v in pairs(p) do
		out[ALIAS[k] or k] = { v[1] or 0, v[2] or 0, v[3] or 0 }
	end
	return out
end

-- Ключи {t, поза, easing}; пропущенные суставы заполняются соседними ключами
local function prepareKeys(keys)
	local list = {}
	local seen = {}
	for i, k in ipairs(keys) do
		list[i] = { k[1], expandPose(k[2]), k[3] or "io" }
		for joint in pairs(list[i][2]) do
			seen[joint] = true
		end
	end
	for joint in pairs(seen) do
		local last
		for _, k in ipairs(list) do
			local v = k[2][joint]
			if v then
				last = v
			elseif last then
				k[2][joint] = { last[1], last[2], last[3] }
			end
		end
		local nextV
		for i = #list, 1, -1 do
			local v = list[i][2][joint]
			if v then
				nextV = v
			elseif nextV then
				list[i][2][joint] = { nextV[1], nextV[2], nextV[3] }
			end
		end
	end
	return list
end

local function lerpPose(a, b, k)
	local out = {}
	for joint, v0 in pairs(a) do
		local v1 = b[joint] or v0
		out[joint] = { v0[1] + (v1[1] - v0[1]) * k, v0[2] + (v1[2] - v0[2]) * k, v0[3] + (v1[3] - v0[3]) * k }
	end
	for joint, v1 in pairs(b) do
		if not out[joint] then
			out[joint] = { v1[1], v1[2], v1[3] }
		end
	end
	return out
end

local function sample(keys, t)
	local n = #keys
	if t <= keys[1][1] then
		return keys[1][2]
	end
	if t >= keys[n][1] then
		return keys[n][2]
	end
	for i = 1, n - 1 do
		local a, b = keys[i], keys[i + 1]
		if t <= b[1] then
			local span = b[1] - a[1]
			local x = span > 0 and (t - a[1]) / span or 1
			local ease = EASE[b[3]] or EASE.io
			return lerpPose(a[2], b[2], ease(math.clamp(x, 0, 1)))
		end
	end
	return keys[n][2]
end

local ANIMS = {}

local function K(t, pose, ease)
	return { t, pose, ease }
end

local function keyAnim(name, spec)
	spec.keys = prepareKeys(spec.keys)
	spec.tEnd = spec.tEnd or spec.keys[#spec.keys][1]
	ANIMS[name] = spec
end

-- Удары ближнего боя ----------------------------------------------------------------------
-- Все удары: 0 — старт, ~0.2 — пик замаха, 0.3 — попадание (easing "in" — резкое ускорение),
-- ~0.42 — доводка ("out"), ~0.6 — фиксация, дальше плавный возврат к позе удержания.

-- Лопата (инструмент продолжает предплечье: плечо 0° — вниз, 90° — вперёд). Держат двумя руками:
-- правая у рукояти возле бедра, левая на черенке; удары — боковой замах, обратный замах, сверху.
-- Боковой замах: полотно заводится вправо-назад и широко идёт справа налево
keyAnim("shovel_side", { melee = true, keys = {
	K(0, { RS = { 25, 10, 0 }, RE = { 30 }, RW = { -10 }, LS = { 45, -28, 0 }, LE = { 20 }, W = { 0, 0, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.2, { RS = { 95, -105, 0 }, RE = { 55 }, RW = { 15, 80, 0 }, LS = { 85, -80, 0 }, LE = { 35 }, W = { -6, -55, 0 }, RH = { -8 }, LH = { 14 } }),
	K(0.3, { RS = { 92, 25, 0 }, RE = { 10 }, RW = { 0, 80, 0 }, LS = { 88, 5, 0 }, LE = { 10 }, W = { -10, 30, 0 }, RH = { -12 }, LH = { 18 } }, "in"),
	K(0.42, { RS = { 85, 75, 0 }, RE = { 20 }, RW = { -10, 80, 0 }, LS = { 80, 55, 0 }, LE = { 25 }, W = { -8, 55, 0 }, RH = { -10 }, LH = { 14 } }, "out"),
	K(0.58, { RS = { 60, 45, 0 }, RE = { 35 }, RW = { 0, 40, 0 }, LS = { 62, 25, 0 }, LE = { 35 }, W = { -4, 35, 0 }, RH = { -5 }, LH = { 8 } }),
} })

-- Обратный замах: полотно заводится влево и идёт слева направо
keyAnim("shovel_back", { melee = true, keys = {
	K(0, { RS = { 55, 45, 0 }, RE = { 35 }, RW = { 0 }, LS = { 58, 25, 0 }, LE = { 40 }, W = { 0, 30, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.2, { RS = { 95, 90, -10 }, RE = { 60 }, RW = { 15, -50, 0 }, LS = { 92, 75, 0 }, LE = { 60 }, W = { 4, 55, 0 }, RH = { 10 }, LH = { -4 } }),
	K(0.3, { RS = { 90, -25, 0 }, RE = { 8 }, RW = { 0, -60, 0 }, LS = { 88, -45, 0 }, LE = { 10 }, W = { -8, -30, 0 }, RH = { 16 }, LH = { -10 } }, "in"),
	K(0.44, { RS = { 78, -85, 10 }, RE = { 22 }, RW = { -10, -60, 0 }, LS = { 76, -100, 0 }, LE = { 28 }, W = { -6, -60, 0 }, RH = { 14 }, LH = { -8 } }, "out"),
	K(0.6, { RS = { 50, -45, 0 }, RE = { 40 }, RW = { 0, -25, 0 }, LS = { 55, -60, 0 }, LE = { 45 }, W = { 0, -30, 0 }, RH = { 6 }, LH = { -4 } }),
} })

-- Удар сверху (финальный в серии): лопата поднимается над головой и рубит вниз-вперёд
keyAnim("shovel_overhead", { melee = true, keys = {
	K(0, { RS = { 110, -5, 0 }, RE = { 60 }, RW = { 0 }, LS = { 100, -15, 0 }, LE = { 60 }, W = { 5, -5, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.2, { RS = { 175, -5, 0 }, RE = { 80 }, RW = { -30 }, LS = { 165, -20, 0 }, LE = { 80 }, W = { 18, -8, 0 }, RH = { 0 }, LH = { -4 } }),
	K(0.3, { RS = { 70, 0, 0 }, RE = { 5 }, RW = { 15 }, LS = { 65, -15, 0 }, LE = { 10 }, W = { -30, 0, 0 }, RH = { -10 }, LH = { 22 } }, "in"),
	K(0.42, { RS = { 45, 0, 0 }, RE = { 10 }, RW = { 25 }, LS = { 42, -12, 0 }, LE = { 15 }, W = { -38, 0, 0 }, RH = { -12 }, LH = { 24 } }, "out"),
	K(0.6, { RS = { 55, 0, 0 }, RE = { 35 }, RW = { 10 }, LS = { 55, -12, 0 }, LE = { 35 }, W = { -18, 0, 0 }, RH = { -6 }, LH = { 12 } }),
} })

-- Бита: размашистый удар двумя руками и обратный замах
keyAnim("bat_swing", { melee = true, keys = {
	K(0, { RS = { 90, -40, 0 }, RE = { 60 }, RW = { 30 }, LS = { 85, -60, 0 }, LE = { 70 }, W = { 0, -20, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.2, { RS = { 120, -95, 15 }, RE = { 85 }, RW = { 40, 60, 0 }, LS = { 110, -90, 0 }, LE = { 90 }, W = { 4, -60, 0 }, RH = { -4 }, LH = { 10 } }),
	K(0.3, { RS = { 92, 30, 0 }, RE = { 10 }, RW = { 0, 70, 0 }, LS = { 90, 10, 0 }, LE = { 8 }, W = { -8, 35, 0 }, RH = { -10 }, LH = { 16 } }, "in"),
	K(0.44, { RS = { 70, 100, -10 }, RE = { 30 }, RW = { -20, 70, 0 }, LS = { 72, 80, 0 }, LE = { 35 }, W = { -5, 70, 0 }, RH = { -8 }, LH = { 14 } }, "out"),
	K(0.6, { RS = { 70, 70, 0 }, RE = { 50 }, RW = { 0, 30, 0 }, LS = { 70, 50, 0 }, LE = { 55 }, W = { 0, 45, 0 }, RH = { -4 }, LH = { 6 } }),
} })

keyAnim("bat_backswing", { melee = true, keys = {
	K(0, { RS = { 80, 60, 0 }, RE = { 40 }, RW = { 0 }, LS = { 80, 40, 0 }, LE = { 45 }, W = { 0, 35, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.2, { RS = { 105, 95, -10 }, RE = { 70 }, RW = { 20, -60, 0 }, LS = { 100, 80, 0 }, LE = { 75 }, W = { 4, 60, 0 }, RH = { 10 }, LH = { -4 } }),
	K(0.3, { RS = { 92, -30, 0 }, RE = { 8 }, RW = { 0, -70, 0 }, LS = { 90, -50, 0 }, LE = { 10 }, W = { -8, -35, 0 }, RH = { 16 }, LH = { -10 } }, "in"),
	K(0.44, { RS = { 75, -95, 10 }, RE = { 25 }, RW = { -10, -70, 0 }, LS = { 75, -110, 0 }, LE = { 30 }, W = { -6, -65, 0 }, RH = { 14 }, LH = { -8 } }, "out"),
	K(0.6, { RS = { 70, -60, 0 }, RE = { 45 }, RW = { 0, -30, 0 }, LS = { 70, -70, 0 }, LE = { 50 }, W = { 0, -40, 0 }, RH = { 6 }, LH = { -4 } }),
} })

-- Мачете: быстрые косые удары, восходящий и укол
keyAnim("machete_slash_r", { melee = true, keys = {
	K(0, { RS = { 100, -40, 20 }, RE = { 50 }, RW = { 20 }, LS = { 30, 0, 0 }, W = { 0, -15, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.2, { RS = { 160, -70, 35 }, RE = { 70 }, RW = { -20 }, LS = { 40, 20, 0 }, W = { 8, -40, 0 }, RH = { -4 }, LH = { 8 } }),
	K(0.3, { RS = { 75, 35, -15 }, RE = { 10 }, RW = { 10 }, LS = { 30, -10, 0 }, W = { -12, 25, 5 }, RH = { -8 }, LH = { 14 } }, "in"),
	K(0.42, { RS = { 45, 65, -20 }, RE = { 20 }, RW = { 20 }, LS = { 25, -20, 0 }, W = { -14, 40, 5 }, RH = { -8 }, LH = { 14 } }, "out"),
	K(0.58, { RS = { 60, 30, -5 }, RE = { 50 }, RW = { 20 }, LS = { 25, -10, 0 }, W = { -5, 15, 0 }, RH = { -3 }, LH = { 5 } }),
} })

keyAnim("machete_slash_l", { melee = true, keys = {
	K(0, { RS = { 90, 40, -10 }, RE = { 50 }, RW = { 20 }, LS = { 30, 0, 0 }, W = { 0, 20, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.2, { RS = { 150, 60, -30 }, RE = { 80 }, RW = { -15 }, LS = { 40, -20, 0 }, W = { 8, 40, 0 }, RH = { 8 }, LH = { -4 } }),
	K(0.3, { RS = { 80, -45, 20 }, RE = { 10 }, RW = { 10 }, LS = { 30, 10, 0 }, W = { -12, -25, -5 }, RH = { 12 }, LH = { -6 } }, "in"),
	K(0.42, { RS = { 55, -80, 25 }, RE = { 15 }, RW = { 15 }, LS = { 25, 15, 0 }, W = { -14, -40, -5 }, RH = { 12 }, LH = { -6 } }, "out"),
	K(0.58, { RS = { 60, -40, 10 }, RE = { 45 }, RW = { 15 }, LS = { 25, 5, 0 }, W = { -5, -15, 0 }, RH = { 5 }, LH = { -3 } }),
} })

keyAnim("machete_rise", { melee = true, keys = {
	K(0, { RS = { 50, -30, 15 }, RE = { 40 }, RW = { 20 }, LS = { 30, 0, 0 }, W = { 0, -15, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.2, { RS = { 20, -60, 25 }, RE = { 20 }, RW = { 30 }, LS = { 45, 20, 0 }, W = { -15, -35, 0 }, RH = { -6 }, LH = { 10 } }),
	K(0.3, { RS = { 130, 30, -10 }, RE = { 15 }, RW = { -10 }, LS = { 30, -10, 0 }, W = { 5, 25, 0 }, RH = { -6 }, LH = { 10 } }, "in"),
	K(0.42, { RS = { 160, 50, -15 }, RE = { 25 }, RW = { -20 }, LS = { 25, -15, 0 }, W = { 10, 35, 0 }, RH = { -4 }, LH = { 8 } }, "out"),
	K(0.58, { RS = { 100, 20, 0 }, RE = { 55 }, RW = { 10 }, LS = { 25, -5, 0 }, W = { 0, 10, 0 }, RH = { -2 }, LH = { 4 } }),
} })

keyAnim("machete_stab", { melee = true, keys = {
	K(0, { RS = { 70, 0, 0 }, RE = { 80 }, RW = { 20 }, LS = { 30, 0, 0 }, LE = { 20 }, W = { 0, -10, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.2, { RS = { 50, -20, 10 }, RE = { 120 }, RW = { 40 }, LS = { 60, 10, 0 }, LE = { 40 }, W = { 6, -40, 0 }, RH = { -6 }, LH = { 6 } }),
	K(0.3, { RS = { 95, 5, 0 }, RE = { 0 }, RW = { 0 }, LS = { 20, -10, 0 }, LE = { 10 }, W = { -20, 25, 0 }, RH = { 26 }, LH = { -14 } }, "in"),
	K(0.45, { RS = { 98, 5, 0 }, RE = { 0 }, RW = { 0 }, LS = { 15, -10, 0 }, LE = { 10 }, W = { -24, 28, 0 }, RH = { 28 }, LH = { -16 } }, "out"),
	K(0.62, { RS = { 80, 0, 0 }, RE = { 40 }, RW = { 15 }, LS = { 25, 0, 0 }, LE = { 20 }, W = { -8, 10, 0 }, RH = { 10 }, LH = { -6 } }),
} })

-- Пожарный топор: тяжёлый рубящий сверху и горизонтальный размах
keyAnim("axe_chop", { melee = true, keys = {
	K(0, { RS = { 120, -5, 0 }, RE = { 50 }, RW = { 0 }, LS = { 110, -15, 0 }, LE = { 55 }, W = { 6, -5, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.22, { RS = { 178, -8, 0 }, RE = { 95 }, RW = { -35 }, LS = { 172, -22, 0 }, LE = { 95 }, W = { 22, -10, 0 }, RH = { 2 }, LH = { -6 } }),
	K(0.3, { RS = { 60, 0, 0 }, RE = { 5 }, RW = { 20 }, LS = { 55, -14, 0 }, LE = { 8 }, W = { -38, 0, 0 }, RH = { -14 }, LH = { 26 } }, "in"),
	K(0.44, { RS = { 35, 0, 0 }, RE = { 10 }, RW = { 30 }, LS = { 32, -10, 0 }, LE = { 12 }, W = { -45, 0, 0 }, RH = { -16 }, LH = { 28 } }, "out"),
	K(0.62, { RS = { 50, 0, 0 }, RE = { 35 }, RW = { 10 }, LS = { 50, -12, 0 }, LE = { 35 }, W = { -20, 0, 0 }, RH = { -8 }, LH = { 14 } }),
} })

keyAnim("axe_sweep", { melee = true, keys = {
	K(0, { RS = { 85, -45, 0 }, RE = { 40 }, RW = { 0 }, LS = { 75, -20, 0 }, LE = { 55 }, W = { 0, -25, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.22, { RS = { 100, -120, 0 }, RE = { 50 }, RW = { 10, 90, 0 }, LS = { 90, -95, 0 }, LE = { 40 }, W = { -8, -70, 0 }, RH = { -10 }, LH = { 18 } }),
	K(0.3, { RS = { 88, 20, 0 }, RE = { 8 }, RW = { 0, 90, 0 }, LS = { 85, 0, 0 }, LE = { 8 }, W = { -14, 25, 0 }, RH = { -14 }, LH = { 22 } }, "in"),
	K(0.44, { RS = { 80, 85, 0 }, RE = { 15 }, RW = { -10, 90, 0 }, LS = { 78, 65, 0 }, LE = { 20 }, W = { -12, 65, 0 }, RH = { -12 }, LH = { 18 } }, "out"),
	K(0.62, { RS = { 72, 55, 0 }, RE = { 35 }, RW = { 0, 40, 0 }, LS = { 70, 40, 0 }, LE = { 40 }, W = { -6, 40, 0 }, RH = { -6 }, LH = { 8 } }),
} })

-- Катана: быстрые диагональные разрезы двумя руками и круговой удар
keyAnim("katana_slash_r", { melee = true, keys = {
	K(0, { RS = { 115, -25, 10 }, RE = { 50 }, RW = { -10 }, LS = { 105, -45, 0 }, LE = { 55 }, W = { 0, -15, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.18, { RS = { 165, -55, 25 }, RE = { 75 }, RW = { -30 }, LS = { 155, -70, 10 }, LE = { 80 }, W = { 10, -40, 0 }, RH = { -4 }, LH = { 10 } }),
	K(0.3, { RS = { 70, 40, -15 }, RE = { 5 }, RW = { 15 }, LS = { 65, 15, -5 }, LE = { 10 }, W = { -16, 30, 5 }, RH = { -12 }, LH = { 20 } }, "in"),
	K(0.42, { RS = { 45, 70, -20 }, RE = { 15 }, RW = { 25 }, LS = { 42, 50, -10 }, LE = { 20 }, W = { -18, 45, 5 }, RH = { -12 }, LH = { 20 } }, "out"),
	K(0.56, { RS = { 70, 35, 0 }, RE = { 40 }, RW = { 10 }, LS = { 70, 15, 0 }, LE = { 45 }, W = { -8, 20, 0 }, RH = { -5 }, LH = { 8 } }),
} })

keyAnim("katana_slash_l", { melee = true, keys = {
	K(0, { RS = { 110, 20, -10 }, RE = { 50 }, RW = { -10 }, LS = { 100, 0, 0 }, LE = { 55 }, W = { 0, 15, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.18, { RS = { 160, 55, -25 }, RE = { 75 }, RW = { -30 }, LS = { 150, 35, -10 }, LE = { 80 }, W = { 10, 40, 0 }, RH = { 10 }, LH = { -4 } }),
	K(0.3, { RS = { 70, -45, 15 }, RE = { 5 }, RW = { 15 }, LS = { 65, -65, 5 }, LE = { 10 }, W = { -16, -30, -5 }, RH = { 20 }, LH = { -12 } }, "in"),
	K(0.42, { RS = { 45, -75, 20 }, RE = { 15 }, RW = { 25 }, LS = { 42, -95, 10 }, LE = { 20 }, W = { -18, -45, -5 }, RH = { 20 }, LH = { -12 } }, "out"),
	K(0.56, { RS = { 70, -35, 0 }, RE = { 40 }, RW = { 10 }, LS = { 70, -55, 0 }, LE = { 45 }, W = { -8, -20, 0 }, RH = { 8 }, LH = { -5 } }),
} })

keyAnim("katana_spin", { melee = true, keys = {
	K(0, { RS = { 90, -60, 0 }, RE = { 20 }, RW = { 0 }, LS = { 85, -80, 0 }, LE = { 30 }, W = { 0, -40, 0 }, N = { 0, 0, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.15, { RS = { 92, -90, 0 }, RE = { 10 }, RW = { 0, 80, 0 }, LS = { 88, -105, 0 }, LE = { 20 }, W = { -6, -70, 0 }, RH = { -8 }, LH = { 12 } }),
	K(0.3, { RS = { 92, 20, 0 }, RE = { 0 }, RW = { 0, 80, 0 }, LS = { 88, 0, 0 }, LE = { 10 }, W = { -10, 150, 0 }, RH = { -8 }, LH = { 12 } }, "lin"),
	K(0.45, { RS = { 90, 40, 0 }, RE = { 5 }, RW = { 0, 80, 0 }, LS = { 86, 20, 0 }, LE = { 15 }, W = { -10, 290, 0 }, RH = { -6 }, LH = { 10 } }, "lin"),
	K(0.56, { RS = { 85, 20, 0 }, RE = { 20 }, RW = { 0, 30, 0 }, LS = { 85, 0, 0 }, LE = { 30 }, W = { -6, 360, 0 }, RH = { -3 }, LH = { 5 } }, "out"),
} })

-- Кувалда: удар по земле сверху
keyAnim("sledge_slam", { melee = true, keys = {
	K(0, { RS = { 100, 10, 0 }, RE = { 50 }, RW = { 0 }, LS = { 100, -20, 0 }, LE = { 55 }, W = { 4, 0, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.22, { RS = { 178, 10, 0 }, RE = { 70 }, RW = { -40 }, LS = { 178, -10, 0 }, LE = { 70 }, W = { 25, 0, 0 }, RH = { 4 }, LH = { -4 } }),
	K(0.3, { RS = { 40, 8, 0 }, RE = { 0 }, RW = { 25 }, LS = { 40, -8, 0 }, LE = { 0 }, W = { -50, 0, 0 }, RH = { -18 }, LH = { 28 } }, "in"),
	K(0.42, { RS = { 30, 8, 0 }, RE = { 5 }, RW = { 30 }, LS = { 30, -8, 0 }, LE = { 5 }, W = { -55, 0, 0 }, RH = { -20 }, LH = { 30 } }, "out"),
	K(0.62, { RS = { 35, 8, 0 }, RE = { 15 }, RW = { 20 }, LS = { 35, -8, 0 }, LE = { 15 }, W = { -40, 0, 0 }, RH = { -14 }, LH = { 22 } }),
} })

-- Бросок
keyAnim("throw", { keys = {
	K(0, { RS = { 100, -20, 0 }, RE = { 60 }, RW = { 0 }, LS = { 40, 0, 0 }, W = { 0, -10, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.3, { RS = { 170, -35, 20 }, RE = { 100 }, RW = { -30 }, LS = { 80, 20, 0 }, W = { 12, -40, 0 }, RH = { -6 }, LH = { 10 } }),
	K(0.45, { RS = { 110, 20, -10 }, RE = { 10 }, RW = { 20 }, LS = { 30, -10, 0 }, W = { -15, 25, 0 }, RH = { -12 }, LH = { 18 } }, "in"),
	K(0.6, { RS = { 60, 35, -10 }, RE = { 20 }, RW = { 30 }, LS = { 25, -10, 0 }, W = { -18, 30, 0 }, RH = { -10 }, LH = { 14 } }, "out"),
} })

-- Еда: рука ко рту, жевание
keyAnim("eat", { keys = {
	K(0, { RS = { 40, 20, 0 }, RE = { 60 }, RW = { 0 }, N = { 0 } }),
	K(0.22, { RS = { 50, 38, 0 }, RE = { 135 }, RW = { 25 }, N = { -8 } }),
	K(0.36, { RE = { 122 }, N = { -2 } }),
	K(0.5, { RE = { 136 }, N = { -10 } }),
	K(0.64, { RE = { 122 }, N = { -2 } }),
	K(0.78, { RE = { 136 }, N = { -10 } }),
} })

-- Действия с предметами в руке ------------------------------------------------------------

-- Питьё: рука к губам, голова запрокинута
keyAnim("drink", { keys = {
	K(0, { RS = { 40, 20, 0 }, RE = { 60 }, RW = { 0 }, N = { 0 } }),
	K(0.25, { RS = { 70, 35, 0 }, RE = { 140 }, RW = { 20 }, N = { 20 } }, "out"),
	K(0.8, { RS = { 75, 35, 0 }, RE = { 145 }, RW = { 25 }, N = { 25 } }),
} })

-- Укол: замах и игла в бедро
keyAnim("inject", { keys = {
	K(0, { RS = { 40, 10, 0 }, RE = { 60 }, W = { 0 } }),
	K(0.3, { RS = { 110, 10, 20 }, RE = { 90 }, W = { 0 } }, "out"),
	K(0.45, { RS = { 10, 30, 0 }, RE = { 30 }, W = { -15, 10, 0 } }, "in"),
	K(0.8, { RS = { 10, 30, 0 }, RE = { 30 }, W = { -12, 10, 0 } }),
} })

-- Установка на землю: наклон и присед
keyAnim("place", { keys = {
	K(0, { RS = { 40, 10, 0 }, RE = { 50 }, LS = { 30, -10, 0 }, LE = { 30 }, W = { 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.35, { RS = { 70, 5, 0 }, RE = { 10 }, LS = { 60, -5, 0 }, LE = { 10 }, W = { -45, 0, 0 }, RH = { 40 }, LH = { 10 } }, "out"),
	K(0.65, { RS = { 72, 5, 0 }, RE = { 10 }, LS = { 62, -5, 0 }, LE = { 10 }, W = { -45, 0, 0 }, RH = { 40 }, LH = { 10 } }),
} })

-- Прикрепить к автобусу: толчок двумя руками вперёд
keyAnim("attach", { keys = {
	K(0, { RS = { 60, 15, 0 }, RE = { 40 }, LS = { 60, -15, 0 }, LE = { 40 }, W = { 0 } }),
	K(0.3, { RS = { 70, 15, 0 }, RE = { 80 }, LS = { 70, -15, 0 }, LE = { 80 }, W = { 5, 0, 0 } }, "out"),
	K(0.45, { RS = { 88, 10, 0 }, RE = { 5 }, LS = { 88, -10, 0 }, LE = { 5 }, W = { -12, 0, 0 } }, "in"),
	K(0.7, { RS = { 85, 10, 0 }, RE = { 10 }, LS = { 85, -10, 0 }, LE = { 10 }, W = { -10, 0, 0 } }),
} })

-- Закинуть в печь: снизу вперёд двумя руками
keyAnim("throw_in", { keys = {
	K(0, { RS = { 40, 10, 0 }, RE = { 50 }, LS = { 30, -10, 0 }, LE = { 40 }, W = { 0 } }),
	K(0.3, { RS = { 20, 10, 0 }, RE = { 70 }, LS = { 20, -10, 0 }, LE = { 70 }, W = { 8, 0, 0 } }, "out"),
	K(0.45, { RS = { 95, 5, 0 }, RE = { 10 }, LS = { 95, -5, 0 }, LE = { 10 }, W = { -15, 0, 0 } }, "in"),
	K(0.7, { RS = { 80, 5, 0 }, RE = { 20 }, LS = { 80, -5, 0 }, LE = { 20 }, W = { -10, 0, 0 } }),
} })

-- Осмотреть: поднести к лицу и повертеть кистью
keyAnim("inspect", { keys = {
	K(0, { RS = { 40, 15, 0 }, RE = { 60 }, RW = { 0, 0, 0 }, N = { 0, 0, 0 } }),
	K(0.25, { RS = { 55, 30, 0 }, RE = { 110 }, RW = { 0, 40, 0 }, N = { -15, 15, 0 } }, "out"),
	K(0.6, { RS = { 55, 30, 0 }, RE = { 110 }, RW = { 0, -40, 0 }, N = { -15, 10, 0 } }),
	K(0.85, { RS = { 50, 25, 0 }, RE = { 100 }, RW = { 0, 20, 0 }, N = { -10, 10, 0 } }),
} })

-- Перезарядка по типу оружия --------------------------------------------------------------
keyAnim("reload_revolver", { keys = {
	K(0, { RS = { 70, 10, 0 }, RE = { 40 }, RW = { 0 }, LS = { 60, -40, 0 }, LE = { 70 }, W = { -5, 0, 0 }, N = { 0 } }),
	K(0.12, { RS = { 45, 20, 0 }, RE = { 80 }, RW = { 0, 0, -40 }, LS = { 55, -45, 0 }, LE = { 85 }, N = { 15 } }),
	K(0.25, { RS = { 40, 20, 0 }, RE = { 95 }, RW = { -30, 0, -40 }, LS = { 35, -30, 0 }, LE = { 60 } }, "out"),
	K(0.36, { LS = { 20, 0, 0 }, LE = { 40 } }),
	K(0.5, { LS = { 55, -45, 0 }, LE = { 95 }, RW = { -10, 0, -40 } }),
	K(0.6, { LS = { 50, -45, 0 }, LE = { 85 } }),
	K(0.7, { LS = { 55, -45, 0 }, LE = { 95 } }),
	K(0.8, { RS = { 75, 5, 0 }, RE = { 30 }, RW = { 0, 0, 0 }, LS = { 70, -40, 0 }, LE = { 60 }, N = { 0 } }, "in"),
	K(0.9, { RS = { 88, 0, 0 }, RE = { 0 }, LS = { 88, -40, 0 }, LE = { 10 }, W = { 0, 0, 0 } }),
} })

keyAnim("reload_shotgun", { keys = {
	K(0, { RS = { 75, 5, 0 }, RE = { 25 }, RW = { 0 }, LS = { 75, -35, 0 }, LE = { 35 }, W = { -5, 0, 0 }, N = { 0 } }),
	K(0.12, { RS = { 50, 10, 0 }, RE = { 60 }, RW = { -35 }, LS = { 40, -25, 0 }, LE = { 50 }, W = { -12, 0, 0 }, N = { 20 } }),
	K(0.25, { RS = { 55, 10, 0 }, RE = { 50 }, RW = { -45 }, LS = { 30, -10, 0 }, LE = { 30 } }, "out"),
	K(0.4, { LS = { 5, 15, 0 }, LE = { 60 } }),
	K(0.55, { LS = { 50, -35, 0 }, LE = { 80 }, RW = { -40 } }),
	K(0.62, { LS = { 45, -35, 0 }, LE = { 70 } }),
	K(0.72, { LS = { 52, -38, 0 }, LE = { 82 } }),
	K(0.82, { RS = { 80, 5, 0 }, RE = { 20 }, RW = { 10 }, LS = { 80, -35, 0 }, LE = { 30 }, W = { -2, 0, 0 }, N = { 0 } }, "in"),
	K(0.92, { RS = { 88, 0, 0 }, RE = { 5 }, RW = { 0 }, LS = { 88, -38, 0 }, LE = { 15 }, W = { 0, 0, 0 } }),
} })

keyAnim("reload_rifle", { keys = {
	K(0, { RS = { 80, 0, 0 }, RE = { 15 }, RW = { 0 }, LS = { 80, -35, 0 }, LE = { 25 }, W = { 0, 0, 0 }, N = { 0 } }),
	K(0.1, { RS = { 60, 15, 0 }, RE = { 50 }, RW = { 0, 0, -30 }, LS = { 40, -20, 0 }, LE = { 70 }, W = { -5, 10, -6 }, N = { 15 } }),
	K(0.22, { LS = { 20, -10, 20 }, LE = { 50 } }, "out"),
	K(0.4, { LS = { 0, 20, 0 }, LE = { 40 }, W = { -5, 15, -8 } }),
	K(0.55, { LS = { 45, -20, 0 }, LE = { 85 }, W = { -5, 10, -6 } }),
	K(0.62, { RS = { 62, 15, 0 }, LS = { 52, -22, 0 }, LE = { 95 } }, "in"),
	K(0.75, { RS = { 70, 5, 0 }, RE = { 35 }, RW = { 0, 0, -10 }, LS = { 85, -5, 0 }, LE = { 120 } }),
	K(0.82, { LS = { 80, -5, 0 }, LE = { 100 } }, "out"),
	K(0.92, { RS = { 85, 0, 0 }, RE = { 10 }, RW = { 0, 0, 0 }, LS = { 85, -35, 0 }, LE = { 25 }, W = { 0, 0, 0 }, N = { 0 } }),
} })

keyAnim("reload_sniper", { keys = {
	K(0, { RS = { 85, 0, 0 }, RE = { 10 }, RW = { 0 }, LS = { 85, -35, 0 }, LE = { 25 }, W = { 0, 0, 0 }, N = { 0 } }),
	K(0.1, { RS = { 65, 10, 0 }, RE = { 45 }, LS = { 55, -30, 0 }, LE = { 55 }, W = { -4, 0, 0 }, N = { 12 } }),
	K(0.18, { RS = { 62, 14, 0 }, RE = { 55 }, RW = { 0, 0, 20 } }, "out"),
	K(0.3, { LS = { 10, 20, 0 }, LE = { 50 } }),
	K(0.42, { LS = { 60, -25, 0 }, LE = { 95 } }),
	K(0.5, { LS = { 55, -25, 0 }, LE = { 85 } }),
	K(0.58, { LS = { 60, -25, 0 }, LE = { 95 } }),
	K(0.66, { LS = { 55, -25, 0 }, LE = { 85 } }),
	K(0.76, { RS = { 68, 8, 0 }, RE = { 50 }, RW = { 0, 0, -15 }, LS = { 70, -30, 0 }, LE = { 50 } }, "in"),
	K(0.9, { RS = { 88, 0, 0 }, RE = { 5 }, RW = { 0, 0, 0 }, LS = { 88, -35, 0 }, LE = { 20 }, W = { 0, 0, 0 }, N = { 0 } }),
} })

keyAnim("reload_crossbow", { keys = {
	K(0, { RS = { 80, 0, 0 }, RE = { 15 }, RW = { 0 }, LS = { 80, -35, 0 }, LE = { 25 }, W = { 0, 0, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.18, { RS = { 25, 0, 0 }, RE = { 20 }, RW = { 20 }, LS = { 35, 0, 0 }, LE = { 20 }, W = { -30, 0, 0 }, RH = { -5 }, LH = { 10 } }),
	K(0.35, { RS = { 25, 5, 0 }, LS = { 30, -5, 0 }, LE = { 40 } }),
	K(0.55, { RS = { 35, 0, 0 }, RE = { 35 }, LS = { 60, -10, 0 }, LE = { 120 }, W = { -15, 0, 0 } }, "out"),
	K(0.68, { LS = { 65, -12, 0 }, LE = { 125 } }),
	K(0.8, { RS = { 70, 0, 0 }, RE = { 20 }, RW = { 0 }, LS = { 70, -35, 0 }, LE = { 35 }, W = { -5, 0, 0 }, RH = { 0 }, LH = { 0 } }),
	K(0.92, { RS = { 88, 0, 0 }, RE = { 10 }, LS = { 88, -35, 0 }, LE = { 20 }, W = { 0, 0, 0 } }),
} })

-- Пистолет (упрощённо): наклон, левая рука к поясу за магазином, вставка, затвор
keyAnim("reload_pistol", { keys = {
	K(0, { RS = { 88, 0, 0 }, RE = { 0 }, RW = { 0 }, LS = { 80, -40, 0 }, LE = { 30 }, W = { 0, 0, 0 }, N = { 0 } }),
	K(0.12, { RS = { 62, 18, 0 }, RE = { 50 }, RW = { 0, 0, -30 }, LS = { 60, -30, 0 }, LE = { 60 }, N = { 12 } }),
	K(0.32, { LS = { 10, 10, 0 }, LE = { 40 } }),
	K(0.54, { LS = { 55, -35, 0 }, LE = { 95 } }),
	K(0.64, { LS = { 62, -36, 0 }, LE = { 80 } }, "in"),
	K(0.8, { RS = { 80, 5, 0 }, RE = { 15 }, RW = { 0, 0, 0 }, LS = { 78, -38, 0 }, LE = { 40 }, N = { 0 } }),
	K(0.92, { RS = { 88, 0, 0 }, RE = { 0 }, LS = { 84, -40, 0 }, LE = { 30 }, W = { 0, 0, 0 } }),
} })

local RELOAD_BY_WEAPON = {
	pistol = "reload_pistol",
	revolver = "reload_revolver",
	shotgun = "reload_shotgun",
	rifle = "reload_rifle",
	sniper = "reload_sniper",
	crossbow = "reload_crossbow",
}

-- Старые имена анимаций (совместимость)
local OLD_NAMES = {
	swing_r = "bat_swing",
	swing_l = "bat_backswing",
	overhead = "axe_chop",
	slash_r = "katana_slash_r",
	slash_l = "katana_slash_l",
	stab = "machete_stab",
	spin = "katana_spin",
	slam = "sledge_slam",
	shovel_sweep = "shovel_side",
	shovel_thrust = "shovel_back",
	shovel_chop = "shovel_overhead",
}

-- Отдача по оружию: добавляется к позе прицеливания
ANIMS.recoil = {
	additive = true,
	fn = function(t, ctx)
		local def = ctx.def
		local r = def and def.recoil or 6
		local kick = t < 0.12 and (t / 0.12) or (1 - (t - 0.12) / 0.88) ^ 2
		local id = ctx.anim.weaponId
		if id == "revolver" then
			return {
				RightShoulder = { r * 0.8 * kick, 0, 0 },
				RightElbow = { r * 1.6 * kick, 0, 0 },
				RightWrist = { r * 2.2 * kick, 0, 0 },
				Waist = { r * 0.25 * kick, 0, 0 },
			}
		elseif id == "shotgun" then
			return {
				RightShoulder = { r * 0.9 * kick, 0, 0 },
				LeftShoulder = { r * 1.1 * kick, 0, 0 },
				Waist = { r * 0.7 * kick, r * 0.3 * kick, 0 },
				Neck = { r * 0.4 * kick, 0, 0 },
			}
		elseif id == "sniper" then
			return {
				RightShoulder = { r * 0.45 * kick, 0, 0 },
				LeftShoulder = { r * 0.6 * kick, 0, 0 },
				Waist = { r * 0.35 * kick, r * 0.15 * kick, 0 },
				Neck = { r * 0.3 * kick, 0, 0 },
			}
		elseif id == "crossbow" then
			return {
				RightShoulder = { 8 * kick, 0, 0 },
				LeftShoulder = { 10 * kick, 0, 0 },
				Waist = { 3 * kick, 0, 0 },
			}
		end
		local j = math.sin(ctx.now * 70) * 1.2 * kick
		return {
			RightShoulder = { r * 1.6 * kick + j, 0, 0 },
			LeftShoulder = { r * 1.4 * kick, j, 0 },
			Waist = { r * 0.4 * kick, 0, 0 },
		}
	end,
}

-- Лук держит левая рука (хват инструмента переносится в левую кисть, см. bowGrip), правая тянет
-- тетиву к щеке; при полном натяжении рука дрожит
ANIMS.bow_draw = {
	noFold = true,
	fn = function(_, ctx)
		local anim = ctx.anim
		local charge = math.clamp((ctx.now - anim.start) / anim.duration, 0, 1)
		local p = ctx.pitch
		local tremble = charge >= 1 and math.sin(ctx.now * 38) * 0.8 or 0
		if ctx.r6 then
			return {
				LeftShoulder = { 90 + p, -8, 0 },
				RightShoulder = { 85 + p + tremble, 30 + 35 * charge, 0 },
				Waist = { 0, -12 * charge, 0 },
			}
		end
		return {
			LeftShoulder = { 90 + p, -10, 0 },
			LeftElbow = { 6, 0, 0 },
			RightShoulder = { 80 + p + tremble, 30 + 25 * charge, 0 },
			RightElbow = { 20 + 105 * charge, 0, 0 },
			RightWrist = { 0, 0, 0 },
			Waist = { 0, -12 * charge, 0 },
			Neck = { p * 0.4, 8 * charge, 0 },
		}
	end,
}

ANIMS.bow_release = {
	noFold = true,
	tEnd = 0.5,
	fn = function(t, ctx)
		local p = ctx.pitch
		local k = EASE.out(math.min(1, t / 0.35))
		if ctx.r6 then
			return {
				LeftShoulder = { 90 + p, -8, 0 },
				RightShoulder = { 85 + p, 65 - 40 * k, 0 },
			}
		end
		return {
			LeftShoulder = { 90 + p - 4 * (1 - k), -10, 0 },
			LeftElbow = { 6, 0, 0 },
			RightShoulder = { 80 + p, 55 - 25 * k, 0 },
			RightElbow = { 125 - 60 * k, 0, 0 },
			Waist = { 0, -12 * (1 - k), 0 },
		}
	end,
}

ANIMS.heal = {
	tEnd = 0.92,
	fn = function(_, ctx)
		local w = ctx.now * 9
		return {
			RightShoulder = { 60 + 10 * math.sin(w), 30, 0 },
			RightElbow = { 85 + 20 * math.cos(w), 0, 0 },
			LeftShoulder = { 55 + 8 * math.cos(w), -30, 0 },
			LeftElbow = { 95 + 20 * math.sin(w), 0, 0 },
			Waist = { -12, 0, 0 },
			Neck = { -18, 0, 0 },
		}
	end,
}

-- Достали предмет: рука подхватывает его снизу и выводит в позу удержания
keyAnim("equip", { keys = {
	K(0, { RS = { 8, 10, 0 }, RE = { 20 }, RW = { 0 }, LS = { 8, -10, 0 }, LE = { 15 }, W = { 0, 0, 0 } }),
	K(0.45, { RS = { 55, 14, 0 }, RE = { 55 }, RW = { 10 }, LS = { 40, -16, 0 }, LE = { 35 } }, "out"),
	K(0.75, { RS = { 44, 12, 0 }, RE = { 45 }, RW = { 5 }, LS = { 34, -14, 0 }, LE = { 30 } }),
} })

-- Лук держат левой рукой: сварку хвата инструмента (RightGrip) переносим в левую кисть.
-- Правка локальная (у каждого клиента своя), физику не трогает — инструмент просто рисуется слева.
local BOW_GRIP_FALLBACK = CFrame.new(0, -0.15, 0) * CFrame.Angles(-math.pi / 2, 0, 0)

local function findGripWeld(char)
	for _, name in ipairs({ "RightHand", "Right Arm" }) do
		local part = char:FindFirstChild(name)
		local weld = part and part:FindFirstChild("RightGrip")
		if weld and weld:IsA("Weld") then
			return weld
		end
	end
	return nil
end

local function bowGrip(char)
	local left = char:FindFirstChild("LeftHand") or char:FindFirstChild("Left Arm")
	if not left then
		return
	end
	local weld = findGripWeld(char)
	if not weld or weld.Part0 == left then
		return
	end
	local att = left:FindFirstChild("LeftGripAttachment")
	weld.Part0 = left
	weld.C0 = (att and att:IsA("Attachment") and att.CFrame) or BOW_GRIP_FALLBACK
end

-- Позы удержания --------------------------------------------------------------------------
local HOLD_MELEE = {
	-- лопата: правая рука у рукояти возле бедра, полотно внизу-впереди, левая на черенке
	shovel = expandPose({ RS = { 22, 12, 0 }, RE = { 34 }, RW = { -12 }, LS = { 44, -26, 0 }, LE = { 20 } }),
	bat = expandPose({ RS = { 30, 10, 0 }, RE = { 110 }, RW = { 30 }, LS = { 40, -45, 0 }, LE = { 95 } }),
	machete = expandPose({ RS = { 25, -5, 8 }, RE = { 65 }, RW = { 30 } }),
	fire_axe = expandPose({ RS = { 25, 15, 0 }, RE = { 70 }, RW = { 30 }, LS = { 50, -20, 0 }, LE = { 60 } }),
	katana = expandPose({ RS = { 45, 15, 0 }, RE = { 50 }, RW = { 35 }, LS = { 45, -20, 0 }, LE = { 55 } }),
	sledgehammer = expandPose({ RS = { 10, 10, 0 }, RE = { 50 }, RW = { 20 }, LS = { 35, -20, 0 }, LE = { 40 }, W = { -5, 0, 0 } }),
}
local HOLD_BOW = expandPose({ RS = { 35, 0, 0 }, RE = { 45 }, RW = { 0 } })
local HOLD_THROW = expandPose({ RS = { 45, 10, 0 }, RE = { 60 }, RW = { 0 } })

-- Предметы в руке (не оружие) по стилю удержания из ItemModels (атрибут инструмента HoldStyle)
local HOLD_ITEM = {
	hand = expandPose({ RS = { 40, 15, 0 }, RE = { 60 }, RW = { 10 } }),
	throw = expandPose({ RS = { 45, 10, 0 }, RE = { 60 }, RW = { 0 } }),
	handle = expandPose({ RS = { -4, 0, 4 }, RE = { 8 }, RW = { 0 } }),
	carry = expandPose({ RS = { 62, 18, 0 }, RE = { 28 }, RW = { 0 }, LS = { 62, -18, 0 }, LE = { 28 }, W = { -4, 0, 0 } }),
	long = expandPose({ RS = { 30, 15, 0 }, RE = { 55 }, RW = { 25 }, LS = { 45, -25, 0 }, LE = { 45 } }),
}

local function gunHold(def, pitch, aimW)
	local two = def.twoHanded or def.kind == "crossbow"
	local aim, low
	if two then
		aim = {
			RightShoulder = { 90 + pitch, 8, 0 }, RightElbow = { 0, 0, 0 }, RightWrist = { 0, 0, 0 },
			LeftShoulder = { 90 + pitch, -45, 0 }, LeftElbow = { 10, 0, 0 }, Neck = { pitch * 0.4, 0, 0 },
		}
		low = {
			RightShoulder = { 40, 10, 0 }, RightElbow = { 50, 0, 0 }, RightWrist = { 0, 0, 0 },
			LeftShoulder = { 55, -40, 0 }, LeftElbow = { 55, 0, 0 }, Neck = { 0, 0, 0 },
		}
		return lerpPose(low, aim, aimW)
	end
	aim = {
		RightShoulder = { 90 + pitch, 0, 0 }, RightElbow = { 0, 0, 0 }, RightWrist = { 0, 0, 0 },
		LeftShoulder = { 80 + pitch, -40, 0 }, LeftElbow = { 30, 0, 0 }, Neck = { pitch * 0.4, 0, 0 },
	}
	low = {
		RightShoulder = { 40, 0, 0 }, RightElbow = { 50, 0, 0 }, RightWrist = { 0, 0, 0 },
		LeftShoulder = { 80 + pitch, -40, 0 }, LeftElbow = { 30, 0, 0 }, Neck = { 0, 0, 0 },
	}
	local pose = lerpPose(low, aim, aimW)
	-- без прицела левая рука свободна (стандартная анимация ходьбы)
	local ls, le = pose.LeftShoulder, pose.LeftElbow
	pose.LeftShoulder = { ls[1], ls[2], ls[3], aimW }
	pose.LeftElbow = { le[1], le[2], le[3], aimW }
	return pose
end

-- Копия позы с покачиванием при ходьбе
local function withSway(pose, now, moveK)
	local out = {}
	local s = math.sin(now * 9) * moveK
	for joint, v in pairs(pose) do
		local p = v[1]
		if joint == "RightShoulder" then
			p = p + s * 5
		elseif joint == "LeftShoulder" then
			p = p - s * 4
		end
		out[joint] = { p, v[2], v[3], v[4] }
	end
	if moveK > 0.05 then
		local w = out.Waist
		out.Waist = { (w and w[1] or 0) - 4 * moveK, w and w[2] or 0, w and w[3] or 0 }
	end
	return out
end

local function holdPose(def, weaponId, pitch, aimW, now, moveK)
	if not def then
		return nil
	end
	if def.kind == "gun" or def.kind == "crossbow" then
		return gunHold(def, pitch, aimW)
	elseif def.kind == "melee" then
		return withSway(HOLD_MELEE[weaponId] or HOLD_MELEE.machete, now, moveK)
	elseif def.kind == "bow" then
		return withSway(HOLD_BOW, now, moveK)
	elseif def.kind == "throw" then
		return withSway(HOLD_THROW, now, moveK)
	end
	return nil
end

-- Рига ------------------------------------------------------------------------------------

-- Завершение/замена анимации: поворот поясницы сворачиваем в [-180,180),
-- чтобы после кругового удара (до 360°) следующий удар не прокручивал торс назад
local function endAnim(rig)
	rig.anim = nil
	local waist = rig.cur.Waist
	if waist then
		waist[2] = wrap180(waist[2])
	end
end

local function buildRig(char)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum then
		return nil
	end
	local r15 = hum.RigType == Enum.HumanoidRigType.R15
	local map = r15 and JOINTS_R15 or JOINTS_R6
	local rig = {
		char = char, hum = hum, motors = {}, base = {}, cur = {}, w = {}, anim = nil, r6 = not r15,
		aimW = 1, stopUntil = 0, lastRecoil = -10,
		-- предмет в руке на момент сборки рига: при первом кадре не считаем его «только что достали»
		tool = char:FindFirstChildOfClass("Tool"),
	}
	for name, path in pairs(map) do
		local part = char:FindFirstChild(path[1])
		local motor = part and part:FindFirstChild(path[2])
		if motor and motor:IsA("Motor6D") then
			rig.motors[name] = motor
			rig.base[name] = motor.C0
		end
	end
	if not rig.motors.RightShoulder then
		return nil
	end
	return rig
end

local function getRig(char)
	local rig = rigs[char]
	if rig and rig.motors.RightShoulder and rig.motors.RightShoulder.Parent then
		return rig
	end
	rig = buildRig(char)
	rigs[char] = rig
	return rig
end

-- След клинка: Trail между TrailBase и TrailTip, создаётся один раз на инструмент
local function getTrail(tool, weaponId)
	local trail = trails[tool]
	if trail and trail.Parent then
		return trail
	end
	local handle = tool:FindFirstChild("Handle")
	local a0 = handle and handle:FindFirstChild("TrailBase")
	local a1 = handle and handle:FindFirstChild("TrailTip")
	if not (a0 and a1 and a0:IsA("Attachment") and a1:IsA("Attachment")) then
		return nil
	end
	trail = Instance.new("Trail")
	trail.Name = "LR_SwingTrail"
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.FaceCamera = false
	trail.Lifetime = 0.16
	trail.MinLength = 0.05
	trail.LightEmission = 0.35
	trail.LightInfluence = 0.4
	trail.Color = ColorSequence.new(WeaponModels.TrailColor(weaponId))
	trail.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
	trail.WidthScale = NumberSequence.new({ NumberSequenceKeypoint.new(0, 1), NumberSequenceKeypoint.new(1, 0.35) })
	trail.Enabled = false
	trail.Parent = handle
	trails[tool] = trail
	return trail
end

-- Свой персонаж от первого лица: тело и инструмент скрыты, след рисует вид от первого лица
local function localFirstPerson(char)
	if char ~= localPlayer.Character then
		return false
	end
	local head = char:FindFirstChild("Head")
	local cam = workspace.CurrentCamera
	return head ~= nil and cam ~= nil and (cam.CFrame.Position - head.Position).Magnitude < 2.5
end

local function startSwingFx(rig, weaponId, duration, contact, now)
	local tool = rig.char:FindFirstChildOfClass("Tool")
	if tool and tool:GetAttribute("WeaponId") == weaponId and not localFirstPerson(rig.char) then
		local trail = getTrail(tool, weaponId)
		if trail then
			if rig.trail and rig.trail ~= trail then
				rig.trail.Enabled = false
			end
			if not trail.Enabled then
				trail:Clear()
			end
			trail.Enabled = true
			rig.trail = trail
			rig.trailOffAt = now + duration * (contact + 0.2)
		end
	end
	-- свист своего удара играет вид от первого лица в кадре начала удара (ViewModel)
	if rig.char ~= localPlayer.Character then
		rig.swooshAt = now + duration * contact * 0.72
		rig.swooshWeapon = weaponId
	end
end

function CharAnimator.Play(char, name, weaponId, duration, hold)
	if not char or type(name) ~= "string" then
		return
	end
	name = OLD_NAMES[name] or name
	if name == "reload" then
		name = RELOAD_BY_WEAPON[weaponId] or "reload_rifle"
	end
	local spec = ANIMS[name]
	if not spec then
		return
	end
	local rig = getRig(char)
	if not rig then
		return
	end
	if rig.anim then
		endAnim(rig)
	end
	if type(duration) ~= "number" or duration ~= duration then
		duration = 0.5
	end
	local def = weaponId and Weapons.List[weaponId]
	local contact = spec.contact or CONTACT
	if spec.melee and def and type(def.hitDelay) == "number" then
		-- попадание в анимации совпадает с моментом урона на сервере
		duration = def.hitDelay / contact
	elseif name == "recoil" then
		duration = math.clamp(duration, 0.12, 0.35)
	end
	duration = math.max(0.1, duration)
	local now = os.clock()
	rig.anim = { name = name, spec = spec, weaponId = weaponId, start = now, elapsed = 0, last = now, duration = duration, hold = hold }
	if name == "recoil" then
		rig.lastRecoil = now
	end
	if spec.melee then
		startSwingFx(rig, weaponId, duration, contact, now)
	end
end

function CharAnimator.Stop(char, name)
	local rig = char and rigs[char]
	name = name and (OLD_NAMES[name] or name)
	if rig and rig.anim and (not name or rig.anim.name == name) then
		endAnim(rig)
	end
end

-- Короткое замедление анимации при попадании (hit-stop)
function CharAnimator.HitStop(char, duration)
	local rig = char and rigs[char]
	if not rig then
		return
	end
	duration = type(duration) == "number" and math.clamp(duration, 0, 0.2) or 0.06
	rig.stopUntil = math.max(rig.stopUntil or 0, os.clock() + duration)
end

function CharAnimator.LocalAimPitch()
	local cam = workspace.CurrentCamera
	if not cam then
		return 0
	end
	local look = cam.CFrame.LookVector
	return math.deg(math.asin(math.clamp(look.Y, -1, 1)))
end

local ZERO = { 0, 0, 0 }

-- Плавный возврат из конца анимации в позу удержания
local function blendToHold(pose, hold, k)
	local out = {}
	for joint, v in pairs(pose) do
		local h = hold and hold[joint]
		if h then
			out[joint] = {
				v[1] + (h[1] - v[1]) * k,
				v[2] + wrap180(h[2] - v[2]) * k,
				v[3] + (h[3] - v[3]) * k,
				1 + ((h[4] or 1) - 1) * k,
			}
		else
			out[joint] = {
				v[1] + (ZERO[1] - v[1]) * k,
				v[2] + wrap180(ZERO[2] - v[2]) * k,
				v[3] + (ZERO[3] - v[3]) * k,
				1 - k,
			}
		end
	end
	return out
end

local function computeTargets(plr, rig, now, dt)
	if plr:GetAttribute("Sleeping") then
		if rig.anim then
			endAnim(rig)
		end
		return nil
	end
	local targets = {}
	if plr:GetAttribute("Downed") then
		if rig.anim then
			endAnim(rig)
		end
		targets.Waist = { -65, 0, 0 }
		targets.RightShoulder = { 110, 10, 0 }
		targets.LeftShoulder = { 110, -10, 0 }
		return targets
	end
	local char = rig.char
	local tool = char:FindFirstChildOfClass("Tool")
	local weaponId = tool and tool:GetAttribute("WeaponId")
	local def = weaponId and Weapons.List[weaponId]
	local isLocal = plr == localPlayer
	-- предмет в руках сменился: у других игроков — короткая анимация доставания со звуком
	-- (свои руки от первого лица делает ViewModel)
	if tool ~= rig.tool then
		rig.tool = tool
		if tool and not isLocal then
			local itemId = tool:GetAttribute("ItemId")
			local key = (weaponId and Weapons.EquipSound(weaponId))
				or (type(itemId) == "string" and Sounds.PickupKey(itemId, tool:GetAttribute("ItemKind")))
			local toolRoot = char:FindFirstChild("HumanoidRootPart")
			if key and toolRoot and C and C.Effects then
				C.Effects.Play(key, toolRoot.Position, nil, 0.7)
			end
			CharAnimator.Play(char, "equip", weaponId, 0.32)
		end
	end
	-- лук держит левая рука (хват переносится один раз на инструмент)
	if tool and def and def.kind == "bow" then
		bowGrip(char)
	end
	local pitch
	if isLocal then
		pitch = CharAnimator.LocalAimPitch()
	else
		pitch = char:GetAttribute("AimPitch") or 0
	end
	pitch = math.clamp(pitch, -70, 70)
	local root = char:FindFirstChild("HumanoidRootPart")
	local speed = 0
	if root then
		local v = root.AssemblyLinearVelocity
		speed = Vector3.new(v.X, 0, v.Z).Magnitude
	end
	local moveK = math.clamp(speed / 16, 0, 1)

	-- огнестрел: прицел, если игрок целится, недавно стрелял или идёт шагом
	local aimTarget = 1
	if def and (def.kind == "gun" or def.kind == "crossbow") then
		local aiming
		if isLocal then
			aiming = C and C.WeaponClient and C.WeaponClient.IsScoped() or false
		else
			aiming = char:GetAttribute("Aiming") == true
		end
		local recent = now - (rig.lastRecoil or -10) < 1.5
		aimTarget = (aiming or recent or speed < 17) and 1 or 0.2
	end
	rig.aimW = rig.aimW + (aimTarget - rig.aimW) * math.min(1, dt * 8)

	local hold = holdPose(def, weaponId, pitch, rig.aimW, now, moveK)
	if not hold and tool and tool:GetAttribute("ItemKind") == "item" then
		-- предмет в руке виден другим игрокам: поза по стилю удержания
		hold = withSway(HOLD_ITEM[tool:GetAttribute("HoldStyle")] or HOLD_ITEM.hand, now, moveK)
	end
	if hold then
		for joint, v in pairs(hold) do
			targets[joint] = v
		end
	end

	local anim = rig.anim
	if anim and (anim.hold or anim.name == "bow_draw") and (not def or def.kind ~= "bow") then
		-- натяжение прервано снятием лука, сменой оружия или падением — не держим позу вечно
		endAnim(rig)
		anim = nil
	end
	if anim and anim.hold and plr ~= localPlayer and now - anim.start > anim.duration + 6 then
		-- страховка для чужих игроков: отмена натяжения (окно/панель) не всегда доходит
		-- с сервера как bow_release — не держим позу бесконечно
		endAnim(rig)
		anim = nil
	end
	local noFold = false
	if anim then
		local t = anim.elapsed / anim.duration
		if t >= 1 and not anim.hold then
			endAnim(rig)
		else
			t = math.clamp(t, 0, 1)
			local spec = anim.spec
			noFold = spec.noFold == true
			local tEnd = spec.tEnd or 1
			local ctx = { pitch = pitch, now = now, anim = anim, def = Weapons.List[anim.weaponId], r6 = rig.r6 }
			local evalT = anim.hold and t or math.min(t, tEnd)
			local pose
			if spec.keys then
				pose = sample(spec.keys, evalT)
			else
				pose = spec.fn(evalT, ctx)
			end
			if spec.additive then
				for joint, v in pairs(pose) do
					local b = targets[joint]
					if b then
						targets[joint] = { b[1] + v[1], b[2] + v[2], b[3] + v[3], b[4] }
					else
						targets[joint] = v
					end
				end
			else
				if not anim.hold and t > tEnd and tEnd < 1 then
					pose = blendToHold(pose, hold, EASE.io((t - tEnd) / (1 - tEnd)))
				end
				for joint, v in pairs(pose) do
					targets[joint] = v
				end
			end
		end
	end

	-- голова компенсирует поворот корпуса
	local waist = targets.Waist
	if waist and not targets.Neck then
		targets.Neck = { -waist[1] * 0.35, -wrap180(waist[2]) * 0.55, -waist[3] * 0.4, waist[4] }
	end
	-- R6 без локтей и кистей: их сгиб частично переносится в плечо
	if rig.r6 and not noFold then
		local rs, re, rw = targets.RightShoulder, targets.RightElbow, targets.RightWrist
		if rs and (re or rw) then
			targets.RightShoulder = { rs[1] + (re and re[1] or 0) * 0.55 + (rw and rw[1] or 0) * 0.35, rs[2], rs[3], rs[4] }
		end
		local ls, le = targets.LeftShoulder, targets.LeftElbow
		if ls and le then
			targets.LeftShoulder = { ls[1] + le[1] * 0.55, ls[2], ls[3], ls[4] }
		end
	end
	-- ноги при ходьбе отдаём стандартной анимации
	if moveK > 0.15 then
		targets.RightHip = nil
		targets.LeftHip = nil
	end
	return targets
end

local function apply(rig, targets, dt, active, stopped)
	local rate = active and 40 or 16
	if stopped then
		rate = rate * 0.08
	end
	local k = 1 - math.exp(-rate * dt)
	for name, motor in pairs(rig.motors) do
		if motor.Parent then
			local target = targets and targets[name]
			if target and rig.r6 and name == "Waist" then
				-- R6: RootJoint несёт и ноги — только поворот, без наклона (иначе ноги отрываются от земли)
				target = { 0, target[2], 0, target[4] }
			end
			local w = rig.w[name] or 0
			local cur = rig.cur[name]
			local wantW = target and (target[4] or 1) or 0
			if target then
				if not cur or w < 0.02 then
					cur = { target[1], target[2], target[3] }
					rig.cur[name] = cur
				else
					cur[1] = cur[1] + (target[1] - cur[1]) * k
					-- поворот — по кратчайшей дуге
					cur[2] = cur[2] + wrap180(target[2] - cur[2]) * k
					cur[3] = cur[3] + (target[3] - cur[3]) * k
				end
			end
			if wantW > w then
				w = math.min(wantW, w + dt * 12)
			else
				w = math.max(wantW, w - dt * 8)
			end
			rig.w[name] = w
			if w > 0.01 and cur then
				local rot = CFrame.fromOrientation(math.rad(cur[1]), math.rad(cur[2]), math.rad(cur[3]))
				local transform = Util.JointTransform(rig.base[name], rot)
				if w >= 0.999 then
					motor.Transform = transform
				else
					motor.Transform = motor.Transform:Lerp(transform, w)
				end
			end
		end
	end
end

-- Свист удара в момент резкого движения
local function playSwoosh(rig)
	local def = Weapons.List[rig.swooshWeapon]
	local root = rig.char:FindFirstChild("HumanoidRootPart")
	if not def or not root or not (C and C.Effects) then
		return
	end
	C.Effects.Play(def.heavy and "swing_heavy" or "swing_light", root.Position, def.cooldown < 0.5 and 1.08 or nil)
end

-- Звуки действий у ДРУГИХ игроков: доля длительности анимации -> ключ звука (свои руки
-- озвучивает ViewModel в тех же кадрах). Прикрепление деталей озвучивает сервер (BusService).
local EMPTY = {}
local ANIM_SOUND = {
	throw_in = { 0.45, "furnace_load" },
	eat = { 0.25, "eat" },
	drink = { 0.3, "drink" },
	heal = { 0.15, "bandage" },
	inject = { 0.45, "inject" },
	place = { 0.4, "place" },
	throw = { 0.42, "throw" },
	bow_draw = { 0, "bow_draw" },
	bow_release = { 0, "bow_release" },
}
-- Перезарядка у других игроков: те же кадры, что в руках от первого лица
local RELOAD_SOUND = {
	pistol = { { 0.1, "pistol_mag_out" }, { 0.2, "pistol_mag_drop" }, { 0.64, "pistol_mag_in" }, { 0.82, "pistol_slide" } },
	revolver = { { 0.1, "revolver_open" }, { 0.3, "revolver_eject" }, { 0.66, "revolver_load" }, { 0.8, "revolver_close" } },
	shotgun = { { 0.12, "revolver_open" }, { 0.45, "shotgun_shell_in" }, { 0.62, "shotgun_shell_in" }, { 0.85, "shotgun_pump" } },
	rifle = { { 0.1, "rifle_mag_out" }, { 0.2, "pistol_mag_drop" }, { 0.62, "rifle_mag_in" }, { 0.8, "rifle_bolt" } },
	sniper = { { 0.1, "sniper_bolt" }, { 0.45, "shotgun_shell_in" }, { 0.85, "sniper_bolt" } },
	crossbow = { { 0.45, "crossbow_reload" } },
}

local function playAt(char, delay, key)
	task.delay(delay, function()
		local root = char.Parent and char:FindFirstChild("HumanoidRootPart")
		if root and C and C.Effects then
			C.Effects.Play(key, root.Position)
		end
	end)
end

function CharAnimator.Init(c)
	C = c
	Net.Get("PlayAnim").OnClientEvent:Connect(function(plr, name, weaponId, duration)
		if typeof(plr) ~= "Instance" or not plr:IsA("Player") or type(name) ~= "string" then
			return
		end
		if plr == localPlayer then
			-- подтверждённое сервером действие с предметом (печь, прикрепление, осмотр) — руки от
			-- первого лица; weaponId у предметов несёт id предмета (для звука и модели в руке)
			if C and C.ViewModel then
				C.ViewModel.Play(name, duration, { id = weaponId })
			end
			return
		end
		local char = plr.Character
		if not char then
			return
		end
		-- звуки действия у других игроков — в тех же кадрах, что и у себя
		local dur = (type(duration) == "number" and duration == duration) and math.clamp(duration, 0.1, 6) or 0.6
		if name == "reload" then
			for _, e in ipairs(RELOAD_SOUND[weaponId] or EMPTY) do
				playAt(char, e[1] * dur, e[2])
			end
		elseif name == "recoil" then
			local wdef = Weapons.List[weaponId]
			if wdef and wdef.boltCycle then
				playAt(char, 0.35, "sniper_bolt") -- перезарядка затвором после выстрела
			end
		else
			local s = ANIM_SOUND[name]
			if s then
				playAt(char, s[1] * dur, s[2])
			end
		end
		if name == "bow_draw" then
			CharAnimator.Play(char, name, weaponId, duration, true)
		else
			CharAnimator.Play(char, name, weaponId, duration)
		end
	end)

	RunService.Stepped:Connect(function(_, dt)
		local now = os.clock()
		local cam = workspace.CurrentCamera
		local camPos = cam and cam.CFrame.Position or Vector3.zero
		for _, plr in ipairs(Players:GetPlayers()) do
			local char = plr.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			local rig = char and rigs[char]
			if rig then
				-- след и свист удара обслуживаем даже вне дистанции анимации
				if rig.trail and now >= (rig.trailOffAt or 0) then
					if rig.trail.Parent then
						rig.trail.Enabled = false
					end
					rig.trail = nil
				end
				if rig.swooshAt and now >= rig.swooshAt then
					rig.swooshAt = nil
					if root and (root.Position - camPos).Magnitude < 150 then
						playSwoosh(rig)
					end
				end
			end
			if root and (plr == localPlayer or (root.Position - camPos).Magnitude < 250) then
				rig = getRig(char)
				if rig then
					local stopped = now < (rig.stopUntil or 0)
					local anim = rig.anim
					if anim then
						if now - anim.last > 0.25 then
							-- риг не обновлялся (был далеко): синхронизируем время
							anim.elapsed = now - anim.start
						else
							anim.elapsed = anim.elapsed + dt * (stopped and 0.06 or 1)
						end
						anim.last = now
					end
					local targets = computeTargets(plr, rig, now, dt)
					apply(rig, targets, dt, rig.anim ~= nil, stopped)
				end
			end
		end
		for char in pairs(rigs) do
			if not char.Parent then
				rigs[char] = nil
			end
		end
	end)
end

return CharAnimator
