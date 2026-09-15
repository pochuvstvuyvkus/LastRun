# «Последний рейс» — спецификация v2 (контракты для параллельной разработки)

Проект: Roblox-игра на Luau. Исходники в `src/`, сборка `python3 build.py` → `build/LastRun.rbxlx`.
Проверки (обязательны перед сдачей):
- `python3 tools/luacheck.py src` — синтаксис + неопределённые глобалы (0 ошибок, 0 предупреждений)
- `python3 tools/xref.py` — все `S.X.Y` / `C.X.Y` / `Alias.Y` из shared-модулей существуют, все `Net.Get("...")` есть в `Net.Events`
- `python3 build.py --out /tmp/x.rbxlx --no-project` (не перезаписывать build/ во время параллельной работы)

Код в Studio запустить нельзя — пишите предельно аккуратно: проверяйте имена свойств Roblox API, порядок аргументов, nil-случаи.

## 0. Общие правила

- Язык интерфейса и комментариев — русский. Luau без аннотаций типов. `task.wait/task.delay/task.spawn`, не `wait/spawn/delay`.
- Никаких внешних ассетов (rbxassetid). Можно встроенные `rbxasset://...`.
- **Редактируйте только свои файлы** (таблица владельцев ниже). Если нужен код в чужом файле — опишите в отчёте в разделе `REQUESTS` (что и зачем). Файлы архитектора (`src/shared/Config.lua, Items.lua, Net.lua, BusTypes.lua, Upgrades.lua, Recipes.lua, Progression.lua, Difficulty.lua, Objectives.lua`, `src/server/Main.server.lua, PlayerData.lua`, `src/client/Main.client.lua`) — только читать.
- Реестры: сервер `S` (ключи см. `Main.server.lua`: Obstacles, Profile, PlayerData, Combat, Projectiles, Weapons, Loot, Workbench, Zombies, Sleep, DayNight, Bus, Props, World, Stations, Objectives, Events, Shop, Lobby, Run). Клиент `C` (UI, Effects, CharAnimator, ZombieAnim, HUD, Panels, ProgressUI, Minimap, ObjectivesUI, EventsUI, WorkbenchUI, LobbyUI, WeaponClient, BusClient, SleepClient; плюс `C.State.Inventory`, `C.State.WeaponOrder`, `C.State.WeaponLevels`).
- Каждый сервис: `Init(S)` (без yield), опционально `Update(dt)` (вызывается каждый Heartbeat, ошибки перехватываются; сами дросселируйте частоту). Модули-заглушки уже лежат на своих местах с минимальным API — замените их полностью, сохранив контракт.
- Сервисы, вызываемые чужим кодом до своего Init/в лобби, должны терпеть отсутствие автобуса/дороги (`S.Bus.Root == nil`, `S.World.Road == nil`).
- Производительность: не создавайте Instance каждый кадр; тяжёлые циклы — 2–10 Гц.

## 1. Владельцы файлов

| Агент | Файлы (владение) |
|---|---|
| **A · Автобус** | `server/BusService.lua`, `client/BusClient.lua`, `client/HUD.lua` |
| **B · Мир, границы, миникарта** | `server/WorldGen.lua`, `server/Props.lua`, `server/Obstacles.lua`, `client/Minimap.lua` |
| **C · Враги и события** | `server/ZombieService.lua`, `shared/Zombies.lua`, `server/EventService.lua`, `shared/Events.lua` (новый), `client/EventsUI.lua`, `client/ZombieAnim.lua`, `server/DayNight.lua`, `shared/WeaponModels.lua` |
| **D · Цели и станции** | `server/ObjectiveService.lua`, `client/ObjectivesUI.lua`, `server/StationService.lua` |
| **E · Профиль и прогрессия** | `server/ProfileService.lua`, `client/ProgressUI.lua` |
| **F · Верстак, оружие, обмен, магазин** | `server/WorkbenchService.lua`, `client/WorkbenchUI.lua`, `server/WeaponService.lua`, `server/LootService.lua`, `server/ShopService.lua`, `client/Panels.lua`, `client/WeaponClient.lua` |
| **G · Лобби, группы, мультисервер** | `server/LobbyService.lua`, `client/LobbyUI.lua`, `server/RunManager.lua` |
| **H · Исправления и эффекты** | `server/CombatService.lua`, `server/ProjectileService.lua`, `server/SleepService.lua`, `client/CharAnimator.lua`, `client/Effects.lua`, `client/UI.lua`, `client/SleepClient.lua`, `shared/Util.lua`, `shared/RoadPath.lua`, `shared/Biomes.lua`, `shared/Classes.lua`, `shared/StatusEffects.lua` |

## 2. Базовые соглашения (уже в коде)

