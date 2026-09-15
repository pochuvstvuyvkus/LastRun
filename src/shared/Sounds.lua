-- Звуки игры (v5, агент AUDIO; контракт — docs/SPEC_v5.md 2.1).
-- Все ID проверены через apis.roblox.com/toolbox-service: только авторы ProSoundEffects (7462895450),
-- APMOfficial (7462718749) и Roblox (1) — такие записи играют в любой игре. В комментарии у каждой
-- записи — названия исходных звуков по порядку ids.
--
-- Формат записи Sounds.List[key]:
--   id = "rbxassetid://N"  или  ids = { "rbxassetid://N1", ... } (варианты; у записи всегда есть и id = ids[1])
--   volume     — базовая громкость (иерархия: выстрелы > удары > замахи > шаги > интерфейс)
--   pitch      = {lo, hi} — случайная PlaybackSpeed
--   region     = {a, b} — обрезка (сек), regions = {[i] = {a, b}} — обрезка отдельного варианта
--   looped     — луп; rolloff = {min, max} — затухание 3D (по умолчанию Sounds.DefaultRollOff = 8/120)
--   maxActive  — одновременно звучащих копий (SoundFX, по умолчанию 6); gap — защита от дублей (сек)
-- API: Sounds.Get(key), Sounds.Apply(sound, key[, variant]) -> ok, variant, Sounds.PickupKey(id[, kind]),
--      Sounds.PreloadList() — варианты для ContentProvider (частые первыми, без длинных лупов).
local Sounds = {}

local function id(n)
	return "rbxassetid://" .. n
end

Sounds.DefaultRollOff = { 8, 120 }

Sounds.List = {
	-- Интерфейс (2D) -----------------------------------------------------------------------------
	ui_click = { ids = { id(15675032796), id(15675059323) }, volume = 0.3, pitch = { 0.98, 1.03 } }, -- Roblox_UI_Small_Click / Roblox_UI_Bright_Click
	ui_hover = { ids = { id(10066931761), id(10066936758), id(10066942189) }, volume = 0.15, gap = 0.05 }, -- RBLX UI Hover 01 / RBLX UI Hover 02 / RBLX UI Hover 03
	ui_open_bag = { ids = { id(9113260699), id(9113260462) }, volume = 0.4, region = { 0, 0.9 } }, -- Bag Zipper From Nylon Bag Backpack Luggage 1 / Bag Zipper From Cloth School Bag 10
	ui_close_bag = { ids = { id(9113241598), id(9113242237) }, volume = 0.4, region = { 0, 0.7 } }, -- Backpack Movement 3 / Backpack Movement 13
	ui_move = { ids = { id(9113563366), id(9113563538), id(9113563536) }, volume = 0.3, pitch = { 0.95, 1.08 } }, -- Box Grab Department Store Type 18 / 19 / 20
	ui_error = { ids = { id(9119715399), id(9119715586), id(9119715581) }, volume = 0.35 }, -- Switch Blurt Single Short Synth Buzzes (3 вар.)

	-- Подбор и выбрасывание ------------------------------------------------------------------------
	pickup_generic = { ids = { id(9116194093), id(9116193837), id(9113562288), id(9113562414) }, volume = 0.5, pitch = { 0.94, 1.08 }, rolloff = { 4, 40 } }, -- Knife Grab / Knife Grab / Box Grab Department Store Type 1 / Box Grab Department Store Type 5
	pickup_metal = { ids = { id(9116633941), id(9116633667), id(9116634153) }, volume = 0.5, pitch = { 0.95, 1.08 }, region = { 0, 0.8 }, rolloff = { 4, 40 } }, -- Metal Grab Hollow Metal Impacts (3 вар.)
	pickup_wood = { ids = { id(9114775008), id(9114775311), id(9114560560), id(9114559968) }, volume = 0.5, pitch = { 0.95, 1.06 }, regions = { [3] = { 0, 0.6 }, [4] = { 0, 0.6 } }, rolloff = { 4, 40 } }, -- Hanger Wooded On Off / Hanger Wooded On Off / Gavel Movement Light Wood Impacts / Gavel Movement Light Wood Impacts
	pickup_food = { ids = { id(9125390932), id(9125390942), id(9125391072) }, volume = 0.45, pitch = { 0.95, 1.08 }, rolloff = { 4, 40 } }, -- Big Plastic Bag Grabs Hard Impacts Rustling 2 / 5 / 6
	pickup_glass = { ids = { id(9114610944), id(9114611299), id(9114611780) }, volume = 0.45, pitch = { 0.95, 1.08 }, rolloff = { 4, 40 } }, -- Glass Pot Set Down 13 / 16 / 22
	pickup_cloth = { ids = { id(9113843005), id(9113843192), id(9113817566) }, volume = 0.45, pitch = { 0.95, 1.06 }, region = { 0, 0.8 }, rolloff = { 4, 40 } }, -- Cloth Whump 1 / Cloth Whump 6 / Clothes Handling 2
	pickup_ammo = { ids = { id(9113577599), id(9113577601), id(9113577424) }, volume = 0.5, pitch = { 0.95, 1.06 }, region = { 0, 0.9 }, rolloff = { 4, 40 } }, -- Box Of Bullets 7 / Box Of Bullets 8 / Box Of Bullets 5
	pickup_weapon = { ids = { id(9114702107), id(9114702116), id(9114701864) }, volume = 0.55, pitch = { 0.96, 1.05 }, region = { 0, 1 }, rolloff = { 4, 40 } }, -- Gun Grab Hard 1 / Gun Grab Hard 2 / Gun From Holster 1
	pickup_fuel = { ids = { id(9120565787), id(9120565938), id(9120565620) }, volume = 0.5, pitch = { 0.95, 1.05 }, region = { 0, 0.9 }, rolloff = { 4, 40 } }, -- Watering Can Slosh Constant (3 вар.)
	pickup_stone = { ids = { id(9114768958), id(9114768231), id(9114768512) }, volume = 0.45, pitch = { 0.95, 1.08 }, region = { 0, 0.8 }, rolloff = { 4, 40 } }, -- Handling Stones (3 вар.)
	drop_item = { ids = { id(9114188704), id(9114188700), id(9114188909) }, volume = 0.5, pitch = { 0.95, 1.08 }, region = { 0, 0.9 }, rolloff = { 5, 50 } }, -- Drop Wallet 1 / Drop Wallet 2 / Drop Wallet 4

	-- Ближний бой ---------------------------------------------------------------------------------
	equip_melee = { ids = { id(9125681612), id(9125681561), id(9125681055) }, volume = 0.5, pitch = { 0.95, 1.08 }, region = { 0, 0.8 }, rolloff = { 4, 40 } }, -- Metal Pole Grabs Big Single Smacking Thunks (3 вар.)
	swing_light = { ids = { id(9113318173), id(9113318154), id(9113318347), id(9113318769) }, volume = 0.45, pitch = { 0.95, 1.12 }, rolloff = { 5, 60 }, gap = 0.02 }, -- Baseball Swish 1 / 2 / 4 / 10
	swing_heavy = { ids = { id(9120729339), id(9120729007), id(9114163342), id(9125495498) }, volume = 0.55, pitch = { 0.8, 0.92 }, rolloff = { 6, 70 }, gap = 0.02 }, -- Whoosh Heavy Punches 7 / Whoosh Heavy Punches / Dowel Swishes Thick Singles Many Versions 11 / Dowel Swish Bamboo Thick Midrange Leg Kicks 5
	hit_flesh = { ids = { id(9113510182), id(9116481223), id(9113483767), id(9116483969) }, volume = 0.7, pitch = { 0.93, 1.07 }, region = { 0, 0.8 }, rolloff = { 8, 120 } }, -- Body Hits Forceful 1 / Meat Chop Big Meaty Impacts 1 / Body Hit 1 / Meat Chop Big Meaty Impacts 2
	hit_wood = { ids = { id(9125573848), id(9125573849), id(9125574158), id(9113225734) }, volume = 0.65, pitch = { 0.92, 1.08 }, region = { 0, 0.8 }, rolloff = { 8, 120 } }, -- Gavel Hit Wood Mallet Hit Wood Single Impacts 2 / 1 / 4 / Axe Impact Giant Thuddy Hits On Wood Floor 2
	hit_metal = { ids = { id(9116712046), id(9116712265), id(9116766066), id(9116768251) }, volume = 0.6, pitch = { 0.94, 1.06 }, region = { 0, 1.1 }, rolloff = { 10, 150 } }, -- Metal Impact Small Claw Hammer 1 / 2 / Metal Pole Impact With Wrench 2 / 6
	hit_stone = { ids = { id(9113225186), id(9113225476), id(9113225486), id(9113964290) }, volume = 0.65, pitch = { 0.94, 1.06 }, region = { 0, 1 }, rolloff = { 8, 120 } }, -- Axe Impact Big Hits Against Concrete 1 / 3 / 5 / Cracky Punch 1
	hit_glass = { ids = { id(9113631722), id(9113631914), id(9113631898) }, volume = 0.55, pitch = { 0.95, 1.08 }, region = { 0, 1 }, rolloff = { 8, 120 } }, -- Bullet Glass 1 / 4 / 5
	hit_dirt = { ids = { id(9114109542), id(9114109550), id(9114112137), id(9114109952) }, volume = 0.6, pitch = { 0.92, 1.06 }, region = { 0, 0.9 }, rolloff = { 8, 120 } }, -- Dirt Impacts 3 / Dirt Impacts 4 / Dirt Impacts 3 / Dirt Impacts 2
	hit_bus = { ids = { id(9116773271), id(9116773464), id(9116774598), id(9116516462) }, volume = 0.7, pitch = { 0.92, 1.05 }, regions = { [4] = { 0, 1 } }, rolloff = { 10, 150 } }, -- Metal Pops Denting Car In Out 4 / 6 / 18 / Metal Auto Impacts 7

	-- Пистолет ----------------------------------------------------------------------------------------
	equip_gun = { ids = { id(9117396530), id(9117396574), id(9117396777) }, volume = 0.5, pitch = { 0.97, 1.05 }, rolloff = { 4, 40 } }, -- Pistol Handling 1 / 2 / 4
	pistol_shot = { ids = { id(9117396996), id(9117397176), id(9117397187), id(9117397321) }, volume = 0.85, pitch = { 0.96, 1.04 }, region = { 0, 1.6 }, rolloff = { 20, 450 }, maxActive = 5 }, -- Pistol Single Shots 1 / 2 / 3 / 4 (L.A.R. Grizzly .45)
	pistol_dry = { ids = { id(9119717529), id(9117279995) }, volume = 0.55, pitch = { 0.82, 0.92 }, regions = { [2] = { 0, 0.3 } }, rolloff = { 4, 40 } }, -- Switch Click On Or Off Toggle Button / Pen Clicks
	pistol_mag_out = { ids = { id(9113104509), id(9113104516) }, volume = 0.6, pitch = { 0.98, 1.06 }, region = { 0, 0.55 }, rolloff = { 5, 50 } }, -- Ammo Magazine 3 / Ammo Magazine 4
	pistol_mag_drop = { ids = { id(9116544317), id(9116544590), id(9116544969) }, volume = 0.5, pitch = { 0.95, 1.1 }, rolloff = { 5, 50 } }, -- Metal Click (3 вар.)
	pistol_mag_in = { ids = { id(9117396156), id(9117396164), id(9117396464) }, volume = 0.6, pitch = { 0.98, 1.05 }, regions = { [2] = { 0, 0.6 }, [3] = { 0, 0.6 } }, rolloff = { 5, 50 } }, -- Pistol Clip 2 / Pistol Clip 1 / Pistol Clip 3
	pistol_slide = { ids = { id(9116357348), id(9116357355) }, volume = 0.6, pitch = { 1.18, 1.3 }, region = { 0, 0.7 }, rolloff = { 5, 50 } }, -- Machine Gun Bolt 1 / Machine Gun Bolt 2

	-- Револьвер ---------------------------------------------------------------------------------------
	revolver_shot = { ids = { id(9118162153), id(9118162163), id(9118162224), id(9118162556) }, volume = 0.9, pitch = { 0.96, 1.03 }, region = { 0, 1.8 }, rolloff = { 22, 500 }, maxActive = 4 }, -- Revolver Standard Bullets 1 / 2 / 3 / 4 (S&W .38)
	revolver_open = { ids = { id(9114004190), id(9114004086) }, volume = 0.55, pitch = { 0.9, 1 }, rolloff = { 5, 50 } }, -- Crossbow Movement Latches 7 / Crossbow Movement Latches 5
	revolver_eject = { ids = { id(9113109832), id(9113106960), id(9113109795) }, volume = 0.55, pitch = { 0.95, 1.08 }, rolloff = { 5, 50 } }, -- Ammo Shell Drop (3 вар.)
	revolver_load = { ids = { id(9116543627), id(9116544091) }, volume = 0.45, pitch = { 1.1, 1.3 }, rolloff = { 5, 50 } }, -- Metal Click / Metal Click
	revolver_close = { ids = { id(9114004620), id(9114004622) }, volume = 0.6, pitch = { 1.05, 1.15 }, rolloff = { 5, 50 } }, -- Crossbow Movement Latches 17 / Crossbow Movement Latches 16

	-- Дробовик ----------------------------------------------------------------------------------------
	shotgun_shot = { ids = { id(9112912106), id(9112912844), id(9112912936) }, volume = 1, pitch = { 0.96, 1.03 }, region = { 0, 0.9 }, rolloff = { 25, 550 }, maxActive = 4 }, -- 12 Gauge Shotgun 1 / 12 Gauge Shotgun 301 / 12 Gauge Shotgun 101
	shotgun_shell_in = { ids = { id(9117396156), id(9117396464) }, volume = 0.55, pitch = { 0.78, 0.88 }, regions = { [2] = { 0, 0.5 } }, rolloff = { 5, 50 } }, -- Pistol Clip 2 / Pistol Clip 3
	shotgun_pump = { ids = { id(9112910709), id(9112910934), id(9112911339), id(9112912000) }, volume = 0.7, pitch = { 0.96, 1.04 }, rolloff = { 6, 70 } }, -- 12 Gauge Shotgun 2 / 12 Gauge Shotgun 5 / 12 Gauge Shotgun 11 / 12 Gauge Shotgun 6 (pump action)

	-- Автомат -----------------------------------------------------------------------------------------
	rifle_shot = { ids = { id(9114727865), id(9114727260), id(9114727096), id(9114727817) }, volume = 0.8, pitch = { 0.97, 1.04 }, region = { 0, 0.9 }, rolloff = { 20, 500 }, maxActive = 8, gap = 0.02 }, -- Gun Single Shots 28 / 13 / 10 / 27 (AK-47)
	rifle_mag_out = { ids = { id(9113104509), id(9113104516) }, volume = 0.6, pitch = { 0.82, 0.9 }, region = { 0, 0.6 }, rolloff = { 5, 50 } }, -- Ammo Magazine 3 / Ammo Magazine 4
	rifle_mag_in = { ids = { id(9117396164), id(9117396464) }, volume = 0.65, pitch = { 0.8, 0.88 }, region = { 0, 0.6 }, rolloff = { 5, 50 } }, -- Pistol Clip 1 / Pistol Clip 3
	rifle_bolt = { ids = { id(9116357383), id(9116357621) }, volume = 0.65, pitch = { 0.95, 1.05 }, region = { 0, 1.2 }, rolloff = { 6, 60 } }, -- Machine Gun Bolt 3 / Machine Gun Bolt 4

	-- Снайперская винтовка ------------------------------------------------------------------------------
	sniper_shot = { ids = { id(9118173739), id(9118173999), id(9118173988) }, volume = 1, pitch = { 0.97, 1.03 }, region = { 0, 2.2 }, rolloff = { 30, 900 }, maxActive = 3 }, -- Rifle Single Shots 1 / 2 / 3 (Barrett .50)
	sniper_bolt = { ids = { id(9113028155), id(9113027964), id(9113027892) }, volume = 0.65, pitch = { 0.96, 1.04 }, region = { 0, 1 }, rolloff = { 6, 60 } }, -- 470 Rifle 4 / 470 Rifle 3 / 470 Rifle 2

	-- Лук и арбалет -----------------------------------------------------------------------------------
	equip_bow = { ids = { id(9125405555), id(9125405557) }, volume = 0.4, pitch = { 1.05, 1.15 }, rolloff = { 4, 40 } }, -- Bow Stretches Wood Creaking Ripping Tearing (2 вар.)
	bow_draw = { ids = { id(9125405769), id(9125405992), id(9125406115), id(9125406197) }, volume = 0.5, pitch = { 0.95, 1.05 }, rolloff = { 6, 60 } }, -- Bow Stretches Wood Creaking Ripping Tearing (4 вар.)
	bow_release = { ids = { id(9114233723), id(9114233865), id(9114234062) }, volume = 0.6, pitch = { 0.7, 0.82 }, region = { 0, 0.6 }, rolloff = { 6, 80 } }, -- Elastic Band (3 вар.)
	arrow_fly = { ids = { id(9113166206), id(9113166218), id(9113166361) }, volume = 0.4, pitch = { 0.95, 1.1 }, rolloff = { 6, 70 } }, -- Arrow Out Whooshing Pass By 1 / 2 / 3
	arrow_hit_flesh = { ids = { id(9114487004), id(9114487361), id(9114487369), id(9114487427) }, volume = 0.65, pitch = { 0.92, 1.08 }, rolloff = { 8, 120 } }, -- Flesh Stab 5 / 10 / 11 / 12
	arrow_hit_wood = { ids = { id(9120893467), id(9120893758), id(9120809592), id(9120811299) }, volume = 0.6, pitch = { 0.9, 1.1 }, regions = { [4] = { 0, 0.7 } }, rolloff = { 8, 120 } }, -- Wood Hits Wood Lodge Pole / Wood Hits Wood Lodge Pole / Wood Chopping Exterior Single Hits / Wood Chopping Exterior Single Hits
	arrow_hit_ground = { ids = { id(9118768545), id(9118768535), id(9118767941) }, volume = 0.55, pitch = { 0.92, 1.08 }, region = { 0, 0.7 }, rolloff = { 8, 120 } }, -- Sand Impacts (3 вар.)
	crossbow_shot = { ids = { id(9114002954), id(9114002998), id(9114003068) }, volume = 0.75, pitch = { 0.95, 1.05 }, region = { 0, 1 }, rolloff = { 10, 150 } }, -- Crossbow Fire 1 / 2 / 3
	crossbow_reload = { ids = { id(9125479375), id(9125478990), id(9125479365) }, volume = 0.6, pitch = { 0.96, 1.04 }, rolloff = { 5, 50 } }, -- Crossbow Movement Slide For Pulling Bow Back 13 / 3 / 10

	-- Бросок, огонь, взрывы ---------------------------------------------------------------------------
	throw = { ids = { id(9113319324), id(9113319480), id(9113319483) }, volume = 0.5, pitch = { 0.9, 1.05 }, rolloff = { 5, 60 } }, -- Baseball Swish Fastball 2 / 3 / 5
	molotov_break = { ids = { id(9113850745), id(9114614607), id(9114590269) }, volume = 0.8, pitch = { 0.95, 1.05 }, region = { 0, 1.5 }, rolloff = { 12, 200 } }, -- Coke Glass Smash / Glass Smashes / Glass Break
	fire_ignite = { ids = { id(9125615451), id(9125616655), id(9125616715) }, volume = 0.7, pitch = { 0.92, 1.05 }, rolloff = { 10, 150 } }, -- Kerosene Explosion Whooshing Poofs Crackling (3 вар.)
	explosion = { ids = { id(9116973348), id(9116973611), id(9116973607), id(9114086657) }, volume = 1, pitch = { 0.92, 1.05 }, rolloff = { 40, 1000 }, maxActive = 4 }, -- Mortar Explosion / Mortar Explosion / Mortar Explosion / Dirt Explosion
	fire_loop = { id = id(9112780193), volume = 0.35, looped = true, rolloff = { 6, 60 } }, -- Fireplace Constant Burning Flame 1

	-- Использование предметов -------------------------------------------------------------------------
	eat = { ids = { id(9113138343), id(9113246944), id(9114224859) }, volume = 0.55, pitch = { 0.95, 1.06 }, regions = { [3] = { 0, 1.6 } }, rolloff = { 4, 40 } }, -- Apple Chew 1 / Bagel Bite 7 / Eating Chips 1
	drink = { ids = { id(9114171849), id(9114171855), id(9114171960), id(9114172114) }, volume = 0.55, pitch = { 0.95, 1.05 }, rolloff = { 4, 40 } }, -- Drinking Cu Gulping 1 / 2 / 5 / 7
	bandage = { ids = { id(9113834008), id(9113834096), id(9113834274) }, volume = 0.5, pitch = { 0.95, 1.08 }, rolloff = { 4, 40 } }, -- Cloth Rips Tears Fast Mostly Short 9 / 10 / 14
	inject = { ids = { id(9113046333), id(9113047026) }, volume = 0.35, pitch = { 1.1, 1.25 }, rolloff = { 4, 40 } }, -- Aerosol Spray Can / Aerosol Spray Can

	-- Тело: шаги, прыжок, приземление, лестница -------------------------------------------------------
	footstep_grass = { ids = { id(9120062559), id(9120062960), id(9120064187) }, volume = 0.45, pitch = { 0.95, 1.08 }, region = { 0, 0.5 }, rolloff = { 5, 60 }, maxActive = 8, gap = 0.06 }, -- Tip Toe Of Object Onto Grass (3 вар.)
	footstep_dirt = { ids = { id(9114657439), id(9114657434), id(9113316178) }, volume = 0.4, pitch = { 0.95, 1.1 }, region = { 0, 0.4 }, rolloff = { 5, 60 }, maxActive = 8, gap = 0.06 }, -- Gravel Hits 1 / Gravel Hits 2 / Baseball Shoe Stomp Base Bag
	footstep_wood = { ids = { id(9114788738), id(9114789004), id(9114788881) }, volume = 0.4, pitch = { 1, 1.15 }, region = { 0, 0.45 }, rolloff = { 5, 60 }, maxActive = 8, gap = 0.06 }, -- Head Impact Wood 1 / Head Impact Wood 1 / Head Impact Wood 4
	footstep_metal = { ids = { id(9116751108), id(9116750726), id(9113469244) }, volume = 0.3, pitch = { 1.05, 1.25 }, region = { 0, 0.45 }, rolloff = { 5, 60 }, maxActive = 8, gap = 0.06 }, -- Metal Plate Impact Manhole Hit / Metal Plate Impact Manhole Hit / Body Bump Hits On Metal
	footstep_concrete = { ids = { id(9114523161), id(9114523351), id(9114523345), id(9114523358) }, volume = 0.35, pitch = { 1.05, 1.25 }, region = { 0, 0.4 }, rolloff = { 5, 60 }, maxActive = 8, gap = 0.06 }, -- Foot Stomp 1 / 2 / 3 / 4
	footstep_snow = { ids = { id(9119310338), id(9119310356), id(9119310905), id(9119310903) }, volume = 0.4, pitch = { 0.95, 1.1 }, region = { 0, 0.45 }, rolloff = { 5, 60 }, maxActive = 8, gap = 0.06 }, -- Snowball Hits Lands Semi- Deep Snow (4 вар.)
	footstep_sand = { ids = { id(9118768256), id(9118768193), id(9118768199) }, volume = 0.35, pitch = { 1, 1.15 }, region = { 0, 0.35 }, rolloff = { 5, 60 }, maxActive = 8, gap = 0.06 }, -- Sand Impacts 4 / Sand Impacts / Sand Impacts
	jump = { ids = { id(9114890978), id(9114890995) }, volume = 0.3, pitch = { 0.95, 1.08 }, region = { 0, 0.6 }, rolloff = { 5, 60 } }, -- Jump Swish 1 / Jump Swish 2
	land = { ids = { id(9114523636), id(9114523612), id(9114523629), id(9113480917) }, volume = 0.5, pitch = { 0.85, 0.95 }, region = { 0, 0.6 }, rolloff = { 6, 70 } }, -- Foot Stomp 5 / 6 / 7 / Body Fall Thud 1
	ladder_climb = { ids = { id(9125793246), id(9125793284), id(9125794217) }, volume = 0.35, pitch = { 1, 1.15 }, region = { 0, 0.45 }, rolloff = { 5, 60 }, maxActive = 6, gap = 0.08 }, -- Rake Stepping On Cu Ringing Metallic Impacts (3 вар.)

	-- Автобус -----------------------------------------------------------------------------------------
	bus_attach_wood = { ids = { id(9114756156), id(9114756277), id(9114756497), id(9114755819) }, volume = 0.7, pitch = { 0.95, 1.05 }, region = { 0, 1.2 }, rolloff = { 10, 150 } }, -- Hammer Nail Into Wood 9 / 10 / 15 / 4
	bus_attach_metal = { ids = { id(9117712334), id(9117712414), id(9117712736) }, volume = 0.6, pitch = { 0.95, 1.05 }, rolloff = { 10, 150 } }, -- Pneumatic Rivet Gun On Off (3 вар.)
	wheel_attach = { ids = { id(9117703983), id(9117703975), id(9117704274) }, volume = 0.65, pitch = { 0.95, 1.05 }, rolloff = { 10, 150 } }, -- Pneumatic Impact Wrench Drill On Off (3 вар.)
	furnace_load = { ids = { id(9125426391), id(9125426396), id(9125426401), id(9119644956) }, volume = 0.65, pitch = { 0.92, 1.05 }, regions = { [4] = { 0, 1.2 } }, rolloff = { 8, 100 } }, -- Cast Iron Movements Cast Iron Fireplace Grate (3 вар.) / Stove Doors
	furnace_loop = { id = id(9112780561), volume = 0.35, looped = true, rolloff = { 6, 45 } }, -- Fire Whoosh (kerosene, loop)

	-- Старые ключи v3/v4 (используются Effects, CharAnimator, WeaponClient, ViewModel, BusService и др.) --
	equip = { id = id(9114704367), volume = 0.35, region = { 0, 0.7 }, rolloff = { 4, 40 } }, -- Gun Handling 2
	place = { id = id(9119606387), volume = 0.5, rolloff = { 6, 80 } }, -- Statue Put Down 9
	slash = { id = id(12222216), volume = 0.5, rolloff = { 6, 70 } }, -- swordslash.wav
	reload = { id = id(9117396530), volume = 0.5, rolloff = { 5, 50 } }, -- Pistol Handling 1
	empty_click = { id = id(9119717523), volume = 0.5, rolloff = { 4, 40 } }, -- Switch Click On Or Off Toggle Button
	zombie_groan = { id = id(9125470501), volume = 0.45, pitch = { 0.92, 1.06 }, rolloff = { 10, 150 } }, -- Creature Growls Lion Deep Guttural Rumbling
	zombie_attack = { id = id(9125476001), volume = 0.55, pitch = { 0.94, 1.06 }, rolloff = { 10, 150 } }, -- Creature Vocal Spider Growl Belch Hiss Snarl
	zombie_death = { id = id(9113987782), volume = 0.5, pitch = { 0.92, 1.05 }, rolloff = { 10, 150 } }, -- Creature Vocal Pterodactyl Death Shriek 1
	player_hurt = { ids = { id(9114030073), id(9114030411), id(9114029937), id(9116455235) }, volume = 0.45, pitch = { 0.95, 1.05 }, regions = { [4] = { 0, 1.2 } }, rolloff = { 5, 50 } }, -- Death Gasp Pained Gasps Short Inhales (3 вар.) / Male Screams In Pain Injury Yells Agony
	heartbeat = { id = id(9043365727), volume = 0.6, looped = true }, -- HEARTBEAT 01 96BPM
	bus_engine = { id = id(9112735339), volume = 0.3, looped = true, rolloff = { 14, 170 } }, -- 1982 Diesel Dump Truck 1
	bus_horn = { id = id(9114661198), volume = 0.8, rolloff = { 30, 600 } }, -- Greyhound Bus Horn Honks
	bus_brakes = { id = id(9114659843), volume = 0.6, rolloff = { 15, 300 } }, -- Greyhound Bus Air Brakes Hiss
	bus_door = { id = id(9114660515), volume = 0.6, rolloff = { 10, 150 } }, -- Greyhound Bus Door Open Close
	crash = { id = id(9118708982), volume = 0.8, region = { 0, 1.8 }, rolloff = { 20, 400 } }, -- Ronking Car Crash 1
	glass_break = { id = id(9113850618), volume = 0.6, rolloff = { 10, 200 } }, -- Coke Glass Smash 1
	wood_break = { id = id(9120802004), volume = 0.6, rolloff = { 10, 200 } }, -- Wood Break 1
	metal_gate = { id = id(9116604303), volume = 0.6, rolloff = { 10, 200 } }, -- Metal Door Creak 2
	alarm = { id = id(9119161877), volume = 0.6, region = { 0, 2 }, rolloff = { 15, 300 } }, -- Siren Blat 4
	thunder = { id = id(12222030), volume = 0.7, rolloff = { 50, 2000 } }, -- HalloweenThunder.wav
	ambience_wind = { id = id(9114057104), volume = 0.22, looped = true }, -- Desert Wind Whistley Light Gusts 1
	ambience_eerie = { id = id(9112775175), volume = 0.2, looped = true }, -- Eerie Ambience 1
	ambience_night = { id = id(9112762653), volume = 0.22, looped = true }, -- Crickets And Cicadas 4
	ambience_rain = { id = id(9112853287), volume = 0.28, looped = true }, -- Rain Heavy 1
	cash = { id = id(9113728042), volume = 0.5, rolloff = { 5, 50 } }, -- Cash Register 1
	level_up = { id = id(12222253), volume = 0.6 }, -- victory.wav
	attach = { id = id(9116541004), volume = 0.55, rolloff = { 10, 150 } }, -- Metal Clang 17
}