- Дорога: `S.World.Road` (`shared/RoadPath.lua`): `Frame(s) -> pos, tangent, right, heading`, `ToWorld(s, d, y)`, `CFrameAt(s, d, y, headingOffset)`, `Project(pos, hintS, window) -> s, d`. `s` — путь вдоль дороги, `d` — вправо. Земля y=0, дорога чуть выше. 1 км = `Config.StudsPerKm` (200).
- Препятствия для автобуса: `S.Obstacles.AddCircle(chunkId, x, z, r, opts)`, `AddBox(chunkId, cf, halfX, halfZ, opts)`, `Query(x,z,r)`, `Hits(ob,x,z,pad)`, `IsBlocked(x,z,pad)`, `Remove(ob)`, `ClearChunk(id)`, `Clear()`. opts: `hard`, `model`, `gate`, `gateText`, `zone` (+`slow`), `damageMult`, `kind`.
- Группы столкновений: `Bus`(не сталкивается с `World`, `Debris`), `World`, `Zombies`(не друг с другом), `Debris`(только с World).
- Папки workspace: `World` (чанки, депо), `Zombies`, `Loot`, `Effects`. Новые папки: `Objectives` (D), `Lobby` (G), `Placeables` (F), `EventsFX` (C).
- Состояние игры — атрибуты на `Net.State()` (ReplicatedStorage.GameState). Существующие: RunState, RunTime, TeamKills, TotalKm, Seed, Weather, IsNight, BiomeId, BiomeName, BusHP, BusMaxHP, Fuel, FuelMax, Speed, Km, OffRoad, Deviation, SteerAngle, Upgrades, DriverName, NextStationKm, NextStationName, Objective, ObjectiveCount, BossActive, BossName, BossHP, BossMaxHP.
  **Новые:** `Mode` ("lobby"|"run", G), `Difficulty` (id, G), `DifficultyName` (G), `ThreatLevel` (число, C), `BusType` (id, A), `BusDistToRoad` (studs, A), `EventId`/`EventTitle`/`EventEnd` (C, EventEnd — server time), `BloodMoon` (bool, C).
  **Формат `Upgrades` меняется (A):** строка `"armor:2,ram:1,autoturret:3"`.
- Атрибуты игрока (Player): Money, ClassId, Downed, DownedUntil, Kills, Hunger, Energy, Sleeping, SleepThreat, SleepAlarm, UseEnd, UseName, Eff_<id>. **Новые (E):** `Level`, `XP`, `XPNext`, `Tickets`. **(F):** `LanternUntil`.
- Атрибуты Tool (F): `WeaponId`, `Kind`, `Mag`, `MaxMag` (новый), `Level` (новый), `Reloading`, `ReloadEnd`, `Count`. Имя инструмента: `"Катана +2"` при уровне > 0.
- Разметка экрана (IgnoreGuiInset=true):
  - верх-центр: маршрут (HUD), строка цели и полоса босса (HUD), баннер события — под ними, y≈165 (EventsUI)
  - верх-право: миникарта 220×220, right 14, top 8 (Minimap); под ней трекер целей, right 14, top 240, ширина 270, высота ≤ 240 (ObjectivesUI)
  - низ-право: панель оружия (HUD, как сейчас); **панель автобуса переносится над ней** (HUD)
  - низ-лево: панель игрока (HUD, как сейчас); **полоска уровня/опыта/билетов** сразу над ней: Position `UDim2.new(0,14,1,-198)`, Size 310×28 (ProgressUI); подсказки управления HUD поднимает выше (top ≈ `1,-420`)
  - центр: модальные окна (Panels, WorkbenchUI, LobbyUI, окно ежедневной награды ProgressUI) — все окна регистрируются через `C.Panels.RegisterWindow(isOpenFn, closeFn)`, чтобы боевая камера отпускала мышь
  - Все фиксированные панели должны масштабироваться `UIScale` = clamp(min(vp.X/1280, vp.Y/720), 0.55, 1).

## 3. Контракты сервисов

### 3.1 BusService (A)
Автобус теперь **ездит свободно по всей карте** (не только по дороге), как машина: положение XZ + курс + скорость. Дорога даёт лёгкий автовыравнивающий «ассист», только когда автобус на дороге и руль отпущен.
- `Bus.Build(startS, busTypeId)` — модель по `BusTypes.Get(id)` (длина/ширина/цвет/этажи). Обязательно: `DriverSeat` (Seat, CanTouch=false, подсказка «Сесть за руль»), койки (`beds` + доп. из апгрейда `bunks`) через `S.Sleep.RegisterBed(part,"bus",standOffset)`, топливный бак (подсказка «Залить топливо»), ящик ремонта, **верстак** (`S.Workbench.RegisterBench(part, "bus")`), дверь с пандусом, лестница на крышу (TrussPart, размеры кратны 2), крыша с поручнями; у `decks = 2` второй этаж с лестницей. Точки крепления вооружения. Модель названа `Bus`, корень `BusRoot`.
- Физика: как сейчас — корень unanchored + жёсткие AlignPosition/AlignOrientation (OneAttachment), цель задаётся каждый кадр.
- Руление: `yawRate = steer * turnRate * clamp(|v|/12,0,1) * sign(v) * gripFactor`. Ассист дороги (|d| ≤ RoadHalfWidth+2 и steer==0): плавно доворачивать курс к касательной дороги.
- `Bus.S`, `Bus.D` — проекция позиции на дорогу (`S.World.Road:Project(pos, Bus.S, 400)`), обновлять ≥10 Гц. Остальные системы опираются на них (генерация, биом, станции, км).
- Границы: не выпускать автобус за `S.World.IsInsideBounds(pos, Bus.S)` (вернуть назад, погасить скорость). Граничные стены B регистрирует как hard-препятствия.
- Бездорожье: множитель скорости `min(1.05, biome.offroadSpeed * type.offroadMult + wheelsOffroadBonus)`; зоны (`ob.zone`) замедляют; при HP≤0 — 30% скорости; без топлива — без газа.
- Столкновения: точки контура из размеров типа; **не зависать** (см. ревизия №3: откатывать поворот, если он вызвал пересечение; если уже внутри — дать выехать).
- Вооружение/улучшения — уровни из `shared/Upgrades.lua` (значения через `Upgrades.Value(id,key,level,default)`):
  - armor (MaxHP, crashMult), ram (ramMult, selfDamageMult, sawDps), engine (speedMult, accelMult), tank (fuelBonus, fuelEff), wheels (gripBonus, offroadBonus)
  - autoturret (damage, interval, range, count — отдельные турели на крыше), **mg_turret** — управляемая башня: сиденье `TurretSeat` на крыше; сидящий шлёт `TurretInput(aimPoint: Vector3, firing: bool)` ~15 Гц; сервер стреляет хитсканом (урон, interval, перегрев heatPerShot/coolRate), трассеры всем (`Tracer` с weaponId `"mg_turret"`), шлёт сидящему `TurretState({active, heat, overheated})`; убийства засчитываются стрелку
  - flamethrower (конус спереди, dps, поджог `z.burnUntil`), tesla (цепная молния: `Tracer` weaponId `"tesla"`), mortar (дуга `S.Projectiles.Fire{kind="shell"}` + `S.Combat.Explode` при попадании, цель — скопление зомби)
  - alarm, lights (slow по уровню), bunks (доп. койки)
- **API:** `Bus.Type` (id), `Bus.TypeDef`, `Bus.Position` (Vector3), `Bus.Heading` (рад), `Bus.GetLevel(id) -> n`, `Bus.HasUpgrade(id) -> level>0`, `Bus.ApplyUpgrade(id) -> ok, message` (только повышает уровень и применяет эффект; **оплату проверяет вызывающий**), плюс существующие: `S, D, V, HP, MaxHP, Fuel, FuelMax, Model, Root, Driver, IsInside(pos), IsNear(player,r), IsNearTank(player), InHeadlights(pos), GetSpawnCFrame(i), Damage(amount, info), Repair(amount), RepairWith(player), RefuelWith(player,itemId), PublishState(), Destroy(), Update(dt)`.
- Атрибуты: BusHP, BusMaxHP, Fuel, FuelMax, Speed, Km, OffRoad, DriverName, Upgrades (новый формат), BusType, BusDistToRoad.
- Сетевое владение: после выхода из сиденья вернуть владение персонажем игроку (ревизия №2).
- SpotLight.Range ≤ 60.
- **HUD (A):** панель автобуса — прочность, топливо, скорость, «до дороги N м», компас курса, тип автобуса; перенести над панелью оружия; прицел/полоса перегрева для башни (когда игрок в `TurretSeat`); в лобби (`Mode=="lobby"`) скрывать заездный HUD (маршрут, автобус, цели); UIScale; исправления ревизии клиента (№7, 8, 10, 13, 15, 16).
- **BusClient (A):** вождение (как сейчас) + управление башней: в `TurretSeat` — LockCenter мыши, прицел по центру экрана, отправка `TurretInput`, приём `TurretState`.

### 3.2 WorldGen / Props / Obstacles / Minimap (B)
- **Границы:** коридор `|d| ≤ Config.Bounds.HalfWidth`, `s ∈ [Config.Bounds.BackS, FinalS + Config.Bounds.FrontExtra]`.
  - Визуальные стены по биому на `d = ±(HalfWidth .. HalfWidth+WallThickness)` в каждом чанке (скалы/каньон в пустыне, стена многоэтажек в городе, непроходимая чаща в джунглях, глубокая топь с туманом в болоте, горный хребет на снегу, военный забор в пустоши). CanCollide=true, высота ≥ 60, группа World → блокируют игроков и зомби. Сегменты с запасом по длине, чтобы не было щелей на изгибах.
  - Для автобуса — hard `AddBox` вдоль стен. Стена позади депо и за конечной.
  - `World.IsInsideBounds(pos, hintS) -> inside, s, d`, `World.ClampToBounds(pos, hintS) -> Vector3`.
  - Страховка в `World.Update` (1 Гц): игрок/зомби за `Config.Bounds.PlayerLimit`, за торцами или ниже y=-40 → игрока вернуть на ближайшую точку внутри (на землю), зомби удалить (`S.Zombies.Remove(z)`); уведомить игрока «Дальше не пройти».