-- Старые ключи, которые теперь звучат как новые (та же таблица записи)
local ALIASES = {
	swing = "swing_light",
	pickup = "pickup_generic", -- вместо синтетического «дзынь» — захват предмета рукой
	shot_pistol = "revolver_shot",
	shot_shotgun = "shotgun_shot",
	shot_rifle = "rifle_shot",
	shot_sniper = "sniper_shot",
	arrow_hit = "arrow_hit_wood",
}
for alias, target in pairs(ALIASES) do
	if Sounds.List[alias] == nil then
		Sounds.List[alias] = Sounds.List[target]
	end
end

-- У каждой записи есть и ids (варианты), и id (первый вариант) — старый код читает def.id
for _, s in pairs(Sounds.List) do
	if s.ids == nil then
		s.ids = { s.id or "" }
	elseif s.id == nil then
		s.id = s.ids[1] or ""
	end
end

local rng = Random.new()
local lastVariant = {}

function Sounds.Get(key)
	local s = Sounds.List[key]
	if s and s.id ~= "" then
		return s
	end
	return nil
end

-- Применить запись к объекту Sound: случайный вариант (без повтора подряд при 3+ вариантах),
-- громкость, высота из pitch, обрезка, луп, затухание. variant — номер варианта (необязательно).
function Sounds.Apply(sound, key, variant)
	local s = Sounds.Get(key)
	if not s then
		return false
	end
	local ids = s.ids
	local n = #ids
	local i = tonumber(variant)
	if not i or i < 1 or i > n then
		if n <= 1 then
			i = 1
		else
			i = rng:NextInteger(1, n)
			if n >= 3 and i == lastVariant[key] then
				i = i % n + 1
			end
		end
	end
	i = math.floor(i)
	lastVariant[key] = i
	sound.SoundId = ids[i]
	sound.Volume = (s.volume or 0.5) * (s.gains and s.gains[i] or 1)
	sound.Looped = s.looped == true
	local region = (s.regions and s.regions[i]) or s.region
	if region then
		sound.PlaybackRegionsEnabled = true
		sound.PlaybackRegion = NumberRange.new(region[1], region[2])
		if s.looped then
			sound.LoopRegion = NumberRange.new(region[1], region[2])
		end
	else
		sound.PlaybackRegionsEnabled = false
	end
	local pitch = s.pitch
	sound.PlaybackSpeed = pitch and rng:NextNumber(pitch[1], pitch[2]) or 1
	local roll = s.rolloff or Sounds.DefaultRollOff
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = roll[1]
	sound.RollOffMaxDistance = roll[2]
	return true, i