- **Свободная езда:** автобус может заехать куда угодно внутри границ, но не беспрепятственно. Зарегистрировать как препятствия ВСЕ твёрдые объекты внутри границ (снять ограничение |d|<92). Добавить по биомам препятствия вне дороги с проездами: гряды скал/каньоны, кварталы с улицами, густой лес с просеками, топкие озёра (zone slow ≤0.45) и мёртвый лес, ледяные озёра и каменные стены, воронки и заборы. Не создавать полностью замкнутых областей. Часть зданий ставить дальше от дороги (до |d| ≈ 250).
- Ревизия сервера: №1 (город блокирует проезд), №7 (таблички депо), №8 (память чанков), №9 (зомби храма в полу), №11 (крыша гаража/арка выше двухэтажного автобуса: ≥ 26).
- **Резервирование мест целей:** `World.ReserveArea(s, d, radius)` — Props не ставит здания/крупные объекты в этих кругах. Вызывается D до генерации чанков.
- **Память чанков (против фарма):** `World.IsLootTaken(key)`, `World.MarkLootTaken(key)`, `World.IsSpawnerUsed(key)`, `World.MarkSpawnerUsed(key)`. Props передаёт стабильные ключи: `S.Loot.SpawnFromTable(table, spots, rng, parent, keyPrefix)`, `S.Loot.SpawnSafe(cf, parent, rng, key)`, `S.Zombies.AddSpawner(chunkId, pos, count, biome, key)`.
- При выгрузке чанка вызывать `S.Stations.OnChunkUnloaded(ci)` (D пересоберёт станцию при возврате).
- Депо: верстак `S.Workbench.RegisterBench(part, "depot")`.
- `World.NewRun(seed)`, `World.Clear()` сбрасывают резервы и память.
- **Minimap (клиент):** правый верх 220×220, север вверх, масштаб ≈ 700 studs по стороне; дорога (строится `RoadPath.new(seed, FinalS+800, straightPoints)` с сидом из атрибута `Seed`, так же как на сервере: straightPoints = станции из Config + FinalS), границы, автобус (`workspace.Bus.BusRoot`, стрелка курса), игроки, станции, маркеры `C.ObjectivesUI.GetMarkers()` и `C.EventsUI.GetMarkers()` (если модули есть). Клавиша **M** — большая карта всего маршрута. Скрыта в лобби. UIScale.

### 3.3 ZombieService / Zombies / EventService / Events / EventsUI / ZombieAnim / DayNight / WeaponModels (C)
- **Сложность:** `Difficulty.Scale(S.Run.Difficulty or "normal", S.Profile.TeamLevel(), km)` → hp, damage, count (множитель желаемого числа зомби и орд станций через `ZS.CountMult()`), reward. Атрибут `ThreatLevel`.
- Награда за убийство: деньги `reward * scale.reward`, опыт `S.Profile.AddXP(killer, def.reward * Progression.XP.killPerReward, "kill")` (элита — `Progression.XP.elite`, босс — `Progression.XP.boss` всем игрокам).
- **Новые типы** в `shared/Zombies.lua`: элита `sand_giant`, `riot_brute`, `jungle_giant`, `swamp_hag`, `yeti`, `mutant` (у каждой своя способность: бросок валуна, щит спереди, призыв ползунов, ядовитое облако, замедляющий рёв, рывок и т.п.; флаг `elite=true`), `nest` (неподвижное гнездо, много HP, раз в N секунд рождает бегунов/ходячих со своим tag, `stationary=true`), `raider` (мародёр-человек: держит дистанцию, стреляет быстрыми снарядами `kind="bullet"`, флаг `human=true`).
- `Zombies.Spawn(typeId, pos, opts)`, opts: `biome, home, aggro, tag, hpMult, elite, onDeath(z, info), noDespawn`. Элита при смерти роняет `S.Loot.SpawnFromTable("elite", ...)`.
- `Zombies.Remove(z)`, `Zombies.List()`, `Zombies.Active`, `Zombies.CountTag(tag)`, `Zombies.Alert(pos, r)`, `Zombies.Knockback`, `Zombies.Stun`, `Zombies.ClearAll()`, `Zombies.AddSpawner(chunkId, pos, count, biome, key)` (учёт `S.World.IsSpawnerUsed/MarkSpawnerUsed`), `Zombies.ClearChunk(id)`, `Zombies.CountMult()`.
- **Дополнительные цели:** `Zombies.AddTarget(entity)`, `Zombies.RemoveTarget(entity)`; entity = `{root = BasePart, radius = number, priority = number?, onDamage = function(amount, z)}` — зомби могут атаковать выживших (D) и обороняемые объекты (D).
- **Укрепления:** если зомби застрял или рядом `S.Workbench.FindPlaceableNear(pos, 5)` → бить её (`placeable.Damage(amount)`).
- Спавн миньонов босса — с проверкой `IsBlocked` и не внутри автобуса (ревизия №9).
- **EventService:** события раз в `Config.Events.MinGapKm..MaxGapKm` км после `StartKm`: `airdrop` (самолёт пролетает, ящик на парашюте падает в стороне от дороги, внутри таблица `airdrop`, зомби сбегаются), `blood_moon` (только ночью: зомби быстрее и больше, награды ×2, красная атмосфера через DayNight), `horde_chase` (орда догоняет сзади), `merchant` (фургон торговца у дороги на 2 мин — `S.Stations.RegisterTrader(part, {name, kind="merchant"})`, убрать по окончании), `raiders` (засада мародёров с баррикадой на дороге), `meteor_shower` (метеориты с предупреждающими кругами, `S.Combat.Explode`, осколки `meteor`). Баннер `EventBanner`, атрибуты `EventId/EventTitle/EventEnd/BloodMoon`, опыт участникам. API: `Events.NewRun(seed)`, `Events.Update(dt)`, `Events.Clear()`, `Events.IsBloodMoon()`.
- **DayNight:** красная атмосфера кровавой луны; в режиме `nightmare` — темнее ночи.
- **WeaponModels.MakeProjectile:** добавить виды `"bullet"` (маленький жёлтый неон), `"shell"` (тёмный шар).
- **EventsUI:** баннер (заголовок, текст, таймер) под полосой босса; `EventsUI.GetMarkers()`.
- **ZombieAnim:** позы для новых типов (гнездо пульсирует, мародёр держит «оружие», элита с особыми атаками).

### 3.4 ObjectiveService / ObjectivesUI / StationService (D)
- `Objectives.NewRun(seed)`: для каждого биома выбрать `Config.Objectives.PerBiome` целей из `shared/Objectives.lua` (детерминированно от seed); место: s ∈ [начало биома+350, s станции этого биома −450] (для Пустоши — до FinalS−500), d = ±rng(`MinOffset`,`MaxOffset`); `S.World.ReserveArea(s, d, 45)`.
- Состояния: `pending` → `active` (автобус ближе 900 studs или игрок ближе 400 — тогда строится место цели в `workspace.Objectives`) → `done`/`failed`. Места не выгружаются с чанками.
- Типы (см. комментарий в `shared/Objectives.lua`): collect (ящики с гарантированными предметами + засчитываются подборы этого предмета командой после активации через `Objectives.OnItemPickup`), clear (`S.Zombies.Spawn("nest")` + охрана с tag), rescue (дружественный NPC-выживший; «Позвать за собой» → идёт за игроком; цель выполнена, когда внутри автобуса `S.Bus.IsInside`; зарегистрирован как `S.Zombies.AddTarget`; при гибели — провал и новый выживший через 45 с), elite (tag + `onDeath`), defend (объект: радиовышка/насос/генератор; удерживать E 3 с «Починить» → таймер `duration`; волны вокруг; пауза, если рядом нет игроков; объект — цель зомби с HP, при разрушении сброс), cache (ключ `cache_key` в одном месте, тайник в 150 studs; открыть можно с ключом → таблица `cache`).
- Награды за цель: `S.Profile.AddXP(p, Progression.XP.objective)`, `S.Profile.AddTickets(p, Progression.Tickets.objective)` всем игрокам, +$60, Toast.
- **API:** `NewRun(seed)`, `Update(dt)`, `Clear()`, `OnItemPickup(player, itemId, amount)`, `StationRequirement(stationIndex) -> done, need, biomeName`, `FinalRequirement() -> done, need, biomeName`, `CountDone() -> n`, `GetList()`.
- Синхронизация: `ObjectivesSync` (при изменении и раз в 2 с) → `{ objectives = { {id, biomeId, biomeName, type, title, text, progress, goal, state, pos, required} }, biomes = { [biomeId] = {done, need, name} }, currentBiome = id }`.
- **StationService:** ворота открываются, когда орда зачищена **и** `StationRequirement` выполнен (строка цели HUD показывает, чего не хватает); ворота/заборы на всю ширину границ (`Config.Bounds.HalfWidth + 20`); верстак на станции (`S.Workbench.RegisterBench`); награды за станцию через Profile; бой с боссом начинается только при выполненном `FinalRequirement`; `Stations.OnChunkUnloaded(ci)` (сбросить `built` станций/конечной этого чанка, чтобы пересобрать; состояние `clear` сохраняется); орда × `S.Zombies.CountMult()`. Ревизия сервера №4 (стена терминала), №6 (волны внутри автобуса).
- **ObjectivesUI:** трекер (верх-право под миникартой): цели текущего биома, прогресс, «обязательно N из M», расстояние; 3D-метки (BillboardGui AlwaysOnTop) для активных целей в пределах 1500 studs; `ObjectivesUI.GetMarkers()`.