end

-- Подбор: какой pickup_* звучит для предмета (shared/Items) или оружия (shared/Weapons).
-- Поле pickupSound у записи предмета/оружия (если появится) важнее таблиц ниже.
local ITEM_SOUND = {
	coal = "pickup_stone", meteorite = "pickup_stone", amber = "pickup_stone", jade_idol = "pickup_stone",
	canned_food = "pickup_metal", energy_drink = "pickup_metal", coffee = "pickup_metal",
	chips = "pickup_food", water = "pickup_food", herbal_tea = "pickup_glass",
	bandage = "pickup_cloth", medkit = "pickup_generic", adrenaline = "pickup_generic",
	arrow = "pickup_wood", bolt = "pickup_ammo", molotov = "pickup_glass", bottle = "pickup_glass",
	scrap = "pickup_metal", spring = "pickup_metal", pipe = "pickup_metal", planks = "pickup_wood",
	cloth = "pickup_cloth", rope = "pickup_cloth", herbs = "pickup_cloth", gunpowder = "pickup_cloth",
	tape = "pickup_generic", battery = "pickup_generic", circuit = "pickup_generic",
	repair_kit = "pickup_metal", lantern = "pickup_metal", barricade = "pickup_wood", trap = "pickup_metal",
	bus_wheel = "pickup_generic", plate_wood = "pickup_wood", plate_metal = "pickup_metal", bus_lamp = "pickup_glass",
	bunk = "pickup_cloth", alarm_box = "pickup_metal", cache_key = "pickup_metal",
	old_coin = "pickup_metal", watch = "pickup_metal", camera = "pickup_generic", silver_bar = "pickup_metal",
	gold_bar = "pickup_metal", skull_ring = "pickup_metal", orchid = "pickup_cloth", wolf_pelt = "pickup_cloth",
}
local CATEGORY_SOUND = {
	fuel = "pickup_fuel", food = "pickup_food", medical = "pickup_cloth", ammo = "pickup_ammo",
	throwable = "pickup_glass", material = "pickup_generic", tool = "pickup_metal", placeable = "pickup_wood",
	quest = "pickup_metal", buspart = "pickup_metal", valuable = "pickup_generic",
}
local MATERIAL_SOUND = {
	Metal = "pickup_metal", CorrodedMetal = "pickup_metal", DiamondPlate = "pickup_metal", Foil = "pickup_metal",
	Glass = "pickup_glass", Neon = "pickup_glass", Fabric = "pickup_cloth", Wood = "pickup_wood", WoodPlanks = "pickup_wood",
}
local WEAPON_SOUND = { bat = "pickup_wood", bow = "pickup_wood", molotov = "pickup_glass" }
local WEAPON_KIND_SOUND = {
	gun = "pickup_weapon", crossbow = "pickup_weapon", bow = "pickup_wood", melee = "pickup_metal", throw = "pickup_glass",
}