### 3.5 ProfileService / ProgressUI (E)
- DataStore `Config.DataStoreName`, ключ `"u_" .. userId`. Загрузка с повторами; если DataStore недоступен (Studio без доступа к API) — профиль по умолчанию, `saveEnabled=false`, уведомление. Сохранение: выход игрока, автосохранение `Config.AutosaveInterval`, `SaveAll()` в BindToClose. `UpdateAsync`.
- Профиль: `{version, level, xp, tickets, ownedBuses = {school=true}, selectedBus = "school", unlockedDifficulty = "normal", dailyStreak, lastDailyDay, pendingItems = {}, stats = {runs, wins, bestKm, kills, objectives}}`.
- **API:** `OnPlayerAdded(player)` (может yield ≤10 с; вызывается PlayerData), `OnPlayerRemoving(player)`, `Get(player)`, `AddXP(player, amount, reason)` (повышение уровня в цикле, `LevelUp`, пересчёт MaxHealth через `S.PlayerData.MaxHP`), `AddTickets(player, amount, reason)`, `SpendTickets(player, amount) -> bool`, `OwnsBus(player, id)`, `GrantBus(player, id)`, `SelectBus(player, id) -> bool`, `TeamLevel() -> number` (средний уровень игроков сервера, ≥1), `LevelPerks(player) -> {bonusHP, damageBonus}` (через `Progression.LevelPerks`; для игрока без профиля — нули), `AwardRun(player, stats) -> {tickets, xp}` (stats: km, victory, difficulty, kills, objectives, stations; множитель `Difficulty.Get(diff).rewardMult`; победа открывает следующую сложность), `UnlockDifficulty(player, id)`, `TakePendingItems(player) -> map` (очищает), `Save(player)`, `SaveAll()`, `SendSync(player)`, `Update(dt)`.
- Атрибуты игрока: Level, XP, XPNext, Tickets. `ProfileSync` клиенту при изменениях.
- **Ежедневные награды:** при загрузке: если `lastDailyDay ~= сегодня` — доступна награда дня `(streak % 7) + 1` (серия продолжается, если вчера забирал, иначе с 1). `DailyReward` → клиенту `{day, streak, reward, claimable}`. `ClaimDaily` → билеты/опыт сразу, предметы — в `pendingItems` (если идёт заезд и игрок в нём — сразу `S.PlayerData.AddItem`). Повторно в тот же день нельзя.
- **ProgressUI:** полоска «Ур. N • опыт • билеты» над панелью игрока; всплывающее окно ежедневной награды (7 дней, текущий подсвечен, кнопка «Забрать»), кнопка «Награды» для повторного открытия; тост при повышении уровня; окно регистрируется в `C.Panels.RegisterWindow`.

### 3.6 WorkbenchService / WorkbenchUI / WeaponService / LootService / ShopService / Panels / WeaponClient (F)
- `Workbench.RegisterBench(part, kind)` — подсказка «Верстак» → `OpenWorkbench(player, {kind, name})`. `Workbench.NearBench(player) -> bool` (≤ 14 studs от любого живого верстака).
- Удалённые вызовы (проверки: игрок активен, рядом верстак): `Craft(recipeId)` (`shared/Recipes.lua`; опыт `Progression.XP.craft`), `UpgradeWeapon(weaponId)` (`Recipes.WeaponUpgradeFor(level, rarity)`; деньги + материалы; `S.PlayerData.SetWeaponLevel`; обновить инструмент: имя, `Level`, `MaxMag`), `UpgradeBus(upgradeId)` (`Upgrades.NextCost(id, S.Bus.GetLevel(id))`, списать деньги+материалы, `S.Bus.ApplyUpgrade(id)`; при ошибке вернуть).
- Укрепления (`cat="placeable"` через UseItem): баррикада — стена перед игроком (HP `placeHP`, анкор, группа World); капкан — на земле, срабатывает на зомби в 3 studs: урон `trapDamage`, `S.Zombies.Stun(z, trapRoot)`, исчезает. Не больше 6 штук на игрока. Папка `workspace.Placeables`. `Workbench.FindPlaceableNear(pos, radius) -> {position, Damage(amount)} | nil` (только баррикады). `Workbench.Clear()`, `Workbench.Update(dt)`.
- `cat="tool"`: repair_kit у автобуса (`S.Bus.IsNear(player, 25)` → `S.Bus.Repair(busRepair * repairMult)`), lantern (PointLight на персонаже `lightTime` секунд, атрибут `LanternUntil`). `cat="quest"` — подсказка.
- **Уровень оружия:** урон уже учитывает `PD.DamageMult` (уровень внутри). Перезарядка/кулдаун — `Recipes.WeaponCooldownMult(level)`, магазин — `Recipes.WeaponMagBonus(def.mag, level)`. API PlayerData уже есть: `GiveWeapon(player, id, {level, mag})`, `RemoveWeapon(player, id) -> {level, mag}`, `GetWeaponLevel`, `SetWeaponLevel`. Событие `Inventory` приходит клиенту как `(inventory, weaponOrder, weaponLevels)`.
- **Выброс/передача:** `DropWeapon(weaponId)` → `PD.RemoveWeapon` → `Loot.SpawnWeapon(id, cf, parent, {level, mag, dropped=true})`; подобрать выброшенное оружие, если такое уже есть, нельзя (оно остаётся лежать). `GiveItem(target, itemId, count)` и `GiveWeapon(target, weaponId)` — оба активны, дистанция ≤ 16, у получателя нет такого оружия.
- **LootService:** `SpawnItem(itemId, count, cf, parent, key)`, `SpawnWeapon(weaponId, cf, parent, opts{level, mag, dropped, key})`, `SpawnFromTable(tableName, spots, rng, parent, keyPrefix)`, `SpawnSafe(cf, parent, rng, key)` с памятью `S.World.IsLootTaken/MarkLootTaken`; при подборе — `S.Objectives.OnItemPickup(player, itemId, amount)`.
- **ShopService/Panels:** вкладки магазина: Продать, Припасы, Материалы (`Items.Shop.materials`), Патроны, Оружие, Автобус (только ремонт + подсказка «вооружение — на верстаке»). Инвентарь: новые категории, список оружия с уровнями и кнопками «Выбросить»/«Передать», у предмета — «Передать» (ближайшие игроки в 16 studs). Разбор атрибута `Upgrades` нового формата, если нужен.
- **WorkbenchUI:** окно с вкладками «Крафт», «Оружие», «Автобус» (категории `Upgrades.Categories`, уровень N/max, стоимость следующего уровня: деньги + материалы с подсветкой «есть/нужно»).
- **WeaponClient:** Q — выбросить экипированное оружие; кулдаун с учётом атрибута `Level`; ContextActionService для телефона/геймпада (ревизия №3); №5, №9. **Panels:** №6, №11, UIScale (№16).
- **SelectClass (депо):** не вызывает `PD.ApplyClass` — меняет набор на набор. Смена разрешена, только пока выданный стартовый набор цел полностью (`kits[player]`, привязан к идентичности таблицы `d.Inventory`); купленное и улучшенное на верстаке оружие остаётся; повтор того же класса игнорируется; лежачим/мёртвым нельзя.
- **Баррикады игроков** — мягкие препятствия `S.Obstacles.AddBox(..., {hard=false, kind="barricade"})`: автобус их сносит, владелец получает уведомление. Снаряды мародёров останавливаются на баррикаде и наносят ей урон.
- **Управление WeaponClient:** прицел — ButtonL2 (удержание) или экранная кнопка «Прицел» (переключатель); бег — ButtonL3 или кнопка «Бег» (переключатель). Прерванное натяжение лука отправляет `Release(tool, {cancel=true})` — сервер снимает натяжение без выстрела и рассылает `bow_release`.
- `PD.AddItem/RemoveItem` возвращают false для не-чисел, NaN, ±inf и количества < 1 (дробь округляется вниз).
- Ревизия сервера №10 (дробь по мёртвому зомби).