local modules = {}
local function sharedModule(name)
	if modules[name] == nil then
		local ok, mod = pcall(function()
			return require(script.Parent:FindFirstChild(name))
		end)
		modules[name] = (ok and type(mod) == "table") and mod or false
	end
	return modules[name] or nil
end

-- id — id предмета или оружия; kind — "item"/"weapon" (необязательно, если id совпадают)
function Sounds.PickupKey(itemOrWeaponId, kind)
	local key
	if type(itemOrWeaponId) == "string" then
		local items = kind ~= "weapon" and sharedModule("Items") or nil
		local weapons = kind ~= "item" and sharedModule("Weapons") or nil
		local item = items and items.List and items.List[itemOrWeaponId]
		local weapon = weapons and weapons.List and weapons.List[itemOrWeaponId]
		if item then
			key = item.pickupSound or ITEM_SOUND[itemOrWeaponId]
				or (typeof(item.material) == "EnumItem" and MATERIAL_SOUND[item.material.Name])
				or CATEGORY_SOUND[item.cat]
		elseif weapon then
			key = weapon.pickupSound or WEAPON_SOUND[itemOrWeaponId] or WEAPON_KIND_SOUND[weapon.kind]
		end
	end
	if type(key) == "string" and Sounds.Get(key) then
		return key
	end
	return "pickup_generic"
end

-- Варианты для прогрева (ContentProvider): частые звуки первыми, длинные лупы не грузим заранее
local PRELOAD_FIRST = { "footstep_", "ui_", "swing", "hit_", "pickup", "equip", "pistol_", "jump", "land", "bow_", "arrow_", "drop_" }
function Sounds.PreloadList()
	local first, rest, seen = {}, {}, {}
	for key, s in pairs(Sounds.List) do
		if not s.looped then
			local early = false
			for _, prefix in ipairs(PRELOAD_FIRST) do
				if string.sub(key, 1, #prefix) == prefix then
					early = true
					break
				end
			end
			for _, sid in ipairs(s.ids) do
				if sid ~= "" and not seen[sid] then
					seen[sid] = true
					table.insert(early and first or rest, sid)
				end
			end
		end
	end
	for _, sid in ipairs(rest) do
		table.insert(first, sid)
	end
	return first
end

return Sounds