### 3.7 LobbyService / LobbyUI / RunManager (G)
- `Run.Boot()`: `Config.StartMode`: `"run"` → `Run.NewRun({})`; `"lobby"` → `S.Lobby.Start()`; `"auto"` → если `game.PrivateServerId ~= ""` и `game.PrivateServerOwnerId == 0` (зарезервированный сервер) — режим заезда: ждать участников из TeleportData первого игрока (`player:GetJoinData().TeleportData = {mode="run", busType, difficulty, members = {userId...}, leader}`) до `Config.PartyStartTimeout`, затем `NewRun(settings)`; иначе (публичный сервер или Studio) — лобби.
- `Run.Mode` ("lobby"|"run"), `Run.Difficulty`, `Run.BusType`, атрибуты `Mode, Difficulty, DifficultyName, BusType`. RunState в лобби = `"Lobby"`.
- `Run.NewRun(settings)`: очистка (Sleep, Zombies, Projectiles, Loot, Workbench, Events, Objectives, Bus, Obstacles, Effects; скрыть лобби `S.Lobby.Stop()`) → `Stations.NewRun()` → `World.NewRun(seed)` → `Objectives.NewRun(seed)` → `Events.NewRun(seed)` → `DayNight.Reset()` → `Bus.Build(70, busType)` → `World.GenerateAround` → игрокам `ResetForRun`, спавн, выдача `S.Profile.TakePendingItems` (после ResetForRun), окно класса.
- Конец заезда (Victory/Fail): `S.Profile.AwardRun(player, stats)` каждому (stats: km, victory, difficulty, kills, objectives=`S.Objectives.CountDone()`, stations), `EndScreen` (добавить в stats награду каждого игрока: tickets, xp), затем: на зарезервированном сервере — телепорт всех обратно в лобби (`TeleportService:TeleportAsync(game.PlaceId, players)`); в Studio/одиночном сервере — `S.Lobby.Start()`; при `StartMode="run"` — новый заезд.
- `Run.GetSpawnCFrame(player)`: в лобби `S.Lobby.GetSpawnCFrame()`, в заезде — автобус. `Run.CanRespawn()` в лобби — true. `CheckWipe` только в заезде.
- **LobbyService:** `Lobby.Start()` (построить лобби в `workspace.Lobby` около `CFrame.new(0, 0, -4000)`: площадь, ангар-витрина автобусов (простые модели по цветам/размерам BusTypes, подсказка «Автобусы»), доска групп (подсказка «Группы»), киоск наград (подсказка → `S.Profile.SendSync` + повторный показ ежедневной награды), табло лучших км), `Lobby.Stop()` (скрыть/удалить), `Lobby.IsActive()`, `Lobby.GetSpawnCFrame()`, `Lobby.Update(dt)`.
- Группы: `parties[id] = {id, code (4 буквы), leader, members, busType, difficulty, maxSize ≤ Config.MaxPartySize, open}`. `PartyAction(action, data)`: `create{busType, difficulty, maxSize, open}`, `join{id|code}`, `leave`, `kick{userId}`, `setBus{busType}` (лидер владеет автобусом), `setDifficulty{difficulty}` (открыта у лидера), `setOpen{open}`, `start`, `solo` (одиночный старт). `PartyState` → всем в лобби `{parties = {...краткие...}, myParty = {...} | nil, openWindow = "party"|"buses"|nil, startPending = bool}` (`startPending` — у игрока идёт старт/телепорт или его группа уже отправляется; клиент блокирует кнопки). Пока группа игрока стартует или его телепорт не завершён (≤ 45 с), любое `PartyAction` отклоняется.
- Старт: живой сервер → `TeleportService:ReserveServer(game.PlaceId)` + `TeleportAsync(game.PlaceId, members, TeleportOptions{ReservedServerAccessCode, SetTeleportData})`, обработка `TeleportInitFailed` (повтор, уведомление); в Studio или при ошибке — локальный старт `Run.NewRun({busType, difficulty})`.
- `BuyBus(busTypeId)` → `S.Profile.SpendTickets(price)` + `GrantBus`; `SelectBus(busTypeId)` → `S.Profile.SelectBus`.
- **LobbyUI:** окно групп (список открытых групп, создать: автобус/сложность/размер/открытость; своя группа: участники, кик, код, «Старт»; «Играть одному»), окно автобусов (характеристики, цена в билетах, «Купить»/«Выбрать»), подсказка в лобби; окна через `C.Panels.RegisterWindow`.

### 3.8 Исправления и эффекты (H)
- Ревизия клиента: №1 (камера уплывает от отдачи/тряски — снимать смещение до камеры), №2 и №17 (SleepClient), №4, №12, №18 (CharAnimator), №14 (звук «hurt» только при уроне игроку).
- Ревизия сервера: №2 (после пробуждения вернуть сетевое владение игроку), №5 (обморок за рулём — сначала удалить SeatWeld).
- SleepService: множители из `Upgrades.Value("alarm","hearMult",S.Bus.GetLevel("alarm"),1)` и `bunks sleepMult`; `AlarmHearRadius` = `HearRadius * hearMult`.
- Effects: трассеры `weaponId = "mg_turret"` (жёлтые), `"tesla"` (зигзаг голубой молнии), `"raider"` (красные); взрывы `kind = "shell"` (крупный), `"lightning"`, `"meteor"` (огненный шар), `"airdrop"` (цветной дымовой столб на месте ящика, 20 с); цифры урона вида `"elite"` (фиолетовые крупные).
- ProjectileService: снаряды мародёров (`kind="bullet"`, `hitsPlayers=true`, быстрые, без гравитации) — урон игрокам уже поддержан; убедиться, что зомби-снаряды не бьют других зомби и автобус получает урон; снаряд `shell` с `onImpact`.
- CombatService: вид урона `"elite"`, опыт/деньги не дублировать (начисляет ZombieService).

## 4. Сетевые события (новые)

Клиент → сервер: `TurretInput(aimPoint, firing)`, `Craft(recipeId)`, `UpgradeWeapon(weaponId)`, `UpgradeBus(upgradeId)`, `DropWeapon(weaponId)`, `GiveItem(targetPlayer, itemId, count)`, `GiveWeapon(targetPlayer, weaponId)`, `ClaimDaily()`, `PartyAction(action, data)`, `BuyBus(id)`, `SelectBus(id)`.
Сервер → клиент: `OpenWorkbench(info)`, `ProfileSync(snapshot)`, `DailyReward(info)`, `LevelUp(level)`, `PartyState(state)`, `ObjectivesSync(state)`, `EventBanner(info)`, `TurretState(info)`.
Все серверные обработчики проверяют типы аргументов (`typeof`/`type`), расстояния и права.

## 5. Отчёт агента (итоговый ответ)
1. Что реализовано (кратко, по пунктам контракта).
2. Отклонения от контракта и почему.
3. `REQUESTS`: изменения в чужих файлах, без которых фича неполная (файл, что добавить).
4. Результат `luacheck` по своим файлам и `xref` целиком.
